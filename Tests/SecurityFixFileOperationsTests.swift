import Foundation
import XCTest
@testable import Core
import Shared

/// The file-operation findings of the 2026-11 audit, each one proved rather than
/// asserted in a comment.
///
/// Every service here is a dry run, so no test can move or remove a real file:
/// the dry-run path runs the whole check sequence and records what would have
/// happened, which is exactly what these tests need to see.
final class SecurityFixFileOperationsTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        ScratchPreferences.reset("security-fix")
        fixture = TemporaryDirectory(tag: "security-fix")
    }

    override func tearDown() {
        ScratchPreferences.reset("security-fix")
        fixture = nil
        super.tearDown()
    }

    /// A service whose answer to "is an application running" is an injected empty
    /// list, so nothing here depends on what this Mac has open.
    private func makeOperations() -> FileOperationService {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        return FileOperationService(
            rules: engine,
            isDryRun: true,
            runningTokenProvider: { [] }
        )
    }

    private func item(_ url: URL, risk: CleanupRisk = .review) -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: url.lastPathComponent,
            category: .applicationCache,
            risk: risk,
            sizeInBytes: 4096,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "tests"
        )
    }

    // MARK: - H1

    /// An ancestor replaced by a symbolic link while the loop is suspended is
    /// refused, and the move is never reached.
    ///
    /// The suspension is the window: the two questions only the main actor can
    /// answer are awaited *before* the relocation and identity checks, so a swap
    /// made during those awaits is seen by the checks that follow. The test holds
    /// the loop open at exactly that point and replaces `Library` with a link to a
    /// second tree, which is the substitution `trashItem` would follow: it resolves
    /// a link in any component of the path.
    ///
    /// Two assertions make the ordering the thing under test rather than the
    /// refusal alone. The plan's identity is the one pre-flight read from the
    /// original object, so with the checks running *before* the awaits instead of
    /// after them, both would pass (the path still resolved to itself when they
    /// ran) and the dry run would record a move of the object the link now names.
    /// `simulatedOperationCount()` is therefore 0 only when validation happened
    /// after the swap.
    func test_aRelocatedAncestorIsRefusedAfterTheAwaitedChecks() async {
        let cacheDirectory = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
            .deletingLastPathComponent()
        let foreignMarker = fixture.write("foreign/Caches/com.example.app/marker.bin", bytes: 8192)
        let service = makeOperations()

        let verdict = await service.preflight([FileOperationService.Candidate(item: item(cacheDirectory))])
        XCTAssertEqual(verdict.ready.count, 1, "the fixture cache directory is pre-flightable")
        guard let plan = verdict.makeApprovedPlan(operation: .junkCleanup) else {
            return XCTFail("a pre-flighted item produces an approved plan")
        }

        let library = fixture.url.appendingPathComponent("Library", isDirectory: true)
        let original = fixture.url.appendingPathComponent("Library.real", isDirectory: true)
        let foreign = fixture.url.appendingPathComponent("foreign", isDirectory: true)
        await service.setValidationSuspension {
            // The swap: the written path `Library/Caches/com.example.app` now names
            // the foreign tree, and nothing about the spelling says so.
            try? FileManager.default.moveItem(at: library, to: original)
            try? FileManager.default.createSymbolicLink(at: library, withDestinationURL: foreign)
        }

        let outcome = await service.execute(plan)

        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: library.path),
            "the test replaced the ancestor with a link"
        )
        XCTAssertEqual(outcome.movedCount, 0, "nothing was moved")
        XCTAssertEqual(
            outcome.results.first?.errorCode,
            ErrorCode.itemChanged.rawValue,
            "the item whose path resolves elsewhere is refused as changed"
        )
        let simulated = await service.simulatedOperationCount()
        XCTAssertEqual(
            simulated,
            0,
            "the move was never reached: between the last validation and it there is no suspension point"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignMarker.path),
            "the tree the link points at is untouched"
        )
    }

    // MARK: - M4

    /// A plan assembled by hand is refused when its path is one no rule may offer.
    ///
    /// `ApprovedPlan.init` is internal, but a plan is data: a future seam that
    /// builds one from a stale or hand-written level must not be able to carry a
    /// path the rule table protects. The risk is re-derived at execution time for
    /// exactly that reason — the level on the item is a claim, not a fact.
    func test_aHandBuiltPlanCannotCarryAProtectedItem() async {
        let document = fixture.write("Documents/tax-return.pdf", bytes: 1024)
        let service = makeOperations()
        let forged = item(document)

        // Pre-flight refuses it, which is the first of the three checks the product
        // promises. The hand-built plan below is the case where that check was
        // skipped by the caller rather than satisfied.
        let verdict = await service.preflight([FileOperationService.Candidate(item: forged)])
        XCTAssertTrue(verdict.ready.isEmpty, "pre-flight never approves a protected path")
        XCTAssertNil(
            verdict.makeApprovedPlan(operation: .junkCleanup),
            "a report with nothing ready is not an executable plan"
        )

        guard let identity = FileIdentitySnapshot.of(path: document.path) else {
            return XCTFail("the fixture document has an identity")
        }
        let plan = ApprovedPlan(
            operation: .junkCleanup,
            items: [forged],
            identities: [forged.id: identity],
            categoryTotals: [],
            refusedResults: []
        )

        let outcome = await service.execute(plan)

        XCTAssertEqual(outcome.movedCount, 0, "a protected path is never moved")
        XCTAssertEqual(
            outcome.failedResults.first?.errorCode,
            ErrorCode.protectedLocation.rawValue,
            "the refusal is reported as a protected location"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: document.path),
            "the document is untouched"
        )
    }

    // MARK: - M2

    /// Emptying the Trash is gated like every other destruction.
    ///
    /// The snapshot used here is empty on purpose: the assertion is about the gate,
    /// and an empty snapshot cannot remove anything from this Mac's real Trash even
    /// if the gate were misordered. `AppEnvironment` builds its own `TrashService`
    /// from the real home directory; what is under test is that nothing reaches it.
    @MainActor
    private func makeEnvironment() -> AppEnvironment {
        let defaults = ScratchPreferences.open("security-fix")
        let store = SettingsStore(
            preferences: StringPreferences(defaults: defaults),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-security-fix-\(UUID().uuidString)", isDirectory: true)
        )
        return AppEnvironment(settings: store, entitlementDefaults: defaults)
    }

    func test_emptyTrashIsRefusedWhileAnotherDestructiveOperationOwnsTheSlot() async {
        let environment = await MainActor.run { makeEnvironment() }
        await MainActor.run {
            XCTAssertTrue(environment.beginDestructiveOperation())
        }
        let refused = await environment.emptyTrashGated(.empty)
        await MainActor.run { environment.endDestructiveOperation() }

        guard case .busy = refused else {
            return XCTFail("the bin must not be emptied while a cleanup owns the slot")
        }
        XCTAssertFalse(refused.didExecute)
        XCTAssertEqual(refused.outcome.removedCount, 0)
    }

    /// The free tier cannot empty the Trash: it is the one irreversible removal, so
    /// the paywall appears here as it does at Clean and Uninstall.
    func test_emptyTrashRequiresThePaidTier() async {
        let environment = await MainActor.run { makeEnvironment() }

        let refused = await environment.emptyTrashGated(.empty)

        guard case .purchaseRequired = refused else {
            return XCTFail("the free tier must not remove anything permanently")
        }
        XCTAssertEqual(refused.outcome.removedCount, 0)
        let busy = await MainActor.run { environment.isPerformingFileOperation }
        XCTAssertFalse(busy, "the slot is released when the request is refused")
    }

    // MARK: - M3

    /// A bin that cannot be listed is not an empty one.
    ///
    /// `try?` turned the permission failure into `.empty`, so a Mac without Full
    /// Disk Access was told there was nothing to empty while the space the user
    /// came to reclaim sat in the bin. The listing failure is now its own state,
    /// and the state is the one that carries the guidance.
    func test_anUnreadableBinIsNotReportedAsAnEmptyOne() async {
        let bin = fixture.url.appendingPathComponent(".Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bin.path)
        defer {
            // Restored before teardown, or the fixture directory cannot be removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }

        let snapshot = await TrashService(homeDirectory: fixture.url, isDryRun: true).inspect()

        XCTAssertTrue(snapshot.isUnreadable, "an unlistable bin is a state of its own")
        XCTAssertEqual(snapshot.unreadable, TrashService.UnreadableReason.needsFullDiskAccess)
        XCTAssertNotEqual(
            snapshot,
            TrashService.Snapshot.empty,
            "an unreadable bin must not answer the same way as a missing one"
        )
        XCTAssertEqual(snapshot.unreadable?.titleKey, LocalizationKey.permissionFullDiskAccess)
        XCTAssertEqual(snapshot.unreadable?.offersSettingsAction, true)
    }


    // MARK: - M15

    /// Removing an app-owned directory refuses a parent that is a symbolic link.
    ///
    /// `FileManager.removeItem` does not follow a link in the final component, but
    /// it does follow one in an ancestor: with `Application Support/Sift` re-pointed
    /// at another tree, "delete the reports this app wrote" becomes a recursive
    /// delete of everything in that tree. The app-owned case is not exercisable
    /// through the report service alone — a refusal reached through a recursive walk
    /// would have to be arranged around the fixture's home — so the helper is tested
    /// where it is decided.
    func test_ownedLocationRemovalRefusesASymbolicLinkParent() throws {
        let support = fixture.directory("Application Support/Sift")
        let reports = fixture.directory("Application Support/Sift/Reports")
        try Data(repeating: 0x41, count: 64).write(to: reports.appendingPathComponent("report.json"))

        // The app's own directory is removed when the path still names it.
        let logs = fixture.directory("Application Support/Sift/Logs")
        try OwnedLocationRemoval.remove(at: logs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))

        // Now the ancestor is re-pointed: `Sift` becomes a link to a foreign tree
        // that happens to have a `Reports` directory in it.
        let foreign = fixture.directory("foreign-tree/Reports")
        let foreignFile = foreign.appendingPathComponent("user-file.txt")
        try Data(repeating: 0x42, count: 32).write(to: foreignFile)
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: fixture.url.appendingPathComponent("foreign-tree"))

        do {
            try OwnedLocationRemoval.remove(at: support.appendingPathComponent("Reports"))
            XCTFail("a symbolic link in the parent must be refused")
        } catch let refusal as OwnedLocationRemoval.Refusal {
            XCTAssertEqual(refusal, .ancestorIsSymbolicLink)
        } catch {
            XCTFail("the refusal is reported as its own error, not as a system one")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignFile.path),
            "the tree the link points at is untouched"
        )
    }

    /// A link one level above the entry's own parent is refused too.
    ///
    /// The history and the engine index sit below the app's own directory: with
    /// `Application Support/Sift` re-pointed, the entry's parent
    /// (`…/Sift/Index`) reads as an ordinary directory whether or not `…/Sift`
    /// is a link — the shape an immediate-parent check lets through.
    func test_ownedLocationRemovalRefusesASymbolicLinkAboveTheParent() throws {
        let support = fixture.directory("Application Support/Sift")
        let index = fixture.directory("Application Support/Sift/Index")
        let entry = index.appendingPathComponent("session.sqlite")
        try Data(repeating: 0x43, count: 16).write(to: entry)

        let foreign = fixture.directory("foreign-tree/Index")
        let foreignFile = foreign.appendingPathComponent("user.sqlite")
        try Data(repeating: 0x44, count: 16).write(to: foreignFile)

        // The real store is moved aside rather than deleted, so the entry it
        // held keeps existing under its own name while `Sift` becomes a link
        // to a foreign tree.
        try FileManager.default.moveItem(
            at: support,
            to: fixture.url.appendingPathComponent("Application Support/Sift-real")
        )
        try FileManager.default.createSymbolicLink(
            at: support,
            withDestinationURL: fixture.url.appendingPathComponent("foreign-tree")
        )

        do {
            try OwnedLocationRemoval.remove(
                at: support.appendingPathComponent("Index").appendingPathComponent("session.sqlite")
            )
            XCTFail("a link above the entry's parent must be refused")
        } catch let refusal as OwnedLocationRemoval.Refusal {
            XCTAssertEqual(refusal, .ancestorIsSymbolicLink)
        } catch {
            XCTFail("the refusal is reported as its own error, not as a system one")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreignFile.path),
            "the tree the link points at is untouched"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.url.appendingPathComponent("Application Support/Sift-real/Index/session.sqlite").path
            ),
            "the entry behind the link chain is untouched"
        )
    }

    // MARK: - M1

    /// A queue that never empties still settles the run.
    ///
    /// The pump used to drain the event queue until a poll came back empty. A
    /// poisoned mutex inside the core makes `poll_events` synthesise a fresh event
    /// on every call without consuming anything, so "until empty" is a loop with no
    /// exit: the run never settles, and the single-flight gate and the destructive
    /// slot stay claimed for the life of the process. The drain is now bounded by a
    /// batch count, a deadline and the failure verdict itself.
    ///
    /// The assertion is on the outcome, not on the elapsed time: a run with no
    /// verdict is reported as failed. A regression shows up as `failure == nil`
    /// after the poll below gives up, never as a hung suite.
    func test_aQueueThatNeverEmptiesStillSettlesTheRun() async {
        let session = PoisonedScanSession(synthesisesFailure: false)
        let model = await makeModel(PoisonedScannerEngine(session: session))

        await model.start(makeRequest())
        let failure = await waitForAFailure(model)

        XCTAssertNotNil(failure, "a drain that cannot empty must still give the run a verdict")
        let phase = await model.phase
        XCTAssertEqual(phase, .failed)
    }

    /// A `failed` event is terminal: the pump stops instead of draining a queue
    /// that keeps answering.
    ///
    /// Counting the polls is what makes this observable at all. A verdict alone is
    /// not enough — `apply` records the failure on the first batch, so a run whose
    /// pump never stopped would still report one while spinning behind the page.
    /// The count therefore has to stop growing, and it has to stay near the drain's
    /// batch bound rather than running away.
    func test_aFailedEventEndsTheDrain() async {
        let session = PoisonedScanSession(synthesisesFailure: true)
        let model = await makeModel(PoisonedScannerEngine(session: session))

        await model.start(makeRequest())
        let failure = await waitForAFailure(model)
        XCTAssertEqual(failure?.code, ErrorCode.internalError)

        let afterFailure = await session.pollCount()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let later = await session.pollCount()

        XCTAssertEqual(afterFailure, later, "the pump stopped polling once the verdict was recorded")
        XCTAssertLessThanOrEqual(later, 100, "the drain is bounded, so a poison queue cannot spin")
    }

    @MainActor
    private func makeModel(_ engine: any ScannerEngine) -> ScanModel {
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        return ScanModel(engine: engine, rules: rules)
    }

    private func makeRequest() -> ScanRequest {
        ScanRequest(
            homeDirectory: fixture.url,
            roots: [ScanRoot(url: fixture.url, anchor: .home)],
            includeDuplicates: false
        )
    }

    /// Waits for a verdict without ever hanging the suite on a defect.
    private func waitForAFailure(_ model: ScanModel, timeout: TimeInterval = 15) async -> (code: ErrorCode, message: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let failure = await model.failure { return failure }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await model.failure
    }

    /// `empty(_:)` still removes exactly the snapshot it was given, and the dry-run
    /// path still records it instead of touching the file.
    ///
    /// The reading half of this type changed, so the removal half is stated again
    /// here: a bin whose state is now reported separately must remove the same
    /// entries it always did.
    func test_theDryRunRecordsWhatEmptyingWouldRemove() async {
        fixture.write(".Trash/old.bin", bytes: 8192)
        let service = TrashService(homeDirectory: fixture.url, isDryRun: true)

        let snapshot = await service.inspect()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertFalse(snapshot.isUnreadable)

        let outcome = await service.empty(snapshot)
        XCTAssertEqual(outcome.removedCount, 1)
        let simulated = await service.simulatedOperations()
        XCTAssertEqual(simulated.map(\.lastPathComponent), ["old.bin"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent(".Trash/old.bin").path),
            "a dry run leaves the bin alone"
        )
    }
    // MARK: - H5 / the uninstaller's exemption

    /// The protection list refuses `/Applications`, and the uninstaller is the
    /// one flow allowed through.
    ///
    /// `/Applications` is on the compiled-in list because a *rule* must never
    /// offer an application: the table can see a name and an age, not whether the
    /// thing inside is wanted. Adding it made every uninstall refuse with
    /// `protectedLocation`, because pre-flight serves both flows — this predicate
    /// is the one place that difference lives, so it is proved directly rather
    /// than through a real `/Applications` fixture this process may not create.
    func test_onlyAnUninstallMayLookPastTheApplicationsPrefix() {
        let applications = RuleEngine.ProtectionReason.systemPath("/Applications")
        // The path has to be one the guard accepts, or the flow is refused for a
        // second reason and the predicate under test is masked. `/Applications`
        // itself is not a bundle, so the predicate test asks the same question the
        // service asks and states the answer it must get — which is the wiring —
        // and the bundle-shaped cases are the guarded ones below.
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertFalse(
            FileOperationService.permitsApplicationMove(applications, intent: .junkCleanup, url: bundle)
        )
        XCTAssertFalse(
            FileOperationService.permitsApplicationMove(applications, intent: .largeFiles, url: bundle)
        )
        XCTAssertEqual(
            FileOperationService.permitsApplicationMove(applications, intent: .uninstall, url: bundle),
            ApplicationBundleGuard.isUninstallable(bundle),
            "under `/Applications` an uninstall is allowed exactly when the guard is"
        )

        // And the reason is necessary but not sufficient: the same bundle-shaped
        // path under any other protected prefix stays refused, because the
        // exception is keyed on the reason rather than on the spelling.
        for reason: RuleEngine.ProtectionReason in [
            .userContent("Documents"),
            .secrets("Library/Keychains"),
            .photosLibrary,
            .systemPath("/System"),
            .systemPath("/Volumes"),
        ] {
            XCTAssertFalse(
                FileOperationService.permitsApplicationMove(reason, intent: .uninstall, url: bundle),
                "\(reason) must stay refused for an uninstall"
            )
            XCTAssertNil(
                FileOperationService.applicationMoveRefusal(reason, intent: .uninstall, url: bundle),
                "\(reason) is not the lifted prefix, so there is no application-move refusal to report"
            )
        }
    }

    /// A real application bundle under `/Applications` still passes pre-flight
    /// when the flow is an uninstall.
    ///
    /// The predicate above is the decision; this is the wiring. Without the
    /// exemption every uninstall would have refused with `protectedLocation`
    /// once `/Applications` joined the protection list, and no existing test
    /// would have noticed — the uninstaller's own tests stop at the plan, never
    /// at the file-operation gate. The bundle is only stat'ed: the service is a
    /// dry run, so nothing is moved.
    func test_aRealApplicationBundleIsPreflightableForAnUninstallOnly() async {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        let bundles = apps.filter { $0.hasSuffix(".app") }
            .sorted()
            .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
        // The exemption is for a bundle the guard accepts, so the machine's first
        // `.app` is not necessarily one: Apple's own applications and anything
        // that is really a link must be refused, which is the point of the guard.
        guard let bundle = bundles.first(where: ApplicationBundleGuard.isUninstallable) else {
            // Nothing to prove on a machine with no third-party applications; the
            // predicate test above still covers the decision.
            return
        }
        let bundleName = bundle.lastPathComponent
        let service = makeOperations()
        let candidate = FileOperationService.Candidate(item: item(bundle))

        let uninstallVerdict = await service.preflight([candidate], intent: CleanupOperationName.uninstall)
        XCTAssertEqual(
            uninstallVerdict.ready.count,
            1,
            "\(bundleName) must be approvable by the uninstaller"
        )

        let cleanupVerdict = await service.preflight([candidate], intent: CleanupOperationName.junkCleanup)
        XCTAssertEqual(cleanupVerdict.ready.count, 0, "a cleanup may never move an application")
        XCTAssertEqual(cleanupVerdict.protected.count, 1)
    }

    /// The exemption is not the prefix; it is the bundle.
    ///
    /// Everything else spelled under `/Applications` reaches pre-flight with the
    /// same protection reason — a folder inside a bundle, a vendor subfolder, a
    /// path that does not exist — and none of them is an application the user
    /// picked. Before the guard, `permitsApplicationMove` answered "yes" for all
    /// of them on an uninstall, because it only ever looked at the reason.
    func test_onlyABundleIsLiftedFromTheApplicationsPrefix() async {
        let service = makeOperations()
        let contents = URL(fileURLWithPath: "/Applications/SiftGuardFixture.app/Contents")
        let vendorFolder = URL(fileURLWithPath: "/Applications/SiftVendorShelf")
        let missing = URL(fileURLWithPath: "/Applications/SiftGuardFixture.app")

        for url in [contents, vendorFolder, missing] {
            let verdict = await service.preflight(
                [FileOperationService.Candidate(item: item(url))],
                intent: CleanupOperationName.uninstall
            )
            XCTAssertEqual(verdict.ready.count, 0, "\(url.lastPathComponent) is not a bundle to uninstall")
            XCTAssertEqual(verdict.protected.count, 1, "\(url.path) stays on the protection list")
        }
    }

    /// And the flow really is what pre-flight consults: user content stays
    /// refused even when the operation is an uninstall.
    func test_userContentIsRefusedEvenForAnUninstall() async {
        let document = fixture.write("Documents/thesis.pdf", bytes: 128)
        let service = makeOperations()
        let verdict = await service.preflight(
            [FileOperationService.Candidate(item: item(document))],
            intent: CleanupOperationName.uninstall
        )
        XCTAssertEqual(verdict.ready.count, 0, "user content stays refused")
        XCTAssertEqual(verdict.protected.count, 1)
    }
}

/// An engine whose event queue never empties.
///
/// It reproduces the shape a poisoned mutex inside the core produces:
/// `isFinished()` answers true, and every `poll_events` call returns another event
/// without ever consuming the queue. With `synthesisesFailure` the event is a
/// `failed` verdict; without it the events are ordinary progress updates that will
/// never end. The poll count is exposed because "the pump stopped" is otherwise
/// not observable from outside.
private struct PoisonedScannerEngine: ScannerEngine {
    let session: PoisonedScanSession
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession { session }
}

private actor PoisonedScanSession: ScanSession {
    nonisolated let id = "poisoned-session"
    private let synthesisesFailure: Bool
    private var polls = 0

    init(synthesisesFailure: Bool) {
        self.synthesisesFailure = synthesisesFailure
    }

    func pollCount() -> Int { polls }

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        polls += 1
        // Yields the main actor periodically. Without it a drain with no exit
        // starves every other task on it, and a regression would wedge the suite
        // instead of failing the two tests that claim to detect it — the same way
        // it wedges the product, which is no use as a signal in CI.
        if polls % 64 == 0 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return synthesisesFailure
            ? [.failed(code: .internalError, message: "queue unavailable")]
            : [.phaseChanged(.preparing)]
    }

    func isFinished() async -> Bool { true }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }
    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }
    func skippedLocations() async -> [SkippedLocation] { [] }
    func cancel() async {}
}
