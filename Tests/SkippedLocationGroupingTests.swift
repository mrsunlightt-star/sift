import Foundation
import XCTest
@testable import Core

/// The skipped-location roll-up.
///
/// A scan that cannot read ~/Library reports two dozen children; the grouping
/// is what turns that flat list into one directory the user can grant once.
final class SkippedLocationGroupingTests: XCTestCase {
    private func location(_ path: String, code: String = "permissionDenied") -> SkippedLocation {
        SkippedLocation(
            url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            code: code,
            message: "unreadable",
            needsFullDiskAccess: code == "permissionDenied"
        )
    }

    func test_childrenRollUpUnderTheirTopLevelDirectory() {
        let groups = SkippedLocation.groupedByTopLevelDirectory([
            location("~/Library/Caches/a"),
            location("~/Library/Caches/b"),
            location("~/Library/Application Support/c"),
            location("~/Music"),
        ])

        XCTAssertEqual(groups.map(\.label), ["~/Library", "~/Music"])
        XCTAssertEqual(groups[0].locations.count, 3)
        XCTAssertEqual(groups[1].locations.count, 1)
    }

    func test_absoluteAndHomeRootsGroupSeparately() {
        let groups = SkippedLocation.groupedByTopLevelDirectory([
            location("/Library/Logs/ToDesk"),
            location("~/Library/Caches/a"),
        ])

        // Same size, so the tie breaks on the label, and "/" sorts before "~".
        XCTAssertEqual(groups.map(\.label), ["/Library", "~/Library"])
    }

    func test_largestGroupComesFirst() {
        let groups = SkippedLocation.groupedByTopLevelDirectory([
            location("~/Music"),
            location("~/Library/Caches/a"),
            location("~/Library/Caches/b"),
            location("~/Library/Caches/c"),
            location("/Library/Logs/ToDesk"),
            location("/Library/Logs/Other"),
        ])

        XCTAssertEqual(groups.first?.label, "~/Library")
        XCTAssertEqual(groups.map(\.locations.count), [3, 2, 1])
    }

    func test_aLocationWithoutAURLGroupsUnderItsMessage() {
        let orphan = SkippedLocation(url: nil, code: "partialFailure", message: "unknown", needsFullDiskAccess: false)
        let groups = SkippedLocation.groupedByTopLevelDirectory([orphan])

        XCTAssertEqual(groups.map(\.label), ["unknown"])
    }

    func test_aSharedReasonSurvivesTheRollUpAndAMixedOneDoesNot() {
        let uniform = SkippedLocation.groupedByTopLevelDirectory([
            location("~/Library/Caches/a"),
            location("~/Library/Caches/b"),
        ])
        XCTAssertEqual(uniform.first?.sharedReasonKey, .scanSkippedReasonPermissionDenied)

        let mixed = SkippedLocation.groupedByTopLevelDirectory([
            location("~/Library/Caches/a"),
            location("~/Library/Application Support/b", code: "protectedLocation"),
        ])
        XCTAssertEqual(mixed.first?.label, "~/Library")
        XCTAssertNil(mixed.first?.sharedReasonKey)
    }
}
