import Foundation
import XCTest
@testable import Core

/// Grouping the scan's residue rows into one entry per application.
///
/// The rows are the scan's output and are not in question here; what is being
/// pinned is the arithmetic that turns them into a decision — which spellings
/// count as the same application, which do not, and what the page shows above
/// them. Every case below is one that would otherwise be a silent mis-grouping:
/// a helper filed under its own name, or two unrelated applications merged
/// because their identifiers start alike.
final class ResidueGroupingTests: XCTestCase {
    private func item(
        _ path: String,
        bundleID: String?,
        category: CleanupCategory = .applicationResidue,
        bytes: Int64 = 1024,
        files: Int = 1,
        modified: Date? = nil
    ) -> CleanupItem {
        CleanupItem(
            url: URL(fileURLWithPath: "/Users/example/\(path)"),
            displayName: (path as NSString).lastPathComponent,
            category: category,
            risk: .review,
            sizeInBytes: bytes,
            fileCount: files,
            explanationKey: "cleanup.explanation.residue",
            relatedBundleID: bundleID,
            sourceRuleID: "app-residue",
            modifiedAt: modified,
            isDirectory: true
        )
    }

    /// The reason this type exists: five locations, one application.
    func testLocationsOfOneApplicationBecomeOneGroup() throws {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app", bytes: 300),
            item("Library/Containers/com.example.app", bundleID: "com.example.app", bytes: 500),
            item("Library/Preferences/com.example.app.plist", bundleID: "com.example.app", bytes: 4),
            item(
                "Library/Logs/com.example.app",
                bundleID: "com.example.app",
                bytes: 100,
                files: 7
            ),
        ])

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.bundleIdentifier, "com.example.app")
        XCTAssertEqual(group.totalBytes, 904)
        XCTAssertEqual(group.fileCount, 10)
        XCTAssertEqual(group.locationCount, 4)
        // Largest first, so the row a user is most likely to act on is on top.
        XCTAssertEqual(group.items.map(\.sizeInBytes), [500, 300, 100, 4])
        // `app` is a shape, not a name.
        XCTAssertEqual(group.displayName, "example")
    }

    /// A helper is the same application's data, and the boundary rule is what
    /// says so. Filing `…​.helper` separately would offer the user two rows for
    /// one decision, and the smaller one would look unrelated.
    func testAnIdentifierThatContinuesAnotherIsMergedIntoIt() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app"),
            item("Library/Caches/com.example.app.helper", bundleID: "com.example.app.helper"),
            item("Library/Caches/com.example.app-updater", bundleID: "com.example.app-updater"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(groups.first?.locationCount, 3)
    }

    /// The boundary rule cuts the other way too: sharing a prefix is not
    /// sharing an owner. This is the exact pair the scanners' own test uses.
    func testAPrefixThatDoesNotEndOnABoundaryIsNotMerged() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app"),
            item("Library/Caches/com.example.appleby", bundleID: "com.example.appleby"),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(
            Set(groups.map(\.bundleIdentifier)),
            ["com.example.app", "com.example.appleby"]
        )
    }

    /// A group container is a different category and stays its own row inside
    /// the group — the page states that the container may be shared, which is
    /// only true while the category survives grouping.
    func testAGroupContainerKeepsItsCategoryInsideTheGroup() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app"),
            item(
                "Library/Group Containers/TEAMID.com.example.app",
                bundleID: "com.example.app",
                category: .groupContainerResidue
            ),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.categories, [.applicationResidue, .groupContainerResidue])
        XCTAssertEqual(groups.first?.hasGroupContainer, true)
    }

    /// A full scan's result set is what the leftovers page receives when the user
    /// ran one already. A cache is not a leftover, and grouping it as one would
    /// put an installed application's live data under an uninstalled
    /// application's heading.
    func testRowsInOtherCategoriesAreNotGrouped() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app"),
            item(
                "Library/Caches/com.installed.app",
                bundleID: "com.installed.app",
                category: .applicationCache,
                bytes: 9_000
            ),
            item("Library/Logs/system.log", bundleID: nil, category: .logs),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(groups.first?.totalBytes, 1024)
    }

    /// The engines attach an identifier to every residue row. A row without one
    /// cannot be attributed, and grouping it under a fallback name would be the
    /// guess this feature exists to avoid.
    func testARowWithoutAnIdentifierIsDropped() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/unnamed", bundleID: nil),
            item("Library/Caches/com.example.app", bundleID: "com.example.app"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.locationCount, 1)
    }

    /// The date the page shows is the newest location's, and it is a hint about
    /// how long the files have been there — not a residue decision, which is why
    /// it is reported rather than compared against a threshold here.
    func testTheGroupReportsTheLatestModification() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.example.app", bundleID: "com.example.app", modified: old),
            item("Library/Logs/com.example.app", bundleID: "com.example.app", modified: recent),
        ])

        XCTAssertEqual(groups.first?.latestModified, recent)
    }

    /// Largest first: the page's first row is the one worth acting on.
    func testGroupsAreSortedByTotalSize() {
        let groups = ResidueGrouping.groups(from: [
            item("Library/Caches/com.small.app", bundleID: "com.small.app", bytes: 10),
            item("Library/Caches/com.large.app", bundleID: "com.large.app", bytes: 9_000),
            item("Library/Caches/com.medium.app", bundleID: "com.medium.app", bytes: 500),
        ])

        XCTAssertEqual(
            groups.map(\.bundleIdentifier),
            ["com.large.app", "com.medium.app", "com.small.app"]
        )
    }

    /// An empty result is not an error and has no group to show.
    func testNoResidueProducesNoGroups() {
        XCTAssertTrue(ResidueGrouping.groups(from: []).isEmpty)
    }
}
