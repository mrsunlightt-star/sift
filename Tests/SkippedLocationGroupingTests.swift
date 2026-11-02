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

    /// A POSIX refusal and a TCC refusal are different claims.
    ///
    /// `EACCES` is a directory whose mode bits say who may read it, so no grant
    /// made to this account opens it; `EPERM` is what macOS answers a TCC
    /// refusal with, and Full Disk Access is the grant that lifts it. The card
    /// keys its title, its settings button and its sentence off the difference.
    func test_aSystemRestrictedLocationIsNotSomethingToGrant() {
        let restricted = location("/var/spool/postfix/private", code: "systemRestricted")

        XCTAssertFalse(restricted.needsFullDiskAccess)
        XCTAssertFalse(restricted.isActionable)
        XCTAssertEqual(restricted.reasonKey, .scanSkippedReasonSystemRestricted)
        XCTAssertNotEqual(
            restricted.reasonKey,
            .scanSkippedReasonPermissionDenied,
            "an administrator-only directory must not read as a missing grant"
        )
    }

    func test_aPermissionDenialStaysActionable() {
        let denied = location("~/Library/Application Support/com.apple.TCC")

        XCTAssertTrue(denied.needsFullDiskAccess)
        XCTAssertTrue(denied.isActionable)
    }

    func test_aProtectedLocationIsPolicyNotPermission() {
        let protected = location("~/Documents/tax", code: "protectedLocation")

        XCTAssertFalse(protected.isActionable)
        XCTAssertTrue(protected.isProtectedByPolicy)
    }

    func test_theWalkerSplitsTheTwoDenials() {
        let path = URL(fileURLWithPath: "/var/spool/postfix")

        let posix = FileWalker.skip(
            for: path,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        )
        XCTAssertEqual(posix.code, .systemRestricted)
        XCTAssertFalse(posix.needsFullDiskAccess)

        let tcc = FileWalker.skip(
            for: path,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        )
        XCTAssertEqual(tcc.code, .permissionDenied)
        XCTAssertTrue(tcc.needsFullDiskAccess)
    }

    /// Foundation wraps the real errno in `NSUnderlyingErrorKey`; reading only
    /// the outer Cocoa code is how every refusal used to pass for a grant.
    func test_aWrappedPosixDenialIsClassifiedFromItsCause() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        let skip = FileWalker.skip(for: URL(fileURLWithPath: "/var/install"), error: wrapped)

        XCTAssertEqual(skip.code, .systemRestricted)
        XCTAssertFalse(skip.needsFullDiskAccess)
    }

    /// Groups a grant could still change come first, and the card says so.
    func test_actionableGroupsAreReportedSeparatelyFromSystemOnes() {
        let groups = SkippedLocation.groupedByTopLevelDirectory([
            location("/var/spool/postfix/private", code: "systemRestricted"),
            location("/var/spool/postfix/public", code: "systemRestricted"),
            location("~/Library/Caches/a"),
        ])

        XCTAssertEqual(groups.filter(\.hasActionableLocations).map(\.label), ["~/Library"])
        XCTAssertEqual(
            groups.filter { !$0.hasActionableLocations }.map(\.label),
            ["/var"]
        )
    }
}
