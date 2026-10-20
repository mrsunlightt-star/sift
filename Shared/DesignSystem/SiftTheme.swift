import AppKit
import SwiftUI

/// Design tokens for the whole app.
///
/// The redesign describes the interface as layered glass: a translucent base for
/// the navigation rail, a card material for the content, and a brighter material
/// for anything that floats above the page. Three things make that read as glass
/// rather than as a grey box — the background shows through, the material blurs
/// what is behind it, and a highlight sits on the top edge. The tokens below keep
/// those three properties consistent across every surface.
public enum SiftColor {
    /// Primary action colour. Violet, fixed rather than the system accent, so a
    /// user's accent-colour choice cannot make the primary action blend into a
    /// category tint.
    public static let accent = Color(
        light: NSColor(srgbRed: 0.42, green: 0.29, blue: 0.95, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.43, blue: 1.00, alpha: 1)
    )
    /// The lighter end of the accent gradient used on primary buttons.
    public static let accentBright = Color(
        light: NSColor(srgbRed: 0.55, green: 0.38, blue: 1.00, alpha: 1),
        dark: NSColor(srgbRed: 0.64, green: 0.53, blue: 1.00, alpha: 1)
    )
    /// Completed safely, or a `safe` risk level.
    public static let safe = Color(
        light: NSColor(srgbRed: 0.09, green: 0.64, blue: 0.38, alpha: 1),
        dark: NSColor(srgbRed: 0.24, green: 0.85, blue: 0.55, alpha: 1)
    )
    /// Needs the user's attention: `review` risk, space pressure.
    public static let review = Color(
        light: NSColor(srgbRed: 0.85, green: 0.50, blue: 0.08, alpha: 1),
        dark: NSColor(srgbRed: 0.96, green: 0.70, blue: 0.28, alpha: 1)
    )
    /// Never acted on: `protected` risk.
    public static let danger = Color(
        light: NSColor(srgbRed: 0.85, green: 0.20, blue: 0.24, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.45, alpha: 1)
    )
    /// Secondary information, unavailable space, disabled states.
    public static let neutral = Color(nsColor: .secondaryLabelColor)

    /// The window canvas the glass sits on.
    ///
    /// Dark mode is nearly black with a violet cast; light mode is a very pale
    /// lavender. The ambient glow in `SiftCanvasBackground` supplies the colour
    /// movement, so the base itself stays quiet.
    public static let canvas = Color(
        light: NSColor(srgbRed: 0.955, green: 0.948, blue: 0.975, alpha: 1),
        dark: NSColor(srgbRed: 0.045, green: 0.045, blue: 0.060, alpha: 1)
    )
    /// The rail's base glass tint.
    public static let baseGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.46),
        dark: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 0.52)
    )
    /// The card surface tint, laid over the material.
    public static let cardGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.58),
        dark: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.135, alpha: 0.58)
    )
    /// The floating surface tint: confirmations, selected rows, popovers.
    public static let floatingGlass = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.78),
        dark: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.17, alpha: 0.86)
    )
    /// Hairline around a glass surface.
    public static let glassBorder = Color(
        light: NSColor(srgbRed: 0.10, green: 0.08, blue: 0.22, alpha: 0.10),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.10)
    )
    /// The top-edge highlight that makes glass look lit rather than painted.
    public static let glassHighlight = Color(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
    )
    /// A selected row or navigation item.
    public static let selectedFill = Color(
        light: NSColor(srgbRed: 0.42, green: 0.29, blue: 0.95, alpha: 0.12),
        dark: NSColor(srgbRed: 0.55, green: 0.43, blue: 1.00, alpha: 0.16)
    )
    /// Hover feedback on a row or a plain button.
    public static let hoverFill = Color(
        light: NSColor(srgbRed: 0.10, green: 0.08, blue: 0.22, alpha: 0.045),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.055)
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
    /// a warning banner. The category identity stays stable because the order is
    /// fixed.
    public static let categoryPalette: [Color] = [
        accent,
        safe,
        Color(light: NSColor(srgbRed: 0.20, green: 0.63, blue: 0.72, alpha: 1),
              dark: NSColor(srgbRed: 0.36, green: 0.78, blue: 0.85, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.28, green: 0.47, blue: 0.86, alpha: 1),
              dark: NSColor(srgbRed: 0.46, green: 0.62, blue: 1.00, alpha: 1)),
        review,
        Color(light: NSColor(srgbRed: 0.85, green: 0.39, blue: 0.55, alpha: 1),
              dark: NSColor(srgbRed: 0.98, green: 0.52, blue: 0.66, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.45, green: 0.36, blue: 0.80, alpha: 1),
              dark: NSColor(srgbRed: 0.62, green: 0.53, blue: 0.98, alpha: 1)),
        Color(light: NSColor(srgbRed: 0.55, green: 0.57, blue: 0.64, alpha: 1),
              dark: NSColor(srgbRed: 0.66, green: 0.68, blue: 0.75, alpha: 1)),
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
public enum SiftMetrics {
    /// 4 pt base unit.
    public static let unit: CGFloat = 4
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24
    public static let spacingXXL: CGFloat = 32

    public static let cornerRadiusS: CGFloat = 8
    public static let cornerRadiusM: CGFloat = 12
    public static let cornerRadiusL: CGFloat = 18
    public static let cornerRadiusXL: CGFloat = 24

    /// Minimum click target (§11.4).
    public static let minimumHitTarget: CGFloat = 44

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
/// Numerals use `.monospacedDigit()` at the call site wherever a value can
/// change, so a scan that is counting up does not make the text jitter.
public enum SiftFont {
    public static let display = Font.system(size: 30, weight: .semibold)
    public static let title = Font.system(size: 19, weight: .semibold)
    public static let sectionTitle = Font.system(size: 15, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let eyebrow = Font.system(size: 11, weight: .semibold)
    public static let metric = Font.system(size: 22, weight: .semibold)
    public static let metricLarge = Font.system(size: 34, weight: .bold)
    /// The number on the overview's hero card: large enough to be the subject.
    public static let heroMetric = Font.system(size: 62, weight: .bold)
    public static let heroUnit = Font.system(size: 20, weight: .semibold)
    public static let badge = Font.system(size: 10, weight: .semibold)
    public static let railLabel = Font.system(size: 10, weight: .medium)
    public static let monospacedNumber = Font.system(size: 13, design: .monospaced)
}

/// Animation curves, all spring-driven and all respectful of Reduce Motion.
public enum SiftMotion {
    /// A view appearing: opacity 0 → 1, scale 0.98 → 1.
    public static let appear = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// A press: scale 0.96.
    public static let press = Animation.spring(response: 0.18, dampingFraction: 0.72)
    /// The progress ring's stroke.
    public static let progress = Animation.spring(response: 0.55, dampingFraction: 0.9)
    /// A page change: a short crossfade.
    public static let page = Animation.easeInOut(duration: 0.18)
    /// A hover highlight.
    public static let hover = Animation.easeOut(duration: 0.14)
    /// The scan progress indicator, which loops while scanning.
    public static let scanning = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// Short transitions used by rows and checkboxes.
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Panel or sheet presentation.
    public static let panel = Animation.spring(response: 0.35, dampingFraction: 0.85)

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

/// The three glass levels from the redesign.
public enum SiftSurface: Sendable {
    /// Navigation rail and dividers: thin, 45% tint, least presence.
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
        case .card: 18
        case .floating: 28
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .base: 0
        case .card: 0.18
        case .floating: 0.28
        }
    }
}
