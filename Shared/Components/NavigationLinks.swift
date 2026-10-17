import Foundation

/// A destination a feature can ask the shell to open.
///
/// Features do not know about the app's router: they state where the user wants
/// to go, and the shell decides what that means. This keeps a feature free of a
/// dependency on the executable target.
/// Why the paywall appeared, so it can name the action the user attempted
/// instead of showing a generic upsell (§12.2).
public enum PaywallReasonLink: String, Sendable, CaseIterable {
    case cleanJunk
    case uninstall
    case cleanFiles
    case exportReport

    /// Localisation key of the action that triggered the paywall.
    public var titleKey: LocalizationKey {
        switch self {
        case .cleanJunk: .navJunkCleanup
        case .uninstall: .navUninstaller
        case .cleanFiles: .navFileCleanup
        case .exportReport: .cleanupResultExportReport
        }
    }
}
