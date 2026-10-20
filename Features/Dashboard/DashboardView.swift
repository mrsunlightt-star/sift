import Core
import Shared
import SwiftUI

/// The overview page (§4.1), rebuilt around the two questions a user opens it
/// with: how much can be released, and what should I do first.
///
/// Every number is explainable. The hero total is the scan's own estimate, split
/// by the risk the scanner attached to each item; the disk ring is the named
/// volume's used fraction; the suggestion list is the first page of the actual
/// result set, with the same selection the scan page uses. Nothing on this page
/// is a composite health score.
public struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Observed directly: `AppEnvironment` holds the models but does not
    /// republish their changes, so a page that only reads them through the
    /// environment would keep a stale total after a scan.
    @ObservedObject private var scan: ScanModel
    @ObservedObject private var cleanup: CleanupModel
    /// The one navigation this page needs: open the merged scan page. A page
    /// does not know the shell's destination type, so it asks for the page it
    /// wants rather than for a route.
    private let onOpenScan: () -> Void
    private let onOpenApps: () -> Void
    @State private var lastOutcome: CleanupOutcome?

    public init(
        scan: ScanModel,
        cleanup: CleanupModel,
        onOpenScan: @escaping () -> Void = {},
        onOpenApps: @escaping () -> Void = {}
    ) {
        self.scan = scan
        self.cleanup = cleanup
        self.onOpenScan = onOpenScan
        self.onOpenApps = onOpenApps
    }

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: LocalizationKey.navDashboard.localized, status: statusLine) {
                SiftMetricPill(
                    symbolName: scan.hasResults ? "leaf.fill" : "clock",
                    value: lastScanCaption,
                    tint: scan.hasResults ? SiftColor.safe : SiftColor.neutral
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                    HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                        heroCard
                        VStack(spacing: SiftMetrics.spacingL) {
                            diskCard
                            lastCleanupCard
                        }
                        .frame(width: SiftMetrics.summaryColumnWidth)
                    }

                    HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                        suggestionCard
                        activityCard
                            .frame(width: SiftMetrics.summaryColumnWidth)
                    }
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.vertical, SiftMetrics.pageSpacing)
                .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task {
            lastOutcome = RecentHistory.lastOutcome()
            environment.refreshVolumes()
            await environment.loadApplications()
        }
    }

    // MARK: - Header

    private var statusLine: String {
        let date = Date().formatted(
            .dateTime.year().month().day().weekday(.wide)
                .locale(environment.preferences.language.locale)
        )
        return LocalizationKey.overviewStatus.localized(date)
    }

    private var lastScanCaption: String {
        if let report = scan.report {
            return LocalizationKey.dashboardLastScan.localized(
                SiftFormat.relativeDate(report.finishedAt ?? report.startedAt)
            )
        }
        guard let stored = RecentHistory.lastScanDate() else {
            return LocalizationKey.dashboardNeverScanned.localized
        }
        return LocalizationKey.dashboardLastScan.localized(SiftFormat.relativeDate(stored))
    }

    // MARK: - Hero

    private var heroCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingXL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                HStack(alignment: .center) {
                    Text(
                        (scan.hasResults
                            ? LocalizationKey.overviewReclaimableTitle
                            : LocalizationKey.overviewReady).localized
                    )
                    .font(SiftFont.eyebrow)
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(SiftColor.accent)

                    Spacer(minLength: SiftMetrics.spacingM)

                    if scan.hasResults {
                        Text(
                            LocalizationKey.overviewReclaimableMeta.localized(
                                scan.categoryTotals.count,
                                scan.report?.itemCount ?? 0
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, SiftMetrics.spacingM)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .overlay {
                            Capsule().strokeBorder(SiftColor.glassBorder, lineWidth: 1)
                        }
                    }
                }

                if scan.hasResults {
                    let parts = Self.byteParts(scan.reclaimableBytes)
                    SiftHugeMetric(parts.value, unit: parts.unit)
                    if scan.riskTotalsComplete {
                        Text(breakdown)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("—")
                        .font(SiftFont.metricLarge)
                        .foregroundStyle(.tertiary)
                    Text(LocalizationKey.overviewNoResults.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: SiftMetrics.spacingM) {
                    if scan.isRunning || environment.isPreparingScan {
                        SiftPrimaryButton(
                            titleKey: .overviewViewProgress,
                            symbolName: "arrow.right"
                        ) {
                            onOpenScan()
                        }
                    } else {
                        SiftPrimaryButton(
                            titleKey: .dashboardStartScan,
                            symbolName: "viewfinder",
                            isEnabled: !scan.isRunning && !environment.isPreparingScan
                        ) {
                            Task { await environment.runScan(.everything) }
                        }
                    }

                    if scan.hasResults {
                        SiftSecondaryButton(titleKey: .overviewViewResults) {
                            onOpenScan()
                        }
                    }

                    Spacer(minLength: SiftMetrics.spacingS)

                    Text(LocalizationKey.overviewLocalOnly.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.top, SiftMetrics.spacingXS)
            }
        }
    }

    /// The hero's one explanatory sentence: how much is safe, and how much needs
    /// a look. Both numbers come from the risk attached to the items themselves.
    private var breakdown: String {
        let review = scan.reviewBytes + scan.duplicateReclaimableBytes
        return LocalizationKey.overviewReclaimableBreakdown.localized(
            SiftFormat.bytes(scan.safeBytes),
            SiftFormat.bytes(review)
        )
    }

    // MARK: - Right column

    private var diskCard: some View {
        let volume = environment.availableVolumes.first { $0.mountPoint.path == "/" }
        return SiftGlassCard(padding: SiftMetrics.spacingL) {
            HStack(spacing: SiftMetrics.spacingL) {
                SiftProgressRing(
                    progress: volume?.usedFraction ?? 0,
                    lineWidth: 9,
                    label: volume?.formattedUsage ?? "—"
                )
                .frame(width: 82, height: 82)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizationKey.dashboardDiskUsed.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    if let volume {
                        Text(volume.name)
                            .font(SiftFont.bodyEmphasis)
                            .lineLimit(1)
                        Text(
                            LocalizationKey.overviewDiskUsageDetail.localized(
                                volume.formattedFree,
                                volume.formattedTotal
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    } else {
                        Text(LocalizationKey.commonNotAvailable.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var lastCleanupCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.overviewLastCleanupTitle.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)

                if let outcome = lastOutcome {
                    Text(outcome.formattedReleased)
                        .font(SiftFont.metricLarge)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(
                        LocalizationKey.overviewLastCleanupMeta.localized(
                            SiftFormat.relativeDate(outcome.finishedAt),
                            outcome.movedCount
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                } else {
                    Text(LocalizationKey.overviewNoCleanup.localized)
                        .font(SiftFont.bodyEmphasis)
                        .foregroundStyle(.secondary)
                    Text(LocalizationKey.overviewCleanupHistoryHint.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let volume = environment.availableVolumes.first(where: { $0.mountPoint.path == "/" }) {
                    UsageBar(
                        fraction: volume.usedFraction,
                        tint: volume.usedFraction > 0.9 ? SiftColor.review : SiftColor.accent,
                        height: 6
                    )
                    .padding(.top, 4)
                    HStack(spacing: SiftMetrics.spacingS) {
                        Circle()
                            .fill(volume.usedFraction > 0.9 ? SiftColor.review : SiftColor.accent)
                            .frame(width: 5, height: 5)
                        Text(LocalizationKey.dashboardNow.localized)
                            .font(SiftFont.badge)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(volume.formattedUsage)
                            .font(SiftFont.badge)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                    Text(
                        (scan.hasResults
                            ? LocalizationKey.dashboardSuggestedCleanup
                            : LocalizationKey.overviewScanScope).localized
                    )
                    .font(SiftFont.sectionTitle)
                    Spacer(minLength: SiftMetrics.spacingS)
                    if !cleanup.items.isEmpty {
                        Text(
                            LocalizationKey.overviewSelectedSummary.localized(
                                cleanup.selectedCount,
                                cleanup.formattedSelectedBytes
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        Button {
                            cleanup.selectAll(in: cleanup.items.filter { $0.risk.isCleanable })
                        } label: {
                            Text(LocalizationKey.overviewSelectSafe.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                }
                .padding(.bottom, SiftMetrics.spacingM)

                Divider()

                if scan.hasResults, !cleanup.items.isEmpty {
                    ForEach(Array(cleanup.items.prefix(4))) { item in
                        suggestedRow(item)
                        Divider()
                    }
                    footerNotice
                    if remainingCount > 0 {
                        Divider()
                        HStack(spacing: SiftMetrics.spacingM) {
                            Text(
                                LocalizationKey.overviewMoreItems.localized(
                                    remainingCount,
                                    SiftFormat.bytes(remainingBytes)
                                )
                            )
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                onOpenScan()
                            } label: {
                                Text(LocalizationKey.overviewShowAll.localized)
                                    .font(SiftFont.caption)
                            }
                            .buttonStyle(SiftLinkButtonStyle())
                        }
                        .padding(.top, SiftMetrics.spacingM)
                    }
                } else {
                    ScanCategoryPreview(
                        CleanupCategory.junkCategories + [.largeFiles, .oldFiles, .duplicateFiles]
                    )
                    .padding(.vertical, SiftMetrics.spacingM)
                    Text(LocalizationKey.dashboardScanCardSubtitle.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func suggestedRow(_ item: CleanupItem) -> some View {
        HStack(spacing: SiftMetrics.spacingM) {
            SiftCheckbox(
                isOn: Binding(
                    get: { cleanup.isSelected(item) },
                    set: { cleanup.setSelected($0, for: item) }
                ),
                isEnabled: item.risk.isCleanable
            )
            .accessibilityLabel(Text(item.displayName))
            .accessibilityHint(Text(item.risk.detailKey.localized))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(suggestedDetail(item))
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            Text(item.formattedSize)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()

            RiskBadge(risk: item.risk.level)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func suggestedDetail(_ item: CleanupItem) -> String {
        if item.fileCount > 1 {
            return "\(item.displayPath) · \(LocalizationKey.commonFileCount.localized(item.fileCount))"
        }
        return item.displayPath
    }

    private var footerNotice: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(LocalizationKey.scanResultsTrashHint.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, SiftMetrics.spacingM)
    }

    private var shownBytes: Int64 {
        cleanup.items.prefix(4).reduce(0) { $0 + $1.sizeInBytes }
    }

    private var remainingCount: Int {
        max((scan.report?.itemCount ?? cleanup.items.count) - min(cleanup.items.count, 4), 0)
    }

    private var remainingBytes: Int64 {
        max((scan.report?.itemBytes ?? shownBytes) - shownBytes, 0)
    }

    // MARK: - Activity

    private var activityCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizationKey.dashboardRecentActivity.localized)
                    .font(SiftFont.sectionTitle)
                    .padding(.bottom, SiftMetrics.spacingM)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    if let outcome = lastOutcome {
                        activityRow(
                            tint: SiftColor.safe,
                            title: "\(LocalizationKey.dashboardCleanupCompleted.localized) · \(outcome.formattedReleased)",
                            detail: "\(SiftFormat.relativeDate(outcome.finishedAt)) · \(LocalizationKey.cleanupResultMoved.localized(outcome.movedCount))"
                        )
                    }

                    if let report = scan.report {
                        activityRow(
                            tint: SiftColor.accent,
                            title: LocalizationKey.overviewActivityScan.localized(report.itemCount),
                            detail: SiftFormat.relativeDate(report.finishedAt ?? report.startedAt)
                        )
                    } else if let date = RecentHistory.lastScanDate() {
                        activityRow(
                            tint: SiftColor.accent,
                            title: LocalizationKey.dashboardScanCompleted.localized,
                            detail: SiftFormat.relativeDate(date)
                        )
                    }

                    if let lastAnalyzed = environment.storageAnalysis.lastAnalyzedAt {
                        activityRow(
                            tint: SiftColor.categoryPalette[2],
                            title: LocalizationKey.overviewActivityStorage.localized(
                                SiftFormat.bytes(environment.storageAnalysis.report.measuredBytes)
                            ),
                            detail: SiftFormat.relativeDate(lastAnalyzed)
                        )
                    }

                    if uninstallAdviceCount > 0 {
                        activityRow(
                            tint: SiftColor.review,
                            title: LocalizationKey.overviewActivityUninstall.localized(uninstallAdviceCount),
                            detail: LocalizationKey.dashboardLookSuggestions.localized,
                            action: onOpenApps
                        )
                    }

                    if lastOutcome == nil, scan.report == nil, RecentHistory.lastScanDate() == nil {
                        Text(LocalizationKey.overviewNoResults.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, SiftMetrics.spacingM)
                    }
                }

                Spacer(minLength: SiftMetrics.spacingL)

                Text(LocalizationKey.overviewHistoryLocal.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingM)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func activityRow(
        tint: Color,
        title: String,
        detail: String,
        action: (() -> Void)? = nil
    ) -> some View {
        let row = HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SiftFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)

        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    /// Apps that have not been opened in six months, excluding system apps and
    /// anything the system has never recorded a launch for.
    private var uninstallAdviceCount: Int {
        let cutoff = Date().addingTimeInterval(-180 * 86_400)
        return environment.installedApplications.filter { application in
            !application.isSystemApplication && (application.lastUsedAt ?? .distantPast) < cutoff
        }.count
    }

    // MARK: - Formatting

    /// Splits a formatted byte count into its number and its unit, so the hero can
    /// set the unit at a smaller size. `ByteCountFormatter` localises both parts
    /// and may use a non-breaking space, so this splits on any whitespace.
    static func byteParts(_ bytes: Int64) -> (value: String, unit: String?) {
        let formatted = SiftFormat.bytes(bytes)
        let parts = formatted.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return (formatted, nil) }
        return (parts.dropLast().joined(separator: " "), parts.last.map(String.init))
    }
}
