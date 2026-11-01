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
                    // A language change has to rebuild the page subtree. The
                    // strings come from `LocalizationKey.localized`, which reads
                    // UserDefaults directly and is therefore invisible to
                    // SwiftUI's dependency tracking: without a new identity, a
                    // leaf view whose inputs did not change (the category grid,
                    // for one) kept rendering the old language.
                    .id(environment.preferences.language)
            }

            presentationLayer
        }
        .environment(\.locale, environment.preferences.language.locale)
        .environment(\.layoutDirection, environment.preferences.language.layoutDirection)
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
                            loadTrash: { await environment.trashSnapshot() },
                            onEmptyTrash: { snapshot in await environment.emptyTrash(snapshot) },
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

            // The appearance switcher lives in the rail, above the account
            // entry: it is a window-level control, and the footer is where the
            // window-level controls sit.
            AppearanceRailMenu(
                selection: environment.preferences.appearance
            ) { appearance in
                Task { await environment.updateSettings { $0.appearance = appearance } }
            }

            // The footer item is the purchase state: an accent call to unlock
            // while locked, the account entry once unlocked.
            if !environment.entitlement.isUnlocked {
                unlockButton
            } else {
                accountButton
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

    /// One rail entry.
    ///
    /// The box, the label, the hover and press feedback and the selection fill
    /// all come from `SiftRailItemLabel` and `siftRailItemChrome`, which the
    /// footer controls wear too — so "the buttons at the bottom do not look like
    /// the buttons at the top" cannot come back from two hand-written styles
    /// drifting apart.
    private func railItem(_ destination: AppDestination) -> some View {
        let isSelected = router.destination == destination
        return Button {
            router.go(to: destination)
        } label: {
            SiftRailItemLabel(
                symbolName: destination.symbolName,
                title: destination.titleKey.localized
            )
            .foregroundStyle(isSelected ? SiftColor.accent : Color.secondary)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: isSelected, showsSelectionMark: true)
        .accessibilityLabel(Text(destination.titleKey.localized))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private var unlockButton: some View {
        Button {
            router.requestPurchase(reason: .cleanJunk)
        } label: {
            // The one accent-tinted entry in the rail, but the same item box,
            // icon size and label as every other rail entry: the footer reads
            // as one column, not three controls that arrived separately.
            SiftRailItemLabel(
                symbolName: "lock.open",
                title: LocalizationKey.purchaseTitle.localized
            )
            .foregroundStyle(SiftColor.accent)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: true)
        .accessibilityIdentifier("sidebar.purchase")
        .help(LocalizationKey.purchaseTitle.localized)
    }

    /// The unlocked footer item: the account page, where the purchase state and
    /// the stored licence are shown. Same item box, icon size and label as every
    /// other rail entry — the call to action is gone because there is nothing
    /// left to sell here.
    private var accountButton: some View {
        let isSelected = router.destination == .purchase
        return Button {
            router.go(to: .purchase)
        } label: {
            SiftRailItemLabel(
                symbolName: "person.crop.circle",
                title: LocalizationKey.navAccount.localized
            )
            .foregroundStyle(isSelected ? SiftColor.accent : Color.secondary)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: isSelected, showsSelectionMark: true)
        .accessibilityIdentifier("sidebar.account")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(LocalizationKey.navAccount.localized)
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
                .strokeBorder(.white.opacity(0.22), lineWidth: SiftMetrics.hairline)
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

/// The appearance switcher, as a rail footer item in the language menu's exact
/// idiom — a plain button with an overlaid label opening a popover — so the
/// footer reads as one column of identically-styled items and no control
/// carries the system menu's accent tint. The current mode names the item, so
/// the state reads without opening it.
///
/// It wears the same `siftRailItemChrome` as the navigation entries, and passes
/// `isSelected` while its popover is open: before that, this was the one entry
/// in the rail with no hover fill and no press state at all, which is what made
/// the bottom of the rail look like a different set of controls.
///
/// Its label does not opt out of hit testing. It did — and a label with hit
/// testing off leaves the button with nothing to hit, so the entry lit up under
/// the pointer and ignored the click. `LanguageMenu` carried the same defect and
/// it is fixed in the same place.
struct AppearanceRailMenu: View {
    let selection: AppSettings.Appearance
    let onSelect: (AppSettings.Appearance) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            SiftRailItemLabel(symbolName: icon, title: selection.titleKey.localized)
                .foregroundStyle(isPresented ? SiftColor.accent : Color.secondary)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: isPresented)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            picker
        }
        .accessibilityIdentifier("sidebar.appearance")
        .accessibilityLabel(Text(LocalizationKey.settingsGroupAppearance.localized))
        .accessibilityValue(Text(selection.titleKey.localized))
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .help(LocalizationKey.settingsGroupAppearance.localized)
    }

    private var icon: String {
        switch selection {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var picker: some View {
        VStack(spacing: 1) {
            ForEach(AppSettings.Appearance.allCases, id: \.self) { appearance in
                pickerRow(appearance)
            }
        }
        .padding(.vertical, SiftMetrics.spacingXS)
        .padding(.horizontal, SiftMetrics.spacingXS)
        .frame(width: 150)
    }

    private func pickerRow(_ appearance: AppSettings.Appearance) -> some View {
        let isSelected = appearance == selection
        return Button {
            onSelect(appearance)
            isPresented = false
        } label: {
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                    .opacity(isSelected ? 1 : 0)
                Text(appearance.titleKey.localized)
                    .font(SiftFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? SiftColor.accent : .primary)
            .padding(.horizontal, SiftMetrics.spacingS)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .fill(rowBackground(isSelected))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowBackground(_ isSelected: Bool) -> Color {
        isSelected ? SiftColor.selectedFill : .clear
    }
}
