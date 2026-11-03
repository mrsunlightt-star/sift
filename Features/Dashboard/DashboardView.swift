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
                let state = overviewState
                SiftMetricPill(
                    symbolName: state.hasResultSet ? "leaf.fill" : "clock",
                    value: lastScanCaption,
                    tone: state.hasResultSet ? .safe : .neutral
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
                    .siftAppear(index: 0)

                    HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                        suggestionCard
                        activityCard
                            .frame(width: SiftMetrics.summaryColumnWidth)
                    }
                    .siftAppear(index: 1)
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

    /// The page's situation, resolved once.
    ///
    /// The header pill, the hero's heading, its number, the sentence that stands
    /// in for the number, the primary button and the suggestion list all read
    /// this value instead of each asking `scan.hasResults` and
    /// `environment.isScanInFlight` on their own — which is how the button came
    /// to offer a first scan over a finished one.
    private var overviewState: OverviewState {
        OverviewState(hasResults: scan.hasResults, isScanInFlight: environment.isScanInFlight)
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
        let state = overviewState
        return SiftGlassCard(padding: SiftMetrics.spacingXL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                HStack(alignment: .center) {
                    Text(state.eyebrowKey.localized)
                        .font(SiftFont.eyebrow)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(SiftColor.accentText)

                    Spacer(minLength: SiftMetrics.spacingM)

                    if state.hasResultSet {
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
                        .background(
                            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                                .fill(SiftColor.subtleFill)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                                .strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.hairline)
                        }
                    }
                }

                if state.hasResultSet {
                    let parts = Self.byteParts(scan.reclaimableBytes)
                    SiftHugeMetric(parts.value, unit: parts.unit)
                    if scan.riskTotalsComplete {
                        Text(breakdown)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let placeholderKey = state.placeholderKey {
                    // An em dash in the slot a size goes in read as "zero bytes"
                    // rather than "not measured yet". A sentence says which one it
                    // is, and the hero stops looking like a value that failed.
                    // It also says which waiting room the user is in: a run in
                    // flight is not the same page as one that never started.
                    Text(placeholderKey.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: SiftMetrics.spacingM) {
                    let action = state.action
                    // Not disabled while a run is in flight: in that stage the
                    // button is "View scan progress", which only navigates. It
                    // used to be disabled in exactly that state, so a user
                    // watching a scan on the overview had a button that named
                    // the page holding the progress and refused to open it.
                    SiftPrimaryButton(
                        titleKey: action.titleKey,
                        symbolName: action.symbolName
                    ) {
                        guard action.startsAScan else {
                            onOpenScan()
                            return
                        }
                        // Starting a scan is also the navigation: the scan
                        // page is where the run's progress lives, so the
                        // hero hands the user straight to it instead of
                        // offering a second button to click.
                        onOpenScan()
                        Task { await environment.runScan(.everything) }
                    }
                    .accessibilityIdentifier("dashboard.primaryAction")

                    if state.offersResultsPage {
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

                if environment.availableVolumes.isEmpty {
                    // Nothing measured yet. A bar at zero said "no disk used".
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        HStack {
                            SiftSkeletonRow()
                        }
                        .frame(height: 18)
                    }
                } else if let volume = environment.availableVolumes.first(where: { $0.mountPoint.path == "/" }) {
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
                        (overviewState.hasResultSet
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
                            onOpenScan()
                        } label: {
                            Text(LocalizationKey.overviewViewResults.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                        .accessibilityIdentifier("dashboard.viewResults")
                    }
                }
                .padding(.bottom, SiftMetrics.spacingM)

                Divider()

                if overviewState.hasResultSet, !cleanup.items.isEmpty {
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

    /// One suggestion. A preview, not a checkbox.
    ///
    /// Two pages used to own one selection: the checkbox here wrote the scan
    /// page's model, and this page had no button that could act on it — the user
    /// ticked items and nothing could happen. The list states what was found and
    /// the row's trailing link takes the user to the page that can clean it.
    private func suggestedRow(_ item: CleanupItem) -> some View {
        HStack(spacing: SiftMetrics.spacingM) {
            IconTile(symbolName: item.category.symbolName, tint: SiftColor.color(for: item.risk.level))

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
            return "\(item.displayPath), \(LocalizationKey.commonFileCount.counted(item.fileCount))"
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
                            title: "\(LocalizationKey.dashboardCleanupCompleted.localized), \(outcome.formattedReleased)",
                            detail: "\(SiftFormat.relativeDate(outcome.finishedAt)), \(LocalizationKey.cleanupResultMoved.counted(outcome.movedCount))"
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
                        // The hero above already says what a scan would show. This
                        // card's empty state states what the card is for.
                        Text(LocalizationKey.overviewCleanupHistoryHint.localized)
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
        // One rule for "unused", in the model, so this page and the Apps page
        // cannot disagree about the same application. It also keeps the count
        // honest when the launch record could not be read at all: unknown is not
        // the same as six months untouched.
        environment.installedApplications.filter { $0.isUnused() }.count
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
