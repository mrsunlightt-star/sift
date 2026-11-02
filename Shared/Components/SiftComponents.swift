import Foundation
import SwiftUI

// MARK: - Surfaces

/// A glass card: the surface every section sits on.
///
/// Three layers, in the order the design language describes them: the system
/// material blurs what is behind the card, a tinted fill decides how much of the
/// backdrop survives, and a top-edge highlight makes the surface look lit. The
/// border is a hairline rather than a frame — a card that is outlined looks like
/// a box, not like glass.
public struct SiftGlassCard<Content: View>: View {
    private let surface: SiftSurface
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        surface: SiftSurface = .card,
        cornerRadius: CGFloat = SiftMetrics.cornerRadiusXL,
        padding: CGFloat = SiftMetrics.spacingXL,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(surface.opaqueFill)
                    } else {
                        shape.fill(surface.material)
                        shape.fill(surface.tint)
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [
                                SiftColor.glassHighlight.opacity(surface == .floating ? 0.16 : 0.08),
                                .clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.panelBorderWidth)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [SiftColor.glassHighlight.opacity(0.50), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: SiftMetrics.panelBorderWidth
                )
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .shadow(
                color: .black.opacity(surface.shadowOpacity),
                radius: surface.shadowRadius,
                y: surface == .card ? 6 : 10
            )
    }
}

/// A panel with a hairline border, the surface every section sits on.
public struct SiftPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = SiftMetrics.spacingXL, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        SiftGlassCard(padding: padding) {
            content
        }
    }
}

/// The window background: a quiet porcelain canvas with two ambient glows.
///
/// The glow is what the glass has to show through. Without it the material has
/// nothing to blur and every card reads as flat grey. Jade breathes from the
/// top-right, a faint warmth from the lower-left, and the base stays quiet.
public struct SiftCanvasBackground: View {
    public init() {}

    /// A flat canvas: one colour, no wash. The glass layers carry the depth.
    public var body: some View {
        SiftColor.canvas
            .ignoresSafeArea()
    }
}

// MARK: - Page chrome

/// A page header: a small status line, then the display title.
///
/// The status line opens with a jade tick — the same mark a section header uses —
/// so every page carries one quiet instance of the accent before any action is
/// taken. The hairline beneath fades out at the edges, which reads as structure
/// rather than as a rule boxing the page in.
public struct SiftPageHeader<Trailing: View>: View {
    private let title: String
    private let status: String?
    private let trailing: Trailing

    public init(
        title: String,
        status: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.status = status
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: SiftMetrics.spacingXL) {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                    if let status, !status.isEmpty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SiftColor.accent)
                                .frame(width: 4, height: 4)
                            Text(status)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Text(title)
                        .siftFont(.display)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SiftMetrics.spacingL)
                trailing
                    .padding(.bottom, 2)
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.top, SiftMetrics.spacingL)
            .padding(.bottom, SiftMetrics.spacingM)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: SiftColor.glassBorder, location: 0.06),
                            .init(color: SiftColor.glassBorder, location: 0.94),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }
}

extension SiftPageHeader where Trailing == EmptyView {
    public init(title: String, status: String? = nil) {
        self.init(title: title, status: status) { EmptyView() }
    }
}
/// The scrolling page column.
///
/// Every page uses the same outer margins and vertical rhythm; only the column
/// width changes with the kind of content. That consistency is what makes the
/// pages look like one app when the window is wide.
public struct SiftPage<Content: View>: View {
    private let maxWidth: CGFloat
    private let content: Content

    public init(maxWidth: CGFloat = SiftMetrics.contentWidthWide, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                content
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.top, SiftMetrics.pageSpacing)
            .padding(.bottom, SiftMetrics.spacingXXL)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

// MARK: - Entrance

/// A staggered entrance: the view fades in and rises a step after its siblings.
///
/// Applied with `siftAppear(index:)` down a column of cards, so a page settles
/// in one wave instead of snapping. Honours `siftReduceMotion` by appearing
/// immediately.
struct SiftAppear: ViewModifier {
    let index: Int
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    // At most two steps of stagger: the page already fades in
                    // for 0.2 s, and a full wave pushed the first meaningful
                    // content half a second behind the click.
                    withAnimation(SiftMotion.quick.delay(Double(min(index, 2)) * 0.03)) {
                        shown = true
                    }
                }
            }
    }
}

public extension View {
    /// Fades the view in with a slight rise, delayed by its position in a wave.
    func siftAppear(index: Int = 0) -> some View {
        modifier(SiftAppear(index: index))
    }
}

// MARK: - Fields

public extension View {
    /// The quiet well a text field sits in: a subtle fill and a hairline border.
    ///
    /// The caller owns its padding and height; this draws only the surface, so a
    /// search field and a form field can share it without agreeing on content.
    func siftFieldSurface(
        cornerRadius: CGFloat = SiftMetrics.controlCornerRadius - 2
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(SiftColor.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.panelBorderWidth)
        }
    }
}

// MARK: - Buttons

/// The primary action: a deep jade rounded rectangle with a lit top edge and a
/// soft glow.
public struct SiftPrimaryButton: View {
    private let title: String
    private let symbolName: String?
    private let isEnabled: Bool
    private let action: () -> Void

    @State private var isHovering = false

    public init(title: String, symbolName: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.action = action
    }

    public init(
        titleKey: LocalizationKey,
        symbolName: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(title: titleKey.localized, symbolName: symbolName, isEnabled: isEnabled, action: action)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SiftMetrics.spacingS) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                    // A label built from a count and a size reaches 60+
                    // characters in German and Russian. Truncating the action is
                    // not an option, so the label shrinks a little first and
                    // only then truncates.
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(SiftColor.onAccent)
            .padding(.horizontal, SiftMetrics.spacingXL)
            .frame(minHeight: SiftMetrics.buttonHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(SiftColor.accentFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(isHovering ? 0.18 : 0.10), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                    .opacity(isEnabled ? 1 : 0.42)
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.14), lineWidth: SiftMetrics.hairline)
            }
            .shadow(
                color: SiftColor.accent.opacity(isHovering ? 0.40 : 0.26),
                radius: isHovering ? 16 : 10,
                y: 6
            )
            // The label stays at full opacity when the control is disabled: a
            // whole-view 0.45 wash left the button's own text at 1.27:1, which
            // is a button that says nothing.
            .opacity(isEnabled ? 1 : 0.72)
        }
        .buttonStyle(SiftPressButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .onHover { isHovering = $0 }
    }
}

/// A secondary action: the same rectangle, but glass instead of paint.
public struct SiftSecondaryButton: View {
    private let title: String
    private let symbolName: String?
    private let action: () -> Void

    @State private var isHovering = false

    public init(title: String, symbolName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.action = action
    }

    public init(titleKey: LocalizationKey, symbolName: String? = nil, action: @escaping () -> Void) {
        self.init(title: titleKey.localized, symbolName: symbolName, action: action)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SiftMetrics.spacingS) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
            }
            .padding(.horizontal, SiftMetrics.spacingXL)
            .frame(minHeight: SiftMetrics.buttonHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                            .fill(isHovering ? SiftColor.hoverFill : SiftColor.subtleFill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.hairline)
            }
        }
        .buttonStyle(SiftPressButtonStyle())
        .accessibilityLabel(Text(title))
        .onHover { isHovering = $0 }
    }
}

/// A plain icon button used in dense rows and page headers.
public struct SiftIconButton: View {
    private let symbolName: String
    private let help: String
    private let action: () -> Void

    @State private var isHovering = false

    public init(symbolName: String, help: String, action: @escaping () -> Void) {
        self.symbolName = symbolName
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? SiftColor.accent : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .fill(isHovering ? SiftColor.hoverFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// A link in the app's own accent.
///
/// The system link style is blue, which puts a second accent colour on a page
/// whose primary action is jade. This style keeps link semantics — a text
/// button with no chrome — and uses the product's accent, easing out on hover.
public struct SiftLinkButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SiftLinkBody(configuration: configuration)
    }
}

private struct SiftLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(SiftColor.accentText)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .underline(isHovering && !configuration.isPressed, color: SiftColor.accentText.opacity(0.6))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Scale-on-press, the interaction the design language specifies for every
/// control with a fill.
public struct SiftPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SiftPressBody(configuration: configuration)
    }
}

private struct SiftPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : SiftMotion.press, value: configuration.isPressed)
    }
}
// MARK: - Metrics and badges
/// The large number on a hero card: the value at display size, the unit beside it.
public struct SiftHugeMetric: View {
    private let value: String
    private let unit: String?

    public init(_ value: String, unit: String? = nil) {
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
            Text(value)
                .siftFont(.heroMetric)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .siftFont(.heroUnit)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded icon tile used at the start of a row.
public struct IconTile: View {
    private let symbolName: String
    private let tint: Color

    public init(symbolName: String, tint: Color = SiftColor.accent) {
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.18), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: SiftMetrics.iconTileSize, height: SiftMetrics.iconTileSize)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// Risk badge.
///
/// Colour is never the only signal: the badge always carries a word, and a lock
/// for a protected item, as §11.4 requires for accessibility and for colour-blind
/// users. The shape follows the control language — a small rounded rectangle —
/// so a badge reads as a label, not as a pill bolted on.
public struct RiskBadge: View {
    private let risk: RiskLevel

    public init(risk: RiskLevel) {
        self.risk = risk
    }

    public var body: some View {
        HStack(spacing: 5) {
            if risk == .protected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
            } else {
                Circle()
                    .fill(SiftColor.color(for: risk))
                    .frame(width: 5, height: 5)
            }
            Text(risk.labelKey.localized)
                .font(SiftFont.badge)
        }
        .foregroundStyle(SiftColor.textColor(for: risk))
        .padding(.horizontal, SiftMetrics.spacingS)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .fill(SiftColor.color(for: risk).opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .strokeBorder(SiftColor.color(for: risk).opacity(0.18), lineWidth: SiftMetrics.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(risk.labelKey.localized))
        .accessibilityHint(Text(risk.detailKey.localized))
    }
}

/// A filter chip: the selected chip is jade glass, the rest are quiet wells.
public struct SiftFilterChip: View {
    private let title: String
    private let detail: String?
    private let isSelected: Bool
    private let action: () -> Void

    @State private var isHovering = false

    public init(title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                if let detail {
                    Text(detail)
                        .font(SiftFont.caption)
                        .opacity(0.7)
                }
            }
            .foregroundStyle(isSelected ? SiftColor.accentText : Color.primary)
            .padding(.horizontal, SiftMetrics.spacingL)
            .frame(minHeight: SiftMetrics.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .fill(
                        isSelected
                            ? SiftColor.selectedFill
                            : (isHovering ? SiftColor.hoverFill : SiftColor.subtleFill)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .strokeBorder(
                        isSelected ? SiftColor.accentText.opacity(0.55) : SiftColor.glassBorder,
                        lineWidth: 1
                    )
            }
            .animation(SiftMotion.hover, value: isHovering)
        }
        .buttonStyle(SiftPressButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A checkbox in the app's own palette.
///
/// The native checkbox follows the system accent, which would put a blue mark in
/// the middle of a jade row. The word beside it is still the accessible label;
/// this view only draws the mark. The tick drops in on a spring rather than
/// appearing, which is the one moment of play the control language allows.
public struct SiftCheckbox: View {
    @Binding private var isOn: Bool
    private let isEnabled: Bool

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(isOn: Binding<Bool>, isEnabled: Bool = true) {
        self._isOn = isOn
        self.isEnabled = isEnabled
    }

    public var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .fill(isOn && isEnabled ? SiftColor.accentDeep : SiftColor.subtleFill)
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .strokeBorder(
                            isOn && isEnabled ? SiftColor.accent.opacity(0.9) : SiftColor.glassBorder,
                            lineWidth: 1
                        )
                }
                .overlay {
                    if isOn && isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.4, anchor: .center).combined(with: .opacity)
                            )
                    }
                }
                .frame(width: 18, height: 18)
                .opacity(isEnabled ? 1 : 0.35)
                // The drawn control is 18 pt; the target is not. 13 pt of
                // padding on every side makes a 44 pt square — the value
                // `SiftMetrics.minimumHitTarget` states — and the negative
                // padding takes it back out of the layout, so a row keeps its
                // height while the pointer gets a target it can hit.
                .padding(SiftMetrics.minimumHitTarget / 2 - 9)
                .contentShape(Rectangle())
                .padding(-(SiftMetrics.minimumHitTarget / 2 - 9))
                .animation(reduceMotion ? nil : SiftMotion.toggle, value: isOn)
        }
        .buttonStyle(.plain)
        // Reachable by Tab (§11.4). SwiftUI's focus ring is the system's own, so
        // the control looks focused the way every other macOS control does; Space
        // then activates it, because it is a button.
        .focusable()
        // `.isSelected` is what VoiceOver speaks as "selected" in the user's own
        // language. A numeric `accessibilityValue` of "1" was read as "1, 已选中,
        // 按钮" and never localised; the trait says it correctly and needs no key.
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Bars and rings

/// A coloured bar showing how much of a total a value represents.
public struct UsageBar: View {
    private let fraction: Double
    private let tint: Color
    private let height: CGFloat

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(fraction: Double, tint: Color = SiftColor.accent, height: CGFloat = 8) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(SiftColor.neutral.opacity(0.14))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : SiftMotion.settle, value: fraction)
        .accessibilityHidden(true)
    }
}

/// A stacked bar showing several segments of one total.
public struct SegmentedUsageBar: View {
    public struct Segment: Identifiable, Sendable {
        public let id: String
        public let fraction: Double
        public let tint: Color

        public init(id: String, fraction: Double, tint: Color) {
            self.id = id
            self.fraction = fraction
            self.tint = tint
        }
    }

    private let segments: [Segment]
    private let height: CGFloat

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(segments: [Segment], height: CGFloat = 10) {
        self.segments = segments
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(segment.tint)
                        .frame(width: max(geometry.size.width * segment.fraction - 2, 0))
                }
            }
        }
        .frame(height: height)
        .animation(
            reduceMotion ? nil : SiftMotion.settle,
            value: segments.map { "\($0.id)-\($0.fraction)" }
        )
        .accessibilityHidden(true)
    }
}

/// A progress ring.
///
/// A determinate ring trims the stroke to `progress`; an indeterminate ring
/// (`progress == nil`) slides a short arc around the track. The scan engine
/// reports phases rather than a fraction, so the running page uses the
/// indeterminate form instead of inventing a percentage.
public struct SiftProgressRing: View {
    private let progress: Double?
    private let tint: Color
    private let lineWidth: CGFloat
    private let label: String?
    private let caption: String?
    /// What VoiceOver says. The ring is the only place the run's progress is
    /// shown, and it used to be announced as a bare number with no label at all.
    private let spokenLabel: String?
    private let spokenValue: String?

    @State private var spin = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(
        progress: Double?,
        tint: Color = SiftColor.accent,
        lineWidth: CGFloat = 10,
        label: String? = nil,
        caption: String? = nil,
        spokenLabel: String? = nil,
        spokenValue: String? = nil
    ) {
        self.progress = progress.map { min(max($0, 0), 1) }
        self.tint = tint
        self.lineWidth = lineWidth
        self.label = label
        self.caption = caption
        self.spokenLabel = spokenLabel
        self.spokenValue = spokenValue
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(SiftColor.neutral.opacity(0.12), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(progress, 0.001))
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.55), tint, tint.opacity(0.55)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : SiftMotion.progress, value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.34)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.15), tint, tint.opacity(0.15)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(reduceMotion ? -90 : (spin ? 360 : 0)))
                    .animation(
                        reduceMotion
                            ? nil
                            : .linear(duration: 1.5).repeatForever(autoreverses: false),
                        value: spin
                    )
                    .onAppear { spin = true }
            }

            VStack(spacing: 2) {
                if let label {
                    Text(label)
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                }
                if let caption {
                    Text(caption)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel ?? label ?? ""))
        .accessibilityValue(Text(spokenValue ?? caption ?? ""))
    }
}

// MARK: - Rows and states
/// A selectable row surface with a hover highlight and a selected fill.
public struct SiftSelectableRow<Content: View>: View {
    private let isSelected: Bool
    private let content: Content
    private let action: () -> Void

    @State private var isHovering = false

    public init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, SiftMetrics.spacingM)
                .padding(.vertical, SiftMetrics.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                        .fill(isSelected ? SiftColor.selectedFill : (isHovering ? SiftColor.hoverFill : .clear))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                        .strokeBorder(isSelected ? SiftColor.accent.opacity(0.30) : .clear, lineWidth: SiftMetrics.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An empty-state block: a symbol resting in a soft well, a headline and a short
/// explanation.
public struct SiftEmptyState: View {
    private let symbolName: String
    private let titleKey: LocalizationKey
    private let detailKey: LocalizationKey?
    private let detail: String?

    public init(symbolName: String, titleKey: LocalizationKey, detailKey: LocalizationKey? = nil) {
        self.symbolName = symbolName
        self.titleKey = titleKey
        self.detailKey = detailKey
        self.detail = nil
    }

    public init(symbolName: String, titleKey: LocalizationKey, detail: String) {
        self.symbolName = symbolName
        self.titleKey = titleKey
        self.detailKey = nil
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: SiftMetrics.spacingM) {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(SiftColor.subtleFill))
                .overlay(Circle().strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.hairline))
            Text(titleKey.localized)
                .siftFont(.sectionTitle)
            if let detailKey {
                Text(detailKey.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else if let detail {
                Text(detail)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SiftMetrics.spacingXXL)
        .accessibilityElement(children: .combine)
    }
}

/// A placeholder for a row that is still being read.
///
/// The scan page used to show a small spinner under a card that already had a
/// header and a column of dividers, which reads as "a list with nothing in it".
/// A skeleton says the same thing in the shape of the thing that is coming: two
/// lines of text and a number, pulsing slowly enough not to look like a progress
/// bar moving.
public struct SiftSkeletonRow: View {
    private let isFirst: Bool
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var dim = false

    public init(isFirst: Bool = false) {
        self.isFirst = isFirst
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .fill(SiftColor.subtleFill)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 6) {
                bar(width: isFirst ? 180 : 220, height: 11)
                bar(width: isFirst ? 260 : 300, height: 9)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            bar(width: 56, height: 11)
        }
        .padding(.vertical, SiftMetrics.spacingM)
        .opacity(dim ? 0.55 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: dim
        )
        .onAppear { dim = true }
        // One element for the whole placeholder: VoiceOver should say "loading",
        // not read six grey rectangles.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizationKey.commonLoading.localized))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(SiftColor.subtleFill)
            .frame(width: width, height: height)
    }
}

/// A message surface for skips, partial failures and warnings.
public struct NoticeBanner: View {
    public enum Level: Sendable {
        case information
        case warning
        case error
        case success

        var tint: Color {
            switch self {
            case .information: SiftColor.accent
            case .warning: SiftColor.review
            case .error: SiftColor.danger
            case .success: SiftColor.safe
            }
        }

        var symbolName: String {
            switch self {
            case .information: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .success: "checkmark.circle.fill"
            }
        }
    }

    private let level: Level
    private let message: String
    private let actionTitle: LocalizationKey?
    private let action: (() -> Void)?

    public init(
        level: Level,
        message: String,
        actionTitle: LocalizationKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.level = level
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public init(level: Level, titleKey: LocalizationKey) {
        self.level = level
        self.message = titleKey.localized
        self.actionTitle = nil
        self.action = nil
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
            Image(systemName: level.symbolName)
                .foregroundStyle(level.tint)
                .accessibilityHidden(true)
            Text(message)
                .font(SiftFont.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SiftMetrics.spacingS)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle.localized)
                        .font(SiftFont.bodyEmphasis)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
        }
        .padding(SiftMetrics.spacingM)
        .background(level.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                .strokeBorder(level.tint.opacity(0.18), lineWidth: SiftMetrics.hairline)
        }
        .accessibilityElement(children: .contain)
    }
}
/// A primary block: an icon, a short headline, an explanation and the action
/// that belongs to them, on one tinted glass surface.
public struct SiftHeroCard<Actions: View>: View {
    private let symbolName: String
    private let title: String
    private let detail: String?
    private let tint: Color
    private let actions: Actions

    public init(
        symbolName: String,
        title: String,
        detail: String? = nil,
        tint: Color = SiftColor.accent,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
        self.tint = tint
        self.actions = actions()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusXL, style: .continuous)
        HStack(alignment: .top, spacing: SiftMetrics.spacingXL) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.30), tint.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(title)
                    .siftFont(.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .padding(.top, SiftMetrics.spacingXS)
            }

            Spacer(minLength: 0)
        }
        .padding(SiftMetrics.spacingXL)
        .background {
            ZStack {
                shape.fill(.thinMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(0.18), SiftColor.cardGlass],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.fill(
                    LinearGradient(
                        colors: [SiftColor.glassHighlight.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
        }
        .overlay {
            shape.strokeBorder(tint.opacity(0.22), lineWidth: SiftMetrics.hairline)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// A small labelled value used in the page summary strips.
public struct SiftMetricPill: View {
    private let symbolName: String
    private let value: String
    private let tint: Color

    public init(symbolName: String, value: String, tint: Color = SiftColor.accent) {
        self.symbolName = symbolName
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(value)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: SiftMetrics.hairline)
        }
    }
}

/// A rail entry's label: the icon over its one-word caption.
///
/// Every entry in the rail draws this same box — the four destinations and the
/// footer controls — so the bottom of the rail cannot drift into a second scale
/// of icon or type by being written somewhere else.
public struct SiftRailItemLabel: View {
    private let symbolName: String
    private let title: String

    public init(symbolName: String, title: String) {
        self.symbolName = symbolName
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 19, weight: .medium))
                .frame(height: 22)
            Text(title)
                .font(SiftFont.railLabel)
                .lineLimit(1)
        }
        .frame(width: SiftMetrics.railItemWidth, height: SiftMetrics.railItemHeight)
        .contentShape(Rectangle())
    }
}

/// The rail item's background chrome: the selection fill, the hover fill that
/// tracks the pointer, and — for an entry that is a destination — the accent
/// mark on its leading edge.
///
/// Every entry wears it: the four destinations, the appearance switcher, the
/// account entry, the language control and settings. One implementation is what
/// keeps a footer press reading exactly like a navigation press; the fills are
/// adaptive, so light and dark modes both get them.
///
/// `isSelected` is also what a footer control passes while its popover is open,
/// so an open appearance or language picker lights its own entry instead of
/// looking like a button that did nothing.
public struct SiftRailItemChrome: ViewModifier {
    public let isSelected: Bool
    public let showsSelectionMark: Bool
    /// Whether this entry paints the selection fill itself.
    ///
    /// The rail draws one fill per group and slides it to the entry the window is
    /// showing, so an entry inside a group hands that job to the slider
    /// (`fillsSelection: false`) and keeps only its hover fill; an entry that is
    /// not part of such a group — the appearance and language controls, whose
    /// "selected" state is their open popover — still paints its own.
    public let fillsSelection: Bool
    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(isSelected: Bool, showsSelectionMark: Bool = false, fillsSelection: Bool = true) {
        self.isSelected = isSelected
        self.showsSelectionMark = showsSelectionMark
        self.fillsSelection = fillsSelection
    }

    /// The fill under the item.
    ///
    /// A selected entry whose fill the slider owns paints nothing even while the
    /// pointer is over it: a hover fill on top of the slider would tint the row
    /// the window is on, which reads as a second state rather than as hover.
    private var fillColor: Color {
        if fillsSelection && isSelected { return SiftColor.selectedFill }
        if isHovering && !isSelected { return SiftColor.hoverFill }
        return .clear
    }

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .fill(fillColor)
                    .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
                    .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
            }
            .overlay(alignment: .leading) {
                // The selection mark: a bar on the item's left edge, so the
                // page the window is showing reads without a border boxing the
                // item in. Only a destination can be "the page you are on".
                Capsule()
                    .fill(SiftColor.accent)
                    .frame(width: 3, height: 18)
                    .padding(.leading, 3)
                    .opacity(showsSelectionMark && isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
    }
}

public extension View {
    func siftRailItemChrome(
        isSelected: Bool,
        showsSelectionMark: Bool = false,
        fillsSelection: Bool = true
    ) -> some View {
        modifier(
            SiftRailItemChrome(
                isSelected: isSelected,
                showsSelectionMark: showsSelectionMark,
                fillsSelection: fillsSelection
            )
        )
    }
}

/// The language control.
///
/// The rail footer and the settings page both render this view and both call the
/// same selection closure, so the choice is written by one function and the two
/// locations cannot disagree about how it is stored.
public struct LanguageMenu: View {
    public enum Style: Sendable {
        /// The icon rail: a globe with the language's short name beside it.
        case rail
        /// A sidebar footer row: globe, current language and a disclosure glyph.
        case sidebar
        /// A settings row: the label on the left, the current language on the right.
        case settings(title: LocalizationKey)
    }

    private let selection: SiftLanguage
    private let style: Style
    private let identifier: String
    private let onSelect: (SiftLanguage) -> Void
    /// Reports the picker opening and closing, so a rail that draws one sliding
    /// fill for its group can move that fill here. The rail entry no longer
    /// paints the fill itself; without this the entry would light up in place
    /// while the group's slider stayed where the last page left it.
    private let onPickerPresentedChange: ((Bool) -> Void)?
    @State private var isPickerPresented = false

    public init(
        selection: SiftLanguage,
        style: Style,
        identifier: String = "language.menu",
        onPickerPresentedChange: ((Bool) -> Void)? = nil,
        onSelect: @escaping (SiftLanguage) -> Void
    ) {
        self.selection = selection
        self.style = style
        self.identifier = identifier
        self.onPickerPresentedChange = onPickerPresentedChange
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if case .rail = style {
                // While the picker is open the entry wears the selected fill and
                // takes the accent, so the popover visibly belongs to it. It is
                // not a destination: no selection mark, and no `.isSelected`
                // trait either — that trait is reserved for the current page.
                sized.siftRailItemChrome(isSelected: isPickerPresented, fillsSelection: false)
            } else {
                sized
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(LocalizationKey.settingsGroupLanguage.localized))
        .accessibilityValue(Text(selection.displayName))
        .accessibilityAddTraits(isPickerPresented ? .isSelected : [])
    }

    /// The picker's presentation state, reporting every change.
    ///
    /// The rail draws one fill for its whole footer group, so it has to hear
    /// about this popover opening and closing; writing it through a binding is
    /// how the rail gets told without the type knowing about that slider.
    /// `onChange` would say the same thing, but the two-argument form it needs
    /// is macOS 14 and this package targets 13.
    private var pickerPresented: Binding<Bool> {
        Binding(
            get: { isPickerPresented },
            set: { presented in
                guard presented != isPickerPresented else { return }
                isPickerPresented = presented
                onPickerPresentedChange?(presented)
            }
        )
    }

    /// A plain button rather than a `Menu`: 34 languages do not fit in a menu
    /// that the window has to grow for, and a menu cannot carry a search field.
    /// The label lives inside the button so the press style scales what the
    /// user sees.
    ///
    /// The label must **not** opt out of hit testing. It used to carry
    /// `allowsHitTesting(false)` — "the button handles the events for the whole
    /// frame" — and a label with hit testing off is what the button's hit region
    /// is made of: the rail entry still tracked the pointer, so it lit up under
    /// the cursor, but a click never reached the action and the picker never
    /// opened. Nothing above this in the hierarchy can repair that; the click has
    /// to land on the label.
    ///
    /// The popover is presented by the button itself, not by the view that
    /// wraps it. Presentation attached to the style's conditional wrapper
    /// (`Group { if case .rail … }`) never opened either: the modifier was
    /// installed on content whose identity is `_ConditionalContent`, and the
    /// picker silently failed to present while the appearance switcher's —
    /// installed on its button — worked.
    private var trigger: some View {
        Button {
            pickerPresented.wrappedValue.toggle()
        } label: {
            label
        }
        .buttonStyle(SiftPressButtonStyle())
        .popover(isPresented: pickerPresented, arrowEdge: popoverEdge) {
            LanguagePickerView(selection: selection) { language in
                onSelect(language)
                pickerPresented.wrappedValue = false
            }
        }
    }

    /// The picker opens toward the window's content, away from the rail edge.
    private var popoverEdge: Edge {
        switch style {
        case .rail: .trailing
        case .sidebar, .settings: .leading
        }
    }

    @ViewBuilder
    private var sized: some View {
        switch style {
        case .rail:
            // The label already carries the rail item's box.
            trigger
        case .sidebar:
            trigger
                .frame(maxWidth: .infinity, minHeight: 30)
        case .settings:
            trigger
                .frame(maxWidth: .infinity, minHeight: 30)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .rail:
            // The rail variant is a rail item first: the same box, icon size
            // and label as the navigation entries above it, so the footer does
            // not introduce a second scale at the bottom of the rail.
            SiftRailItemLabel(symbolName: "globe", title: shortName)
                .foregroundStyle(isPickerPresented ? SiftColor.accent : Color.secondary)

        case .sidebar:
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(selection.displayName)
                    .font(SiftFont.body)
                    .lineLimit(1)
                Spacer(minLength: SiftMetrics.spacingS)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, SiftMetrics.spacingS)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())

        case let .settings(title):
            HStack {
                Text(title.localized)
                    .font(SiftFont.body)
                Spacer()
                HStack(spacing: SiftMetrics.spacingXS) {
                    Text(selection.displayName)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
    }

    /// The rail has room for four characters at most.
    private var shortName: String {
        switch selection {
        case .english: "EN"
        case .simplifiedChinese: "中文"
        case .traditionalChinese: "繁中"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "DE"
        case .french: "FR"
        case .spanish: "ES"
        case .italian: "IT"
        case .brazilianPortuguese: "BR"
        case .russian: "RU"
        case .turkish: "TR"
        case .polish: "PL"
        case .dutch: "NL"
        case .lao: "ລາວ"
        case .arabic: "عربي"
        case .hebrew: "עברית"
        case .persian: "فارسی"
        case .bulgarian: "БГ"
        case .czech: "CS"
        case .danish: "DA"
        case .greek: "ΕΛ"
        case .latinAmericanSpanish: "LAT"
        case .finnish: "FI"
        case .hungarian: "HU"
        case .indonesian: "ID"
        case .malay: "MS"
        case .norwegian: "NO"
        case .europeanPortuguese: "PT"
        case .romanian: "RO"
        case .swedish: "SV"
        case .thai: "ไทย"
        case .ukrainian: "УК"
        case .vietnamese: "VI"
        }
    }
}

/// A fixed-height, searchable list of every shipped language.
///
/// The picker is a popover rather than a menu because the list is longer than
/// the window is tall: a menu would either clip or push the window's edge off
/// screen. The search field narrows the list by endonym, language code or
/// locale identifier, and matching ignores case and diacritics so `espana`
/// finds `Español (España)`.
private struct LanguagePickerView: View {
    let selection: SiftLanguage
    let onSelect: (SiftLanguage) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private static let orderedLanguages = SiftLanguage.allCases.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }

    private var matches: [SiftLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.orderedLanguages }
        return Self.orderedLanguages.filter { language in
            language.displayName.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
                || language.rawValue.range(of: trimmed, options: .caseInsensitive) != nil
                || language.localeIdentifier.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if matches.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 272, height: 360)
        .onAppear {
            // The field is not in a window until after the popover's first
            // layout pass, so focusing it synchronously is ignored.
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(LocalizationKey.languageSearch.localized, text: $query)
                .textFieldStyle(.plain)
                .font(SiftFont.body)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = matches.first { choose(first) }
                }
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .frame(height: SiftMetrics.fieldHeight + 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(matches) { language in
                    LanguagePickerRow(
                        language: language,
                        isSelected: language == selection
                    ) {
                        choose(language)
                    }
                }
            }
            .padding(.vertical, SiftMetrics.spacingXS)
            .padding(.horizontal, SiftMetrics.spacingXS)
        }
        .scrollIndicators(.visible)
    }

    private var emptyState: some View {
        VStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(LocalizationKey.languageNoResults.localized)
                .font(SiftFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SiftMetrics.spacingL)
    }

    private func choose(_ language: SiftLanguage) {
        onSelect(language)
    }
}

/// One row of the language picker: a checkmark column, the endonym, and a
/// hover/selection fill that keeps the current language visible while the list
/// scrolls.
private struct LanguagePickerRow: View {
    let language: SiftLanguage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                    .opacity(isSelected ? 1 : 0)
                Text(language.displayName)
                    .font(SiftFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? SiftColor.accent : .primary)
            .padding(.horizontal, SiftMetrics.spacingS)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .fill(background)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("language.\(language.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return SiftColor.selectedFill }
        return isHovering ? SiftColor.hoverFill : .clear
    }
}
