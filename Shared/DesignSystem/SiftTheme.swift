import SwiftUI

/// Design tokens for the whole app.
///
/// The specification (§11.1) fixes the palette: blue for the primary action,
/// green for a safe completion, orange where the user must confirm. Everything
/// here is built from system colours so light and dark mode stay correct without
/// a second palette, and so the app follows the user's accent-colour setting.
public enum SiftColor {
    /// Primary action colour, used for the scan button and the main CTA.
    public static let accent = Color.accentColor
    /// Completed safely, or a `safe` risk level.
    public static let safe = Color(nsColor: .systemGreen)
    /// Needs the user's attention: `review` risk, space pressure.
    public static let review = Color(nsColor: .systemOrange)
    /// Never acted on: `protected` risk.
    public static let danger = Color(nsColor: .systemRed)
    /// Secondary information, unavailable space, disabled states.
    public static let neutral = Color(nsColor: .secondaryLabelColor)

    /// Window background, matching System Settings rather than pure white.
    public static let windowBackground = Color(nsColor: .windowBackgroundColor)
    /// Panel surface sitting on the window background.
    public static let panel = Color(nsColor: .controlBackgroundColor)
    /// A raised surface inside a panel (selected row, stat tile).
    public static let raised = Color(nsColor: .textBackgroundColor)
    /// Hairline border used around panels and tiles.
    public static let border = Color(nsColor: .separatorColor)

    /// Chart segment colours, in the order `StorageCategory.paletteOrder`.
    public static let categoryPalette: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemYellow),
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
        case .safe: "checkmark.seal.fill"
        case .review: "exclamationmark.triangle.fill"
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
}

/// Spacing, radius and size tokens.
///
/// A single scale keeps densities consistent across features, which is what
/// makes the app read as a native macOS tool rather than a web page in a window.
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
    public static let cornerRadiusL: CGFloat = 16
    public static let cornerRadiusXL: CGFloat = 20

    /// Minimum click target (§11.4).
    public static let minimumHitTarget: CGFloat = 44

    public static let sidebarWidth: CGFloat = 236
    public static let rowHeight: CGFloat = 44
    public static let iconTileSize: CGFloat = 32
    public static let panelBorderWidth: CGFloat = 1

    /// The page column widths. A page picks the one that suits its content and
    /// keeps the same margins everywhere, so switching destinations does not
    /// make the layout jump left or right.
    public static let contentWidthWide: CGFloat = 1000
    public static let contentWidthStandard: CGFloat = 880
    public static let contentWidthForm: CGFloat = 740

    /// Height a result list may grow to before it scrolls.
    public static let resultListMaxHeight: CGFloat = 320
}

/// Typography built on the system font, with no external typefaces (§11.1).
public enum SiftFont {
    public static let display = Font.system(size: 28, weight: .semibold, design: .default)
    public static let title = Font.system(size: 18, weight: .semibold)
    public static let sectionTitle = Font.system(size: 14, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let eyebrow = Font.system(size: 11, weight: .semibold)
    public static let metric = Font.system(size: 22, weight: .semibold)
    public static let metricLarge = Font.system(size: 34, weight: .bold)
    public static let badge = Font.system(size: 10, weight: .semibold)
    public static let monospacedNumber = Font.system(size: 13, design: .monospaced)
}

/// Animation curves, all of which respect Reduce Motion.
public enum SiftMotion {
    /// Short transition for a row appearing or a selection moving.
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Panel or sheet presentation.
    public static let panel = Animation.easeInOut(duration: 0.22)
    /// The scan progress indicator, which loops while scanning.
    public static let scanning = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// Returns an animation only when the user has not asked for reduced motion.
    public static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
