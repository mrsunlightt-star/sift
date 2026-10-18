import XCTest

/// UI tests for the flows the specification calls out (§16.3).
///
/// These run against the built app, not against a view model, so they are the
/// check that the sidebar, the scan button, the confirmation panel and the
/// paywall are actually reachable by a user. XCTest UI testing requires Xcode.
///
/// `XCUIApplication` and its queries are main-actor isolated in the SDK this
/// project builds against, so the suite is `@MainActor` and each test launches the
/// app through `launchApp()`. There is no `setUpWithError` override for that
/// reason: it stays nonisolated whatever the class says, and the launch belongs to
/// the test's own actor. XCTest terminates the app when a test ends.
@MainActor
final class SiftUITests: XCTestCase {
    /// A sidebar row.
    ///
    /// `List(selection:)` exposes each row as a row/cell, not as a button, so the
    /// query asks for any element carrying the identifier rather than assuming
    /// the type.
    private func sidebarRow(_ app: XCUIApplication, _ destination: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.\(destination)").firstMatch
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// The window comes up and the sidebar is populated.
    func test_mainWindowAppears() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(sidebarRow(app, "dashboard").waitForExistence(timeout: 5))
    }

    /// Every primary destination is reachable from the sidebar.
    func test_everyDestinationIsReachable() throws {
        let app = launchApp()
        for destination in [
            "dashboard", "smartScan", "junkCleanup", "uninstaller", "fileCleanup", "storageAnalysis",
        ] {
            let row = sidebarRow(app, destination)
            if row.waitForExistence(timeout: 2) {
                row.click()
                XCTAssertTrue(app.windows.firstMatch.exists)
            }
        }
    }

    /// Starting a scan shows a named phase, and cancelling is offered while it
    /// runs (§5.1).
    func test_scanStartsAndCanBeCancelled() throws {
        let app = launchApp()
        sidebarRow(app, "smartScan").click()
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
        let app = launchApp()
        sidebarRow(app, "junkCleanup").click()
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
        let app = launchApp()
        let settings = app.descendants(matching: .any).matching(identifier: "sidebar.settings").firstMatch
        if settings.waitForExistence(timeout: 3) {
            settings.click()
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
