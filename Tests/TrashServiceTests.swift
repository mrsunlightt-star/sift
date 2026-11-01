import Foundation
import XCTest
@testable import Core
import Shared

/// Emptying the Trash (§9.1).
///
/// This is the only permanent removal in the product, so the tests state what it
/// refuses as carefully as what it removes. Every test runs in dry-run mode: the
/// suite must never empty a real Trash, and the dry run exercises the whole path
/// including the path check.
final class TrashServiceTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "trash")
        // The bin exists for most tests; the ones that care create it themselves.
        try? FileManager.default.createDirectory(
            at: fixture.url.appendingPathComponent(".Trash"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeService(isDryRun: Bool = true) -> TrashService {
        TrashService(homeDirectory: fixture.url, isDryRun: isDryRun)
    }

    /// The bin's contents are measured the way the scanner measures them, so the
    /// number the confirmation states is the number the row showed.
    func test_inspectReportsEveryEntryAndTheTotal() async {
        fixture.write(".Trash/old.bin", bytes: 8192)
        fixture.write(".Trash/folder/inside.bin", bytes: 4096)
        try? FileManager.default.createDirectory(
            at: fixture.url.appendingPathComponent(".Trash/empty"),
            withIntermediateDirectories: true
        )

        let snapshot = await makeService().inspect()

        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(
            snapshot.entries.map(\.url.lastPathComponent).sorted(),
            ["empty", "folder", "old.bin"]
        )
        let folder = snapshot.entries.first { $0.url.lastPathComponent == "folder" }
        XCTAssertEqual(folder?.isDirectory, true)
        XCTAssertEqual(folder?.fileCount, 1)
        XCTAssertEqual(
            folder?.bytes,
            4096,
            "a directory is measured through its files, not by its own size"
        )
        XCTAssertEqual(
            snapshot.totalBytes,
            snapshot.entries.reduce(0) { $0 + $1.bytes },
            "the total is the sum of the entries the user was shown"
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    /// A bin that does not exist is empty, not an error.
    func test_aMissingBinIsEmpty() async {
        try? FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".Trash"))
        let snapshot = await makeService().inspect()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalBytes, 0)
    }

    /// What the confirmation described is what goes.
    ///
    /// The snapshot is passed back rather than re-read: an entry created while
    /// the confirmation was open must survive, and everything the user saw must
    /// be removed.
    func test_emptyRemovesExactlyTheSnapshotItWasGiven() async {
        fixture.write(".Trash/old.bin", bytes: 4096)
        let service = makeService()
        let snapshot = await service.inspect()
        XCTAssertEqual(snapshot.count, 1)

        // Added after the confirmation: not part of the batch.
        fixture.write(".Trash/appeared.bin", bytes: 1024)

        let outcome = await service.empty(snapshot)
        let simulated = await service.simulatedOperations()
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(
            simulated.map(\.lastPathComponent),
            ["old.bin"],
            "the entry the user confirmed is the entry that is removed"
        )
    }

    /// A snapshot naming a path outside the bin is refused, not removed.
    ///
    /// Nothing in the product builds such a snapshot, which is why the check is
    /// here: the service takes a value, and a value can be assembled by hand.
    func test_anEntryOutsideTheBinIsRefused() async {
        fixture.write("Documents/keep.bin", bytes: 4096)
        let outside = fixture.url.appendingPathComponent("Documents/keep.bin")
        let snapshot = TrashService.Snapshot(
            entries: [
                TrashService.Entry(url: outside, isDirectory: false, bytes: 4096, fileCount: 1)
            ],
            totalBytes: 4096
        )

        let service = makeService()
        let outcome = await service.empty(snapshot)

        XCTAssertEqual(outcome.removedCount, 0)
        let simulated = await service.simulatedOperations()
        XCTAssertFalse(outcome.isComplete, "an entry that could not be removed is reported")
        XCTAssertTrue(
            simulated.isEmpty,
            "the service never acts on a path outside the bin"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "and the file it named is untouched"
        )
    }

    /// An entry that is already gone is not a failure: the user's goal for it is
    /// met, and reporting it as a problem would leave the page with a warning
    /// nobody can act on.
    func test_anEntryThatVanishedIsNotReportedAsAFailure() async {
        fixture.write(".Trash/old.bin", bytes: 4096)
        let service = makeService()
        let snapshot = await service.inspect()
        try? FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".Trash/old.bin"))

        let outcome = await service.empty(snapshot)

        XCTAssertEqual(outcome.removedCount, 0)
        XCTAssertTrue(outcome.isComplete)
    }

    /// A symlink in the bin removes the link, never its target.
    ///
    /// `removeItem` unlinks the entry itself, which is what makes this safe: the
    /// file behind the link is not in the Trash and must survive.
    func test_emptyRemovesTheLinkAndNotItsTarget() async {
        let target = fixture.write("Documents/keep.bin", bytes: 4096)
        try? FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent(".Trash/link"),
            withDestinationURL: target
        )

        let service = makeService()
        let snapshot = await service.inspect()
        let outcome = await service.empty(snapshot)

        let simulated = await service.simulatedOperations()
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertEqual(simulated.map(\.lastPathComponent), ["link"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path),
            "the link's target is outside the bin and is never touched"
        )
    }
}
