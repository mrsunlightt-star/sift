import Foundation
import OSLog
import Shared

/// All destructive file work lives here (§9).
///
/// Four rules shape this type:
///
///  1. **Trash, never delete.** Every cleanup and uninstall moves items to the
///     Trash through `FileManager.trashItem`, so the user can undo until they
///     empty it. There is no permanent-delete path in this file at all.
///  2. **No shell.** Nothing here builds a command string. Paths with spaces,
///     quotes, newlines or emoji are just paths.
///  3. **Re-validate, then act.** Every item is re-checked against the
///     protection list and re-stat'ed immediately before the move; a stale scan
///     result is never trusted (§13.3).
///  4. **Partial success is reported per item.** One failure never rolls back or
///     hides the items that already moved (§9.3).
public actor FileOperationService {
    /// Snapshot of what the service needs to know about a candidate item.
    public struct Candidate: Sendable, Hashable {
        public let url: URL
        public let category: CleanupCategory
        public let risk: CleanupRisk
        public let sizeInBytes: Int64
        public let displayName: String
        /// The item this candidate came from.
        ///
        /// Pre-flight used to rebuild every item from a five-field snapshot,
        /// which stamped the placeholder explanation and rule id back onto the
        /// row the user approved. Keeping the original preserves the sentence
        /// the scanner attached and the rule that produced it.
        private let original: CleanupItem?

        public init(url: URL, category: CleanupCategory, risk: CleanupRisk, sizeInBytes: Int64, displayName: String) {
            self.url = url
            self.category = category
            self.risk = risk
            self.sizeInBytes = sizeInBytes
            self.displayName = displayName
            self.original = nil
        }

        public init(item: CleanupItem) {
            self.url = item.url
            self.category = item.category
            self.risk = item.risk
            self.sizeInBytes = item.sizeInBytes
            self.displayName = item.displayName
            self.original = item
        }

        /// The candidate as the domain item execution carries.
        func asCleanupItem() -> CleanupItem {
            if let original { return original }
            return CleanupItem(
                url: url,
                displayName: displayName,
                category: category,
                risk: risk,
                sizeInBytes: sizeInBytes,
                fileCount: 1,
                explanationKey: "cleanup.explanation.temporary",
                sourceRuleID: "preflight"
            )
        }

        /// The same candidate at a more cautious risk level.
        ///
        /// Pre-flight uses this when the rule table no longer backs the level
        /// the scan recorded. The item keeps its identity, size and the sentence
        /// the scanner attached, and loses the pre-selection that made `safe`
        /// convenient: a level this build does not vouch for is offered, not
        /// queued.
        func withRisk(_ newRisk: CleanupRisk) -> Candidate {
            guard newRisk != risk else { return self }
            let downgraded = CleanupItem(
                url: url,
                displayName: displayName,
                category: category,
                risk: newRisk,
                sizeInBytes: sizeInBytes,
                fileCount: original?.fileCount ?? 1,
                explanationKey: original?.rawExplanationKey ?? "cleanup.explanation.temporary",
                relatedBundleID: original?.relatedBundleID,
                isRestorable: original?.isRestorable ?? true,
                sourceRuleID: original?.sourceRuleID ?? "preflight",
                modifiedAt: original?.modifiedAt,
                isDirectory: original?.isDirectory ?? false,
                isSelectedByDefault: false,
                note: original?.note
            )
            return Candidate(item: downgraded)
        }
    }

    private let rules: RuleEngine
    private let fileManager: FileManager
    private let logger = SiftLog.operations

    /// Simulated runs, used by the test suite so a test can never move a real
    /// file. Production code never enables this.
    private let isDryRun: Bool
    /// Records what a dry run would have done, so tests can assert on it.
    private var simulatedOperations: [URL] = []
    /// Cached running-application snapshot, refreshed at most once per second.
    private var runningPathsCache: (Date, Set<String>)?
    /// Cached aliases of the running applications, refreshed at most once per
    /// second like the bundle paths.
    private var runningTokensCache: (Date, [String])?
    /// Where the aliases come from.
    ///
    /// Injected so a test can decide which applications are "running" without
    /// launching one, and so this service never has to know about AppKit.
    private let runningTokenProvider: @Sendable () async -> [String]

    public init(
        rules: RuleEngine,
        fileManager: FileManager = .default,
        isDryRun: Bool = false,
        runningTokenProvider: @escaping @Sendable () async -> [String] = {
            await WorkspaceActions.runningApplicationTokens()
        }
    ) {
        self.rules = rules
        self.fileManager = fileManager
        self.isDryRun = isDryRun
        self.runningTokenProvider = runningTokenProvider
    }

    // MARK: - Pre-flight

    /// Checks a selection before anything is moved (§9.2).
    ///
    /// Resolves, in one pass:
    ///  * items the protection list forbids, which are reported and dropped,
    ///  * items that no longer exist, or whose path changed since the scan,
    ///  * symlinks, which are never followed,
    ///  * parent/child overlap, so a folder and a file inside it are not both
    ///    counted,
    ///  * items a running application holds open.
    public func preflight(_ candidates: [Candidate]) async -> PreflightReport {
        var ready: [Candidate] = []
        var skipped: [(item: Candidate, code: ErrorCode, message: String)] = []
        var subsumed: [Candidate] = []
        var protected: [Candidate] = []

        // Deepest paths first, so a parent can absorb its children without the
        // children having been queued already.
        let ordered = candidates.sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }

        for scanned in ordered {
            // The level is re-derived below, so the loop works with a copy: what
            // the scanner recorded and what this pass approves are two different
            // statements, and the second is the one the plan carries.
            var candidate = scanned
            let path = candidate.url.path

            // The scanner marks an item `protected` precisely so it can never be
            // acted on. That decision is repeated here because this service is
            // the last boundary before `trashItem`, and a future entry point must
            // not be able to hand it a protected item by constructing one.
            if !candidate.risk.isCleanable {
                protected.append(candidate)
                logger.notice("Refused a non-cleanable risk at pre-flight")
                continue
            }

            if let reason = rules.protectionReason(for: path) {
                protected.append(candidate)
                logger.notice(
                    "Refused a protected location (code=protectedLocation, reason=\(String(describing: reason)))"
                )
                continue
            }

            if rules.isInExcludedLocation(path) {
                protected.append(candidate)
                logger.notice("Refused a path inside an excluded application's data")
                continue
            }

            // `~/Library`, `~/Applications` and the system containers are places
            // to scan inside, never a single cleanup target. A rule with an empty
            // relative path used to produce exactly such an item; this is the
            // last boundary that refuses one however it was assembled.
            if rules.isCleanupContainer(path) {
                protected.append(candidate)
                logger.notice("Refused a container path at pre-flight")
                continue
            }

            // Only a rule may call an item `safe`, and this is where that is
            // checked rather than assumed. A scan result can be minutes old and
            // the user's rule file can change between the scan and the click, so
            // a `safe` level is re-derived from the table in force now:
            //
            //   * a path no rule may offer at all is refused, which is what keeps
            //     "only a rule can say safe" from depending on every other
            //     producer remembering to say `review`;
            //   * a `safe` item the table no longer backs arrives at the user as
            //     `review`, unselected, instead of pre-selected.
            //
            // `review` and `protected` items are not re-derived: the protection
            // list, the excluded-location list and the container check above are
            // the gates that decide those, and `review` is the level that asks
            // the user anyway.
            if candidate.risk == .safe {
                let derivedRisk = rules.risk(for: path)
                if derivedRisk == .protected {
                    protected.append(candidate)
                    logger.notice("Refused a location no rule may offer (re-derived at pre-flight)")
                    continue
                }
                if derivedRisk != .safe {
                    candidate = candidate.withRisk(.review)
                    logger.notice("Lowered a stale `safe` level to `review` at pre-flight")
                }
            }

            // A symlink is never followed and never moved: its target may be
            // outside the authorised scope.
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                skipped.append((candidate, .protectedLocation, "Symbolic links are never followed."))
                continue
            }

            guard fileManager.fileExists(atPath: path) else {
                skipped.append((candidate, .fileNotFound, LocalizationKey.cleanupFailureFileNotFound.localized))
                continue
            }

            // Reported here as well as at the move, so the confirmation panel
            // says which items are no longer the ones that were scanned.
            if let refusal = Self.refusalForARelocatedPath(candidate.url) {
                logger.notice("Refused an item whose path resolves elsewhere (code=itemChanged)")
                skipped.append((candidate, refusal.code, refusal.message))
                continue
            }

            if isSubsumed(candidate, by: ready) {
                subsumed.append(candidate)
                continue
            }

            // Two different meanings of "in use", and the item is refused for
            // both: an `.app` bundle the user launched, and a cache directory
            // whose owning application is running (see `needsAppClosed`). The
            // second is the one that used to slip through — the move succeeded,
            // the application wrote the directory back, and the space was never
            // reclaimed.
            if await isInUse(candidate.url) {
                skipped.append((candidate, .fileInUse, LocalizationKey.cleanupFailureFileInUse.localized))
                continue
            }
            if await isOwnedByARunningApplication(candidate.url) {
                skipped.append((candidate, .fileInUse, LocalizationKey.cleanupFailureFileInUse.localized))
                logger.notice("Refused an item whose application is running")
                continue
            }

            ready.append(candidate)
        }

        // A parent chosen after its children must still absorb them.
        let resolved = resolveOverlap(ready)
        if resolved.count != ready.count {
            let absorbed = ready.filter { candidate in
                !resolved.contains(where: { $0.url == candidate.url })
            }
            subsumed.append(contentsOf: absorbed)
        }

        // The object each approved item names now. Execution compares this with
        // the object at the path immediately before the move; a path that was
        // re-pointed or whose object was replaced must not be moved. An item
        // whose identity cannot be read is not approved: falling back to the
        // path-only checks is the gap this snapshot exists to close.
        var approved: [Candidate] = []
        var identities: [String: FileIdentitySnapshot] = [:]
        for candidate in resolved {
            guard let identity = FileIdentitySnapshot.of(path: candidate.url.path) else {
                skipped.append((
                    candidate,
                    .fileNotFound,
                    LocalizationKey.cleanupFailureFileNotFound.localized
                ))
                continue
            }
            approved.append(candidate)
            identities[CleanupItem.stableID(category: candidate.category, url: candidate.url)] = identity
        }

        logger.info(
            "Pre-flight: ready=\(approved.count) skipped=\(skipped.count) subsumed=\(subsumed.count) protected=\(protected.count)"
        )
        return PreflightReport(
            ready: approved.map { $0.asCleanupItem() },
            skipped: skipped.map { (item: $0.item.asCleanupItem(), code: $0.code, message: $0.message) },
            subsumed: subsumed.map { $0.asCleanupItem() },
            protected: protected.map { $0.asCleanupItem() },
            identities: identities
        )
    }

    /// Drops any item contained in another selected directory.
    private func resolveOverlap(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates {
            if isSubsumed(candidate, by: kept) { continue }
            kept.append(candidate)
        }
        return kept
    }

    private func isSubsumed(_ candidate: Candidate, by selected: [Candidate]) -> Bool {
        selected.contains { parent in
            parent.url != candidate.url
                && isDirectory(parent.url)
                && RuleEngine.isPrefix(parent.url.path, candidate.url.path)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// True when an application currently holds the file open.
    ///
    /// A running `.app` bundle is the case the user hits in practice: removing
    /// it while it runs produces an opaque failure, so it is reported as
    /// `fileInUse` up front. The check runs on the main actor because only
    /// AppKit knows which applications are running.
    /// `fresh` bypasses the one-second cache. Pre-flight can tolerate a cached
    /// answer because it is only deciding what to offer; the move cannot,
    /// because the confirmation panel may have been open long enough for the
    /// user to launch the application it is about to remove.
    private func isInUse(_ url: URL, fresh: Bool = false) async -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        let running = await cachedRunningBundlePaths(fresh: fresh)
        return running.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// True when the item belongs to an application that is running now.
    ///
    /// A cache directory is not locked the way a bundle is: the move succeeds
    /// while the owner keeps writing into the path it remembers, so the directory
    /// comes back after the cleanup, or the application loses what it was in the
    /// middle of writing. Only a rule that says so (`needsAppClosed`) is asked
    /// about, because the answer costs a walk over the running-application list.
    private func isOwnedByARunningApplication(_ url: URL, fresh: Bool = false) async -> Bool {
        guard rules.requiresAppClosed(for: url.path) else { return false }
        let tokens = await cachedRunningTokens(fresh: fresh)
        guard !tokens.isEmpty else { return false }
        return RuleEngine.isOwnedByRunningApplication(url.path, tokens: tokens)
    }

    /// Aliases of the running applications, cached for one second.
    ///
    /// The pre-flight asks about every selected item; the answer is a snapshot
    /// taken on the main actor, so it is taken once per batch rather than once
    /// per row. Execution passes `fresh`, because the confirmation panel may have
    /// been open long enough for the user to launch the application.
    private func cachedRunningTokens(fresh: Bool = false) async -> [String] {
        let now = Date()
        if !fresh, let cached = runningTokensCache, now.timeIntervalSince(cached.0) < 1 {
            return cached.1
        }
        let tokens = await runningTokenProvider()
        runningTokensCache = (now, tokens)
        return tokens
    }

    /// Why the path no longer names the item that was selected, if it does not.
    ///
    /// A scan result can be minutes old, and the item it names can be replaced
    /// in that window. The dangerous substitution is a symlink in an ancestor:
    /// `trashItem` follows a link in any component of the path, so
    ///
    ///   ~/Library/Caches/com.example.app   ->  ~/Documents
    ///
    /// turns a request to move a cache directory into a request to move
    /// `~/Documents/<whatever the item was called>`. The protection list cannot
    /// catch that: it compares the path as it is written, and the written path
    /// sits under `Caches`.
    ///
    /// The comparison is lexical-versus-resolved through the product's own
    /// normalisation, because `resolvingSymlinksInPath` answers `/var` for a path
    /// under `/private/var` and the alias mapping is what reconciles the two
    /// spellings. A legitimate path therefore compares equal whichever spelling
    /// it arrived in.
    private static func refusalForARelocatedPath(_ url: URL) -> (code: ErrorCode, message: String)? {
        let written = RuleEngine.normalize(url.path)
        let resolved = RuleEngine.normalize(url.resolvingSymlinksInPath().path)
        guard written == resolved else {
            return (.itemChanged, LocalizationKey.cleanupFailureItemChanged.localized)
        }
        return nil
    }

    /// Snapshot of running bundle paths, refreshed at most once per second.
    ///
    /// The pre-flight check asks about every selected item, and a cached snapshot
    /// keeps that from becoming one main-actor hop per file.
    ///
    /// The hop is an `await` rather than a semaphore with a timeout. A wait that
    /// gave up returned an empty set — "nothing is running" about a question that
    /// was never answered — and the main thread went on to write its answer into
    /// the same box the reader had already walked away from.
    private func cachedRunningBundlePaths(fresh: Bool = false) async -> Set<String> {
        let now = Date()
        if !fresh, let cached = runningPathsCache, now.timeIntervalSince(cached.0) < 1 {
            return cached.1
        }
        let paths = Set(await NSWorkspaceWorker.shared.runningApplicationBundlePaths())
        runningPathsCache = (now, paths)
        return paths
    }

    // MARK: - Execution

    /// Moves an approved plan to the Trash.
    ///
    /// This is the only destructive entry point. It takes an `ApprovedPlan`
    /// rather than a live selection so the risk level, the object identity and
    /// the pre-flight refusals are the ones the user approved, not ones a caller
    /// could rebuild from a newer list.
    ///
    /// Returns one result per item. Items are processed sequentially on this
    /// actor so two operations can never race on the same path.
    ///
    /// `refusedByPreflight` is what the caller's pre-flight pass dropped —
    /// `PreflightReport.refusedResults`. Those items never reach this loop, so
    /// they are carried into the outcome here instead: the result page and the
    /// report describe the batch the user approved, and a batch that reported on
    /// nothing but the items that happened to arrive would hide the refusals.
    /// The moved and failed items come first, so the page still leads with what
    /// it did.
    public func execute(_ plan: ApprovedPlan) async -> CleanupOutcome {
        let startedAt = Date()
        var results: [FileOperationResult] = []
        let operation = plan.operation
        let categoryTotals = plan.categoryTotals

        for item in plan.items {
            // A protected item is not executable even if a plan was assembled by
            // hand. The pre-flight pass refuses it too; this is the last word.
            guard item.risk.isCleanable else {
                logger.error("Blocked a non-cleanable risk at execution time")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: ErrorCode.protectedLocation.rawValue,
                        message: LocalizationKey.cleanupFailureProtectedLocation.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // Re-validate every item immediately before acting: the scan result
            // may be minutes old, and a protected path must never slip through
            // because it was classified earlier.
            if let reason = rules.protectionReason(for: item.url.path) {
                logger.error("Blocked a protected path at execution time (reason=\(String(describing: reason)))")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: ErrorCode.protectedLocation.rawValue,
                        message: reason.explanation,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            guard fileManager.fileExists(atPath: item.url.path) else {
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: ErrorCode.fileNotFound.rawValue,
                        message: LocalizationKey.cleanupFailureFileNotFound.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // The same ancestor check as pre-flight. A candidate constructed by
            // another caller, or a path re-pointed after pre-flight, must not be
            // able to reach an excluded application's data through the move.
            if rules.isInExcludedLocation(item.url.path) {
                logger.error("Blocked a path inside an excluded application's data at execution time")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: ErrorCode.protectedLocation.rawValue,
                        message: LocalizationKey.cleanupFailureProtectedLocation.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // A container is never executable, even if a plan was assembled by
            // hand: moving `~/Library` is not a cleanup.
            if rules.isCleanupContainer(item.url.path) {
                logger.error("Blocked a container path at execution time")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: ErrorCode.protectedLocation.rawValue,
                        message: LocalizationKey.cleanupFailureProtectedLocation.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // The last word before the move, and the reason it exists: between
            // the pre-flight check and this line the path can be re-pointed.
            if let refusal = Self.refusalForARelocatedPath(item.url) {
                logger.error("Refused an item whose path resolves elsewhere before the move")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: refusal.code.rawValue,
                        message: refusal.message,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // The path can also stay exactly as it was while the object behind
            // it is replaced. `trashItem` would then move the new object, which
            // the user never selected and the protection list never judged.
            // Pre-flight recorded the object it approved; anything else at this
            // path now is refused. A missing snapshot is refused too: falling
            // back to the path checks is exactly the gap this snapshot closes.
            guard let expected = plan.identities[item.id] else {
                logger.error("Refused an item without a pre-flight identity (code=itemChanged)")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: ErrorCode.itemChanged.rawValue,
                        message: LocalizationKey.cleanupFailureItemChanged.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }
            guard let current = FileIdentitySnapshot.of(path: item.url.path), current == expected else {
                logger.error("Refused an item whose object changed before the move (code=itemChanged)")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: ErrorCode.itemChanged.rawValue,
                        message: LocalizationKey.cleanupFailureItemChanged.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            // The state that can change while the panel is open, and that the
            // identity check cannot see: the object is the same, but its
            // application is now running. Moving it then would either fail
            // opaquely or pull a bundle out from under a live process.
            let bundleInUse = await isInUse(item.url, fresh: true)
            let ownerRunning = await isOwnedByARunningApplication(item.url, fresh: true)
            if bundleInUse || ownerRunning {
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: ErrorCode.fileInUse.rawValue,
                        message: LocalizationKey.cleanupFailureFileInUse.localized,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            if isDryRun {
                simulatedOperations.append(item.url)
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        destinationURL: URL(fileURLWithPath: "/Trash").appendingPathComponent(item.displayName),
                        status: .movedToTrash,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                continue
            }

            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        destinationURL: resultingURL as URL?,
                        status: .movedToTrash,
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
                logger.debug(
                    "Moved one item to the Trash (category=\(item.category.rawValue, privacy: .public) band=\(SizeBand(bytes: item.sizeInBytes).rawValue, privacy: .public))"
                )
            } catch {
                let code = Self.classify(error)
                logger.error(
                    "Move failed (code=\(code.rawValue, privacy: .public) category=\(item.category.rawValue, privacy: .public))"
                )
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: code.rawValue,
                        message: Self.message(for: error, code: code),
                        sizeInBytes: item.sizeInBytes,
                        category: item.category
                    )
                )
            }
        }

        let finishedAt = Date()
        results.append(contentsOf: plan.refusedResults)
        let outcome = CleanupOutcome(
            results: results,
            categoryTotals: categoryTotals,
            startedAt: startedAt,
            finishedAt: finishedAt,
            operationName: operation
        )
        logger.info(
            "Batch finished (moved=\(outcome.movedCount) skipped=\(outcome.skippedCount) failed=\(outcome.failedCount) band=\(SizeBand(bytes: outcome.releasedBytes).rawValue, privacy: .public))"
        )
        return outcome
    }

    /// Reveals the Trash in Finder, for the "show me where it went" button.
    public func trashDirectoryURL() -> URL {
        // `~/.Trash` is where `trashItem` puts things for the current user.
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// The operations a dry run recorded. Test-only.
    public func simulatedOperationCount() -> Int { simulatedOperations.count }

    // MARK: - Error classification

    /// Maps a `FileManager` error onto the product error table (§14).
    static func classify(_ error: Error) -> ErrorCode {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .fileNotFound
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied
            case NSFileWriteVolumeReadOnlyError, NSFileWriteUnknownError:
                return .volumeUnavailable
            case NSFileWriteFileExistsError:
                return .partialFailure
            default:
                return .partialFailure
            }
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case EBUSY, ETXTBSY:
                return .fileInUse
            case EACCES, EPERM:
                return .permissionDenied
            case ENOENT:
                return .fileNotFound
            case EROFS:
                return .volumeUnavailable
            default:
                return .partialFailure
            }
        default:
            return .partialFailure
        }
    }

    /// A user-facing sentence, never the raw system error text.
    static func message(for error: Error, code: ErrorCode) -> String {
        _ = error
        return code.localizedTitle.localized
    }
}
