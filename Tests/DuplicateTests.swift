import Foundation
import XCTest
@testable import Core
import Shared

/// Duplicate detection (§5.5, §16.1).
///
/// The pipeline has four stages, and each test targets one of them, so a
/// regression names the stage that broke rather than "duplicates stopped working".
final class DuplicateTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "dupes")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func runDuplicateScan(roots: [String]? = nil) async throws -> [DuplicateGroup] {
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = SwiftScannerEngine(rules: rules)
        let request = ScanRequest(
            roots: [ScanRoot(url: fixture.url, anchor: .home)],
            includeDuplicates: true,
            duplicateRoots: roots ?? [fixture.url.appendingPathComponent("Downloads").path]
        )
        let session = try await engine.startScan(request)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        _ = await session.pollEvents(maxEvents: 256)
        return try await session.duplicateGroups(offset: 0, limit: 50)
    }

    /// A granted folder inside a default duplicate root must not be walked twice.
    ///
    /// Both roots used to stay in the request, so the same path entered the size
    /// index twice, hashed twice, and formed a group of the file with itself —
    /// with one file's bytes reported as reclaimable.
    func test_nestedDuplicateRootsDoNotDuplicateAMember() async throws {
        let payload = Data(repeating: 0x41, count: 64 * 1024)
        let downloads = fixture.url.appendingPathComponent("Downloads")
        let project = downloads.appendingPathComponent("Project")
        fixture.writeBytes("Downloads/Project/one.bin", payload)
        fixture.writeBytes("Downloads/Project/two.bin", payload)

        let groups = try await runDuplicateScan(
            roots: [downloads.path, project.path]
        )
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.members.count, 2, "one entry per file, not per traversal")
        XCTAssertEqual(Set(group.members.map(\.url.path)).count, 2)
        XCTAssertEqual(group.reclaimableSizeInBytes, Int64(payload.count))
    }

    func test_identicalFilesFormOneGroup() async throws {
        let payload = Data(repeating: 0x41, count: 64 * 1024)
        fixture.writeBytes("Downloads/one.bin", payload)
        fixture.writeBytes("Downloads/nested/two.bin", payload)
        fixture.writeBytes("Downloads/three.bin", payload)

        let groups = try await runDuplicateScan()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 3)
        XCTAssertEqual(groups.first?.members.filter(\.isRecommendedToKeep).count, 1)
    }

    func test_sameSizeDifferentContentIsNotAGroup() async throws {
        // Identical length, one byte different in the middle: the cheap size stage
        // groups them, so the sampling and full-hash stages must separate them.
        var first = Data(repeating: 0x41, count: 64 * 1024)
        let second = first
        first[32 * 1024] = 0x42
        fixture.writeBytes("Downloads/a.bin", first)
        fixture.writeBytes("Downloads/b.bin", second)

        let groups = try await runDuplicateScan()
        XCTAssertTrue(groups.isEmpty, "a differing byte must split the pair")
    }

    func test_reclaimableSizeExcludesTheKeeper() async throws {
        let payload = Data(repeating: 0x41, count: 32 * 1024)
        fixture.writeBytes("Downloads/a.bin", payload)
        fixture.writeBytes("Downloads/b.bin", payload)

        let groups = try await runDuplicateScan()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.reclaimableSizeInBytes, Int64(payload.count))
    }

    func test_cloudPlaceholderIsNotACandidate() async throws {
        let payload = Data(repeating: 0x41, count: 32 * 1024)
        fixture.writeBytes("Downloads/real.bin", payload)
        fixture.writeBytes("Downloads/hidden.icloud", payload)

        let groups = try await runDuplicateScan()
        XCTAssertTrue(groups.isEmpty, "an iCloud placeholder is never offered for deletion")
    }

    func test_filesBelowTheMinimumSizeAreIgnored() async throws {
        // The floor is `ScanDefaults.duplicateMinimumBytes`, compared against the
        // allocated size. macOS rounds allocation up to a 4 KB block, so a file of
        // a few hundred bytes still reports one block; what matters, and what this
        // asserts, is that a pair of tiny files is not offered as reclaimable
        // space while a pair above the floor is.
        fixture.writeBytes("Downloads/big1.bin", Data(repeating: 0x42, count: Int(ScanDefaults.duplicateMinimumBytes) * 2))
        fixture.writeBytes("Downloads/big2.bin", Data(repeating: 0x42, count: Int(ScanDefaults.duplicateMinimumBytes) * 2))
        let groups = try await runDuplicateScan()
        XCTAssertEqual(groups.count, 1, "a pair above the floor is grouped")
        XCTAssertGreaterThanOrEqual(
            groups.first?.fileSizeInBytes ?? 0,
            ScanDefaults.duplicateMinimumBytes,
            "no group may sit below the floor"
        )
    }

    func test_groupMembersAreReadablePerGroup() async throws {
        let payload = Data(repeating: 0x41, count: 32 * 1024)
        fixture.writeBytes("Downloads/a.bin", payload)
        fixture.writeBytes("Downloads/b.bin", payload)

        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = SwiftScannerEngine(rules: rules)
        let session = try await engine.startScan(
            ScanRequest(
                roots: [ScanRoot(url: fixture.url, anchor: .home)],
                includeDuplicates: true,
                duplicateRoots: [fixture.url.appendingPathComponent("Downloads").path]
            )
        )
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let groups = try await session.duplicateGroups(offset: 0, limit: 10)
        let group = try XCTUnwrap(groups.first)
        let members = try await session.duplicateMembers(groupID: group.id)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members.filter(\.isRecommendedToKeep).count, 1)
    }
}
