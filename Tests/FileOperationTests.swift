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

    func test_preflightRefusesProtectedContent() async {
        let file = fixture.write("Documents/taxes.pdf", bytes: 4096)
        let verdict = await makeService().preflight([FileOperationService.Candidate(item: item(file))])
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
        // Handed straight to execution without pre-flight, the service must still
        // refuse: the check exists twice on purpose (§13.3).
        let file = fixture.write("Documents/taxes.pdf", bytes: 4096)
        let outcome = await makeService().moveToTrash([item(file)], operation: .junkCleanup)
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.failedResults.first?.errorCode, ErrorCode.protectedLocation.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_dryRunMovesNothing() async {
        let file = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let outcome = await makeService().moveToTrash([item(file)], operation: .junkCleanup)
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_releasedBytesCountOnlyWhatMoved() async {
        let cache = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let document = fixture.write("Documents/taxes.pdf", bytes: 8192)
        let outcome = await makeService().moveToTrash(
            [item(cache, size: 4096), item(document, size: 8192)],
            operation: .junkCleanup
        )
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
}
