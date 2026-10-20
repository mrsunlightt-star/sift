import Shared
import SwiftUI

/// Results grouped by category, with per-group counts, sizes, risk and a link to
/// the details (§11.2).
///
/// The list is paged from the scanner's index rather than held in memory, so a
/// scan that found 40,000 items still renders immediately.
public struct ScanResultsView: View {
    @ObservedObject private var scan: ScanModel
    @ObservedObject private var cleanup: CleanupModel
    @State private var expandedCategory: CleanupCategory?
    @State private var page: [CleanupItemSummary] = []
    @State private var isLoading = false
    @State private var hasMore = false

    private let pageSize = 200
    /// The categories this page owns, or `nil` for all of them.
    private let categories: [CleanupCategory]?

    public init(scan: ScanModel, cleanup: CleanupModel, categories: [CleanupCategory]? = nil) {
        self.scan = scan
        self.cleanup = cleanup
        self.categories = categories
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            summaryHeader
            let totals = scan.categoryTotals.limited(to: categories)
            if totals.isEmpty {
                SiftEmptyState(
                    symbolName: "checkmark.circle",
                    titleKey: .scanNothingFound,
                    detailKey: .scanNothingFoundDetail
                )
            } else {
                ForEach(totals) { total in
                    CategoryGroupCard(
                        total: total,
                        isExpanded: expandedCategory == total.category,
                        items: expandedCategory == total.category ? page : [],
                        isLoading: isLoading && expandedCategory == total.category,
                        hasMore: hasMore,
                        cleanup: cleanup,
                        onToggle: { Task { await toggle(total.category) } },
                        onLoadMore: { Task { await loadMore(for: total.category) } }
                    )
                }
            }
            // Duplicate groups are a category of their own: a page that does not
            // own duplicate files must not show them.
            if !scan.duplicateGroups.isEmpty,
               categories?.contains(.duplicateFiles) ?? true {
                DuplicateGroupsCard(groups: scan.duplicateGroups, scan: scan, cleanup: cleanup)
            }
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizationKey.scanResults.localized)
                    .font(SiftFont.sectionTitle)
                Text(
                    "\(LocalizationKey.scanCheckedFiles.localized(SiftFormat.count(scan.progress.filesSeen))) · \(LocalizationKey.scanItemsFound.localized(SiftFormat.count(scan.progress.itemsFound)))"
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !scan.duplicateGroups.isEmpty, categories?.contains(.duplicateFiles) ?? true {
                Text(
                    LocalizationKey.scanDuplicatesFound
                        .localized(scan.duplicateGroups.count)
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func toggle(_ category: CleanupCategory) async {
        if expandedCategory == category {
            expandedCategory = nil
            return
        }
        expandedCategory = category
        page = []
        await loadMore(for: category)
    }

    private func loadMore(for category: CleanupCategory) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let next = await scan.page(offset: page.count, limit: pageSize, sort: .size, category: category)
        page.append(contentsOf: next.items)
        hasMore = next.remaining > 0
        cleanup.appendItems(next.items.map { $0.asCleanupItem() })
    }
}

/// One category: header, totals, risk summary and its paged item rows.
struct CategoryGroupCard: View {
    let total: CategoryTotal
    let isExpanded: Bool
    let items: [CleanupItemSummary]
    let isLoading: Bool
    let hasMore: Bool
    @ObservedObject var cleanup: CleanupModel
    let onToggle: () -> Void
    let onLoadMore: () -> Void

    var body: some View {
        SiftPanel(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Button(action: onToggle) {
                    HStack(spacing: SiftMetrics.spacingM) {
                        IconTile(
                            symbolName: total.category.symbolName,
                            tint: SiftColor.categoryPalette[total.category.paletteIndex]
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(total.category.titleKey.localized)
                                .font(SiftFont.sectionTitle)
                            Text(
                                "\(LocalizationKey.scanGroupCount.localized(SiftFormat.count(total.itemCount))) · \(total.formattedSize)"
                            )
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: SiftMetrics.spacingS)
                        RiskBadge(risk: riskForCategory)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(total.category.titleKey.localized))
                .accessibilityValue(Text("\(SiftFormat.count(total.itemCount)) · \(total.formattedSize)"))

                if isExpanded {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            ItemRow(item: item, cleanup: cleanup)
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else if hasMore {
                        Button {
                            onLoadMore()
                        } label: {
                            Text(LocalizationKey.scanReviewDetails.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                    if items.isEmpty, !isLoading {
                        Text(LocalizationKey.commonEmptyFolder.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The most cautious risk in the group, so a category holding anything the
    /// user must review is labelled that way at the group level too.
    private var riskForCategory: RiskLevel {
        let levels = items.map(\.risk.level)
        if levels.contains(.protected) { return .protected }
        if levels.contains(.review) { return .review }
        switch total.category {
        case .applicationCache, .logs, .temporaryFiles: return .safe
        default: return .review
        }
    }
}

/// One result row: checkbox, name, path, size, risk and the "why" text.
struct ItemRow: View {
    let item: CleanupItemSummary
    @ObservedObject var cleanup: CleanupModel
    @State private var isRevealing = false

    var body: some View {
        let domainItem = item.asCleanupItem()
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            Toggle(
                isOn: Binding(
                    get: { cleanup.isSelected(domainItem) },
                    set: { cleanup.setSelected($0, for: domainItem) }
                )
            ) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!item.risk.isCleanable)
            .help(item.risk.isCleanable ? "" : LocalizationKey.riskProtectedDetail.localized)
            .accessibilityLabel(Text(item.displayName))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SiftMetrics.spacingS) {
                    Text(item.displayName)
                        .font(SiftFont.bodyEmphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    RiskBadge(risk: item.risk.level)
                }
                Text(item.displayPath)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(domainItem.explanation())
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(SiftFont.monospacedNumber)
                if item.fileCount > 1 {
                    Text(LocalizationKey.commonFileCount.localized(item.fileCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isRevealing = true
                Task {
                    await WorkspaceActions.reveal(item.url)
                    isRevealing = false
                }
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .contentShape(Rectangle())
    }
}
