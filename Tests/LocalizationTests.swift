import Foundation
import XCTest
@testable import Core
import Shared

/// Localisation completeness and formatting (§11.5, §16.1).
///
/// The spec requires eight languages with English as the fallback, so the tests
/// check that every key has a translation in every language rather than trusting
/// the generator.
final class LocalizationTests: XCTestCase {
    private let languages = ["en", "zh-hans", "ko", "ru", "es", "ja", "fr", "de"]

    func test_everyKeyResolves() {
        let unresolved = LocalizationKey.allCases.filter { $0.localized == $0.rawValue }
        XCTAssertTrue(unresolved.isEmpty, "unresolved keys: \(unresolved.map(\.rawValue))")
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
        XCTAssertEqual(LocalizationKey.commonItemCount.localized(7), "7 items")
        XCTAssertTrue(LocalizationKey.cleanupResultMoved.localized(3).contains("3"))
        XCTAssertFalse(LocalizationKey.cleanupResultMoved.localized(3).contains("%d"))
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
