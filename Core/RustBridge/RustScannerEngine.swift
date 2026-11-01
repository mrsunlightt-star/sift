import Foundation
import OSLog
import Shared

#if canImport(SiftScanner)
import SiftScanner

/// The production scanner engine: the Rust core through its C ABI (§6.4).
///
/// The shape of this file follows the FFI rules directly:
///
///  * every call crosses once and returns a batch or a page, never one call per
///    file,
///  * the Rust session runs on its own thread; this type only polls and pages,
///  * cancellation is forwarded to the Rust atomic flag immediately,
///  * every byte the Rust side allocates is released here, including on the
///    error paths, so a long scan cannot leak.
///
/// The engine is an `actor` because the session handle and the C buffers are not
/// safe to touch from two threads at once.
actor RustScannerEngine: ScannerEngine {
    nonisolated let kind: ScannerEngineKind = .rust

    private let logger = SiftLog.scan
    private let indexDirectory: URL

    init(indexDirectory: URL = SettingsStore.defaultSupportDirectory().appendingPathComponent("Index", isDirectory: true)) {
        self.indexDirectory = indexDirectory
        Self.prepareIndexDirectory(indexDirectory)
        SiftABILayout.verify()
    }

    /// Creates the index directory with owner-only permissions and empties it.
    ///
    /// The database and its WAL carry every scanned path and file name, which is
    /// the one thing on disk this product must never keep: the directory is 0700
    /// and the files 0600 so another account cannot read them, and nothing in it
    /// outlives the process that wrote it.
    ///
    /// The sweep is unconditional. It used to spare anything younger than a day,
    /// so that a scan still running in another process was never touched — but a
    /// session removes its own index when it ends, so what the age test actually
    /// kept was the debris of a session that died without unwinding: force quit,
    /// a debugger stop, a rebuild while the app was scanning. One day of that on
    /// this machine left 60 databases holding 185 MB of full paths, and they
    /// stayed because a launch is what would have deleted them. A second running
    /// instance is now the only case the sweep reaches into: its database is
    /// unlinked, and its SQLite handle — the one its scan and its paging read
    /// through — stays valid on the deleted inode, so the run is unaffected and
    /// only the file it would have removed itself is gone.
    private static func prepareIndexDirectory(_ directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` does not tighten a directory that already exists.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            // Every entry here was written by this product — the directory is the
            // app's own `Index` folder — so a leftover is removed under its own
            // name rather than by matching a `.sqlite` suffix. A path this sweep
            // cannot remove (a permission error, a volume that went away) is left
            // for the next launch instead of failing the one.
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Removes the database and the WAL/SHM files SQLite writes beside it.
    ///
    /// `-wal` and `-shm` carry the same rows as the database; deleting only the
    /// `.sqlite` file leaves a copy of every scanned path behind.
    fileprivate static func removeIndexArtifacts(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Confirms the linked library matches the header this build compiled against.
    ///
    /// A mismatch is a hard failure rather than a silent misread of a struct.
    static func verifyContractVersion() -> Bool {
        let expected = UInt32(SIFT_FFI_VERSION)
        let actual = sift_ffi_version()
        if actual != expected {
            SiftLog.scan.fault(
                "Scanner ABI version mismatch: header \(expected), library \(actual, privacy: .public)"
            )
            return false
        }
        return true
    }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        guard Self.verifyContractVersion() else {
            throw ScannerError(
                code: .invalidRequest,
                message: "The scanner core and the app disagree on their interface version."
            )
        }
        let engine = sift_engine_new()
        guard let engine else {
            throw ScannerError(code: .internalError, message: LocalizationKey.commonUnknownError.localized)
        }

        // The index lives in the app's data directory and is removed when the
        // session ends: the spec requires scan results not to accumulate.
        // `prepareIndexDirectory` also sets the owner-only permissions.
        Self.prepareIndexDirectory(indexDirectory)
        let sessionID = UUID().uuidString
        let indexURL = indexDirectory.appendingPathComponent("\(sessionID).sqlite")

        let payload = RustScanRequest(request: request, sessionID: sessionID, indexPath: indexURL.path)
        let json = try JSONEncoder().encode(payload)
        let jsonString = String(decoding: json, as: UTF8.self)

        var error = SiftResult()
        let handle = jsonString.withCStringBuffer { buffer in
            sift_scan_start(engine, buffer.value, &error)
        }
        guard let handle else {
            let code = ErrorCode(rawValue: readString(error.code)) ?? .internalError
            let message = readString(error.message).isEmpty
                ? LocalizationKey.commonUnknownError.localized
                : readString(error.message)
            releaseResult(&error)
            sift_engine_free(engine)
            throw ScannerError(code: code, message: message)
        }
        releaseResult(&error)

        // The database holds every scanned path; keep it owner-readable only.
        // SQLite creates `-wal`/`-shm` on first write, but they live in the 0700
        // directory, so the directory permission covers them too.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: indexURL.path + suffix
            )
        }

        logger.info("Scan started (engine=rust roots=\(request.roots.count))")
        let owner = RustEngineHandle(pointer: engine)
        return RustScanSession(
            id: sessionID,
            handle: handle,
            owner: owner,
            indexURL: indexURL,
            scannedLocationCount: request.roots.count
        )
    }

    /// Releases the strings a `SiftResult` owns.
    private func releaseResult(_ result: inout SiftResult) {
        sift_string_free(result.code)
        sift_string_free(result.message)
    }
}

/// Keeps the Rust engine pointer alive for as long as any session needs it.
///
/// The pointer is owned by exactly one session: `deinit` releases it once, and
/// the Rust side tolerates a cancel after the worker finished.
private final class RustEngineHandle: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    var raw: OpaquePointer { pointer }

    deinit {
        sift_engine_free(pointer)
    }
}

/// One Rust scan session.
///
/// A class rather than an actor: the C ABI takes non-`Sendable` pointers and
/// C structs, which an actor cannot hand across an isolation boundary. A lock
/// gives the same guarantee — one caller at a time — without crossing that
/// boundary, and the Rust side does the actual work on its own thread.
private final class RustScanSession: ScanSession, @unchecked Sendable {
    let id: String

    // The Rust handle is an opaque pointer, which Swift cannot prove `Sendable`.
    // The actor serialises every use, and `deinit` is the only place it is
    // released, so the single-owner rule holds.
    private let lock = NSLock()
    private let handle: OpaquePointer
    private let owner: RustEngineHandle
    private let indexURL: URL
    /// How many roots the request covered, reported in the summary.
    private let scannedLocationCount: Int
    private let logger = SiftLog.scan

    init(
        id: String,
        handle: OpaquePointer,
        owner: RustEngineHandle,
        indexURL: URL,
        scannedLocationCount: Int
    ) {
        self.id = id
        self.handle = handle
        self.owner = owner
        self.indexURL = indexURL
        self.scannedLocationCount = scannedLocationCount
    }

    deinit {
        // The lock cannot be taken in `deinit`; that is safe here because a
        // session is released only after its last caller has let it go.
        sift_scan_free(handle)
        // The SQLite index is a scan artifact; removing it keeps the data
        // directory from accumulating paths the user has since deleted. The WAL
        // and shared-memory files hold the same rows and must go with it.
        RustScannerEngine.removeIndexArtifacts(at: indexURL)
        _ = owner
    }

    func pollEvents(maxEvents: Int) -> [ScanEvent] {
        guard maxEvents > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return lockedPollEvents(maxEvents: maxEvents)
    }

    private func lockedPollEvents(maxEvents: Int) -> [ScanEvent] {
        var buffer = [SiftScanEvent](repeating: SiftScanEvent(), count: maxEvents)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            sift_scan_poll_events(handle, UInt32(maxEvents), pointer.baseAddress)
        }
        guard written > 0 else { return [] }

        var events: [ScanEvent] = []
        var sawIncompatible = false
        for index in 0..<Int(written) {
            var raw = buffer[index]
            // Every event owns strings and possibly an item array, even one
            // this build cannot interpret. Free it on every path, including the
            // version-mismatch branch that used to leak it.
            defer { sift_event_free_items(&raw) }
            guard !sawIncompatible else { continue }
            guard raw.version == UInt32(SIFT_FFI_VERSION) else {
                // The library answered with a shape this build did not compile
                // against. A silently skipped event would leave the page waiting
                // for a terminal phase that can never arrive.
                sawIncompatible = true
                events.append(
                    .failed(
                        code: .internalError,
                        message: "The scanner core returned an incompatible event."
                    )
                )
                continue
            }
            if let event = self.convert(&raw) {
                events.append(event)
            }
        }
        return events
    }

    private func convert(_ raw: inout SiftScanEvent) -> ScanEvent? {
        switch raw.kind {
        case 0:
            return .phaseChanged(ScanPhase(rawValue: readString(raw.text)) ?? .idle)

        case 1:
            let phase = switch raw.phase {
            case 1: ScanPhase.preparing
            case 2: ScanPhase.scanning
            case 3: ScanPhase.indexing
            case 4: ScanPhase.ready
            case 5: ScanPhase.cancelled
            case 6: ScanPhase.partial
            case 7: ScanPhase.failed
            default: ScanPhase.idle
            }
            return .progress(
                ScanProgress(
                    phase: phase,
                    filesSeen: Int(raw.files_seen),
                    bytesSeen: raw.bytes_seen,
                    itemsFound: Int(raw.items_found),
                    currentItemName: readString(raw.text)
                )
            )

        case 2:
            guard let pointer = raw.items else { return nil }
            var items: [CleanupItemSummary] = []
            items.reserveCapacity(raw.item_count)
            for index in 0..<raw.item_count {
                let row = pointer[index]
                guard row.version == UInt32(SIFT_FFI_VERSION) else {
                    return .failed(
                        code: .internalError,
                        message: "The scanner core returned an incompatible result row."
                    )
                }
                guard let category = CleanupCategory(rawValue: readString(row.category)),
                      let risk = CleanupRisk(rawValue: readString(row.risk)) else { continue }
                items.append(
                    CleanupItemSummary(
                        id: Int64(items.count + 1),
                        url: URL(fileURLWithPath: readString(row.path)),
                        displayName: readString(row.display_name),
                        parentPath: readString(row.parent_path),
                        category: category,
                        risk: risk,
                        sizeInBytes: row.size_bytes,
                        fileCount: Int(row.file_count),
                        explanationKey: readString(row.explanation_key),
                        sourceRuleID: readString(row.rule_id),
                        relatedBundleID: row.bundle_id.ptr == nil ? nil : readString(row.bundle_id),
                        modifiedAt: row.modified_secs > 0
                            ? Date(timeIntervalSince1970: TimeInterval(row.modified_secs))
                            : nil,
                        isDirectory: row.is_directory
                    )
                )
            }
            return .itemsFound(items)

        case 3:
            return .duplicateGroupFound(
                index: Int(raw.group_index),
                memberCount: Int(raw.member_count),
                reclaimableBytes: raw.reclaimable_bytes
            )

        case 4:
            return .locationSkipped(
                SkippedLocation(
                    url: readString(raw.detail).isEmpty ? nil : URL(fileURLWithPath: readString(raw.detail)),
                    code: readString(raw.text),
                    message: LocalizationKey.scanSkippedReasonPartialFailure.localized,
                    needsFullDiskAccess: raw.flag != 0
                )
            )

        case 5:
            return decodeSummary(readString(raw.text)).map { ScanEvent.completed($0) }

        case 6:
            return .failed(
                code: ErrorCode(rawValue: readString(raw.text)) ?? .internalError,
                message: readString(raw.detail)
            )

        default:
            return nil
        }
    }

    private func decodeSummary(_ json: String) -> ScanReport? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(RustSummary.self, from: data) else { return nil }

        let categories = (payload.categoryTotals ?? []).compactMap { entry -> CategoryTotal? in
            guard let category = CleanupCategory(rawValue: entry.category) else { return nil }
            return CategoryTotal(
                category: category,
                itemCount: Int(entry.itemCount),
                totalBytes: entry.totalBytes
            )
        }
        let skipped = (payload.skipped ?? []).map { entry in
            SkippedLocation(
                url: entry.path.isEmpty ? nil : URL(fileURLWithPath: entry.path),
                code: entry.code,
                message: entry.message,
                needsFullDiskAccess: entry.code == "permissionDenied"
            )
        }
        // `isPartial` is the flag the core computes; the phase string is carried
        // beside it for readers. Deriving the phase from the flag keeps an older
        // core that still writes "ready" from turning a partial scan into a
        // complete one.
        let isPartial = payload.isPartial ?? false
        let phase: ScanPhase = isPartial
            ? .partial
            : (ScanPhase(rawValue: payload.phase ?? "ready") ?? .ready)
        return ScanReport(
            sessionID: payload.sessionId ?? "",
            startedAt: Date(),
            finishedAt: Date(),
            phase: phase,
            scannedFileCount: Int(payload.scannedFileCount ?? 0),
            scannedByteCount: payload.scannedByteCount ?? 0,
            scannedLocationCount: scannedLocationCount,
            itemCount: Int(payload.itemCount ?? 0),
            itemBytes: payload.itemBytes ?? 0,
            categoryTotals: categories,
            duplicateGroupCount: Int(payload.duplicateGroupCount ?? 0),
            duplicateReclaimableBytes: payload.duplicateReclaimableBytes ?? 0,
            skippedLocations: skipped
        )
    }

    func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sift_scan_is_finished(handle)
    }

    func page(offset: Int, limit: Int, sort: ScanSort, category: CleanupCategory?) async throws -> ScanPage {
        try lockedPage(offset: offset, limit: limit, sort: sort, category: category)
    }

    /// Paging that assumes the caller is not inside an async context, so the
    /// lock can be held across the whole C call.
    private func lockedPage(offset: Int, limit: Int, sort: ScanSort, category: CleanupCategory?) throws -> ScanPage {
        lock.lock()
        defer { lock.unlock() }
        var page = SiftPage()
        var error = SiftResult()
        let categoryString = category?.rawValue
        let ok = sort.rawValue.withCStringBuffer { sortBuffer in
            withOptionalCStringBuffer(categoryString) { categoryBuffer in
                let sortValue = sortBuffer.value
                // Already a value descriptor; the optional helper produced it.
                let categoryValue = categoryBuffer
                return withUnsafeMutablePointer(to: &page) { pagePointer in
                    withUnsafeMutablePointer(to: &error) { errorPointer in
                        sift_scan_page_results(
                            handle,
                            UInt32(max(offset, 0)),
                            UInt32(max(limit, 1)),
                            sortValue,
                            categoryValue,
                            pagePointer,
                            errorPointer
                        )
                    }
                }
            }
        }
        defer {
            withUnsafeMutablePointer(to: &page) { sift_page_free($0) }
            sift_string_free(error.code)
            sift_string_free(error.message)
        }
        guard ok else {
            throw ScannerError(
                code: ErrorCode(rawValue: readString(error.code)) ?? .internalError,
                message: readString(error.message)
            )
        }
        guard page.version == UInt32(SIFT_FFI_VERSION) else {
            throw ScannerError(
                code: .internalError,
                message: "The scanner core returned an incompatible result page."
            )
        }

        var items: [CleanupItemSummary] = []
        if let pointer = page.items {
            for index in 0..<page.item_count {
                let row = pointer[index]
                guard row.version == UInt32(SIFT_FFI_VERSION) else {
                    throw ScannerError(
                        code: .internalError,
                        message: "The scanner core returned an incompatible result row."
                    )
                }
                guard let rowCategory = CleanupCategory(rawValue: readString(row.category)),
                      let rowRisk = CleanupRisk(rawValue: readString(row.risk)) else { continue }
                items.append(
                    CleanupItemSummary(
                        id: Int64(offset + index + 1),
                        url: URL(fileURLWithPath: readString(row.path)),
                        displayName: readString(row.display_name),
                        parentPath: readString(row.parent_path),
                        category: rowCategory,
                        risk: rowRisk,
                        sizeInBytes: row.size_bytes,
                        fileCount: Int(row.file_count),
                        explanationKey: readString(row.explanation_key),
                        sourceRuleID: readString(row.rule_id),
                        relatedBundleID: row.bundle_id.ptr == nil ? nil : readString(row.bundle_id),
                        modifiedAt: row.modified_secs > 0
                            ? Date(timeIntervalSince1970: TimeInterval(row.modified_secs))
                            : nil,
                        isDirectory: row.is_directory
                    )
                )
            }
        }
        return ScanPage(items: items, remaining: Int(page.remaining))
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] {
        lockedDuplicateGroups(offset: offset, limit: limit)
    }


    private func lockedDuplicateGroups(offset: Int, limit: Int) -> [DuplicateGroup] {
        lock.lock()
        defer { lock.unlock() }
        let capacity = max(limit, 1)
        var buffer = [SiftDuplicateGroup](repeating: SiftDuplicateGroup(), count: capacity)
        let written = sift_scan_page_duplicate_groups(
            handle,
            UInt32(max(offset, 0)),
            UInt32(capacity),
            &buffer,
            UInt32(capacity)
        )
        defer {
            for index in 0..<buffer.count {
                sift_duplicate_group_free(&buffer[index])
            }
        }
        guard written > 0 else { return [] }

        var groups: [DuplicateGroup] = []
        for index in 0..<Int(written) {
            let row = buffer[index]
            let members = lockedDuplicateMembers(groupID: row.group_id)
            groups.append(
                DuplicateGroup(
                    id: row.group_id,
                    contentHash: readString(row.digest),
                    fileSizeInBytes: row.size_bytes,
                    members: members,
                    reclaimableSizeInBytes: row.reclaimable_bytes
                )
            )
        }
        return groups
    }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] {
        // The synchronous helper is where the lock is taken: a lock cannot be
        // held across a suspension point, so the async surface stays thin.
        lockedDuplicateMembersTakingLock(groupID: groupID)
    }

    private func lockedDuplicateMembersTakingLock(groupID: Int64) -> [DuplicateMember] {
        lock.lock()
        defer { lock.unlock() }
        return lockedDuplicateMembers(groupID: groupID)
    }


    /// Member read that assumes the lock is already held.
    private func lockedDuplicateMembers(groupID: Int64) -> [DuplicateMember] {
        // A group with a very large member count pages internally so a folder
        // with thousands of identical files cannot allocate an unbounded array.
        let pageSize = 512
        var buffer = [SiftDuplicateMember](repeating: SiftDuplicateMember(), count: pageSize)
        var members: [DuplicateMember] = []
        var offset = 0
        while true {
            // `offset` is passed through to the index: before this parameter
            // existed, every call re-read the first page and a group larger than
            // one page accumulated duplicates.
            let written = sift_scan_duplicate_members(
                handle,
                groupID,
                UInt32(offset),
                UInt32(pageSize),
                &buffer,
                UInt32(pageSize)
            )
            if written == 0 { break }
            for index in 0..<Int(written) {
                let row = buffer[index]
                members.append(
                    DuplicateMember(
                        url: URL(fileURLWithPath: readString(row.path)),
                        sizeInBytes: row.size_bytes,
                        modifiedAt: row.modified_secs > 0
                            ? Date(timeIntervalSince1970: TimeInterval(row.modified_secs))
                            : nil,
                        isRecommendedToKeep: row.keep
                    )
                )
            }
            for index in 0..<buffer.count {
                sift_duplicate_member_free(&buffer[index])
            }
            if Int(written) < pageSize { break }
            offset += Int(written)
            if offset > 100_000 { break }
        }
        return members
    }

    func skippedLocations() -> [SkippedLocation] {
        lock.lock()
        defer { lock.unlock() }
        return lockedSkippedLocations()
    }

    private func lockedSkippedLocations() -> [SkippedLocation] {
        let json = sift_scan_skipped_json(handle)
        defer { sift_string_free(json) }
        guard let data = readString(json).data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Row: Decodable {
            let path: String
            let code: String
            let message: String
        }
        guard let rows = try? decoder.decode([Row].self, from: data) else { return [] }
        return rows.map { row in
            SkippedLocation(
                url: row.path.isEmpty ? nil : URL(fileURLWithPath: row.path),
                code: row.code,
                message: row.message,
                needsFullDiskAccess: row.code == "permissionDenied"
            )
        }
    }

    func cancel() {
        // Deliberately unlocked: cancelling must work even while another call
        // holds the lock, and the Rust side accepts it from any thread.
        sift_scan_cancel(owner.raw)
        logger.notice("Cancellation requested (engine=rust)")
    }
}

/// The JSON shape of `ScanRequest` on the Rust side.
private struct RustScanRequest: Encodable {
    let sessionId: String
    let homeDir: String
    let roots: [Root]
    let largeFileThresholdBytes: UInt64
    let oldFileThresholdDays: UInt32
    let staleThresholdDays: UInt32
    let ignorePaths: [String]
    let authorizedRoots: [String]
    let installedBundleIds: [String]
    let appGroupIds: [String]
    let appGroupIdsComplete: Bool
    let runningAppTokens: [String]
    let includeHiddenFiles: Bool
    let extraRulesJson: String?
    let includeDuplicates: Bool
    let duplicates: Duplicates
    let eventBatchItems: UInt32
    let indexPath: String

    struct Root: Encodable {
        let path: String
        let anchor: String
        let isCleanable: Bool
        let includesThresholdFiles: Bool
        let maxDepth: UInt32?
        let volumeId: String?
    }

    struct Duplicates: Encodable {
        let roots: [String]
        let minSizeBytes: UInt64
        let maxFullHashes: UInt64
    }

    init(request: ScanRequest, sessionID: String, indexPath: String) {
        self.sessionId = sessionID
        self.homeDir = request.homeDirectory.path
        self.roots = request.roots.map { root in
            Root(
                path: root.url.path,
                anchor: root.anchor.rawValue,
                isCleanable: root.isCleanable,
                includesThresholdFiles: root.includesThresholdFiles,
                maxDepth: root.maxDepth.map(UInt32.init),
                volumeId: root.volumeIdentifier
            )
        }
        self.largeFileThresholdBytes = UInt64(max(request.largeFileThresholdBytes, 0))
        self.oldFileThresholdDays = UInt32(max(request.oldFileThresholdDays, 0))
        self.staleThresholdDays = UInt32(max(request.staleThresholdDays, 0))
        self.ignorePaths = request.ignoredPaths
        self.authorizedRoots = request.authorizedRoots
        self.installedBundleIds = request.installedBundleIdentifiers
        // The groups installed applications declare: a container named after one
        // of them is live however its name reads.
        self.appGroupIds = request.appGroupIdentifiers
        self.appGroupIdsComplete = request.appGroupIdentifiersComplete
        // A rule that owns one application's data reads this to decide whether
        // its items may stay `safe`. The Swift engine reads the same request
        // field, so both engines downgrade the same items.
        self.runningAppTokens = request.runningApplicationTokens
        self.includeHiddenFiles = request.includeHiddenFiles
        self.extraRulesJson = request.extraRulesJSON
        self.includeDuplicates = request.includeDuplicates
        self.duplicates = Duplicates(
            roots: request.duplicateRoots,
            minSizeBytes: UInt64(ScanDefaults.duplicateMinimumBytes),
            maxFullHashes: UInt64(max(request.duplicateMaxFullHashes, 0))
        )
        // Batches of 512 keep the event queue small without making the poller
        // work per file.
        self.eventBatchItems = 512
        self.indexPath = indexPath
    }
}

/// The JSON shape of `ScanSummary` on the Rust side.
private struct RustSummary: Decodable {
    let sessionId: String?
    let phase: String?
    let scannedFileCount: Int64?
    let scannedByteCount: Int64?
    let itemCount: Int64?
    let itemBytes: Int64?
    let categoryTotals: [Category]?
    let duplicateGroupCount: Int64?
    let duplicateReclaimableBytes: Int64?
    let skipped: [Skip]?
    let isPartial: Bool?

    struct Category: Decodable {
        let category: String
        let itemCount: Int64
        let totalBytes: Int64
    }

    struct Skip: Decodable {
        let path: String
        let code: String
        let message: String
    }
}

#endif
