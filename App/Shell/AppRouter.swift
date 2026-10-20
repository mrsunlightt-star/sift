import Foundation
import Shared
import SwiftUI

/// The five primary destinations plus the auxiliary pages (§4).
///
/// Kept as a single enum so the sidebar, the keyboard shortcuts and the
/// deep-linkable titles cannot drift apart.
public enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard
    case smartScan
    case junkCleanup
    case uninstaller
    case fileCleanup
    case storageAnalysis
    case settings
    case purchase

    public var id: String { rawValue }

    /// The entries the main navigation keeps (§4), in sidebar order.
    public static var primary: [AppDestination] {
        SidebarGroup.allCases.flatMap(\.destinations)
    }

    public var titleKey: LocalizationKey {
        switch self {
        case .dashboard: .navDashboard
        case .smartScan: .navSmartScan
        case .junkCleanup: .navJunkCleanup
        case .uninstaller: .navUninstaller
        case .fileCleanup: .navFileCleanup
        case .storageAnalysis: .navStorageAnalysis
        case .settings: .navSettings
        case .purchase: .purchaseTitle
        }
    }

    public var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .smartScan: "viewfinder"
        case .junkCleanup: "trash"
        case .uninstaller: "shippingbox"
        case .fileCleanup: "doc.on.doc"
        case .storageAnalysis: "chart.pie"
        case .settings: "gearshape"
        case .purchase: "lock.open"
        }
    }

    /// Digit shortcut matching the sidebar order, so ⌘1 is the overview and ⌘6
    /// is storage. Settings uses the conventional ⌘, instead.
    public var digitShortcut: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .smartScan: "2"
        case .junkCleanup: "3"
        case .fileCleanup: "4"
        case .uninstaller: "5"
        case .storageAnalysis: "6"
        case .settings, .purchase: nil
        }
    }

    /// The full shortcut, including the conventional settings binding.
    public var shortcut: KeyEquivalent? {
        self == .settings ? "," : digitShortcut
    }
}

/// The three parts of the main navigation.
///
/// Grouping is a navigation decision, not a view decision: the sidebar renders
/// the groups, the keyboard shortcuts number the same order, and the page header
/// names the group a page belongs to.
public enum SidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case workbench
    case cleanup
    case apps

    public var id: String { rawValue }

    public var titleKey: LocalizationKey {
        switch self {
        case .workbench: .navWorkbench
        case .cleanup: .navGroupCleanup
        case .apps: .navGroupApps
        }
    }

    public var destinations: [AppDestination] {
        switch self {
        case .workbench: [.dashboard, .smartScan]
        case .cleanup: [.junkCleanup, .fileCleanup]
        case .apps: [.uninstaller, .storageAnalysis]
        }
    }
}

/// Navigation state.
@MainActor
public final class AppRouter: ObservableObject {
    @Published public var destination: AppDestination = .dashboard
    /// Set when a view asks for the purchase page, so the paywall can explain
    /// which action triggered it.
    @Published public var paywallReason: PaywallReason?

    public init() {}

    /// Switches to a destination.
    public func go(to destination: AppDestination) {
        self.destination = destination
    }

    /// Asks for the paywall, remembering what the user was trying to do so the
    /// sheet can name the action rather than showing a generic upsell (§12.2).
    public func requestPurchase(reason: PaywallReason) {
        paywallReason = reason
        destination = .purchase
    }
}

/// Why the paywall appeared.
public enum PaywallReason: String, Sendable, Hashable {
    case cleanJunk
    case uninstall
    case cleanFiles
    case exportReport

    public var titleKey: LocalizationKey {
        switch self {
        case .cleanJunk: .navJunkCleanup
        case .uninstall: .navUninstaller
        case .cleanFiles: .navFileCleanup
        case .exportReport: .cleanupResultExportReport
        }
    }
}
