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
    case systemDiagnostics
    case settings
    case purchase

    public var id: String { rawValue }

    /// The entries the main navigation keeps (§4).
    public static var primary: [AppDestination] {
        [
            .dashboard, .smartScan, .junkCleanup, .uninstaller, .fileCleanup,
            .storageAnalysis, .systemDiagnostics,
        ]
    }

    public var titleKey: LocalizationKey {
        switch self {
        case .dashboard: .navDashboard
        case .smartScan: .navSmartScan
        case .junkCleanup: .navJunkCleanup
        case .uninstaller: .navUninstaller
        case .fileCleanup: .navFileCleanup
        case .storageAnalysis: .navStorageAnalysis
        case .systemDiagnostics: .navSystemDiagnostics
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
        case .systemDiagnostics: "stethoscope"
        case .settings: "gearshape"
        case .purchase: "lock.open"
        }
    }

    /// Digit shortcut matching the sidebar order, so ⌘1 is the overview and ⌘7
    /// is the system diagnostics. Settings uses the conventional ⌘, instead.
    public var digitShortcut: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .smartScan: "2"
        case .junkCleanup: "3"
        case .uninstaller: "4"
        case .fileCleanup: "5"
        case .storageAnalysis: "6"
        case .systemDiagnostics: "7"
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
        case .cleanJunk: .navJunkCleanup
        case .uninstall: .navUninstaller
        case .cleanFiles: .navFileCleanup
        case .exportReport: .cleanupResultExportReport
        }
    }
}
