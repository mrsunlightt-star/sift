import Foundation

extension Bundle {
    /// The resource bundle that owns the string catalog.
    ///
    /// Kept as a single accessor so every feature resolves text the same way:
    /// the string catalog lives in one target, and a view model in another target
    /// must not fall back to its own (empty) table.
    public var localizationBundle: Bundle { Self.siftResources }

    /// The `Shared` bundle, reachable without an instance.
    ///
    /// Used by tests and diagnostics that need to enumerate what shipped.
    public static var siftResources: Bundle { .module }
}

/// Text formatting helpers.
///
/// The specification (§11.5) requires sizes, dates, counts and currency to use
/// the system locale rather than the developer's assumptions, so nothing here
/// builds a string by hand.
public enum SiftFormat {
    /// Byte counts as the Finder shows them (1 KB = 1000 bytes, decimal units).
    ///
    /// Decimal units are deliberate: macOS reports APFS capacities decimally, so
    /// matching that is what stops "12.4 GB removed" from disagreeing with the
    /// free-space change in the Finder.
    public static func bytes(_ count: Int64, locale: Locale = .current) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        return formatter.string(fromByteCount: count)
    }

    /// A file count with the current locale's grouping separator.
    public static func count(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// A percentage such as `73%` or `73 %`, per locale conventions.
    public static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }

    /// An abbreviated relative date: `Today`, `Yesterday`, `3 days ago`, or an
    /// absolute date once it is older than a week.
    public static func relativeDate(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return LocalizationKey.commonToday.localized
        }
        if calendar.isDateInYesterday(date) {
            return LocalizationKey.commonYesterday.localized
        }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days > 0, days < 7 {
            return LocalizationKey.commonDaysAgo.localized(days)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// A full timestamp for report headers and file rows.
    public static func timestamp(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A price, always in the store's own currency.
    ///
    /// The literal `$4.99` in the specification is the reference price; the App
    /// Store and the license service return localised amounts, which is what
    /// this formats so the in-app string and the store page cannot disagree.
    public static func price(_ amount: Decimal, currencyCode: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currencyCode) \(amount)"
    }
}
