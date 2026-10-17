import Foundation
import PDFKit
import XCTest
@testable import Core
import Shared

/// Reports and PDF export (§5.7, §16.1).
final class ReportTests: XCTestCase {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "report")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeReport(entries: Int = 5) -> CleanupReport {
        CleanupReport(
            operation: .junkCleanup,
            appVersion: "0.1.0",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            scannedLocationCount: 4,
            scannedFileCount: 120,
            categories: ["applicationCache", "logs"],
            movedCount: 120,
            movedBytes: 12_400_000,
            skippedCount: 3,
            failedCount: 1,
            entries: (0..<entries).map { index in
                CleanupReport.Entry(
                    displayName: "file\(index).bin",
                    category: "applicationCache",
                    sizeInBytes: 1024,
                    status: OperationStatus.movedToTrash.rawValue,
                    errorCode: nil
                )
            }
        )
    }

    func test_reportCarriesCountsAndSizes() {
        let report = makeReport()
        XCTAssertEqual(report.movedCount, 120)
        XCTAssertEqual(report.movedBytes, 12_400_000)
        XCTAssertEqual(report.operation, .junkCleanup)
    }

    func test_localCopyIsWrittenBeforeExport() async throws {
        let service = ReportService(supportDirectory: fixture.url)
        let url = try await service.storeLocally(makeReport())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let stored = await service.storedReports()
        XCTAssertFalse(stored.isEmpty)
    }

    func test_localCopyContainsNoDirectoryPaths() async throws {
        let service = ReportService(supportDirectory: fixture.url)
        let report = makeReport()
        let url = try await service.storeLocally(report)
        let contents = try String(contentsOf: url, encoding: .utf8)

        // The report names files but never the directories they live in (§13.2).
        XCTAssertFalse(contents.contains("/Users/"))
        XCTAssertFalse(contents.contains("/Library/"))
        XCTAssertTrue(contents.contains("file0.bin"))
    }

    func test_pdfRendersADocumentWithALongTable() async {
        let service = ReportService(supportDirectory: fixture.url)
        let pdf = await service.renderPDF(makeReport(entries: 200), title: "Cleanup report")
        XCTAssertGreaterThan(pdf.count, 1000)
        XCTAssertEqual(pdf.prefix(5), Data("%PDF-".utf8))
    }

    func test_pdfStatesTheScanScopeAndFileCountSeparately() async {
        let service = ReportService(supportDirectory: fixture.url)
        let report = makeReport(entries: 2)
        XCTAssertEqual(report.scannedLocationCount, 4, "the fixture states four locations")
        XCTAssertEqual(report.scannedFileCount, 120, "the fixture states 120 files")
        let pdf = await service.renderPDF(report, title: "Scope")
        let text = PDFDocument(data: pdf)?.string ?? ""
        // The scope line used to be given the file count twice, so the PDF
        // reported "42 locations, 42 files" for every cleanup.
        let expected = LocalizationKey.reportScopeDetail.localized(
            report.scannedLocationCount,
            report.scannedFileCount
        )
        XCTAssertFalse(text.isEmpty, "the PDF carries extractable text")
        XCTAssertTrue(
            text.contains(expected),
            "the PDF states \"\(expected)\" (count=\(text.count), extracted: \(text.prefix(600)))"
        )
    }

    func test_pdfRendersWithNoEntries() async {
        let service = ReportService(supportDirectory: fixture.url)
        let pdf = await service.renderPDF(makeReport(entries: 0), title: "Empty report")
        XCTAssertGreaterThan(pdf.count, 500)
    }

    func test_pdfRendersInEveryShippedLanguage() async {
        // The renderer resolves its labels through the catalog, so a language that
        // is missing a key would produce a report with a raw identifier in it.
        let service = ReportService(supportDirectory: fixture.url)
        for language in ["en", "zh-hans", "ko", "ru", "es", "ja", "fr", "de"] {
            let pdf = await service.renderPDF(makeReport(entries: 3), title: language)
            XCTAssertGreaterThan(pdf.count, 500, "\(language) must render")
        }
    }

    func test_exportedPDFLandsWhereAsked() async throws {
        let service = ReportService(supportDirectory: fixture.url)
        let destination = fixture.url.appendingPathComponent("export.pdf")
        try await service.exportPDF(makeReport(), to: destination, title: "Report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data.prefix(5), Data("%PDF-".utf8))
    }
}
