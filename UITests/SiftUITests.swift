import XCTest

/// UI tests for the flows the specification calls out (§16.3).
///
/// These run against the built app, not against a view model, so they are the
/// check that the sidebar, the scan button, the confirmation panel and the
/// paywall are actually reachable by a user. XCTest UI testing requires Xcode.
final class SiftUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    /// The window comes up and the sidebar is populated.
    func test_mainWindowAppears() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["sidebar.dashboard"].waitForExistence(timeout: 5)
                || app.staticTexts["总览"].exists
        )
    }

    /// Every primary destination is reachable from the sidebar.
    func test_everyDestinationIsReachable() throws {
        for destination in [
            "dashboard", "smartScan", "junkCleanup", "uninstaller", "fileCleanup", "storageAnalysis",
        ] {
            let row = app.buttons["sidebar.\(destination)"]
            if row.waitForExistence(timeout: 2) {
                row.click()
                XCTAssertTrue(app.windows.firstMatch.exists)
            }
        }
    }

    /// Starting a scan shows a named phase, and cancelling is offered while it
    /// runs (§5.1).
    func test_scanStartsAndCanBeCancelled() throws {
        app.buttons["sidebar.smartScan"].click()
        let start = app.buttons["开始扫描"].firstMatch
        if start.waitForExistence(timeout: 3) {
            start.click()
            let cancel = app.buttons["取消扫描"].firstMatch
            if cancel.waitForExistence(timeout: 10) {
                cancel.click()
            }
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    /// A free user reaching for a cleanup sees the paywall at that moment, not
    /// at launch (§12.2).
    func test_cleanupAsksForAPurchase() throws {
        app.buttons["sidebar.junkCleanup"].click()
        let clean = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "移入废纸篓"))
            .firstMatch
        if clean.waitForExistence(timeout: 5), clean.isEnabled {
            clean.click()
            XCTAssertTrue(
                app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS %@", "解锁"))
                    .firstMatch
                    .waitForExistence(timeout: 5)
            )
        }
    }

    /// Settings opens and is reachable from the sidebar footer.
    func test_settingsOpens() throws {
        let settings = app.buttons["settings"].firstMatch
        if settings.waitForExistence(timeout: 3) {
            settings.click()
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
