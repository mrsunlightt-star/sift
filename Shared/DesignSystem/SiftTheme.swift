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

    // MARK: - Text roles
    //
    // The bright jade family is a *fill* palette: #00AEEC on white is 2.54:1,
    // which fails AA for the 13 pt text that carries every link, eyebrow and
    // selected chip in the product. Colour is therefore split by role — a fill
    // token and a text token per meaning — and the text tokens below are the
    // darkened variants that reach 4.5:1 on the canvas.
    //
    // Measured with the WCAG 2.1 relative-luminance formula over sRGB values
    // (the numbers are in the commit message that introduced them):
    //   accentText light #007FAC 4.54:1 · accentFill light #007EB2 + white 4.52:1
    //   safeText 4.53 · reviewText 4.51 · dangerText 4.54
    // Dark mode keeps the luminous variants, which already measure 6.99–10.10:1.

    /// Text, icons and links. Never the fill of a control.
    public static let accentText = Color(
        light: NSColor(srgbRed: 0.0, green: 0.498, blue: 0.675, alpha: 1),   // #007FAC
        dark: NSColor(srgbRed: 0.357, green: 0.776, blue: 0.961, alpha: 1)
    )
    /// The fill of a pressed control: a primary button, a selected toggle.
    /// Darker than `accentDeep` so that white text on it reaches 4.52:1.
    public static let accentFill = Color(
        light: NSColor(srgbRed: 0.0, green: 0.494, blue: 0.698, alpha: 1),   // #007EB2
        dark: NSColor(srgbRed: 0.0, green: 0.682, blue: 0.925, alpha: 1)
    )
    /// The text laid on `accentFill`. White on the bright dark-mode jade is only
    /// 2.54:1, so dark mode flips to near-black (8.26:1) instead of whitening.
    public static let onAccent = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.02, green: 0.10, blue: 0.13, alpha: 1)
    )
    /// `safe` as text on the canvas.
    public static let safeText = Color(
        light: NSColor(srgbRed: 0.173, green: 0.525, blue: 0.286, alpha: 1),  // #2C8649
        dark: NSColor(srgbRed: 0.306, green: 0.796, blue: 0.431, alpha: 1)
    )
    /// `review` as text on the canvas.
    public static let reviewText = Color(
        light: NSColor(srgbRed: 0.667, green: 0.404, blue: 0.035, alpha: 1),  // #AA6709
        dark: NSColor(srgbRed: 0.937, green: 0.698, blue: 0.290, alpha: 1)
    )
    /// `danger` as text on the canvas.
    public static let dangerText = Color(
        light: NSColor(srgbRed: 0.804, green: 0.282, blue: 0.282, alpha: 1),  // #CD4848
        dark: NSColor(srgbRed: 1.00, green: 0.431, blue: 0.439, alpha: 1)
    )
    /// Quiet text that still has to be read: the "read only, never uploaded"
    /// sentence and other trust copy. `.tertiary` measures 1.73:1 on white,
    /// which is why this role exists instead of reusing it.
    public static let subtleText = Color(
        light: NSColor(srgbRed: 0.365, green: 0.384, blue: 0.420, alpha: 1),  // 4.6:1
        dark: NSColor(srgbRed: 0.702, green: 0.722, blue: 0.753, alpha: 1)
    )

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

    /// The opaque stand-ins for the three glass levels, used when
    /// "Reduce transparency" is on.
    public static let cardOpaque = Color(
        light: NSColor(srgbRed: 0.973, green: 0.976, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.133, blue: 0.149, alpha: 1)
    )
    public static let floatOpaque = Color(
        light: NSColor(srgbRed: 0.996, green: 0.996, blue: 0.996, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.161, blue: 0.180, alpha: 1)
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
        // Appended, never inserted: a palette index is written into the category
        // list, and moving one would recolour every row on the page.
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
    public static let rowHeight: CGFloat = 44
    public static let iconTileSize: CGFloat = 32
    public static let panelBorderWidth: CGFloat = 1

    public static let contentWidthWide: CGFloat = 1180
    public static let contentWidthStandard: CGFloat = 1080
    public static let contentWidthForm: CGFloat = 760

    /// The right-hand summary column on the overview, scan and storage pages.
    public static let summaryColumnWidth: CGFloat = 330

    /// Height a result list may grow to before it scrolls.
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
    ///
    /// Every size is multiplied by `SiftTypeScale.current`. macOS has no system
    /// text-size setting an app can read, so this is the product's own answer to
    /// "I cannot read this": three steps, applied at the root and persisted. The
    /// enum stays a computed property rather than a `let` for exactly that
    /// reason — a stored font would freeze the scale at launch.
    public static var display: Font { scaled(32, .semibold) }
    public static var title: Font { scaled(20, .semibold) }
    public static var sectionTitle: Font { scaled(15, .semibold) }
    public static var body: Font { scaled(13, .regular) }
    public static var bodyEmphasis: Font { scaled(13, .medium) }
    public static var caption: Font { scaled(13, .regular) }
    public static var eyebrow: Font { scaled(13, .semibold) }
    public static var metric: Font { scaled(32, .semibold) }
    public static var metricLarge: Font { scaled(32, .bold) }
    public static var heroMetric: Font { scaled(32, .bold) }
    public static var heroUnit: Font { scaled(20, .semibold) }
    public static var badge: Font { scaled(13, .semibold) }
    public static var railLabel: Font { scaled(13, .medium) }
    public static var monospacedNumber: Font {
        .system(size: 13 * SiftTypeScale.current.multiplier, design: .monospaced)
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
