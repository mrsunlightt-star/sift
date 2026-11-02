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
/// view and one selection rail.
public struct ScanView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Observed directly: the page's header, its result branch and its summary
    /// rail all change with the scan, and a view that reads the model through
    /// the environment does not subscribe to it.
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

    /// Moves the keyboard cursor by one row, clamped at both ends.
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

    /// What the last click on "clean" produced, when it produced no panel.
    @State private var actionNotice: (level: NoticeBanner.Level, text: String)?

    /// Set while the dialog that turns a whole review group into a selection
    /// is up.
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
            SiftPageHeader(title: LocalizationKey.navScan.localized, status: headerStatus) {
                headerAction
            }

            if hasActionableResults {
                filterBar
                resultsWorkspace
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
                            startCard
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

    /// True when the run ended without a result but did find something.
    ///
    /// A cancelled or failed run used to fall straight back to the empty start
    /// card: forty seconds of walking left nothing on screen but the phase name.
    /// The page now states what the run found before it stopped. It does not
    /// offer a cleanable list, because the core's worker removes its own index
    /// when it ends — a claim it could not honour would be worse than the number.
    private var showsStoppedCard: Bool {
        guard scan.phase == .cancelled || scan.phase == .failed else { return false }
        return (scan.report?.itemCount ?? scan.progress.itemsFound) > 0
            || scan.progress.filesSeen > 0
            || !scan.skippedLocations.isEmpty
    }

    private var stoppedCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                SiftGlassCard(padding: SiftMetrics.spacingXL) {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
                            Image(systemName: scan.phase.symbolName)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(SiftColor.textColor(for: .review))
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
                                .foregroundStyle(.secondary)
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
                .siftAppear(index: 0)

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
            .foregroundStyle(.secondary)
            .padding(.horizontal, SiftMetrics.spacingS)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .fill(SiftColor.subtleFill)
            )
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

    /// The results page keeps the summary rail in place while the list scrolls.
    /// The clean action is the reason the page exists, so it must not move out of
    /// sight when a scan found hundreds of rows.
    ///
    /// The result list is the first thing in the scroll, not the scan's
    /// footnotes: a run that could not read a few dozen locations used to open
    /// on a two-screen "some locations could not be read" card with the whole
    /// result list below the fold, and a chip click then changed a list the
    /// user could not see. Failures stay on top — they explain a short list —
    /// while the skipped locations and the cancelled notice follow the results
    /// they supplement.
    private var resultsWorkspace: some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
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
                        if filter == .duplicates {
                            if scan.duplicateGroups.isEmpty {
                                SiftGlassCard(padding: SiftMetrics.spacingXL) {
                                    SiftEmptyState(
                                        symbolName: "doc.on.doc",
                                        titleKey: .filesNoDuplicates,
                                        detailKey: .filesRequiresAuthorization
                                    )
                                }
                            } else {
                                DuplicateGroupsCard(
                                    groups: scan.duplicateGroups,
                                    scan: scan,
                                    cleanup: cleanup
                                )
                            }
                        } else {
                            resultsCard
                            // The card is a second, self-contained result set.
                            // Showing it under "Junk" or "Large" claimed the
                            // duplicate files were part of that filter.
                            if !scan.duplicateGroups.isEmpty, filter == .all {
                                DuplicateGroupsCard(
                                    groups: scan.duplicateGroups,
                                    scan: scan,
                                    cleanup: cleanup
                                )
                            }
                        }
                        supplementalMessages
                    }
                    .padding(.horizontal, SiftMetrics.pagePadding)
                    .padding(.bottom, SiftMetrics.spacingXL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A reload replaces the list the user may have scrolled down
                // past, so the new one is shown from its first row.
                .task(id: reloadKey) {
                    proxy.scrollTo(Self.listTopID, anchor: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            summaryRail
                .frame(width: SiftMetrics.summaryColumnWidth)
                .padding(.trailing, SiftMetrics.pagePadding)
                .padding(.bottom, SiftMetrics.spacingXL)
                .frame(maxHeight: .infinity)
        }
        .padding(.top, SiftMetrics.pageSpacing)
        .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Header

    private var headerStatus: String {
        if isBusy {
            let step = isPreparing ? 1 : (scan.phase.step ?? 1)
            return LocalizationKey.scanRunningStatus.localized(step, ScanPhase.stepCount)
        }
        if scan.hasStoppedResults, let report = scan.report {
            return LocalizationKey.scanHeaderStatus.localized(
                SiftFormat.relativeDate(report.finishedAt ?? report.startedAt),
                report.itemCount
            ) + " · " + LocalizationKey.scanPhaseCancelled.localized
        }
        if scan.phase == .cancelled || scan.phase == .failed {
            return scan.phase.labelKey.localized
        }
        if let report = scan.report {
            let status = LocalizationKey.scanHeaderStatus.localized(
                SiftFormat.relativeDate(report.finishedAt ?? report.startedAt),
                report.itemCount
            )
            guard scan.phase == .partial else { return status }
            // "Some locations could not be read" is about permissions and says
            // nothing about a run that was cut short to keep the app responsive.
            let suffix = scan.skippedLocations.isEmpty
                ? LocalizationKey.scanPartialBudget.localized
                : LocalizationKey.scanPhasePartial.localized
            return status + " · " + suffix
        }
        // The page name is already the title, so the status states only the
        // rest: "Scan, nothing scanned yet" said the same thing twice.
        return LocalizationKey.scanPhaseIdle.localized
    }

    @ViewBuilder
    private var headerAction: some View {
        if isPreparing {
            HStack(spacing: SiftMetrics.spacingS) {
                ProgressView().controlSize(.small)
                Text(LocalizationKey.scanPhasePreparing.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SiftMetrics.spacingM)
        } else if hasActionableResults {
            SiftPrimaryButton(titleKey: .scanRescan, symbolName: "arrow.clockwise") {
                Task { await environment.runScan(.everything) }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SiftMetrics.spacingS) {
                ForEach(ScanFilter.allCases) { candidate in
                    SiftFilterChip(
                        title: candidate.titleKey.localized,
                        detail: chipDetail(candidate),
                        isSelected: filter == candidate
                    ) {
                        filter = candidate
                    }
                }
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.spacingM)
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

    private var startCard: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            SiftGlassCard(padding: SiftMetrics.spacingXL) {
                HStack(alignment: .top, spacing: SiftMetrics.spacingXL) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(SiftColor.accent)
                        .frame(width: 58, height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                                .fill(SiftColor.accent.opacity(0.14))
                        )

                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.dashboardScanCardTitle.localized)
                            .font(SiftFont.title)
                        Text(LocalizationKey.dashboardScanCardSubtitle.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // What the scan will read, before it reads it. The page
                        // used to start walking on the same frame as the click
                        // with no statement of which folders were involved.
                        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                            Text(LocalizationKey.scanFirstRunScope.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
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
                                                .fill(SiftColor.subtleFill)
                                        )
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.top, SiftMetrics.spacingXS)

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
                                .foregroundStyle(SiftColor.subtleText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, SiftMetrics.spacingXS)
                    }

                    Spacer(minLength: 0)
                }
            }
            .siftAppear(index: 0)

            ScanCategoryPreview(ScanFilter.all.categories ?? CleanupCategory.allCases)
                .siftAppear(index: 1)

            SiftGlassCard(padding: SiftMetrics.spacingL) {
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SiftColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.filesScopeTitle.localized)
                            .font(SiftFont.bodyEmphasis)
                        Text(LocalizationKey.filesRequiresAuthorization.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: SiftMetrics.spacingS)
                    Button(action: onManageScope) {
                        Text(LocalizationKey.filesManageScope.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
            }
            .siftAppear(index: 2)
        }
    }

    // MARK: - Results

    private var resultsCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                    Text(LocalizationKey.scanResults.localized)
                        .font(SiftFont.sectionTitle)
                    Text(resultSummary)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: SiftMetrics.spacingS)
                    sortMenu
                }
                .padding(.bottom, SiftMetrics.spacingM)

                Divider()

                if items.isEmpty, !isLoading, scan.resultLoadFailure == nil {
                    let empty = emptyState
                    SiftEmptyState(
                        symbolName: empty.symbolName,
                        titleKey: empty.titleKey,
                        detailKey: empty.detailKey
                    )
                } else {
                    resultGroups
                }

                Divider()
                resultsFooter
            }
        }
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
        }
        let safeGroup = groupItems(.safe)
        let reviewGroup = groupItems(.review)
        let protectedGroup = groupItems(.protected)
        let safe = isExpanded(.safe) ? visible(safeGroup) : []
        let review = isExpanded(.review) ? visible(reviewGroup) : []
        let protected = isExpanded(.protected) ? visible(protectedGroup) : []

        if !safeGroup.isEmpty {
            groupHeader(
                LocalizationKey.scanResultsSafeGroup.localized,
                count: safeGroup.count,
                detail: LocalizationKey.scanResultsDefaultSelected.localized,
                tint: SiftColor.safe
            )
            ForEach(safe, id: \.stableRowID) { item in
                ScanItemRow(
                    item: item,
                    cleanup: cleanup,
                    onLookUpOwner: lookUpOwner,
                    focus: $focusedRow,
                    onMove: moveCursor
                )
                    .transition(.opacity.combined(with: .offset(y: 6)))
                Divider()
            }
        }

        if !reviewGroup.isEmpty {
            reviewHeader(reviewGroup)
            if isExpanded(.review) {
                HStack(spacing: SiftMetrics.spacingS) {
                    Spacer()
                    Button {
                        pendingSelectAll = visible(reviewGroup)
                    } label: {
                        Text(
                            LocalizationKey.scanSelectAllShown
                                .localized(visible(reviewGroup).count)
                        )
                        .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                .padding(.bottom, SiftMetrics.spacingS)

                ForEach(review, id: \.stableRowID) { item in
                    ScanItemRow(
                        item: item,
                        cleanup: cleanup,
                        onLookUpOwner: lookUpOwner,
                        focus: $focusedRow,
                        onMove: moveCursor
                    )
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    Divider()
                }
            }
        }

        if !protectedGroup.isEmpty {
            groupHeader(
                LocalizationKey.scanResultsProtectedGroup.localized,
                count: protectedGroup.count,
                detail: RiskLevel.protected.detailKey.localized,
                tint: SiftColor.danger
            )
            ForEach(protected, id: \.stableRowID) { item in
                ScanItemRow(
                    item: item,
                    cleanup: cleanup,
                    onLookUpOwner: lookUpOwner,
                    focus: $focusedRow,
                    onMove: moveCursor
                )
                Divider()
            }
        }

        if isLoading {
            // A page that is being read, drawn in the shape of the page: four
            // placeholder rows in the same rhythm as real ones.
            ForEach(0..<4, id: \.self) { index in
                SiftSkeletonRow(isFirst: index == 0)
                Divider()
            }
        } else if hiddenItemCount > 0 {
            HStack(spacing: SiftMetrics.spacingM) {
                Text(hiddenSummary)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await showAllRows() }
                } label: {
                    Text(
                        (showsAllRows && hasMore
                            ? LocalizationKey.commonLoadMore
                            : LocalizationKey.overviewShowAll).localized
                    )
                    .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
            .padding(.vertical, SiftMetrics.spacingM)
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

    /// Whether a group's rows are on screen.
    ///
    /// The default comes from the risk level — `review` opens closed — and a
    /// click overrides it for the rest of the page's life.
    private func isExpanded(_ risk: CleanupRisk) -> Bool {
        groupExpansion[risk] ?? risk.isExpandedByDefault
    }

    private func toggleExpansion(_ risk: CleanupRisk) {
        // A group opening is a layout re-flow, not a state change: 0.24 s of
        // smooth motion so the eye can follow where the rows came from.
        withAnimation(SiftMotion.expand) {
            groupExpansion[risk] = !isExpanded(risk)
        }
    }

    /// The review group's header: a disclosure, not a decoration.
    ///
    /// The group starts closed because its rows are the ones that need a
    /// decision each, and a list that opens with them expanded puts the one
    /// group the user has to read next to the one that is already selected. The
    /// header still reports the count and the bytes, so a closed group is a
    /// summary rather than a hidden one — and the hint says why it is closed.
    @ViewBuilder
    private func reviewHeader(_ group: [CleanupItemSummary]) -> some View {
        let expanded = isExpanded(.review)
        Button {
            toggleExpansion(.review)
        } label: {
            HStack(spacing: SiftMetrics.spacingS) {
                Circle()
                    .fill(SiftColor.review)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.scanResultsReviewGroup.localized)
                            .font(SiftFont.bodyEmphasis)
                        Text(LocalizationKey.commonItemCount.counted(group.count))
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                        Text(SiftFormat.bytes(group.reduce(0) { $0 + $1.sizeInBytes }))
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(LocalizationKey.scanResultsReviewHint.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.subtleText)
                }
                Spacer(minLength: SiftMetrics.spacingS)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, SiftMetrics.spacingM)
        .accessibilityLabel(
            Text(LocalizationKey.scanResultsReviewGroup.localized)
        )
        .accessibilityValue(
            Text(LocalizationKey.commonItemCount.counted(group.count))
        )
        .accessibilityHint(Text(LocalizationKey.scanResultsReviewHint.localized))
        .confirmationDialog(
            LocalizationKey.scanSelectAllShown.localized(pendingSelectAll.count),
            isPresented: Binding(
                get: { !pendingSelectAll.isEmpty },
                set: { presented in if !presented { pendingSelectAll = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizationKey.scanSelectAll.localized) {
                // Only what the page is showing: a row the list has not revealed
                // yet is not something the user agreed to by opening a group.
                cleanup.selectAll(in: pendingSelectAll.filter { $0.risk.isCleanable }.map { $0.asCleanupItem() })
                pendingSelectAll = []
            }
            Button(LocalizationKey.cleanupConfirmCancel.localized, role: .cancel) {
                pendingSelectAll = []
            }
        } message: {
            Text(LocalizationKey.cleanupConfirmRiskWarning.localized)
        }
    }

    private func groupHeader(_ title: String, count: Int, detail: String, tint: Color) -> some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(title)
                .font(SiftFont.bodyEmphasis)
            Text(LocalizationKey.commonItemCount.counted(count))
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: SiftMetrics.spacingS)
            Text(detail)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.subtleText)
        }
        .padding(.vertical, SiftMetrics.spacingM)
    }

    private var resultsFooter: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Circle()
                .fill(cleanup.selectedCount > 0 ? SiftColor.accent : SiftColor.neutral.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(
                LocalizationKey.overviewSelectedSummary.localized(
                    cleanup.selectedCount,
                    cleanup.formattedSelectedBytes
                )
            )
            .font(SiftFont.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: SiftMetrics.spacingS)

            Button {
                // The same confirmation the review group asks for, over the same
                // scope: what this filter is showing.
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
        }
        .padding(.top, SiftMetrics.spacingM)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, SiftMetrics.spacingM)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                    .fill(SiftColor.subtleFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                    .strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.hairline)
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
    private var hiddenSummary: String {
        let count = LocalizationKey.commonItemCount.counted(hiddenItemCount)
        let bytes = SiftFormat.bytes(hiddenBytes)
        guard sort == .size else {
            return "\(count) · \(bytes)"
        }
        return LocalizationKey.overviewMoreItems.localized(hiddenItemCount, bytes)
    }

    private var resultSummary: String {
        if filter == .duplicates {
            return "\(SiftFormat.bytes(scan.duplicateReclaimableBytes)), \(LocalizationKey.commonItemCount.counted(scan.duplicateGroupsTotal))"
        }
        let totals = scan.categoryTotals.limited(to: filter.categories)
        let bytes = totals.reduce(Int64(0)) { $0 + $1.totalBytes }
        let count = filter == .all
            ? (scan.report?.itemCount ?? 0)
            : totals.reduce(0) { $0 + $1.itemCount }
        let shown = items.count
        let summary = "\(SiftFormat.bytes(bytes)), \(LocalizationKey.commonItemCount.counted(count))"
        guard shown > 0, shown < count else { return summary }
        return summary + " · " + LocalizationKey.commonOf.localized(
            SiftFormat.count(shown),
            SiftFormat.count(count)
        )
    }

    // MARK: - Summary rail

    private var summaryRail: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.scanResultsCleanTitle.localized)
                    .font(SiftFont.eyebrow)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(SiftColor.accent)

                Text(cleanup.formattedSelectedBytes)
                    .font(SiftFont.metricLarge)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(
                    "\(LocalizationKey.commonItemCount.counted(cleanup.selectedCount)), \(LocalizationKey.cleanupConfirmMethodValue.localized)"
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if hiddenSelectedCount > 0 {
                    Text(LocalizationKey.scanHiddenSelected.localized(hiddenSelectedCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.textColor(for: .review))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let actionNotice {
                    NoticeBanner(level: actionNotice.level, message: actionNotice.text)
                }

                if !cleanup.selectedByCategory.isEmpty {
                    Text(
                        LocalizationKey.scanResultsCategoryTotals.localized(
                            cleanup.selectedByCategory
                                .map { "\($0.category.titleKey.localized) \($0.formattedSize)" }
                                .joined(separator: ", ")
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.subtleText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                summaryHint(
                    symbolName: "arrow.uturn.backward.circle",
                    text: LocalizationKey.scanResultsTrashHint.localized
                )
                summaryHint(
                    symbolName: "lock.shield",
                    text: LocalizationKey.scanResultsProtectedHint.localized
                )

                Spacer(minLength: SiftMetrics.spacingXL)

                SiftPrimaryButton(
                    title: LocalizationKey.scanResultsCleanButton.localized(cleanup.selectedCount),
                    isEnabled: cleanup.selectedCount > 0 && !cleanup.isWorking
                ) {
                    Task { await beginCleanup() }
                }
                .accessibilityIdentifier("scan.clean")

                Text(LocalizationKey.scanResultsReportHint.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.subtleText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func summaryHint(symbolName: String, text: String) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SiftColor.subtleText)
                .padding(.top, 2)
            Text(text)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
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
        return "\(session)-\(filter.rawValue)-\(sort.rawValue)-\(cleanup.listGeneration)"
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
        // empty card before the new page arrived.
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
    /// asking the user to approve rows they have never seen. The rail states the
    /// number instead of hiding it.
    private var hiddenSelectedCount: Int {
        let shown = Set(items.map(\.stableRowID))
        let shownPairs = Set(items.map { "\($0.category.rawValue)|\($0.url.path)" })
        return cleanup.selectedItems.filter {
            !shown.contains(CleanupItem.stableID(category: $0.category, url: $0.url))
                && !shownPairs.contains("\($0.category.rawValue)|\($0.url.path)")
        }.count
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

    /// The categories whose totals the chip describes.
    /// Which operation a cleanup started from this filter is.
    var operationName: CleanupOperationName {
        switch self {
        case .large: .largeFiles
        case .old: .oldFiles
        case .duplicates: .duplicateFiles
        case .all, .junk: .junkCleanup
        }
    }

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

    var body: some View {
        let domainItem = item.asCleanupItem()
        HStack(spacing: SiftMetrics.spacingM) {
            SiftCheckbox(
                isOn: Binding(
                    get: { cleanup.isSelected(domainItem) },
                    set: { cleanup.setSelected($0, for: domainItem) }
                ),
                isEnabled: item.risk.isCleanable
            )
            .focused(focus, equals: item.stableRowID)
            .onMoveCommand { direction in onMove(direction, item.stableRowID) }
            .accessibilityLabel(Text(item.displayName))
            .accessibilityHint(Text(item.risk.detailKey.localized))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // One spoken element for the row's identity: name and path
                    // belong together, and the two lines below repeat what this
                    // label already says.
                    .accessibilityLabel(
                        Text("\(item.displayName), \(item.displayPath), \(domainItem.explanation())")
                    )
                Text(itemDetail)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)
                Text(domainItem.explanation())
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.subtleText)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                if let bundleIdentifier = item.relatedBundleID,
                   let onLookUpOwner,
                   item.category == .applicationResidue
                    || item.category == .groupContainerResidue {
                    Button {
                        onLookUpOwner(bundleIdentifier)
                    } label: {
                        Text(LocalizationKey.scanResultsOwnerAction.localized)
                            .font(SiftFont.badge)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                    .help(bundleIdentifier)
                }
            }

            Spacer(minLength: SiftMetrics.spacingS)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(SiftFont.bodyEmphasis)
                    .monospacedDigit()
                if item.fileCount > 1 {
                    Text(LocalizationKey.commonFileCount.counted(item.fileCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            // Part of the row, not revealed by hover. A control that only exists
            // while the pointer is inside the row is a moving target to click,
            // and one hover state per row is one state change per row: on a page
            // holding hundreds of rows that is where the scroll cost was. Every
            // row now lays out the same width, whether or not the pointer is over
            // it.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SiftLinkButtonStyle())
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))

            RiskBadge(risk: item.risk.level)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .contentShape(Rectangle())
        // The same two actions the row offers as buttons, on every row of every
        // group: a path the user can inspect is the cheapest way to judge a row
        // the page cannot judge for them, and it was only reachable from the
        // residue rows before.
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

    private var itemDetail: String {
        "\(item.displayPath), \(item.category.titleKey.localized)"
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
            SiftGlassCard(padding: SiftMetrics.spacingXL) {
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
                        Text(LocalizationKey.scanRunningTarget.localized)
                            .font(SiftFont.eyebrow)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(SiftColor.accent)
                        Text(phase.labelKey.localized)
                            .font(SiftFont.title)
                            .contentTransition(.opacity)
                            .animation(SiftMotion.phase, value: phase)
                        if !shownItemName.isEmpty {
                            Text(LocalizationKey.scanCurrentItem.localized(shownItemName))
                                .font(SiftFont.caption)
                                .contentTransition(.opacity)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, SiftMetrics.spacingM)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                                        .fill(SiftColor.subtleFill)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS + 2, style: .continuous)
                                        .strokeBorder(SiftColor.glassBorder, lineWidth: SiftMetrics.hairline)
                                }
                        }
                        HStack(spacing: SiftMetrics.spacingS) {
                            Text(
                                LocalizationKey.scanRunningWalked.localized(
                                    SiftFormat.count(scan.progress.filesSeen)
                                )
                            )
                            Circle().fill(SiftColor.neutral.opacity(0.4)).frame(width: 3, height: 3)
                            // The found figure is the candidate bytes the item
                            // events actually delivered, not the volume the
                            // walk has looked at — those are different facts.
                            Text(
                                LocalizationKey.scanRunningFound.localized(
                                    SiftFormat.bytes(scan.liveFoundBytes)
                                )
                            )
                            .foregroundStyle(SiftColor.safe)
                        }
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: SiftMetrics.spacingM)

                    VStack(alignment: .trailing, spacing: SiftMetrics.spacingS) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(LocalizationKey.scanRunningElapsed.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(Self.duration(scan.elapsed))
                                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                    .contentTransition(.numericText())
                            }
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(LocalizationKey.scanRunningPhase.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                            Text(phase.labelKey.localized)
                                .font(SiftFont.caption)
                        }
                    }
                }
            }

            SiftGlassCard(padding: SiftMetrics.spacingL) {
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
                        .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, SiftMetrics.spacingM)

                    Divider()

                    ForEach(categories, id: \.self) { category in
                        categoryRow(category)
                        Divider()
                    }

                    HStack(spacing: SiftMetrics.spacingS) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SiftColor.subtleText)
                        Text(LocalizationKey.scanRunningReadOnly.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.subtleText)
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
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)

            // A share of the largest category, not progress: the bar is drawn
            // at a third of the control weight so a nearly full bar cannot be
            // mistaken for "nearly done".
            UsageBar(fraction: fraction, tint: tint.opacity(0.7), height: 4)

            Text(bytes > 0 || phase.hasResults ? SiftFormat.bytes(bytes) : "—")
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)

            Text(
                (phase.hasResults
                    ? LocalizationKey.commonDone
                    : (bytes > 0 ? LocalizationKey.scanRunningFinding : LocalizationKey.scanRunningWaiting)).localized
            )
            .font(SiftFont.badge)
            .foregroundStyle(bytes > 0 ? SiftColor.safe : .secondary)
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

/// The skipped-location list, rolled up by top-level directory.
///
/// A scan that cannot read ~/Library reports two dozen children and the flat
/// list read like noise; the card now shows one row per directory — "~/Library
/// 24 项" — with the location-level detail one click away, because the
/// summary is what the user can act on and the detail is what they audit.
struct SkippedLocationsCard: View {
    let locations: [SkippedLocation]
    @State private var expandedGroups: Set<String> = []

    private var groups: [SkippedLocationGroup] {
        SkippedLocation.groupedByTopLevelDirectory(locations)
    }

    /// "Some locations could not be read" is only true for the reasons a person
    /// can act on. A location the protection list refuses was never unreadable:
    /// saying so sent the user to System Settings for a permission that changes
    /// nothing.
    private var cardTitle: String {
        let needsPermission = locations.contains(where: \.needsFullDiskAccess)
        let allProtected = locations.allSatisfy { $0.code == ErrorCode.protectedLocation.rawValue }
        if allProtected {
            return LocalizationKey.permissionProtectedTitle.localized
        }
        return needsPermission || !allProtected
            ? LocalizationKey.permissionPartialAccess.localized
            : LocalizationKey.scanPhasePartial.localized
    }

    var body: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(cardTitle)
                        .font(SiftFont.sectionTitle)
                    Spacer()
                    if locations.contains(where: \.needsFullDiskAccess) {
                        Button {
                            Task { await WorkspaceActions.openFullDiskAccessSettings() }
                        } label: {
                            Text(LocalizationKey.permissionOpenSettings.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                }
                Divider()
                ForEach(groups) { group in
                    groupSection(group)
                    if group.id != groups.last?.id {
                        Divider()
                    }
                }
            }
        }
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
                        .foregroundStyle(.secondary)
                    Text(group.label)
                        .font(SiftFont.bodyEmphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isExpandable {
                        Text(LocalizationKey.commonItemCount.counted(group.locations.count))
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: SiftMetrics.spacingS)
                    if isExpandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SiftColor.subtleText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isExpandable)
            .accessibilityLabel(Text(group.label))
            .accessibilityHint(Text(isExpandable ? LocalizationKey.overviewShowAll.localized : ""))

            if let reason = group.sharedReasonKey {
                Text(reason.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                ForEach(group.locations) { location in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.displayPath)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if group.sharedReasonKey == nil {
                            Text(location.reasonKey.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.subtleText)
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
