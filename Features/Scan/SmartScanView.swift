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

            if scan.hasResults {
                filterBar
                resultsWorkspace
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
        .task(id: scan.hasResults) {
            if scan.hasResults {
                await scan.loadDuplicateGroups()
            }
        }
    }

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
                    VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                        Color.clear
                            .frame(height: 1)
                            .accessibilityHidden(true)
                            .id(Self.listTopID)
                        failureBanners
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
                            if !scan.duplicateGroups.isEmpty {
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
        if scan.phase == .cancelled || scan.phase == .failed {
            return scan.phase.labelKey.localized
        }
        if let report = scan.report {
            return LocalizationKey.scanHeaderStatus.localized(
                SiftFormat.relativeDate(report.finishedAt ?? report.startedAt),
                report.itemCount
            )
        }
        return LocalizationKey.scanHeaderStatusEmpty.localized
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
        } else if scan.hasResults {
            SiftPrimaryButton(titleKey: .scanRescan, symbolName: "arrow.clockwise") {
                Task { await environment.runScan(.everything) }
            }
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
            return LocalizationKey.commonItemCount.localized(scan.report?.itemCount ?? 0)
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
                        HStack(spacing: SiftMetrics.spacingM) {
                            SiftPrimaryButton(
                                titleKey: .dashboardStartScan,
                                symbolName: "viewfinder",
                                isEnabled: !isBusy
                            ) {
                                Task { await environment.runScan(.everything) }
                            }
                            .accessibilityIdentifier("scan.start")
                            Text(LocalizationKey.overviewLocalOnly.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.tertiary)
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
                    SiftEmptyState(
                        symbolName: "checkmark.circle",
                        titleKey: .scanNothingFound,
                        detailKey: .scanNothingFoundDetail
                    )
                } else {
                    resultGroups
                }

                Divider()
                resultsFooter
            }
        }
    }

    @ViewBuilder
    private var resultGroups: some View {
        let safe = visible(groupItems(.safe))
        let review = visible(groupItems(.review))
        let protected = visible(groupItems(.protected))

        if !safe.isEmpty {
            groupHeader(
                LocalizationKey.scanResultsSafeGroup.localized,
                count: groupItems(.safe).count,
                detail: LocalizationKey.scanResultsDefaultSelected.localized,
                tint: SiftColor.safe
            )
            ForEach(safe, id: \.stableRowID) { item in
                ScanItemRow(item: item, cleanup: cleanup)
                Divider()
            }
        }

        if !review.isEmpty {
            groupHeader(
                LocalizationKey.scanResultsReviewGroup.localized,
                count: groupItems(.review).count,
                detail: LocalizationKey.scanResultsReviewHint.localized,
                tint: SiftColor.review
            )
            ForEach(review, id: \.stableRowID) { item in
                ScanItemRow(item: item, cleanup: cleanup)
                Divider()
            }
        }

        if !protected.isEmpty {
            groupHeader(
                LocalizationKey.scanResultsProtectedGroup.localized,
                count: groupItems(.protected).count,
                detail: RiskLevel.protected.detailKey.localized,
                tint: SiftColor.danger
            )
            ForEach(protected, id: \.stableRowID) { item in
                ScanItemRow(item: item, cleanup: cleanup)
                Divider()
            }
        }

        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SiftMetrics.spacingM)
        } else if hiddenItemCount > 0 {
            HStack(spacing: SiftMetrics.spacingM) {
                Text(
                    LocalizationKey.overviewMoreItems.localized(
                        hiddenItemCount,
                        SiftFormat.bytes(hiddenBytes)
                    )
                )
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

    private func groupHeader(_ title: String, count: Int, detail: String, tint: Color) -> some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(title)
                .font(SiftFont.bodyEmphasis)
            Text(LocalizationKey.commonItemCount.localized(count))
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: SiftMetrics.spacingS)
            Text(detail)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
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
                cleanup.selectAll(in: cleanup.items.filter { $0.risk.isCleanable })
            } label: {
                Text(LocalizationKey.scanSelectAll.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())

            Button {
                cleanup.deselectAll()
            } label: {
                Text(LocalizationKey.scanDeselectAll.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
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
                    .strokeBorder(SiftColor.glassBorder, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var resultSummary: String {
        if filter == .duplicates {
            return "\(SiftFormat.bytes(scan.duplicateReclaimableBytes)) · \(LocalizationKey.commonItemCount.localized(scan.duplicateGroupsTotal))"
        }
        let totals = scan.categoryTotals.limited(to: filter.categories)
        let bytes = totals.reduce(Int64(0)) { $0 + $1.totalBytes }
        let count = filter == .all
            ? (scan.report?.itemCount ?? 0)
            : totals.reduce(0) { $0 + $1.itemCount }
        return "\(SiftFormat.bytes(bytes)) · \(LocalizationKey.commonItemCount.localized(count))"
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
                    "\(LocalizationKey.commonItemCount.localized(cleanup.selectedCount)) · \(LocalizationKey.cleanupConfirmMethodValue.localized)"
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !cleanup.selectedByCategory.isEmpty {
                    Text(
                        LocalizationKey.scanResultsCategoryTotals.localized(
                            cleanup.selectedByCategory
                                .map { "\($0.category.titleKey.localized) \($0.formattedSize)" }
                                .joined(separator: " · ")
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Text(text)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Loading

    private var reloadKey: String {
        let session = scan.report?.sessionID ?? "none"
        return "\(session)-\(filter.rawValue)-\(sort.rawValue)"
    }

    private func reload() async {
        guard scan.hasResults else {
            items = []
            cursors = [:]
            hasMore = false
            showsAllRows = false
            return
        }
        isLoading = true
        showsAllRows = false
        defer { isLoading = false }

        items = []
        cursors = [:]
        // A previous filter may have had more pages. Leaving the old value set
        // showed "Load more" on a filter that had already loaded everything.
        hasMore = false
        let expectedKey = reloadKey

        for category in filter.rowCategories {
            let page = await scan.page(offset: 0, limit: pageSize, sort: sort, category: category)
            guard reloadKey == expectedKey else { return }
            items.append(contentsOf: page.items)
            cursors[category] = page.items.count
            if page.remaining > 0 { hasMore = true }
        }

        items = deduplicated(items).sorted(by: sortComparator)
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

    private var visibleRowCount: Int {
        if showsAllRows { return items.count }
        return [CleanupRisk.safe, .review, .protected]
            .reduce(0) { total, risk in
                total + min(groupItems(risk).count, collapsedRowsPerGroup)
            }
    }

    private var hiddenItemCount: Int {
        max(items.count - visibleRowCount, 0)
    }

    private var hiddenBytes: Int64 {
        let shownIDs = Set(
            [CleanupRisk.safe, .review, .protected].flatMap { visible(groupItems($0)).map(\.stableRowID) }
        )
        return items.filter { !shownIDs.contains($0.stableRowID) }.reduce(0) { $0 + $1.sizeInBytes }
    }

    private func beginCleanup() async {
        let result = await environment.beginCleanup(
            operation: .smartScan,
            requiresConfirmation: environment.preferences.showsConfirmationPanel,
            scanReport: environment.scan.report
        )
        if case .purchaseRequired = result {
            onRequestPurchase()
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
            .accessibilityLabel(Text(item.displayName))
            .accessibilityHint(Text(item.risk.detailKey.localized))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(itemDetail)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(domainItem.explanation())
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(SiftFont.bodyEmphasis)
                    .monospacedDigit()
                if item.fileCount > 1 {
                    Text(LocalizationKey.commonFileCount.localized(item.fileCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RiskBadge(risk: item.risk.level)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .contentShape(Rectangle())
    }

    private var itemDetail: String {
        "\(item.displayPath) · \(item.category.titleKey.localized)"
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

    init(scan: ScanModel, displayPhase: ScanPhase? = nil, onOpenPermissions: @escaping () -> Void) {
        self.scan = scan
        self.displayPhase = displayPhase
        self.onOpenPermissions = onOpenPermissions
    }

    /// The phase the card shows. While the request is being assembled the engine
    /// has no phase of its own, so the page passes `.preparing` in rather than
    /// claiming the run has already started.
    private var phase: ScanPhase { displayPhase ?? scan.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            SiftGlassCard(padding: SiftMetrics.spacingXL) {
                HStack(spacing: SiftMetrics.spacingXL) {
                    SiftProgressRing(
                        progress: nil,
                        lineWidth: 9,
                        label: "\(phase.step ?? 0)/\(ScanPhase.stepCount)",
                        caption: LocalizationKey.navScan.localized
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
                        if !scan.progress.currentItemName.isEmpty {
                            Text(scan.progress.currentItemName)
                                .font(SiftFont.caption)
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
                                        .strokeBorder(SiftColor.glassBorder, lineWidth: 1)
                                }
                        }
                        HStack(spacing: SiftMetrics.spacingS) {
                            Text(
                                LocalizationKey.scanRunningWalked.localized(
                                    SiftFormat.count(scan.progress.filesSeen)
                                )
                            )
                            Circle().fill(SiftColor.neutral.opacity(0.4)).frame(width: 3, height: 3)
                            Text(
                                LocalizationKey.scanRunningFound.localized(
                                    SiftFormat.bytes(scan.progress.bytesSeen)
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
                            Text(
                                LocalizationKey.scanRunningStep.localized(
                                    phase.step ?? 0,
                                    ScanPhase.stepCount
                                )
                            )
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
                            .foregroundStyle(.tertiary)
                        Text(LocalizationKey.scanRunningReadOnly.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.tertiary)
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
    }

    private var categories: [CleanupCategory] {
        CleanupCategory.junkCategories + [.largeFiles, .oldFiles]
    }

    private func liveBytes(_ category: CleanupCategory) -> Int64 {
        if let total = scan.categoryTotals.first(where: { $0.category == category }) {
            return total.totalBytes
        }
        return scan.recentItems
            .filter { $0.category == category }
            .reduce(0) { $0 + $1.sizeInBytes }
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

            UsageBar(fraction: fraction, tint: tint, height: 6)

            Text(SiftFormat.bytes(bytes))
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

/// The skipped-location list, with the reason and the fix for each entry.
struct SkippedLocationsCard: View {
    let locations: [SkippedLocation]

    var body: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(LocalizationKey.permissionPartialAccess.localized)
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
                ForEach(locations) { location in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.displayPath)
                            .font(SiftFont.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(location.reasonKey.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
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
