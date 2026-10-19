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
