import Core
import FeatureDashboard
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

/// The window: an icon rail and the selected page, over the shared canvas.
///
/// The redesign replaces the system sidebar with a narrow rail. It carries the
/// four destinations a user goes to, the language control and settings; category
/// filters moved into the scan page, which is where they belong.
public struct RootShellView: View {
    public init() {}

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public var body: some View {
        ZStack {
            SiftCanvasBackground()

            HStack(spacing: 0) {
                IconRailView()
                DetailView(destination: router.destination)
            }

            presentationLayer
        }
        .environment(\.locale, environment.preferences.language.locale)
        .environment(
            \.siftReduceMotion,
            accessibilityReduceMotion || environment.preferences.reduceMotion
        )
        .preferredColorScheme(preferredColorScheme)
        .tint(SiftColor.accent)
        .animation(reduceMotion ? nil : SiftMotion.panel, value: environment.cleanup.outcome != nil)
        .animation(reduceMotion ? nil : SiftMotion.panel, value: environment.cleanup.isConfirming)
    }

    private var reduceMotion: Bool {
        accessibilityReduceMotion || environment.preferences.reduceMotion
    }

    private var preferredColorScheme: ColorScheme? {
        switch environment.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The result and the confirmation panel are presented by the shell, so they
    /// appear above whichever page started the operation. A dimmed backdrop makes
    /// them the only thing that can be clicked while they are open.
    @ViewBuilder
    private var presentationLayer: some View {
        if let outcome = environment.cleanup.outcome {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                ScrollView {
                    SiftGlassCard(surface: .floating, padding: 0) {
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
                        .padding(SiftMetrics.spacingXL)
                    }
                    .frame(maxWidth: 820)
                    .padding(SiftMetrics.spacingXXL)
                }
                .frame(maxWidth: 900)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        }

        if environment.cleanup.isConfirming {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                ConfirmationHost()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

/// The confirmation panel, hosted with the preferences snapshot the shell owns.
private struct ConfirmationHost: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var preferences = PreferencesSnapshot()

    var body: some View {
        SiftGlassCard(surface: .floating, padding: 0) {
            CleanupConfirmationView(
                cleanup: environment.cleanup,
                preferences: preferences,
                onConfirm: {
                    Task {
                        let result = await environment.confirmCleanup(
                            scanReport: environment.scan.report
                        )
                        if case .purchaseRequired = result {
                            router.requestPurchase(reason: .cleanJunk)
                        }
                    }
                },
                onCancel: { environment.cleanup.cancelConfirmation() },
                onToggleSkipConfirmation: { value in
                    Task { await environment.updateSettings { $0.skipConfirmation = value } }
                }
            )
            .padding(SiftMetrics.spacingXL)
        }
        .frame(width: 560)
        .task(id: environment.preferences) {
            preferences.skipConfirmation = environment.preferences.skipConfirmation
            preferences.requireConfirmation = environment.preferences.requireConfirmation
        }
    }
}

// MARK: - Rail

/// The icon rail: the product mark, the four destinations, then the window-level
/// controls at the bottom.
struct IconRailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var hovered: AppDestination?

    var body: some View {
        VStack(spacing: SiftMetrics.spacingXS) {
            SiftMark()
                .frame(width: 40, height: 40)
                .padding(.top, 8)
                .padding(.bottom, SiftMetrics.spacingXL)

            ForEach(AppDestination.primary) { destination in
                railItem(destination)
            }

            Spacer(minLength: SiftMetrics.spacingL)

            if !environment.entitlement.isUnlocked {
                unlockButton
                    .padding(.bottom, SiftMetrics.spacingS)
            }

            LanguageMenu(
                selection: environment.preferences.language,
                style: .rail,
                identifier: "sidebar.language"
            ) { language in
                environment.selectLanguage(language)
            }
            .help(LocalizationKey.settingsGroupLanguage.localized)

            railItem(.settings)
        }
        .padding(.bottom, SiftMetrics.spacingM)
        .frame(width: SiftMetrics.railWidth)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(SiftColor.baseGlass)
                LinearGradient(
                    colors: [SiftColor.glassHighlight.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SiftColor.glassBorder)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func railItem(_ destination: AppDestination) -> some View {
        let isSelected = router.destination == destination
        let isHovering = hovered == destination
        return Button {
            router.go(to: destination)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: destination.symbolName)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(destination.titleKey.localized)
                    .font(SiftFont.railLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? SiftColor.accent : Color.secondary)
            .frame(width: SiftMetrics.railItemWidth, height: SiftMetrics.railItemHeight)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .fill(isSelected ? SiftColor.selectedFill : (isHovering ? SiftColor.hoverFill : .clear))
            }
            .overlay(alignment: .leading) {
                // The selection mark: a jade bar on the item's left edge, so the
                // selected destination reads without a border boxing it in.
                Capsule()
                    .fill(SiftColor.accent)
                    .frame(width: 3, height: 18)
                    .padding(.leading, 3)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
        }
        .buttonStyle(SiftPressButtonStyle())
        .onHover { hovered = $0 ? destination : (hovered == destination ? nil : hovered) }
        .accessibilityLabel(Text(destination.titleKey.localized))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private var unlockButton: some View {
        Button {
            router.requestPurchase(reason: .cleanJunk)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "lock.open")
                    .font(.system(size: 13, weight: .semibold))
                Text(LocalizationKey.purchaseTitle.localized)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(SiftColor.accent)
            .frame(width: SiftMetrics.railItemWidth, height: 46)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .fill(SiftColor.accent.opacity(0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                    .strokeBorder(SiftColor.accent.opacity(0.22), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SiftPressButtonStyle())
        .accessibilityIdentifier("sidebar.purchase")
        .help(LocalizationKey.purchaseTitle.localized)
    }
}

/// The product mark: three lines in a violet rounded square.
struct SiftMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SiftColor.accentBright, SiftColor.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            VStack(spacing: 4) {
                markLine(width: 18)
                markLine(width: 14)
                markLine(width: 18)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: SiftColor.accent.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    private func markLine(width: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.92))
            .frame(width: width, height: 2.2)
    }
}

// MARK: - Pages

/// Routes the rail selection to the feature's root view.
///
/// Each feature receives a navigation closure rather than a router, so a feature
/// can ask the shell to move without knowing what the shell is.
struct DetailView: View {
    let destination: AppDestination
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch destination {
            case .dashboard:
                DashboardView(
                    scan: environment.scan,
                    cleanup: environment.cleanup,
                    onOpenScan: { router.go(to: .scan) },
                    onOpenApps: { router.go(to: .apps) }
                )
            case .scan:
                ScanView(
                    scan: environment.scan,
                    cleanup: environment.cleanup,
                    onRequestPurchase: { router.requestPurchase(reason: .cleanJunk) },
                    onManageScope: { router.go(to: .settings) }
                )
            case .apps:
                UninstallerView { router.requestPurchase(reason: .uninstall) }
            case .storage:
                StorageAnalysisView(
                    model: environment.storageAnalysis,
                    onGoClean: { router.go(to: .scan) }
                )
            case .settings:
                SettingsView()
            case .purchase:
                PurchaseView(reason: router.paywallReason?.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(destination)
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .offset(y: 8))
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : SiftMotion.page, value: destination)
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
