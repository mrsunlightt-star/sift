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
    /// Primary action colour, used for links, selected states, icons and tints.
    /// Jade, fixed rather than the system accent, so a user's accent-colour
    /// choice cannot make the primary action blend into a category tint. The
    /// dark variant is luminous because text and icons need the brightness; the
    /// filled-control colour is `accentDeep`, which stays deep enough to carry
    /// white text in both appearances.
    public static let accent = Color(
        light: NSColor(srgbRed: 0.0, green: 0.682, blue: 0.925, alpha: 1),
        dark: NSColor(srgbRed: 0.357, green: 0.776, blue: 0.961, alpha: 1)
    )
    /// The bright end of decorative jade gradients (the product mark, hero
    /// washes, icon tiles). Too light to carry white text; that is `accentDeep`.
    public static let accentBright = Color(
        light: NSColor(srgbRed: 0.333, green: 0.769, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.494, green: 0.824, blue: 0.973, alpha: 1)
    )
    /// The fill of a control the user presses: primary buttons and selected
    /// toggles. The product's bright blue, #00AEEC — white text on it is the
    /// reference button's own pairing. Other accent roles (links, icons,
    /// selected states) keep the jade `accent`; only the pressed fill moved.
    public static let accentDeep = Color(
        light: NSColor(srgbRed: 0.0, green: 0.604, blue: 0.851, alpha: 1),
        dark: NSColor(srgbRed: 0.0, green: 0.682, blue: 0.925, alpha: 1)
    )
    /// Completed safely, or a `safe` risk level. A grass green, kept clearly
    /// yellower than the jade accent so the two never read as the same colour.
    public static let safe = Color(
        light: NSColor(srgbRed: 0.184, green: 0.561, blue: 0.306, alpha: 1),
        dark: NSColor(srgbRed: 0.306, green: 0.796, blue: 0.431, alpha: 1)
    )
    /// Needs the user's attention: `review` risk, space pressure.
    public static let review = Color(
        light: NSColor(srgbRed: 0.761, green: 0.463, blue: 0.039, alpha: 1),
        dark: NSColor(srgbRed: 0.937, green: 0.698, blue: 0.290, alpha: 1)
    )
    /// Never acted on: `protected` risk.
    public static let danger = Color(
        light: NSColor(srgbRed: 0.820, green: 0.290, blue: 0.290, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.431, blue: 0.439, alpha: 1)
    )
    /// Secondary information, unavailable space, disabled states.
    public static let neutral = Color(nsColor: .secondaryLabelColor)

    /// The window canvas the glass sits on.
    ///
    /// Light mode is warm porcelain rather than the cool lavender it replaced;
    /// dark mode is near-black with the faintest jade cast, so the ambient glow
    /// has something to breathe against.
    public static let canvas = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.055, green: 0.063, blue: 0.075, alpha: 1)
    )
    /// The rail's base glass tint.
    public static let baseGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.50),
        dark: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.14, alpha: 0.55)
    )
    /// The card surface tint, laid over the material.
    public static let cardGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.60),
        dark: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.17, alpha: 0.62)
    )
    /// The floating surface tint: confirmations, selected rows, popovers.
    public static let floatingGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.82),
        dark: NSColor(srgbRed: 0.17, green: 0.19, blue: 0.22, alpha: 0.88)
    )
    /// Hairline around a glass surface.
    public static let glassBorder = Color(
        light: NSColor(srgbRed: 0.05, green: 0.10, blue: 0.16, alpha: 0.10),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.10)
    )
    /// The top-edge highlight that makes glass look lit rather than painted.
    public static let glassHighlight = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.90),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.13)
    )
    /// A selected row or navigation item.
    public static let selectedFill = Color(
        light: NSColor(srgbRed: 0.0, green: 0.682, blue: 0.925, alpha: 0.11),
        dark: NSColor(srgbRed: 0.357, green: 0.776, blue: 0.961, alpha: 0.15)
    )
    /// Hover feedback on a row or a plain button.
    public static let hoverFill = Color(
        light: NSColor(srgbRed: 0.05, green: 0.10, blue: 0.16, alpha: 0.08),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.09)
    )
    /// A quiet well: search fields, sort menus, static capsules that hold text.
    /// Appearance-adaptive so no call site needs to guess `Color.white.opacity`
    /// again — that guess is what made dark mode read as frost on glass.
    public static let subtleFill = Color(
        light: NSColor(srgbRed: 0.05, green: 0.10, blue: 0.16, alpha: 0.045),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.05)
    )

    /// Window background, kept for pages that predate the canvas.
    public static let windowBackground = canvas
    /// Panel surface sitting on the window background.
    public static let panel = cardGlass
    /// A raised surface inside a panel.
    public static let raised = floatingGlass
    /// Hairline border used around panels and tiles.
    public static let border = glassBorder

    /// Chart segment colours.
    ///
    /// Muted, low-saturation versions of the accent palette: a storage map uses
    /// large fields of colour, and eight fully saturated hues turn the page into
    /// a warning banner. Jade leads, and the order is fixed so a category keeps
    /// its identity between the map and the list.
    public static let categoryPalette: [Color] = [
        Color(light: NSColor(srgbRed: 0.0, green: 0.598, blue: 0.831, alpha: 1),
              dark: NSColor(srgbRed: 0.357, green: 0.776, blue: 0.961, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.306, green: 0.620, blue: 0.322, alpha: 1),
              dark: NSColor(srgbRed: 0.400, green: 0.784, blue: 0.451, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.122, green: 0.561, blue: 0.647, alpha: 1),
              dark: NSColor(srgbRed: 0.247, green: 0.714, blue: 0.800, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.243, green: 0.482, blue: 0.776, alpha: 1),
              dark: NSColor(srgbRed: 0.435, green: 0.639, blue: 0.910, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.761, green: 0.463, blue: 0.039, alpha: 1),
              dark: NSColor(srgbRed: 0.937, green: 0.698, blue: 0.290, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.761, green: 0.369, blue: 0.494, alpha: 1),
              dark: NSColor(srgbRed: 0.910, green: 0.518, blue: 0.624, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.490, green: 0.373, blue: 0.722, alpha: 1),
              dark: NSColor(srgbRed: 0.643, green: 0.545, blue: 0.878, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.431, green: 0.463, blue: 0.506, alpha: 1),
              dark: NSColor(srgbRed: 0.592, green: 0.627, blue: 0.671, alpha: 1)),
    ]

    /// Colour for a risk level.
    ///
    /// Colour alone never carries meaning: every use of this is paired with an
    /// icon and a word, as §11.4 requires.
    public static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .safe: safe
        case .review: review
        case .protected: danger
        }
    }

    /// Colour for a scan or cleanup phase.
    public static func color(for phase: ScanPhase) -> Color {
        switch phase {
        case .ready: safe
        case .partial, .cancelled: review
        case .failed: danger
        default: accent
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
    /// 4 pt base unit.
    public static let unit: CGFloat = 4
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24
    public static let spacingXXL: CGFloat = 32

    public static let cornerRadiusS: CGFloat = 6
    public static let cornerRadiusM: CGFloat = 10
    public static let cornerRadiusL: CGFloat = 14
    public static let cornerRadiusXL: CGFloat = 20

    /// The corner radius of a pressed control: buttons, chips, fields.
    public static let controlCornerRadius: CGFloat = 12

    /// Minimum click target (§11.4).
    public static let minimumHitTarget: CGFloat = 44

    /// The standard control heights, so a page never invents its own.
    public static let buttonHeight: CGFloat = 40
    public static let chipHeight: CGFloat = 30
    public static let fieldHeight: CGFloat = 34

    /// The hairline stroke: half a point, so a border reads as glass edge
    /// rather than a drawn frame.
    public static let hairline: CGFloat = 0.5

    /// The icon rail. 112 pt holds a 76 pt item with the glyph and its label.
    public static let railWidth: CGFloat = 112
    public static let railItemWidth: CGFloat = 76
    public static let railItemHeight: CGFloat = 58

    /// The page's outer margins and columns.
    public static let pagePadding: CGFloat = 28
    public static let pageSpacing: CGFloat = 20
    public static let sidebarWidth: CGFloat = railWidth
    public static let rowHeight: CGFloat = 44
    public static let iconTileSize: CGFloat = 32
    public static let panelBorderWidth: CGFloat = 1

    public static let contentWidthWide: CGFloat = 1180
    public static let contentWidthStandard: CGFloat = 1080
    public static let contentWidthForm: CGFloat = 760

    /// The right-hand summary column on the overview, scan and storage pages.
    public static let summaryColumnWidth: CGFloat = 330

    /// Height a result list may grow to before it scrolls.
    public static let resultListMaxHeight: CGFloat = 320
}

/// Typography built on the system font, with no external typefaces (§11.1).
///
/// The scale's character comes from three disciplines. Large sizes pull their
/// tracking in (-0.6 on display, -1.5 on the hero numeral) so headings read as
/// composed rather than loud. Weight climbs only one step per role — regular,
/// medium, semibold, and bold reserved for the numerals that are the page's
/// subject. Every value that can change is rendered with `.monospacedDigit()` at
/// the call site so a counting scan does not jitter.
public enum SiftFont {
    /// The type ladder is four sizes — 13 reading, 15 section, 20 title, 32
    /// display — and every distinction below them is weight, grey and spacing,
    /// never a fifth size.
    public static let display = Font.system(size: 32, weight: .semibold)
    public static let title = Font.system(size: 20, weight: .semibold)
    public static let sectionTitle = Font.system(size: 15, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 13, weight: .regular)
    public static let eyebrow = Font.system(size: 13, weight: .semibold)
    public static let metric = Font.system(size: 32, weight: .semibold)
    public static let metricLarge = Font.system(size: 32, weight: .bold)
    public static let heroMetric = Font.system(size: 32, weight: .bold)
    public static let heroUnit = Font.system(size: 20, weight: .semibold)
    public static let badge = Font.system(size: 13, weight: .semibold)
    public static let railLabel = Font.system(size: 13, weight: .medium)
    public static let monospacedNumber = Font.system(size: 13, design: .monospaced)
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
    /// A hover highlight.
    public static let hover = Animation.easeOut(duration: 0.15)
    /// The scan progress indicator, which loops while scanning.
    public static let scanning = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// Short transitions used by rows and checkboxes.
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Panel or sheet presentation.
    public static let panel = Animation.spring(response: 0.36, dampingFraction: 0.88)
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
