import AppKit
import Core
import Foundation
import Shared
import SwiftUI

/// The one scan page.
///
/// Smart scan, junk cleanup and file cleanup were three pages over one scan,
/// differing only in the categories they showed. The redesign merges them: this
/// page always runs the same scan, and the chips select which categories the
/// result list displays. That is why there is one start button, one progress
/// view and one selection summary — and why the page never assembles a request
/// of its own (invariant 17).
///
/// The page is a workbench rather than a card stack: a header, one row of filter
/// chips, then the result list with the selection summary beside it. The list is
/// the subject; the summary states what is about to move and offers the one
/// action that moves it, and it moves to the bottom of the page when the window
/// is too narrow to hold both (05 §5).
public struct ScanView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Observed directly: the page's header, its result branch and its
    /// selection summary all change with the scan, and a view that reads the
    /// model through the environment does not subscribe to it.
    @ObservedObject private var scan: ScanModel
    @ObservedObject private var cleanup: CleanupModel
    private let onRequestPurchase: () -> Void
    private let onManageScope: () -> Void

    @State private var filter: ScanFilter = .all
    @State private var sort: ScanSort = .size
    @State private var items: [CleanupItemSummary] = []
    @State private var cursors: [CleanupCategory: Int] = [:]
    @State private var isLoading = false
    @State private var hasMore = false
    @State private var showsAllRows = false
    /// What the owner lookup answered, shown above the list.
    @State private var ownerLookupMessage: String?
    /// Groups the user opened or closed, keyed by risk.
    ///
    /// Absent means "whatever the group starts as": `review` opens closed, the
    /// other two open. Recorded rather than derived so that reopening a group
    /// survives the list being rebuilt by a later page.
    @State private var groupExpansion: [CleanupRisk: Bool] = [:]
    /// The row the keyboard is on.
    ///
    /// `onMoveCommand` is delivered to the focused responder, so an arrow key
    /// pressed while a row's checkbox has focus moves the cursor to the next row
    /// instead of doing nothing. No global shortcut and no custom focus ring: the
    /// rows behave the way every other list in macOS does.
    @FocusState private var focusedRow: String?

    /// What the last click on "move to Trash" produced, when it produced no panel.
    @State private var actionNotice: (level: NoticeBanner.Level, text: String)?

    /// Rows a "select all" is about to add. One pending selection, one dialog:
    /// the footer's select-all used to act on the whole model with no
    /// confirmation while the review group's asked first, so the same page had
    /// two safety levels for the same action.
    @State private var pendingSelectAll: [CleanupItemSummary] = []

    private let pageSize = 100
    private let collapsedRowsPerGroup = 4

    public init(
        scan: ScanModel,
        cleanup: CleanupModel,
        onRequestPurchase: @escaping () -> Void = {},
        onManageScope: @escaping () -> Void = {}
    ) {
        self.scan = scan
        self.cleanup = cleanup
        self.onRequestPurchase = onRequestPurchase
        self.onManageScope = onManageScope
    }

    private var isPreparing: Bool { environment.isPreparingScan }
    /// The environment holds the run until its first page is loaded, not just
    /// until the engine settles. The page must use the same gate, or it offers
    /// a rescan the environment will ignore.
    private var isBusy: Bool { environment.isScanInFlight }

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(
                title: LocalizationKey.navScan.localized,
                status: headerStatus,
                subtitleLead: headerSubtitleLead,
                subtitle: headerSubtitle,
                subtitleDetail: headerSubtitleDetail
            ) {
                headerAction
            }

            if holdsResidueRun {
                residueScopeNotice
            } else if hasActionableResults {
                workArea
            } else if showsStoppedCard {
                stoppedCard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                        if isBusy {
                            ScanRunningCard(
                                scan: scan,
                                displayPhase: isPreparing ? .preparing : nil,
                                onOpenPermissions: {
                                    Task { await environment.openPermissionSettings() }
                                }
                            )
                        } else {
                            startContent
                        }
                        statusMessages
                    }
                    .padding(.horizontal, SiftMetrics.pagePadding)
                    .padding(.vertical, SiftMetrics.pageSpacing)
                    .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .task(id: reloadKey) {
            await reload()
        }
        .task(id: hasActionableResults) {
            if hasActionableResults {
                await scan.loadDuplicateGroups()
            }
        }
    }

    /// True when the page has rows to show, including a stopped run's.
    ///
    /// The stopped run keeps its index now, so its rows are ordinary candidates:
    /// the same list, the same selection, the same cleanup. The banner at the top
    /// of the list is what tells the user the run did not finish.
    private var hasActionableResults: Bool {
        scan.hasResults || scan.hasStoppedResults
    }

    /// True when the model holds a run this page did not start.
    ///
    /// The Apps page's leftovers view runs the residue strategy on the same
    /// model, so opening the scan page afterwards shows that run's rows: two
    /// categories, no caches, no logs. Rendering them through the ordinary
    /// result list would say this Mac has almost nothing to clean, which is a
    /// question that run never asked. The page states what it is looking at and
    /// offers the full scan instead.
    private var holdsResidueRun: Bool {
        scan.scope == .residue && (scan.hasResults || scan.hasStoppedResults)
    }

    private var residueScopeNotice: some View {
        ScrollView {
            VStack(spacing: SiftMetrics.spacingL) {
                SiftEmptyState(
                    symbolName: "questionmark.folder",
                    titleKey: .cleanupCategoryApplicationResidue,
                    detailKey: .residueIntroDetail
                )
                SiftPrimaryButton(
                    titleKey: .dashboardStartScan,
                    symbolName: "viewfinder",
                    isEnabled: !isBusy
                ) {
                    Task { await environment.runScan(.everything) }
                }
                .accessibilityIdentifier("scan.start")
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.pageSpacing)
            .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// True when the run ended without a result but did find something.
    ///
    /// A cancelled or failed run used to fall straight back to the empty start
    /// card: forty seconds of walking left nothing on screen but the phase name.
    /// The page now states what the run found before it stopped.
    private var showsStoppedCard: Bool {
        guard scan.phase == .cancelled || scan.phase == .failed else { return false }
        return (scan.report?.itemCount ?? scan.progress.itemsFound) > 0
            || scan.progress.filesSeen > 0
            || !scan.skippedLocations.isEmpty
    }

    // MARK: - Stopped run

    private var stoppedCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                SiftSection(style: .outlined, padding: SiftMetrics.spacingXL) {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
                            Image(systemName: scan.phase.symbolName)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(SiftColor.reviewTextColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizationKey.scanStoppedTitle.localized)
                                    .font(SiftFont.title)
                                Text(
                                    LocalizationKey.scanStoppedDetail.localized(
                                        scan.report?.itemCount ?? scan.progress.itemsFound,
                                        SiftFormat.bytes(scan.liveFoundBytes)
                                    )
                                )
                                .font(SiftFont.body)
                                .foregroundStyle(SiftColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: SiftMetrics.spacingS)
                        }

                        HStack(spacing: SiftMetrics.spacingM) {
                            stoppedFact(
                                LocalizationKey.scanRunningWalked.localized(
                                    SiftFormat.count(scan.progress.filesSeen)
                                )
                            )
                            stoppedFact(
                                "\(LocalizationKey.scanRunningElapsed.localized) "
                                    + ScanRunningCard.duration(scan.elapsed)
                            )
                            if !scan.skippedLocations.isEmpty {
                                stoppedFact(
                                    LocalizationKey.scanPartialNotice.localized(scan.skippedLocations.count)
                                )
                            }
                            Spacer(minLength: 0)
                        }

                        SiftPrimaryButton(titleKey: .scanRescan, symbolName: "arrow.clockwise") {
                            Task { await environment.runScan(.everything) }
                        }
                        .accessibilityIdentifier("scan.rescanAfterStop")
                        .padding(.top, SiftMetrics.spacingXS)
                    }
                }

                statusMessages
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.pageSpacing)
            .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func stoppedFact(_ text: String) -> some View {
        Text(text)
            .font(SiftFont.caption)
            .foregroundStyle(SiftColor.secondaryText)
            .padding(.horizontal, SiftMetrics.spacingS)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .fill(SiftColor.controlFill)
            )
    }

    // MARK: - Header

    /// The header's one line of status.
    ///
    /// It carries the result count and the last run's date because that is the
    /// one fact the page cannot state anywhere else, and it carries the phase
    /// only when the phase is a real state: a run that was cut short, one that
    /// could not finish, or a page that has not scanned yet. A finished, complete
    /// run says nothing about its phase — it does not have one.
    private var headerStatus: String {
        if isBusy {
            let step = isPreparing ? 1 : (scan.phase.step ?? 1)
            return LocalizationKey.scanRunningStatus.localized(step, ScanPhase.stepCount)
        }
        if scan.hasStoppedResults {
            return LocalizationKey.scanPhaseCancelled.localized
        }
        if scan.phase == .cancelled || scan.phase == .failed {
            return scan.phase.labelKey.localized
        }
        if scan.report != nil {
            guard scan.phase == .partial else { return "" }
            // A partial run with skipped locations already says so in the
            // permissions card in the result list. Repeating it in the header
            // made the same sentence appear three times above the fold. Only
            // the budget cut — which has no card — is stated here.
            return scan.skippedLocations.isEmpty
                ? LocalizationKey.scanPartialBudget.localized
                : ""
        }
        // The page name is already the title, so the status states only the
        // rest: "Scan, nothing scanned yet" said the same thing twice.
        return LocalizationKey.scanPhaseIdle.localized
    }

    /// When the run on screen happened.
    ///
    /// The header reads as three facts of the same rank — when, how many, how
    /// much — because that is the order a reader asks them in. The date is the
    /// lead slot rather than a prefix inside `headerSubtitle`: joining it into one
    /// translated string made every language carry a separator glyph.
    private var headerSubtitleLead: String? {
        guard let report = scan.report, !isBusy, !scan.hasStoppedResults else { return nil }
        return SiftFormat.relativeDate(report.finishedAt ?? report.startedAt)
    }

    /// What the page currently holds, as one sentence under the title: the
    /// studies put the count and the reclaimable size there rather than above the
    /// title, and `05 §6` wants a status only when it says something the title
    /// does not.
    ///
    /// Both numbers are the settled run's own totals, never the selection's: this
    /// line must keep describing the scan after the user starts ticking rows.
    ///
    /// The count and the size are two pieces of text rather than one string with
    /// a middle dot in it: the dot was baked into 34 translations, where it is a
    /// punctuation mark each language had to reproduce whether or not it uses it.
    private var headerSubtitle: String? {
        guard let report = scan.report, !isBusy, !scan.hasStoppedResults else { return nil }
        return LocalizationKey.commonItemCount.counted(report.itemCount)
    }

    /// The second half of the header's sentence.
    private var headerSubtitleDetail: String? {
        guard headerSubtitle != nil else { return nil }
        return LocalizationKey.scanHeaderReclaimable.localized(
            SiftFormat.bytes(scan.reclaimableBytes)
        )
    }

    @ViewBuilder
    private var headerAction: some View {
        if isPreparing {
            HStack(spacing: SiftMetrics.spacingS) {
                ProgressView().controlSize(.small)
                Text(LocalizationKey.scanPhasePreparing.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
            }
            .padding(.horizontal, SiftMetrics.spacingM)
        } else if scan.isRunning {
            SiftSecondaryButton(titleKey: .scanCancel) {
                Task { await scan.cancel() }
            }
            .accessibilityIdentifier("scan.cancel")
        } else if isBusy {
            // The engine settled but the first page is still being read. A
            // rescan button here would start a run the environment refuses.
            HStack(spacing: SiftMetrics.spacingS) {
                ProgressView().controlSize(.small)
                Text(LocalizationKey.scanPhaseReady.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
            }
            .padding(.horizontal, SiftMetrics.spacingM)
        } else if hasActionableResults {
            // A ghost button, not a second filled one: the page's filled control
            // is "Move to Trash" in the selection column, and two equally
            // weighted buttons leave the page without a primary action (`05 §7`).
            // Rescanning is a repeat of what the page already did.
            SiftSecondaryButton(titleKey: .scanRescan, symbolName: "arrow.clockwise") {
                Task { await environment.runScan(.everything) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("scan.rescan")
        }
    }

    // MARK: - Filters

    /// The tabs *filter the display* of the one `.everything` result.
    ///
    /// They are not scan scopes: no value here assembles a request or narrows
    /// what the engine walks (invariant 17). The run is the same run, and a tab
    /// only chooses which of its categories this page shows.
    ///
    /// The row is a tab strip with a rule under it, not a row of filled pills:
    /// the page's one filled control is the action that moves files, and five
    /// solid marks above the list left the button reading as one option among
    /// several. The rule is the strip's own, so the list starts on a hairline
    /// the same way the header ends on one.
    ///
    /// The rule spans the page and the tabs scroll above it: the strip sits in a
    /// horizontal `ScrollView`, and a `SiftHairline` inside that scroll view ends
    /// where the tabs end — which drew a rule under the first two tabs and left
    /// the rest of the line as the header's own separator, so the selected tab's
    /// underline looked like the end of a line rather than the mark of a tab.
    private var filterBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: SiftMetrics.spacingM) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: SiftMetrics.spacingXL) {
                        ForEach(ScanFilter.allCases) { candidate in
                            SiftFilterChip(
                                title: candidate.titleKey.localized,
                                detail: chipDetail(candidate),
                                isSelected: filter == candidate
                            ) {
                                filter = candidate
                            }
                            .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The sort control ends the strip rather than opening a line of
                // its own; it is the quietest fact on the row and it belongs to
                // the same decision as the tabs (what the list shows).
                if filter != .all {
                    resultSummary
                }
                sortMenu
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            SiftHairline()
        }
        .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipDetail(_ candidate: ScanFilter) -> String? {
        if candidate == .duplicates {
            return SiftFormat.bytes(scan.duplicateReclaimableBytes)
        }
        if candidate == .all {
            return LocalizationKey.commonItemCount.counted(scan.report?.itemCount ?? 0)
        }
        let total = scan.categoryTotals
            .limited(to: candidate.categories)
            .reduce(Int64(0)) { $0 + $1.totalBytes }
        return SiftFormat.bytes(total)
    }

    // MARK: - Start

    /// The first-run state, said as a scope rather than as a card.
    ///
    /// What the scan will read is stated before it reads it: the page used to
    /// start walking on the same frame as the click with no statement of which
    /// folders were involved.
    private var startContent: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 28, weight: .medium))
                        // A glyph is text-role, so it takes the readable green
                        // and not the brand fill (2.43:1).
                        .foregroundStyle(SiftColor.actionGreen)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                                .fill(SiftColor.brandWash)
                        )

                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.dashboardScanCardTitle.localized)
                            .font(SiftFont.title)
                        Text(LocalizationKey.dashboardScanCardSubtitle.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(SiftColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(LocalizationKey.scanFirstRunScope.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                    HStack(spacing: SiftMetrics.spacingS) {
                        ForEach(Self.scanScopePreview, id: \.self) { path in
                            Text(path)
                                .font(SiftFont.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, SiftMetrics.spacingS)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                                        .fill(SiftColor.controlFill)
                                )
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: SiftMetrics.spacingM) {
                    SiftPrimaryButton(
                        titleKey: .dashboardStartScan,
                        symbolName: "viewfinder",
                        isEnabled: !isBusy
                    ) {
                        Task { await environment.runScan(.everything) }
                    }
                    .accessibilityIdentifier("scan.start")
                    .keyboardShortcut("r", modifiers: .command)
                    Text(LocalizationKey.scanScopeNote.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.quietText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, SiftMetrics.spacingXS)
            }
            .siftAppear(index: 0)

            SiftHairline()

            ScanCategoryPreview(ScanFilter.all.categories ?? CleanupCategory.allCases)
                .siftAppear(index: 1)

            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SiftColor.actionGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.filesScopeTitle.localized)
                        .font(SiftFont.bodyEmphasis)
                    Text(LocalizationKey.filesRequiresAuthorization.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                }
                Spacer(minLength: SiftMetrics.spacingS)
                Button(action: onManageScope) {
                    Text(LocalizationKey.filesManageScope.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
            .siftAppear(index: 2)
        }
    }

    /// The first few folders a default scan reads, home-relative.
    ///
    /// Named after the shipped rules' anchors rather than assembled from the
    /// request: the page states what the product is about to do, and the request
    /// is rebuilt on every run.
    private static let scanScopePreview = [
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Downloads",
        "~/Library/Application Support",
    ]

    // MARK: - Work area

    /// The tab strip, the list, and the action bar under it.
    ///
    /// One layout at every width now. The page used to carry a 272 pt inspector
    /// column on the right, which held a number, one sentence and one button in a
    /// column whose remaining three-quarters was empty — while the list, the
    /// thing the page is about, paid for that width with earlier path
    /// truncation. The same facts fit in a bar across the bottom, where they sit
    /// under the rows they describe, and the list keeps the whole width
    /// (`02 §2`, `02 §9`).
    private var workArea: some View {
        VStack(spacing: 0) {
            filterBar
            resultsList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBar
        }
        .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The result list.
    ///
    /// It scrolls, it pages (one `LazyVStack`, one incremental page per category,
    /// a session-held cursor — 02 §3), and it is the first thing in the scroll:
    /// a run that could not read a few dozen locations used to open on a
    /// two-screen "some locations could not be read" card with the whole list
    /// below the fold. Failures stay on top — they explain a short list — while
    /// the skipped locations follow the results they supplement.
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .id(Self.listTopID)
                    failureBanners
                    if scan.hasStoppedResults {
                        NoticeBanner(
                            level: .information,
                            message: LocalizationKey.scanStoppedDetail.localized(
                                scan.report?.itemCount ?? cleanup.items.count,
                                SiftFormat.bytes(scan.liveFoundBytes)
                            ),
                            actionTitle: .scanRescan,
                            action: { Task { await environment.runScan(.everything) } }
                        )
                    }
                    // A run that hit its budget reports more than it walked.
                    // When locations were skipped, the permissions card in the
                    // list already says the run was partial — a second banner
                    // with the same sentence is noise. Only a pure budget cut,
                    // which has no card, needs this line.
                    if scan.phase == .partial, scan.skippedLocations.isEmpty {
                        NoticeBanner(
                            level: .warning,
                            message: LocalizationKey.scanPartialBudget.localized
                        )
                    }
                    if filter == .duplicates {
                        if scan.duplicateGroups.isEmpty {
                            emptyBlock(
                                symbolName: "doc.on.doc",
                                titleKey: .filesNoDuplicates,
                                detailKey: .filesNoDuplicatesDetail
                            )
                        } else {
                            DuplicateGroupsCard(
                                groups: scan.duplicateGroups,
                                scan: scan,
                                cleanup: cleanup
                            )
                        }
                    } else {
                        resultsBlock
                    }
                    supplementalMessages
                    // Duplicates come last in "All". They are a second,
                    // self-contained result set — and the one result whose rows
                    // the user has to read before deciding anything — so they
                    // belong after the junk that is already judged.
                    if !scan.duplicateGroups.isEmpty, filter == .all {
                        DuplicateGroupsCard(
                            groups: scan.duplicateGroups,
                            scan: scan,
                            cleanup: cleanup
                        )
                    }
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.top, SiftMetrics.pageSpacing)
                .padding(.bottom, SiftMetrics.spacingXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A reload replaces the list the user may have scrolled down past,
            // so the new one is shown from its first row.
            .task(id: reloadKey) {
                proxy.scrollTo(Self.listTopID, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The id of the invisible anchor at the top of the result scroll.
    private static let listTopID = "scan.result.list.top"

    @ViewBuilder
    private var failureBanners: some View {
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
            // The index could not be read. Without this line the page showed an
            // empty result area, which reads as "nothing was found" — a
            // different statement from "the result could not be loaded".
            NoticeBanner(level: .error, message: failure)
        }
    }

    /// Scan context that supplements the result list rather than replacing it.
    @ViewBuilder
    private var supplementalMessages: some View {
        if !scan.skippedLocations.isEmpty {
            SkippedLocationsCard(locations: scan.skippedLocations)
        }
        if scan.phase == .cancelled {
            NoticeBanner(level: .information, titleKey: .scanPhaseCancelled)
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        failureBanners
        if !scan.skippedLocations.isEmpty {
            SkippedLocationsCard(locations: scan.skippedLocations)
        }
        if scan.phase == .cancelled {
            NoticeBanner(level: .information, titleKey: .scanPhaseCancelled)
        }
    }

    // MARK: - Results

    /// The results, as groups over the risk levels.
    ///
    /// There is no "Results" heading above them any more. The tabs directly
    /// above state what the list is showing and how much of it there is, so a
    /// section title repeated both facts in a second type ramp and pushed the
    /// first row down — the third of the three headers the page used to stack
    /// between its chrome and its content.
    ///
    /// The sort control rides the tab strip instead of a line of its own: a row
    /// whose only content is one menu put 40 pt of empty page between the tabs
    /// and the first group. A narrowed filter still prints its own small summary
    /// beside it, because the tabs describe the whole run.
    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty, !isLoading, scan.resultLoadFailure == nil {
                let empty = emptyState
                emptyBlock(
                    symbolName: empty.symbolName,
                    titleKey: empty.titleKey,
                    detailKey: empty.detailKey
                )
            } else {
                resultGroups
            }
        }
    }

    private func emptyBlock(
        symbolName: String,
        titleKey: LocalizationKey,
        detailKey: LocalizationKey
    ) -> some View {
        SiftEmptyState(symbolName: symbolName, titleKey: titleKey, detailKey: detailKey)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SiftMetrics.spacingXL)
    }

    /// Asks LaunchServices which application a residue row belongs to.
    ///
    /// Residue is normally an application that is *gone*, so the usual answer is
    /// "nothing is installed". That is reported, with the identifier copied to the
    /// clipboard, because the identifier is the only handle the user has left for
    /// support or a search — a button that silently revealed nothing would be
    /// worse than no button.
    private func lookUpOwner(_ bundleIdentifier: String) {
        Task {
            switch await environment.revealOwningApplication(bundleIdentifier: bundleIdentifier) {
            case .revealed:
                ownerLookupMessage = nil
            case let .notInstalled(identifier):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(identifier, forType: .string)
                ownerLookupMessage = LocalizationKey.scanResultsOwnerMissing.localized(identifier)
            }
        }
    }

    @ViewBuilder
    private var resultGroups: some View {
        if let ownerLookupMessage {
            NoticeBanner(level: .information, message: ownerLookupMessage)
                .padding(.top, SiftMetrics.spacingM)
        }
        let safeGroup = groupItems(.safe)
        let reviewGroup = groupItems(.review)
        let protectedGroup = groupItems(.protected)
        let safe = isExpanded(.safe) ? visible(safeGroup) : []
        let review = isExpanded(.review) ? visible(reviewGroup) : []
        let protected = isExpanded(.protected) ? visible(protectedGroup) : []

        if !safeGroup.isEmpty {
            riskHeader(.safe, group: safeGroup)
            rows(safe)
            groupFooter(.safe, group: safeGroup)
        }

        if !reviewGroup.isEmpty {
            riskHeader(.review, group: reviewGroup)
            if isExpanded(.review) {
                rows(review)
                groupFooter(.review, group: reviewGroup)
            }
        }

        if !protectedGroup.isEmpty {
            riskHeader(.protected, group: protectedGroup)
            rows(protected)
            groupFooter(.protected, group: protectedGroup)
        }

        if isLoading {
            // A page that is being read, drawn in the shape of the page: four
            // placeholder rows in the same rhythm as real ones.
            ForEach(0..<4, id: \.self) { index in
                SiftSkeletonRow(isFirst: index == 0)
                SiftHairline(inset: SiftMetrics.spacingM)
            }
        } else if hasMore {
            Button {
                Task { await loadMore() }
            } label: {
                Text(LocalizationKey.commonLoadMore.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, SiftMetrics.spacingM)
        }
    }

    /// One group's rows, divided by hairlines and closed by one.
    @ViewBuilder
    private func rows(_ group: [CleanupItemSummary]) -> some View {
        ForEach(group, id: \.stableRowID) { item in
            ScanItemRow(
                item: item,
                cleanup: cleanup,
                onLookUpOwner: lookUpOwner,
                focus: $focusedRow,
                onMove: moveCursor
            )
            SiftHairline(inset: SiftMetrics.spacingM)
        }
    }

    /// What an open group is holding back, directly under its own rows.
    ///
    /// It belongs to the group it describes: the footer used to sit once at the
    /// bottom of the whole list, so "33 smaller items" appeared under the review
    /// group it was not counting.
    @ViewBuilder
    private func groupFooter(_ risk: CleanupRisk, group: [CleanupItemSummary]) -> some View {
        let shown = visible(group).count
        if isExpanded(risk), !showsAllRows, shown < group.count {
            HStack(spacing: SiftMetrics.spacingM) {
                Text(
                    LocalizationKey.overviewMoreItems.localized(
                        group.count - shown,
                        SiftFormat.bytes(
                            group.dropFirst(shown).reduce(Int64(0)) { $0 + $1.sizeInBytes }
                        )
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.quietText)
                Spacer(minLength: SiftMetrics.spacingS)
                Button {
                    Task { await showAllRows() }
                } label: {
                    Text(LocalizationKey.overviewShowAll.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
            .padding(.leading, 14 + SiftMetrics.spacingS)
            .padding(.vertical, SiftMetrics.spacingS)
        }
    }

    /// Whether a group's rows are on screen.
    ///
    /// The default comes from the risk level — `review` opens closed — and a
    /// click overrides it for the rest of the page's life.
    private func isExpanded(_ risk: CleanupRisk) -> Bool {
        groupExpansion[risk] ?? risk.isExpandedByDefault
    }

    /// A disclosure is a fact about what is on screen, not a performance.
    ///
    /// The rows were animated for 0.24 s to show where they came from; the only
    /// thing the animation reliably produced was a wait between the click and
    /// the rows. Clicking inserts them in the same frame (invariant 45).
    private func toggleExpansion(_ risk: CleanupRisk) {
        groupExpansion[risk] = !isExpanded(risk)
    }

    /// The heading every risk group wears.
    ///
    /// There used to be three: an inert heading for `safe`, a button with its own
    /// type ramp for `review`, and a third for `protected`. They read as three
    /// different kinds of object on one page, which is most of what made the
    /// result area look assembled rather than designed. One heading now carries
    /// all three: the risk's own glyph, its name, how many rows it holds and what
    /// they weigh, then one optional action and the disclosure.
    ///
    /// The glyph is the group's rank signal — a filled tick for `safe`, a warning
    /// triangle for `review`, a lock for `protected` — and it is also what lets a
    /// row stop carrying a badge: a row's risk is its group's.
    @ViewBuilder
    private func riskHeader(_ risk: CleanupRisk, group: [CleanupItemSummary]) -> some View {
        let expanded = isExpanded(risk)
        VStack(alignment: .leading, spacing: 0) {
            // The disclosure and the group's action are two controls beside each
            // other rather than one nested inside the other: a link drawn inside
            // a button's label is a target that looks clickable and is not.
            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    toggleExpansion(risk)
                } label: {
                    HStack(spacing: SiftMetrics.spacingS) {
                        Image(systemName: risk.groupSymbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SiftColor.textColor(for: risk.level))
                            .frame(width: 14)
                        Text(risk.groupTitleKey.localized)
                            .font(SiftFont.secondaryHeading)
                            .foregroundStyle(SiftColor.mainText)
                        Text(LocalizationKey.commonItemCount.counted(group.count))
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.secondaryText)
                        Text(SiftFormat.bytes(group.reduce(0) { $0 + $1.sizeInBytes }))
                            .font(SiftFont.caption)
                            .monospacedDigit()
                            .foregroundStyle(SiftColor.secondaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SiftColor.quietText)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .padding(.leading, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(risk.groupTitleKey.localized))
                .accessibilityValue(
                    Text(
                        "\(LocalizationKey.commonItemCount.counted(group.count)), "
                            + SiftFormat.bytes(group.reduce(0) { $0 + $1.sizeInBytes })
                    )
                )
                .accessibilityHint(Text(risk.detailKey.localized))

                Spacer(minLength: SiftMetrics.spacingS)

                // Only the review group offers this from its heading: the safe
                // group is already fully selected, and the protected group cannot
                // be selected at all.
                if risk == .review, expanded {
                    reviewSelectAll(for: group)
                }
            }

            // The review group states its rule once, for the whole group. The
            // rows used to carry it individually, which put the same sentence on
            // 114 rows and turned the one thing worth reading into texture.
            if risk == .review, expanded {
                Text(LocalizationKey.scanResultsReviewHint.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.quietText)
                    .padding(.leading, 14 + SiftMetrics.spacingS)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, SiftMetrics.spacingL)
        .padding(.bottom, SiftMetrics.spacingS)
        .background {
            // The select-all confirmation belongs to the heading that offers it,
            // so it lives here rather than on a header built for one risk.
            Color.clear
                .confirmationDialog(
                    LocalizationKey.scanSelectAllShown.localized(pendingSelectAll.count),
                    isPresented: Binding(
                        get: { !pendingSelectAll.isEmpty },
                        set: { presented in if !presented { pendingSelectAll = [] } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(LocalizationKey.scanSelectAll.localized) {
                        // Only what the page is showing: a row the list has not
                        // revealed yet is not something the user agreed to by
                        // opening a group.
                        cleanup.selectAll(
                            in: pendingSelectAll
                                .filter { $0.risk.isCleanable }
                                .map { $0.asCleanupItem() }
                        )
                        pendingSelectAll = []
                    }
                    Button(LocalizationKey.cleanupConfirmCancel.localized, role: .cancel) {
                        pendingSelectAll = []
                    }
                } message: {
                    Text(LocalizationKey.cleanupConfirmRiskWarning.localized)
                }
        }
    }

    /// The review heading's select-all, as a button.
    ///
    /// It is a link inside the heading, so the heading's own click target keeps
    /// toggling the disclosure; this is the one nested control and it exists
    /// because selecting 114 rows one at a time is not a real option.
    private func reviewSelectAll(for group: [CleanupItemSummary]) -> some View {
        Button {
            pendingSelectAll = visible(group)
        } label: {
            Text(LocalizationKey.scanSelectAllShown.localized(visible(group).count))
                .font(SiftFont.caption)
        }
        .buttonStyle(SiftLinkButtonStyle())
    }

    private var sortMenu: some View {
        Menu {
            ForEach([ScanSort.size, .name, .modified], id: \.self) { candidate in
                Button {
                    sort = candidate
                } label: {
                    Text(candidate.titleKey.localized)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(sort.titleKey.localized)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(SiftFont.caption)
            .foregroundStyle(SiftColor.secondaryText)
            .padding(.horizontal, SiftMetrics.spacingM)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(SiftColor.controlFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.hairline)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// What the collapsed groups are hiding.
    ///
    /// "N smaller items" is a claim about the sort: under name or modification
    /// date the rows behind the fold are not smaller, they are simply not shown.
    /// Two figures are two pieces of text with space between them rather than one
    /// string joined by a separator glyph.
    @ViewBuilder
    private var hiddenSummary: some View {
        let count = LocalizationKey.commonItemCount.counted(hiddenItemCount)
        let bytes = SiftFormat.bytes(hiddenBytes)
        if sort == .size {
            Text(LocalizationKey.overviewMoreItems.localized(hiddenItemCount, bytes))
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
        } else {
            HStack(spacing: SiftMetrics.spacingS) {
                Text(count)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                Text(bytes)
                    .font(SiftFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(SiftColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The narrow filter's own summary: bytes and count, side by side.
    ///
    /// The "showing x of y" tail is gone with the separator: the list states how
    /// many rows it is holding back in the row that offers to reveal them, so the
    /// heading does not need to repeat it in a second spelling.
    @ViewBuilder
    private var resultSummary: some View {
        let totals = scan.categoryTotals.limited(to: filter.categories)
        let bytes = SiftFormat.bytes(
            filter == .duplicates
                ? scan.duplicateReclaimableBytes
                : totals.reduce(Int64(0)) { $0 + $1.totalBytes }
        )
        let count = filter == .duplicates
            ? scan.duplicateGroupsTotal
            : (filter == .all ? (scan.report?.itemCount ?? 0) : totals.reduce(0) { $0 + $1.itemCount })
        HStack(spacing: SiftMetrics.spacingS) {
            Text(bytes)
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(SiftColor.secondaryText)
            Text(LocalizationKey.commonItemCount.counted(count))
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Action bar

    /// The one place the page states what is selected and offers to move it.
    ///
    /// It spans the page under the list rather than sitting in a 272 pt column
    /// beside it: the same facts in a bar cost the list no width, and a summary
    /// that sits below the rows it describes reads as their footer rather than as
    /// a peer (`02 §2`, `02 §9`).
    ///
    /// Four things, in the order a user asks for them: how much the selection
    /// would free, what is in it, where it goes, and the control that sends it
    /// there. Protected rows are not here — they are not selectable, so they are
    /// not part of this sentence; the protected group's own heading states them.
    private var actionBar: some View {
        VStack(spacing: 0) {
            SiftHairline()
            if let actionNotice {
                NoticeBanner(level: actionNotice.level, message: actionNotice.text)
                    .padding(.horizontal, SiftMetrics.pagePadding)
                    .padding(.top, SiftMetrics.spacingM)
            }
            HStack(alignment: .center, spacing: SiftMetrics.spacingL) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleanup.formattedSelectedBytes)
                        .font(SiftFont.pageTitle)
                        .monospacedDigit()
                        .foregroundStyle(cleanup.selectedCount == 0
                            ? SiftColor.quietText
                            : SiftColor.mainText)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    Text(selectionCountLine)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)

                // The split and the Trash sentence are one line of supporting
                // copy each. A selection made of nothing but `safe` rows is the
                // state the page already put the user in, so the split only
                // appears when a review row is in it.
                VStack(alignment: .leading, spacing: 2) {
                    riskSummaryLine
                    summaryHint(
                        symbolName: "arrow.uturn.backward.circle",
                        text: LocalizationKey.scanResultsTrashHint.localized
                    )
                }
                .frame(maxWidth: 460, alignment: .leading)

                Spacer(minLength: SiftMetrics.spacingM)

                Button {
                    pendingSelectAll = displayedCleanableRows
                } label: {
                    Text(LocalizationKey.scanSelectAll.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .keyboardShortcut("a", modifiers: .command)

                Button {
                    cleanup.deselectAll()
                } label: {
                    Text(LocalizationKey.scanDeselectAll.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .keyboardShortcut("a", modifiers: [.command, .shift])

                SiftPrimaryButton(
                    title: LocalizationKey.cleanupConfirmMoveAction.localized,
                    symbolName: "trash",
                    isEnabled: cleanup.selectedCount > 0 && !cleanup.isWorking
                ) {
                    Task { await beginCleanup() }
                }
                .accessibilityIdentifier("scan.clean")
                .fixedSize()
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.spacingM)

            // `02 §5`: a control that is disabled has to say why.
            if cleanup.selectedCount == 0 {
                HStack(spacing: 0) {
                    Text(LocalizationKey.scanResultsReportHint.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.quietText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.bottom, SiftMetrics.spacingM)
            }
        }
        .background(SiftColor.surfaceColor)
    }

    /// The selection's count, in the form the language's plural rules ask for.
    private var selectionCountLine: String {
        LocalizationKey.commonItemCount.counted(cleanup.selectedCount)
    }

    /// The review rows in the selection, and the selected rows the list is not
    /// showing, on one line.
    ///
    /// The safe count is deliberately absent: every cleanable row starts
    /// selected, so "Safe 37" beside "37 items" says nothing the line above it
    /// has not already said. The review count is the number that decides whether
    /// the batch is worth a second look.
    @ViewBuilder
    private var riskSummaryLine: some View {
        let review = selectedCount(for: .review)
        if review > 0 || hiddenSelectedCount > 0 {
            HStack(spacing: SiftMetrics.spacingS) {
                if review > 0 {
                    riskSegment(.review, count: review)
                }
                if hiddenSelectedCount > 0 {
                    Button {
                        Task { await showAllRows() }
                    } label: {
                        Text(LocalizationKey.scanHiddenSelected.localized(hiddenSelectedCount))
                            .font(SiftFont.metadata)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                    .disabled(hiddenItemCount == 0)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// One `<risk> <count>` pair, the risk word carrying its own colour.
    private func riskSegment(_ level: RiskLevel, count: Int) -> some View {
        HStack(spacing: SiftMetrics.spacingXS) {
            Text(level.labelKey.localized)
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.textColor(for: level))
            Text(SiftFormat.count(count))
                .font(SiftFont.metadata)
                .monospacedDigit()
                .foregroundStyle(SiftColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func selectedCount(for risk: CleanupRisk) -> Int {
        cleanup.selectedItems.count(where: { $0.risk == risk })
    }

    /// Protected rows in this result. Informational: they are never selected, so
    /// they are never in the count or the bytes above.
    private var protectedRowCount: Int {
        groupItems(.protected).count
    }

    /// Selected rows the page cannot show.
    ///
    /// The list renders four rows per open group and pre-selects the whole safe
    /// group, so a button that says "400 items" over eight visible rows is asking
    /// the user to approve rows they have never seen. `hiddenSelectedCount` is
    /// what the action bar states, and this is the predicate it asks.
    private func summaryHint(symbolName: String, text: String) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SiftColor.quietText)
                .padding(.top, 2)
            Text(text)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The empty state for the filter on screen.
    ///
    /// "Nothing to clean up — your Mac looks tidy" was shown for every empty
    /// list, including a filter that had nothing of its own while other
    /// categories held gigabytes. A statement about the whole Mac is reserved for
    /// a run that found nothing at all.
    private var emptyState: (symbolName: String, titleKey: LocalizationKey, detailKey: LocalizationKey) {
        switch filter {
        case .duplicates:
            ("doc.on.doc", .filesNoDuplicates, .filesNoDuplicatesDetail)
        case .large, .old, .junk:
            ("line.3.horizontal.decrease.circle", .scanNothingFoundScope, .scanNothingFoundDetail)
        case .all:
            ("checkmark.circle", .scanNothingFound, .scanNothingFoundDetail)
        }
    }

    // MARK: - Loading

    /// Everything that makes the loaded rows describe a different set.
    ///
    /// `listGeneration` is what a cleanup bumps: without it the rows that just
    /// moved to the Trash stayed in the list, stayed selectable, and a second
    /// click produced a screenful of "already gone".
    private var reloadKey: String {
        let session = scan.report?.sessionID ?? "none"
        // `cleanedPaths` is the list of rows a cleanup moved. It is in the key as
        // well as `listGeneration`: the generation bumps when the batch starts,
        // which is a moment before the model knows what moved, so a reload
        // driven by it alone could fetch the index while the moved rows were
        // still in it.
        return "\(session)-\(filter.rawValue)-\(sort.rawValue)-\(cleanup.listGeneration)-\(scan.cleanedPaths.count)"
    }

    private func reload() async {
        guard hasActionableResults else {
            items = []
            cursors = [:]
            hasMore = false
            showsAllRows = false
            return
        }
        isLoading = true
        showsAllRows = false
        defer { isLoading = false }

        // A previous filter may have had more pages. Leaving the old value set
        // showed "Load more" on a filter that had already loaded everything.
        hasMore = false
        let expectedKey = reloadKey

        // Rows are collected beside the old ones and swapped in at the end: the
        // old list used to be emptied first, so every chip click flashed an
        // empty list before the new page arrived.
        var fresh: [CleanupItemSummary] = []
        var freshCursors: [CleanupCategory: Int] = [:]
        for category in filter.rowCategories {
            let page = await scan.page(offset: 0, limit: pageSize, sort: sort, category: category)
            guard reloadKey == expectedKey else { return }
            fresh.append(contentsOf: page.items)
            freshCursors[category] = page.items.count
            if page.remaining > 0 { hasMore = true }
        }

        items = deduplicated(fresh).sorted(by: sortComparator)
        cursors = freshCursors
        cleanup.appendItems(items.map { $0.asCleanupItem() })
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let expectedKey = reloadKey

        var added: [CleanupItemSummary] = []
        for category in filter.rowCategories {
            let offset = cursors[category] ?? 0
            let page = await scan.page(offset: offset, limit: pageSize, sort: sort, category: category)
            guard reloadKey == expectedKey else { return }
            added.append(contentsOf: page.items)
            cursors[category] = offset + page.items.count
        }
        hasMore = false
        for category in filter.rowCategories {
            let page = await scan.page(
                offset: cursors[category] ?? 0,
                limit: 1,
                sort: sort,
                category: category
            )
            guard reloadKey == expectedKey else { return }
            if page.remaining > 0 { hasMore = true }
        }
        let known = Set(items.map { CleanupItem.stableID(category: $0.category, url: $0.url) })
        let unique = deduplicated(added).filter {
            !known.contains(CleanupItem.stableID(category: $0.category, url: $0.url))
        }
        items.append(contentsOf: unique)
        items.sort(by: sortComparator)
        cleanup.appendItems(unique.map { $0.asCleanupItem() })
    }

    /// One row per cleanup target.
    ///
    /// The engine can report one path under two rules that share a category; the
    /// cleanup identity is category plus path, so two rows would share a
    /// checkbox and look like a duplicate. The list keeps the first row, which
    /// the engine ordered by the current sort.
    private func deduplicated(_ items: [CleanupItemSummary]) -> [CleanupItemSummary] {
        var seen = Set<String>()
        return items.filter {
            seen.insert(CleanupItem.stableID(category: $0.category, url: $0.url)).inserted
        }
    }

    private func showAllRows() async {
        showsAllRows = true
        if hasMore {
            await loadMore()
        }
    }

    private var sortComparator: (CleanupItemSummary, CleanupItemSummary) -> Bool {
        switch sort {
        case .size:
            return { $0.sizeInBytes > $1.sizeInBytes }
        case .name:
            return { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .modified:
            return { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .category:
            return { lhs, rhs in
                lhs.category.displayOrder == rhs.category.displayOrder
                    ? lhs.sizeInBytes > rhs.sizeInBytes
                    : lhs.category.displayOrder < rhs.category.displayOrder
            }
        }
    }

    // MARK: - Selection helpers

    private func groupItems(_ risk: CleanupRisk) -> [CleanupItemSummary] {
        items.filter { $0.risk == risk }
    }

    private func visible(_ group: [CleanupItemSummary]) -> [CleanupItemSummary] {
        showsAllRows ? group : Array(group.prefix(collapsedRowsPerGroup))
    }

    /// The risks whose rows are on screen, in display order.
    private var expandedGroups: [CleanupRisk] {
        [.safe, .review, .protected].filter { isExpanded($0) }
    }

    private var visibleRowCount: Int {
        expandedGroups.reduce(0) { total, risk in
            let count = groupItems(risk).count
            return total + (showsAllRows ? count : min(count, collapsedRowsPerGroup))
        }
    }

    /// Rows this page holds back *within* an open group.
    ///
    /// A closed group is not counted: its header already states what it holds,
    /// and adding it here would offer "show all" for rows the user did not ask
    /// to see yet.
    private var hiddenItemCount: Int {
        expandedGroups.reduce(0) { total, risk in
            let count = groupItems(risk).count
            return total + (showsAllRows ? 0 : max(count - collapsedRowsPerGroup, 0))
        }
    }

    private var hiddenBytes: Int64 {
        let shownIDs = Set(
            expandedGroups.flatMap { visible(groupItems($0)).map(\.stableRowID) }
        )
        let expandedIDs = Set(expandedGroups.flatMap { groupItems($0).map(\.stableRowID) })
        return items
            .filter { expandedIDs.contains($0.stableRowID) && !shownIDs.contains($0.stableRowID) }
            .reduce(0) { $0 + $1.sizeInBytes }
    }

    /// Rows this filter is showing that may be selected.
    private var displayedCleanableRows: [CleanupItemSummary] {
        items.filter { $0.risk.isCleanable }
    }

    /// Selected rows the current list is not showing.
    ///
    /// The safe group renders four rows and pre-selects every one of them, so a
    /// button that says "clean 347 items" over a list of eight visible rows is
    /// asking the user to approve rows they have never seen. The summary states
    /// the number instead of hiding it.
    private var hiddenSelectedCount: Int {
        let shown = Set(items.map(\.stableRowID))
        let shownPairs = Set(items.map { "\($0.category.rawValue)|\($0.url.path)" })
        return cleanup.selectedItems.filter {
            !shown.contains(CleanupItem.stableID(category: $0.category, url: $0.url))
                && !shownPairs.contains("\($0.category.rawValue)|\($0.url.path)")
        }.count
    }

    /// The keyboard cursor, clamped at both ends.
    private func moveCursor(_ direction: MoveCommandDirection, from rowID: String) {
        let rows = orderedRowIDs
        guard let index = rows.firstIndex(of: rowID) else { return }
        let next: Int
        switch direction {
        case .up: next = max(index - 1, 0)
        case .down: next = min(index + 1, rows.count - 1)
        default: return
        }
        focusedRow = rows[next]
    }

    /// Every row currently on screen, in the order they are drawn.
    private var orderedRowIDs: [String] {
        [CleanupRisk.safe, .review, .protected]
            .flatMap { risk in isExpanded(risk) ? visible(groupItems(risk)).map(\.stableRowID) : [] }
    }

    private func beginCleanup() async {
        actionNotice = nil
        let result = await environment.beginCleanup(
            // The operation the user is looking at, not a fixed one: a report
            // that says "smart scan" for a cleanup started from the "Large"
            // filter describes a different run than the one that happened.
            operation: filter.operationName,
            requiresConfirmation: environment.preferences.showsConfirmationPanel,
            scanReport: environment.scan.report
        )
        switch result {
        case .purchaseRequired:
            onRequestPurchase()
        case .busy:
            actionNotice = (.warning, LocalizationKey.cleanupBusyNotice.localized)
        case .nothingToDo:
            actionNotice = (
                .warning,
                cleanup.failure?.message ?? LocalizationKey.cleanupNothingToDo.localized
            )
        case .awaitingConfirmation, .executed:
            break
        }
    }
}

// MARK: - Filter

/// What the result list is showing. The scan itself is the same for every value.
enum ScanFilter: String, CaseIterable, Identifiable {
    case all
    case junk
    case large
    case old
    case duplicates

    var id: String { rawValue }

    var titleKey: LocalizationKey {
        switch self {
        case .all: .scanFilterAll
        case .junk: .scanFilterJunk
        case .large: .scanFilterLarge
        case .old: .scanFilterOld
        case .duplicates: .scanFilterDuplicates
        }
    }

    /// The categories the list pages rows from. Duplicates are groups rather than
    /// rows, so their filter pages none.
    var rowCategories: [CleanupCategory] {
        switch self {
        case .all: CleanupCategory.allCases.filter { $0 != .duplicateFiles }
        case .junk: CleanupCategory.junkCategories
        case .large: [.largeFiles]
        case .old: [.oldFiles]
        case .duplicates: []
        }
    }

    /// Which operation a cleanup started from this filter is.
    var operationName: CleanupOperationName {
        switch self {
        case .large: .largeFiles
        case .old: .oldFiles
        case .duplicates: .duplicateFiles
        case .all, .junk: .junkCleanup
        }
    }

    /// The categories whose totals the chip describes.
    var categories: [CleanupCategory]? {
        switch self {
        case .all: nil
        case .junk: CleanupCategory.junkCategories
        case .large: [.largeFiles]
        case .old: [.oldFiles]
        case .duplicates: nil
        }
    }
}

private extension ScanSort {
    var titleKey: LocalizationKey {
        switch self {
        case .size: .scanResultsSortSize
        case .name: .scanResultsSortName
        case .modified: .scanResultsSortModified
        case .category: .commonSortBy
        }
    }
}

// MARK: - Result row

/// One result row: checkbox, name, path, size and risk.
///
/// Two actions, kept apart on purpose (02 §3): the checkbox changes the
/// selection and nothing else, and the row's body opens the item's detail —
/// the full path, the category, the explanation and the owner lookup that used
/// to occupy a third line on every row. The explanation is not repeated
/// per-row because a list where every line carries a sentence is a list nobody
/// scans; it is one click away instead.
struct ScanItemRow: View {
    let item: CleanupItemSummary
    @ObservedObject var cleanup: CleanupModel

    /// Asks which application the row belongs to.
    ///
    /// Only residue rows carry a bundle identifier, and the answer is usually
    /// "nothing is installed" — which is why the page says that instead of
    /// offering a button that appears to do nothing.
    var onLookUpOwner: ((String) -> Void)? = nil
    /// The page's keyboard cursor, and how a row asks it to move.
    var focus: FocusState<String?>.Binding
    var onMove: (MoveCommandDirection, String) -> Void

    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var showsDetail = false

    var body: some View {
        let domainItem = item.asCleanupItem()

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SiftMetrics.spacingM) {
                leadingControl(domainItem)

                // The body of the row. Name and path belong together and are
                // one spoken element: the detail block below repeats them, and
                // VoiceOver reads the row once.
                Button {
                    showsDetail.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(SiftFont.secondaryHeading)
                            .foregroundStyle(item.risk.isCleanable ? SiftColor.mainText : SiftColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.displayPath)
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(domainItem.explanation())
                .accessibilityLabel(
                    Text("\(item.displayName), \(item.displayPath), \(domainItem.explanation())")
                )
                .accessibilityValue(Text(item.formattedSize))
                .accessibilityHint(Text(item.risk.detailKey.localized))

                Spacer(minLength: SiftMetrics.spacingS)

                // The row's three right-hand slots used to be a size, a chevron,
                // a Finder button and a risk badge — on every row. The badge is
                // the group's job (a group is one risk), the chevron duplicated
                // the row body's own click, and the Finder button is an
                // occasional action that keeps its place without holding a
                // permanent glyph in the scan path.
                Text(item.formattedSize)
                    .font(SiftFont.monospacedEmphasis)
                    .foregroundStyle(SiftColor.mainText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .trailing)
                    .accessibilityHidden(true)

                revealButton
                    .opacity(isHovering || showsDetail ? 1 : 0)
                    .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
            }

            if showsDetail {
                detailBlock(domainItem)
            }
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, SiftMetrics.spacingXS)
        .frame(minHeight: SiftMetrics.rowHeightTwoLine)
        .background(isHovering ? SiftColor.rowHoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
        // The same two actions the row offers as buttons, on every row of every
        // group: a path the user can inspect is the cheapest way to judge a row
        // the page cannot judge for them.
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label(
                    LocalizationKey.filesRevealInFinder.localized,
                    systemImage: "folder"
                )
            }
            if let bundleIdentifier = item.relatedBundleID, let onLookUpOwner {
                Button {
                    onLookUpOwner(bundleIdentifier)
                } label: {
                    Label(
                        LocalizationKey.scanResultsOwnerAction.localized,
                        systemImage: "app.badge.checkmark"
                    )
                }
                .help(bundleIdentifier)
            }
        }
    }

    /// The row's leading slot: the checkbox, or the lock that says why there is
    /// no checkbox.
    ///
    /// A protected row used to carry a greyed-out checkbox and a "Protected"
    /// badge on the right, so the same fact was drawn twice and the second copy
    /// sat where a reader looks for the item's size. The shape of the control is
    /// the statement now.
    @ViewBuilder
    private func leadingControl(_ domainItem: CleanupItem) -> some View {
        if item.risk.isCleanable {
            SiftCheckbox(
                isOn: Binding(
                    get: { cleanup.isSelected(domainItem) },
                    set: { cleanup.setSelected($0, for: domainItem) }
                ),
                isEnabled: true
            )
            .focused(focus, equals: item.stableRowID)
            .onMoveCommand { direction in onMove(direction, item.stableRowID) }
            .accessibilityLabel(Text(item.displayName))
            .accessibilityHint(Text(item.risk.detailKey.localized))
        } else {
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SiftColor.quietText)
                .frame(width: 18, height: 18)
                .accessibilityLabel(Text(item.risk.detailKey.localized))
        }
    }

    private var revealButton: some View {
        SiftIconButton(
            symbolName: "folder",
            help: LocalizationKey.filesRevealInFinder.localized
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
    }

    /// The item's detail: everything the row cannot say in two lines.
    ///
    /// Opened in the frame the click landed in — no expansion animation — for the
    /// same reason a group opens immediately (invariant 45).
    private func detailBlock(_ domainItem: CleanupItem) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(domainItem.explanation())
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.url.path)
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.quietText)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: SiftMetrics.spacingM) {
                Text(item.category.titleKey.localized)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                if item.fileCount > 1 {
                    Text(LocalizationKey.commonFileCount.counted(item.fileCount))
                        .font(SiftFont.metadata)
                        .foregroundStyle(SiftColor.quietText)
                }
                if let bundleIdentifier = item.relatedBundleID,
                   let onLookUpOwner,
                   item.category == .applicationResidue
                    || item.category == .groupContainerResidue {
                    Button {
                        onLookUpOwner(bundleIdentifier)
                    } label: {
                        Text(LocalizationKey.scanResultsOwnerAction.localized)
                            .font(SiftFont.metadata)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                    .help(bundleIdentifier)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, SiftMetrics.spacingXS)
        .padding(.bottom, SiftMetrics.spacingS)
        .padding(.leading, 44 + SiftMetrics.spacingM)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Running

/// The live scan: the phase, what is being examined, and how much has been found.
///
/// The core reports phases, not a fraction, so the ring is indeterminate and the
/// page states the step instead of a percentage. The category list says "found"
/// rather than "progress": it counts what the run has actually discovered, which
/// is a fact, instead of drawing a bar the engine never measured.
struct ScanRunningCard: View {
    @ObservedObject var scan: ScanModel
    let displayPhase: ScanPhase?
    let onOpenPermissions: () -> Void

    @Environment(\.siftReduceMotion) private var reduceMotion

    init(scan: ScanModel, displayPhase: ScanPhase? = nil, onOpenPermissions: @escaping () -> Void) {
        self.scan = scan
        self.displayPhase = displayPhase
        self.onOpenPermissions = onOpenPermissions
    }

    /// The phase the card shows. While the request is being assembled the engine
    /// has no phase of its own, so the page passes `.preparing` in rather than
    /// claiming the run has already started.
    private var phase: ScanPhase { displayPhase ?? scan.phase }

    /// The item name as displayed.
    ///
    /// The engine reports a leaf name on every progress event, several times a
    /// second. Rendered directly, the chip was unreadable — it changed faster
    /// than anyone could read it. This is a leading-edge throttle: the first
    /// name appears immediately and later ones at most every 0.6 s.
    @State private var shownItemName = ""
    @State private var lastNameCommit = Date.distantPast

    private func commitItemName(_ name: String) {
        let now = Date()
        guard shownItemName.isEmpty
            || now.timeIntervalSince(lastNameCommit) > 0.6
            || name.isEmpty
        else { return }
        lastNameCommit = now
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.15)) {
            shownItemName = name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            SiftSection(style: .outlined, padding: SiftMetrics.spacingXL) {
                HStack(spacing: SiftMetrics.spacingXL) {
                    // The centre used to read "2/4", which sits in the slot a
                    // percentage sits in and was read as progress by everyone who
                    // saw it. The bytes found so far are the fact the run
                    // actually measures, and they only ever grow.
                    SiftProgressRing(
                        progress: nil,
                        lineWidth: 9,
                        label: SiftFormat.bytes(scan.liveFoundBytes),
                        caption: LocalizationKey.scanRunningStep.localized(
                            phase.step ?? 0,
                            ScanPhase.stepCount
                        ),
                        spokenLabel: phase.labelKey.localized,
                        spokenValue: "\(SiftFormat.bytes(scan.liveFoundBytes)), \(LocalizationKey.scanRunningStep.localized(phase.step ?? 0, ScanPhase.stepCount))"
                    )
                    .frame(width: 112, height: 112)

                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        // Sentence case, no tracking (`01` §Typography).
                        Text(LocalizationKey.scanRunningTarget.localized)
                            .font(SiftFont.eyebrow)
                            .foregroundStyle(SiftColor.quietText)
                        Text(phase.labelKey.localized)
                            .font(SiftFont.title)
                            .foregroundStyle(SiftColor.mainText)
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : SiftMotion.phase, value: phase)
                        if !shownItemName.isEmpty {
                            Text(LocalizationKey.scanCurrentItem.localized(shownItemName))
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.secondaryText)
                                .contentTransition(.opacity)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, SiftMetrics.spacingM)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                                        .fill(SiftColor.controlFill)
                                )
                        }
                        HStack(spacing: SiftMetrics.spacingM) {
                            Text(
                                LocalizationKey.scanRunningWalked.localized(
                                    SiftFormat.count(scan.progress.filesSeen)
                                )
                            )
                            // The found figure is the candidate bytes the item
                            // events actually delivered, not the volume the
                            // walk has looked at — those are different facts.
                            Text(
                                LocalizationKey.scanRunningFound.localized(
                                    SiftFormat.bytes(scan.liveFoundBytes)
                                )
                            )
                            .foregroundStyle(SiftColor.safeTextColor)
                        }
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                    }

                    Spacer(minLength: SiftMetrics.spacingM)

                    VStack(alignment: .trailing, spacing: SiftMetrics.spacingS) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(LocalizationKey.scanRunningElapsed.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.secondaryText)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(Self.duration(scan.elapsed))
                                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(SiftColor.mainText)
                                    .contentTransition(.numericText())
                            }
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(LocalizationKey.scanRunningPhase.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.secondaryText)
                            Text(phase.labelKey.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.mainText)
                        }
                    }
                }
            }

            SiftSection(style: .outlined, padding: SiftMetrics.spacingL) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LocalizationKey.scanRunningCategories.localized)
                            .font(SiftFont.sectionTitle)
                        Spacer()
                        Text(
                            LocalizationKey.scanRunningCategoryCount.localized(
                                ScanFilter.junk.rowCategories.count + 2
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                    }
                    .padding(.bottom, SiftMetrics.spacingM)

                    SiftHairline()

                    ForEach(categories, id: \.self) { category in
                        categoryRow(category)
                        SiftHairline()
                    }

                    HStack(spacing: SiftMetrics.spacingS) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SiftColor.quietText)
                        Text(LocalizationKey.scanRunningReadOnly.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.quietText)
                        Spacer(minLength: SiftMetrics.spacingS)
                        Button(action: onOpenPermissions) {
                            Text(LocalizationKey.permissionOpenSettings.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                    .padding(.top, SiftMetrics.spacingM)
                }
            }
        }
        .onAppear { commitItemName(scan.progress.currentItemName) }
        // `task(id:)` rather than `onChange`: the package targets macOS 13, and
        // the two-parameter `onChange` is 14+. Restarting on a new value with a
        // timestamp inside `commitItemName` is the same leading-edge throttle.
        .task(id: scan.progress.currentItemName) {
            commitItemName(scan.progress.currentItemName)
        }
    }

    private var categories: [CleanupCategory] {
        CleanupCategory.junkCategories + [.largeFiles, .oldFiles]
    }

    /// Bytes discovered for the category so far in this run.
    ///
    /// The per-category bar is a share, not a progress: it reads `bytes ÷
    /// largest category`, so the largest category is always full and the rest
    /// are proportionally shorter. The figures come from the accumulator that
    /// folds every item event, so a strategy whose items were pushed out of the
    /// recent window by a later one keeps its bar instead of collapsing to
    /// zero.
    private func liveBytes(_ category: CleanupCategory) -> Int64 {
        scan.liveBytes(for: category)
    }

    private func categoryRow(_ category: CleanupCategory) -> some View {
        let bytes = liveBytes(category)
        let largest = categories.map(liveBytes).max() ?? 0
        let fraction = largest > 0 ? Double(bytes) / Double(largest) : 0
        let tint = SiftColor.categoryPalette[category.paletteIndex]
        return HStack(spacing: SiftMetrics.spacingM) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(category.titleKey.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)

            // A share of the largest category, not progress. A category with
            // no bytes yet shows no bar at all — an empty grey track here reads
            // as measured-zero and, across nine categories, becomes a stack of
            // grey placeholder lines with no information in them.
            if bytes > 0 {
                UsageBar(
                    fraction: fraction,
                    tint: tint.opacity(0.7),
                    height: 4,
                    showsEmptyTrack: false
                )
            } else {
                Spacer(minLength: 0)
            }

            Text(bytes > 0 || phase.hasResults ? SiftFormat.bytes(bytes) : "—")
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(SiftColor.secondaryText)
                .frame(width: 74, alignment: .trailing)

            Text(
                (phase.hasResults
                    ? LocalizationKey.commonDone
                    : (bytes > 0 ? LocalizationKey.scanRunningFinding : LocalizationKey.scanRunningWaiting)).localized
            )
            .font(SiftFont.badge)
            .foregroundStyle(bytes > 0 ? SiftColor.safeTextColor : SiftColor.quietText)
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(category.titleKey.localized))
        .accessibilityValue(Text(SiftFormat.bytes(bytes)))
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(Int(interval), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Skipped locations

/// The skipped-location list, rolled up by top-level directory.
///
/// A scan that cannot read ~/Library reports two dozen children and the flat
/// list read like noise; the card now shows one row per directory — "~/Library
/// 24 项" — with the location-level detail one click away, because the
/// summary is what the user can act on and the detail is what they audit.
struct SkippedLocationsCard: View {
    let locations: [SkippedLocation]
    @State private var expandedGroups: Set<String> = []
    @State private var showsDetails = false

    private var allGroups: [SkippedLocationGroup] {
        SkippedLocation.groupedByTopLevelDirectory(locations)
    }

    /// The only skips a grant could change. These stay fully visible: the user
    /// can open System Settings about them, so hiding them would hide an action.
    private var actionableGroups: [SkippedLocationGroup] {
        allGroups.filter(\.hasActionableLocations)
    }

    /// Policy-protected and administrator-only locations. Nothing the user can
    /// toggle changes these, so they collapse to one summary row instead of a
    /// list that reads like a permission the user forgot to give.
    private var inactiveGroups: [SkippedLocationGroup] {
        allGroups.filter { !$0.hasActionableLocations }
    }

    private var inactiveLocationCount: Int {
        inactiveGroups.reduce(0) { $0 + $1.locations.count }
    }

    /// Locations a grant could still change — a TCC refusal and nothing else.
    private var actionableCount: Int {
        locations.count(where: \.isActionable)
    }

    /// "Some locations could not be read" is only true for the reasons a person
    /// can act on.
    ///
    /// A location the protection list refuses was never unreadable, and a
    /// `0700` directory owned by `root` is not missing a permission the user
    /// forgot to give: both used to send the user to System Settings for a
    /// switch that changes nothing.
    private var cardTitle: String {
        if actionableCount > 0 {
            // Name the specific grant rather than the generic "some locations
            // could not be read" — that sentence also appears as the header
            // status on a partial run, and two identical lines read as a bug.
            return LocalizationKey.permissionFullDiskAccess.localized
        }
        // No grant changes any of these. The protected/system rows now live
        // behind one collapsed summary, so the card title must name the whole
        // set rather than repeat the summary row's own label.
        return LocalizationKey.permissionProtectedTitle.localized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One line, collapsed by default. The card used to open with a
            // section heading, a settings link, one row per unreadable directory,
            // a second collapsible list for the ones no grant can open, and a
            // restart note — enough to take a screen, in the common case where
            // every unreadable location is one the product refuses on purpose.
            // The line states the count a person can act on, the link that grants
            // it, and a disclosure for the audit.
            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SiftColor.reviewTextColor)
                    .frame(width: 14)
                Text(summaryLine)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SiftMetrics.spacingS)
                if actionableCount > 0 {
                    Button {
                        Task { await WorkspaceActions.openFullDiskAccessSettings() }
                    } label: {
                        Text(LocalizationKey.permissionOpenSettings.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                Button {
                    showsDetails.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
                        .rotationEffect(.degrees(showsDetails ? 180 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(cardTitle))
                .accessibilityHint(Text(LocalizationKey.scanSkippedExpandHint.localized))
            }
            .padding(.vertical, SiftMetrics.spacingS)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.controlCornerRadius, style: .continuous)
                    .fill(SiftColor.controlFill)
            }

            if showsDetails {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                    if actionableCount > 0 {
                        // The switch is on and these rows still say "permission":
                        // macOS applies a TCC grant when an app starts, and a
                        // rebuilt or updated copy of Sift is a different code
                        // identity.
                        Text(LocalizationKey.permissionRestartHint.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.quietText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(actionableGroups) { group in
                        groupSection(group)
                        SiftHairline()
                    }

                    if !inactiveGroups.isEmpty {
                        Text(LocalizationKey.permissionSystemProtectedTitle.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.quietText)
                        ForEach(inactiveGroups) { group in
                            groupSection(group)
                            SiftHairline()
                        }
                    }
                }
                .padding(.top, SiftMetrics.spacingM)
            }
        }
    }

    /// The one sentence a collapsed card says.
    ///
    /// It counts what a grant could change, never the whole skip list: a
    /// `0700` directory owned by `root` and a location the protection list
    /// refuses are both unreadable on purpose, and adding them to the number
    /// would promise a switch that changes nothing.
    private var summaryLine: String {
        if actionableCount > 0 {
            return LocalizationKey.scanSkippedActionable.localized(actionableCount)
        }
        return LocalizationKey.scanSkippedProtectedSummary.localized(locations.count)
    }

    @ViewBuilder
    private func groupSection(_ group: SkippedLocationGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        let isExpandable = group.locations.count > 1
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Button {
                guard isExpandable else { return }
                if isExpanded {
                    expandedGroups.remove(group.id)
                } else {
                    expandedGroups.insert(group.id)
                }
            } label: {
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SiftColor.quietText)
                    Text(group.label)
                        .font(SiftFont.secondaryHeading)
                        .foregroundStyle(SiftColor.mainText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isExpandable {
                        Text(LocalizationKey.commonItemCount.counted(group.locations.count))
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                    // A single-location group states its reason on the same line
                    // rather than under it: the sentence is the reason the row
                    // exists, and a second line per directory turned five
                    // directories into ten lines of grey.
                    if let reason = group.sharedReasonKey, !isExpandable {
                        Text(reason.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: SiftMetrics.spacingS)
                    if isExpandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SiftColor.quietText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isExpandable)
            .accessibilityLabel(Text(group.label))
            .accessibilityHint(Text(isExpandable ? LocalizationKey.overviewShowAll.localized : ""))

            // The shared reason appears only where the reader is looking at the
            // locations it applies to, i.e. once the group is open. A collapsed
            // group is a count; an open one is the list, and one sentence for
            // the whole list still beats one sentence per row.
            if let reason = group.sharedReasonKey, isExpandable, isExpanded {
                Text(reason.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
            }
            if isExpanded {
                ForEach(group.locations) { location in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.displayPath)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if group.sharedReasonKey == nil {
                            Text(location.reasonKey.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.quietText)
                        }
                    }
                    .padding(.leading, SiftMetrics.spacingXL)
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The row identity for a merged list.
///
/// The engine's per-row id is the offset inside the page it came from, so the
/// first row of every category page is id 1. A merged list needs the cleanup
/// target's identity instead, which is exactly what the selection uses.
private extension CleanupItemSummary {
    var stableRowID: String {
        CleanupItem.stableID(category: category, url: url)
    }
}
