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
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .scanTitle) {
                    if environment.scan.hasResults {
                        Text(environment.scan.formattedReclaimable)
                            .font(SiftFont.metric)
                            .foregroundStyle(SiftColor.accent)
                    }
                }

                if environment.scan.phase == .idle {
                    StartScanCard {
                        Task { await startScan() }
                    }
                } else {
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
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .task {
            if environment.scan.hasResults {
                await environment.scan.loadDuplicateGroups()
            }
        }
    }

    private func startScan() async {
        environment.cleanup.resetForNewScan()
        let request = await environment.makeScanRequest()
        await environment.scan.start(request)
        await environment.scan.loadDuplicateGroups()
        // Load the first page into the cleanup model so the selection bar has
        // something to count before the user expands a category.
        let page = await environment.scan.page(offset: 0, limit: 200, sort: .size, category: nil)
        environment.cleanup.setItems(page.items.map { $0.asCleanupItem() })
    }
}

/// The idle state: the primary action with the explanation of what it does.
struct StartScanCard: View {
    let onStart: () -> Void

    var body: some View {
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
                PrimaryActionButton(titleKey: .dashboardStartScan, symbolName: "viewfinder") {
                    onStart()
                }
                .padding(.top, SiftMetrics.spacingXS)
            }
        }
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
