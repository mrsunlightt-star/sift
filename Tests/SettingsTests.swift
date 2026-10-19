import Foundation
import XCTest
@testable import Core
import Shared

/// Preferences (§5.6, §16.1).
final class SettingsTests: XCTestCase, @unchecked Sendable {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "sift.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return SettingsStore(preferences: StringPreferences(defaults: defaults))
    }

    func test_defaultsMatchTheSpecification() async {
        let settings = await makeStore().current()
        XCTAssertFalse(settings.skipConfirmation, "skip confirmation must be off by default")
        XCTAssertTrue(settings.requireConfirmation, "confirmation must be on by default")
        XCTAssertEqual(settings.largeFileThresholdBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(settings.oldFileThresholdDays, 180)
        XCTAssertEqual(settings.staleThresholdDays, 30)
        XCTAssertEqual(settings.keepScanHistory, 10)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.language, SiftLanguage.preferred)
        XCTAssertEqual(settings.language, SiftLanguage.preferred)
        XCTAssertTrue(settings.ignoredPaths.isEmpty)
    }

    func test_valuesSurviveANewStore() async {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let first = SettingsStore(preferences: StringPreferences(defaults: defaults))
        await first.update { settings in
            settings.largeFileThresholdBytes = 2 * 1024 * 1024 * 1024
            settings.oldFileThresholdDays = 365
            settings.appearance = .dark
            settings.language = .japanese
            settings.ignoredPaths = ["/Users/example/keep"]
            settings.skipConfirmation = true
        }

        let second = SettingsStore(preferences: StringPreferences(defaults: defaults))
        let reloaded = await second.current()
        XCTAssertEqual(reloaded.largeFileThresholdBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(reloaded.oldFileThresholdDays, 365)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.language, .japanese)
        XCTAssertEqual(reloaded.ignoredPaths, ["/Users/example/keep"])
        XCTAssertTrue(reloaded.skipConfirmation)
    }

    func test_confirmationDefaultsToOnWhenTheKeyIsAbsent() async {
        // An upgrade from a build without the key must not silently disable the
        // confirmation panel.
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removeObject(forKey: "settings.requireConfirmation")
        let settings = await SettingsStore(preferences: StringPreferences(defaults: defaults)).current()
        XCTAssertTrue(settings.requireConfirmation)
    }

    func test_skipConfirmationImpliesNoPanelOnlyWhenConfirmationIsOn() async {
        var settings = AppSettings.default
        XCTAssertTrue(settings.showsConfirmationPanel)

        settings.skipConfirmation = true
        XCTAssertFalse(settings.showsConfirmationPanel)

        settings.requireConfirmation = false
        XCTAssertFalse(settings.showsConfirmationPanel)
    }

    func test_changesArePublished() async throws {
        let store = makeStore()
        let stream = await store.changes()

        let received = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 { break }
            }
            return count
        }

        await store.update { $0.staleThresholdDays = 14 }
        let count = await received.value
        XCTAssertGreaterThanOrEqual(count, 2, "the first value plus the change")
    }

    func test_resetRestoresEveryDefault() async {
        let store = makeStore()
        await store.update { settings in
            settings.largeFileThresholdBytes = 512
            settings.skipConfirmation = true
            settings.appearance = .light
        }
        await store.resetToDefaults()
        let settings = await store.current()
        XCTAssertEqual(settings.largeFileThresholdBytes, AppSettings.default.largeFileThresholdBytes)
        XCTAssertFalse(settings.skipConfirmation)
        XCTAssertEqual(settings.appearance, .system)
    }
}
