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
///
/// Public because the app entry point lives in a different target: the entry file
/// is shared between the SwiftPM executable and the Xcode app target.
public struct RootShellView: View {
    public init() {}

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: SiftMetrics.sidebarWidth, max: 280)
        } detail: {
            DetailView(destination: router.destination)
        }
        .navigationSplitViewStyle(.balanced)
        .background(SiftColor.windowBackground)
        .environment(\.locale, environment.preferences.language.locale)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                LanguageSwitcher()
            }
        }
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
                .accessibilityIdentifier("sidebar.settings")

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


/// Always-visible language control in the window toolbar. Language names are
/// shown in their native writing systems so the control is understandable before
/// the user can read the rest of the interface.
struct LanguageSwitcher: View {
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View {
        Menu {
            ForEach(SiftLanguage.allCases) { language in
                Button {
                    select(language)
                } label: {
                    HStack {
                        Text(language.displayName)
                        if environment.preferences.language == language {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier("language.\\(language.rawValue)")
            }
        } label: {
            Label(environment.preferences.language.shortName, systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .help(LocalizationKey.settingsGroupLanguage.localized)
        .accessibilityLabel(LocalizationKey.settingsGroupLanguage.localized)
        .accessibilityIdentifier("toolbar.language")
    }

    private func select(_ language: SiftLanguage) {
        // Publish the choice synchronously for string lookup; SettingsStore then
        // persists it through the normal preferences pipeline.
        UserDefaults.standard.set(language.rawValue, forKey: "settings.language")
        Task {
            await environment.updateSettings { $0.language = language }
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
                DashboardView()
            case .smartScan:
                SmartScanView { router.requestPurchase(reason: .cleanJunk) }
            case .junkCleanup:
                JunkCleanupView { router.requestPurchase(reason: .cleanJunk) }
            case .uninstaller:
                UninstallerView { router.requestPurchase(reason: .uninstall) }
            case .fileCleanup:
                FileCleanupView(
                    onRequestPurchase: { router.requestPurchase(reason: .cleanFiles) },
                    onManageScope: { router.go(to: .settings) }
                )
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
        .overlay(alignment: .top) {
            // The result page is presented from the shell so it appears whichever
            // page started the cleanup, and stays until the user dismisses it.
            if let outcome = environment.cleanup.outcome {
                ScrollView {
                    CleanupResultView(
                        outcome: outcome,
                        report: environment.cleanup.report,
                        onAcknowledge: {
                            environment.cleanup.acknowledgeOutcome()
                            environment.clearReportExportMessage()
                        },
                        onExport: {
                            Task {
                                guard await environment.canExportReports() else {
                                    environment.cleanup.acknowledgeOutcome()
                                    router.requestPurchase(reason: .exportReport)
                                    return
                                }
                                if let report = environment.cleanup.report {
                                    await environment.exportReport(report)
                                }
                            }
                        },
                        onOpenTrash: { Task { await environment.openTrash() } },
                        onRevealFailed: { url in Task { await environment.reveal(url) } },
                        onRequestPurchase: { router.requestPurchase(reason: .exportReport) },
                        statusMessage: environment.reportExportMessage
                    )
                    .background(SiftColor.windowBackground)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous))
                .shadow(radius: 20, y: 6)
                .padding(SiftMetrics.spacingXL)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            // The confirmation panel is presented from the shell so it appears
            // above whichever page started the cleanup.
            if environment.cleanup.isConfirming {
                CleanupConfirmationView(
                    cleanup: environment.cleanup,
                    preferences: preferences,
                    onConfirm: {
                        Task {
                            await environment.cleanup.confirmCleanup(
                                scanReport: environment.scan.report
                            )
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
