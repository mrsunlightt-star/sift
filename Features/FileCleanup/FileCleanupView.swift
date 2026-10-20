import Core
import Shared
import SwiftUI

/// File cleanup: large files, old files and duplicates (§5.5).
///
/// The three modes are filters over one scan, so the selection and confirmation
/// flow is identical to junk cleanup, and the page shows only the category it
/// owns. The duplicate mode is the one with its own scope: only the folders the
/// user granted, which are managed in Settings rather than here.
public struct FileCleanupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    /// Set by the shell: authorisation is managed in one place, and this page
    /// links there instead of offering a second copy of it.
    private let onManageScope: () -> Void
    @State private var mode: FileCleanupMode = .large

    public init(
        onRequestPurchase: @escaping () -> Void = {},
        onManageScope: @escaping () -> Void = {}
    ) {
        self.onRequestPurchase = onRequestPurchase
        self.onManageScope = onManageScope
    }

    public var body: some View {
        SiftPage(maxWidth: SiftMetrics.contentWidthStandard) {
            PageHeader(titleKey: .filesTitle, eyebrowKey: .navGroupCleanup) {
                if environment.scan.hasResults {
                    SiftMetricPill(
                        symbolName: "leaf.fill",
                        value: environment.scan.formattedReclaimable
                    )
                }
            }

            modeBar

            if mode == .duplicates {
                duplicateScopeCard
            }

            if environment.scan.hasResults {
                SelectionBar(
                    cleanup: environment.cleanup,
                    environment: environment,
                    operation: mode.operationName,
                    onRequestPurchase: onRequestPurchase
                )
                ScanResultsView(
                    scan: environment.scan,
                    cleanup: environment.cleanup,
                    categories: mode.categories
                )
            } else {
                SiftHeroCard(
                    symbolName: mode.symbolName,
                    title: mode.titleKey.localized,
                    detail: modeExplanation,
                    tint: mode.tint
                ) {
                    PrimaryActionButton(titleKey: .dashboardStartScan, symbolName: "viewfinder") {
                        Task { await environment.runScan(.files(mode)) }
                    }
                }
            }
        }
    }

    /// The mode picker and the sentence that explains the selected mode live in
    /// one bar. The picker used to sit in the page header, far from the card it
    /// changed, which made the page read as unrelated fragments.
    private var modeBar: some View {
        SiftPanel(padding: SiftMetrics.spacingL) {
            HStack(spacing: SiftMetrics.spacingL) {
                Picker(String(), selection: $mode) {
                    ForEach(FileCleanupMode.allCases, id: \.self) { mode in
                        Text(mode.titleKey.localized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                Divider()
                    .frame(height: 22)

                Image(systemName: "info.circle")
                    .foregroundStyle(SiftColor.accent)
                    .accessibilityHidden(true)

                Text(modeExplanation)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
    }

    private var modeExplanation: String {
        switch mode {
        case .large:
            LocalizationKey.filesThresholdLarge.localized(
                SiftFormat.bytes(environment.preferences.largeFileThresholdBytes)
            )
        case .old:
            LocalizationKey.filesThresholdOld.localized(environment.preferences.oldFileThresholdDays)
        case .duplicates:
            LocalizationKey.cleanupExplanationDuplicates.localized
        }
    }

    /// The folders a duplicate scan may look in, and the one way to change them.
    ///
    /// Read-only on purpose: adding or removing a grant is authorisation, and
    /// authorisation lives in Settings so there is one place that owns it.
    private var duplicateScopeCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(LocalizationKey.filesScopeTitle.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer()
                    Button(action: onManageScope) {
                        Text(LocalizationKey.filesManageScope.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
                Text(LocalizationKey.filesRequiresAuthorization.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(environment.authorizedLocations) { location in
                    HStack(spacing: SiftMetrics.spacingM) {
                        Image(systemName: "folder")
                            .foregroundStyle(SiftColor.accent)
                            .accessibilityHidden(true)
                        Text(location.displayName)
                            .font(SiftFont.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                if environment.authorizedLocations.isEmpty {
                    Text(LocalizationKey.filesScopeEmpty.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension FileCleanupMode {
    /// The glyph and tint of the mode, shared by the first-run block and the
    /// result groups so a mode keeps one identity on the page.
    var symbolName: String {
        switch self {
        case .large: "doc.zipper"
        case .old: "calendar.badge.clock"
        case .duplicates: "doc.on.doc"
        }
    }

    var tint: Color {
        switch self {
        case .large: SiftColor.categoryPalette[5]
        case .old: SiftColor.categoryPalette[6]
        case .duplicates: SiftColor.categoryPalette[7]
        }
    }
}
