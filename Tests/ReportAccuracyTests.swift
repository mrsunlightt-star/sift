import Foundation
import XCTest
@testable import Core
import Shared

/// Report counts and categories (§5.7).
final class ReportAccuracyTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "report-accuracy")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func test_countsComeFromTheOutcomeNotFromGuesses() async {
        let moved = FileOperationResult(
            sourceURL: fixture.url.appendingPathComponent("a.bin"),
            status: .movedToTrash,
            sizeInBytes: 100,
            category: .applicationCache
        )
        let skipped = FileOperationResult(
            sourceURL: fixture.url.appendingPathComponent("b.bin"),
            status: .skipped,
            errorCode: ErrorCode.fileNotFound.rawValue,
            sizeInBytes: 50,
            category: .logs
        )
        let failed = FileOperationResult(
            sourceURL: fixture.url.appendingPathComponent("c.bin"),
            status: .failed,
            errorCode: ErrorCode.permissionDenied.rawValue,
            sizeInBytes: 25,
            category: .installers
        )
        let outcome = CleanupOutcome(
            results: [moved, skipped, failed],
            categoryTotals: [
                CategoryTotal(category: .applicationCache, itemCount: 1, totalBytes: 100),
            ],
            startedAt: Date(),
            finishedAt: Date(),
            operationName: .junkCleanup
        )
        let scanReport = ScanReport(
            sessionID: "accuracy",
            startedAt: Date(),
            finishedAt: Date(),
            phase: .ready,
            scannedFileCount: 42,
            scannedByteCount: 4096,
            scannedLocationCount: 2,
            itemCount: 3,
            itemBytes: 175,
            categoryTotals: [],
            duplicateGroupCount: 0,
            duplicateReclaimableBytes: 0,
            skippedLocations: []
        )

        let service = ReportService(supportDirectory: fixture.url)
        let report = await service.makeReport(from: outcome, scanReport: scanReport)

        XCTAssertEqual(report.scannedLocationCount, 2, "the report states the scan scope")
        XCTAssertEqual(report.scannedFileCount, 42)
        XCTAssertEqual(report.skippedCount, 1, "skipped items are counted once")
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.categories, ["applicationCache"])
        XCTAssertEqual(report.entries.count, 3)
        XCTAssertEqual(
            report.entries.first { $0.status == "movedToTrash" }?.category,
            "applicationCache",
            "an entry names the category it came from"
        )
    }

    func test_aReportWithoutAScanStillReportsWhatHappened() async {
        let moved = FileOperationResult(
            sourceURL: fixture.url.appendingPathComponent("a.bin"),
            status: .movedToTrash,
            sizeInBytes: 10,
            category: .temporaryFiles
        )
        let outcome = CleanupOutcome(
            results: [moved],
            categoryTotals: [CategoryTotal(category: .temporaryFiles, itemCount: 1, totalBytes: 10)],
            startedAt: Date(),
            finishedAt: Date(),
            operationName: .junkCleanup
        )
        let service = ReportService(supportDirectory: fixture.url)
        let report = await service.makeReport(from: outcome, scanReport: nil)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertEqual(report.scannedLocationCount, 0)
    }

    /// The result page's title is derived from the outcome, not from the fact
    /// that a page opened.
    ///
    /// The case that produced this test: one 2 GB application refused to move
    /// while 180 KB of residue moved, and the page said "Cleanup finished" above
    /// both. The headline is the assertion the user could not perform.
    func test_theHeadlineStatesWhatHappened() {
        XCTAssertEqual(outcome(moved: 3, failed: 0).headline, .finished)
        XCTAssertEqual(outcome(moved: 1, failed: 1).headline, .partiallyCompleted)
        XCTAssertEqual(outcome(moved: 0, failed: 1).headline, .nothingMoved)
        XCTAssertEqual(outcome(moved: 0, failed: 0).headline, .finished, "a batch nothing was asked of is not a failure")
    }

    /// A stopped batch is still described by what it managed to move.
    func test_aStoppedBatchWithAFailureIsPartial() {
        let stopped = outcome(moved: 2, failed: 1)
        XCTAssertEqual(stopped.headline, .partiallyCompleted)
    }

    /// A retried row is rebuilt from the row itself, and it is still the item
    /// the user selected: same path, same identity, and an application bundle
    /// stays a directory.
    func test_aFailedRowRebuildsTheItemItStandsFor() {
        let bundle = URL(fileURLWithPath: "/Applications/CapCut.app")
        let failed = FileOperationResult(
            sourceURL: bundle,
            status: .failed,
            errorCode: ErrorCode.appManagementRequired.rawValue,
            sizeInBytes: 2_056_216_576,
            category: .applicationResidue
        )
        let item = failed.retryItem
        XCTAssertEqual(item.url, bundle)
        XCTAssertEqual(item.displayName, "CapCut.app")
        XCTAssertEqual(item.category, .applicationResidue)
        XCTAssertEqual(item.sizeInBytes, 2_056_216_576)
        XCTAssertTrue(item.isDirectory, "an application bundle is moved whole")

        let file = FileOperationResult(
            sourceURL: fixture.url.appendingPathComponent("Library/Caches/blob.bin"),
            status: .failed,
            errorCode: ErrorCode.permissionDenied.rawValue,
            sizeInBytes: 128,
            category: nil
        )
        XCTAssertFalse(file.retryItem.isDirectory)
        XCTAssertEqual(file.retryItem.category, .applicationResidue)
    }

    private func outcome(moved: Int, failed: Int) -> CleanupOutcome {
        var results: [FileOperationResult] = []
        for index in 0..<moved {
            results.append(
                FileOperationResult(
                    sourceURL: fixture.url.appendingPathComponent("moved-\(index).bin"),
                    status: .movedToTrash,
                    sizeInBytes: 1024,
                    category: .applicationCache
                )
            )
        }
        for index in 0..<failed {
            results.append(
                FileOperationResult(
                    sourceURL: fixture.url.appendingPathComponent("failed-\(index).app"),
                    status: .failed,
                    errorCode: ErrorCode.appManagementRequired.rawValue,
                    sizeInBytes: 2_056_216_576,
                    category: .applicationResidue
                )
            )
        }
        return CleanupOutcome(
            results: results,
            categoryTotals: [],
            startedAt: Date(),
            finishedAt: Date(),
            operationName: .uninstall
        )
    }

}
