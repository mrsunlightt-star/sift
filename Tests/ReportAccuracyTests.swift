import Foundation
import XCTest
@testable import Core
import Shared

/// Report counts and categories (§5.7).
final class ReportAccuracyTests: XCTestCase {
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
}
