import CryptoKit
import Foundation
import OSLog
import Shared

/// The pure-Swift scanner.
///
/// It exists for three reasons:
///
///  1. **The app must run without the Rust binary.** A `swift build` that has not
///     run the Rust step still gets a working cleaner.
///  2. **It is the reference implementation.** The Rust core's rule, protection
///     and duplicate behaviour is checked against this one, so a divergence is a
///     test failure rather than a user-visible difference.
///  3. **It makes the whole pipeline testable** in a plain Swift test suite, with
///     no cross-language build.
///
/// It follows the same contracts as the Rust engine: symlinks are never followed,
/// protected paths are refused, one unreadable folder never fails a scan, results
/// are paged, and nothing here deletes anything.
public actor SwiftScannerEngine: ScannerEngine {
    public nonisolated let kind: ScannerEngineKind = .swift

    private let rules: RuleEngine
    private let logger = SiftLog.scan

    /// Duplicate-scan tuning; mirrors `DuplicateOptions` on the Rust side.
    public struct DuplicateOptions: Sendable {
        public var minimumBytes: Int64
        public var maximumFullHashes: Int
        public var roots: [String]

        public init(
            minimumBytes: Int64 = ScanDefaults.duplicateMinimumBytes,
            maximumFullHashes: Int = 50_000,
            roots: [String] = []
        ) {
            self.minimumBytes = minimumBytes
            self.maximumFullHashes = maximumFullHashes
            self.roots = roots
        }

        public static let `default` = DuplicateOptions()
    }

    public init(rules: RuleEngine) {
        self.rules = rules
    }

    public func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        let sessionID = UUID().uuidString
        let session = SwiftScanSession(id: sessionID, request: request, rules: rules)
        await session.start()
        logger.info(
            "Scan started (engine=swift roots=\(request.roots.count) duplicates=\(request.includeDuplicates, privacy: .public))"
        )
        return session
    }

    public func analyzeStorage(roots: [ScanRoot]) async throws -> StorageAnalysis {
        let flag = CancellationFlag()
        return try await StorageAnalyzer(rules: rules).analyze(
            roots: roots,
            cancelled: { flag.isCancelled }
        )
    }
}

/// One Swift scan session.
///
/// The session owns an index of every item it found and publishes coalesced
/// events, exactly like the Rust coordinator: `pollEvents` returns at most one
/// progress event per drain, and item batches are bounded.
actor SwiftScanSession: ScanSession {
    nonisolated let id: String

    private let request: ScanRequest
    private let rules: RuleEngine
    private let logger = SiftLog.scan

    private var events: [ScanEvent] = []
    private var items: [CleanupItemSummary] = []
    private var groups: [DuplicateGroup] = []
    private var skipped: [SkippedLocation] = []
    private var progress = ScanProgress()
    private var phase: ScanPhase = .idle
    private var cancelled = false
    private var finished = false
    private var task: Task<Void, Never>?

    private let eventBatchSize: Int

    /// Cancellation flag readable from the walker's synchronous closure.
    ///
    /// The walker runs inside this actor's detached task and only ever observes
    /// the flag, so a small locked box is both sufficient and free of a hop back
    /// onto the actor (which would deadlock while the actor is busy).
    private nonisolated let cancellationFlag = CancellationFlag()

    init(id: String, request: ScanRequest, rules: RuleEngine) {
        self.id = id
        self.request = request
        self.rules = rules
        self.eventBatchSize = 512
    }

    func start() {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    // MARK: - Session interface

    func pollEvents(maxEvents: Int) -> [ScanEvent] {
        guard !events.isEmpty else { return [] }
        var drained: [ScanEvent] = []
        var progressEmitted = false
        // Progress is coalesced: a slow poller should see current numbers, not a
        // backlog. Item batches and lifecycle events are never dropped.
        while drained.count < maxEvents, !events.isEmpty {
            let event = events[0]
            if case .progress = event {
                let hasNewerProgress = events.dropFirst().contains { candidate in
                    if case .progress = candidate { return true }
                    return false
                }
                if progressEmitted || hasNewerProgress {
                    events.removeFirst()
                    continue
                }
                progressEmitted = true
            }
            drained.append(events.removeFirst())
        }
        return drained
    }

    func isFinished() -> Bool { finished }

    func page(offset: Int, limit: Int, sort: ScanSort, category: CleanupCategory?) async throws -> ScanPage {
        var filtered = items
        if let category {
            filtered = filtered.filter { $0.category == category }
        }
        switch sort {
        case .size: filtered.sort { $0.sizeInBytes > $1.sizeInBytes }
        case .name: filtered.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .modified: filtered.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .category:
            filtered.sort {
                $0.category.displayOrder == $1.category.displayOrder
                    ? $0.sizeInBytes > $1.sizeInBytes
                    : $0.category.displayOrder < $1.category.displayOrder
            }
        }
        let start = min(max(offset, 0), filtered.count)
        let end = min(start + max(limit, 1), filtered.count)
        return ScanPage(items: Array(filtered[start..<end]), remaining: max(filtered.count - end, 0))
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] {
        let start = min(max(offset, 0), groups.count)
        let end = min(start + max(limit, 1), groups.count)
        return Array(groups[start..<end])
    }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] {
        groups.first { $0.id == groupID }?.members ?? []
    }

    func skippedLocations() -> [SkippedLocation] { skipped }

    func cancel() {
        markCancelled()
        logger.notice("Cancellation requested (engine=swift)")
    }

    // MARK: - The scan

    private func run() async {
        let startedAt = Date()
        setPhase(.preparing)

        // Rule-driven categories.
        setPhase(.scanning)
        for rule in rules.rules {
            if cancelled { break }
            // One rule can apply under several roots when it names an authorised
            // anchor, so each is scanned rather than only the first.
            for root in rules.resolvedRoots(for: rule) {
                if cancelled { break }
                guard directoryExists(root), isAuthorised(root) else { continue }
                scanRule(rule, root: root)
            }
        }

        if !cancelled { scanApplicationResidue() }
        if !cancelled { scanThresholdFiles() }

        if cancelled {
            finishCancelled(startedAt: startedAt)
            return
        }

        if request.includeDuplicates {
            setPhase(.indexing)
            scanDuplicates()
        }

        if cancelled {
            finishCancelled(startedAt: startedAt)
            return
        }
        finish(startedAt: startedAt)
    }

    private func setPhase(_ next: ScanPhase) {
        phase = next
        progress.phase = next
        events.append(.phaseChanged(next))
        events.append(.progress(progress))
    }

    /// True when the home directory sits inside a root the caller allows cleaning.
    private var homeIsCleanable: Bool {
        if request.roots.isEmpty { return true }
        let home = URL(fileURLWithPath: rules.homeDirectory)
        return request.roots.contains {
            $0.isCleanable && RuleEngine.isPrefix($0.url.path, home.path)
        }
    }

    private func isAuthorised(_ url: URL) -> Bool {
        // With no explicit roots the standard home rules apply; with roots, the
        // location must sit inside one the caller marked cleanable. A
        // measure-only root contributes to storage totals and nothing else.
        if request.roots.isEmpty { return true }
        return request.roots.contains {
            $0.isCleanable && RuleEngine.isPrefix($0.url.path, url.path)
        }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func options(for mode: FileWalker.Mode, maxDepth: Int? = nil, home: URL) -> FileWalker.Options {
        FileWalker.Options(
            mode: mode,
            homeDirectory: home,
            maxDepth: maxDepth,
            skipDirectoryNames: FileWalker.defaultSkipDirectoryNames,
            skipPaths: request.ignoredPaths,
            skipHidden: skipsHiddenEntries
        )
    }

    private func scanRule(_ rule: RuleEngine.Rule, root: URL) {
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let spec = rule.matchSpec ?? (rule.relativePath.isEmpty ? .childDirectories : .directory)
        // Resolved once per rule, exactly as the Rust core resolves it: a rule
        // that follows the user's stale threshold reads its age from the request
        // rather than from the rule file.
        let minimumAgeDays = rule.effectiveMinAgeDays(
            staleThresholdDays: request.staleThresholdDays
        )

        switch spec {
        case .directory:
            if let item = directoryItem(rule: rule, url: root, minimumAgeDays: minimumAgeDays) {
                add([item])
            }

        case .childDirectories:
            let report = FileWalker.walk(
                root: root,
                options: options(for: .immediateChildren, maxDepth: 1, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            recordSkips(report.skips)
            var found: [CleanupItemSummary] = []
            for entry in report.entries where entry.isDirectory {
                if rule.excludes.contains(where: { entry.displayName == $0 || entry.displayName.hasPrefix($0 + ".") }) {
                    continue
                }
                if rules.isExcludedBundleName(entry.displayName) { continue }
                guard let item = directoryItem(rule: rule, url: entry.url, minimumAgeDays: minimumAgeDays) else {
                    continue
                }
                found.append(item)
            }
            add(found)

        case let .filesByExtension(extensions):
            let report = FileWalker.walk(
                root: root,
                options: options(for: .files, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            recordSkips(report.skips)
            let found = report.entries.compactMap { entry -> CleanupItemSummary? in
                guard !entry.isDirectory else { return nil }
                let ext = entry.url.pathExtension.lowercased()
                guard extensions.contains(ext) else { return nil }
                if let minimumAgeDays,
                   !olderThanDays(entry.modifiedAt, days: minimumAgeDays) {
                    return nil
                }
                return summary(entry: entry, rule: rule)
            }
            add(found)

        case .anyFile:
            let report = FileWalker.walk(
                root: root,
                options: options(for: .files, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            recordSkips(report.skips)
            let found = report.entries.compactMap { entry -> CleanupItemSummary? in
                guard !entry.isDirectory else { return nil }
                if let minimumAgeDays,
                   !olderThanDays(entry.modifiedAt, days: minimumAgeDays) {
                    return nil
                }
                return summary(entry: entry, rule: rule)
            }
            add(found)
        }
    }

    /// Synchronous cancellation read, valid because the actor is single-threaded
    /// for its own state and the walker only needs a boolean.
    private nonisolated var cancelledSync: Bool {
        cancellationFlag.isCancelled
    }

    /// True when a dotfile is outside this scan.
    ///
    /// The "show hidden files" setting changes what a scan produces, so every
    /// traversal in this engine asks the same question, and the Rust core applies
    /// the same rule.
    private var skipsHiddenEntries: Bool { !request.includeHiddenFiles }

    /// True when a name is one this scan must not report.
    private func isOutOfScope(_ name: String) -> Bool {
        skipsHiddenEntries && name.hasPrefix(".")
    }

    /// A directory candidate, measured through the age filter when the rule has one.
    private func directoryItem(
        rule: RuleEngine.Rule,
        url: URL,
        minimumAgeDays: Int?
    ) -> CleanupItemSummary? {
        if rules.protectionReason(for: url.path) != nil { return nil }
        let measured: (bytes: Int64, files: Int)
        var newestQualifying: Date?
        if let minimumAgeDays {
            measured = measureMatching(url: url, days: minimumAgeDays, newest: &newestQualifying)
            // A directory whose files are all still fresh is not a cleanup item.
            guard measured.bytes > 0 else { return nil }
        } else {
            measured = FileWalker.measure(
                url: url,
                rules: rules,
                skipHidden: skipsHiddenEntries,
                isCancelled: { self.cancelledSync }
            )
            guard measured.bytes > 0 else { return nil }
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modified = newestQualifying ?? values?.contentModificationDate
        return CleanupItemSummary(
            id: nextIdentifier(),
            url: url,
            displayName: url.lastPathComponent,
            parentPath: url.deletingLastPathComponent().path,
            category: rule.category,
            risk: rule.risk,
            sizeInBytes: measured.bytes,
            fileCount: measured.files,
            explanationKey: rule.explanationKey,
            sourceRuleID: rule.id,
            modifiedAt: modified,
            isDirectory: true
        )
    }

    /// Measures a directory while keeping only files older than `days`.
    ///
    /// An age threshold belongs to files, not to the folder: `~/Library/Logs/<app>`
    /// may hold a week-old and a year-old log, and only the stale one counts.
    private func measureMatching(url: URL, days: Int, newest: inout Date?) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        var stack = [url]
        while let directory = stack.popLast() {
            if cancelledSync { return (bytes, files) }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey],
                options: []
            ) else { continue }
            for child in contents {
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
                ])
                if values?.isSymbolicLink == true { continue }
                if rules.protectionReason(for: child.path) != nil { continue }
                if isOutOfScope(child.lastPathComponent) { continue }
                if values?.isDirectory == true {
                    stack.append(child)
                    continue
                }
                let modified = values?.contentModificationDate
                guard olderThanDays(modified, days: days) else { continue }
                bytes += FileWalker.allocatedSize(values: values, url: child)
                files += 1
                if let modified, newest == nil || modified > newest! {
                    newest = modified
                }
            }
        }
        return (bytes, files)
    }

    private func summary(entry: FileWalker.Entry, rule: RuleEngine.Rule) -> CleanupItemSummary {
        CleanupItemSummary(
            id: nextIdentifier(),
            url: entry.url,
            displayName: entry.displayName,
            parentPath: entry.parentPath,
            category: rule.category,
            risk: rule.risk,
            sizeInBytes: entry.sizeBytes ?? 0,
            fileCount: 1,
            explanationKey: rule.explanationKey,
            sourceRuleID: rule.id,
            modifiedAt: entry.modifiedAt,
            isDirectory: false
        )
    }

    /// Application residue, matched strictly by bundle identifier (§5.3).
    private func scanApplicationResidue() {
        // Residue is derived from the home directory, so it inherits that root's
        // policy: a measure-only home contributes no candidates.
        guard homeIsCleanable else { return }
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let installed = Set(request.installedBundleIdentifiers.map { $0.lowercased() })
        var found: [CleanupItemSummary] = []

        let locations: [(String, CleanupCategory, CleanupRisk)] = [
            ("Library/Application Support", .applicationResidue, .review),
            ("Library/Caches", .applicationResidue, .review),
            ("Library/Logs", .applicationResidue, .safe),
            ("Library/Saved Application State", .applicationResidue, .review),
        ]
        let rule = RuleEngine.Rule(
            id: "app-residue",
            category: .applicationResidue,
            risk: .review,
            root: .homeLibrary,
            relativePath: "",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.residue",
            isEnabled: true
        )

        for (relative, category, risk) in locations {
            let directory = home.appendingPathComponent(relative)
            guard directoryExists(directory) else { continue }
            let report = FileWalker.walk(
                root: directory,
                options: options(for: .immediateChildren, maxDepth: 1, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            for entry in report.entries where entry.isDirectory {
                let name = entry.displayName
                if rules.isExcludedBundleName(name) { continue }
                if !rules.looksLikeBundleIdentifier(name) { continue }
                if installed.contains(name.lowercased()) { continue }
                let measured = FileWalker.measure(url: entry.url, rules: rules, isCancelled: { self.cancelledSync })
                guard measured.bytes > 0 else { continue }
                found.append(
                    CleanupItemSummary(
                        id: nextIdentifier(),
                        url: entry.url,
                        displayName: name,
                        parentPath: entry.parentPath,
                        category: category,
                        risk: risk,
                        sizeInBytes: measured.bytes,
                        fileCount: measured.files,
                        explanationKey: "cleanup.explanation.residue",
                        sourceRuleID: rule.id,
                        relatedBundleID: name,
                        modifiedAt: entry.modifiedAt,
                        isDirectory: true
                    )
                )
            }
        }

        // Preference files, matched on the full `<bundle-id>.plist` name.
        let preferences = home.appendingPathComponent("Library/Preferences")
        if directoryExists(preferences) {
            let report = FileWalker.walk(
                root: preferences,
                options: options(for: .files, maxDepth: 1, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            for entry in report.entries where !entry.isDirectory {
                let name = entry.displayName
                let stem = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                if rules.isExcludedBundleName(stem) { continue }
                guard rules.looksLikeBundleIdentifier(stem) else { continue }
                if installed.contains(stem.lowercased()) { continue }
                found.append(
                    CleanupItemSummary(
                        id: nextIdentifier(),
                        url: entry.url,
                        displayName: name,
                        parentPath: entry.parentPath,
                        category: .applicationResidue,
                        risk: .review,
                        sizeInBytes: entry.sizeBytes ?? 0,
                        fileCount: 1,
                        explanationKey: "cleanup.explanation.residuePreferences",
                        sourceRuleID: "app-residue-preferences",
                        relatedBundleID: stem,
                        modifiedAt: entry.modifiedAt,
                        isDirectory: false
                    )
                )
            }
        }

        add(found)
    }

    /// Large and old files, only inside the roots the caller supplied.
    private func scanThresholdFiles() {
        let home = URL(fileURLWithPath: rules.homeDirectory)
        for root in request.roots where root.isCleanable {
            if cancelled { return }
            let report = FileWalker.walk(
                root: root.url,
                options: options(for: .files, maxDepth: root.maxDepth, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            recordSkips(report.skips)
            var found: [CleanupItemSummary] = []
            for entry in report.entries where !entry.isDirectory {
                let size = entry.sizeBytes ?? 0
                if size >= request.largeFileThresholdBytes {
                    found.append(
                        CleanupItemSummary(
                            id: nextIdentifier(),
                            url: entry.url,
                            displayName: entry.displayName,
                            parentPath: entry.parentPath,
                            category: .largeFiles,
                            risk: .review,
                            sizeInBytes: size,
                            fileCount: 1,
                            explanationKey: "cleanup.explanation.largeFiles",
                            sourceRuleID: "large-files",
                            modifiedAt: entry.modifiedAt,
                            isDirectory: false
                        )
                    )
                } else if size >= ScanDefaults.oldFileMinimumBytes,
                          olderThanDays(entry.modifiedAt, days: request.oldFileThresholdDays) {
                    found.append(
                        CleanupItemSummary(
                            id: nextIdentifier(),
                            url: entry.url,
                            displayName: entry.displayName,
                            parentPath: entry.parentPath,
                            category: .oldFiles,
                            risk: .review,
                            sizeInBytes: size,
                            fileCount: 1,
                            explanationKey: "cleanup.explanation.oldFiles",
                            sourceRuleID: "old-files",
                            modifiedAt: entry.modifiedAt,
                            isDirectory: false
                        )
                    )
                }
            }
            found.sort { $0.sizeInBytes > $1.sizeInBytes }
            add(found)
        }
    }

    // MARK: - Duplicates

    private func scanDuplicates() {
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let roots: [URL]
        if !request.duplicateRoots.isEmpty {
            roots = request.duplicateRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else if !request.roots.isEmpty {
            roots = request.roots.map(\.url)
        } else {
            roots = ["Downloads", "Desktop", "Documents"]
                .map { home.appendingPathComponent($0) }
                .filter { directoryExists($0) }
        }
        // Duplicate candidates are cleanup candidates: a measure-only root is
        // measured for storage, never offered for removal.
        let allowed = request.roots.filter(\.isCleanable).map(\.url)
        let searchable = roots.filter { root in
            rules.protectionReason(for: root.path) == nil
                && (allowed.isEmpty || allowed.contains { RuleEngine.isPrefix($0.path, root.path) })
        }
        guard !searchable.isEmpty else { return }

        // Stage 1: exact size groups.
        var bySize: [Int64: [URL]] = [:]
        for root in searchable {
            let report = FileWalker.walk(
                root: root,
                options: options(for: .files, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            progress.filesSeen += report.totalFiles
            progress.bytesSeen += report.totalBytes
            for entry in report.entries where !entry.isDirectory {
                let size = entry.sizeBytes ?? 0
                guard size >= ScanDefaults.duplicateMinimumBytes else { continue }
                guard let identity = FileIdentity(url: entry.url), !identity.isPlaceholder else { continue }
                // Cloud placeholders are never deletion candidates.
                if entry.url.lastPathComponent.hasSuffix(".icloud")
                    || entry.url.lastPathComponent.contains("com~apple~") {
                    continue
                }
                bySize[size, default: []].append(entry.url)
            }
        }

        // Stage 2 and 3: sample, then hash the survivors.
        var byDigest: [String: (size: Int64, urls: [URL])] = [:]
        var hashes = 0
        for (size, urls) in bySize where urls.count > 1 {
            var bySample: [String: [URL]] = [:]
            for url in urls {
                if cancelled { return }
                guard let sample = sampleFingerprint(url: url, size: size) else { continue }
                bySample[sample, default: []].append(url)
            }
            for (_, sameSample) in bySample where sameSample.count > 1 {
                for url in sameSample {
                    if cancelled { return }
                    guard hashes < 50_000 else { return }
                    guard let digest = fullDigest(url: url) else { continue }
                    hashes += 1
                    var entry = byDigest[digest] ?? (size, [])
                    entry.urls.append(url)
                    byDigest[digest] = entry
                }
            }
        }

        // Stage 4: groups, with a keeper.
        var built: [DuplicateGroup] = []
        for (digest, value) in byDigest where value.urls.count > 1 {
            let sorted = value.urls.sorted { $0.path < $1.path }
            let keeper = chooseKeeper(sorted)
            let members = sorted.map { url -> DuplicateMember in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return DuplicateMember(
                    url: url,
                    sizeInBytes: value.size,
                    modifiedAt: modified,
                    isRecommendedToKeep: url == keeper
                )
            }
            built.append(
                DuplicateGroup(
                    id: Int64(built.count + 1),
                    contentHash: digest,
                    fileSizeInBytes: value.size,
                    members: members,
                    reclaimableSizeInBytes: value.size * Int64(members.count - 1)
                )
            )
        }
        built.sort { $0.reclaimableSizeInBytes > $1.reclaimableSizeInBytes }
        groups = built
        for (index, group) in built.enumerated() {
            events.append(
                .duplicateGroupFound(
                    index: index,
                    memberCount: group.members.count,
                    reclaimableBytes: group.reclaimableSizeInBytes
                )
            )
        }
    }

    /// Head/tail/middle fingerprint: cheap rejection of same-sized non-duplicates.
    private func sampleFingerprint(url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let sampleBytes = 8 * 1024
        // Small files are read whole; large files only at the sample points.
        let offsets: [UInt64] = size <= 96 * 1024
            ? [0]
            : [0, UInt64(max(size / 2 - Int64(sampleBytes / 2), 0)), UInt64(max(size - Int64(sampleBytes), 0))]
        for offset in offsets {
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            let data = (try? handle.read(upToCount: sampleBytes)) ?? Data()
            hasher.update(data: data)
            if size <= 96 * 1024, data.count < sampleBytes { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Full-content digest, streamed and cancellable.
    private func fullDigest(url: URL) -> String? {
        guard let before = FileIdentity(url: url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancelled { return nil }
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        // A file that changed while hashing is not reported as truth.
        guard let after = FileIdentity(url: url), after == before else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the oldest copy, then the shortest path, then the first alphabetically.
    private func chooseKeeper(_ urls: [URL]) -> URL {
        var best = urls[0]
        var bestModified = (try? best.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        for url in urls.dropFirst() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let better: Bool
            if modified == nil {
                better = false
            } else if bestModified == nil {
                better = true
            } else if modified != bestModified {
                better = modified! < bestModified!
            } else {
                better = url.path.count < best.path.count
            }
            if better {
                best = url
                bestModified = modified
            }
        }
        return best
    }

    // MARK: - Bookkeeping

    private var identifier: Int64 = 0
    private func nextIdentifier() -> Int64 {
        identifier += 1
        return identifier
    }

    /// Adds a batch of items, publishing bounded event batches.
    private func add(_ found: [CleanupItemSummary]) {
        guard !found.isEmpty else { return }
        items.append(contentsOf: found)
        progress.itemsFound = items.count
        var index = 0
        while index < found.count {
            let end = min(index + eventBatchSize, found.count)
            events.append(.itemsFound(Array(found[index..<end])))
            index = end
        }
        events.append(.progress(progress))
    }

    private func recordSkips(_ skips: [FileWalker.Skip]) {
        for skip in skips {
            // Bounded and deduplicated: a user does not need 4,000 identical
            // permission warnings.
            guard skipped.count < 200 else { return }
            let location = SkippedLocation(
                url: skip.url,
                code: skip.code.rawValue,
                message: skip.message,
                needsFullDiskAccess: skip.needsFullDiskAccess
            )
            if skipped.contains(where: { $0.id == location.id }) { continue }
            skipped.append(location)
            events.append(.locationSkipped(location))
        }
    }

    private func finish(startedAt: Date) {
        phase = skipped.isEmpty ? .ready : .partial
        progress.phase = phase
        let report = buildReport(startedAt: startedAt, phase: phase)
        events.append(.phaseChanged(phase))
        events.append(.completed(report))
        finished = true
        logger.info(
            "Scan finished (engine=swift phase=\(self.phase.rawValue, privacy: .public) items=\(self.items.count) skipped=\(self.skipped.count))"
        )
    }

    private func finishCancelled(startedAt: Date) {
        phase = .cancelled
        progress.phase = .cancelled
        events.append(.phaseChanged(.cancelled))
        events.append(.completed(buildReport(startedAt: startedAt, phase: .cancelled)))
        finished = true
        logger.notice("Scan cancelled (engine=swift items=\(self.items.count))")
    }

    private func buildReport(startedAt: Date, phase: ScanPhase) -> ScanReport {
        var totals: [CleanupCategory: (count: Int, bytes: Int64)] = [:]
        for item in items {
            var entry = totals[item.category] ?? (0, 0)
            entry.count += 1
            entry.bytes += item.sizeInBytes
            totals[item.category] = entry
        }
        let categoryTotals = totals
            .map { CategoryTotal(category: $0.key, itemCount: $0.value.count, totalBytes: $0.value.bytes) }
            .sorted { $0.category.displayOrder < $1.category.displayOrder }
        return ScanReport(
            sessionID: id,
            startedAt: startedAt,
            finishedAt: Date(),
            phase: phase,
            scannedFileCount: progress.filesSeen,
            scannedByteCount: progress.bytesSeen,
            scannedLocationCount: request.roots.count,
            itemCount: items.count,
            itemBytes: items.reduce(0) { $0 + $1.sizeInBytes },
            categoryTotals: categoryTotals,
            duplicateGroupCount: groups.count,
            duplicateReclaimableBytes: groups.reduce(0) { $0 + $1.reclaimableSizeInBytes },
            skippedLocations: skipped
        )
    }

    private func olderThanDays(_ date: Date?, days: Int) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) >= Double(days) * 86_400
    }

    func markCancelled() {
        cancelled = true
        cancellationFlag.isCancelled = true
    }
}

