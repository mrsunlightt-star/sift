import Foundation
import SwiftUI

// The shared component primitives. A page composes these and nothing else: no
// page introduces a second palette, a second surface or a second button.
//
// V2 rule, and the reason this file is shaped the way it is: a surface earns its
// paint. Most content on a page is separated by whitespace and a hairline, not by
// a card, so the default surface here is a plain one. A fill, a border and a
// radius exist for the cases the design study names — a floating sheet, a small
// meaningful group — and glass is not one of them: nothing in this file blurs
// what is behind it, because a blurred surface under every section is what made
// the old pages read as a stack of panes.

// MARK: - Surfaces

/// A page section, in one of four surface styles.
///
/// - `plain` (default): no fill, no border, no shadow. Whitespace, the page's own
///   rhythm and `SiftHairline` are what separate one group from the next.
/// - `outlined`: a `surfaceColor` fill with a 1 pt `divider` border, for content
///   that is genuinely a block — a form, an empty state, a group the user acts on
///   as a unit.
/// - `subtle`: a single small group that needs to be read as one thing without
///   becoming a card; a low-contrast wash (`brandWash`) and the same hairline.
/// - `floating`: sheets and popovers only. It takes the raised fill, because the
///   platform already draws the elevation for the window it is in; drawing a
///   second shadow inside a sheet is the doubled depth the design study rules out.
///
/// A page should not become a grid of outlined cards: reach for `.outlined` when
/// the block is an object, not for every heading.
public struct SiftSection<Content: View>: View {
    public enum Style: String, Sendable, CaseIterable {
        case plain
        case outlined
        case subtle
        case floating
    }

    private let style: Style
    private let padding: CGFloat?
    private let cornerRadius: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - style: the surface, `.plain` unless the content is an object.
    ///   - padding: the inset; `nil` asks the style for its own (0 for `.plain`,
    ///     `spacingL` for a painted surface, so text never touches a border).
    ///   - cornerRadius: ignored by `.plain`, which paints nothing to round.
    public init(
        style: Style = .plain,
        padding: CGFloat? = nil,
        cornerRadius: CGFloat = SiftMetrics.cornerRadiusM,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    private var resolvedPadding: CGFloat {
        padding ?? (style == .plain ? 0 : SiftMetrics.spacingL)
    }

    private var fill: Color? {
        switch style {
        case .plain: nil
        case .outlined: SiftColor.surfaceColor
        case .subtle: SiftColor.brandWash
        case .floating: SiftColor.elevatedSurface
        }
    }

    private var hasBorder: Bool {
        switch style {
        case .plain: false
        case .outlined, .subtle, .floating: true
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(resolvedPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let fill {
                    shape.fill(fill)
                }
            }
            .overlay {
                if hasBorder {
                    shape.strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
                }
            }
    }
}

/// A section rule: the line that separates two groups on a plain page.
///
/// One pixel of `divider`, not of the system's own separator, so a rule on a page
/// and a rule between two sections are the same weight.
public struct SiftHairline: View {
    private let inset: CGFloat

    public init(inset: CGFloat = 0) {
        self.inset = inset
    }

    public var body: some View {
        Rectangle()
            .fill(SiftColor.divider)
            .frame(height: SiftMetrics.panelBorderWidth)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

/// A flat content block, kept under its old name for the call sites that already
/// use it.
///
/// This used to be three layers of blur, a tint, a lit top edge and a glow. V2
/// makes it the outlined section and nothing else: the same padding at the same
/// radius, so a page that has not been rewritten yet keeps its geometry while the
/// material stack and the decorative shadow are gone from the app.
///
/// `surface` is accepted and ignored. Its only two callers pass `.floating` for
/// content hosted by a sheet, which already carries the platform's own elevation;
/// a fill there would draw a card inside a sheet.
public struct SiftGlassCard<Content: View>: View {
    private let surface: SiftSurface
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

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
        SiftSection(style: .outlined, padding: padding, cornerRadius: cornerRadius) {
            content
        }
    }
}

/// A bordered panel. Kept under its old name; it is now exactly the outlined
/// section, which is what the hairline it always promised actually is.
public struct SiftPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = SiftMetrics.spacingXL, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        SiftSection(style: .outlined, padding: padding) {
            content
        }
    }
}

/// The window background: one flat canvas colour.
///
/// The two ambient glows that used to sit here existed to give the material
/// something to blur. With no material on an ordinary page there is nothing to
/// show through, so the canvas is what the design study asks for — a quiet field
/// that leaves the content as the only thing with edges.
public struct SiftCanvasBackground: View {
    public init() {}

    public var body: some View {
        SiftColor.canvasSurface
            .ignoresSafeArea()
    }
}

// MARK: - Page chrome

/// A page header: the title, an optional status line beneath it, and the page's
/// trailing controls.
///
/// The title is the anchor — `pageTitle`, `mainText`, the largest thing on the
/// page — and the status is quiet metadata under it. There is no decorative dot
/// beside the status any more: a mark that is always there and never means
/// anything is a second accent on a page that has one real action. The rule below
/// is a plain hairline rather than a gradient that fades out at the edges; the
/// fade read as a decorative flourish and did not survive the V2 pass.
public struct SiftPageHeader<Trailing: View>: View {
    private let title: String
    private let status: String?
    private let trailing: Trailing

    public init(
        title: String,
        /// Shown only when it says something the title does not. An empty string
        /// is the same as no status.
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
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    if let status, !status.isEmpty {
                        Text(status)
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(title)
                        // `display` is the ladder's own name for the page
                        // title (28 pt semibold); `pageTitle` is the metric it
                        // resolves to.
                        .siftFont(.display)
                        .foregroundStyle(SiftColor.mainText)
                        .fixedSize(horizontal: false, vertical: true)
                        // The page's one heading. VoiceOver's rotor and the
                        // window's reading order both need it to say so.
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: SiftMetrics.spacingL)
                trailing
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.top, SiftMetrics.spacingL)
            .padding(.bottom, SiftMetrics.spacingM)

            SiftHairline()
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

/// The entrance: a short fade, and nothing else.
///
/// This used to rise 10 pt and wait a step behind its siblings, which read as a
/// page assembling itself out of parts. V2 wants the content to be there, so the
/// rise and the stagger are gone and only the opacity change remains — which is
/// also what the user asked for when they turned Reduce Motion on.
///
/// `index` stays in the signature because six call sites pass it and they are not
/// this file's to edit; it no longer orders anything.
struct SiftAppear: ViewModifier {
    let index: Int
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? nil : SiftMotion.quick) {
                    shown = true
                }
            }
    }
}

public extension View {
    /// Fades the view in. The index is accepted for source compatibility and
    /// ignored: there is no wave to take a position in any more.
    func siftAppear(index: Int = 0) -> some View {
        modifier(SiftAppear(index: index))
    }
}

// MARK: - Fields

public extension View {
    /// The quiet well a text field sits in: a control fill and a hairline border.
    ///
    /// The caller owns its padding and height; this draws only the surface, so a
    /// search field and a form field can share it without agreeing on content.
    func siftFieldSurface(
        cornerRadius: CGFloat = SiftMetrics.controlCornerRadius - 2
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(SiftColor.controlFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
        }
    }
}

// MARK: - Buttons

/// The primary action: one solid `actionFill` rectangle, 40 pt high, 8 pt radius.
///
/// No gradient, no lit edge, no glow. Hover and press both move the fill to
/// `actionGreenHover` rather than adding a highlight on top of it, so the button
/// has exactly two appearances and both of them carry the label at 5.16:1 in light
/// mode and 7.13:1 in dark.
///
/// Disabled keeps the label readable instead of washing the whole control out:
/// white on a diluted green measures under 3:1, so the fill drops to `controlFill`
/// and the label takes `quietText` — a grey button that still says what it does.
public struct SiftPrimaryButton: View {
    private let title: String
    private let symbolName: String?
    private let isEnabled: Bool
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

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

    private var fillColor: Color {
        guard isEnabled else { return SiftColor.controlFill }
        return isHovering ? SiftColor.actionGreenHover : SiftColor.actionFill
    }

    /// The glyph and the word in one colour: the pair the fill was measured
    /// against, not a fill token the label would be painted with.
    private var labelColor: Color {
        isEnabled ? SiftColor.onActionFill : SiftColor.quietText
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
            .foregroundStyle(labelColor)
            .padding(.horizontal, SiftMetrics.spacingXL)
            .frame(minHeight: SiftMetrics.buttonHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                // A disabled control keeps a hairline so it still reads as a
                // control; an enabled one needs no border at all.
                if !isEnabled {
                    RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                        .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
                }
            }
            // 40 pt of paint, 44 pt of target: the extra 2 pt on each side is
            // taken back out of the layout, so the button sits where the design
            // says while the pointer gets a target it can hit.
            .padding(.vertical, (SiftMetrics.minimumHitTarget - SiftMetrics.buttonHeight) / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -(SiftMetrics.minimumHitTarget - SiftMetrics.buttonHeight) / 2)
        }
        .buttonStyle(SiftPressButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
    }
}

/// The secondary action: a quiet button beside the primary one.
///
/// It is deliberately not a second filled control. The fill only appears under
/// the pointer, the border is the 1 pt `divider` the rest of the page uses, and
/// the label is `mainText` at 13.81:1 — a native-looking button that cannot
/// compete with the one action the page is offering.
public struct SiftSecondaryButton: View {
    private let title: String
    private let symbolName: String?
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

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
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(SiftColor.mainText)
            .padding(.horizontal, SiftMetrics.spacingL)
            .frame(minHeight: SiftMetrics.buttonHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(isHovering ? SiftColor.rowHoverFill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
            }
            .padding(.vertical, (SiftMetrics.minimumHitTarget - SiftMetrics.buttonHeight) / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -(SiftMetrics.minimumHitTarget - SiftMetrics.buttonHeight) / 2)
        }
        .buttonStyle(SiftPressButtonStyle())
        .accessibilityLabel(Text(title))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
    }
}

/// A plain icon button used in dense rows and page headers.
public struct SiftIconButton: View {
    private let symbolName: String
    private let help: String
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(symbolName: String, help: String, action: @escaping () -> Void) {
        self.symbolName = symbolName
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                // The glyph is read, so it takes the text token: `actionGreen` is
                // the colour that clears 4.5:1 on a row. `accent` is the fill and
                // is 2.43:1 there — an icon nobody can see is not an icon.
                .foregroundStyle(isHovering ? SiftColor.actionGreen : SiftColor.quietText)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .fill(isHovering ? SiftColor.rowHoverFill : Color.clear)
                }
                // 30 pt of paint, 44 pt of target: 7 pt on each side, given
                // back to the layout so a dense row keeps its height.
                .padding((SiftMetrics.minimumHitTarget - 30) / 2)
                .contentShape(Rectangle())
                .padding(-(SiftMetrics.minimumHitTarget - 30) / 2)
        }
        .buttonStyle(.plain)
        .help(help)
        // The glyph has no spoken name of its own once the tooltip is a hint
        // rather than a label; VoiceOver reads the same words.
        .accessibilityLabel(Text(help))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
    }
}

/// A link in the app's own accent.
///
/// The system link style is blue, which puts a second accent colour on a page
/// whose primary action is jade. This style keeps link semantics — a text button
/// with no chrome — and uses `actionGreen`, the text twin of the action fill,
/// easing out on hover.
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
            .foregroundStyle(SiftColor.actionGreen)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .underline(isHovering && !configuration.isPressed, color: SiftColor.actionGreen.opacity(0.6))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Scale-on-press, the interaction the design language specifies for every
/// control with a fill.
///
/// 0.98 rather than 0.97: the button is the largest thing that moves, and the
/// deeper scale read as a bounce on a control that is pressed dozens of times in a
/// row.
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
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
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
                .foregroundStyle(SiftColor.mainText)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .siftFont(.heroUnit)
                    .foregroundStyle(SiftColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded icon tile used at the start of a row.
///
/// One flat wash of the tint and the glyph on top. It used to be a two-stop
/// gradient, which is decoration on a 32 pt square: at this size the gradient is
/// two shades of one colour nobody can tell apart.
public struct IconTile: View {
    private let symbolName: String
    private let tint: Color

    public init(symbolName: String, tint: Color = SiftColor.actionGreen) {
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: SiftMetrics.iconTileSize, height: SiftMetrics.iconTileSize)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

/// Risk badge.
///
/// Colour is never the only signal: the badge always carries a word and its own
/// glyph, which is what §11.4 asks for and what a colour-blind reader needs. The
/// shape is a small label on a wash, not a lozenge — a risk level is metadata
/// beside a row, not a badge the page is about.
public struct RiskBadge: View {
    private let risk: RiskLevel

    public init(risk: RiskLevel) {
        self.risk = risk
    }

    /// The wash under the label. The theme names a text colour and a wash per
    /// semantic role; a badge needs the second one, and painting the text colour
    /// at an opacity would put the two roles on one token.
    private var wash: Color {
        switch risk {
        case .safe: SiftColor.safeWash
        case .review: SiftColor.reviewWash
        case .protected: SiftColor.protectedWash
        }
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingXS) {
            Image(systemName: risk.symbolName)
                .font(.system(size: 8, weight: .bold))
            Text(risk.labelKey.localized)
                .font(SiftFont.metadata)
        }
        .foregroundStyle(SiftColor.textColor(for: risk))
        .padding(.horizontal, SiftMetrics.spacingS)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .fill(wash)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(risk.labelKey.localized))
        .accessibilityHint(Text(risk.detailKey.localized))
    }
}

/// A filter chip: one line, 32 pt, 8 pt radius.
///
/// The selected chip is `selectedWash` with `actionGreen` text and the
/// `selectedBorder` hairline — the same treatment a selected row and a selected
/// rail entry wear, so "this one is chosen" looks the same everywhere in the app.
/// It is not a solid `actionFill` chip: a filter is a view of the list, not the
/// page's action, and a row of solid green pills competed with the one real button.
/// `actionGreen` on that wash measures 4.66:1 in light mode and clears AA.
public struct SiftFilterChip: View {
    private let title: String
    private let detail: String?
    private let isSelected: Bool
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    private var fillColor: Color {
        if isSelected { return SiftColor.selectedWash }
        return isHovering ? SiftColor.rowHoverFill : SiftColor.controlFill
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SiftMetrics.spacingS) {
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                if let detail {
                    Text(detail)
                        .font(SiftFont.metadata)
                        // A quieter second line of text, not the title's colour
                        // at an opacity: 70 % of a green is not a text token and
                        // measures under 4.5:1 on the wash.
                        .foregroundStyle(SiftColor.secondaryText)
                }
            }
            .foregroundStyle(isSelected ? SiftColor.actionGreen : SiftColor.mainText)
            .padding(.horizontal, SiftMetrics.spacingM)
            .frame(minHeight: SiftMetrics.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? SiftColor.selectedBorder : SiftColor.divider,
                        lineWidth: SiftMetrics.panelBorderWidth
                    )
            }
            .padding(.vertical, (SiftMetrics.minimumHitTarget - SiftMetrics.chipHeight) / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -(SiftMetrics.minimumHitTarget - SiftMetrics.chipHeight) / 2)
        }
        .buttonStyle(SiftPressButtonStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
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
                // The action pair, which the palette measured: `actionFill` with
                // `onActionFill` on it. The border is the same fill, so the mark
                // has no outline of a second colour.
                .fill(isOn && isEnabled ? SiftColor.actionFill : SiftColor.controlFill)
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .strokeBorder(
                            isOn && isEnabled ? SiftColor.actionFill : SiftColor.divider,
                            lineWidth: SiftMetrics.panelBorderWidth
                        )
                }
                .overlay {
                    if isOn && isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(SiftColor.onActionFill)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.4, anchor: .center).combined(with: .opacity)
                            )
                    }
                }
                .frame(width: 18, height: 18)
                // A disabled box keeps a readable border: at 0.35 the whole
                // control disappeared and a list of protected items looked empty.
                .opacity(isEnabled ? 1 : 0.55)
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
///
/// One solid fill on a `divider` track. The two-stop gradient it used to carry
/// described nothing — a bar states a fraction, and the eye reads the fraction
/// from the length, not from a shade change along it.
public struct UsageBar: View {
    private let fraction: Double
    private let tint: Color
    private let height: CGFloat

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(fraction: Double, tint: Color = SiftColor.actionFill, height: CGFloat = 8) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(SiftColor.divider)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : SiftMotion.settle, value: fraction)
        .accessibilityHidden(true)
    }
}

/// A stacked bar showing several segments of one total.
///
/// The segments are the category colours and they carry meaning, so they are
/// already solid; the gaps between them are what keeps two adjacent segments
/// readable as two.
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
///
/// The determinate stroke is one solid colour: a progress indicator is allowed a
/// gradient where it says something, and a shade that fades along the arc says
/// nothing about how far along the run is. The one gradient left is the
/// indeterminate arc, where the fading tail is what makes a moving segment read as
/// motion rather than as a static mark at an arbitrary angle.
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
        tint: Color = SiftColor.actionFill,
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
                .stroke(SiftColor.divider, lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(progress, 0.001))
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : SiftMotion.progress, value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.34)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.18), tint, tint.opacity(0.18)],
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

            VStack(spacing: SiftMetrics.spacingXS) {
                if let label {
                    Text(label)
                        // On the type ladder, not a size of its own: the ring's
                        // numeral used to be a private 22 pt and ignored the
                        // reader's type-size setting.
                        .siftFont(.heroUnit)
                        .foregroundStyle(SiftColor.mainText)
                        .monospacedDigit()
                }
                if let caption {
                    Text(caption)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel ?? label ?? ""))
        .accessibilityValue(Text(spokenValue ?? caption ?? ""))
    }
}

// MARK: - Rows and states

/// A selectable row surface: a 52 pt row with a hover wash and a selected wash.
///
/// Selection is never a saturated fill. A list of twelve rows where the chosen one
/// is painted in the action colour is a list with a button in it; `selectedWash`
/// plus the `selectedBorder` hairline says "this one" and leaves the row's own
/// text and risk badge as the brightest things in it.
///
/// The row is one button, and the caller's content owns everything inside it — a
/// checkbox in the content has its own 44 pt target and does not send the row's
/// action, which is the two behaviours the design study asks for: clicking the row
/// selects it, clicking the box ticks it.
public struct SiftSelectableRow<Content: View>: View {
    private let isSelected: Bool
    private let content: Content
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    private var fillColor: Color {
        if isSelected { return SiftColor.selectedWash }
        return isHovering ? SiftColor.rowHoverFill : Color.clear
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, SiftMetrics.spacingM)
                .frame(maxWidth: .infinity, minHeight: SiftMetrics.rowHeight, alignment: .leading)
                .background { shape.fill(fillColor) }
                .overlay {
                    shape.strokeBorder(
                        isSelected ? SiftColor.selectedBorder : Color.clear,
                        lineWidth: SiftMetrics.panelBorderWidth
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
        .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An empty-state block: a symbol resting in a quiet well, a headline and a short
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
                .foregroundStyle(SiftColor.quietText)
                .frame(width: 56, height: 56)
                .background(Circle().fill(SiftColor.controlFill))
                .overlay(Circle().strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth))
                .accessibilityHidden(true)
            Text(titleKey.localized)
                .siftFont(.sectionTitle)
                .foregroundStyle(SiftColor.mainText)
                .multilineTextAlignment(.center)
            if let detailKey {
                Text(detailKey.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else if let detail {
                Text(detail)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.secondaryText)
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
                .fill(SiftColor.controlFill)
                .frame(width: 18, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
                }
            VStack(alignment: .leading, spacing: 6) {
                bar(width: isFirst ? 180 : 220, height: 11)
                bar(width: isFirst ? 260 : 300, height: 9)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            bar(width: 56, height: 11)
        }
        .frame(minHeight: SiftMetrics.rowHeight)
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
            .fill(SiftColor.divider)
            .frame(width: width, height: height)
    }
}

/// A message surface for skips, partial failures and warnings.
///
/// The role is carried by three things and never by colour alone: the glyph, the
/// sentence itself, and a small wash. What it is not is a large coloured panel —
/// the semantic washes measure a few percent away from the canvas, so the banner
/// states its role with an icon on a wash and a hairline border, at the weight of
/// a note beside the content rather than a block over it.
public struct NoticeBanner: View {
    public enum Level: String, Sendable, CaseIterable {
        case information
        case warning
        case error
        case success

        /// The banner's surface: a small wash, which is a fill role.
        var wash: Color {
            switch self {
            case .information: SiftColor.infoWash
            case .warning: SiftColor.reviewWash
            case .error: SiftColor.dangerWash
            case .success: SiftColor.safeWash
            }
        }

        /// The banner's icon: a small glyph the user reads, so it takes the text
        /// twin of `wash`. On the accent pair that is 2.43:1 against the banner's
        /// own background instead of 4.5:1.
        var glyph: Color {
            switch self {
            case .information: SiftColor.infoTextColor
            case .warning: SiftColor.reviewTextColor
            case .error: SiftColor.dangerTextColor
            case .success: SiftColor.safeTextColor
            }
        }

        /// The hairline: a tinted rule, at an opacity low enough to stay a rule
        /// rather than become a frame around the message.
        var border: Color {
            glyph.opacity(0.28)
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
        let shape = RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
            Image(systemName: level.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(level.glyph)
                .accessibilityHidden(true)
            Text(message)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)
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
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, SiftMetrics.spacingS)
        .background { shape.fill(level.wash) }
        .overlay { shape.strokeBorder(level.border, lineWidth: SiftMetrics.panelBorderWidth) }
        .accessibilityElement(children: .contain)
    }
}

/// A primary block: an icon, a short headline, an explanation and the action
/// that belongs to them.
///
/// Flat: one wash of the tint, a hairline in the same tint and the content on top.
/// The material, the three-stop gradient and the 14 pt shadow it used to carry
/// were the glass treatment on the single largest surface in the app, which is
/// exactly where it made ordinary content look like a floating pane.
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
        tint: Color = SiftColor.actionFill,
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
        HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(title)
                    .siftFont(.title)
                    .foregroundStyle(SiftColor.mainText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .padding(.top, SiftMetrics.spacingXS)
            }

            Spacer(minLength: 0)
        }
        .padding(SiftMetrics.spacingXL)
        .background { shape.fill(tint.opacity(0.10)) }
        .overlay { shape.strokeBorder(tint.opacity(0.22), lineWidth: SiftMetrics.panelBorderWidth) }
    }
}

/// A small labelled value used in the page summary strips.
///
/// The pill is two roles at once and used to be painted with one colour: the wash
/// and hairline are a *fill*, while the value and the glyph beside it are text the
/// user reads. On the accent pair that is the difference between 2.43:1 and
/// 5.16:1, so the pigment is named by `Tone` rather than passed as a `Color` — a
/// call site cannot hand a fill token to the label.
///
/// `neutral` is the default because most pills are metadata: a count, a date, a
/// size. A pill takes a semantic tone when it states a state — a scan that came
/// back partial, an item that may need a look — and that is the only reason for
/// pigment to appear in a summary strip.
public struct SiftMetricPill: View {
    /// The palette pair a pill is painted with: `wash` for its surface, `glyph`
    /// for the value and icon.
    public enum Tone: String, Sendable, CaseIterable {
        case accent
        case safe
        case review
        case neutral

        var wash: Color {
            switch self {
            case .accent: return SiftColor.brandWash
            case .safe: return SiftColor.safeWash
            case .review: return SiftColor.reviewWash
            case .neutral: return SiftColor.controlFill
            }
        }

        var glyph: Color {
            switch self {
            case .accent: return SiftColor.actionGreen
            case .safe: return SiftColor.safeTextColor
            case .review: return SiftColor.reviewTextColor
            case .neutral: return SiftColor.quietText
            }
        }
    }

    private let symbolName: String
    private let value: String
    private let tone: Tone

    public init(symbolName: String, value: String, tone: Tone = .neutral) {
        self.symbolName = symbolName
        self.value = value
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(value)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()
        }
        .foregroundStyle(tone.glyph)
        .padding(.horizontal, SiftMetrics.spacingM)
        .frame(minHeight: SiftMetrics.chipHeight)
        .background {
            RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                .fill(tone.wash)
        }
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
        }
        .accessibilityElement(children: .combine)
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
/// tracks the pointer, and — for an entry that is a destination — the mark on its
/// leading edge.
///
/// Every entry wears it: the four destinations, the appearance switcher, the
/// account entry, the language control and settings. One implementation is what
/// keeps a footer press reading exactly like a navigation press; the fills are
/// adaptive, so light and dark modes both get them.
///
/// The mark is `actionFill`, not the brand green: on the selection wash the brand
/// colour is 1.9:1, which is a mark the user cannot see, and the mark is the one
/// thing in the rail that has to be legible at a glance.
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
        if fillsSelection && isSelected { return SiftColor.selectedWash }
        if isHovering && !isSelected { return SiftColor.rowHoverFill }
        return .clear
    }

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.sidebarRowRadius, style: .continuous)
                    .fill(fillColor)
                    .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
                    .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
            }
            .overlay(alignment: .leading) {
                // The selection mark: a bar on the item's left edge, so the
                // page the window is showing reads without a border boxing the
                // item in. Only a destination can be "the page you are on".
                Capsule()
                    .fill(SiftColor.actionFill)
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

    /// The picker opens toward the window's content, away from the edge the
    /// control sits against.
    ///
    /// Both fixed columns are on the left — the retired icon rail and the V2
    /// sidebar alike — so both point the picker right, over the content. A
    /// `.leading` arrow on a control 12 pt from the window's left edge aims the
    /// popover at the wall; only the Settings form, which sits inside the
    /// scrolling content, still opens leftward.
    private var popoverEdge: Edge {
        switch style {
        case .rail, .sidebar: .trailing
        case .settings: .leading
        }
    }

    @ViewBuilder
    private var sized: some View {
        switch style {
        case .rail:
            // The label already carries the rail item's box.
            trigger
        case .sidebar:
            // 44 pt, not the 32 pt the label draws: a sidebar row is pressed
            // with a pointer on a trackpad, and `01 §Spacing` holds every hit
            // target at 44×44 while the destination rows above are 44.
            trigger
                .frame(maxWidth: .infinity, minHeight: SiftMetrics.minimumHitTarget)
        case .settings:
            trigger
                .frame(maxWidth: .infinity, minHeight: SiftMetrics.chipHeight)
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
                .foregroundStyle(isPickerPresented ? SiftColor.actionGreen : SiftColor.quietText)

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
                    .foregroundStyle(SiftColor.quietText)
            }
            .foregroundStyle(SiftColor.secondaryText)
            .padding(.horizontal, SiftMetrics.spacingS)
            .frame(maxWidth: .infinity, minHeight: SiftMetrics.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())

        case let .settings(title):
            HStack {
                Text(title.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
                Spacer()
                HStack(spacing: SiftMetrics.spacingXS) {
                    Text(selection.displayName)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
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
            SiftHairline()
            if matches.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: SiftMetrics.summaryColumnWidth, height: 360)
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
                .foregroundStyle(SiftColor.quietText)
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
                .foregroundStyle(SiftColor.quietText)
            Text(LocalizationKey.languageNoResults.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.secondaryText)
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
///
/// 34 pt rather than the 30 it used to be: the row is a target, and this is the
/// densest list in the app short of the results table, so it takes the field
/// height the rest of the controls use instead of a size of its own.
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
            .foregroundStyle(isSelected ? SiftColor.actionGreen : SiftColor.mainText)
            .padding(.horizontal, SiftMetrics.spacingS)
            .frame(height: SiftMetrics.fieldHeight)
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
        if isSelected { return SiftColor.selectedWash }
        return isHovering ? SiftColor.rowHoverFill : .clear
    }
}
