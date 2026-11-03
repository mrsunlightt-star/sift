import Foundation
import XCTest
@testable import Core

/// The App Management gate, and what this build is allowed to claim about it.
///
/// The failure this covers: an uninstall moved 180 KB of residue, left a 2 GB
/// application in `/Applications`, and offered Full Disk Access — a switch that
/// cannot lift the refusal, because moving another developer's bundle is App
/// Management. The page now asks before the batch runs, and the answer has to be
/// either the system's or nothing at all.
final class AppManagementTests: XCTestCase, @unchecked Sendable {
    /// Only an explicit denial becomes a banner.
    ///
    /// `TCCAccessPreflight` answers `unknown`/`denied`/`allowed` as 0/1/2, and a
    /// value this build does not recognise is not a denial: telling a user who
    /// already turned the switch on that they have not is worse than staying
    /// quiet, and the probe reads a private framework that can change shape.
    func test_onlyADenialBecomesABanner() {
        XCTAssertEqual(AppManagementStatus.from(preflight: 2), .granted)
        XCTAssertEqual(AppManagementStatus.from(preflight: 1), .denied)
        XCTAssertEqual(AppManagementStatus.from(preflight: 0), .unknown)
        XCTAssertEqual(AppManagementStatus.from(preflight: 3), .unknown)
        XCTAssertEqual(AppManagementStatus.from(preflight: -1), .unknown)
        XCTAssertEqual(AppManagementStatus.from(preflight: nil), .unknown)
    }

    /// The probe either gives one of the three values or gives nothing.
    ///
    /// Asserted as a domain rather than as a value: the answer depends on this
    /// Mac's privacy settings, and a test that pinned it would fail on the next
    /// machine instead of catching a regression.
    func test_theProbeAnswersWithinItsDomain() {
        guard let raw = AppManagementProbe.preflight(service: AppManagementProbe.service) else {
            return // No framework or no symbol: "no answer" is a correct answer.
        }
        XCTAssertTrue((0...3).contains(raw), "a preflight value outside the enum is not a verdict: \(raw)")
    }

    /// A real move outranks the probe, and an unknown never erases either.
    func test_aMoveTeachesTheStatusAndOutranksTheProbe() async {
        let permissions = PermissionsService()

        await permissions.recordAppManagement(.denied)
        let denied = await permissions.appManagementStatus()
        XCTAssertEqual(denied, .denied, "a refusal naming App Management is the system's own answer")

        await permissions.recordAppManagement(.granted)
        let granted = await permissions.appManagementStatus()
        XCTAssertEqual(granted, .granted, "a bundle that moved proves the gate is open")

        await permissions.recordAppManagement(.unknown)
        let afterUnknown = await permissions.appManagementStatus()
        XCTAssertEqual(afterUnknown, .granted, "asking again without an answer does not undo a proven grant")
    }

    /// A failed row for an application bundle carries the remedy that lifts it.
    ///
    /// End to end through the two pieces the page reads: the error code the
    /// classifier produces, and the action the table offers for it.
    func test_theBundleRefusalOffersAppManagementAndNotFullDiskAccess() {
        let refusal = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let code = FileOperationService.classify(refusal, at: URL(fileURLWithPath: "/Applications/CapCut.app"))
        XCTAssertEqual(code, .appManagementRequired)
        XCTAssertEqual(code.suggestedAction, .openAppManagement)
        XCTAssertNotEqual(code.suggestedAction, .openSystemSettings, "Full Disk Access cannot lift this gate")
    }
}
