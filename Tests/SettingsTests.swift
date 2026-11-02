import Foundation
import XCTest
@testable import Core
import Shared

/// Preferences (§5.6, §16.1).
final class SettingsTests: XCTestCase, @unchecked Sendable {
    override func setUp() {
        super.setUp()
        ScratchPreferences.reset("settings")
    }

    override func tearDown() {
        ScratchPreferences.reset("settings")
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        let defaults = ScratchPreferences.open("settings")
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
        XCTAssertTrue(settings.ignoredPaths.isEmpty)
    }

    func test_valuesSurviveANewStore() async {
        let defaults = ScratchPreferences.open("settings")
        let first = SettingsStore(preferences: StringPreferences(defaults: defaults))
        await first.update { settings in
            settings.largeFileThresholdBytes = 2 * 1024 * 1024 * 1024
            settings.oldFileThresholdDays = 365
            settings.appearance = .dark
            settings.language = .japanese
            settings.ignoredPaths = ["/Users/example/keep"]
            settings.skipConfirmation = true
            settings.textScale = .large
        }

        let second = SettingsStore(preferences: StringPreferences(defaults: defaults))
        let reloaded = await second.current()
        XCTAssertEqual(reloaded.largeFileThresholdBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(reloaded.oldFileThresholdDays, 365)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.language, .japanese)
        XCTAssertEqual(reloaded.ignoredPaths, ["/Users/example/keep"])
        XCTAssertTrue(reloaded.skipConfirmation)
        XCTAssertEqual(reloaded.textScale, .large)
    }

    /// The type scale is a stored preference, and its three steps are the only
    /// values the theme accepts.
    ///
    /// A scale that did not round-trip would draw the standard ladder after every
    /// relaunch, which is the same bug as having no setting at all.
    func test_theTypeScaleSurvivesAndHasThreeSteps() async {
        // The model's default, not a scratch store's first read: a scratch
        // domain outlives one run, and this test itself leaves `large` in it, so
        // asserting "a fresh store starts at standard" asserted the order the
        // suite happened to run in rather than the product.
        XCTAssertEqual(AppSettings.default.textScale, .standard)

        let defaults = ScratchPreferences.open("settings")
        let store = makeStore()

        for step in AppSettings.TextScale.allCases {
            await store.update { $0.textScale = step }
            let reloaded = await makeStore().current()
            XCTAssertEqual(reloaded.textScale, step)
        }
        XCTAssertEqual(Set(AppSettings.TextScale.allCases.map(\.multiplier)).count, 3)
    }

    /// The first-cleanup hint is shown once per installation.
    ///
    /// It is a stored fact rather than a per-run one: the panel reads it to add a
    /// sentence to the first batch and stay quiet afterwards, so a value that did
    /// not survive a relaunch would greet the user as a beginner on every launch.
    func test_theFirstCleanupFlagStartsFalseAndSurvives() async {
        let store = makeStore()
        let initial = await store.current()
        XCTAssertEqual(initial.hasCompletedCleanup, false)

        await store.update { $0.hasCompletedCleanup = true }
        let reloaded = await makeStore().current()
        XCTAssertTrue(reloaded.hasCompletedCleanup)
    }

    func test_confirmationDefaultsToOnWhenTheKeyIsAbsent() async {
        // An upgrade from a build without the key must not silently disable the
        // confirmation panel.
        let defaults = ScratchPreferences.open("settings")
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
            settings.language = .japanese
        }
        await store.resetToDefaults()
        let settings = await store.current()
        XCTAssertEqual(settings.largeFileThresholdBytes, AppSettings.default.largeFileThresholdBytes)
        XCTAssertFalse(settings.skipConfirmation)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.language, SiftLanguage.preferred)
    }

    /// "Clear history" removes the on-disk history directory; reports are a
    /// separate action and must survive it.
    func test_clearHistoryRemovesTheDirectoryButNotReports() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-settings-\(UUID().uuidString)", isDirectory: true)
        let history = support.appendingPathComponent("History", isDirectory: true)
        let reports = support.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let report = reports.appendingPathComponent("Sift-Report.json")
        try Data("{}".utf8).write(to: report)
        defer { try? FileManager.default.removeItem(at: support) }

        let defaults = ScratchPreferences.open("settings")
        let store = SettingsStore(
            preferences: StringPreferences(defaults: defaults),
            supportDirectory: support
        )
        await store.clearHistory()

        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.path),
            "clearing history must not delete the user's saved reports"
        )
    }

    /// The scratch domain must not look like an application.
    ///
    /// `~/Library/Preferences` is one of the places residue is looked for, and a
    /// name with three or more dot-separated components is a bundle identifier by
    /// that reading: `sift.tests.<uuid>` left 7865 offerable "leftovers" on a
    /// machine that runs the suite daily, all of them empty. A stable, dot-free name
    /// is what keeps the product from reporting its own test artifacts.
    func test_theScratchSuiteCannotBeMistakenForAnApplication() {
        let name = ScratchPreferences.suite("settings")
        XCTAssertEqual(
            name,
            ScratchPreferences.suite("settings"),
            "one stable domain per class, so a run rewrites it rather than adding to a pile"
        )
        XCTAssertLessThan(
            name.split(separator: ".").count,
            3,
            "a preference domain with three components is offered as application residue: \(name)"
        )
    }
}
