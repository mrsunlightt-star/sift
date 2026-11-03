import AppKit
import SwiftUI
import XCTest
import Shared

/// The V2 palette is a claim about contrast, and this file measures it.
///
/// The design pack states one green for the icon and a second, darker green for
/// anything a user reads (`Design/V2/01-visual-foundation.md` §1). That is the
/// same split this product already had to make once for its blue palette, and
/// `DesignSystemRoleTests` enforces the *call site* half of it: no page may paint
/// small text with a fill token. This file enforces the other half — that the
/// tokens themselves measure what the specification says they measure, in both
/// appearances, so a future retint cannot quietly undo the split.
///
/// Every ratio is computed with the WCAG 2.1 relative-luminance formula over
/// sRGB, from the token's *resolved* `NSColor` rather than from a copied hex
/// string: a copy would pass while the palette drifted away from it.
final class V2PaletteTests: XCTestCase, @unchecked Sendable {
    private let tolerance = 0.06

    // MARK: - Resolving a token in one appearance

    private func resolved(_ color: Color, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            ?? NSAppearance(named: .aqua)!
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    /// A token as it appears on the page: translucent tokens are composited over
    /// what is behind them, because a wash that measures 1.1:1 against the canvas
    /// is a wash, and the text on it has to clear AA against the *result*.
    private func composited(_ color: Color, over backdrop: Color, dark: Bool) -> NSColor {
        let top = resolved(color, dark: dark)
        let bottom = resolved(backdrop, dark: dark)
        let alpha = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
                       green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
                       blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha),
                       alpha: 1)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func ratio(_ first: NSColor, _ second: NSColor) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func ratio(_ first: Color, _ second: Color, dark: Bool) -> Double {
        ratio(resolved(first, dark: dark), resolved(second, dark: dark))
    }

    private func assertRatio(_ measured: Double,
                             _ expected: Double,
                             _ label: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        // `XCTAssertEqual(_:_:accuracy:)` is an XCTest overload that the
        // Command-Line-Tools shim in `Scripts/run-tests.sh` does not carry, and a
        // test file that compiles under `swift test` alone breaks the suite on a
        // machine without Xcode. The difference is asserted instead, which every
        // XCTest-compatible runner has.
        XCTAssertLessThanOrEqual(
            abs(measured - expected), tolerance,
            "\(label): measured \(String(format: "%.2f", measured)):1, "
            + "the specification and the doc comment say "
            + "\(String(format: "%.2f", expected)):1",
            file: file, line: line
        )
    }

    // MARK: - The canvas is the canvas

    func test_theCanvasIsPureWhiteInLightAppearanceAndTheDarkGroundIsGreenCast() {
        XCTAssertEqual(hex(resolved(SiftColor.canvas, dark: false)), "#FFFFFF",
                       "V2 fixes the light canvas at pure white; a cool grey page "
                       + "background is what the specification rules out")
        XCTAssertEqual(hex(resolved(SiftColor.canvas, dark: true)), "#111713")
    }

    // MARK: - Text roles

    func test_everyTextRoleClearsAAOnTheCanvasInBothAppearances() {
        // The ratios are the ones stated in `SiftColor`'s V2 doc comment.
        let light: [(String, Color, Double)] = [
            ("mainText", SiftColor.mainText, 15.28),
            ("secondaryText", SiftColor.secondaryText, 5.70),
            ("quietText", SiftColor.quietText, 5.04),
            ("actionGreen", SiftColor.actionGreen, 5.16),
            ("safeText", SiftColor.safeTextColor, 6.26),
            ("reviewText", SiftColor.reviewTextColor, 5.93),
            ("dangerText", SiftColor.dangerTextColor, 5.90),
            ("protectedText", SiftColor.protectedTextColor, 5.70),
            ("infoText", SiftColor.infoTextColor, 7.80),
        ]
        for (name, token, expected) in light {
            let measured = ratio(token, SiftColor.canvas, dark: false)
            assertRatio(measured, expected, "light \(name)")
            XCTAssertGreaterThanOrEqual(measured, 4.5, "light \(name) misses AA for body text")
        }
        let dark: [(String, Color, Double)] = [
            ("mainText", SiftColor.mainText, 16.51),
            ("secondaryText", SiftColor.secondaryText, 8.32),
            ("quietText", SiftColor.quietText, 6.80),
            ("actionGreen", SiftColor.actionGreen, 8.68),
            ("safeText", SiftColor.safeTextColor, 9.22),
            ("reviewText", SiftColor.reviewTextColor, 9.50),
            ("dangerText", SiftColor.dangerTextColor, 7.69),
            ("protectedText", SiftColor.protectedTextColor, 6.80),
            ("infoText", SiftColor.infoTextColor, 8.79),
        ]
        for (name, token, expected) in dark {
            let measured = ratio(token, SiftColor.canvas, dark: true)
            assertRatio(measured, expected, "dark \(name)")
            XCTAssertGreaterThanOrEqual(measured, 4.5, "dark \(name) misses AA for body text")
        }
    }

    func test_theBrightBrandGreenIsAFillAndNotATextColour() {
        // 2.43:1 on white. This assertion is the reason the file exists: if a
        // future change makes the brand green pass as text, the split has
        // collapsed and every `accentText` site would silently become unreadable
        // if it were repointed at the brand green.
        let onWhite = ratio(SiftColor.brandGreen, SiftColor.canvas, dark: false)
        assertRatio(onWhite, 2.43, "brandGreen on white")
        XCTAssertLessThan(onWhite, 3.0,
                          "the brand green is the icon's own colour and must stay a "
                          + "fill token; text uses actionGreen")
    }

    // MARK: - Filled controls

    func test_thePrimaryFillCarriesItsOwnForegroundInBothAppearances() {
        let light = ratio(SiftColor.actionFill, SiftColor.onActionFill, dark: false)
        assertRatio(light, 5.16, "light actionFill / onActionFill")
        XCTAssertGreaterThanOrEqual(light, 4.5)

        let dark = ratio(SiftColor.actionFill, SiftColor.onActionFill, dark: true)
        assertRatio(dark, 7.13, "dark actionFill / onActionFill")
        XCTAssertGreaterThanOrEqual(dark, 4.5,
                                    "dark mode puts dark text on the brighter green; "
                                    + "white on it is 2.43:1")
    }

    // MARK: - Text on a tinted surface

    func test_textKeepsItsContrastOnASelectedRow() {
        let wash = SiftColor.selectedWash
        let lightRow = composited(wash, over: SiftColor.canvas, dark: false)
        let pairs: [(String, Color, Double)] = [
            ("actionGreen on selectedWash", SiftColor.actionGreen, 4.66),
            ("mainText on selectedWash", SiftColor.mainText, 13.81),
            ("quietText on selectedWash", SiftColor.quietText, 4.56),
        ]
        for (label, token, expected) in pairs {
            let measured = ratio(resolved(token, dark: false), lightRow)
            assertRatio(measured, expected, label)
            XCTAssertGreaterThanOrEqual(measured, 4.5, label)
        }

        // The dark wash is translucent, so the row's colour is the composite.
        let darkRow = composited(wash, over: SiftColor.canvas, dark: true)
        for (label, token) in [("mainText", SiftColor.mainText),
                               ("actionGreen", SiftColor.actionGreen),
                               ("quietText", SiftColor.quietText)] {
            let measured = ratio(resolved(token, dark: true), darkRow)
            XCTAssertGreaterThanOrEqual(measured, 4.5,
                                        "dark \(label) on the selected wash is "
                                        + "\(String(format: "%.2f", measured)):1")
        }
    }

    func test_eachSemanticLabelClearsAAOnItsOwnWash() {
        let pairs: [(String, Color, Color)] = [
            ("safe", SiftColor.safeTextColor, SiftColor.safeWash),
            ("review", SiftColor.reviewTextColor, SiftColor.reviewWash),
            ("danger", SiftColor.dangerTextColor, SiftColor.dangerWash),
            ("protected", SiftColor.protectedTextColor, SiftColor.protectedWash),
            ("info", SiftColor.infoTextColor, SiftColor.infoWash),
        ]
        for (name, text, wash) in pairs {
            for dark in [false, true] {
                let surface = composited(wash, over: SiftColor.canvas, dark: dark)
                let measured = ratio(resolved(text, dark: dark), surface)
                XCTAssertGreaterThanOrEqual(measured, 4.5,
                                            "\(name) text on its own wash "
                                            + (dark ? "(dark)" : "(light)")
                                            + " is \(String(format: "%.2f", measured)):1")
            }
        }
    }

    // MARK: - Hexes the specification names

    private func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func part(_ value: CGFloat) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#" + part(srgb.redComponent) + part(srgb.greenComponent) + part(srgb.blueComponent)
    }

    func test_theTokensCarryTheHexesTheDesignPackNames() {
        XCTAssertEqual(hex(resolved(SiftColor.brandGreen, dark: false)), "#00BF63")
        XCTAssertEqual(hex(resolved(SiftColor.brandGold, dark: false)), "#FFBA36")
        XCTAssertEqual(hex(resolved(SiftColor.actionGreen, dark: false)), "#007E46")
        XCTAssertEqual(hex(resolved(SiftColor.actionGreenHover, dark: false)), "#006B3C")
        XCTAssertEqual(hex(resolved(SiftColor.actionFill, dark: false)), "#007E46")
        XCTAssertEqual(hex(resolved(SiftColor.mainText, dark: false)), "#202722")
        XCTAssertEqual(hex(resolved(SiftColor.secondaryText, dark: false)), "#5F6962")
        XCTAssertEqual(hex(resolved(SiftColor.quietText, dark: false)), "#68716B")
        XCTAssertEqual(hex(resolved(SiftColor.quietText, dark: true)), "#96A19A")
        XCTAssertEqual(hex(resolved(SiftColor.divider, dark: false)), "#E5EAE6")
        XCTAssertEqual(hex(resolved(SiftColor.controlFill, dark: false)), "#F6F8F6")
        XCTAssertEqual(hex(resolved(SiftColor.rowHoverFill, dark: false)), "#F2F6F3")
        XCTAssertEqual(hex(resolved(SiftColor.selectedWash, dark: false)), "#E8F7EF")
    }

    // MARK: - The legacy aliases are aliases

    func test_theLegacyRolesPointAtTheV2TokensAndNotAtASecondPalette() {
        // A page that has not been migrated yet must still be green and still be
        // readable, which is only true while these are the same value.
        XCTAssertEqual(hex(resolved(SiftColor.accentText, dark: false)),
                       hex(resolved(SiftColor.actionGreen, dark: false)))
        XCTAssertEqual(hex(resolved(SiftColor.accentFill, dark: false)),
                       hex(resolved(SiftColor.actionFill, dark: false)))
        XCTAssertEqual(hex(resolved(SiftColor.accent, dark: false)),
                       hex(resolved(SiftColor.brandGreen, dark: false)))
        XCTAssertEqual(hex(resolved(SiftColor.accentDeep, dark: false)),
                       hex(resolved(SiftColor.actionFill, dark: false)))
        XCTAssertEqual(hex(resolved(SiftColor.subtleText, dark: false)),
                       hex(resolved(SiftColor.quietText, dark: false)))
    }
}
