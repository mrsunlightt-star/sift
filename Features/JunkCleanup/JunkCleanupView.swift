import Core
import Shared
import SwiftUI

/// The junk cleanup page: the scan results filtered to the four junk categories,
/// with the same selection and confirmation flow as the smart scan (§5.2).
///
/// It shares `ScanModel` and `CleanupModel` with the scan page on purpose: the
/// safety rules live in one place, so a user cannot reach a weaker confirmation
/// panel by choosing a different entry point.
public struct JunkCleanupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    @State private var categoryFilter: CleanupCategory?

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .navJunkCleanup) {
                    if environment.scan.hasResults {
                        Text(environment.scan.formattedReclaimable)
                            .font(SiftFont.metric)
                            .foregroundStyle(SiftColor.accent)
                    }
                }

                if !environment.scan.hasResults {
                    ScanGateCard(
                        titleKey: .navJunkCleanup,
                        detailKey: .cleanupConfirmUndoNotice,
                        onStart: { Task { await startScan() } }
                    )
                } else {
                    CategoryFilterBar(
                        categories: CleanupCategory.junkCategories,
                        totals: environment.scan.categoryTotals.limited(to: CleanupCategory.junkCategories),
                        selection: $categoryFilter
                    )
                    SelectionBar(
                        cleanup: environment.cleanup,
                        environment: environment,
                        operation: .junkCleanup,
                        onRequestPurchase: onRequestPurchase
                    )
                    ScanResultsView(
                        scan: environment.scan,
                        cleanup: environment.cleanup,
                        categories: CleanupCategory.junkCategories
                    )
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func startScan() async {
        await environment.runScan(.junk)
    }
}

/// Category chips that scroll the result list to one category.
struct CategoryFilterBar: View {
    let categories: [CleanupCategory]
    let totals: [CategoryTotal]
    @Binding var selection: CleanupCategory?

    var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            chip(label: LocalizationKey.scanSelectAll.localized, isSelected: selection == nil) {
                selection = nil
            }
            ForEach(categories) { category in
                if let total = totals.first(where: { $0.category == category }) {
                    chip(
                        label: "\(category.titleKey.localized) · \(total.formattedSize)",
                        isSelected: selection == category
                    ) {
                        selection = selection == category ? nil : category
                    }
                }
            }
            Spacer()
        }
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(SiftFont.caption)
                .padding(.horizontal, SiftMetrics.spacingM)
                .padding(.vertical, 5)
                .background(isSelected ? SiftColor.accent.opacity(0.16) : SiftColor.panel)
                .foregroundStyle(isSelected ? SiftColor.accent : Color.primary)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(isSelected ? SiftColor.accent.opacity(0.5) : SiftColor.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
