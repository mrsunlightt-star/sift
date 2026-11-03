import AppKit
import SwiftUI

/// Design tokens for the whole app.
///
/// The glass language: a pure white canvas (deep neutral in dark mode), one
/// light-blue accent family that carries every interactive meaning, and three
/// levels of translucent surface.
/// Two decisions shape everything downstream. First, colour is assigned by role
/// — accent, safe, review, danger — never by decoration, so a page cannot grow a
/// second palette by accident. Second, controls are rounded rectangles at one
/// radius scale rather than capsules, which is what gives the interface its
/// drawn, instrument-like character; the capsule survives only where it is the
/// literal shape of the thing (progress bars, the product mark's lines).
public enum SiftColor {
    // MARK: - Sift V2 roles
    //
    // The palette comes from the app icon: a green star on a green field, with
    // gold in the star. V2 keeps the icon's own green as *brand* and gives the
    // product a second, darker green for anything a user has to read or press.
    //
    // That split is not a matter of taste. Measured against white, the icon
    // green is 2.43:1 — a filled button carrying white text at that contrast is
    // the defect this file already fixed once for the blue palette, and it would
    // come straight back if one token served both roles. Every ratio below is
    // computed with the WCAG 2.1 relative-luminance formula over these sRGB
    // values, and `Tests/V2PaletteTests.swift` pins them.
    //
    //   brandGreen  #00BF63  2.43 on white · 7.47 on the dark canvas (fill/decoration)
    //   actionGreen #007E46  5.16 on white · #2ECC7A 8.68 on the dark canvas (text, icons)
    //   actionFill  #007E46 + white 5.16 · dark #00BF63 + #0B1E14 7.13
    //   mainText 15.28 · secondaryText 5.70 · quietText 5.04 (light)
    //   mainText 16.51 · secondaryText 8.32 · quietText 6.80 (dark)
    //
    // Dark appearance is not an inversion: the light action green would measure
    // 3.52:1 on `#111713`, below AA, so dark mode carries a brighter green and
    // puts dark text on the fill rather than white.

    /// The icon's own green. Decorative fills, the product mark, a large numeral's
    /// wash — never small text, and never the fill behind white text.
    public static let brandGreen = Color(
        light: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 1),   // #00BF63
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 1)     // #00BF63
    )
    /// The star's gold. The brand mark only: never a warning, a selected row, a
    /// link or a primary button, so brand and semantic meaning stay separate.
    public static let brandGold = Color(
        light: NSColor(srgbRed: 1.0, green: 0.729, blue: 0.212, alpha: 1),   // #FFBA36
        dark: NSColor(srgbRed: 1.0, green: 0.729, blue: 0.212, alpha: 1)     // #FFBA36
    )
    /// Text, icons, links and the selected navigation label: the green a user
    /// reads. 5.16:1 on white, 8.68:1 on the dark canvas.
    public static let actionGreen = Color(
        light: NSColor(srgbRed: 0.0, green: 0.494, blue: 0.275, alpha: 1),   // #007E46
        dark: NSColor(srgbRed: 0.180, green: 0.800, blue: 0.478, alpha: 1)   // #2ECC7A
    )
    /// `actionGreen` under the pointer: 6.63:1 on white.
    public static let actionGreenHover = Color(
        light: NSColor(srgbRed: 0.0, green: 0.420, blue: 0.235, alpha: 1),   // #006B3C
        dark: NSColor(srgbRed: 0.247, green: 0.851, blue: 0.549, alpha: 1)   // #3FD98C
    )
    /// The fill of a control the user presses. Light carries white text (5.16:1);
    /// dark carries `onActionFill` on the brighter green (7.13:1).
    public static let actionFill = Color(
        light: NSColor(srgbRed: 0.0, green: 0.494, blue: 0.275, alpha: 1),   // #007E46
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 1)     // #00BF63
    )
    /// The text laid on `actionFill`. Not "white in both appearances": white on
    /// the dark-mode bright green is 2.43:1.
    public static let onActionFill = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.043, green: 0.118, blue: 0.078, alpha: 1)   // #0B1E14
    )
    /// A selected row or navigation item: a pale green wash, not a saturated
    /// fill, so the row's own text keeps its contrast.
    public static let selectedWash = Color(
        light: NSColor(srgbRed: 0.910, green: 0.969, blue: 0.937, alpha: 1), // #E8F7EF
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 0.18)
    )
    /// The optional boundary around a selected row.
    public static let selectedBorder = Color(
        light: NSColor(srgbRed: 0.725, green: 0.902, blue: 0.800, alpha: 1), // #B9E6CC
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 0.30)
    )
    /// A brand-tinted surface: the mark's own tile, a hero wash.
    public static let brandWash = Color(
        light: NSColor(srgbRed: 0.918, green: 0.973, blue: 0.941, alpha: 1), // #EAF8F0
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 0.14)
    )

    /// Heading and primary content text. 15.28:1 light, 16.51:1 dark.
    public static let mainText = Color(
        light: NSColor(srgbRed: 0.125, green: 0.153, blue: 0.133, alpha: 1), // #202722
        dark: NSColor(srgbRed: 0.945, green: 0.961, blue: 0.949, alpha: 1)   // #F1F5F2
    )
    /// Supporting information: a row's path, a metric's caption. 5.70 / 8.32.
    public static let secondaryText = Color(
        light: NSColor(srgbRed: 0.373, green: 0.412, blue: 0.384, alpha: 1), // #5F6962
        dark: NSColor(srgbRed: 0.659, green: 0.698, blue: 0.667, alpha: 1)   // #A8B2AA
    )
    /// Metadata that still has to be legible. 5.04 / 6.80 — never `.tertiary`,
    /// which measures 1.73:1 on white.
    ///
    /// The dark value was first written as `#8A948E`, which reads 5.80:1 on the
    /// canvas and **4.31:1 on a selected row**: the selected wash is lighter than
    /// the ground, so a quiet grey loses contrast exactly where the row the user
    /// just clicked is. `Tests/V2PaletteTests` measures text against the wash,
    /// not only against the canvas, and that is what caught it.
    public static let quietText = Color(
        light: NSColor(srgbRed: 0.408, green: 0.443, blue: 0.420, alpha: 1), // #68716B
        dark: NSColor(srgbRed: 0.588, green: 0.631, blue: 0.604, alpha: 1)   // #96A19A
    )

    /// The page canvas. Pure white in light appearance — a fixed product
    /// decision, so surface separation comes from whitespace, type and hairlines
    /// rather than a cool grey page.
    public static let canvasSurface = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),        // #FFFFFF
        dark: NSColor(srgbRed: 0.067, green: 0.090, blue: 0.075, alpha: 1)   // #111713
    )
    /// An ordinary content surface, and the fill of an outlined section.
    public static let surfaceColor = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),        // #FFFFFF
        dark: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.106, alpha: 1)   // #191F1B
    )
    /// A raised surface: the summary column's well, a floating header.
    public static let elevatedSurface = Color(
        light: NSColor(srgbRed: 0.996, green: 0.996, blue: 0.996, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.161, blue: 0.137, alpha: 1)   // #202923
    )
    /// A list separator or section rule.
    public static let divider = Color(
        light: NSColor(srgbRed: 0.898, green: 0.918, blue: 0.902, alpha: 1), // #E5EAE6
        dark: NSColor(srgbRed: 0.169, green: 0.204, blue: 0.180, alpha: 1)   // #2B342E
    )
    /// A search field or quiet input well.
    public static let controlFill = Color(
        light: NSColor(srgbRed: 0.965, green: 0.973, blue: 0.965, alpha: 1), // #F6F8F6
        dark: NSColor(srgbRed: 0.125, green: 0.161, blue: 0.137, alpha: 1)   // #202923
    )
    /// Hover feedback on a row or a plain button.
    public static let rowHoverFill = Color(
        light: NSColor(srgbRed: 0.949, green: 0.965, blue: 0.953, alpha: 1), // #F2F6F3
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.06)
    )

    /// Semantic text and icon colours, measured on the canvas in each appearance.
    /// Light: 6.26 / 5.93 / 5.90 / 5.70 / 7.80. Dark: 9.22 / 9.50 / 7.69 / 6.80 / 8.79.
    public static let safeTextColor = Color(
        light: NSColor(srgbRed: 0.157, green: 0.427, blue: 0.255, alpha: 1), // #286D41
        dark: NSColor(srgbRed: 0.310, green: 0.816, blue: 0.494, alpha: 1)   // #4FD07E
    )
    public static let reviewTextColor = Color(
        light: NSColor(srgbRed: 0.541, green: 0.353, blue: 0.0, alpha: 1),   // #8A5A00
        dark: NSColor(srgbRed: 0.910, green: 0.702, blue: 0.290, alpha: 1)   // #E8B34A
    )
    public static let dangerTextColor = Color(
        light: NSColor(srgbRed: 0.698, green: 0.227, blue: 0.227, alpha: 1), // #B23A3A
        dark: NSColor(srgbRed: 0.961, green: 0.541, blue: 0.541, alpha: 1)   // #F58A8A
    )
    public static let protectedTextColor = Color(
        light: NSColor(srgbRed: 0.373, green: 0.412, blue: 0.384, alpha: 1), // #5F6962
        dark: NSColor(srgbRed: 0.588, green: 0.631, blue: 0.604, alpha: 1)   // #96A19A
    )
    public static let infoTextColor = Color(
        light: NSColor(srgbRed: 0.275, green: 0.337, blue: 0.294, alpha: 1), // #46564B
        dark: NSColor(srgbRed: 0.663, green: 0.722, blue: 0.682, alpha: 1)   // #A9B8AE
    )

    /// The wash behind a semantic label. Each is the light-tint counterpart of
    /// its text colour, so a badge keeps one meaning in two layers.
    public static let safeWash = Color(
        light: NSColor(srgbRed: 0.918, green: 0.965, blue: 0.933, alpha: 1), // #EAF6EE
        dark: NSColor(srgbRed: 0.310, green: 0.816, blue: 0.494, alpha: 0.14)
    )
    public static let reviewWash = Color(
        light: NSColor(srgbRed: 1.0, green: 0.961, blue: 0.890, alpha: 1),   // #FFF5E3
        dark: NSColor(srgbRed: 0.910, green: 0.702, blue: 0.290, alpha: 0.14)
    )
    public static let dangerWash = Color(
        light: NSColor(srgbRed: 0.988, green: 0.933, blue: 0.933, alpha: 1), // #FCEEEE
        dark: NSColor(srgbRed: 0.961, green: 0.541, blue: 0.541, alpha: 0.14)
    )
    public static let protectedWash = Color(
        light: NSColor(srgbRed: 0.953, green: 0.961, blue: 0.953, alpha: 1), // #F3F5F3
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.06)
    )
    public static let infoWash = Color(
        light: NSColor(srgbRed: 0.953, green: 0.965, blue: 0.953, alpha: 1), // #F3F6F3
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.05)
    )

    // MARK: - Legacy roles
    //
    // Kept so every call site compiles while pages migrate in phases, and
    // repointed at the V2 roles so an unmigrated view is *green already* rather
    // than blue-until-touched. Each is a genuine alias, not a second palette:
    // delete one only after a repo-wide search (V2 plan, step 5).

    /// Legacy fill/decoration accent. Decorative only — the foreground role is
    /// `accentText`, and `DesignSystemRoleTests` refuses this token as a
    /// foreground colour because it is 2.43:1 on white.
    public static let accent = brandGreen
    /// The bright end of a decorative gradient.
    public static let accentBright = Color(
        light: NSColor(srgbRed: 0.200, green: 0.800, blue: 0.502, alpha: 1), // #33CC80
        dark: NSColor(srgbRed: 0.247, green: 0.851, blue: 0.549, alpha: 1)   // #3FD98C
    )
    /// Legacy pressed fill. Same value as `actionFill`.
    public static let accentDeep = actionFill
    /// Completed safely, or a `safe` risk level, as a *fill*: a dot, a wash, a bar.
    public static let safe = safeTextColor
    /// Needs the user's attention: `review` risk, space pressure.
    public static let review = reviewTextColor
    /// Never acted on: `protected` risk.
    public static let danger = dangerTextColor
    /// Secondary information, unavailable space, disabled states.
    public static let neutral = secondaryText

    // MARK: - Text roles
    //
    // One token per role, never one accent for four jobs. The split survives from
    // the blue palette this replaces because the reason for it does: a fill that
    // carries decoration and a colour a user reads have different contrast
    // requirements, and the V2 green has the same shape of problem (2.43:1 for
    // the brand green as text). These are aliases of the V2 roles above.

    /// Text, icons and links. Never the fill of a control.
    public static let accentText = actionGreen
    /// The fill of a pressed control: a primary button, a selected toggle.
    public static let accentFill = actionFill
    /// The text laid on `accentFill`.
    public static let onAccent = onActionFill
    /// `safe` as text on the canvas.
    public static let safeText = safeTextColor
    /// `review` as text on the canvas.
    public static let reviewText = reviewTextColor
    /// `danger` as text on the canvas.
    public static let dangerText = dangerTextColor
    /// Quiet text that still has to be read: the "read only, never uploaded"
    /// sentence and other trust copy.
    public static let subtleText = quietText

    /// The window canvas.
    ///
    /// V2 is flat: pure white in light appearance, and a near-black green-cast
    /// ground in dark. There is no ambient wash for a glass layer to sit on,
    /// because ordinary page content no longer has glass (V2 §6).
    public static let canvas = canvasSurface
    /// The rail's base fill. Opaque, so the sidebar is a surface and not a pane.
    public static let baseGlass = surfaceColor
    /// The card surface fill. Opaque: a card is a deliberate grouping, not a
    /// translucent layer over a glow that no longer exists.
    public static let cardGlass = surfaceColor
    /// The floating surface: confirmations, sheets, popovers. The one place a
    /// material may still be used is the platform's own sheet chrome.
    public static let floatingGlass = elevatedSurface
    /// Hairline around a surface.
    public static let glassBorder = divider
    /// V2 removes the top-edge glass highlight. The token stays for the
    /// components that still reference it, and renders nothing.
    public static let glassHighlight = Color.clear
    /// A selected row or navigation item.
    public static let selectedFill = selectedWash
    /// Hover feedback on a row or a plain button.
    public static let hoverFill = rowHoverFill
    /// A quiet well: search fields, sort menus, static capsules that hold text.
    public static let subtleFill = controlFill

    /// The opaque stand-ins for the two surface levels. Kept because call sites
    /// already switch on "Reduce transparency"; with V2 the surfaces are opaque
    /// either way, so both now answer with the same values.
    public static let cardOpaque = surfaceColor
    public static let floatOpaque = elevatedSurface

    /// Window background, kept for pages that predate the canvas.
    public static let windowBackground = canvas
    /// Panel surface sitting on the window background.
    public static let panel = surfaceColor
    /// A raised surface inside a panel.
    public static let raised = elevatedSurface
    /// Hairline border used around panels and tiles.
    public static let border = divider

    /// Chart segment colours.
    ///
    /// A storage map paints large fields, so eight saturated hues turn the page
    /// into a legend. These are the V2 greens, sages, a muted gold and two
    /// neutrals: the map reads as one brand family with enough separation to
    /// tell its regions apart, and the order is fixed so a category keeps its
    /// identity between the map and the list. A palette index is written into
    /// the category list — append, never insert.
    public static let categoryPalette: [Color] = [
        Color(light: NSColor(srgbRed: 0.0, green: 0.494, blue: 0.275, alpha: 1),     // #007E46 action
              dark: NSColor(srgbRed: 0.180, green: 0.800, blue: 0.478, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.243, green: 0.545, blue: 0.361, alpha: 1),   // #3E8B5C
              dark: NSColor(srgbRed: 0.435, green: 0.749, blue: 0.545, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.541, green: 0.353, blue: 0.0, alpha: 1),     // #8A5A00 gold
              dark: NSColor(srgbRed: 0.910, green: 0.702, blue: 0.290, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.325, green: 0.478, blue: 0.412, alpha: 1),   // sage slate
              dark: NSColor(srgbRed: 0.549, green: 0.690, blue: 0.616, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.176, green: 0.400, blue: 0.361, alpha: 1),   // deep pine
              dark: NSColor(srgbRed: 0.361, green: 0.667, blue: 0.588, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.729, green: 0.502, blue: 0.153, alpha: 1),   // amber
              dark: NSColor(srgbRed: 0.910, green: 0.749, blue: 0.435, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.435, green: 0.514, blue: 0.447, alpha: 1),   // warm grey
              dark: NSColor(srgbRed: 0.616, green: 0.671, blue: 0.627, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.267, green: 0.416, blue: 0.302, alpha: 1),   // moss
              dark: NSColor(srgbRed: 0.478, green: 0.643, blue: 0.518, alpha: 1)),
        // Appended, never inserted.
        Color(light: NSColor(srgbRed: 0.404, green: 0.478, blue: 0.310, alpha: 1),
              dark: NSColor(srgbRed: 0.596, green: 0.729, blue: 0.435, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.376, green: 0.420, blue: 0.612, alpha: 1),
              dark: NSColor(srgbRed: 0.545, green: 0.588, blue: 0.812, alpha: 1)),
    ]

    /// Colour for a risk level, for a *fill*: a dot, a badge wash, a bar.
    ///
    /// Colour alone never carries meaning: every use of this is paired with an
    /// icon and a word, as §11.4 requires. Text laid on the canvas uses
    /// `textColor(for:)` instead — these values are 3.56–4.38:1 on white.
    public static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .safe: safe
        case .review: review
        case .protected: danger
        }
    }

    /// Colour for a risk level, for *text*: every one of these reaches 4.5:1
    /// on the canvas, which the fill values do not.
    public static func textColor(for risk: RiskLevel) -> Color {
        switch risk {
        case .safe: safeText
        case .review: reviewText
        case .protected: dangerText
        }
    }

    /// Colour for a scan or cleanup phase, for a *fill*.
    public static func color(for phase: ScanPhase) -> Color {
        switch phase {
        case .ready: safe
        case .partial, .cancelled: review
        case .failed: danger
        default: accent
        }
    }

    /// Colour for a scan or cleanup phase, for *text*.
    public static func textColor(for phase: ScanPhase) -> Color {
        switch phase {
        case .ready: safeText
        case .partial, .cancelled: reviewText
        case .failed: dangerText
        default: accentText
        }
    }
}

/// A colour that resolves differently in light and dark appearance.
private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// A risk level re-exported for the design system without importing Core.
///
/// Keeping this enum here lets `Shared` render badges and rows without a
/// dependency on the domain layer.
public enum RiskLevel: String, Sendable, CaseIterable, Codable {
    case safe
    case review
    case protected

    /// Localisation key for the short label.
    public var labelKey: LocalizationKey {
        switch self {
        case .safe: .riskSafeShort
        case .review: .riskReviewShort
        case .protected: .riskProtectedShort
        }
    }

    /// Localisation key for the explanatory sentence.
    public var detailKey: LocalizationKey {
        switch self {
        case .safe: .riskSafeDetail
        case .review: .riskReviewDetail
        case .protected: .riskProtectedDetail
        }
    }

    /// SF Symbol carrying the same meaning as the colour.
    public var symbolName: String {
        switch self {
        case .safe: "checkmark"
        case .review: "exclamationmark"
        case .protected: "lock.fill"
        }
    }

    /// Only `safe` and `review` may enter a deletion queue (§5.2).
    public var isCleanable: Bool {
        self != .protected
    }

    /// Only `safe` items are selected when a result list first appears.
    public var isSelectedByDefault: Bool {
        self == .safe
    }
}

/// Scan lifecycle phases (§5.1).
public enum ScanPhase: String, Sendable, CaseIterable, Codable {
    case idle
    case preparing
    case scanning
    case indexing
    case ready
    case cancelled
    case partial
    case failed

    public var labelKey: LocalizationKey {
        switch self {
        case .idle: .scanPhaseIdle
        case .preparing: .scanPhasePreparing
        case .scanning: .scanPhaseScanning
        case .indexing: .scanPhaseIndexing
        case .ready: .scanPhaseReady
        case .cancelled: .scanPhaseCancelled
        case .partial: .scanPhasePartial
        case .failed: .scanPhaseFailed
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: "magnifyingglass"
        case .preparing: "folder.badge.gearshape"
        case .scanning: "magnifyingglass.circle"
        case .indexing: "chart.bar.doc.horizontal"
        case .ready: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .partial: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        }
    }

    /// True while work is in flight, which is when cancelling is offered.
    public var isRunning: Bool {
        switch self {
        case .preparing, .scanning, .indexing: true
        default: false
        }
    }

    /// True when the phase produced a result the user can act on.
    public var hasResults: Bool {
        self == .ready || self == .partial
    }

    /// Where the phase sits in the four-stage run, for a stage indicator.
    ///
    /// The engine reports a phase, not a percentage; this maps the phase to its
    /// step so the interface can say "step 2 of 4" without inventing a number the
    /// scan did not measure.
    public var step: Int? {
        switch self {
        case .preparing: 1
        case .scanning: 2
        case .indexing: 3
        case .ready, .partial, .cancelled, .failed: 4
        case .idle: nil
        }
    }

    /// The number of stages a run passes through.
    public static let stepCount = 4
}

/// Spacing, radius and size tokens.
///
/// The radius scale is two steps tighter than the one it replaced: the same
/// hierarchy (control, group, card, hero) with a crisper, more drawn edge.
public enum SiftMetrics {
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24
    public static let spacingXXL: CGFloat = 32

    public static let cornerRadiusS: CGFloat = 6
    public static let cornerRadiusM: CGFloat = 10
    public static let cornerRadiusL: CGFloat = 12
    /// V2 caps content-group corners at 12: a 20 pt corner on every card made the
    /// product look like a widget board (01 §5).
    public static let cornerRadiusXL: CGFloat = 12

    /// The corner radius of a pressed control: buttons, chips, fields.
    public static let controlCornerRadius: CGFloat = 8

    /// Minimum click target (§11.4).
    public static let minimumHitTarget: CGFloat = 44

    /// The standard control heights, so a page never invents its own.
    public static let buttonHeight: CGFloat = 40
    public static let chipHeight: CGFloat = 32
    public static let fieldHeight: CGFloat = 34

    /// The hairline stroke: half a point, so a border reads as a hairline rather
    /// than a drawn frame.
    public static let hairline: CGFloat = 0.5

    /// The sidebar: 190 pt of icon-left, label-right rows (05 §5).
    public static let sidebarWidth: CGFloat = 190
    public static let sidebarRowHeight: CGFloat = 44
    public static let sidebarRowRadius: CGFloat = 8
    public static let sidebarRowHorizontalPadding: CGFloat = 12
    public static let sidebarIconSize: CGFloat = 17
    public static let sidebarIconGap: CGFloat = 10

    /// The retired vertical icon rail. Nothing new may use these: they are the
    /// geometry the shell converts away from, kept until the last call site goes.
    public static let railWidth: CGFloat = 112
    public static let railItemWidth: CGFloat = 76
    public static let railItemHeight: CGFloat = 58

    /// The page's outer margins and columns.
    public static let pagePadding: CGFloat = 28
    public static let pageSpacing: CGFloat = 20
    /// A dense list row (V2: 48-52 single line) and a two-line row (54-60).
    public static let rowHeight: CGFloat = 52
    public static let rowHeightTwoLine: CGFloat = 56
    public static let iconTileSize: CGFloat = 32
    public static let panelBorderWidth: CGFloat = 1

    public static let contentWidthWide: CGFloat = 1180
    public static let contentWidthStandard: CGFloat = 1080
    public static let contentWidthForm: CGFloat = 760

    /// The right-hand summary column. V2's scan inspector is 260-280 pt, and it
    /// narrows rather than staying fixed when the window is small (05 §5).
    public static let summaryColumnWidth: CGFloat = 272
    public static let summaryColumnMinWidth: CGFloat = 240

    /// Height a result list may grow to before it scrolls.
}

/// Typography built on the system font, with no external typefaces (§11.1).
///
/// The V2 ladder is four sizes and no more: 12 supporting, 14 reading, 16
/// section, 28 page title, with the metric at 40-44 and nothing between 16 and
/// 28. A page title that has to compete with a section heading has the wrong
/// size; so does a caption that is the same size as body text, which is what the
/// old "13 for everything" ladder produced (01 §4: body and supporting text must
/// differ in size *and* emphasis).
///
/// Weight climbs only one step per role — regular, medium, semibold — and every
/// value that can change is rendered with `.monospacedDigit()` at the call site
/// so a counting scan does not jitter.
public enum SiftFont {
    /// Every size is multiplied by `SiftTypeScale.current`. macOS has no system
    /// text-size setting an app can read, so this is the product's own answer to
    /// "I cannot read this": three steps, applied at the root and persisted. The
    /// enum stays a computed property rather than a `let` for exactly that
    /// reason — a stored font would freeze the scale at launch.
    ///
    /// The ladder: page title 28 · primary metric 42 · section heading 16 ·
    /// secondary heading 14 medium · body 14 · supporting copy 12 · metadata 11.
    public static var pageTitle: Font { scaled(28, .semibold) }
    public static var metricPrimary: Font { scaled(42, .semibold) }
    public static var sectionHeading: Font { scaled(16, .semibold) }
    public static var secondaryHeading: Font { scaled(14, .medium) }
    public static var supporting: Font { scaled(12, .regular) }
    public static var metadata: Font { scaled(11, .regular) }

    /// Legacy names, repointed at the V2 ladder so an unmigrated view is already
    /// on the new scale. `display` and `title` were two sizes for one job (a page
    /// or sheet heading); both now answer with the 28 pt title.
    public static var display: Font { pageTitle }
    public static var title: Font { pageTitle }
    public static var sectionTitle: Font { sectionHeading }
    public static var body: Font { scaled(14, .regular) }
    public static var bodyEmphasis: Font { secondaryHeading }
    public static var caption: Font { supporting }
    public static var eyebrow: Font { scaled(12, .semibold) }
    public static var metric: Font { metricPrimary }
    public static var metricLarge: Font { metricPrimary }
    public static var heroMetric: Font { scaled(44, .semibold) }
    public static var heroUnit: Font { scaled(20, .semibold) }
    public static var badge: Font { metadata }
    public static var railLabel: Font { scaled(14, .medium) }
    public static var monospacedNumber: Font {
        .system(size: (14 * SiftTypeScale.current.multiplier).rounded(), design: .monospaced)
    }
    /// A size a row prints in the same monospaced digits as its body text.
    public static var monospacedEmphasis: Font {
        .system(size: (14 * SiftTypeScale.current.multiplier).rounded(),
                weight: .medium, design: .monospaced)
    }

    private static func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: (size * SiftTypeScale.current.multiplier).rounded(), weight: weight)
    }
}

/// The interface's own type scale.
///
/// A process-wide value rather than an environment value: `SiftFont` is read from
/// three hundred call sites, and threading a scale through every one of them
/// would have been a refactor of the whole UI for a setting with three states.
/// The root re-renders on change (`RootShellView` keys its subtree on the stored
/// value), which is what makes the new scale take effect everywhere at once.
public enum SiftTypeScale {
    public enum Step: String, Sendable, CaseIterable {
        case small
        case standard
        case large

        public var multiplier: CGFloat {
            switch self {
            case .small: 0.9
            case .standard: 1.0
            case .large: 1.15
            }
        }
    }

    /// Standard by default; the settings page sets it at launch and on change.
    ///
    /// Lock-backed rather than `@MainActor`: `SiftFont` is read while building a
    /// view, from PDF report drawing and from self-test code, and pinning the
    /// whole type ladder to the main actor to satisfy Swift 6 would have been a
    /// larger change than the setting. The value changes on a user action, never
    /// in a loop, so the lock is uncontended in practice.
    nonisolated(unsafe) private static var stored: Step = .standard
    private static let lock = NSLock()

    public static var current: Step {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

/// The named text styles, each pairing a font with the tracking that belongs to
/// it, so a call site cannot set the display size and forget the tracking.
///
/// `SiftFont` stays available for the many call sites that apply a font alone;
/// new code and the components use these so the typographic details travel
/// together.
public enum SiftTextStyle {
    case display, title, sectionTitle
    case body, bodyEmphasis, caption, eyebrow
    case metric, metricLarge, heroMetric, heroUnit
    case badge, railLabel, monospacedNumber

    public var font: Font {
        switch self {
        case .display: SiftFont.display
        case .title: SiftFont.title
        case .sectionTitle: SiftFont.sectionTitle
        case .body: SiftFont.body
        case .bodyEmphasis: SiftFont.bodyEmphasis
        case .caption: SiftFont.caption
        case .eyebrow: SiftFont.eyebrow
        case .metric: SiftFont.metric
        case .metricLarge: SiftFont.metricLarge
        case .heroMetric: SiftFont.heroMetric
        case .heroUnit: SiftFont.heroUnit
        case .badge: SiftFont.badge
        case .railLabel: SiftFont.railLabel
        case .monospacedNumber: SiftFont.monospacedNumber
        }
    }

    public var tracking: CGFloat {
        switch self {
        case .display: -0.6
        case .title: -0.3
        case .sectionTitle: -0.1
        case .metric: -0.3
        case .metricLarge: -0.6
        case .heroMetric: -1.5
        case .eyebrow: 0.8
        default: 0
        }
    }
}

public extension View {
    /// Applies a named text style: font and tracking together.
    func siftFont(_ style: SiftTextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }
}

/// Animation curves, all spring-driven and all respectful of Reduce Motion.
///
/// The set is small on purpose: one snappy curve for things the user directly
/// moved, one gentle curve for things the system changed, one settle curve for
/// layout that re-flows, and the two special cases (press and scan loop). A page
/// that needs a different-feeling animation is usually describing a different
/// meaning, not a different duration.
public enum SiftMotion {
    /// A view appearing: opacity 0 → 1, offset 10 → 0.
    public static let appear = Animation.spring(response: 0.38, dampingFraction: 0.85)
    /// A press: scale 0.97.
    public static let press = Animation.spring(response: 0.20, dampingFraction: 0.70)
    /// The progress ring's stroke and other value changes that report work.
    public static let progress = Animation.spring(response: 0.50, dampingFraction: 0.90)
    /// A page change: a short crossfade with a slight rise.
    public static let page = Animation.easeInOut(duration: 0.20)
    /// A hover highlight. 0.12 is the pointer-feedback value macOS uses; 0.16
    /// read as lag on a row the user is sweeping across.
    public static let hover = Animation.easeOut(duration: 0.12)
    /// The scan progress indicator, which loops while scanning. Kept for the
    /// indeterminate spinner the ring draws itself; nothing else may loop.
    public static let scanning = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// A scan phase changing — preparing → scanning → indexing → ready.
    ///
    /// This is the state change the product most needs to read as one event, and
    /// it used to be a hard text swap while the ring kept spinning. 0.28 sits in
    /// macOS's state-change band and is long enough to be noticed.
    public static let phase = Animation.smooth(duration: 0.28)
    /// A group of rows opening or closing. A layout re-flow: no bounce.
    public static let expand = Animation.smooth(duration: 0.24)
    /// A checkbox, chip or row toggling. Snappy with a trace of bounce.
    public static let toggle = Animation.snappy(duration: 0.18, extraBounce: 0.06)
    /// The result replacing the running scan: the product's one arrival.
    public static let reveal = Animation.smooth(duration: 0.30)

    /// Short transitions used by rows and checkboxes.
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Panel or sheet presentation.
    public static let panel = Animation.spring(response: 0.36, dampingFraction: 0.88)
    /// A sheet the system presents, which has its own timeline.
    public static let sheet = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Layout that re-flows: bars resizing, groups expanding, the treemap.
    public static let settle = Animation.spring(response: 0.45, dampingFraction: 0.95)
    /// A small element celebrating a state change: a checkmark dropping in.
    public static let springy = Animation.spring(response: 0.30, dampingFraction: 0.60)

    /// Returns an animation only when the user has not asked for reduced motion.
    public static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The app's motion preference, combined with the system's accessibility
/// setting at the root of the view tree.
///
/// SwiftUI's `accessibilityReduceMotion` is read-only; this key lets the settings
/// page's own switch participate without every component reading two values.
private struct SiftReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var siftReduceMotion: Bool {
        get { self[SiftReduceMotionKey.self] }
        set { self[SiftReduceMotionKey.self] = newValue }
    }
}

/// The three glass levels from the design language.
public enum SiftSurface: Sendable {
    /// Navigation rail and dividers: thin, tinted, least presence.
    case base
    /// The main content cards.
    case card
    /// Confirmations, selected rows and anything above the page.
    case floating

    var material: Material {
        switch self {
        case .base: .ultraThinMaterial
        case .card: .thinMaterial
        case .floating: .regularMaterial
        }
    }

    var tint: Color {
        switch self {
        case .base: SiftColor.baseGlass
        case .card: SiftColor.cardGlass
        case .floating: SiftColor.floatingGlass
        }
    }

    /// What the surface is filled with when the user has asked the system to
    /// reduce transparency. Glass has no fallback of its own: three layers of
    /// `.ultraThinMaterial` stay translucent whatever the setting says, which is
    /// exactly the case the accessibility option exists for.
    var opaqueFill: Color {
        switch self {
        case .base: SiftColor.canvas
        case .card: SiftColor.cardOpaque
        case .floating: SiftColor.floatOpaque
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .base: 0
        case .card: 14
        case .floating: 24
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .base: 0
        case .card: 0.10
        case .floating: 0.18
        }
    }
}
