import Foundation
import XCTest
@testable import Core
import Shared

/// Selection identity and the scan-root policy (§5.2, §5.4, §16.1).
///
/// These cover the two defects found in review: a random identity per row meant a
/// checked checkbox never entered the cleanup set, and a measure-only root still
/// produced cleanup candidates.
final class SelectionTests: XCTestCase {
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
            return items
        }

        let cleanable = try await scan(isCleanable: true)
        let measureOnly = try await scan(isCleanable: false)
        XCTAssertFalse(cleanable.isEmpty)
        XCTAssertTrue(measureOnly.isEmpty, "a measure-only root must not offer cleanup candidates")
    }
}
