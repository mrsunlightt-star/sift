import Foundation
import XCTest
@testable import Core
import Shared

/// File operations (§9, §16.1).
///
/// Every test runs the service in dry-run mode: the suite must never touch a real
/// file, and the dry run exercises the whole path including the pre-flight checks
/// and the execution-time re-validation.
final class FileOperationTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "ops")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeService() -> FileOperationService {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        return FileOperationService(rules: engine, isDryRun: true)
    }

    private func approve(
        _ service: FileOperationService,
        _ items: [CleanupItem],
        operation: CleanupOperationName = .junkCleanup
    ) async -> ApprovedPlan? {
        let verdict = await service.preflight(items.map(FileOperationService.Candidate.init(item:)))
        return verdict.makeApprovedPlan(operation: operation)
    }

    private func item(_ url: URL, size: Int64 = 4096, risk: CleanupRisk = .safe) -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: url.lastPathComponent,
            category: .applicationCache,
            risk: risk,
            sizeInBytes: size,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "tests"
        )
    }

    func test_preflightAcceptsAnOrdinaryCacheItem() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(file))])
        XCTAssertEqual(verdict.ready.count, 1)
        XCTAssertTrue(verdict.protected.isEmpty)
    }

    /// A cache item whose application is running is refused, not moved.
    ///
    /// The scanner already took the row down to `review`, so it was not
    /// pre-selected — but the user may still tick it, and the panel may stay open
    /// while they go and launch the application. The move would succeed and the
    /// directory would come back with the application's next write, which is the
    /// case this refusal exists for.
    func test_preflightRefusesAnItemWhoseApplicationIsRunning() async {
        fixture.write("Library/Caches/com.running.app/blob.bin", bytes: 4096)
        let file = fixture.directory("Library/Caches/com.running.app")
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let service = FileOperationService(
            rules: engine,
            isDryRun: true,
            runningTokenProvider: { ["com.running.app"] }
        )

        let verdict = await service.preflight([
            FileOperationService.Candidate(item: item(file, risk: .review))
        ])

        XCTAssertTrue(verdict.ready.isEmpty, "a running application's cache must not be queued")
        XCTAssertEqual(verdict.skipped.count, 1)
        XCTAssertEqual(verdict.skipped.first?.code, .fileInUse)
    }

    /// The same item is accepted once its application is not running.
    ///
    /// The refusal has to be about the state of the machine, not about the path:
    /// otherwise every cache item becomes uncleanable the moment any application
    /// happens to be running.
    func test_preflightAcceptsTheSameItemWhenTheApplicationIsNotRunning() async {
        fixture.write("Library/Caches/com.running.app/blob.bin", bytes: 4096)
        let file = fixture.directory("Library/Caches/com.running.app")
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let service = FileOperationService(
            rules: engine,
            isDryRun: true,
            runningTokenProvider: { ["com.other.app"] }
        )

        let verdict = await service.preflight([
            FileOperationService.Candidate(item: item(file, risk: .review))
        ])

        XCTAssertEqual(verdict.ready.count, 1)
        XCTAssertTrue(verdict.skipped.isEmpty)
    }

    /// The approved item is the item the user selected, not a five-field copy.
    ///
    /// Rebuilding it during pre-flight used to replace the scanner's explanation
    /// and rule id with placeholders, so the confirmation and the result spoke
    /// about the item in a vocabulary the scan had not used.
    func test_preflightPreservesTheItemsProvenance() async throws {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let original = CleanupItem(
            url: file,
            displayName: file.lastPathComponent,
            category: .applicationCache,
            risk: .safe,
            sizeInBytes: 4096,
            fileCount: 3,
            explanationKey: "cleanup.explanation.cache",
            relatedBundleID: "com.example.app",
            sourceRuleID: "user-cache",
            modifiedAt: modified,
            isDirectory: true
        )

        let verdict = await makeService().preflight([FileOperationService.Candidate(item: original)])
        let ready = try XCTUnwrap(verdict.ready.first)

        XCTAssertEqual(ready.rawExplanationKey, "cleanup.explanation.cache")
        XCTAssertEqual(ready.sourceRuleID, "user-cache")
        XCTAssertEqual(ready.fileCount, 3)
        XCTAssertEqual(ready.relatedBundleID, "com.example.app")
        XCTAssertEqual(ready.modifiedAt, modified)
        XCTAssertTrue(ready.isDirectory)
    }

    /// Pre-flight records the object behind each approved path.
    func test_preflightRecordsTheObjectItApproved() async throws {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let approved = item(file)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: approved)])

        let recorded = try XCTUnwrap(verdict.identities[approved.id])
        XCTAssertEqual(recorded, FileIdentitySnapshot.of(path: file.path))
    }

    /// The same path can name a different object by the time the move runs.
    ///
    /// `trashItem` acts on the path, and the protection list compares paths, so
    /// neither can see a file replaced by something else at the same spelling.
    /// The identity pre-flight approved is the last word.
    func test_theMoveRefusesAnObjectReplacedAtTheSamePath() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let service = makeService()
        let approved = item(file)
        let verdict = await service.preflight([FileOperationService.Candidate(item: approved)])
        XCTAssertEqual(verdict.ready.count, 1)

        // Replace a regular file with a directory at the same path. The path is
        // unchanged and only the object behind it differs.
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)

        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.results.first?.errorCode, ErrorCode.itemChanged.rawValue)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "the replacement must be left alone"
        )
    }

    /// An unchanged object still moves; the identity check refuses only a change.
    func test_theMoveAcceptsTheObjectPreflightApproved() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let service = makeService()
        let approved = item(file)
        let verdict = await service.preflight([FileOperationService.Candidate(item: approved)])

        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
    }

    /// A path re-pointed before the move is refused, at both checks.
    ///
    /// `trashItem` follows a symlink in any component, so an ancestor replaced
    /// by a link turns a cache path into a request to move something else
    /// entirely — and the protection list cannot see it, because the path as
    /// written sits under `Caches`.
    func test_preflightRefusesAPathThatNowResolvesElsewhere() async {
        let elsewhere = fixture.directory("Documents")
        try? Data(repeating: 0x78, count: 4096)
            .write(to: elsewhere.appendingPathComponent("thing.bin"))
        let cacheDirectory = fixture.directory("Library/Caches/com.example.app")
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: elsewhere)

        let item = item(cacheDirectory.appendingPathComponent("thing.bin"))
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item)])
        XCTAssertTrue(verdict.ready.isEmpty, "the item must not be offered")
        XCTAssertEqual(verdict.skipped.count, 1)
        XCTAssertEqual(verdict.skipped.first?.code, .itemChanged)
    }

    func test_theMoveRefusesAPathThatNowResolvesElsewhere() async {
        // The same substitution, but discovered only at the move: the pre-flight
        // check cannot be the last word, because the path can be re-pointed
        // between the confirmation panel and this call.
        let elsewhere = fixture.directory("Documents")
        let victim = elsewhere.appendingPathComponent("thing.bin")
        try? Data(repeating: 0x78, count: 4096).write(to: victim)
        let cacheDirectory = fixture.directory("Library/Caches/com.example.app")
        let cacheFile = cacheDirectory.appendingPathComponent("thing.bin")
        try? Data(repeating: 0x79, count: 4096).write(to: cacheFile)

        let service = makeService()
        let verdict = await service.preflight([FileOperationService.Candidate(item: item(cacheFile))])
        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)

        // Re-point an ancestor after pre-flight. The object at the written path
        // is now the victim under Documents.
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: elsewhere)

        let outcome = await service.execute(plan!)
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.results.first?.errorCode, ErrorCode.itemChanged.rawValue)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victim.path),
            "the item the link points at must be untouched"
        )
    }

    /// And an ordinary item is not refused, whichever spelling its path is in.
    ///
    /// The refusal compares the path as written with the path as resolved, and
    /// `resolvingSymlinksInPath` answers `/var` for a path under `/private/var`.
    /// Without the alias mapping in that comparison every item on a `/var`
    /// spelling would be refused as relocated.
    func test_anOrdinaryItemIsNotRefusedAsRelocated() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(file))])
        XCTAssertEqual(verdict.ready.count, 1)

        XCTAssertEqual(
            RuleEngine.normalize(file.path),
            RuleEngine.normalize(file.resolvingSymlinksInPath().path),
            "the two spellings of one path must compare equal"
        )
        // And the same file written the other way round is still one item.
        let symlink = fixture.url.appendingPathComponent("Library/Caches/link-to-app")
        try? FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.url.appendingPathComponent("Library/Caches/com.example.app")
        )
        let throughLink = await makeService()
            .preflight([FileOperationService.Candidate(item: item(symlink))])
        XCTAssertTrue(
            throughLink.ready.isEmpty,
            "a symlink the user selected is still refused, as it always was"
        )
    }

    /// A scanner can mark an ordinary path `protected`; the operation boundary
    /// must refuse it even though the protection list has no entry for the path.
    func test_preflightRefusesAProtectedRiskOnAnOrdinaryPath() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(file, risk: .protected))
        ])
        XCTAssertTrue(verdict.ready.isEmpty)
        XCTAssertEqual(verdict.protected.count, 1)
        XCTAssertNil(verdict.makeApprovedPlan(operation: .junkCleanup))
    }

    /// A ready item with no identity is not an approvable plan.
    func test_aPlanWithoutIdentityIsNotApproved() {
        let item = item(fixture.url.appendingPathComponent("Library/Caches/com.example.app/blob.bin"))
        let report = PreflightReport(
            ready: [item],
            skipped: [],
            subsumed: [],
            protected: [],
            identities: [:]
        )
        XCTAssertNil(report.makeApprovedPlan(operation: .junkCleanup))
    }

    /// If a plan reaches execution without an identity, the move is refused
    /// instead of falling back to a path-only check.
    func test_executionRefusesAPlanWithoutIdentity() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let approved = item(file)
        let plan = ApprovedPlan(
            operation: .junkCleanup,
            items: [approved],
            identities: [:],
            categoryTotals: [],
            refusedResults: []
        )
        let outcome = await makeService().execute(plan)
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.results.first?.errorCode, ErrorCode.itemChanged.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_preflightRefusesProtectedContent() async {
        let file = fixture.write("Documents/taxes.pdf", bytes: 4096)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(file))])
        XCTAssertTrue(verdict.ready.isEmpty)
        XCTAssertEqual(verdict.protected.count, 1)
    }

    func test_preflightRefusesAContainerPath() async {
        // `~/Library` is scannable but is not a cleanup item: moving it would
        // take every application's data with it.
        let library = fixture.directory("Library")
        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(library, risk: .review)),
        ])
        XCTAssertTrue(verdict.ready.isEmpty)
        XCTAssertEqual(verdict.protected.count, 1)
        XCTAssertNil(verdict.makeApprovedPlan(operation: .junkCleanup))
    }

    /// A `safe` level the rule table no longer backs is lowered, not acted on.
    ///
    /// The scan result can be minutes old and the user's rule file can change
    /// between the scan and the click. Re-deriving the level from the table in
    /// force now is what keeps "only a rule may call an item safe" true without
    /// depending on every producer remembering to say `review`.
    func test_aSafeLevelTheTableDoesNotBackIsLoweredToReview() async {
        let cache = fixture.directory("Library/Caches/com.example.app")
        let unclaimed = fixture.directory("Library/Application Support/com.example.app")

        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(cache, risk: .safe)),
            FileOperationService.Candidate(item: item(unclaimed, risk: .safe)),
        ])

        XCTAssertEqual(verdict.ready.count, 2, "both are still offered")
        let backed = verdict.ready.first { $0.url == cache }
        let lowered = verdict.ready.first { $0.url == unclaimed }
        XCTAssertEqual(backed?.risk, .safe)
        XCTAssertEqual(lowered?.risk, .review, "a level no rule backs arrives unselected")
        XCTAssertEqual(lowered?.isSelectedByDefault, false)
        XCTAssertTrue(lowered?.explanation().isEmpty == false, "the row keeps its sentence")
    }

    /// An item inside an excluded application's data is refused even when it
    /// arrives claiming `safe`: no rule may offer that location at all.
    func test_preflightRefusesALocationNoRuleMayOffer() async {
        let file = fixture.write("Library/Caches/CloudKit/db.bin", bytes: 4096)
        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(file, risk: .safe))
        ])
        XCTAssertTrue(verdict.ready.isEmpty)
        XCTAssertEqual(verdict.protected.count, 1)
    }

    func test_parentAndChildAreNotBothProcessed() async {
        let directory = fixture.directory("Library/Caches/com.example.app")
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(directory)),
            FileOperationService.Candidate(item: item(file)),
        ])
        XCTAssertEqual(verdict.ready.count, 1, "the parent absorbs the child")
        XCTAssertEqual(verdict.subsumed.count, 1)
        XCTAssertEqual(verdict.ready.first?.url, directory)
    }

    func test_missingFileIsSkippedWithTheRightCode() async {
        let missing = fixture.url.appendingPathComponent("Library/Caches/gone.bin")
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(missing))])
        XCTAssertEqual(verdict.skipped.count, 1)
        XCTAssertEqual(verdict.skipped.first?.code, .fileNotFound)
    }

    func test_symlinkIsNeverFollowed() async {
        let link = fixture.url.appendingPathComponent("Library/Caches/link")
        try? FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(link))])
        XCTAssertTrue(verdict.ready.isEmpty)
    }

    func test_executionTimeRecheckBlocksAProtectedPath() async {
        // A plan assembled by another caller must still be refused: the check
        // exists twice on purpose (§13.3).
        let file = fixture.write("Documents/taxes.pdf", bytes: 4096)
        let approved = item(file)
        let identity = FileIdentitySnapshot.of(path: file.path)
        XCTAssertNotNil(identity)
        let report = PreflightReport(
            ready: [approved],
            skipped: [],
            subsumed: [],
            protected: [],
            identities: [approved.id: identity!]
        )
        let plan = report.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await makeService().execute(plan!)
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.failedResults.first?.errorCode, ErrorCode.protectedLocation.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_dryRunMovesNothing() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let service = makeService()
        let plan = await approve(service, [item(file)])
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_releasedBytesCountOnlyWhatMoved() async {
        let cache = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let service = makeService()
        let verdict = await service.preflight([
            FileOperationService.Candidate(item: item(cache, size: 4096)),
            FileOperationService.Candidate(item: item(
                fixture.write("Documents/taxes.pdf", bytes: 8192),
                size: 8192
            )),
        ])
        XCTAssertEqual(verdict.ready.count, 1, "the protected document never enters the plan")
        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)
        XCTAssertEqual(outcome.releasedBytes, 4096)
    }

    func test_pathsWithSpacesAndNonASCIIAreHandled() async {
        let file = fixture.write("Library/Caches/应用 缓存/v1.0 (beta)+t#1.bin", bytes: 512)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(file))])
        XCTAssertEqual(verdict.ready.count, 1)
    }

    func test_errorClassificationMapsToTheProductTable() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(FileOperationService.classify(cocoa), .permissionDenied)

        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        XCTAssertEqual(FileOperationService.classify(posix), .fileInUse)

        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertEqual(FileOperationService.classify(missing), .fileNotFound)
    }

    /// An item pre-flight refused is in the outcome, with its reason.
    ///
    /// `moveToTrash` never sees it, so without this the batch would report only
    /// what it moved and the item the user selected would vanish from the result
    /// without a word.
    func test_aRefusedItemIsReportedInTheOutcomeNotDropped() async {
        let missing = fixture.url.appendingPathComponent("Library/Caches/gone.bin")
        let present = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let service = makeService()

        let verdict = await service.preflight([
            FileOperationService.Candidate(item: item(missing)),
            FileOperationService.Candidate(item: item(present)),
        ])
        XCTAssertEqual(verdict.ready.count, 1)
        XCTAssertEqual(verdict.refusedResults.count, 1, "the pre-flight refusal becomes a result")
        XCTAssertEqual(verdict.refusedResults.first?.errorCode, ErrorCode.fileNotFound.rawValue)

        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)
        XCTAssertEqual(outcome.results.count, 2, "one moved and one refused, both reported")
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(
            outcome.skippedResults.first?.sourceURL,
            missing,
            "the row names the path, so the user can tell which item was left alone"
        )
        XCTAssertEqual(outcome.releasedBytes, 4096, "only what moved counts as released")
    }

    /// A protected item pre-flight refused carries the reason the row shows.
    func test_aProtectedRefusalIsReportedWithItsReason() async {
        let document = fixture.write("Documents/taxes.pdf", bytes: 8192)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(document))])

        XCTAssertTrue(verdict.ready.isEmpty)
        XCTAssertEqual(verdict.refusedResults.count, 1)
        XCTAssertEqual(verdict.refusedResults.first?.errorCode, ErrorCode.protectedLocation.rawValue)
        XCTAssertFalse(
            verdict.refusedResults.first?.message?.isEmpty ?? true,
            "a refusal the user is shown needs a sentence to show"
        )
    }

    /// A child absorbed by a selected directory is not a refusal.
    ///
    /// Its bytes are already part of the directory's total, so reporting it as
    /// one would count the same file twice under a status that reads like a
    /// failure.
    func test_aSubsumedChildIsNotReportedAsRefused() async {
        let directory = fixture.directory("Library/Caches/com.example.app")
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let verdict = await makeService().preflight([
            FileOperationService.Candidate(item: item(directory)),
            FileOperationService.Candidate(item: item(file)),
        ])

        XCTAssertEqual(verdict.subsumed.count, 1)
        XCTAssertTrue(verdict.refusedResults.isEmpty)
    }
}


/// The one test that performs a real move.
///
/// Every other test in this file runs dry, and that is deliberate: a test must
/// never move a user's files. But a dry run never calls
/// `FileManager.trashItem`, so nothing else proves that the production call
/// works, that the resulting location is reported, or that the item really is
/// gone from where it was. This test moves a file out of its own temporary
/// directory and takes it back out of the Trash afterwards.
final class TrashIntegrationTests: XCTestCase, @unchecked Sendable {
    func test_aRealMoveTrashesTheItemAndReportsWhereItWent() async throws {
        let fixture = TemporaryDirectory(tag: "trash-integration")
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        // Not a dry run: this is the production path.
        let service = FileOperationService(rules: rules)
        let item = CleanupItem(
            url: file,
            displayName: file.lastPathComponent,
            category: .applicationCache,
            risk: .safe,
            sizeInBytes: 4096,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "tests"
        )

        let verdict = await service.preflight([FileOperationService.Candidate(item: item)])
        let plan = verdict.makeApprovedPlan(operation: .junkCleanup)
        XCTAssertNotNil(plan)
        let outcome = await service.execute(plan!)

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failedCount, 0, "\(outcome.failedResults.map(\.message))")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "the item must be gone from where it was"
        )
        let trashed = try XCTUnwrap(
            outcome.results.first?.destinationURL,
            "a move has to report where the item went"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashed.path),
            "and the item must be there"
        )

        // Only the fixture this test moved, and only its own copy.
        try? FileManager.default.removeItem(at: trashed)
    }
}
