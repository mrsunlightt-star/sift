import Foundation

/// Languages shipped with Sift. The display names are endonyms so a user can
/// recognise their language even before the rest of the interface has switched.
public enum SiftLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-hans"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case russian = "ru"

    public var id: String { rawValue }

    /// A native-language name, independent of the currently selected UI language.
    public var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .russian: "Русский"
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .japanese: "ja"
        case .korean: "ko"
        case .german: "de"
        case .french: "fr"
        case .spanish: "es"
        case .russian: "ru"
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// The system language is used only before the user makes an explicit choice.
    public static var preferred: SiftLanguage {
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("ru") { return .russian }
        return .english
    }

    /// The preference key the selected language is stored under.
    ///
    /// One constant is shared by the sidebar control, the settings row and the
    /// settings store, so no view can invent a second storage key.
    public static let preferenceKey = "settings.language"

    /// Stores a selection synchronously.
    ///
    /// `localized` reads the preference directly, and a view can re-render before
    /// the settings actor has finished its round trip; writing the value first
    /// keeps the strings and the control in step in the same frame. The settings
    /// store persists the same value through its own pipeline.
    public static func persistSelection(_ language: SiftLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
    }

    /// A synchronous lookup keeps the current localisation API usable from
    /// SwiftUI views and domain services alike. The same key is persisted by
    /// SettingsStore, so a language change takes effect immediately.
    public static var current: SiftLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: preferenceKey),
              let language = SiftLanguage(rawValue: rawValue) else {
            return preferred
        }
        return language
    }
}


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

    /// Resolves strings from the explicitly selected language, rather than
    /// relying on the operating system's preferred-languages order.
    public static func localizedBundle(for language: SiftLanguage) -> Bundle {
        guard let path = siftResources.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return siftResources
        }
        return bundle
    }
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
    public static func bytes(_ count: Int64, locale: Locale = SiftLanguage.current.locale) -> String {
        let formatter = ByteCountFormatter()
        // ByteCountFormatter follows the system's unit conventions; unlike
        // NumberFormatter/DateFormatter, it has no locale setter on macOS.
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        return formatter.string(fromByteCount: count)
    }

    /// A file count with the current locale's grouping separator.
    public static func count(_ value: Int, locale: Locale = SiftLanguage.current.locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// A percentage such as `73%` or `73 %`, per locale conventions.
    public static func percent(_ fraction: Double, locale: Locale = SiftLanguage.current.locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }

    /// An abbreviated relative date: `Today`, `Yesterday`, `3 days ago`, or an
    /// absolute date once it is older than a week.
    public static func relativeDate(_ date: Date, now: Date = Date(), locale: Locale = SiftLanguage.current.locale) -> String {
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
    public static func timestamp(_ date: Date, locale: Locale = SiftLanguage.current.locale) -> String {
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
    public static func price(_ amount: Decimal, currencyCode: String, locale: Locale = SiftLanguage.current.locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currencyCode) \(amount)"
    }
}
