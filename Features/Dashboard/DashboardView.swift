import Core
import Shared
import SwiftUI

/// The overview page (§4.1).
///
/// Every number on it is explainable: disk usage is a percentage of a named
/// volume, "can be cleaned" comes from an actual scan, and there is no composite
/// health score. The health figure is the disk line, with the words that say so.
public struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var lastOutcome: CleanupOutcome?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .dashboardTitle, subtitle: greeting) {
                    EmptyView()
                }

                HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                    scanCard
                    diskCard
                }

                statRow
                suggestionRow

                if let outcome = lastOutcome {
                    RecentActivityCard(outcome: outcome)
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 1000, alignment: .leading)
            // Keep a readable column, centred in the available detail area.
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { lastOutcome = RecentHistory.lastOutcome() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let key: LocalizationKey
        switch hour {
        case ..<12: key = .dashboardGreetingMorning
        case ..<18: key = .dashboardGreetingAfternoon
        default: key = .dashboardGreetingEvening
        }
        return Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
            + " · " + key.localized
    }

    private var scanCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Label {
                    Text(LocalizationKey.navSmartScan.localized)
                        .font(SiftFont.bodyEmphasis)
                        .foregroundStyle(SiftColor.accent)
                } icon: {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(SiftColor.accent)
                }
                Text(LocalizationKey.dashboardScanCardTitle.localized)
                    .font(SiftFont.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizationKey.dashboardScanCardSubtitle.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SiftMetrics.spacingM) {
                    PrimaryActionButton(titleKey: .dashboardStartScan, symbolName: "viewfinder") {
                        Task { await environment.runScan(.everything) }
                    }
                    .disabled(environment.scan.isRunning)
                    if environment.scan.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, SiftMetrics.spacingXS)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var diskCard: some View {
        let volume = environment.availableVolumes.first { $0.mountPoint.path == "/" }
        return SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume?.formattedUsage ?? "—")
                        .font(SiftFont.metricLarge)
                    Spacer()
                    Text(volume?.name ?? LocalizationKey.commonNotAvailable.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(LocalizationKey.dashboardDiskUsed.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                UsageBar(
                    fraction: volume?.usedFraction ?? 0,
                    tint: (volume?.usedFraction ?? 0) > 0.9 ? SiftColor.review : SiftColor.safe,
                    height: 10
                )
                if let volume {
                    Text(LocalizationKey.dashboardDiskFree.localized(volume.formattedFree))
                        .font(SiftFont.bodyEmphasis)
                }
                Text(LocalizationKey.dashboardHealthExplain.localized(volume?.formattedUsage ?? "—"))
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 320)
    }

    private var statRow: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            StatTile(
                title: .dashboardCleanable,
                value: environment.scan.hasResults ? environment.scan.formattedReclaimable : "—",
                caption: lastScanCaption,
                symbolName: "trash",
                tint: SiftColor.accent
            )
            StatTile(
                title: .dashboardUninstallable,
                value: environment.installedApplications.isEmpty ? "—" : "\(removableAppCount)",
                caption: LocalizationKey.dashboardLargeFilesDetail.localized("1 GB"),
                symbolName: "shippingbox",
                tint: SiftColor.review
            )
            StatTile(
                title: .dashboardLargeFiles,
                value: largeFilesTotal,
                caption: LocalizationKey.dashboardLargeFilesDetail.localized("1 GB"),
                symbolName: "doc.zipper",
                tint: SiftColor.categoryPalette[5]
            )
        }
        .task { await environment.loadApplications() }
    }

    private var lastScanCaption: String {
        guard let report = environment.scan.report else {
            guard let stored = RecentHistory.lastScanDate() else {
                return LocalizationKey.dashboardNeverScanned.localized
            }
            return LocalizationKey.dashboardLastScan.localized(SiftFormat.relativeDate(stored))
        }
        let date = report.finishedAt ?? report.startedAt
        return LocalizationKey.dashboardLastScan.localized(SiftFormat.relativeDate(date))
    }

    private var removableAppCount: Int {
        environment.installedApplications.filter { !$0.isSystemApplication }.count
    }

    private var largeFilesTotal: String {
        let total = environment.scan.categoryTotals
            .filter { $0.category == .largeFiles }
            .reduce(0) { $0 + $1.totalBytes }
        return total > 0 ? SiftFormat.bytes(total) : "—"
    }

    private var suggestionRow: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.dashboardSuggestedCleanup.localized)
                    .font(SiftFont.sectionTitle)
                if environment.scan.categoryTotals.isEmpty {
                    Text(LocalizationKey.scanNothingFoundDetail.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(environment.scan.categoryTotals.prefix(4)) { total in
                        BreakdownBar(
                            label: total.category.titleKey.localized,
                            value: total.formattedSize,
                            fraction: fraction(for: total),
                            tint: SiftColor.categoryPalette[total.category.paletteIndex]
                        )
                    }
                }
            }
        }
    }

    private func fraction(for total: CategoryTotal) -> Double {
        let largest = environment.scan.categoryTotals.map(\.totalBytes).max() ?? 1
        guard largest > 0 else { return 0 }
        return Double(total.totalBytes) / Double(largest)
    }

}

/// The last cleanup's summary, read back from local history.
struct RecentActivityCard: View {
    let outcome: CleanupOutcome

    var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.dashboardRecentActivity.localized)
                    .font(SiftFont.sectionTitle)
                Divider()
                HStack(spacing: SiftMetrics.spacingM) {
                    IconTile(symbolName: "checkmark.circle.fill", tint: SiftColor.safe)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.dashboardCleanupCompleted.localized)
                            .font(SiftFont.bodyEmphasis)
                        Text(LocalizationKey.cleanupResultMoved.localized(outcome.movedCount))
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(outcome.formattedReleased)
                        .font(SiftFont.metric)
                        .foregroundStyle(SiftColor.safe)
                }
            }
        }
    }
}
