import AppKit
import AppShell
import Core
import Shared
import SwiftUI

/// The application entry point.
///
/// This file compiles both in the SwiftPM executable and in the Xcode app target,
/// so the two builds cannot drift. Everything it needs comes from `AppShell`, a
/// library the Xcode target links as a local package product.
@main
struct SiftApp: App {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var router = AppRouter()

    init() {
        // The app is a normal foreground app; it never installs a status item and
        // never runs in the background (§3.2 defers the menu-bar helper).
        //
        // The one exception is not a mode a user can reach. When this process is
        // hosting the XCTest bundle it is the unit-test host, not the app the user
        // launched, and Xcode starts one host per test worker — seven of them at
        // once before the test plan was made serial. A `.regular` policy put an
        // icon for each in the Dock; `.accessory` keeps the process and its
        // windows, which is what the tests use, and leaves the Dock to the
        // applications the user opened.
        //
        // The environment is what tells the two apart, not `NSClassFromString`:
        // the bundle is injected into this process, but not yet loaded when
        // SwiftUI calls `init` (a class lookup here answered nil on a host that
        // was running the suite). The unit-test host is launched with
        // `XCTestBundlePath` and a session identifier; the application under test
        // in a UI test is a plain launch whose only injected library is the main
        // thread checker.
        let environment = ProcessInfo.processInfo.environment
        let hostingXCTest = environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        NSApplication.shared.setActivationPolicy(hostingXCTest ? .accessory : .regular)
    }

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(environment)
                .environmentObject(router)
                .frame(minWidth: 980, minHeight: 640)
                .task { await environment.bootstrap() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1160, height: 780)
        .commands { SiftCommands(router: router) }
    }
}

/// Menu-bar commands, so every primary destination is reachable from the
/// keyboard as well as the sidebar (§11.4).
struct SiftCommands: Commands {
    @ObservedObject var router: AppRouter

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(LocalizationKey.navSettings.localized) {
                router.go(to: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            ForEach(AppDestination.primary) { destination in
                Button(destination.titleKey.localized) {
                    router.go(to: destination)
                }
                .keyboardShortcut(destination.shortcut ?? "1", modifiers: .command)
            }
        }
    }
}
