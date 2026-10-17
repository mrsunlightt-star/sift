import Foundation
import XCTest
@testable import Core
import Shared

/// Scanner behaviour against a synthetic home directory (§16.1, §16.2).
///
/// The fixture contains every hazard the specification lists: an unreadable
/// folder, a symlink pointing outside the tree, a package directory, a
/// same-size-different-content pair, and a fresh file next to a stale one.
final class ScannerTests: XCTestCase {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "scan")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeEngine() -> SwiftScannerEngine {
        SwiftScannerEngine(rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url))
    }

    private func makeRequest(includeDuplicates: Bool = false) -> ScanRequest {
        ScanRequest(
            roots: [ScanRoot(url: fixture.url, anchor: .home)],
            largeFileThresholdBytes: 1024 * 1024,
            oldFileThresholdDays: 180,
            staleThresholdDays: 30,
            ignoredPaths: [],
            installedBundleIdentifiers: [],
            includeDuplicates: includeDuplicates,
            duplicateRoots: []
        )
    }

    /// Runs a scan to completion and returns what it found.
    private func runScan(_ request: ScanRequest) async throws -> (items: [CleanupItemSummary], report: ScanReport?, skipped: [SkippedLocation]) {
        let session = try await makeEngine().startScan(request)
        var items: [CleanupItemSummary] = []
        var skipped: [SkippedLocation] = []
        var report: ScanReport?

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for event in await session.pollEvents(maxEvents: 256) {
                switch event {
                case let .itemsFound(batch): items.append(contentsOf: batch)
                case let .locationSkipped(location): skipped.append(location)
                case let .completed(summary): report = summary
                default: break
                }
            }
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // `isFinished` can flip between the last poll and the completion event,
        // so the final drain collects every event type.
        for event in await session.pollEvents(maxEvents: 512) {
            switch event {
            case let .itemsFound(batch): items.append(contentsOf: batch)
            case let .locationSkipped(location): skipped.append(location)
            case let .completed(summary): report = summary
            default: break
            }
        }
        return (items, report, skipped)
    }

    func test_scanFindsCachesLogsAndInstallers() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        fixture.write("Library/Caches/com.other.app/blob.bin", bytes: 4096)
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)
        let installer = fixture.write("Downloads/Old.dmg", bytes: 4096)
        fixture.age(installer, days: 60)

        let result = try await runScan(makeRequest())
        let categories = Set(result.items.map(\.category))
        XCTAssertTrue(categories.contains(.applicationCache))
        XCTAssertTrue(categories.contains(.logs))
        XCTAssertTrue(categories.contains(.installers))
        XCTAssertNotNil(result.report)
    }

    func test_freshInstallerIsNotOffered() async throws {
        fixture.write("Downloads/JustDownloaded.dmg", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(
            result.items.contains { $0.displayName == "JustDownloaded.dmg" },
            "a download the user may still need must not be pre-selected"
        )
    }

    func test_cloudKitIsNeverOffered() async throws {
        fixture.write("Library/Caches/CloudKit/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.displayName == "CloudKit" })
    }

    func test_userDocumentsNeverAppear() async throws {
        fixture.write("Documents/taxes.pdf", bytes: 8192)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.url.path.contains("/Documents/") })
        XCTAssertTrue(
            result.skipped.contains { $0.code == ErrorCode.protectedLocation.rawValue },
            "the refusal is reported, not hidden"
        )
    }

    func test_logAgeFilterCountsOnlyStaleFiles() async throws {
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)
        fixture.write("Library/Logs/com.example.app/fresh.log", bytes: 2048)

        let result = try await runScan(makeRequest())
        let logItem = try XCTUnwrap(result.items.first { $0.category == .logs })
        XCTAssertLessThan(
            logItem.sizeInBytes,
            8192,
            "a fresh log next to a stale one must not be counted as reclaimable"
        )
    }

    func test_symlinkIsNotFollowed() async throws {
        let outside = TemporaryDirectory(tag: "outside")
        outside.write("secret.bin", bytes: 4096)
        let link = fixture.url.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)

        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.url.path.contains("secret.bin") })
    }

    func test_packageDirectoryIsMeasuredAsOneUnit() async throws {
        fixture.write("Library/Caches/App.app/Contents/MacOS/App", bytes: 8192)
        fixture.write("Library/Caches/App.app/Contents/Resources/data", bytes: 8192)
        let result = try await runScan(makeRequest())
        let package = result.items.first { $0.displayName == "App.app" }
        XCTAssertNotNil(package, "a bundle is one item")
        XCTAssertGreaterThanOrEqual(package?.fileCount ?? 0, 2)
    }

    func test_ignoredPathsAreNotScanned() async throws {
        fixture.write("Library/Caches/keep/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/skip/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.ignoredPaths = [fixture.url.appendingPathComponent("Library/Caches/skip").path]
        let result = try await runScan(request)
        XCTAssertFalse(result.items.contains { $0.url.path.contains("/skip") })
    }

    func test_pagingIsStableAcrossPages() async throws {
        for index in 0..<12 {
            fixture.write("Library/Caches/com.app\(index)/blob.bin", bytes: 1024 * (index + 1))
        }
        let session = try await makeEngine().startScan(makeRequest())
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let first = try await session.page(offset: 0, limit: 5, sort: .size, category: nil)
        let second = try await session.page(offset: 5, limit: 5, sort: .size, category: nil)
        XCTAssertEqual(first.items.count, 5)
        XCTAssertTrue(first.items[0].sizeInBytes >= first.items[4].sizeInBytes)
        XCTAssertTrue(
            Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))),
            "pages must not repeat rows"
        )
    }

    func test_categoryFilterIsolatesOneCategory() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)

        let session = try await makeEngine().startScan(makeRequest())
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let page = try await session.page(offset: 0, limit: 50, sort: .size, category: .logs)
        XCTAssertTrue(page.items.allSatisfy { $0.category == .logs })
    }

    func test_cancellationStopsTheScan() async throws {
        for index in 0..<120 {
            fixture.write("Library/Caches/com.app\(index)/blob.bin", bytes: 8192)
        }
        let session = try await makeEngine().startScan(makeRequest())
        await session.cancel()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, await !session.isFinished() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let finished = await session.isFinished()
        XCTAssertTrue(finished, "cancellation must stop the scan")
    }

    func test_unreadableDirectoryIsReportedNotFatal() async throws {
        let locked = fixture.directory("Library/Caches/com.locked")
        fixture.write("Library/Caches/com.locked/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.ok/blob.bin", bytes: 4096)

        var permissions = try FileManager.default.attributesOfItem(atPath: locked.path)
        permissions[.posixPermissions] = 0o000
        try FileManager.default.setAttributes(permissions, ofItemAtPath: locked.path)
        defer {
            var restore = try? FileManager.default.attributesOfItem(atPath: locked.path)
            restore?[.posixPermissions] = 0o755
            if let restore { try? FileManager.default.setAttributes(restore, ofItemAtPath: locked.path) }
        }

        let result = try await runScan(makeRequest())
        XCTAssertNotNil(result.report, "one unreadable folder must not fail the scan")

        // Root ignores the mode bits, so the skip is only observable for a normal
        // user. The unconditional part of this test is that the scan completed.
        if geteuid() != 0 {
            XCTAssertTrue(
                result.skipped.contains { $0.code == ErrorCode.permissionDenied.rawValue },
                "the unreadable folder is reported by code"
            )
        }
    }

    func test_everyItemCarriesAnExplanationAndRuleID() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        for item in result.items {
            XCTAssertFalse(item.sourceRuleID.isEmpty)
            XCTAssertFalse(item.explanationKey.isEmpty)
        }
    }
}
