import Core
import Shared
import SwiftUI

/// The smart scan page: one button, then honest progress, then results.
public struct SmartScanView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Called when a free user asks for a cleanup, so the shell can open the
    /// purchase page naming the action.
    private let onRequestPurchase: () -> Void

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        SiftPage(maxWidth: SiftMetrics.contentWidthStandard) {
            PageHeader(titleKey: .scanTitle, eyebrowKey: .navWorkbench) {
                if environment.scan.hasResults {
                    SiftMetricPill(
                        symbolName: "leaf.fill",
                        value: environment.scan.formattedReclaimable
                    )
                }
            }

            // Offered whenever a scan is not running and left no results to
            // act on — cancelled and failed included, not just a first run.
            // The other pages already show their gate card on `!hasResults`;
            // gating on `.idle` alone left "cancelled" as a dead end with no
            // way to start again.
            if !environment.scan.hasResults, !environment.scan.isRunning {
                SiftHeroCard(
                    symbolName: "wand.and.sparkles",
                    title: LocalizationKey.dashboardScanCardTitle.localized,
                    detail: LocalizationKey.dashboardScanCardSubtitle.localized,
                    tint: SiftColor.accent
                ) {
                    PrimaryActionButton(titleKey: .dashboardStartScan, symbolName: "viewfinder") {
                        Task { await startScan() }
                    }
                }

                ScanCategoryPreview(Self.scanCategories)
            } else if environment.scan.isRunning || !environment.scan.hasResults {
                ScanProgressPanel(model: environment.scan)
            }

            if let failure = environment.scan.failure {
                NoticeBanner(
                    level: .error,
                    message: failure.message,
                    actionTitle: failure.code.suggestedAction?.titleKey,
                    action: failure.code.suggestedAction == .openSystemSettings
                        ? { Task { await environment.openPermissionSettings() } }
                        : nil
                )
            }

            if environment.scan.hasResults {
                SelectionBar(
                    cleanup: environment.cleanup,
                    environment: environment,
                    operation: .smartScan,
                    onRequestPurchase: onRequestPurchase
                )
                ScanResultsView(scan: environment.scan, cleanup: environment.cleanup)
            }

            if !environment.scan.skippedLocations.isEmpty {
                SkippedLocationsCard(locations: environment.scan.skippedLocations)
            }
        }
        .task {
            if environment.scan.hasResults {
                await environment.scan.loadDuplicateGroups()
            }
        }
    }

    /// What a smart scan can find. Naming the categories before the first run
    /// sets the expectation, and the same names are the result groups.
    private static let scanCategories: [CleanupCategory] = [
        .applicationCache, .logs, .installers, .temporaryFiles,
        .largeFiles, .oldFiles, .duplicateFiles,
    ]

    private func startScan() async {
        await environment.runScan(.everything)
    }
}

/// The skipped-location list, with the reason and the fix for each entry.
struct SkippedLocationsCard: View {
    let locations: [SkippedLocation]

    var body: some View {
        SiftPanel {
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
                        .buttonStyle(.link)
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
