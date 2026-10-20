import Foundation
import XCTest
@testable import Core
import Shared

/// The composition root's state transitions that cross several services.
final class AppEnvironmentTests: XCTestCase, @unchecked Sendable {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "sift.tests.environment.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    private func makeEnvironment() -> AppEnvironment {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = SettingsStore(
            preferences: StringPreferences(defaults: defaults),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-environment-\(UUID().uuidString)", isDirectory: true)
        )
        return AppEnvironment(settings: store)
    }

    /// The switch is a runtime setting, not a next-launch one.
    func test_togglingUserRulesRebuildsTheScanModel() async {
        let environment = await MainActor.run { makeEnvironment() }
        let before = await environment.scan

        await environment.updateSettings { $0.userRulesEnabled = true }
        let afterEnable = await environment.scan
        XCTAssertFalse(
            afterEnable === before,
            "the new rule table must reach the scanner before the next scan"
        )

        await environment.updateSettings { $0.userRulesEnabled = false }
        let afterDisable = await environment.scan
        XCTAssertFalse(
            afterDisable === afterEnable,
            "turning the rule file off rebuilds the engines too"
        )
    }

    /// Resetting settings must release the grants as well as forget them in the
    /// settings store; otherwise the scan scope keeps reading an old volume.
    func test_resetSettingsReleasesAuthorizedLocations() async throws {
        let environment = await MainActor.run { makeEnvironment() }
        let folder = await MainActor.run {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".sift-reset-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let grant = await environment.authorizeLocation(folder)
        XCTAssertNotNil(grant, "a readable folder inside home is authorisable")
        let grantURL = folder.resolvingSymlinksInPath()
        let request = await environment.makeScanRequest(includeDuplicates: false)
        XCTAssertTrue(
            request.authorizedRoots.contains(grantURL.path),
            "the grant is part of the scan request while it is in force"
        )

        await environment.resetSettings()

        let locations = await environment.authorizedLocations
        XCTAssertTrue(locations.isEmpty)
        let afterReset = await environment.makeScanRequest(includeDuplicates: false)
        XCTAssertFalse(
            afterReset.authorizedRoots.contains(grantURL.path),
            "a reset scan must not keep reading the previously authorised folder"
        )
    }
}
