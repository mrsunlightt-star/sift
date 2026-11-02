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
        .frame(width: 780, height: 660)
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
    /// Whether a footer popover is up. The two popover controls are rail entries
    /// like any other, so their group's fill has to travel to them; the state
    /// lives here because one slider draws the fill for all four footer slots.
    @State private var isAppearancePresented = false
    @State private var isLanguagePresented = false

    var body: some View {
        VStack(spacing: SiftMetrics.spacingXS) {
            SiftMark()
                .frame(width: 40, height: 40)
                // The window keeps its traffic lights (hidden title bar, not a
                // hidden title bar zone), and they occupy the first ~28 pt.
                .padding(.top, 28)
                .padding(.bottom, SiftMetrics.spacingXL)

            // One fill for the whole group, drawn behind the entries and moved
            // to the entry the window is showing: switching pages slides it
            // instead of lighting a second entry and fading the first.
            ZStack(alignment: .top) {
                RailSelectionSlider(index: primarySelection, count: AppDestination.primary.count)
                VStack(spacing: SiftMetrics.spacingXS) {
                    ForEach(AppDestination.primary) { destination in
                        railItem(destination)
                    }
                }
            }

            Spacer(minLength: SiftMetrics.spacingL)

            // The footer is its own group, and its entries pass the fill to the
            // same slider for the same reason: account and settings are pages, so
            // moving between them slides one fill rather than swapping two.
            ZStack(alignment: .top) {
                RailSelectionSlider(index: footerSelection, count: IconRailView.footerSlotCount)
                VStack(spacing: SiftMetrics.spacingXS) {
                    // The appearance switcher lives in the rail, above the account
                    // entry: it is a window-level control, and the footer is where
                    // the window-level controls sit. It keeps its own highlight
                    // while its popover is open — it is not a page.
                    AppearanceRailMenu(
                        selection: environment.preferences.appearance,
                        onSelect: { appearance in
                            Task { await environment.updateSettings { $0.appearance = appearance } }
                        },
                        onPresentedChange: { isAppearancePresented = $0 }
                    )

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
                        identifier: "sidebar.language",
                        onPickerPresentedChange: { isLanguagePresented = $0 },
                        onSelect: { language in
                            environment.selectLanguage(language)
                        }
                    )
                    .help(LocalizationKey.settingsGroupLanguage.localized)

                    railItem(.settings)
                }
            }
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

    /// The footer's slots, in the order they are laid out: appearance, the
    /// purchase state (unlock while locked, account once unlocked), language and
    /// settings.
    static let footerSlotCount = 4

    /// Which destination the rail's top group is showing, or `nil` while the
    /// window is on a page that group does not hold.
    private var primarySelection: Int? {
        AppDestination.primary.firstIndex(of: router.destination)
    }

    /// Which footer slot the fill sits on.
    ///
    /// All four slots are entries the user can press, so all four move the fill:
    /// an open popover wins over the page underneath it, because it is the thing
    /// the user just did. The one slot that never takes the fill is the unlock
    /// call to action — a fill parked on it read as "the page you are on", which
    /// the rail already got wrong once. Its state is `nil` there, so the fill
    /// fades out rather than sliding onto the CTA.
    private var footerSelection: Int? {
        if isAppearancePresented { return 0 }
        if isLanguagePresented { return 2 }
        switch router.destination {
        case .purchase:
            return environment.entitlement.isUnlocked ? 1 : nil
        case .settings:
            return 3
        default:
            return nil
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
        // The group's slider paints the selection fill, so this entry only
        // contributes its box, its hover fill and its leading mark.
        .siftRailItemChrome(isSelected: isSelected, fillsSelection: false)
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
        // Not `isSelected: true`: the call to action used to wear the same
        // selection fill as the current page, so the rail showed two selected
        // items and VoiceOver heard the CTA as "the page you are on". The accent
        // label is what distinguishes it.
        .siftRailItemChrome(isSelected: false)
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
        .siftRailItemChrome(isSelected: isSelected, fillsSelection: false)
        .accessibilityIdentifier("sidebar.account")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(LocalizationKey.navAccount.localized)
    }
}

/// The rail's selection fill, drawn once per group.
///
/// It is placed by slot rather than by `matchedGeometryEffect`: the rail's
/// entries are a fixed size in a fixed column, so the slot's offset is known
/// arithmetic, and a geometry hand-off would add a second source of truth about
/// where the fill belongs. `nil` means "this group holds no page", and the fill
/// fades out rather than sliding back to the first slot.
private struct RailSelectionSlider: View {
    let index: Int?
    let count: Int
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        let stride = SiftMetrics.railItemHeight + SiftMetrics.spacingXS
        let slot = min(max(index ?? 0, 0), max(count - 1, 0))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                .fill(SiftColor.selectedFill)
            // The leading selection mark rides with the fill. Drawn on the entry
            // instead, it jumped to the next slot a frame before the fill
            // arrived, which read as two indicators disagreeing about where the
            // window was.
            Capsule()
                .fill(SiftColor.accent)
                .frame(width: 3, height: 18)
                .padding(.leading, 3)
        }
        .frame(width: SiftMetrics.railItemWidth, height: SiftMetrics.railItemHeight)
        .offset(y: CGFloat(slot) * stride)
        .opacity(index == nil ? 0 : 1)
        .animation(reduceMotion ? nil : SiftMotion.settle, value: index)
        .allowsHitTesting(false)
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
                .foregroundStyle(isPresented ? SiftColor.accent : Color.secondary)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftRailItemChrome(isSelected: isPresented, fillsSelection: false)
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
