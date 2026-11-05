import AppKit
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

/// The window: a horizontal macOS sidebar and the selected page, over the
/// shared canvas. Primary destinations stay separate from appearance, account,
/// language and settings controls in the footer.
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
                    // Language and type scale both change text that SwiftUI
                    // cannot see as a dependency (`LocalizationKey.localized` and
                    // a process-wide font scale), so the subtree is rebuilt on
                    // either.
                    .id("\(environment.preferences.language.rawValue)-\(environment.preferences.textScale.rawValue)")
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

    /// One modal slot for the whole cleanup flow.
    ///
    /// Confirmation, execution and the result are three states of one decision,
    /// and each one hides the last. Presenting them as three separate sheets
    /// drops the second while the first is still dismissing; one sheet whose
    /// content is chosen from the model cannot get out of step. They are real
    /// sheets rather than a dimmed `ZStack` because a panel that covers the
    /// window has to behave like a modal: ⌘., Esc and focus belong to it.
    ///
    /// The host observes `CleanupModel` itself. Reading it through
    /// `AppEnvironment` alone looked right and presented nothing: the shell
    /// re-renders when the environment's own published values change, and
    /// `isConfirming` is one level down — so the panel appeared only when
    /// something unrelated happened to redraw the window.
    private var presentationLayer: some View {
        ShellPresentationHost(cleanup: environment.cleanup)
    }
}

/// Everything modal, in one place.
private struct ShellPresentationHost: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @ObservedObject var cleanup: CleanupModel

    private enum ShellSheet: String, Identifiable {
        case confirmation
        case executing
        case result
        var id: String { rawValue }
    }

    var body: some View {
        // A full-size, inert layer: a sheet needs somewhere to hang, and it must
        // not intercept a click on the page underneath.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .sheet(item: sheetBinding) { sheet in
                switch sheet {
                case .confirmation:
                    ConfirmationHost()
                case .executing:
                    CleanupExecutionView(cleanup: cleanup) {
                        cleanup.stopExecution()
                    }
                case .result:
                    outcomeSheet
                }
            }
    }

    /// Which modal is up. The result wins over both others: a batch that
    /// finishes while its own overlay is still up must land on the outcome, not
    /// on the panel it started from.
    private var currentSheet: ShellSheet? {
        if cleanup.outcome != nil { return .result }
        if cleanup.isWorking || cleanup.isPreparingCleanup { return .executing }
        if cleanup.isConfirming { return .confirmation }
        return nil
    }

    private var sheetBinding: Binding<ShellSheet?> {
        Binding(
            get: { currentSheet },
            set: { newValue in
                guard newValue == nil else { return }
                // A dismissal the system performs (Esc) is the same decision as
                // the panel's own cancel, so it goes back through the model
                // instead of being dropped.
                if cleanup.isConfirming {
                    cleanup.cancelConfirmation()
                } else if cleanup.outcome != nil {
                    cleanup.acknowledgeOutcome()
                    environment.clearReportExportMessage()
                }
            }
        )
    }

    private var outcomeSheet: some View {
        ScrollView {
            CleanupResultView(
                outcome: cleanup.outcome ?? .none,
                report: cleanup.report,
                onAcknowledge: {
                    cleanup.acknowledgeOutcome()
                    environment.clearReportExportMessage()
                },
                onExport: {
                    Task {
                        guard await environment.canExportReports() else {
                            router.requestPurchase(reason: .exportReport)
                            return
                        }
                        if let report = cleanup.report {
                            await environment.exportReport(report)
                        }
                    }
                },
                onOpenTrash: { Task { await environment.openTrash() } },
                loadTrash: { await environment.trashSnapshot() },
                onEmptyTrash: { snapshot in await environment.emptyTrashGated(snapshot) },
                onRevealFailed: { url in Task { await environment.reveal(url) } },
                onRetryFailed: { results in
                    Task {
                        if case .purchaseRequired = await environment.retryCleanup(results) {
                            router.requestPurchase(reason: .cleanJunk)
                        }
                    }
                },
                onUndo: {
                    Task { _ = await environment.undoLastCleanup() }
                },
                onRequestPurchase: { router.requestPurchase(reason: .exportReport) },
                statusMessage: environment.reportExportMessage
            )
            .padding(SiftMetrics.spacingXL)
        }
        // Keep the result sheet inside the supported minimum window
        // height. The report itself already scrolls, so reducing the sheet
        // does not hide failure rows or recovery actions.
        .frame(width: 760, height: 560)
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
        }
        .task(id: environment.preferences) {
            preferences.skipConfirmation = environment.preferences.skipConfirmation
            preferences.requireConfirmation = environment.preferences.requireConfirmation
            preferences.hasCompletedCleanup = environment.preferences.hasCompletedCleanup
        }
    }
}

// MARK: - Rail

/// The icon rail: the product mark, the four destinations, then the window-level
/// controls at the bottom.
struct IconRailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var isLanguagePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SiftMetrics.spacingM) {
                SiftMark()
                    .frame(width: 42, height: 42)
                Text("Sift")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SiftColor.mainText)
            }
            .padding(.horizontal, SiftMetrics.spacingM)
            .padding(.top, 28)
            .padding(.bottom, SiftMetrics.spacingXL)

            VStack(spacing: SiftMetrics.spacingXS) {
                ForEach(AppDestination.primary) { destination in
                    railItem(destination)
                }
            }

            Spacer(minLength: SiftMetrics.spacingXL)

            Rectangle()
                .fill(SiftColor.glassBorder)
                .frame(height: 1)
                .padding(.horizontal, SiftMetrics.spacingM)
                .padding(.bottom, SiftMetrics.spacingS)

            VStack(spacing: SiftMetrics.spacingXS) {
                AppearanceRailMenu(
                    selection: environment.preferences.appearance,
                    onSelect: { appearance in
                        Task { await environment.updateSettings { $0.appearance = appearance } }
                    }
                )
                .padding(.horizontal, SiftMetrics.spacingS)

                if !environment.entitlement.isUnlocked {
                    unlockButton
                } else {
                    accountButton
                }

                LanguageMenu(
                    selection: environment.preferences.language,
                    style: .sidebar,
                    identifier: "sidebar.language",
                    onPickerPresentedChange: { isLanguagePresented = $0 },
                    onSelect: { language in environment.selectLanguage(language) }
                )
                .padding(.horizontal, SiftMetrics.spacingS)
                .siftRailItemChrome(isSelected: isLanguagePresented)

                railItem(.settings)
            }
            .padding(.bottom, SiftMetrics.spacingM)
        }
        .padding(.horizontal, SiftMetrics.spacingS)
        .frame(width: SiftMetrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(SiftColor.canvas.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SiftColor.glassBorder)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func railItem(_ destination: AppDestination) -> some View {
        let isSelected = router.destination == destination
        return Button {
            router.go(to: destination)
        } label: {
            SiftRailItemLabel(
                symbolName: destination.symbolName,
                title: destination.titleKey.localized
            )
            .foregroundStyle(isSelected ? SiftColor.accentText : SiftColor.mainText)
        }
        .buttonStyle(.plain)
        .siftRailItemChrome(isSelected: isSelected, showsSelectionMark: true)
        .accessibilityLabel(Text(destination.titleKey.localized))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private var unlockButton: some View {
        Button {
            router.requestPurchase(reason: .cleanJunk)
        } label: {
            SiftRailItemLabel(
                symbolName: "lock.open",
                title: LocalizationKey.purchaseTitle.localized
            )
            .foregroundStyle(SiftColor.accentText)
        }
        .buttonStyle(.plain)
        .siftRailItemChrome(isSelected: false)
        .accessibilityIdentifier("sidebar.purchase")
        .help(LocalizationKey.purchaseTitle.localized)
    }

    private var accountButton: some View {
        let isSelected = router.destination == .purchase
        return Button {
            router.go(to: .purchase)
        } label: {
            SiftRailItemLabel(
                symbolName: "person.crop.circle",
                title: LocalizationKey.navAccount.localized
            )
            .foregroundStyle(isSelected ? SiftColor.accentText : SiftColor.mainText)
        }
        .buttonStyle(.plain)
        .siftRailItemChrome(isSelected: isSelected, showsSelectionMark: true)
        .accessibilityIdentifier("sidebar.account")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(LocalizationKey.navAccount.localized)
    }
}

/// The product mark is the actual application icon, not a separate gradient
/// menu glyph. The icon is the source of Sift's green and gold identity.
struct SiftMark: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
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
    /// Reports the popover opening and closing so the footer's slider can move
    /// to this entry. The entry itself no longer paints the selection fill —
    /// `fillsSelection: false` — because a fill drawn here would appear under the
    /// pointer while the slider was still travelling.
    var onPresentedChange: ((Bool) -> Void)? = nil

    @State private var isPresented = false

    var body: some View {
        Button {
            presented.wrappedValue.toggle()
        } label: {
            SiftRailItemLabel(symbolName: icon, title: selection.titleKey.localized)
                .foregroundStyle(isPresented ? SiftColor.accentText : Color.secondary)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: isPresented)
        .popover(isPresented: presented, arrowEdge: .trailing) {
            picker
        }
        .accessibilityIdentifier("sidebar.appearance")
        .accessibilityLabel(Text(LocalizationKey.settingsGroupAppearance.localized))
        .accessibilityValue(Text(selection.titleKey.localized))
        // A popover control is not "the page you are on". The fill already says
        // the picker is open; the trait claimed a state the rail does not have.
        .help(LocalizationKey.settingsGroupAppearance.localized)
    }

    /// The popover's state, reporting every change to the rail.
    ///
    /// The footer's slider needs to hear about this one: the entry hands the
    /// selection fill to it (`fillsSelection: false`), so a popover that opened
    /// silently would leave the fill on whatever page was last shown.
    private var presented: Binding<Bool> {
        Binding(
            get: { isPresented },
            set: { presented in
                guard presented != isPresented else { return }
                isPresented = presented
                onPresentedChange?(presented)
            }
        )
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
            presented.wrappedValue = false
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
            .foregroundStyle(isSelected ? SiftColor.accentText : .primary)
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
