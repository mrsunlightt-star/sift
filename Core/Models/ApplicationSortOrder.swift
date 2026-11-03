import Foundation
import Shared

/// How the Apps page orders the installed applications (§5.3).
///
/// The order lives here rather than inside the view for two reasons: the menu, the
/// list and the summary line above it all read one definition, so a fourth order
/// cannot be half-wired; and the ordering itself is a value operation, which is
/// the only part of the page a test can hold.
///
/// Three of the four orders are "newest or biggest first", because that is what
/// the page is for: the application at the top should be the one worth removing.
/// An application whose date could not be read sorts **after** every application
/// whose date could — an unreadable date is not the newest one, and putting it
/// first would claim it is.
public enum ApplicationSortOrder: String, CaseIterable, Sendable {
    case name
    case size
    case lastUsed
    case installedAt

    public var titleKey: LocalizationKey {
        switch self {
        case .name: .uninstallSortName
        case .size: .uninstallSortSize
        case .lastUsed: .uninstallSortLastUsed
        case .installedAt: .uninstallSortInstalledAt
        }
    }

    /// The applications in this order.
    public func sorted(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        switch self {
        case .name:
            return applications.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .size:
            return applications.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .lastUsed:
            return applications.sorted { newestFirst($0.lastUsedAt, $1.lastUsedAt) }
        case .installedAt:
            return applications.sorted { newestFirst($0.installedAt, $1.installedAt) }
        }
    }

    /// Newest first, and a date that is missing after every date that is present.
    private func newestFirst(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case let (lhs?, rhs?):
            return lhs > rhs
        case (_?, nil):
            return true
        default:
            return false
        }
    }
}
