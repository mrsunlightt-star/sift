import Core
import FeatureDashboard
import FeatureFileCleanup
import FeatureJunkCleanup
import FeaturePurchase
import FeatureScan
import FeatureSettings
import FeatureStorageAnalysis
import FeatureUninstaller
import Shared
import SwiftUI

/// `PreferencesSnapshot` and the paywall reason bridge live in the junk cleanup
/// feature, which owns the confirmation panel the shell presents.

/// The window: a sidebar of destinations and the selected page.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: SiftMetrics.sidebarWidth, max: 280)
        } detail: {
            DetailView(destination: router.destination)
        }
        .navigationSplitViewStyle(.balanced)
        .background(SiftColor.windowBackground)
        .environment(\.locale, Locale.current)
    }
}

/// The sidebar: the product identity, the destinations, and the health footer.
struct SidebarView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
                .padding(.horizontal, SiftMetrics.spacingL)
                .padding(.top, SiftMetrics.spacingL)
                .padding(.bottom, SiftMetrics.spacingM)

            Text(LocalizationKey.navWorkbench.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SiftMetrics.spacingL)
                .padding(.bottom, SiftMetrics.spacingXS)

            List(selection: selectionBinding) {
                ForEach(AppDestination.primary) { destination in
                    Label(destination.titleKey.localized, systemImage: destination.symbolName)
                        .tag(destination)
                        .accessibilityLabel(Text(destination.titleKey.localized))
                        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Button {
                    router.go(to: .settings)
                } label: {
                    Label(LocalizationKey.navSettings.localized, systemImage: AppDestination.settings.symbolName)
                        .font(SiftFont.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(router.destination == .settings ? .primary : .secondary)

                if !environment.entitlement.isUnlocked {
                    Button {
                        router.requestPurchase(reason: .cleanJunk)
                    } label: {
                        Label(LocalizationKey.purchaseTitle.localized, systemImage: AppDestination.purchase.symbolName)
                            .font(SiftFont.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(router.destination == .purchase ? .primary : .secondary)
                }

                HealthFooter()
                    .padding(.top, SiftMetrics.spacingS)
            }
            .padding(.horizontal, SiftMetrics.spacingL)
            .padding(.vertical, SiftMetrics.spacingM)
        }
        .background(SiftColor.panel.opacity(0.5))
    }

    private var identity: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                .fill(SiftColor.accent)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizationKey.appName.localized)
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizationKey.appTagline.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Bridges the router's single destination to `List`'s optional selection.
    private var selectionBinding: Binding<AppDestination?> {
        Binding(
            get: { router.destination },
            set: { if let value = $0 { router.go(to: value) } }
        )
    }
}

/// The health footer.
///
/// It shows the disk figure and the words that explain it: §4.1 forbids an
/// unexplained numeric score, so the number is always paired with what it means.
struct HealthFooter: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        let volume = environment.availableVolumes.first { $0.mountPoint.path == "/" }
        SiftPanel(padding: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                HStack {
                    Text(LocalizationKey.dashboardHealth.localized)
                        .font(SiftFont.caption)
                    Spacer()
                    Text(healthLabel(volume).localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(healthTint(volume))
                }
                UsageBar(fraction: volume?.usedFraction ?? 0, tint: healthTint(volume), height: 6)
                if let volume {
                    Text(LocalizationKey.dashboardHealthExplain.localized(volume.formattedUsage))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            Text(LocalizationKey.dashboardHealthExplain.localized(volume.formattedUsage))
                        )
                }
            }
        }
    }

    private func healthLabel(_ volume: VolumeInfo?) -> LocalizationKey {
        guard let volume else { return .dashboardHealthGood }
        return volume.usedFraction > 0.9 ? .dashboardHealthReview : .dashboardHealthGood
    }

    private func healthTint(_ volume: VolumeInfo?) -> Color {
        guard let volume else { return SiftColor.neutral }
        switch volume.usedFraction {
        case ..<0.8: return SiftColor.safe
        case ..<0.92: return SiftColor.review
        default: return SiftColor.danger
        }
    }
}

/// Routes the sidebar selection to the feature's root view.
///
/// Each feature receives a navigation closure rather than a router, so a feature
/// can ask the shell to move without knowing what the shell is.
struct DetailView: View {
    let destination: AppDestination
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var preferences = PreferencesSnapshot()

    var body: some View {
        Group {
            switch destination {
            case .dashboard:
                DashboardView { link in
                    router.go(to: link.appDestination)
                }
            case .smartScan:
                SmartScanView { router.requestPurchase(reason: .cleanJunk) }
            case .junkCleanup:
                JunkCleanupView { router.requestPurchase(reason: .cleanJunk) }
            case .uninstaller:
                UninstallerView { router.requestPurchase(reason: .uninstall) }
            case .fileCleanup:
                FileCleanupView { router.requestPurchase(reason: .cleanFiles) }
            case .storageAnalysis:
                StorageAnalysisView()
            case .settings:
                SettingsView()
            case .purchase:
                PurchaseView(reason: router.paywallReason?.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SiftColor.windowBackground)
        .overlay(alignment: .bottom) {
            // The confirmation panel is presented from the shell so it appears
            // above whichever page started the cleanup.
            if environment.cleanup.isConfirming {
                CleanupConfirmationView(
                    cleanup: environment.cleanup,
                    preferences: preferences,
                    onConfirm: {
                        Task {
                            await environment.cleanup.confirmCleanup()
                            RecentHistoryBridge.record(environment.cleanup.outcome)
                        }
                    },
                    onCancel: { environment.cleanup.isConfirming = false },
                    onToggleSkipConfirmation: { value in
                        Task { await environment.updateSettings { $0.skipConfirmation = value } }
                    }
                )
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous))
                .shadow(radius: 24, y: 8)
                .padding(SiftMetrics.spacingXL)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: environment.preferences) {
            preferences.skipConfirmation = environment.preferences.skipConfirmation
            preferences.requireConfirmation = environment.preferences.requireConfirmation
        }
    }
}

/// Bridges the dashboard's destination enum to the app's router, keeping the
/// feature free of a dependency on the shell.
extension AppDestinationLink {
    var appDestination: AppDestination {
        switch self {
        case .dashboard: .dashboard
        case .smartScan: .smartScan
        case .junkCleanup: .junkCleanup
        case .uninstaller: .uninstaller
        case .fileCleanup: .fileCleanup
        case .storageAnalysis: .storageAnalysis
        case .settings: .settings
        case .purchase: .purchase
        }
    }
}

extension PaywallReason {
    var link: PaywallReasonLink {
        switch self {
        case .cleanJunk: .cleanJunk
        case .uninstall: .uninstall
        case .cleanFiles: .cleanFiles
        case .exportReport: .exportReport
        }
    }
}

/// Records a finished cleanup in the dashboard's local history.
enum RecentHistoryBridge {
    static func record(_ outcome: CleanupOutcome?) {
        guard let outcome else { return }
        RecentHistory.recordCleanup(outcome)
    }
}
