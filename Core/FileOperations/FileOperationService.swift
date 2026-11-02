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
    /// A suspension point inside the awaited region of `execute`.
    ///
    /// The window this file's ordering exists to close can only be exercised from
    /// inside it: a test has to suspend the loop and then replace an ancestor
    /// with a symbolic link, and no argument can express "be suspended now".
    /// Production never installs one; it is internal so no feature can either.
    private var validationSuspension: (@Sendable () async -> Void)?

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

    /// Installs the test-only suspension described on `validationSuspension`.
    func setValidationSuspension(_ body: (@Sendable () async -> Void)?) {
        validationSuspension = body
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
    /// Checks a selection before anything is moved.
    ///
    /// `intent` is the flow asking, and it changes exactly one answer. The
    /// protection list carries `/Applications` because a rule must never offer
    /// an application: a bundle is not junk, and a rule can only see a name and
    /// an age, never whether the thing inside is still wanted. The uninstaller
    /// is the one flow whose *subject* is the bundle, it does not take its items
    /// from a rule (the user picks from the installed list), and refusing here
    /// would make the feature impossible rather than safe. Nothing else is
    /// lifted — user content, secrets, a recycle bin and every other system
    /// prefix stay refused for both flows — and the exception is keyed on the
    /// protection *reason* rather than on the path, so a second entry that
    /// happens to sit under `/Applications` cannot widen it by accident.
    public func preflight(
        _ candidates: [Candidate],
        intent: CleanupOperationName = .junkCleanup
    ) async -> PreflightReport {
        var ready: [Candidate] = []
        var skipped: [(item: Candidate, code: ErrorCode, message: String)] = []
        var subsumed: [Candidate] = []
        var protected: [Candidate] = []

        // Shallowest paths first, which is the order the overlap rule needs: a
        // parent approved first absorbs every child approved after it, so a
        // folder and a file inside it are one move rather than two. The children
        // are not skipped by this ordering — `isSubsumed` drops them when they
        // arrive — and `resolveOverlap` below covers the reverse order.
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

            let protectionReason = rules.protectionReason(for: path)
            let isApplicationMove = protectionReason.map {
                Self.permitsApplicationMove($0, intent: intent)
            } ?? false

            if let reason = protectionReason, !isApplicationMove {
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
                if derivedRisk == .protected && !isApplicationMove {
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
        // Both sides are folded. `RuleEngine.isPrefix` is case-sensitive because
        // rule matching needs the exact spelling, while the protection list
        // compares case-folded because a default APFS volume is case-insensitive.
        // Using the sensitive one here let `~/Library/Caches/Foo` and
        // `~/Library/caches/foo` sit in one selection as two items: the second
        // was queued instead of absorbed and then failed at the move, because by
        // then the first had taken the directory away.
        let target = RuleEngine.normalize(candidate.url.path).lowercased()
        return selected.contains { parent in
            parent.url != candidate.url
                && isDirectory(parent.url)
                && RuleEngine.isPrefix(RuleEngine.normalize(parent.url.path).lowercased(), target)
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
    ///
    /// A path that cannot be stat'ed is a refusal, not a pass. `resolvingSymlinksInPath`
    /// answers the written path when nothing is there, so a vanished item would
    /// compare equal to itself and be admitted to the move, where the failure
    /// would arrive from `trashItem` instead of from this check — and the two are
    /// not the same statement: an object that does not exist is not an object this
    /// check verified.
    /// Whether this flow may move an application bundle out of `/Applications`.
    ///
    /// Exactly one flow may, and exactly one prefix is lifted. The list protects
    /// `/Applications` because a *rule* must never offer an application: a bundle
    /// is not junk, and a rule can only see a name and an age, never whether the
    /// thing inside is still wanted. The uninstaller's subject is the bundle, and
    /// its items do not come from a rule at all — the user picks one from the
    /// installed list — so the protection is not doing its job there, it is only
    /// making the feature impossible.
    ///
    /// Everything else stays refused for both flows: user content, secrets, a
    /// recycle bin, photo libraries and every other system prefix. The test is
    /// keyed on the protection *reason* rather than on the path so that a future
    /// entry under `/Applications` — `/Applications/Utilities`, a moved system
    /// app — cannot widen the exception by being spelled the same way.
    static func permitsApplicationMove(
        _ reason: RuleEngine.ProtectionReason,
        intent: CleanupOperationName
    ) -> Bool {
        guard intent == .uninstall else { return false }
        if case .systemPath(let prefix) = reason, prefix == "/Applications" {
            return true
        }
        return false
    }

    private static func refusalForARelocatedPath(_ url: URL) -> (code: ErrorCode, message: String)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return (.itemChanged, LocalizationKey.cleanupFailureItemChanged.localized)
        }
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
    /// Moves the approved batch, reporting progress and honouring a soft stop.
    ///
    /// The stop is soft on purpose: it is checked between items, so the move in
    /// hand finishes and the filesystem is never left with a half-moved
    /// directory. Everything already moved stays moved — the outcome says
    /// "stopped after N", and the items that were never reached are neither
    /// failed nor skipped, because nothing judged them.
    public func execute(
        _ plan: ApprovedPlan,
        onProgress: (@Sendable (ExecutionProgress) -> Void)? = nil,
        shouldStop: (@Sendable () -> Bool)? = nil
    ) async -> CleanupOutcome {
        let startedAt = Date()
        var results: [FileOperationResult] = []
        let operation = plan.operation
        let categoryTotals = plan.categoryTotals
        let total = plan.items.count
        var movedBytes: Int64 = 0
        var stoppedAfter: Int?
        /// Progress is published at most twenty times a second: one call per
        /// item would be one main-actor hop per file on a 5,000-item batch.
        var lastEmitted = Date.distantPast

        for (index, item) in plan.items.enumerated() {
            if shouldStop?() == true {
                stoppedAfter = index
                break
            }
            let now = Date()
            if now.timeIntervalSince(lastEmitted) > 0.05 || index == total - 1 {
                lastEmitted = now
                onProgress?(
                    ExecutionProgress(
                        done: index,
                        total: total,
                        movedBytes: movedBytes,
                        currentName: item.displayName
                    )
                )
            }
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
            // because it was classified earlier. The uninstaller's own subject —
            // an application bundle under `/Applications` — is the one reason
            // this flow may look past, and `permitsApplicationMove` is the single
            // place that decision exists.
            let executionProtection = rules.protectionReason(for: item.url.path)
            let executionApplicationMove = executionProtection.map {
                Self.permitsApplicationMove($0, intent: operation)
            } ?? false
            if let reason = executionProtection, !executionApplicationMove {
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

            // The state that can change while the panel is open, and that the
            // identity check cannot see: the object is the same, but its
            // application is now running. Moving it then would either fail
            // opaquely or pull a bundle out from under a live process.
            //
            // These two questions are asked FIRST, and the invariant that
            // explains the order is: **between the last validation and the move
            // there must be no suspension point**. It used to be the other way
            // round — relocation check, identity check, then these two `await`s,
            // then `trashItem` — and the window they opened was real.
            // `trashItem` follows a symbolic link in any component of the path,
            // so an ancestor replaced by a link during the suspension turned a
            // request to move a cache directory into a request to move an object
            // under, say, `~/Documents`: an object the protection list never
            // judged, because the written path still sits under `Caches`, and one
            // the identity snapshot never saw, because it was read before the link
            // appeared.
            let bundleInUse = await isInUse(item.url, fresh: true)
            // The one suspension inside the region a test has to be able to hold
            // open: everything below judges the state this pause leaves behind.
            if let suspended = validationSuspension { await suspended() }
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

            // A level is a statement about a rule table, and the table in force
            // at the move is not necessarily the one the plan was built from. The
            // plan is a snapshot and its `risk` field is data, so a plan assembled
            // by another caller — or one built before the user's rule file changed
            // — can carry a level no rule backs any more. It is re-derived rather
            // than trusted: a path the current table calls `protected` is refused,
            // which is the same statement pre-flight makes before anything is
            // approved.
            if rules.risk(for: item.url.path) == .protected && !executionApplicationMove {
                logger.error("Blocked a location no rule may offer (re-derived at execution time)")
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

            // The last validation, and the reason it is last: between this line
            // and `trashItem` there is nothing that can be suspended. A path
            // re-pointed after the pre-flight check is refused here.
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
            //
            // This is the second half of the same invariant: the object is read
            // after every suspension the loop takes, so a replacement made while
            // the loop was suspended is visible here and the move below is the
            // only thing that follows.
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
                movedBytes += item.sizeInBytes
                logger.debug(
                    "Moved one item to the Trash (category=\(item.category.rawValue, privacy: .public) band=\(SizeBand(bytes: item.sizeInBytes).rawValue, privacy: .public))"
                )
            } catch {
                let code = Self.classify(error, at: item.url)
                // The code alone cannot be diagnosed afterwards: `permissionDenied`
                // covered a TCC refusal, a POSIX refusal and the App Management
                // gate at once, and the log said only "Move failed". The domain,
                // the code and the errno inside it are what tell them apart.
                logger.error(
                    "Move failed (code=\(code.rawValue, privacy: .public) category=\(item.category.rawValue, privacy: .public) error=\(Self.describe(error), privacy: .public))"
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
            operationName: operation,
            stoppedAfter: stoppedAfter
        )
        logger.info(
            "Batch finished (moved=\(outcome.movedCount) skipped=\(outcome.skippedCount) failed=\(outcome.failedCount) band=\(SizeBand(bytes: outcome.releasedBytes).rawValue, privacy: .public))"
        )
        return outcome
    }

    /// Puts a batch back where it came from.
    ///
    /// The one file operation that runs backwards, and it is bounded by the same
    /// two facts everything else here is bounded by: the object has to be the one
    /// that moved (the destination the system handed back), and it has to still
    /// be inside a Trash. A path that does not rebuild to a bin entry is refused
    /// rather than followed — that is what keeps a stale outcome from moving a
    /// file out of somewhere it was never put.
    public func restore(_ results: [FileOperationResult]) async -> RestoreReport {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let ownTrash = home + "/.Trash"
        var restored: [URL] = []
        var failures: [FileOperationResult] = []

        for result in results where result.status == .movedToTrash {
            guard let destination = result.destinationURL else {
                failures.append(
                    FileOperationResult(
                        sourceURL: result.sourceURL,
                        status: .failed,
                        errorCode: ErrorCode.itemChanged.rawValue,
                        message: LocalizationKey.cleanupResultUndoUnavailable.localized,
                        sizeInBytes: result.sizeInBytes,
                        category: result.category
                    )
                )
                continue
            }
            let trashedPath = destination.standardizedFileURL.path
            // The two shapes a Trash can have: this user's own bin, and another
            // volume's `.Trashes/<uid>`.
            let inTrash = trashedPath.hasPrefix(ownTrash + "/") || trashedPath.contains("/.Trashes/")
            guard inTrash, fileManager.fileExists(atPath: trashedPath) else {
                failures.append(
                    FileOperationResult(
                        sourceURL: result.sourceURL,
                        status: .failed,
                        errorCode: ErrorCode.itemChanged.rawValue,
                        message: LocalizationKey.cleanupResultUndoUnavailable.localized,
                        sizeInBytes: result.sizeInBytes,
                        category: result.category
                    )
                )
                continue
            }
            // Never overwrite something that appeared at the original path while
            // the batch sat in the bin: the undo must not destroy a newer file.
            guard !fileManager.fileExists(atPath: result.sourceURL.path) else {
                failures.append(
                    FileOperationResult(
                        sourceURL: result.sourceURL,
                        status: .failed,
                        errorCode: ErrorCode.itemChanged.rawValue,
                        message: LocalizationKey.cleanupFailureItemChanged.localized,
                        sizeInBytes: result.sizeInBytes,
                        category: result.category
                    )
                )
                continue
            }
            do {
                try fileManager.moveItem(at: destination, to: result.sourceURL)
                restored.append(result.sourceURL)
            } catch {
                let code = Self.classify(error, at: result.sourceURL)
                failures.append(
                    FileOperationResult(
                        sourceURL: result.sourceURL,
                        status: .failed,
                        errorCode: code.rawValue,
                        message: Self.message(for: error, code: code),
                        sizeInBytes: result.sizeInBytes,
                        category: result.category
                    )
                )
            }
        }
        logger.info("Restored a batch (restored=\(restored.count, privacy: .public) failed=\(failures.count, privacy: .public))")
        return RestoreReport(restored: restored, failures: failures)
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
    ///
    /// The path decides one case that the error cannot: a refused move of an
    /// application bundle is the App Management gate rather than a folder
    /// permission, and the two are lifted by different switches.
    static func classify(_ error: Error, at url: URL? = nil) -> ErrorCode {
        let code = classifyWithoutPath(error)
        guard code == .permissionDenied || code == .systemRestricted else { return code }
        if let url, isApplicationBundle(url) { return .appManagementRequired }
        return code
    }

    /// True when the path names an application bundle (`…/Name.app`).
    ///
    /// The trailing component is what matters: a bundle can sit in
    /// `/Applications`, in `~/Applications`, on a mounted volume, or inside a
    /// DMG staged for installation, and the gate follows the bundle rather than
    /// one directory.
    static func isApplicationBundle(_ url: URL) -> Bool {
        url.standardizedFileURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    /// A system error stated in the terms a bug report needs.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "\(nsError.domain)/\(nsError.code)"
        if let posix = posixCode(of: nsError) { text += " errno=\(posix)" }
        return text
    }

    /// The POSIX errno inside a Foundation error, when it carries one.
    ///
    /// `FileManager` reports a POSIX refusal as `NSCocoaErrorDomain` and keeps
    /// the real errno in `NSUnderlyingErrorKey`, so reading only the top-level
    /// code would conflate `EACCES` with `EPERM`.
    private static func posixCode(of error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(of: underlying)
        }
        return nil
    }

    private static func classifyWithoutPath(_ error: Error) -> ErrorCode {
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
