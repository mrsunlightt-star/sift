import SwiftUI

/// A white panel with a hairline border, matching the content surfaces in the
/// design mockups.
public struct SiftPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = SiftMetrics.spacingL, @ViewBuilder content: () -> Content) {
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
                    .stroke(SiftColor.border, lineWidth: SiftMetrics.panelBorderWidth)
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

/// A page header: the date line, a display title and optional trailing actions.
public struct PageHeader<Trailing: View>: View {
    private let titleKey: LocalizationKey
    private let subtitle: String?
    private let trailing: Trailing

    public init(titleKey: LocalizationKey, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.titleKey = titleKey
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(subtitle ?? SiftFormat.timestamp(Date()))
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                Text(titleKey.localized)
                    .font(SiftFont.display)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SiftMetrics.spacingL)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    public init(titleKey: LocalizationKey, subtitle: String? = nil) {
        self.init(titleKey: titleKey, subtitle: subtitle) { EmptyView() }
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
