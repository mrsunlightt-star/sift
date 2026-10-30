import Foundation
import SwiftUI

/// Languages shipped with Sift. The display names are endonyms so a user can
/// recognise their language even before the rest of the interface has switched.
public enum SiftLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-hans"
    case traditionalChinese = "zh-hant"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case brazilianPortuguese = "pt-br"
    case russian = "ru"
    case turkish = "tr"
    case polish = "pl"
    case dutch = "nl"
    case lao = "lo"
    case arabic = "ar"
    case hebrew = "he"
    case persian = "fa"
    case bulgarian = "bg"
    case czech = "cs"
    case danish = "da"
    case greek = "el"
    case latinAmericanSpanish = "es-419"
    case finnish = "fi"
    case hungarian = "hu"
    case indonesian = "id"
    case malay = "ms"
    case norwegian = "nb"
    case europeanPortuguese = "pt-pt"
    case romanian = "ro"
    case swedish = "sv"
    case thai = "th"
    case ukrainian = "uk"
    case vietnamese = "vi"

    public var id: String { rawValue }

    /// A native-language name, independent of the currently selected UI language.
    public var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español (España)"
        case .italian: "Italiano"
        case .brazilianPortuguese: "Português (Brasil)"
        case .russian: "Русский"
        case .turkish: "Türkçe"
        case .polish: "Polski"
        case .dutch: "Nederlands"
        case .lao: "ລາວ"
        case .arabic: "العربية"
        case .hebrew: "עברית"
        case .persian: "فارسی"
        case .bulgarian: "Български"
        case .czech: "Čeština"
        case .danish: "Dansk"
        case .greek: "Ελληνικά"
        case .latinAmericanSpanish: "Español (Latinoamérica)"
        case .finnish: "Suomi"
        case .hungarian: "Magyar"
        case .indonesian: "Bahasa Indonesia"
        case .malay: "Bahasa Melayu"
        case .norwegian: "Norsk"
        case .europeanPortuguese: "Português (Portugal)"
        case .romanian: "Română"
        case .swedish: "Svenska"
        case .thai: "ไทย"
        case .ukrainian: "Українська"
        case .vietnamese: "Tiếng Việt"
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .japanese: "ja"
        case .korean: "ko"
        case .german: "de"
        case .french: "fr"
        case .spanish: "es"
        case .italian: "it"
        case .brazilianPortuguese: "pt-BR"
        case .russian: "ru"
        case .turkish: "tr"
        case .polish: "pl"
        case .dutch: "nl"
        case .lao: "lo"
        case .arabic: "ar"
        case .hebrew: "he"
        case .persian: "fa"
        case .bulgarian: "bg"
        case .czech: "cs"
        case .danish: "da"
        case .greek: "el"
        case .latinAmericanSpanish: "es-419"
        case .finnish: "fi"
        case .hungarian: "hu"
        case .indonesian: "id"
        case .malay: "ms"
        case .norwegian: "nb"
        case .europeanPortuguese: "pt-PT"
        case .romanian: "ro"
        case .swedish: "sv"
        case .thai: "th"
        case .ukrainian: "uk"
        case .vietnamese: "vi"
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// The reading direction the interface lays out in. Arabic, Hebrew and
    /// Persian are right-to-left; everything else is left-to-right. The shell
    /// pushes this into the environment, because selecting a language inside the
    /// app does not move the window's own direction — SwiftUI takes that from
    /// the system localization, which this preference overrides.
    public var layoutDirection: LayoutDirection {
        switch self {
        case .arabic, .hebrew, .persian: .rightToLeft
        default: .leftToRight
        }
    }

    /// The system language is used only before the user makes an explicit choice.
    ///
    /// Chinese needs a region split the other prefixes do not: Taiwan, Hong Kong
    /// and Macau run Traditional script, everything else Simplified. Hebrew is
    /// matched under both of its codes — modern "he" and the legacy "iw" that
    /// some systems still report.
    public static var preferred: SiftLanguage {
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh-hant")
            || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk")
            || identifier.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("fr") { return .french }
        // Spanish and Portuguese each ship two variants, so the region decides.
        // Bare "es" and the Iberian variants are Spain; every other Spanish
        // region — including Apple's "es-419" — is Latin America. Bare "pt" is
        // European Portuguese, the base variety; only Brazil is Brazilian.
        if identifier == "es" || identifier.hasPrefix("es-es") || identifier.hasPrefix("es-ic") {
            return .spanish
        }
        if identifier.hasPrefix("es") { return .latinAmericanSpanish }
        if identifier.hasPrefix("it") { return .italian }
        if identifier.hasPrefix("pt-br") { return .brazilianPortuguese }
        if identifier.hasPrefix("pt") { return .europeanPortuguese }
        if identifier.hasPrefix("ru") { return .russian }
        if identifier.hasPrefix("tr") { return .turkish }
        if identifier.hasPrefix("pl") { return .polish }
        if identifier.hasPrefix("nl") { return .dutch }
        if identifier.hasPrefix("lo") { return .lao }
        if identifier.hasPrefix("ar") { return .arabic }
        if identifier.hasPrefix("he") || identifier.hasPrefix("iw") { return .hebrew }
        if identifier.hasPrefix("fa") { return .persian }
        if identifier.hasPrefix("bg") { return .bulgarian }
        if identifier.hasPrefix("cs") { return .czech }
        if identifier.hasPrefix("da") { return .danish }
        if identifier.hasPrefix("el") { return .greek }
        if identifier.hasPrefix("fi") { return .finnish }
        if identifier.hasPrefix("hu") { return .hungarian }
        if identifier.hasPrefix("id") { return .indonesian }
        if identifier.hasPrefix("ms") { return .malay }
        // Norwegian ships as Bokmål under "nb", but macOS also reports "no" and
        // Nynorsk as "nn"; the shipped translation is Bokmål for all three.
        if identifier.hasPrefix("nb") || identifier.hasPrefix("no") || identifier.hasPrefix("nn") {
            return .norwegian
        }
        if identifier.hasPrefix("ro") { return .romanian }
        if identifier.hasPrefix("sv") { return .swedish }
        if identifier.hasPrefix("th") { return .thai }
        if identifier.hasPrefix("uk") { return .ukrainian }
        if identifier.hasPrefix("vi") { return .vietnamese }
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
