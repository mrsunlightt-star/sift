import Foundation
import Shared
import SwiftUI

/// The four primary destinations plus the two auxiliary pages.
///
/// The redesign merges smart scan, junk cleanup and file cleanup into one scan
/// page: they always ran the same scan and differed only in which categories they
/// displayed. Category filters now live inside the scan page, so navigation only
/// has to name the places a user can go.
public enum AppDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard
    case scan
    case apps
    case storage
    case settings
    case purchase

    public var id: String { rawValue }

    /// The entries the icon rail keeps, in order.
    public static var primary: [AppDestination] {
        [.dashboard, .scan, .apps, .storage]
    }

    public var titleKey: LocalizationKey {
        switch self {
        case .dashboard: .navDashboard
        case .scan: .navScan
        case .apps: .navApps
        case .storage: .navStorageAnalysis
        case .settings: .navSettings
        case .purchase: .purchaseTitle
        }
    }

    public var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .scan: "viewfinder"
        case .apps: "shippingbox"
        case .storage: "chart.bar.xaxis"
        case .settings: "gearshape"
        case .purchase: "lock.open"
        }
    }

    /// Digit shortcut matching the rail order, so ⌘1 is the overview and ⌘4 is
    /// storage. Settings uses the conventional ⌘, instead.
    public var digitShortcut: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .scan: "2"
        case .apps: "3"
        case .storage: "4"
        case .settings, .purchase: nil
        }
    }

    /// The full shortcut, including the conventional settings binding.
    public var shortcut: KeyEquivalent? {
        self == .settings ? "," : digitShortcut
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
        case .cleanJunk: .navScan
        case .uninstall: .navApps
        case .cleanFiles: .navScan
        case .exportReport: .cleanupResultExportReport
        }
    }
}
