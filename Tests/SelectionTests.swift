import Foundation
import XCTest
@testable import Core
import Shared

/// Selection identity and the scan-root policy (§5.2, §5.4, §16.1).
///
/// These cover the two defects found in review: a random identity per row meant a
/// checked checkbox never entered the cleanup set, and a measure-only root still
/// produced cleanup candidates.
final class SelectionTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "selection")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func summary(
        url: URL,
        category: CleanupCategory = .applicationCache,
        risk: CleanupRisk = .safe
    ) -> CleanupItemSummary {
        CleanupItemSummary(
            id: 1,
            url: url,
            displayName: url.lastPathComponent,
            parentPath: url.deletingLastPathComponent().path,
            category: category,
            risk: risk,
            sizeInBytes: 4096,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "user-cache",
            isDirectory: true
        )
    }

    @MainActor
    private func makeModel() -> CleanupModel {
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        return CleanupModel(
            rules: rules,
            operations: FileOperationService(rules: rules, isDryRun: true),
            reports: ReportService(supportDirectory: fixture.url)
        )
    }

    func test_aSummaryConvertsToAStableIdentity() {
        let url = fixture.url.appendingPathComponent("Library/Caches/com.example.app")
        let first = summary(url: url).asCleanupItem()
        let second = summary(url: url).asCleanupItem()
        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
    }

    func test_theSamePathInTwoCategoriesIsTwoTargets() {
        let url = fixture.url.appendingPathComponent("Library/Logs/com.example.app")
        let cache = summary(url: url, category: .applicationCache).asCleanupItem()
        let logs = summary(url: url, category: .logs).asCleanupItem()
        XCTAssertNotEqual(cache.id, logs.id)
    }

    func test_aCheckedRowIsSelectedAfterAReRender() async {
        let url = fixture.url.appendingPathComponent("Library/Caches/com.example.app")
        await MainActor.run {
            let model = makeModel()
            model.setItems([summary(url: url).asCleanupItem()], preselect: false)

            // SwiftUI rebuilds the row on every render; the selection must survive
            // a fresh conversion of the same summary.
            let rendered = summary(url: url).asCleanupItem()
            XCTAssertFalse(model.isSelected(rendered))
            model.setSelected(true, for: rendered)
            XCTAssertTrue(model.isSelected(rendered))
            XCTAssertEqual(model.selectedCount, 1)
        }
    }

    func test_selectingAnItemOutsideTheListAddsIt() async {
        let url = fixture.url.appendingPathComponent("Downloads/copy.bin")
        let item = summary(url: url, category: .duplicateFiles, risk: .review).asCleanupItem()
        await MainActor.run {
            let model = makeModel()
            // Duplicate members are paged separately from the item list, so
            // checking one must still put it in the set the panel reads.
            model.setSelected(true, for: item)
            XCTAssertEqual(model.selectedCount, 1)
            XCTAssertTrue(model.selectedItems.contains { $0.id == item.id })
        }
    }

    func test_protectedItemsCannotBeSelected() async {
        let url = fixture.url.appendingPathComponent("Documents/taxes.pdf")
        let item = summary(url: url, risk: .protected).asCleanupItem()
        await MainActor.run {
            let model = makeModel()
            model.setSelected(true, for: item)
            XCTAssertEqual(model.selectedCount, 0)
        }
    }

    func test_appendingTheSameItemTwiceDoesNotDuplicateIt() async {
        let url = fixture.url.appendingPathComponent("Library/Caches/com.example.app")
        let item = summary(url: url).asCleanupItem()
        await MainActor.run {
            let model = makeModel()
            model.appendItems([item])
            model.appendItems([item])
            XCTAssertEqual(model.items.count, 1)
        }
    }

    func test_aLaterPageFollowsTheScansDefaultSelection() async {
        // The result list pages its rows. A safe item that sorts onto page two
        // starts selected for the same reason one on page one does; reselecting
        // nothing would make the first screenful and the full set disagree.
        let first = summary(url: fixture.url.appendingPathComponent("Library/Caches/com.first"))
            .asCleanupItem()
        let second = summary(url: fixture.url.appendingPathComponent("Library/Caches/com.second"))
            .asCleanupItem()
        await MainActor.run {
            let model = makeModel()
            model.setItems([first], preselect: true)
            model.appendItems([second])
            XCTAssertTrue(model.isSelected(first))
            XCTAssertTrue(model.isSelected(second))
        }
    }

    func test_aReviewPageDoesNotPreselectALaterPage() async {
        // File cleanup loads its items for review. That choice belongs to the
        // scan intent, not to which page happens to be loaded first.
        let first = summary(url: fixture.url.appendingPathComponent("Library/Caches/com.first"))
            .asCleanupItem()
        let second = summary(url: fixture.url.appendingPathComponent("Library/Caches/com.second"))
            .asCleanupItem()
        await MainActor.run {
            let model = makeModel()
            model.setItems([first], preselect: false)
            model.appendItems([second])
            XCTAssertEqual(model.selectedCount, 0)
        }
    }

    func test_aReviewItemRequiresConfirmationEvenWhenTheSettingIsOff() async {
        let url = fixture.directory("Library/Caches/com.example.review")
        let item = summary(url: url, risk: .review).asCleanupItem()
        let model = await MainActor.run { makeModel() }
        await model.setItems([item], preselect: false)
        await model.setSelected(true, for: item)

        let result = await model.prepareCleanup(requiresConfirmation: false)
        let confirming = await model.isConfirming
        XCTAssertEqual(result, .awaitingConfirmation)
        XCTAssertTrue(
            confirming,
            "a review item must be shown even when the user disabled the panel for safe items"
        )
    }

    func test_theApprovedPlanDoesNotFollowTheLiveSelection() async {
        let firstURL = fixture.write("Library/Caches/com.first/blob.bin", bytes: 4096)
        let secondURL = fixture.write("Library/Caches/com.second/blob.bin", bytes: 8192)
        let first = summary(url: firstURL).asCleanupItem()
        let second = summary(url: secondURL).asCleanupItem()

        let model = await MainActor.run { makeModel() }
        await model.setItems([first, second], preselect: true)
        let selected = await model.selectedCount
        XCTAssertEqual(selected, 2)

        _ = await model.prepareCleanup(requiresConfirmation: true)
        let confirming = await model.isConfirming
        let approvedCount = await model.approvedCount
        let approvedItems = await model.approvedByCategory.reduce(0) { $0 + $1.itemCount }
        XCTAssertTrue(confirming)
        XCTAssertEqual(approvedCount, 2)
        XCTAssertEqual(approvedItems, 2)

        // The panel describes what pre-flight approved. Changing the selection
        // underneath it must not change the batch being approved.
        await model.setSelected(false, for: second)
        let selectedAfter = await model.selectedCount
        let approvedAfter = await model.approvedCount
        let totalsAfter = await model.approvedByCategory.reduce(0) { $0 + $1.itemCount }
        XCTAssertEqual(selectedAfter, 1)
        XCTAssertEqual(approvedAfter, 2)
        XCTAssertEqual(totalsAfter, 2, "the approved summary still describes both items")

        await model.executePrepared(operation: .junkCleanup)

        let outcome = await model.outcome
        XCTAssertEqual(
            outcome?.movedCount,
            2,
            "confirm moves the approved plan, not the live selection"
        )
        XCTAssertEqual(
            outcome?.categoryTotals.reduce(0) { $0 + $1.itemCount },
            2,
            "the report describes the same batch the move performed"
        )
    }

    /// One batch must not append the same cleanup target twice.
    func test_aBatchThatRepeatsATargetAppendsOneRow() async {
        let model = await MainActor.run { makeModel() }
        let item = summary(
            url: fixture.url.appendingPathComponent("Library/Caches/com.example.app")
        ).asCleanupItem()

        await MainActor.run { model.appendItems([item, item]) }

        let count = await model.items.count
        XCTAssertEqual(count, 1)
    }

    /// A pre-flight that is already describing a plan is not replaced by a
    /// second request while its panel is open.
    func test_aSecondPrepareDoesNotReplaceTheOpenPlansOperation() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let model = await MainActor.run { makeModel() }
        await MainActor.run {
            model.setItems([summary(url: file).asCleanupItem()])
        }

        let first = await model.prepareCleanup(
            requiresConfirmation: true,
            operation: .junkCleanup
        )
        XCTAssertEqual(first, .awaitingConfirmation)
        let confirming = await model.isConfirming
        XCTAssertTrue(confirming)

        let second = await model.prepareCleanup(
            requiresConfirmation: true,
            operation: .largeFiles
        )
        XCTAssertEqual(second, .nothingToDo, "the open panel's plan is not re-prepared")
        let operation = await model.preparedOperation
        XCTAssertEqual(operation, .junkCleanup, "the plan still names the operation it was built for")
    }

    func test_aMeasureOnlyRootProducesNoCandidates() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        fixture.write("Downloads/huge.bin", bytes: 2 * 1024 * 1024)

        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = SwiftScannerEngine(rules: rules)

        func scan(isCleanable: Bool) async throws -> [CleanupItemSummary] {
            let request = ScanRequest(
                homeDirectory: fixture.url,
                roots: [ScanRoot(url: fixture.url, anchor: .home, isCleanable: isCleanable)],
                largeFileThresholdBytes: 1024 * 1024,
                includeDuplicates: false
            )
            let session = try await engine.startScan(request)
            var items: [CleanupItemSummary] = []
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                for event in await session.pollEvents(maxEvents: 128) {
                    if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
                }
                if await session.isFinished() { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            // `isFinished` can flip between the last poll and the final batch, so
            // one more drain is required.
            for event in await session.pollEvents(maxEvents: 256) {
                if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
            }
            return items
        }

        let cleanable = try await scan(isCleanable: true)
        let measureOnly = try await scan(isCleanable: false)
        XCTAssertFalse(cleanable.isEmpty)
        XCTAssertTrue(measureOnly.isEmpty, "a measure-only root must not offer cleanup candidates")
    }
}
