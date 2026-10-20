import SwiftUI

/// A panel with a hairline border, the surface every section sits on.
public struct SiftPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = SiftMetrics.spacingXL, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SiftColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                    .stroke(SiftColor.border.opacity(0.7), lineWidth: SiftMetrics.panelBorderWidth)
            }
    }
}

/// A stat tile: a label, a large value and an optional caption.
///
/// Used for "Can be cleaned", "Apps to remove" and "Large files" on the
/// dashboard.
public struct StatTile: View {
    private let titleKey: LocalizationKey
    private let value: String
    private let caption: String?
    private let symbolName: String
    private let tint: Color

    public init(
        title: LocalizationKey,
        value: String,
        caption: String? = nil,
        symbolName: String,
        tint: Color = SiftColor.accent
    ) {
        self.titleKey = title
        self.value = value
        self.caption = caption
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Label {
                    Text(titleKey.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                }
                .labelStyle(.titleAndIcon)

                Text(value)
                    .font(SiftFont.metric)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text(titleKey.localized))
                    .accessibilityValue(Text(value))

                if let caption {
                    Text(caption)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
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
            .fill(tint.opacity(0.14))
            .frame(width: SiftMetrics.iconTileSize, height: SiftMetrics.iconTileSize)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}

/// Risk badge.
///
/// Colour is never the only signal: the badge always carries an SF Symbol and a
/// word, as §11.4 requires for accessibility and for colour-blind users.
public struct RiskBadge: View {
    private let risk: RiskLevel

    public init(risk: RiskLevel) {
        self.risk = risk
    }

    public var body: some View {
        Label {
            Text(risk.labelKey.localized)
                .font(SiftFont.badge)
        } icon: {
            Image(systemName: risk.symbolName)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(SiftColor.color(for: risk))
        .padding(.horizontal, SiftMetrics.spacingS)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(SiftColor.color(for: risk).opacity(0.14))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(risk.labelKey.localized))
        .accessibilityHint(Text(risk.detailKey.localized))
    }
}

/// A coloured bar showing how much of a total a value represents.
public struct UsageBar: View {
    private let fraction: Double
    private let tint: Color
    private let height: CGFloat

    public init(fraction: Double, tint: Color = SiftColor.accent, height: CGFloat = 8) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(SiftColor.neutral.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A stacked bar showing several segments of one total, used by the storage
/// overview. Each segment is labelled in the legend beside it, so colour is
/// never the only key.
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

    public init(segments: [Segment], height: CGFloat = 10) {
        self.segments = segments
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.tint)
                        .frame(width: max(geometry.size.width * segment.fraction - 2, 0))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A row that resembles the sidebar and list rows in the mockups: icon tile,
/// title, optional subtitle, trailing content.
public struct SiftRow<Trailing: View>: View {
    private let symbolName: String
    private let tint: Color
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(
        symbolName: String,
        tint: Color = SiftColor.accent,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.symbolName = symbolName
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            IconTile(symbolName: symbolName, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: SiftMetrics.spacingS)
            trailing
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .frame(minHeight: SiftMetrics.rowHeight)
    }
}

extension SiftRow where Trailing == EmptyView {
    public init(symbolName: String, tint: Color = SiftColor.accent, title: String, subtitle: String? = nil) {
        self.init(symbolName: symbolName, tint: tint, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

/// An empty-state block: a symbol, a headline and a short explanation.
///
/// `ContentUnavailableView` is macOS 14 and later, so the macOS 13 baseline
/// needs its own implementation (§6.1).
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
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(titleKey.localized)
                .font(SiftFont.sectionTitle)
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

/// The primary call-to-action button.
public struct PrimaryActionButton: View {
    private let titleKey: LocalizationKey
    private let symbolName: String?
    private let action: () -> Void

    public init(titleKey: LocalizationKey, symbolName: String? = nil, action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.symbolName = symbolName
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SiftMetrics.spacingS) {
                if let symbolName {
                    Image(systemName: symbolName)
                }
                Text(titleKey.localized)
                    .font(SiftFont.bodyEmphasis)
            }
            .padding(.horizontal, SiftMetrics.spacingL)
            .frame(minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
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
                .buttonStyle(.link)
            }
        }
        .padding(SiftMetrics.spacingM)
        .background(level.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A page header: an eyebrow naming the sidebar group, a display title, an
/// optional subtitle and trailing actions aligned with the title.
///
/// The eyebrow is what ties a page to the group it was opened from, so the
/// window has a readable hierarchy instead of a title floating over a card.
public struct PageHeader<Trailing: View>: View {
    private let eyebrowKey: LocalizationKey?
    private let titleKey: LocalizationKey
    private let subtitle: String?
    private let trailing: Trailing

    public init(
        titleKey: LocalizationKey,
        eyebrowKey: LocalizationKey? = nil,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.titleKey = titleKey
        self.eyebrowKey = eyebrowKey
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: SiftMetrics.spacingXL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                if let eyebrowKey {
                    Text(eyebrowKey.localized)
                        .font(SiftFont.eyebrow)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(SiftColor.accent)
                }
                Text(titleKey.localized)
                    .font(SiftFont.display)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SiftMetrics.spacingL)
            trailing
                .padding(.bottom, 2)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    public init(titleKey: LocalizationKey, eyebrowKey: LocalizationKey? = nil, subtitle: String? = nil) {
        self.init(titleKey: titleKey, eyebrowKey: eyebrowKey, subtitle: subtitle) { EmptyView() }
    }
}

/// A labelled horizontal bar chart row, used instead of a ring chart (§5.4
/// explicitly ranks accurate lists above elaborate charts).
public struct BreakdownBar: View {
    private let label: String
    private let value: String
    private let fraction: Double
    private let tint: Color

    public init(label: String, value: String, fraction: Double, tint: Color) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            HStack {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(label)
                    .font(SiftFont.body)
                Spacer(minLength: SiftMetrics.spacingS)
                Text(value)
                    .font(SiftFont.bodyEmphasis)
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction, tint: tint, height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}

/// The scrolling page column.
///
/// Every page uses the same outer margins and vertical rhythm; only the column
/// width changes with the kind of content. That consistency is what makes the
/// pages look like one app when the window is wide, instead of a set of columns
/// that each chose their own alignment.
public struct SiftPage<Content: View>: View {
    private let maxWidth: CGFloat
    private let content: Content

    public init(maxWidth: CGFloat = SiftMetrics.contentWidthWide, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                content
            }
            .padding(.horizontal, SiftMetrics.spacingXXL)
            .padding(.top, SiftMetrics.spacingXL)
            .padding(.bottom, SiftMetrics.spacingXXL)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(SiftColor.windowBackground)
    }
}

/// A primary block: an icon, a short headline, an explanation and the action
/// that belongs to them, on one tinted surface.
///
/// The empty and first-run states use this instead of centring a small card in a
/// large blank area: the block fills the page column deliberately, and the
/// action sits where the eye already is.
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
        HStack(alignment: .top, spacing: SiftMetrics.spacingXL) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.24), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(title)
                    .font(SiftFont.title)
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
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusXL, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.10), SiftColor.panel],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusXL, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: SiftMetrics.panelBorderWidth)
        }
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
                .font(.system(size: 11, weight: .semibold))
            Text(value)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// The language control.
///
/// The sidebar footer and the settings page both render this view and both call
/// the same selection closure, so the choice is written by one function and the
/// two locations cannot disagree about how it is stored.
public struct LanguageMenu: View {
    public enum Style: Sendable {
        /// A sidebar footer row: globe, current language and a disclosure glyph.
        case sidebar
        /// A settings row: the label on the left, the current language on the right.
        case settings(title: LocalizationKey)
    }

    private let selection: SiftLanguage
    private let style: Style
    private let identifier: String
    private let onSelect: (SiftLanguage) -> Void

    public init(
        selection: SiftLanguage,
        style: Style,
        identifier: String = "language.menu",
        onSelect: @escaping (SiftLanguage) -> Void
    ) {
        self.selection = selection
        self.style = style
        self.identifier = identifier
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(SiftLanguage.allCases) { language in
                Button {
                    onSelect(language)
                } label: {
                    HStack {
                        Text(language.displayName)
                        if language == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier("language.\(language.rawValue)")
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(LocalizationKey.settingsGroupLanguage.localized))
        .accessibilityValue(Text(selection.displayName))
    }

    @ViewBuilder
    private var label: some View {
        switch style {
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
}
