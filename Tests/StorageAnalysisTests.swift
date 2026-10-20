import Foundation
import XCTest
@testable import Core
import Shared

/// Storage analysis scope and display (§5.4).
final class StorageAnalysisTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "storage")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeAnalyzer() -> StorageAnalyzer {
        StorageAnalyzer(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        )
    }

    func test_ignoredPathsAreNotTraversedOrCounted() async throws {
        fixture.write("keep/data.bin", bytes: 4096)
        let ignored = fixture.write("skip/data.bin", bytes: 8192)

        let analysis = try await makeAnalyzer().analyze(
            roots: [ScanRoot(url: fixture.url, anchor: .home)],
            ignoredPaths: [ignored.deletingLastPathComponent().path]
        )

        XCTAssertEqual(analysis.scannedFileCount, 1, "the ignored directory is out of scope")
        XCTAssertEqual(analysis.scannedByteCount, 4096)
        XCTAssertFalse(
            analysis.topFiles.contains { $0.url.path.contains("/skip/") },
            "the ignored location is not listed either"
        )
        XCTAssertEqual(
            analysis.categories.reduce(0) { $0 + $1.fileCount },
            1,
            "only the file that was actually visited is counted"
        )
    }

    func test_anIgnoredScanRootIsNotAnalysed() async throws {
        // The ignored location can be a root itself when a granted folder is
        // later excluded from Settings.
        let ignored = fixture.directory("skip")
        fixture.write("skip/data.bin", bytes: 8192)
        let analysis = try await makeAnalyzer().analyze(
            roots: [ScanRoot(url: ignored, anchor: .authorized)],
            ignoredPaths: [ignored.path]
        )
        XCTAssertEqual(analysis.scannedFileCount, 0)
        XCTAssertEqual(analysis.scannedByteCount, 0)
    }

    func test_excludedApplicationDataIsNotAnalysed() async throws {        fixture.write("Library/Caches/CloudKit/large.bin", bytes: 8192)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)

        let analysis = try await makeAnalyzer().analyze(
            roots: [ScanRoot(url: fixture.url, anchor: .home)]
        )

        XCTAssertEqual(analysis.scannedFileCount, 1)
        XCTAssertEqual(analysis.scannedByteCount, 4096)
    }

    func test_nestedRootsAreNotCountedTwice() async throws {
        fixture.write("Downloads/a.bin", bytes: 4096)

        let analysis = try await makeAnalyzer().analyze(
            roots: [
                ScanRoot(url: fixture.url, anchor: .home),
                ScanRoot(url: fixture.url.appendingPathComponent("Downloads"), anchor: .authorized),
            ]
        )

        XCTAssertEqual(analysis.scannedFileCount, 1, "the nested root is the same file")
        XCTAssertEqual(analysis.scannedByteCount, 4096)
    }

    /// Protected user content is deliberately out of scope, not unreadable.
    func test_protectedContentDoesNotMakeTheMeasurementLookIncomplete() async throws {
        fixture.write("Documents/taxes.pdf", bytes: 4096)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)

        let analysis = try await makeAnalyzer().analyze(
            roots: [ScanRoot(url: fixture.url, anchor: .home)]
        )

        XCTAssertEqual(analysis.scannedFileCount, 1)
        XCTAssertEqual(analysis.skippedCount, 0, "a protected folder is not a read failure")
    }

    private func analysis(
        scannedFiles: Int,
        skippedCount: Int = 0,
        isAggregated: Bool = false
    ) -> StorageAnalysis {
        StorageAnalysis(
            mountPoint: "/",
            volumeName: "Test",
            totalBytes: 1000,
            freeBytes: 400,
            usedBytes: 600,
            categories: [],
            topFiles: [],
            topDirectories: [],
            scannedFileCount: scannedFiles,
            scannedByteCount: 4096,
            skippedCount: skippedCount,
            isAggregated: isAggregated
        )
    }

    /// A failed run is not an empty disk.
    ///
    /// The previous result and its timestamp stay; only the run outcome says the
    /// new measurement did not happen. Replacing the analysis with `.empty` made
    /// a failed run indistinguishable from a volume that held nothing.
    func test_aFailedRunKeepsTheLastGoodResultAndItsTimestamp() async {
        let model = await MainActor.run { StorageAnalysisModel() }
        let started = await model.begin()
        XCTAssertNotNil(started)
        await model.finish(analysis: analysis(scannedFiles: 3), report: .empty)
        let stamp = await model.lastAnalyzedAt
        let completed = await model.runOutcome
        XCTAssertEqual(completed, .completed(partial: false))
        XCTAssertNotNil(stamp)

        let retry = await model.begin()
        XCTAssertNotNil(retry)
        let cleared = await model.runOutcome
        XCTAssertNil(cleared, "a retry clears the previous verdict")
        let failure = StorageAnalysisFailure(code: .permissionDenied, message: "no access")
        await model.recordFailure(failure)

        let scanned = await model.analysis.scannedFileCount
        let stampAfter = await model.lastAnalyzedAt
        let outcome = await model.runOutcome
        let running = await model.isAnalyzing
        XCTAssertEqual(scanned, 3, "the last good result stays on screen")
        XCTAssertEqual(stampAfter, stamp, "a failed run must not look like a completed one")
        XCTAssertEqual(outcome, .failed(failure))
        XCTAssertFalse(running)
    }

    func test_aRunThatSkippedFoldersIsReportedAsPartial() async {
        let model = await MainActor.run { StorageAnalysisModel() }
        _ = await model.begin()
        await model.finish(analysis: analysis(scannedFiles: 2, skippedCount: 1), report: .empty)
        let outcome = await model.runOutcome
        XCTAssertEqual(outcome, .completed(partial: true))
    }

    func test_cancellationIsItsOwnOutcome() async {
        let model = await MainActor.run { StorageAnalysisModel() }
        _ = await model.begin()
        await model.recordCancellation()

        let outcome = await model.runOutcome
        let running = await model.isAnalyzing
        let stamp = await model.lastAnalyzedAt
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(running)
        XCTAssertNil(stamp, "a cancelled run produced no result")
    }

    func test_everyFileTypeHasItsOwnTitle() {
        let identifiers = [
            "images", "video", "audio", "documents", "archives", "code", "data", "other",
        ]
        let titles = identifiers.map(StorageAnalyzer.title(for:))
        XCTAssertEqual(
            Set(titles).count,
            identifiers.count,
            "a category row must say what it holds, not repeat the section header: \(titles)"
        )
        XCTAssertFalse(titles.contains(LocalizationKey.storageByType.localized))
    }
}
