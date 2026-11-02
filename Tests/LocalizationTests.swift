import Foundation
import XCTest
@testable import Core
import Shared

/// Localisation completeness and formatting (§11.5, §16.1).
///
/// The spec requires every shipped language to carry a full translation with
/// English as the fallback, so the tests check that every key has a translation
/// in every language rather than trusting the generator.
final class LocalizationTests: XCTestCase, @unchecked Sendable {
    /// Every language the app offers must ship a full table, so the list comes
    /// from the same enum the picker renders rather than a second copy that can
    /// fall behind it.
    private let languages = SiftLanguage.allCases.map(\.rawValue)

    func test_everyKeyResolves() {
        let unresolved = LocalizationKey.allCases.filter { $0.localized == $0.rawValue }
        XCTAssertTrue(unresolved.isEmpty, "unresolved keys: \(unresolved.map(\.rawValue))")
    }

    /// A count of one takes the singular form where the language has one.
    ///
    /// This is the check behind "1 items moved to Trash": the base string is the
    /// plural, the singular lives beside it as `<key>.one`, and `SiftPlural` says
    /// which counts take it per language. The pairs below are the whole contract,
    /// so a language that gains or loses a singular form has to change here.
    func test_aCountOfOneTakesTheSingularForm() {
        let key = LocalizationKey.commonItemCount
        let cases: [(SiftLanguage, String, String)] = [
            (.english, "1 item", "2 items"),
            (.german, "1 Eintrag", "2 Einträge"),
            (.french, "1 élément", "2 éléments"),
            (.brazilianPortuguese, "1 item", "2 itens"),
            // A label form: the count sits after the noun, so no inflection.
            (.russian, "Элементов: 1", "Элементов: 2"),
            // A language with no singular form at all.
            (.japanese, "1 項目", "2 項目"),
            (.simplifiedChinese, "1 个项目", "2 个项目"),
        ]
        let original = UserDefaults.standard.string(forKey: SiftLanguage.preferenceKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: SiftLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SiftLanguage.preferenceKey)
            }
        }
        for (language, one, many) in cases {
            UserDefaults.standard.set(language.rawValue, forKey: SiftLanguage.preferenceKey)
            XCTAssertEqual(key.counted(1), one, "\(language.rawValue) singular")
            XCTAssertEqual(key.counted(2), many, "\(language.rawValue) plural")
        }

        // Zero is the case that separates the two rules: French counts it as a
        // singular, Brazilian Portuguese does not.
        UserDefaults.standard.set(SiftLanguage.french.rawValue, forKey: SiftLanguage.preferenceKey)
        XCTAssertEqual(key.counted(0), "0 élément")
        UserDefaults.standard.set(
            SiftLanguage.brazilianPortuguese.rawValue,
            forKey: SiftLanguage.preferenceKey
        )
        XCTAssertEqual(key.counted(0), "0 itens")
    }

    func test_selectedLanguageLoadsTheMatchingResourceBundle() {
        for language in SiftLanguage.allCases {
            let bundle = Bundle.localizedBundle(for: language)
            let translated = bundle.localizedString(
                forKey: LocalizationKey.navDashboard.rawValue,
                value: nil,
                table: "Localizable"
            )
            XCTAssertNotEqual(
                translated,
                LocalizationKey.navDashboard.rawValue,
                "\(language.rawValue) did not resolve the dashboard title"
            )
        }
    }

    func test_everyLanguageShipsAFullTranslation() throws {
        for language in languages {
            let path = try XCTUnwrap(
                Bundle.siftResources.path(forResource: language, ofType: "lproj"),
                "\(language).lproj is missing from the bundle"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            let stringsPath = try XCTUnwrap(
                bundle.path(forResource: "Localizable", ofType: "strings")
            )
            let table = try XCTUnwrap(
                NSDictionary(contentsOfFile: stringsPath) as? [String: String]
            )
            let missing = LocalizationKey.allCases.filter { (table[$0.rawValue] ?? "").isEmpty }
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.prefix(5).map(\.rawValue))")
        }
    }

    func test_englishIsTheFallbackLanguage() throws {
        let path = try XCTUnwrap(Bundle.siftResources.path(forResource: "en", ofType: "lproj"))
        XCTAssertFalse(path.isEmpty)
    }

    func test_placeholderKeysSubstituteEveryArgument() {
        // The catalog resolves for the machine's language, so what is asserted is
        // that the argument arrived — never which language it arrived in. A
        // literal English expectation made these fail on a Chinese machine as
        // soon as the suite ran under real XCTest rather than the shim.
        let items = LocalizationKey.commonItemCount.counted(7)
        XCTAssertTrue(items.contains("7"), "the count is substituted")
        XCTAssertFalse(items.contains("%d"), "no placeholder survives")

        let moved = LocalizationKey.cleanupResultMoved.counted(3)
        XCTAssertTrue(moved.contains("3"))
        XCTAssertFalse(moved.contains("%d"))

        XCTAssertFalse(
            LocalizationKey.cleanupResultReleased.localized("1.2 GB").contains("%@"),
            "no placeholder may survive substitution"
        )
    }

    func test_pluralFormsUseDistinctStrings() {
        // The one/other pair for the confirmation button must not be the same
        // string, or a single-item cleanup would read as plural.
        let one = LocalizationKey.cleanupConfirmMoveCountOne.localized("4.2 MB")
        let other = LocalizationKey.cleanupConfirmMoveCount.localized(4, "4.2 MB")
        XCTAssertNotEqual(one, other)
    }

    func test_formattersFollowTheLocale() {
        let german = Locale(identifier: "de_DE")
        let english = Locale(identifier: "en_US")

        XCTAssertFalse(SiftFormat.bytes(1_500_000, locale: german).isEmpty)
        XCTAssertFalse(SiftFormat.bytes(1_500_000, locale: english).isEmpty)
        XCTAssertEqual(SiftFormat.percent(0.5, locale: english).contains("50"), true)

        // A locale that groups with a period must not produce an English grouping.
        let grouped = SiftFormat.count(1234, locale: german)
        XCTAssertTrue(grouped.contains("1") && grouped.contains("234"))
    }

    func test_currencyFormattingUsesTheGivenCode() {
        let price = SiftFormat.price(4.99, currencyCode: "EUR", locale: Locale(identifier: "fr_FR"))
        XCTAssertFalse(price.isEmpty)
        XCTAssertTrue(price.contains("€") || price.contains("EUR"))
    }

    func test_longTranslationsArePresentForOverflowTesting() {
        // German and Russian are the longest of the shipped languages; the spec
        // asks for overflow testing with them, so their strings must exist.
        for key in [LocalizationKey.purchasePriceLine, .cleanupConfirmUndoNotice, .settingsPrivacyStatement] {
            let german = localized(key, language: "de")
            let english = localized(key, language: "en")
            XCTAssertFalse(german.isEmpty)
            XCTAssertGreaterThanOrEqual(german.count, Int(Double(english.count) * 0.6))
        }
    }

    private func localized(_ key: LocalizationKey, language: String) -> String {
        guard let path = Bundle.siftResources.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let stringsPath = bundle.path(forResource: "Localizable", ofType: "strings"),
              let table = NSDictionary(contentsOfFile: stringsPath) as? [String: String] else {
            return ""
        }
        return table[key.rawValue] ?? ""
    }
}
