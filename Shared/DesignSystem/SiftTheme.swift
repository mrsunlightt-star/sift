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
    // MARK: - Brand

    /// Exact green sampled from the supplied Sift app icon. Use sparingly for
    /// recognizable brand details; it is not a small white-text button fill.
    public static let brandGreen = Color(
        light: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 1), // #00BF63
        dark: NSColor(srgbRed: 0.20, green: 0.86, blue: 0.53, alpha: 1)
    )
    /// Exact gold sampled from the star in the supplied Sift app icon.
    public static let brandGold = Color(
        light: NSColor(srgbRed: 1.0, green: 0.729, blue: 0.212, alpha: 1), // #FFBA36
        dark: NSColor(srgbRed: 1.0, green: 0.79, blue: 0.36, alpha: 1)
    )

    // MARK: - Functional accent

    /// Darker green for controls and readable links. White on #007E46 is
    /// approximately 5.16:1; the bright icon green is not sufficient.
    public static let actionGreen = Color(
        light: NSColor(srgbRed: 0.0, green: 0.494, blue: 0.275, alpha: 1), // #007E46
        dark: NSColor(srgbRed: 0.0, green: 0.749, blue: 0.388, alpha: 1)  // #00BF63
    )
    public static let actionGreenHover = Color(
        light: NSColor(srgbRed: 0.0, green: 0.420, blue: 0.235, alpha: 1), // #006B3C
        dark: NSColor(srgbRed: 0.10, green: 0.84, blue: 0.48, alpha: 1)
    )

    /// Compatibility token for existing brand-fill call sites. New text must
    /// use accentText; new controls should use accentFill.
    public static let accent = brandGreen
    public static let accentBright = brandGreen
    public static let accentDeep = actionGreen
    public static let accentText = actionGreen
    public static let accentFill = actionGreen
    public static let accentHover = actionGreenHover
    public static let onAccent = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.05, green: 0.13, blue: 0.08, alpha: 1)
    )

    // MARK: - Semantic status roles

    /// Safe / completed. Kept separate from the Sift brand accent.
    public static let safe = Color(
        light: NSColor(srgbRed: 0.20, green: 0.61, blue: 0.34, alpha: 1),
        dark: NSColor(srgbRed: 0.36, green: 0.82, blue: 0.50, alpha: 1)
    )
    public static let safeText = Color(
        light: NSColor(srgbRed: 0.157, green: 0.427, blue: 0.247, alpha: 1), // #286D3F
        dark: NSColor(srgbRed: 0.45, green: 0.86, blue: 0.57, alpha: 1)
    )
    /// Needs the user's attention; intentionally not the brand gold.
    public static let review = Color(
        light: NSColor(srgbRed: 0.95, green: 0.70, blue: 0.25, alpha: 1),
        dark: NSColor(srgbRed: 0.96, green: 0.73, blue: 0.34, alpha: 1)
    )
    public static let reviewText = Color(
        light: NSColor(srgbRed: 0.541, green: 0.353, blue: 0.0, alpha: 1), // #8A5A00
        dark: NSColor(srgbRed: 1.0, green: 0.80, blue: 0.43, alpha: 1)
    )
    /// Error / dangerous action. Protected is also labelled explicitly.
    public static let danger = Color(
        light: NSColor(srgbRed: 0.86, green: 0.31, blue: 0.29, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
    )
    public static let dangerText = Color(
        light: NSColor(srgbRed: 0.698, green: 0.227, blue: 0.227, alpha: 1), // #B23A3A
        dark: NSColor(srgbRed: 1.0, green: 0.52, blue: 0.49, alpha: 1)
    )
    public static let neutral = Color(nsColor: .secondaryLabelColor)

    // MARK: - Text roles

    public static let mainText = Color(
        light: NSColor(srgbRed: 0.125, green: 0.153, blue: 0.133, alpha: 1), // #202722
        dark: NSColor(srgbRed: 0.945, green: 0.961, blue: 0.949, alpha: 1)
    )
    public static let secondaryText = Color(
        light: NSColor(srgbRed: 0.373, green: 0.412, blue: 0.384, alpha: 1), // #5F6962
        dark: NSColor(srgbRed: 0.659, green: 0.698, blue: 0.671, alpha: 1)
    )
    public static let subtleText = Color(
        light: NSColor(srgbRed: 0.408, green: 0.443, blue: 0.420, alpha: 1), // #68716B
        dark: NSColor(srgbRed: 0.702, green: 0.741, blue: 0.714, alpha: 1)
    )

    // MARK: - Surfaces

    /// The light canvas is deliberately pure white. Dark mode uses a restrained
    /// green-black neutral without ambient gradients.
    public static let canvas = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.067, green: 0.09, blue: 0.075, alpha: 1) // #111713
    )
    public static let baseGlass = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.11, alpha: 1)
    )
    public static let cardGlass = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.11, alpha: 1)
    )
    public static let floatingGlass = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.13, green: 0.17, blue: 0.14, alpha: 1)
    )
    public static let glassBorder = Color(
        light: NSColor(srgbRed: 0.898, green: 0.918, blue: 0.902, alpha: 1), // #E5EAE6
        dark: NSColor(srgbRed: 0.17, green: 0.22, blue: 0.18, alpha: 1)
    )
    public static let glassHighlight = Color.clear
    public static let selectedFill = Color(
        light: NSColor(srgbRed: 0.91, green: 0.969, blue: 0.937, alpha: 1), // #E8F7EF
        dark: NSColor(srgbRed: 0.10, green: 0.25, blue: 0.16, alpha: 1)
    )
    public static let selectedBorder = Color(
        light: NSColor(srgbRed: 0.725, green: 0.902, blue: 0.800, alpha: 1), // #B9E6CC
        dark: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.30, alpha: 1)
    )
    public static let hoverFill = Color(
        light: NSColor(srgbRed: 0.949, green: 0.965, blue: 0.953, alpha: 1), // #F2F6F3
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
    )
    public static let subtleFill = Color(
        light: NSColor(srgbRed: 0.965, green: 0.973, blue: 0.965, alpha: 1), // #F6F8F6
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)
    )
    public static let cardOpaque = canvas
    public static let floatOpaque = floatingGlass

    /// Compatibility aliases for older feature code.
    public static let windowBackground = canvas
    public static let panel = cardGlass
    public static let raised = floatingGlass
    public static let border = glassBorder

    /// Muted category colors for data visualization. Green leads; other
    /// categories retain distinguishable hues so the chart remains legible.
    public static let categoryPalette: [Color] = [
        Color(light: NSColor(srgbRed: 0.16, green: 0.61, blue: 0.36, alpha: 1),
              dark: NSColor(srgbRed: 0.31, green: 0.78, blue: 0.49, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.39, green: 0.65, blue: 0.43, alpha: 1),
              dark: NSColor(srgbRed: 0.48, green: 0.78, blue: 0.52, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.12, green: 0.56, blue: 0.65, alpha: 1),
              dark: NSColor(srgbRed: 0.25, green: 0.71, blue: 0.80, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.31, green: 0.53, blue: 0.72, alpha: 1),
              dark: NSColor(srgbRed: 0.44, green: 0.64, blue: 0.84, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.72, green: 0.48, blue: 0.16, alpha: 1),
              dark: NSColor(srgbRed: 0.90, green: 0.68, blue: 0.34, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.71, green: 0.40, blue: 0.50, alpha: 1),
              dark: NSColor(srgbRed: 0.86, green: 0.55, blue: 0.65, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.52, green: 0.43, blue: 0.70, alpha: 1),
              dark: NSColor(srgbRed: 0.65, green: 0.56, blue: 0.86, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.43, green: 0.47, blue: 0.51, alpha: 1),
              dark: NSColor(srgbRed: 0.59, green: 0.63, blue: 0.67, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.40, green: 0.54, blue: 0.35, alpha: 1),
              dark: NSColor(srgbRed: 0.60, green: 0.73, blue: 0.44, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.38, green: 0.42, blue: 0.61, alpha: 1),
              dark: NSColor(srgbRed: 0.55, green: 0.59, blue: 0.81, alpha: 1)),
    ]

    /// Fill color for a risk badge or indicator.
    public static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .safe: safe
        case .review: review
        case .protected: danger
        }
    }

    /// Readable text color for a risk label.
    public static func textColor(for risk: RiskLevel) -> Color {
        switch risk {
        case .safe: safeText
        case .review: reviewText
        case .protected: dangerText
        }
    }

    /// Fill color for a scan phase.
    public static func color(for phase: ScanPhase) -> Color {
        switch phase {
        case .ready: safe
        case .partial, .cancelled: review
        case .failed: danger
        default: accent
        }
    }

    /// Readable text color for a scan phase.
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
    public static let cornerRadiusXL: CGFloat = 12

    /// Compact, consistent radius for buttons, fields and segmented controls.
    public static let controlCornerRadius: CGFloat = 8

    /// Minimum click target (§11.4).
    public static let minimumHitTarget: CGFloat = 44

    /// The standard control heights, so a page never invents its own.
    public static let buttonHeight: CGFloat = 40
    public static let chipHeight: CGFloat = 30
    public static let fieldHeight: CGFloat = 34

    /// The hairline stroke: half a point, so a border reads as glass edge
    /// rather than a drawn frame.
    public static let hairline: CGFloat = 0.5

    /// Horizontal macOS sidebar: 12 pt outer inset on each side.
    public static let railWidth: CGFloat = 190
    public static let railItemWidth: CGFloat = 166
    public static let railItemHeight: CGFloat = 44

    /// The page's outer margins and columns.
    public static let pagePadding: CGFloat = 28
    public static let pageSpacing: CGFloat = 20
    public static let rowHeight: CGFloat = 52
    public static let iconTileSize: CGFloat = 32
    public static let panelBorderWidth: CGFloat = 1

    public static let contentWidthWide: CGFloat = 1180
    public static let contentWidthStandard: CGFloat = 1080
    public static let contentWidthForm: CGFloat = 760

    /// The right-hand summary column on the overview, scan and storage pages.
    public static let summaryColumnWidth: CGFloat = 270

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
    /// The type ladder separates display, title, section, body and metadata
    /// sizes so hierarchy is carried by typography rather than decorative cards.
    ///
    /// Every size is multiplied by `SiftTypeScale.current`. macOS has no system
    /// text-size setting an app can read, so this is the product's own answer to
    /// "I cannot read this": three steps, applied at the root and persisted. The
    /// enum stays a computed property rather than a `let` for exactly that
    /// reason — a stored font would freeze the scale at launch.
    public static var display: Font { scaled(28, .semibold) }
    public static var title: Font { scaled(20, .semibold) }
    public static var sectionTitle: Font { scaled(16, .semibold) }
    public static var body: Font { scaled(14, .regular) }
    public static var bodyEmphasis: Font { scaled(14, .medium) }
    public static var caption: Font { scaled(12, .regular) }
    public static var eyebrow: Font { scaled(11, .semibold) }
    public static var metric: Font { scaled(32, .semibold) }
    public static var metricLarge: Font { scaled(40, .bold) }
    public static var heroMetric: Font { scaled(44, .bold) }
    public static var heroUnit: Font { scaled(18, .semibold) }
    public static var badge: Font { scaled(12, .semibold) }
    public static var railLabel: Font { scaled(14, .medium) }
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
