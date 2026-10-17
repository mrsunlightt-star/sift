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
        NSApplication.shared.setActivationPolicy(.regular)
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
        CommandGroup(after: .newItem) {
            ForEach(AppDestination.primary) { destination in
                Button(destination.titleKey.localized) {
                    router.go(to: destination)
                }
                .keyboardShortcut(destination.shortcut ?? "1", modifiers: .command)
            }
        }
        CommandGroup(replacing: .help) {
            Button(LocalizationKey.navHelp.localized) {
                router.go(to: .settings)
            }
        }
    }
}
