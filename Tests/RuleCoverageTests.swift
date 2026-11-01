import Foundation
import XCTest
@testable import Core
import Shared

/// The coverage audit's arithmetic (§5.6 diagnostics).
///
/// The scan itself is the scanner's — `RuleCoverageAnalyzer.run()` is one scan
/// grouped by rule — so what is tested here is the part with the counting in it:
/// every enabled rule appears, rows are grouped and summed, an item from a
/// strategy that is not a rule is ignored, and a large folder nothing claims is
/// reported with its size.
final class RuleCoverageTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!
    private let home = URL(fileURLWithPath: "/Users/example")

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "coverage")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeRules() -> RuleEngine {
        RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
    }

    private func makeAnalyzer() -> RuleCoverageAnalyzer {
        RuleCoverageAnalyzer(
            rules: makeRules(),
            request: ScanRequest(
                homeDirectory: fixture.url,
                roots: [ScanRoot(url: fixture.url, anchor: .home)],
                includeDuplicates: false
            )
        )
    }

    private func summary(
        _ relative: String,
        ruleID: String,
        bytes: Int64,
        files: Int = 1,
        category: CleanupCategory = .applicationCache
    ) -> CleanupItemSummary {
        CleanupItemSummary(
            id: Int64.random(in: 0...Int64.max),
            url: fixture.url.appendingPathComponent(relative),
            displayName: (relative as NSString).lastPathComponent,
            parentPath: fixture.url.appendingPathComponent(relative).deletingLastPathComponent().path,
            category: category,
            risk: category == .applicationCache ? .safe : .review,
            sizeInBytes: bytes,
            fileCount: files,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: ruleID
        )
    }

    /// A rule that found nothing is still a row: that is the whole point of the
    /// page — a rule nobody exercises is a claim nobody checks.
    func test_everyEnabledRuleIsARowEvenWhenItFoundNothing() {
        let report = makeAnalyzer().report(from: [])
        let enabled = makeRules().rules.filter(\.isEnabled)

        XCTAssertEqual(report.rows.count, enabled.count)
        XCTAssertEqual(Set(report.rows.map(\.ruleID)), Set(enabled.map(\.id)))
        XCTAssertEqual(report.idleRows.count, enabled.count)
        XCTAssertEqual(report.totalItems, 0)
        XCTAssertEqual(report.totalBytes, 0)
    }

    /// Rows are grouped by the strategy that produced them, and a strategy outside
    /// the table keeps its own row.
    ///
    /// The residue scans are code rather than rules, and this report used to drop
    /// their rows: the page then said "no rule reaches this" about a home whose
    /// residue the scan had just found, and both residue claims — a private
    /// container and a shared one — were missing from the one page that lists what
    /// the scan produces. They appear now, marked `isSynthesized`, and the bytes
    /// are still not mixed into a rule that had nothing to do with them.
    func test_aStrategyThatIsNotARuleGetsItsOwnRow() {
        let report = makeAnalyzer().report(from: [
            summary("Library/Caches/com.a", ruleID: "user-cache", bytes: 100, files: 3),
            summary("Library/Caches/com.b", ruleID: "user-cache", bytes: 200, files: 2),
            summary("Library/Logs/app/old.log", ruleID: "user-logs", bytes: 50),
            summary(
                "Library/Group Containers/group.com.gone",
                ruleID: "app-residue-group-containers",
                bytes: 999,
                category: .groupContainerResidue
            ),
        ])

        let cache = report.rows.first { $0.ruleID == "user-cache" }
        XCTAssertEqual(cache?.itemCount, 2)
        XCTAssertEqual(cache?.totalBytes, 300, "a rule's bytes are its own")
        XCTAssertEqual(cache?.fileCount, 5)
        XCTAssertEqual(cache?.isSynthesized, false)

        let shared = report.rows.first { $0.ruleID == "app-residue-group-containers" }
        XCTAssertEqual(shared?.itemCount, 1)
        XCTAssertEqual(shared?.totalBytes, 999)
        XCTAssertEqual(shared?.category, .groupContainerResidue)
        XCTAssertEqual(shared?.risk, .review)
        XCTAssertEqual(shared?.isSynthesized, true, "the row says it came from a scan, not a rule")

        XCTAssertEqual(report.totalItems, 4, "every row is counted once")
        XCTAssertEqual(report.totalBytes, 1349)
    }

    /// Two residue claims stay two rows: the page never merges a private container
    /// with a shared one.
    func test_theTwoResidueClaimsAreSeparateRows() {
        let report = makeAnalyzer().report(from: [
            summary(
                "Library/Containers/com.gone",
                ruleID: "app-residue",
                bytes: 10,
                category: .applicationResidue
            ),
            summary(
                "Library/Group Containers/group.com.gone",
                ruleID: "app-residue-group-containers",
                bytes: 20,
                category: .groupContainerResidue
            ),
        ])

        let rows = report.rows.filter(\.isSynthesized)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.category)), [.applicationResidue, .groupContainerResidue])
    }

    /// A large folder no rule reaches is reported, and one that holds an item is
    /// not: `Application Support` sits above the caches the rules offer, so it
    /// counts as reached.
    func test_aFolderNoRuleReachesIsReportedWithItsSize() {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        fixture.write("Library/Huawei/Sdk/blob.bin", bytes: 8192)
        fixture.write("Library/Application Support/discord/Cache/blob.bin", bytes: 2048)

        let report = makeAnalyzer().report(from: [
            summary("Library/Caches/com.example.app", ruleID: "user-cache", bytes: 4096),
            summary(
                "Library/Application Support/discord/Cache",
                ruleID: "app-support-caches",
                bytes: 2048
            ),
        ])

        let names = Set(report.uncovered.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("Huawei"), "a subtree no rule claims is reported")
        XCTAssertFalse(names.contains("Caches"), "a folder holding a rule's item is covered")
        XCTAssertFalse(
            names.contains("Application Support"),
            "an ancestor of a rule's item is reached, not uncovered"
        )
        let huawei = report.uncovered.first { $0.url.lastPathComponent == "Huawei" }
        XCTAssertGreaterThan(huawei?.bytes ?? 0, 0, "the row states what the folder occupies")
    }

    /// A directory the residue scanner reads is never offered as "uncovered".
    ///
    /// It used to be: `~/Library/Group Containers` holds no rule item and no
    /// residue item on a machine whose containers are all live, so the page listed
    /// it and offered a rule draft — for a container folder, which `RuleDraft`
    /// refuses. The page told the user nothing looks there when the scan reads it
    /// every run, and the action it offered could not be taken.
    func test_aDirectoryABuiltInScannerReadsIsNotReportedAsUncovered() {
        fixture.write("Library/Group Containers/group.com.vendor.notes/store.db", bytes: 4096)
        fixture.write("Library/Huawei/Sdk/blob.bin", bytes: 8192)

        let report = makeAnalyzer().report(from: [])

        let names = Set(report.uncovered.map(\.url.lastPathComponent))
        XCTAssertFalse(
            names.contains("Group Containers"),
            "the residue scan reads this directory, whatever it finds today"
        )
        XCTAssertTrue(names.contains("Huawei"), "and a directory nothing reads is still listed")
    }

    /// The report's totals are the rows' totals, so the page cannot state a
    /// different number from the list beneath it.
    func test_totalsAreTheSumOfTheRows() {
        let report = makeAnalyzer().report(from: [
            summary("Library/Caches/com.a", ruleID: "user-cache", bytes: 1234),
            summary("Library/Logs/app/old.log", ruleID: "user-logs", bytes: 4321),
        ])
        XCTAssertEqual(report.totalBytes, report.rows.reduce(0) { $0 + $1.totalBytes })
        XCTAssertEqual(report.totalItems, report.rows.reduce(0) { $0 + $1.itemCount })
    }
}
