import CryptoKit
import Darwin
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
        // The rules are anchored to one home directory. A request naming a
        // different one would be measured against the wrong protection list,
        // while the Rust core anchors to the request — the two engines would
        // scan different trees. Refuse the mismatch instead of guessing.
        guard RuleEngine.normalize(request.homeDirectory.path) == rules.homeDirectory else {
            throw ScannerError(
                code: .invalidRequest,
                message: "The scan request and the rule table name different home directories."
            )
        }
        let sessionID = UUID().uuidString
        let session = SwiftScanSession(id: sessionID, request: request, rules: rules)
        await session.start()
        logger.info(
            "Scan started (engine=swift roots=\(request.roots.count) duplicates=\(request.includeDuplicates, privacy: .public))"
        )
        return session
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
    /// Index by normalised path, so two rules that match one location produce
    /// one row at the more cautious risk — the same merge the Rust coordinator
    /// performs before its index.
    private var itemIndexByPath: [String: Int] = [:]
    private var duplicatesTruncated = false
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

    /// The bundle identifiers the name of a group container could stand for.
    ///
    /// macOS writes a group container as `<team-id>.<bundle-id>`, where the team id
    /// carries no dot — which is what makes splitting on the first dot safe — or as
    /// the bundle identifier on its own, and an app group may add a leading
    /// `group.`. The readings are returned in lower case, longest-lived first, and
    /// the caller compares *every* one against the installed applications: deciding
    /// on a single reading is how a shared container of an installed application
    /// gets offered for removal. The Rust scanner reads the same two spellings.
    static func groupContainerBundleIdentifiers(_ name: String) -> [String] {
        let lowered = name.lowercased()
        var readings: [String] = []
        if let dot = lowered.firstIndex(of: ".") {
            let prefix = String(lowered[lowered.startIndex..<dot])
            let suffix = String(lowered[lowered.index(after: dot)...])
            if !prefix.contains("."), !suffix.isEmpty {
                readings.append(suffix)
            }
        }
        readings.append(lowered)
        return readings
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
                add([item], dedupeParents: true)
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
                if rules.isExcludedByRule(rule, path: entry.url.path, under: root.path) {
                    continue
                }
                if rules.isExcludedBundleName(entry.displayName) { continue }
                // A child that is a container (`~/Library` from a home rule) is
                // never a single item.
                if rules.isCleanupContainer(entry.url.path) { continue }
                guard let item = directoryItem(rule: rule, url: entry.url, minimumAgeDays: minimumAgeDays) else {
                    continue
                }
                found.append(item)
            }
            add(found, dedupeParents: true)

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
                if rules.isExcludedByRule(rule, path: entry.url.path, under: root.path) {
                    return nil
                }
                let ext = entry.url.pathExtension.lowercased()
                guard extensions.contains(ext) else { return nil }
                if let minimumAgeDays,
                   !olderThanDays(entry.modifiedAt, days: minimumAgeDays) {
                    return nil
                }
                return summary(entry: entry, rule: rule)
            }
            add(found, dedupeParents: true)

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
                if rules.isExcludedByRule(rule, path: entry.url.path, under: root.path) {
                    return nil
                }
                if let minimumAgeDays,
                   !olderThanDays(entry.modifiedAt, days: minimumAgeDays) {
                    return nil
                }
                return summary(entry: entry, rule: rule)
            }
            add(found, dedupeParents: true)
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
        if rules.isCleanupContainer(url.path) { return nil }
        // A `directory` rule whose relative path names a file must not become a
        // zero-byte item labelled as a directory.
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        let measured: (bytes: Int64, files: Int)
        var oldestQualifying: Date?
        if let minimumAgeDays {
            let matching = measureMatching(
                url: url,
                days: minimumAgeDays,
                oldest: &oldestQualifying,
                skipPaths: request.ignoredPaths
            )
            // The item is the directory, so the move takes every file in it.
            // The threshold may only decide whether the directory qualifies; it
            // must not count a stale subset while the move takes fresh files
            // too. A mixed directory is therefore not a cleanup item.
            let whole = FileWalker.measure(
                url: url,
                rules: rules,
                skipHidden: skipsHiddenEntries,
                skipPaths: request.ignoredPaths,
                isCancelled: { self.cancelledSync }
            )
            guard matching.bytes > 0,
                  matching.bytes == whole.bytes,
                  matching.files == whole.files
            else { return nil }
            // The threshold rule reports the oldest surviving file's date; a
            // directory whose none of its files carry a readable timestamp has
            // no date to report, which the Rust core treats as "not a
            // candidate" rather than falling back to the folder's own mtime.
            guard oldestQualifying != nil else { return nil }
            measured = whole
        } else {
            measured = FileWalker.measure(
                url: url,
                rules: rules,
                skipHidden: skipsHiddenEntries,
                skipPaths: request.ignoredPaths,
                isCancelled: { self.cancelledSync }
            )
            guard measured.bytes > 0 else { return nil }
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modified = oldestQualifying ?? values?.contentModificationDate
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
    /// `oldest` receives the *oldest* surviving file's modification time, which
    /// is what the Rust core reports for the row.
    private func measureMatching(
        url: URL,
        days: Int,
        oldest: inout Date?,
        skipPaths: [String]
    ) -> (bytes: Int64, files: Int) {
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
                if rules.isInExcludedLocation(child.path) { continue }
                if skipPaths.contains(where: { RuleEngine.isPrefix($0, child.path) }) { continue }
                if isOutOfScope(child.lastPathComponent) { continue }
                if values?.isDirectory == true {
                    stack.append(child)
                    continue
                }
                let modified = values?.contentModificationDate
                guard olderThanDays(modified, days: days) else { continue }
                bytes += FileWalker.allocatedSize(values: values, url: child)
                files += 1
                if let modified, oldest == nil || modified < oldest! {
                    oldest = modified
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
        // policy: a measure-only home contributes no candidates. An empty
        // installed list is not "no applications": every Mac has system bundles,
        // so it means discovery failed, and without that list every live
        // container would be reported as belonging to an uninstalled app.
        guard homeIsCleanable, !request.installedBundleIdentifiers.isEmpty else { return }
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let installed = Set(request.installedBundleIdentifiers.map { $0.lowercased() })
        var found: [CleanupItemSummary] = []

        // The locations residue may live in, mirroring the Rust scanner. A
        // container is an application's whole data directory, so it is here — where
        // the name is checked against the installed bundle identifiers — rather than
        // in a rule, which can only match a name shape or an age.
        let locations: [(String, CleanupCategory, CleanupRisk)] = [
            ("Library/Application Support", .applicationResidue, .review),
            ("Library/Caches", .applicationResidue, .review),
            ("Library/Containers", .applicationResidue, .review),
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
                let measured = FileWalker.measure(
                    url: entry.url,
                    rules: rules,
                    // The container is the item: trashing it takes the dotfiles
                    // inside as well, so the measurement must count them. This
                    // matches the Rust residue scanner.
                    skipHidden: false,
                    skipPaths: request.ignoredPaths,
                    isCancelled: { self.cancelledSync }
                )
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

        // `~/Library/Group Containers/<team-id>.<bundle-id>` belongs to an
        // application that is gone when the bundle identifier it names is not
        // installed. macOS writes the name with the team prefix or as the bundle
        // identifier alone, so both readings are consulted: deciding on one alone
        // offers the shared container of an installed application for removal, as
        // `TEAMID.com.example.app` never equals an installed identifier.
        let groupContainers = home.appendingPathComponent("Library/Group Containers")
        if directoryExists(groupContainers) {
            let report = FileWalker.walk(
                root: groupContainers,
                options: options(for: .immediateChildren, maxDepth: 1, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            for entry in report.entries where entry.isDirectory {
                let name = entry.displayName
                if rules.isExcludedBundleName(name) { continue }
                let readings = Self.groupContainerBundleIdentifiers(name)
                if readings.contains(where: { installed.contains($0) }) { continue }
                guard let bundleID = readings.first(where: { rules.looksLikeBundleIdentifier($0) })
                else { continue }
                let measured = FileWalker.measure(
                    url: entry.url,
                    rules: rules,
                    // The container is the item: trashing it takes the dotfiles
                    // inside as well, so the measurement must count them. This
                    // matches the Rust residue scanner.
                    skipHidden: false,
                    skipPaths: request.ignoredPaths,
                    isCancelled: { self.cancelledSync }
                )
                guard measured.bytes > 0 else { continue }
                found.append(
                    CleanupItemSummary(
                        id: nextIdentifier(),
                        url: entry.url,
                        displayName: name,
                        parentPath: entry.parentPath,
                        category: .applicationResidue,
                        risk: .review,
                        sizeInBytes: measured.bytes,
                        fileCount: measured.files,
                        explanationKey: "cleanup.explanation.residueGroupContainer",
                        sourceRuleID: "app-residue-group-containers",
                        relatedBundleID: bundleID,
                        modifiedAt: entry.modifiedAt,
                        isDirectory: true
                    )
                )
            }
        }

        // Preference and web-storage files, matched on the full `<bundle-id>.plist`
        // (or `<bundle-id>.binarycookies`) name. One loop over both directories, but
        // not one sentence: a preference file and a web store are different things
        // to the user deciding whether to remove them.
        for (relative, explanationKey) in [
            ("Library/Preferences", "cleanup.explanation.residuePreferences"),
            ("Library/HTTPStorages", "cleanup.explanation.residueWebStorage"),
        ] {
            let directory = home.appendingPathComponent(relative)
            guard directoryExists(directory) else { continue }
            let report = FileWalker.walk(
                root: directory,
                options: options(for: .files, maxDepth: 1, home: home),
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            for entry in report.entries where !entry.isDirectory {
                let name = entry.displayName
                let stem = name.hasSuffix(".plist")
                    ? String(name.dropLast(6))
                    : (name.hasSuffix(".binarycookies") ? String(name.dropLast(14)) : name)
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
                        explanationKey: explanationKey,
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
        // A granted folder inside the home directory is covered by the home root
        // as well. Without this, the same file arrives twice and the list shows
        // one row per traversal rather than one row per file.
        var seenPaths = Set<String>()
        // A rules-only root stays out even when the home root contains it.
        let rulesOnlyRoots = request.roots
            .filter { !$0.includesThresholdFiles }
            .map(\.url.path)
        for root in request.roots where root.isCleanable && root.includesThresholdFiles {
            if cancelled { return }
            var walkOptions = options(for: .files, maxDepth: root.maxDepth, home: home)
            // Live databases and device backups are not "large files". The Rust
            // scanner uses the same list as `WalkOptions.skip_paths`.
            walkOptions.skipPaths += ThresholdExclusions.paths(home: home)
            walkOptions.skipPaths += rulesOnlyRoots
            let report = FileWalker.walk(
                root: root.url,
                options: walkOptions,
                rules: rules,
                isCancelled: { self.cancelledSync },
                onFile: nil
            )
            recordSkips(report.skips)
            var found: [CleanupItemSummary] = []
            for entry in report.entries where !entry.isDirectory {
                guard seenPaths.insert(RuleEngine.normalize(entry.url.path)).inserted else {
                    continue
                }
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
                            explanationKey: "cleanup.explanation.largeFilesItem",
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
                            explanationKey: "cleanup.explanation.oldFilesItem",
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
        // measured for storage, never offered for removal. An explicit request
        // whose roots are all measure-only therefore has nothing to search —
        // the `allowed.isEmpty` fallback below is only for a request that named
        // no roots at all.
        let allowed = request.roots.filter(\.isCleanable).map(\.url)
        if !request.roots.isEmpty, allowed.isEmpty { return }
        let searchable = Self.nonOverlappingRoots(
            roots.filter { root in
                rules.protectionReason(for: root.path) == nil
                    && (allowed.isEmpty || allowed.contains { RuleEngine.isPrefix($0.path, root.path) })
            }
        )
        guard !searchable.isEmpty else { return }

        // Stage 1: exact size groups.
        var bySize: [Int64: [URL]] = [:]
        // One entry per file. Overlapping roots — the home folder plus a granted
        // folder inside it — used to put the same URL in the list twice, which
        // could then form a "duplicate group" of a file with itself.
        var seenPaths = Set<String>()
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
                guard seenPaths.insert(RuleEngine.normalize(entry.url.path)).inserted else {
                    continue
                }
                bySize[size, default: []].append(entry.url)
            }
        }

        // Stage 2 and 3: sample, then hash the survivors.
        var byDigest: [String: (size: Int64, urls: [URL])] = [:]
        var hashes = 0
        let maxFullHashes = max(request.duplicateMaxFullHashes, 0)
        // Deterministic traversal. The hash budget can run out before every
        // candidate is hashed, and a dictionary's order decided which groups a
        // truncated run happened to include — so two identical scans could
        // report different partial results.
        for size in bySize.keys.sorted() where (bySize[size]?.count ?? 0) > 1 {
            let urls = bySize[size] ?? []
            var bySample: [String: [URL]] = [:]
            for url in urls {
                if cancelled { return }
                guard let sample = sampleFingerprint(url: url, size: size) else { continue }
                bySample[sample, default: []].append(url)
            }
            for sample in bySample.keys.sorted() where (bySample[sample]?.count ?? 0) > 1 {
                let sameSample = bySample[sample] ?? []
                for url in sameSample {
                    if cancelled { return }
                    guard hashes < maxFullHashes else {
                        // The cap is a budget, not a result: the run is partial
                        // and says so instead of reporting a complete list that
                        // silently stopped halfway.
                        duplicatesTruncated = true
                        return
                    }
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
        for digest in byDigest.keys.sorted() where (byDigest[digest]?.urls.count ?? 0) > 1 {
            let value = byDigest[digest] ?? (0, [])
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
        built.sort {
            $0.reclaimableSizeInBytes == $1.reclaimableSizeInBytes
                ? $0.contentHash < $1.contentHash
                : $0.reclaimableSizeInBytes > $1.reclaimableSizeInBytes
        }
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

    /// The roots with duplicates and nested descendants removed.
    ///
    /// `Set` on the original strings only removed paths spelled identically. A
    /// granted folder inside `~/Downloads` survived next to `~/Downloads` and the
    /// tree was walked twice. The sort puts shorter paths first, so a root is
    /// kept only when no already-kept root contains it.
    static func nonOverlappingRoots(_ roots: [URL]) -> [URL] {
        var unique: [String: URL] = [:]
        for root in roots {
            let resolved = root.resolvingSymlinksInPath()
            let path = RuleEngine.normalize(resolved.path)
            if unique[path] == nil {
                unique[path] = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let ordered = unique.keys.sorted { first, second in
            let firstDepth = first.split(separator: "/").count
            let secondDepth = second.split(separator: "/").count
            return firstDepth == secondDepth ? first < second : firstDepth < secondDepth
        }
        var kept: [URL] = []
        for path in ordered {
            if kept.contains(where: { RuleEngine.isPrefix($0.path, path) }) { continue }
            kept.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return kept
    }

    /// Opens `url` for reading without following a symlink in the final component.
    ///
    /// The walker refuses symlinks, but a path can be replaced between the walk
    /// and the hash. Following it then reads a file the scan never judged and
    /// can form a duplicate group around the wrong content.
    private static func openWithoutFollowingSymlink(_ url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Head/tail/middle fingerprint: cheap rejection of same-sized non-duplicates.
    private func sampleFingerprint(url: URL, size: Int64) -> String? {
        guard let handle = Self.openWithoutFollowingSymlink(url) else { return nil }
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
        guard let handle = Self.openWithoutFollowingSymlink(url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if cancelled { return nil }
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        // A file that changed while hashing is not reported as truth. The byte
        // count is checked as well: a read that ended early must not become a
        // digest of a prefix.
        guard let after = FileIdentity(url: url), after == before, total == before.size else {
            return nil
        }
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
    ///
    /// Two rules can name one path, and a rule can name a directory whose child
    /// an earlier rule already reported. The Rust core merges the first case and
    /// drops the second before its index; doing it here keeps the two engines'
    /// rows and totals identical instead of relying on the page to deduplicate.
    private func add(_ found: [CleanupItemSummary], dedupeParents: Bool = false) {
        guard !found.isEmpty else { return }
        var emitted: [CleanupItemSummary] = []
        for incoming in Self.dedupeParentChild(found) {
            let path = RuleEngine.normalize(incoming.url.path)
            if let existing = itemIndexByPath[path] {
                let kept = items[existing]
                // The more cautious risk wins; the rule id breaks a tie so two
                // runs over the same tree produce the same row.
                if (incoming.risk.severity, incoming.sourceRuleID)
                    > (kept.risk.severity, kept.sourceRuleID) {
                    items[existing] = incoming
                }
                continue
            }
            // Across the rule phase, a directory subsumes a child that an
            // earlier rule already reported. The residue and threshold phases
            // opt out: their child is a different cleanup item and Rust keeps
            // both rows.
            if dedupeParents,
               items.contains(where: { candidate in
                   candidate.isDirectory
                       && RuleEngine.isPrefix(
                           RuleEngine.normalize(candidate.url.path),
                           path
                       )
               }) {
                continue
            }
            if dedupeParents, incoming.isDirectory {
                let subsumed = items.indices.filter { index in
                    RuleEngine.isPrefix(path, RuleEngine.normalize(items[index].url.path))
                }
                if !subsumed.isEmpty {
                    for index in subsumed.sorted(by: >) {
                        items.remove(at: index)
                    }
                    rebuildItemIndex()
                }
            }
            itemIndexByPath[path] = items.count
            items.append(incoming)
            emitted.append(incoming)
        }
        guard !emitted.isEmpty else { return }
        progress.itemsFound = items.count
        var index = 0
        while index < emitted.count {
            let end = min(index + eventBatchSize, emitted.count)
            events.append(.itemsFound(Array(emitted[index..<end])))
            index = end
        }
        events.append(.progress(progress))
    }

    private func rebuildItemIndex() {
        itemIndexByPath.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            itemIndexByPath[RuleEngine.normalize(item.url.path)] = index
        }
    }

    /// Drops a candidate contained in another *in the same batch*.
    ///
    /// The scope is deliberate. Rust's `dedupe_parent_child` runs over the
    /// rule-driven candidates and not across the residue or threshold phases: a
    /// residue directory below a rule's directory is its own cleanup item. A
    /// process-wide parent check here dropped that row from the Swift fallback
    /// while the Rust core kept it.
    private static func dedupeParentChild(_ found: [CleanupItemSummary]) -> [CleanupItemSummary] {
        let ordered = found.sorted { first, second in
            let firstDepth = first.url.pathComponents.count
            let secondDepth = second.url.pathComponents.count
            return firstDepth == secondDepth ? first.url.path < second.url.path : firstDepth < secondDepth
        }
        var kept: [CleanupItemSummary] = []
        for item in ordered {
            let path = RuleEngine.normalize(item.url.path)
            if kept.contains(where: { parent in
                parent.isDirectory
                    && RuleEngine.isPrefix(RuleEngine.normalize(parent.url.path), path)
                    && RuleEngine.normalize(parent.url.path) != path
            }) {
                continue
            }
            kept.append(item)
        }
        return kept
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
        phase = (skipped.isEmpty && !duplicatesTruncated) ? .ready : .partial
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

