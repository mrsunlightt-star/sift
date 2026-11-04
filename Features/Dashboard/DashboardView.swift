import Core
import Shared
import SwiftUI

/// The overview page (§1 of the V2 page specification), built around the one
/// question a user opens it with: how much can be released, and what should I do
/// first.
///
/// The page has exactly one visual anchor — the metric region — and everything
/// below it is a plain list of facts. It used to be a grid of four equally
/// weighted cards, which said that a finished scan, the disk's free space and the
/// last cleanup were four answers of the same size; they are not.
///
/// Nothing here is computed a second time. The metric is the scan model's own
/// estimate, split by the risk the scanner attached to each item; the disk figure
/// belongs to the named volume; the recommended rows are the first page of the
/// actual result set. `OverviewState` still resolves the page's situation once and
/// every label — eyebrow, number's slot, button — reads that one value, so the
/// page cannot say "start" over a result set it already has (invariant 46).
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
            SiftPageHeader(
                title: LocalizationKey.navDashboard.localized,
                subtitle: LocalizationKey.overviewPurpose.localized
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXXL) {
                    if hasNotice {
                        notices
                            .siftAppear(index: 0)
                    }

                    primaryRegion
                        .siftAppear(index: 0)

                    if !overviewState.hasResultSet {
                        scopeSection
                            .siftAppear(index: 1)
                    }

                    factsSection
                        .siftAppear(index: 1)

                    if showsRecommendations {
                        recommendedSection
                            .siftAppear(index: 2)
                    }

                    activitySection
                        .siftAppear(index: 3)
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.top, SiftMetrics.spacingXL)
                .padding(.bottom, SiftMetrics.spacingXXL)
                .frame(maxWidth: SiftMetrics.contentWidthStandard, alignment: .leading)
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
    /// The eyebrow, the number's slot, the sentence that stands in for the
    /// number, the primary button and the supporting facts all read this value
    /// instead of each asking `scan.hasResults` and `environment.isScanInFlight`
    /// on their own — which is how the button came to offer a first scan over a
    /// finished one.
    private var overviewState: OverviewState {
        OverviewState(hasResults: scan.hasResults, isScanInFlight: environment.isScanInFlight)
    }

    // MARK: - Header

    // The date stood above the title until the visual studies settled the
    // question: `05 §6` lets a page state a status only when it says something
    // the title does not, and a page whose facts band already carries
    // "Last scan — Today · 09:42" was printing the same day twice, once as a
    // status and once as a fact. The header now says what the page *is*, and the
    // date lives where its number does.

    // MARK: - What happened to the last run

    /// True when the last run needs a sentence of its own.
    ///
    /// A failed or partial run is a different page from a clean one, and the two
    /// used to look identical: the metric region simply sat empty, which reads as
    /// "nothing to clean" — the opposite of "the scan could not finish". The
    /// previous valid result may stay on the page, and this is the line that says
    /// which run it came from.
    private var hasNotice: Bool {
        scan.failure != nil
            || scan.resultLoadFailure != nil
            || scan.phase == .partial
            || scan.phase == .cancelled
    }

    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            if let failure = scan.failure {
                NoticeBanner(
                    level: .error,
                    message: failure.message,
                    actionTitle: failure.code.suggestedAction?.titleKey,
                    action: failure.code.suggestedAction == .openSystemSettings
                        ? { Task { await environment.openPermissionSettings() } }
                        : nil
                )
            }
            if let failure = scan.resultLoadFailure {
                // The index could not be read. Without this line the page showed
                // no recommended rows, which reads as "nothing was found" — a
                // different statement from "the result could not be loaded".
                NoticeBanner(level: .error, message: failure)
            }
            if scan.phase == .partial {
                // Two different reasons for an incomplete picture, and the copy
                // keeps them apart: locations the run could not read, or the
                // budget it stopped at to stay responsive.
                if scan.skippedLocations.isEmpty {
                    NoticeBanner(
                        level: .information,
                        message: LocalizationKey.scanPartialBudget.localized
                    )
                } else {
                    NoticeBanner(
                        level: .warning,
                        message: LocalizationKey.scanPartialNotice.localized(
                            scan.skippedLocations.count
                        )
                    )
                }
            }
            if scan.phase == .cancelled {
                NoticeBanner(level: .information, titleKey: .scanPhaseCancelled)
            }
        }
    }

    // MARK: - The primary region

    /// The page's single visual anchor: one number, what it means, and the one
    /// action that follows from it.
    ///
    /// Deliberately not a card. A surface here would make the metric one tile
    /// among several again; the size, the space around it and the hairline below
    /// are what carry its weight.
    private var primaryRegion: some View {
        let state = overviewState
        return ZStack(alignment: .topTrailing) {
            brandMark

            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                // Sentence case, no tracking: `01` retires all-caps eyebrow
                // labels with wide letter spacing, which in a longer
                // translation is a wall of capitals above a 42 pt number. The
                // 12 pt semibold weight and the colour are what rank it.
                Text(state.eyebrowKey.localized)
                    .font(SiftFont.eyebrow)
                    .foregroundStyle(SiftColor.actionGreen)

                if state.hasResultSet {
                    metricLine
                    if scan.riskTotalsComplete {
                        Text(breakdown)
                            .font(SiftFont.body)
                            .foregroundStyle(SiftColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let placeholderKey = state.placeholderKey {
                    // An em dash in the slot a size goes in read as "zero bytes"
                    // rather than "not measured yet". A sentence says which one it
                    // is, and it also says which waiting room the user is in: a run
                    // in flight is not the same page as one that never started.
                    Text(placeholderKey.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 176, alignment: .topLeading)
    }

    private var metricLine: some View {
        let parts = Self.byteParts(scan.reclaimableBytes)
        return HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
            Text(parts.value)
                .font(SiftFont.metricPrimary)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
                .contentTransition(.numericText())
            if let unit = parts.unit {
                Text(unit)
                    .font(SiftFont.heroUnit)
                    .foregroundStyle(SiftColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The one decorative element on the page: a pale star in the metric region's
    /// corner.
    ///
    /// It carries no meaning — the number beside it does — so it is hidden from
    /// assistive technology, it does not take a click, and it is drawn in the
    /// brand green at a wash's opacity, never as text: that green measures 2.43:1.
    private var brandMark: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 150, weight: .regular))
            .foregroundStyle(SiftColor.brandGreen.opacity(0.12))
            .offset(x: 16, y: -10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var actionRow: some View {
        let action = overviewState.action
        return HStack(spacing: SiftMetrics.spacingM) {
            // Not disabled while a run is in flight: in that stage the button is
            // "View scan progress", which only navigates. It used to be disabled
            // in exactly that state, so a user watching a scan on the overview had
            // a button that named the page holding the progress and refused to
            // open it.
            SiftPrimaryButton(
                titleKey: action.titleKey,
                symbolName: action.symbolName
            ) {
                // Starting a scan is also the navigation: the scan page is where
                // the run's progress lives, so the hero hands the user straight to
                // it instead of offering a second button to click. The other two
                // states of this button ("View scan progress", "View results")
                // only navigate, which is why the press always opens the page.
                onOpenScan()
                if action.startsAScan {
                    Task { await environment.runScan(.everything) }
                }
            }
            .accessibilityIdentifier("dashboard.primaryAction")

            if overviewState.offersResultsPage {
                // A text link, not a second filled control: the studies put one
                // solid button on this page, and a page that offers two equally
                // weighted buttons has no primary action at all.
                Button {
                    onOpenScan()
                } label: {
                    HStack(spacing: SiftMetrics.spacingXS) {
                        Text(LocalizationKey.overviewViewResults.localized)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(SiftFont.secondaryHeading)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .padding(.horizontal, SiftMetrics.spacingXS)
                .accessibilityIdentifier("dashboard.viewResults")
            }

            Spacer(minLength: SiftMetrics.spacingS)
        }
        .padding(.top, SiftMetrics.spacingXS)
    }

    /// The metric's one explanatory sentence: how much is safe, and how much needs
    /// a look. Both numbers come from the risk attached to the items themselves.
    private var breakdown: String {
        let review = scan.reviewBytes + scan.duplicateReclaimableBytes
        return LocalizationKey.overviewReclaimableBreakdown.localized(
            SiftFormat.bytes(scan.safeBytes),
            SiftFormat.bytes(review)
        )
    }

    /// Where the run keeps nothing to show, the page says what a run would look
    /// for. Only in the first-run state: over a result set, the categories are
    /// already visible as rows.
    private var scopeSection: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.overviewScanScope.localized)
                    .font(SiftFont.sectionHeading)
                    .foregroundStyle(SiftColor.mainText)

                ScanCategoryPreview(
                    CleanupCategory.junkCategories + [.largeFiles, .oldFiles, .duplicateFiles]
                )

                Text(LocalizationKey.dashboardScanCardSubtitle.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The run happens here, so the page says so where the decision is made.
    private var localOnlyLine: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
            Text(LocalizationKey.overviewLocalOnly.localized)
                .font(SiftFont.supporting)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(SiftColor.quietText)
    }

    // MARK: - Supporting facts

    /// Operational facts as a two-column band.
    ///
    /// The visual studies settled this shape: a label above its value, two pairs
    /// per row, one vertical hairline between the columns and one horizontal
    /// hairline between the rows. The label-left / value-right form this replaced
    /// read as a settings table — five rows of the same rhythm, in which the disk
    /// figure and the last cleanup looked like entries rather than the two
    /// measurements they are.
    ///
    /// Every cell still comes from the same resolved state as the rest of the
    /// page, so a run in flight and a run that never happened cannot be described
    /// two different ways on one screen.
    private var factsSection: some View {
        SiftSection {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    factCell(
                        title: LocalizationKey.dashboardScanCompleted.localized,
                        value: lastScanValue
                    )

                    columnRule

                    factCell(
                        title: LocalizationKey.overviewLastCleanupTitle.localized,
                        value: lastOutcome?.formattedReleased
                            ?? LocalizationKey.overviewNoCleanup.localized,
                        detail: lastOutcome.map {
                            LocalizationKey.overviewLastCleanupMeta.localized(
                                SiftFormat.relativeDate($0.finishedAt),
                                $0.movedCount
                            )
                        }
                    )
                }
                .padding(.vertical, SiftMetrics.spacingL)

                SiftHairline()

                HStack(alignment: .top, spacing: 0) {
                    diskCell

                    if overviewState.hasResultSet {
                        columnRule

                        factCell(
                            title: LocalizationKey.scanResults.localized,
                            value: LocalizationKey.overviewReclaimableMeta.localized(
                                scan.categoryTotals.count,
                                scan.report?.itemCount ?? 0
                            )
                        )
                    }
                }
                .padding(.vertical, SiftMetrics.spacingL)

                localOnlyLine
                    .padding(.top, SiftMetrics.spacingS)
            }
        }
    }

    /// One cell of the band: label, value, optional second line.
    ///
    /// The label is supporting copy and the value is the measurement, which is the
    /// one place on this page where the smaller size is the more important line —
    /// it is a label, not an assertion.
    private func factCell(title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(title)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .font(SiftFont.sectionHeading)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The band's vertical rule. Drawn only between two cells that both exist, so
    /// a page with no result set does not end a row with a line and nothing after
    /// it.
    private var columnRule: some View {
        Rectangle()
            .fill(SiftColor.divider)
            .frame(width: SiftMetrics.panelBorderWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, SiftMetrics.spacingXS)
            .padding(.horizontal, SiftMetrics.spacingL)
            .accessibilityHidden(true)
    }

    /// The disk figure, or a skeleton until the volume has been read.
    ///
    /// A bar at zero said "no disk used"; a spinner claims a measurement is
    /// running. The volume list is filled by `refreshVolumes()` on appear, so the
    /// honest thing to draw in the meantime is a placeholder of the value's own
    /// height.
    private var diskCell: some View {
        let volume = rootVolume
        return VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(LocalizationKey.dashboardDiskUsed.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)

            if let volume {
                Text(volume.formattedUsage)
                    .font(SiftFont.sectionHeading)
                    .monospacedDigit()
                    .foregroundStyle(SiftColor.mainText)
                Text(
                    LocalizationKey.overviewDiskUsageDetail.localized(
                        volume.formattedFree,
                        volume.formattedTotal
                    )
                )
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.quietText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                SiftSkeletonRow()
                    .frame(width: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var rootVolume: VolumeInfo? {
        environment.availableVolumes.first { $0.mountPoint.path == "/" }
    }

    /// The last run, as a date and not as a claim about this machine.
    ///
    /// "Not scanned yet" when no run has ever finished. Recency wording is right
    /// here — a scan's age is the point — unlike the two application dates, which
    /// are read against one another and carry their year (invariant 47).
    ///
    /// The clock time travels with the day (`Today · 09:42`): a user who has just
    /// scanned needs to know whether that result set is the run they are looking
    /// at, and "Today" alone cannot answer a second run on the same day.
    private var lastScanValue: String {
        if let report = scan.report {
            return SiftFormat.relativeDateTime(report.finishedAt ?? report.startedAt)
        }
        guard let stored = RecentHistory.lastScanDate() else {
            return LocalizationKey.dashboardNeverScanned.localized
        }
        return SiftFormat.relativeDateTime(stored)
    }

    // MARK: - Recommendations

    /// Recommended rows are the result set's own first page, never a second
    /// ranking built here: a recommendation the scan page cannot reproduce is a
    /// recommendation the user cannot check.
    private var showsRecommendations: Bool {
        overviewState.hasResultSet && !cleanup.items.isEmpty
    }

    private var recommendedSection: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                    Text(LocalizationKey.dashboardSuggestedCleanup.localized)
                        .font(SiftFont.sectionHeading)
                        .foregroundStyle(SiftColor.mainText)

                    Spacer(minLength: SiftMetrics.spacingS)

                    // Only the count here. The hero above already carries the one
                    // "View scan results" link this page needs; two identical
                    // labels 400 pt apart are two controls for one destination,
                    // and the second one makes the first look like it did nothing.
                    Text(
                        LocalizationKey.overviewSelectedSummary.localized(
                            cleanup.selectedCount,
                            cleanup.formattedSelectedBytes
                        )
                    )
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .accessibilityIdentifier("dashboard.selectedSummary")
                }
                .padding(.bottom, SiftMetrics.spacingS)

                SiftHairline()

                ForEach(Array(cleanup.items.prefix(4))) { item in
                    suggestedRow(item)
                    SiftHairline(inset: SiftMetrics.iconTileSize + SiftMetrics.spacingM)
                }

                footerNotice

                if remainingCount > 0 {
                    HStack(spacing: SiftMetrics.spacingM) {
                        Text(
                            LocalizationKey.overviewMoreItems.localized(
                                remainingCount,
                                SiftFormat.bytes(remainingBytes)
                            )
                        )
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)

                        Spacer(minLength: SiftMetrics.spacingS)

                        Button {
                            onOpenScan()
                        } label: {
                            Text(LocalizationKey.overviewShowAll.localized)
                                .font(SiftFont.supporting)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                    .padding(.top, SiftMetrics.spacingM)
                }

                // What the rows are and what happens next, in one sentence: a
                // recommendation is a claim about a *previous* run, and the
                // safety check happens again at the moment of the move. Stating
                // both is what stops "suggested" from reading as "already
                // judged safe".
                Text(LocalizationKey.overviewSuggestionsNote.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingM)
            }
        }
    }

    /// One suggestion. A preview, not a checkbox.
    ///
    /// Two pages used to own one selection: the checkbox here wrote the scan
    /// page's model, and this page had no button that could act on it — the user
    /// ticked items and nothing could happen. The list states what was found and
    /// the section's link takes the user to the page that can clean it.
    private func suggestedRow(_ item: CleanupItem) -> some View {
        HStack(spacing: SiftMetrics.spacingM) {
            IconTile(
                symbolName: item.category.symbolName,
                tint: SiftColor.color(for: item.risk.level)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(suggestedDetail(item))
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            Text(item.formattedSize)
                .font(SiftFont.monospacedEmphasis)
                .foregroundStyle(SiftColor.mainText)

            // The risk is a word before it is a colour, in both appearances.
            RiskBadge(risk: item.risk.level)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .frame(minHeight: SiftMetrics.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                .foregroundStyle(SiftColor.quietText)
                .accessibilityHidden(true)
            Text(LocalizationKey.scanResultsTrashHint.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.quietText)
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

    /// What the app has done recently, in one plain list.
    ///
    /// The kind of each entry is a glyph, not a coloured dot: a dot said what it
    /// meant only in colour, and a page that encodes a category that way is a page
    /// a colour-blind user reads as four identical rows.
    private struct ActivityEntry: Identifiable {
        let id: String
        let symbolName: String
        let title: String
        let detail: String
        var action: (() -> Void)?
    }

    private var activityEntries: [ActivityEntry] {
        var entries: [ActivityEntry] = []

        if let outcome = lastOutcome {
            entries.append(
                ActivityEntry(
                    id: "cleanup",
                    symbolName: "trash",
                    title: "\(LocalizationKey.dashboardCleanupCompleted.localized), \(outcome.formattedReleased)",
                    detail: "\(SiftFormat.relativeDate(outcome.finishedAt)), \(LocalizationKey.cleanupResultMoved.counted(outcome.movedCount))"
                )
            )
        }

        if let report = scan.report {
            entries.append(
                ActivityEntry(
                    id: "scan",
                    symbolName: "magnifyingglass",
                    title: LocalizationKey.overviewActivityScan.localized(report.itemCount),
                    detail: SiftFormat.relativeDate(report.finishedAt ?? report.startedAt)
                )
            )
        } else if let date = RecentHistory.lastScanDate() {
            entries.append(
                ActivityEntry(
                    id: "scan",
                    symbolName: "magnifyingglass",
                    title: LocalizationKey.dashboardScanCompleted.localized,
                    detail: SiftFormat.relativeDate(date)
                )
            )
        }

        if let lastAnalyzed = environment.storageAnalysis.lastAnalyzedAt {
            entries.append(
                ActivityEntry(
                    id: "storage",
                    symbolName: "internaldrive",
                    title: LocalizationKey.overviewActivityStorage.localized(
                        SiftFormat.bytes(environment.storageAnalysis.report.measuredBytes)
                    ),
                    detail: SiftFormat.relativeDate(lastAnalyzed)
                )
            )
        }

        if uninstallAdviceCount > 0 {
            entries.append(
                ActivityEntry(
                    id: "uninstall",
                    symbolName: "shippingbox",
                    title: LocalizationKey.overviewActivityUninstall.localized(uninstallAdviceCount),
                    detail: LocalizationKey.dashboardLookSuggestions.localized,
                    action: onOpenApps
                )
            )
        }

        return entries
    }

    private var activitySection: some View {
        let entries = activityEntries
        return SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizationKey.dashboardRecentActivity.localized)
                    .font(SiftFont.sectionHeading)
                    .foregroundStyle(SiftColor.mainText)
                    .padding(.bottom, SiftMetrics.spacingS)

                SiftHairline()

                if entries.isEmpty {
                    // The metric region above already says what a scan would show.
                    // This list's empty state states what the list is for.
                    Text(LocalizationKey.overviewCleanupHistoryHint.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, SiftMetrics.spacingM)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        activityRow(entry, showsRule: index > 0)
                    }
                }

                Text(LocalizationKey.overviewHistoryLocal.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingM)
            }
        }
    }

    private func activityRow(_ entry: ActivityEntry, showsRule: Bool) -> some View {
        VStack(spacing: 0) {
            if showsRule {
                SiftHairline(inset: 28)
            }

            let content = HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                Image(systemName: entry.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiftColor.quietText)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.mainText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.detail)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if entry.action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, SiftMetrics.spacingM)
            .frame(minHeight: SiftMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())

            if let action = entry.action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            } else {
                content
            }
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

    /// Splits a formatted byte count into its number and its unit, so the metric
    /// can set the unit at a smaller size. `ByteCountFormatter` localises both
    /// parts and may use a non-breaking space, so this splits on any whitespace.
    static func byteParts(_ bytes: Int64) -> (value: String, unit: String?) {
        let formatted = SiftFormat.bytes(bytes)
        let parts = formatted.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return (formatted, nil) }
        return (parts.dropLast().joined(separator: " "), parts.last.map(String.init))
    }
}
