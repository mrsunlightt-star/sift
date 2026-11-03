import Foundation
import Shared

/// How the Apps page orders the installed applications (§5.3).
///
/// The order lives here rather than inside the view for three reasons: the menu,
/// the list and the summary line above it all read one definition, so a ninth
/// order cannot be half-wired; the ordering itself is a value operation, which is
/// the only part of the page a test can hold; and one attribute with two
/// directions is one case, not two orders the menu has to keep paired.
///
/// Every attribute offers both directions. A page that only sorts "biggest first"
/// and "newest first" answers one question — what is worth removing — and leaves
/// the other unasked: which application did I install a week ago, which one is
/// the small leftover I keep scrolling past, which one have I used most recently.
/// The direction is therefore part of the selection rather than something the
/// page implies, and `axis` is what keeps the menu grouped by attribute instead
/// of listing eight unrelated rows.
///
/// An application whose date could not be read sorts **after** every application
/// whose date could, in both directions — an unreadable date is not the newest one
/// and not the oldest one either, and ranking it as either would state something
/// the system did not say.
public enum ApplicationSortOrder: String, CaseIterable, Sendable {
    case nameAscending
    case nameDescending
    case largestFirst
    case smallestFirst
    case recentlyUsed
    case leastRecentlyUsed
    case newestInstalled
    case oldestInstalled

    /// The attribute the order sorts by, which is what the menu groups rows by.
    public enum Axis: String, CaseIterable, Sendable {
        case name
        case size
        case lastUsed
        case installedAt
    }

    public var axis: Axis {
        switch self {
        case .nameAscending, .nameDescending: .name
        case .largestFirst, .smallestFirst: .size
        case .recentlyUsed, .leastRecentlyUsed: .lastUsed
        case .newestInstalled, .oldestInstalled: .installedAt
        }
    }

    /// The attribute's own name — the menu's row prefix and the summary's subject.
    public var titleKey: LocalizationKey {
        switch axis {
        case .name: .uninstallSortName
        case .size: .uninstallSortSize
        case .lastUsed: .uninstallSortLastUsed
        case .installedAt: .uninstallSortInstalledAt
        }
    }

    /// Which way this order reads that attribute.
    ///
    /// Separate from `titleKey` because the two halves are composed: four
    /// attributes times two directions is eight selections but only six sentences,
    /// and writing eight full titles is how one of them ends up saying "oldest"
    /// over a list sorted newest-first.
    public var directionKey: LocalizationKey {
        switch self {
        case .nameAscending: .uninstallSortNameAscending
        case .nameDescending: .uninstallSortNameDescending
        case .largestFirst: .uninstallSortLargestFirst
        case .smallestFirst: .uninstallSortSmallestFirst
        case .recentlyUsed: .uninstallSortNewestFirst
        case .leastRecentlyUsed: .uninstallSortOldestFirst
        case .newestInstalled: .uninstallSortNewestFirst
        case .oldestInstalled: .uninstallSortOldestFirst
        }
    }

    /// What the menu row and the summary line say: "Install date · Newest first".
    ///
    /// The separator is a middle dot rather than a colon or a dash because neither
    /// half is a label for the other, and a middle dot needs no localisation of
    /// punctuation. The menu shows the same sentence the header states, so the
    /// selection on screen cannot be described two ways.
    public var title: String {
        "\(titleKey.localized) · \(directionKey.localized)"
    }

    /// The applications in this order.
    public func sorted(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        switch self {
        case .nameAscending:
            return applications.sorted { name($0, $1) == .orderedAscending }
        case .nameDescending:
            return applications.sorted { name($0, $1) == .orderedDescending }
        case .largestFirst:
            return applications.sorted { sized($0, $1, descending: true) }
        case .smallestFirst:
            return applications.sorted { sized($0, $1, descending: false) }
        case .recentlyUsed:
            return ordered(applications, by: \.lastUsedAt, newestFirst: true)
        case .leastRecentlyUsed:
            return ordered(applications, by: \.lastUsedAt, newestFirst: false)
        case .newestInstalled:
            return ordered(applications, by: \.installedAt, newestFirst: true)
        case .oldestInstalled:
            return ordered(applications, by: \.installedAt, newestFirst: false)
        }
    }

    private func name(_ left: InstalledApplication, _ right: InstalledApplication) -> ComparisonResult {
        let result = left.name.localizedStandardCompare(right.name)
        // Two bundles can carry one display name (`/Applications/X.app` and a copy
        // in `~/Applications`). Falling back to the identifier keeps the list from
        // reordering itself between renders for a reason the user cannot see.
        return result == .orderedSame ? left.id.localizedStandardCompare(right.id) : result
    }

    private func sized(
        _ left: InstalledApplication,
        _ right: InstalledApplication,
        descending: Bool
    ) -> Bool {
        if left.sizeInBytes != right.sizeInBytes {
            return descending ? left.sizeInBytes > right.sizeInBytes : left.sizeInBytes < right.sizeInBytes
        }
        return name(left, right) == .orderedAscending
    }

    /// Newest or oldest first, and a missing date after every date that is present.
    ///
    /// The unknown-after-known rule is not part of the direction: reversing the
    /// order must not move the applications with no readable date to the top, where
    /// the list would present them as the oldest — or the newest — on no evidence.
    private func ordered(
        _ applications: [InstalledApplication],
        by date: (InstalledApplication) -> Date?,
        newestFirst: Bool
    ) -> [InstalledApplication] {
        applications.sorted { left, right in
            switch (date(left), date(right)) {
            case let (lhs?, rhs?):
                if lhs != rhs { return newestFirst ? lhs > rhs : lhs < rhs }
                return name(left, right) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return name(left, right) == .orderedAscending
            }
        }
    }
}
