import Foundation
import XCTest
@testable import Core
import Shared

/// The composition root's state transitions that cross several services.
final class AppEnvironmentTests: XCTestCase, @unchecked Sendable {
    override func setUp() {
        super.setUp()
        ScratchPreferences.reset("environment")
    }

    override func tearDown() {
        ScratchPreferences.reset("environment")
        super.tearDown()
    }

    @MainActor
    private func makeEnvironment() -> AppEnvironment {
        let defaults = ScratchPreferences.open("environment")
        let store = SettingsStore(
            preferences: StringPreferences(defaults: defaults),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-environment-\(UUID().uuidString)", isDirectory: true)
        )
        // The entitlement cache shares the isolated suite too: hosted by the
        // app, `.standard` is the app's own domain, and an activation left
        // there by a session on this machine would unlock the tier under test.
        return AppEnvironment(settings: store, entitlementDefaults: defaults)
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

    /// The entitlement gate runs again at the execution boundary, not only when
    /// the confirmation panel opened.
    func test_theFreeTierCannotExecuteAPreparedCleanup() async throws {
        let environment = await MainActor.run { makeEnvironment() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-gate-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("Library/Caches/com.example.app/blob.bin")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 4096).write(to: file)
        defer { try? FileManager.default.removeItem(at: folder) }

        let item = CleanupItem(
            url: file,
            displayName: file.lastPathComponent,
            category: .applicationCache,
            risk: .safe,
            sizeInBytes: 4096,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "tests"
        )
        await MainActor.run { environment.cleanup.setItems([item]) }
        _ = await environment.cleanup.prepareCleanup(requiresConfirmation: false)

        let result = await environment.confirmCleanup(operation: .junkCleanup)
        guard case .purchaseRequired = result else {
            return XCTFail("the free tier must not execute a cleanup")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "the file was not moved"
        )
    }

    /// The destructive slot is synchronous and exclusive.
    ///
    /// Both `confirmCleanup` and `performUninstall` claim it before the
    /// entitlement check, which is their first suspension. The previous order
    /// awaited the licence answer first, so two callers could both pass the
    /// guard while neither had set the flag.
    func test_theDestructiveSlotCannotBeClaimedTwice() async {
        let environment = await MainActor.run { makeEnvironment() }
        await MainActor.run {
            XCTAssertTrue(environment.beginDestructiveOperation())
            XCTAssertFalse(
                environment.beginDestructiveOperation(),
                "a second destructive operation must be refused while the first owns the slot"
            )
            environment.endDestructiveOperation()
            XCTAssertTrue(
                environment.beginDestructiveOperation(),
                "releasing the slot makes it available again"
            )
            environment.endDestructiveOperation()
        }
    }

    /// The uninstaller is judged before it is confirmed.
    ///
    /// The panel used to be shown first and the pre-flight run afterwards, so the
    /// batch the user approved and the batch that moved were two different
    /// documents — and a batch that nothing survived moved nothing after a click
    /// that had already said it would. This pins the contract the panel reads:
    /// the numbers come from pre-flight, and a refusal arrives with its reason.
    ///
    /// Execution itself is not exercised here: an uninstall really moves files,
    /// and the destructive slot and entitlement gates around it are covered by
    /// `test_theDestructiveSlotCannotBeClaimedTwice` and the entitlement suite.
    func test_prepareUninstallJudgesTheBatchBeforeAnyoneConfirms() async throws {
        let environment = await MainActor.run { makeEnvironment() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-prepare-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = folder.appendingPathComponent("Example App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let payload = app.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 4096).write(to: payload)

        // A fresh environment is on the free tier; the preparation path is what
        // this test is about, so it unlocks the way the debug channel does.
        _ = try? await environment.entitlements.activate(licenseKey: LicenseVerifier.developmentKey)
        await environment.refreshEntitlement()

        let bundleItem = CleanupItem(
            url: app,
            displayName: "Example App.app",
            category: .applicationResidue,
            risk: .review,
            sizeInBytes: 4096,
            fileCount: 1,
            explanationKey: "cleanup.explanation.residue",
            sourceRuleID: "applicationResidue"
        )

        // An empty batch is not a confirmation waiting to happen.
        if case let .nothingToDo(preparation) = await environment.prepareUninstall(items: []) {
            XCTAssertEqual(preparation.count, 0)
            XCTAssertFalse(preparation.isActionable)
        } else {
            XCTFail("an empty batch must not open a panel")
        }

        // A batch that pre-flight can judge comes back with the numbers the panel
        // states, not the ones the caller intended.
        switch await environment.prepareUninstall(items: [bundleItem]) {
        case let .ready(preparation):
            XCTAssertEqual(preparation.count, 1)
            XCTAssertEqual(preparation.bytes, 4096)
            XCTAssertTrue(preparation.isActionable)
        case let .nothingToDo(preparation):
            // An uninstaller item that is refused must be refused *with a reason*
            // the panel can print, rather than as a silent zero.
            XCTAssertFalse(preparation.refused.isEmpty, "a refusal carries its reason")
        case .purchaseRequired, .busy:
            XCTFail("a fresh environment on the paid tier must not gate the preparation")
        }
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
