import Dispatch
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
    /// The session this engine started most recently.
    ///
    /// Kept so a superseded run can be shut down in order — cancel, wait for the
    /// worker to report finished, then release — instead of being freed the
    /// instant the caller drops its reference, which is what let a live worker
    /// keep writing an index that had already been unlinked. Replaced on the
    /// next `startScan`, so at most one session is retained, and the index left
    /// behind by a run the caller released without superseding it is what
    /// `prepareIndexDirectory` sweeps at the start of the next one.
    private var liveSession: RustScanSession?

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
        // The directory this product creates must still be the one its path
        // spells. `Application Support/Sift` re-pointed by a restore would have
        // the sweep — and the engine's own writes after it — act inside the
        // link target. A refused preparation leaves whatever is there for the
        // next launch, the same way a sweep that cannot remove a leftover does.
        guard OwnedLocationRemoval.ancestorsSpellTheLocation(directory.path) else {
            SiftLog.scan.error("Index preparation refused: an ancestor is a symbolic link")
            return
        }
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
            // cannot remove (a permission error, a volume that went away, an
            // ancestor re-pointed since the check above) is left for the next
            // launch instead of failing the one.
            do {
                try OwnedLocationRemoval.remove(at: entry)
            } catch {
                SiftLog.scan.notice("The index sweep left one entry in place")
            }
        }
    }

    /// Removes the database and the WAL/SHM files SQLite writes beside it.
    ///
    /// `-wal` and `-shm` carry the same rows as the database; deleting only the
    /// `.sqlite` file leaves a copy of every scanned path behind.
    fileprivate static func removeIndexArtifacts(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            do {
                try OwnedLocationRemoval.remove(at: URL(fileURLWithPath: url.path + suffix))
            } catch {
                // A refusal or a failure leaves the file behind rather than
                // following a re-pointed ancestor: a stale `-wal` on this
                // machine's own disk is recoverable, a deletion under a link
                // target is not.
                SiftLog.scan.notice("One index artifact was left in place")
            }
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
        // A run is superseded only here: the caller replaces its own reference
        // without telling anyone, so the previous session would otherwise be
        // released the moment it is dropped — handle freed and index unlinked
        // while its worker is still scanning. Tearing it down first is the one
        // ordered place to do it, because this actor is the thing that started
        // it.
        if let previous = liveSession {
            liveSession = nil
            await previous.shutDown()
        }

        let engine = sift_engine_new()
        guard let engine else {
            throw ScannerError(code: .internalError, message: LocalizationKey.commonUnknownError.localized)
        }
        // The handle owns the pointer from this line on, not from the one that
        // builds the session: everything between here and there can throw — the
        // request encoding below, the C start call — and each of those paths
        // reached neither `sift_engine_free` nor a handle's `deinit`, so a scan
        // that failed to assemble leaked the engine and its worker thread.
        let owner = RustEngineHandle(pointer: engine)

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
            // The engine is released by `owner` as this frame unwinds; freeing
            // it here as well would release it twice.
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
        let session = RustScanSession(
            id: sessionID,
            handle: handle,
            owner: owner,
            indexURL: indexURL,
            scannedLocationCount: request.roots.count
        )
        // Remembered so the next `startScan` can tear this one down in order.
        // Holding it changes nothing for the caller, which still owns its own
        // reference: at most one finished session is kept alive here.
        liveSession = session
        return session
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
    // The lock serialises every use, and `releaseResourcesLocked` is the only
    // place it is released, so the single-owner rule holds.
    private let lock = NSLock()
    private let handle: OpaquePointer
    private let owner: RustEngineHandle
    private let indexURL: URL
    /// How many roots the request covered, reported in the summary.
    private let scannedLocationCount: Int
    private let logger = SiftLog.scan
    /// Set once the C handle has been released, so no later call reaches it.
    ///
    /// Guarded by `lock` on every path but `deinit`, which cannot suspend and
    /// runs only after the last strong reference is gone. Without it a page or a
    /// poll that was already in flight when `shutDown()` released the handle
    /// would read freed memory — the very window this session's teardown exists
    /// to close.
    private var released = false

    /// How long a teardown waits for the worker to report finished.
    ///
    /// A worker stops at its next checkpoint, and a checkpoint inside a large
    /// hashing pass takes a moment; two seconds is long enough to reach one and
    /// short enough that a wedged worker cannot stall a teardown for ever.
    private static let teardownTimeout: TimeInterval = 2

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
        // No waiting here, and no lock: `deinit` cannot suspend, and a session is
        // released only after its last caller has let it go.
        //
        // The cancel is still required. The worker holds its own reference to
        // the scan state and is writing the SQLite index, so freeing the handle
        // without asking it to stop left it scanning into a database whose
        // `-wal` and `-shm` this teardown then unlinked — a state SQLite does
        // not support. `shutDown()` is the ordered path; this is the backstop
        // for a session nobody tore down.
        sift_scan_cancel(owner.raw)
        releaseResourcesLocked()
    }

    /// Stops the worker, waits for it, and only then releases everything.
    ///
    /// The order is the point. Cancel, then wait (bounded) for the worker to
    /// report finished, then free the handle and remove the index: releasing
    /// first is how the index came to be unlinked while the worker still held an
    /// open database on it. The wait is bounded rather than indefinite because a
    /// worker stuck in one syscall must not hold teardown for ever, and the
    /// deletion that follows is a fallback, not the proof that it stopped.
    func shutDown() async {
        guard !hasReleased() else { return }

        cancel()

        let deadline = Date().addingTimeInterval(Self.teardownTimeout)
        while Date() < deadline {
            if await isFinished() { break }
            // A cancelled caller stops the wait rather than spinning through it:
            // `Task.sleep` returns immediately once the task is cancelled, so the
            // deadline alone would turn this loop into two seconds of busy work.
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        releaseResources()
    }

    /// Whether the handle is already gone.
    ///
    /// A synchronous question on purpose: `NSLock.lock()` is unavailable from an
    /// async context, so every lock is taken inside a synchronous helper and the
    /// async surface only ever calls those.
    private func hasReleased() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    /// Releases the handle and the index, taking the lock itself.
    private func releaseResources() {
        lock.lock()
        defer { lock.unlock() }
        releaseResourcesLocked()
    }

    /// Releases the C handle and removes the index artifacts, exactly once.
    ///
    /// The name is the contract: every caller holds `lock`, or is `deinit`, which
    /// runs after the last reference is gone. The Rust side now removes its own
    /// index when the worker ends, so the deletion here is the fallback for a
    /// session whose worker never ran (a request the core refused after the file
    /// was created) — and it only ever runs after the worker reported finished,
    /// so nothing is writing those files when they go.
    private func releaseResourcesLocked() {
        guard !released else { return }
        released = true
        sift_scan_free(handle)
        RustScannerEngine.removeIndexArtifacts(at: indexURL)
    }

    /// The queue the event drain runs on.
    ///
    /// One call is a blocking C poll plus decoding of up to 64 events of 512
    /// rows each, with eight strings per row. That is not work for the caller's
    /// executor — and the caller's executor is the main actor, because the pump
    /// runs there — so the drain gets a queue of its own rather than tying up a
    /// cooperative thread that other work needs.
    private static let pollingQueue = DispatchQueue(
        label: "com.siftmac.scanner.rust-poll",
        qos: .userInitiated
    )

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        guard maxEvents > 0 else { return [] }
        // A real `async` body, not a synchronous witness: a sync function
        // satisfies the protocol's `async` requirement without any hop, so
        // `await session.pollEvents(...)` stayed on the main actor and decoded
        // every batch on the UI thread.
        return await withCheckedContinuation { continuation in
            Self.pollingQueue.async {
                continuation.resume(returning: self.drain(maxEvents: maxEvents))
            }
        }
    }

    /// One locked drain, called on `pollingQueue`.
    private func drain(maxEvents: Int) -> [ScanEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return [] }
        return lockedPollEvents(maxEvents: maxEvents)
    }

    private func lockedPollEvents(maxEvents: Int) -> [ScanEvent] {
        var buffer = [SiftScanEvent](repeating: SiftScanEvent(), count: maxEvents)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            sift_scan_poll_events(handle, UInt32(clamping: maxEvents), pointer.baseAddress)
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
        // A released handle reports finished rather than being asked: nothing
        // can happen to this session any more, and a pump that asked would be
        // reading freed memory.
        guard !released else { return true }
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
        // A torn-down session answers with cancellation instead of reading a
        // released handle.
        guard !released else {
            throw ScannerError(
                code: .cancelled,
                message: LocalizationKey.commonUnknownError.localized
            )
        }
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
                            UInt32(clamping: offset),
                            UInt32(clamping: max(limit, 1)),
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
        guard !released else { return [] }
        let capacity = max(limit, 1)
        var buffer = [SiftDuplicateGroup](repeating: SiftDuplicateGroup(), count: capacity)
        let written = sift_scan_page_duplicate_groups(
            handle,
            UInt32(clamping: offset),
            UInt32(clamping: capacity),
            &buffer,
            UInt32(clamping: capacity)
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
        guard !released else { return [] }
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
                UInt32(clamping: offset),
                UInt32(clamping: pageSize),
                &buffer,
                UInt32(clamping: pageSize)
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
        guard !released else { return [] }
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

    /// Forwards cancellation to the Rust flag.
    ///
    /// The lock is taken here like everywhere else, because the handle below is
    /// the one `sift_scan_page_results` is inside: the Rust side accepts a
    /// cancel from any thread, so the unlocked version bought no latency and
    /// allowed two calls into one handle at once. What the wait costs is one
    /// page read — the work the user is already waiting on.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
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
    /// Whether `installedBundleIds` is the whole set.
    ///
    /// Sent under the key the core reads, `installedBundleIdsComplete`. False
    /// means the caller could not finish reading the installed bundles, and the
    /// core then reports no application residue for the run: a partial set is
    /// worse than none, because every application that went unread makes its
    /// live data look like a leftover.
    let installedBundleIdsComplete: Bool
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
                maxDepth: root.maxDepth.map { UInt32(clamping: $0) },
                volumeId: root.volumeIdentifier
            )
        }
        // `clamping` rather than `UInt32(_:)`: these four values come from
        // `UserDefaults`, which the user can write from outside the app
        // (`defaults write … -int 4294967296`), and a trapping conversion here
        // takes the whole app down on the next scan. The settings store clamps
        // them as well; this is the boundary that must not trust its caller, and
        // a value out of range becomes the nearest one the ABI can carry instead
        // of a crash.
        self.largeFileThresholdBytes = UInt64(clamping: request.largeFileThresholdBytes)
        self.oldFileThresholdDays = UInt32(clamping: request.oldFileThresholdDays)
        self.staleThresholdDays = UInt32(clamping: request.staleThresholdDays)
        self.ignorePaths = request.ignoredPaths
        self.authorizedRoots = request.authorizedRoots
        self.installedBundleIds = request.installedBundleIdentifiers
        self.installedBundleIdsComplete = request.installedBundleIdentifiersComplete
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
            maxFullHashes: UInt64(clamping: request.duplicateMaxFullHashes)
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
