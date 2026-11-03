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

/// The window: the sidebar and the selected page, over the shared canvas.
///
/// V2 replaces the narrow icon rail with a 190 pt sidebar whose rows are icon-left
/// and label-right (`01 §8`). It carries the four destinations a user goes to,
/// then settings and the account entry, then the window's own preferences — the
/// language control among them, reachable without opening Settings. Category
/// filters live in the scan page, which is where they belong.
///
/// The shell is chrome and nothing else: it routes, and every page keeps its own
/// state, so what a destination does is unchanged by any of this.
public struct RootShellView: View {
    public init() {}

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public var body: some View {
        ZStack {
            SiftCanvasBackground()

            HStack(spacing: 0) {
                SidebarView()
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
        // The window's tint is the green a user reads, not the icon's field green:
        // a tint reaches focus rings, the progress ring and every default control,
        // and the brand green measures 2.43:1 against white — the exact ratio V2
        // splits `brandGreen` from `actionGreen` to keep out of controls.
        .tint(SiftColor.actionGreen)
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

// MARK: - Sidebar

/// The row's own inset from the column's edges, and the gap between rows.
///
/// The inset exists so a row's rounded fill has an edge to be seen against: a wash
/// that ran to the window border reads as a divider rather than as the row the
/// window is on. Two points between rows keeps two washes from touching without
/// breaking the column into separate blocks.
private let sidebarRowInset: CGFloat = 8
private let sidebarRowGap: CGFloat = 2

/// The window's navigation: a flat 190 pt column of icon-left rows.
///
/// V2 replaces the 112 pt icon rail (`01 §8`, `05 §5`). The rail stacked each
/// caption under its icon because 76 pt of width left room for nothing else; at
/// 190 pt the label sits beside the icon, and four destinations read as a list of
/// places instead of four glyphs with words beneath them.
struct SidebarView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    /// Reported by `LanguageMenu` rather than owned here: the picker's state lives
    /// in the control, and the row's wash has to follow it (`onPickerPresentedChange`
    /// exists for exactly this — a footer entry that lights while its picker is up).
    @State private var isLanguagePresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            primary
            Spacer(minLength: SiftMetrics.spacingL)
            groupRule
            footer
        }
        .frame(width: SiftMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        // One flat surface and one hairline between it and the page. The frosted
        // material, the highlight gradient and the glowing border went with the
        // rail: separation in V2 is a surface step plus a rule, and a column of
        // 14 pt labels does not need a light source behind it (`01 §6`).
        .background(SiftColor.surfaceColor.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SiftColor.divider)
                .frame(width: SiftMetrics.hairline)
                .ignoresSafeArea()
        }
    }

    // MARK: Header

    /// The product mark and the product's name.
    ///
    /// 38 pt down, because the window keeps its hidden title bar: the traffic
    /// lights sit in the window's top-left corner and the column starts below them
    /// rather than around them. "Sift" is the product's name in every language and
    /// is deliberately not localized.
    private var header: some View {
        HStack(spacing: SiftMetrics.sidebarIconGap) {
            SiftMark()

            Text("Sift")
                .font(SiftFont.sectionHeading)
                .foregroundStyle(SiftColor.mainText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, sidebarRowInset + SiftMetrics.sidebarRowHorizontalPadding)
        .padding(.top, 38)
        .padding(.bottom, SiftMetrics.spacingL)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Destinations

    private var primary: some View {
        VStack(spacing: sidebarRowGap) {
            ForEach(AppDestination.primary) { destination in
                destinationRow(destination)
            }
        }
        .padding(.horizontal, sidebarRowInset)
    }

    /// One destination, or the Settings entry — they are the same thing to the
    /// window, and the footer's page rows are this function for that reason.
    ///
    /// The box, the label, the hover fill, the selection wash and the leading mark
    /// all come from `SidebarRowLabel` and `siftSidebarRowChrome`, which every
    /// entry in the column wears; one implementation of a row's chrome is what
    /// keeps the foot of the column from becoming a second style of button.
    private func destinationRow(_ destination: AppDestination) -> some View {
        let isSelected = router.destination == destination
        return Button {
            router.go(to: destination)
        } label: {
            SidebarRowLabel(
                symbolName: destination.symbolName,
                title: destination.titleKey.localized
            )
            // The label's colour is set here rather than inside the label, because
            // the selection is the button's fact and not the row's: a selected
            // destination is `actionGreen` — the readable green, 5.16:1 — and
            // everything else is `secondaryText`, never the brand fill.
            .foregroundStyle(isSelected ? SiftColor.actionGreen : SiftColor.secondaryText)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftSidebarRowChrome(isSelected: isSelected)
        .accessibilityLabel(Text(destination.titleKey.localized))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    // MARK: Lower group

    /// The rule that opens the lower group. Inset to the rows' own width, so it
    /// reads as a boundary between groups rather than as a second window edge.
    private var groupRule: some View {
        Rectangle()
            .fill(SiftColor.divider)
            .frame(height: SiftMetrics.hairline)
            .padding(.horizontal, sidebarRowInset + SiftMetrics.sidebarRowHorizontalPadding)
            .padding(.bottom, SiftMetrics.spacingS)
    }

    /// Settings and Account are pages, so they wear a destination row and the
    /// indicator can land on them. Appearance and language are not places: they
    /// open a picker, they belong to the window rather than to a page, and they
    /// sit under the two page rows as the quieter pair (`01 §8`).
    private var footer: some View {
        VStack(spacing: sidebarRowGap) {
            destinationRow(.settings)

            if !environment.entitlement.isUnlocked {
                unlockButton
            } else {
                accountButton
            }

            VStack(spacing: 0) {
                AppearanceSidebarMenu(
                    selection: environment.preferences.appearance,
                    onSelect: { appearance in
                        Task { await environment.updateSettings { $0.appearance = appearance } }
                    }
                )

                // The language control keeps its own presentation: it is a picker,
                // not a row, and `LanguageMenu` attaches the popover to its button
                // — never to the style's conditional wrapper, which never presented
                // at all (`AGENTS.md`, layout notes). Its open state is reported
                // out rather than guessed at, so this row lights exactly while its
                // picker is up and takes no indicator: it is a preference, not the
                // page the window is showing.
                LanguageMenu(
                    selection: environment.preferences.language,
                    style: .sidebar,
                    identifier: "sidebar.language",
                    onPickerPresentedChange: { isLanguagePresented = $0 },
                    onSelect: { language in
                        environment.selectLanguage(language)
                    }
                )
                .siftSidebarRowChrome(isSelected: isLanguagePresented, showsMark: false)
                .help(LocalizationKey.settingsGroupLanguage.localized)
            }
            .padding(.top, SiftMetrics.spacingS)
        }
        .padding(.horizontal, sidebarRowInset)
        .padding(.bottom, SiftMetrics.spacingM)
    }

    /// The purchase state, while locked: an invitation, not a page.
    ///
    /// It is the one entry in the column painted in `actionGreen` while nothing is
    /// selected there, and it never takes the selection wash or the `.isSelected`
    /// trait. It used to take both, which showed the window on two pages at once
    /// and had VoiceOver announce the call to action as "the page you are on"
    /// (`05 §5`).
    private var unlockButton: some View {
        Button {
            router.requestPurchase(reason: .cleanJunk)
        } label: {
            SidebarRowLabel(
                symbolName: "lock.open",
                title: LocalizationKey.purchaseTitle.localized
            )
            .foregroundStyle(SiftColor.actionGreen)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftSidebarRowChrome(isSelected: false)
        .accessibilityIdentifier("sidebar.purchase")
        .help(LocalizationKey.purchaseTitle.localized)
    }

    /// The unlocked entry: the account page, where the licence and the purchase
    /// state live. Same row as a destination, because it is one.
    private var accountButton: some View {
        let isSelected = router.destination == .purchase
        return Button {
            router.go(to: .purchase)
        } label: {
            SidebarRowLabel(
                symbolName: "person.crop.circle",
                title: LocalizationKey.navAccount.localized
            )
            .foregroundStyle(isSelected ? SiftColor.actionGreen : SiftColor.secondaryText)
        }
        .buttonStyle(SiftPressButtonStyle())
        .siftSidebarRowChrome(isSelected: isSelected)
        .accessibilityIdentifier("sidebar.account")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(LocalizationKey.navAccount.localized)
    }
}

/// One row's contents: the icon, then the label.
///
/// Icon left and label right is the structural change V2 makes (`01 §8`). The
/// stack it replaces was not a style: 76 pt of rail could not hold a word beside a
/// glyph, so the caption went underneath. A 190 pt column can, and the single line
/// is what lets four destinations be compared at a glance.
private struct SidebarRowLabel: View {
    let symbolName: String
    let title: String

    var body: some View {
        HStack(spacing: SiftMetrics.sidebarIconGap) {
            Image(systemName: symbolName)
                .font(.system(size: SiftMetrics.sidebarIconSize, weight: .medium))
                // A fixed glyph box, so every label in the column starts at the
                // same x however wide the symbol itself happens to be.
                .frame(width: SiftMetrics.sidebarIconSize, height: SiftMetrics.sidebarIconSize)

            Text(title)
                .font(SiftFont.railLabel)
                .lineLimit(1)
                // Truncation, never wrapping: a longer translation must not change
                // a row's height and push the column out of alignment.
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SiftMetrics.sidebarRowHorizontalPadding)
        .frame(height: SiftMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A preference row's contents, in the design system's own sidebar-footer idiom.
///
/// It is one step quieter than a destination — a 12 pt glyph in an 18 pt box, a
/// 14 pt name and a 32 pt row — and it is deliberately the same shape as
/// `LanguageMenu`'s sidebar label, because the appearance and language controls
/// stand one above the other: two heights, two glyph boxes or one row with a
/// disclosure glyph and its neighbour without would read as an accident. A
/// preference belongs to the window rather than to a place, so it does not take a
/// destination's row height, its icon size or its weight (`05 §5`).
private struct SidebarPreferenceLabel: View {
    let symbolName: String
    let title: String

    var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)

            Text(title)
                .font(SiftFont.body)
                .lineLimit(1)

            Spacer(minLength: SiftMetrics.spacingS)

            // The same disclosure glyph, at the same size and in the same colour,
            // as the language row's: both open a picker and both say so the same
            // way. `quietText` because the glyph is a hint, not a label.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(SiftColor.quietText)
        }
        .foregroundStyle(SiftColor.secondaryText)
        .padding(.horizontal, SiftMetrics.spacingS)
        .frame(maxWidth: .infinity, minHeight: SiftMetrics.minimumHitTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A row's background chrome: the hover fill that tracks the pointer, the
/// selection wash, and the leading mark a selected destination carries.
///
/// This is the rail's `siftRailItemChrome` re-cut for a horizontal row, and it
/// stays one implementation for the same reason it was one before: the four
/// destinations, Settings, the account entry, the purchase invitation and the
/// appearance switcher all wear it, so the bottom of the column cannot drift into
/// a second style of button.
///
/// What changed is the geometry and the mark. The rail drew a 3 pt bar down the
/// item's full height, under a caption it had to be visible past; a 44 pt row with
/// a full-height bar reads as a spreadsheet row, so the mark is a capsule inset
/// 10 pt from the top and bottom and weighted to the emblem rather than to the
/// row.
private struct SidebarRowChrome: ViewModifier {
    let isSelected: Bool
    /// `false` for a control whose "selected" state is an open popover: it lights
    /// while its picker is up, but it never claims the page the window is on.
    let showsMark: Bool
    let radius: CGFloat

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    /// No hover tint over a selected row: a second fill on top of the wash reads
    /// as a third state rather than as the pointer arriving.
    private var fill: Color {
        if isSelected { return SiftColor.selectedWash }
        if isHovering { return SiftColor.rowHoverFill }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    // 120 ms for the pointer and 160 ms for the selection: V2's
                    // band is 120–180 ms for both, and the fill fades in place
                    // rather than travelling between rows (`01 §9`).
                    .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
                    .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
            }
            .overlay(alignment: .leading) {
                // The mark belongs to the row it marks and fades with it. Drawn on
                // a shared track it had to travel, which is why the rail slid one
                // fill between slots; a column of full-width rows does not.
                Capsule()
                    .fill(SiftColor.actionGreen)
                    .frame(width: 3, height: 24)
                    .opacity(showsMark && isSelected ? 1 : 0)
                    .animation(reduceMotion ? nil : SiftMotion.quick, value: isSelected)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func siftSidebarRowChrome(
        isSelected: Bool,
        showsMark: Bool = true,
        radius: CGFloat = SiftMetrics.sidebarRowRadius
    ) -> some View {
        modifier(SidebarRowChrome(isSelected: isSelected, showsMark: showsMark, radius: radius))
    }
}

/// The product mark, reduced to what survives at 29 pt.
///
/// The rail's mark was three white lines on a blue-violet gradient square with a
/// shadow under it. V2 retires it (`01 §8`) in favour of the app icon's own two
/// shapes: a green field and a gold star, both flat. The gradient, the inner
/// stroke and the drop shadow went with the lines — a mark carrying its own light
/// source was the loudest thing in a column of 14 pt labels, and what identifies
/// the product is the green-and-gold pair, not the depth.
struct SiftMark: View {
    /// The tile's edge.
    private static let tile: CGFloat = 29
    /// 0.66 of the tile rather than 0.62: `star.fill` carries roughly a point of
    /// bearing on each side, so the ink lands at about 0.62 of the tile — the
    /// icon's own proportion.
    private static let starSize: CGFloat = tile * 0.66

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(SiftColor.brandGreen)
            .frame(width: Self.tile, height: Self.tile)
            .overlay {
                Image(systemName: "star.fill")
                    .font(.system(size: Self.starSize, weight: .regular))
                    .foregroundStyle(SiftColor.brandGold)
            }
            // Decorative: the word beside it is the product's name, and a
            // VoiceOver user hears that instead of an unlabelled image.
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

/// The appearance switcher, as a preference row at the foot of the column.
///
/// A plain button with a popover rather than a `Menu`, in `LanguageMenu`'s idiom:
/// 34 languages do not fit in a menu the window has to grow for, and the two
/// preferences at the bottom read as one pair only if they are built the same way.
/// The current mode names the row, so the state reads without opening it.
///
/// The popover is presented by the button itself. That is not incidental: the
/// language picker's used to hang off the style's `Group { if case .rail … }`
/// wrapper and never opened, because a presentation installed on
/// `_ConditionalContent` has no view to present from (`AGENTS.md`, layout notes).
///
/// Its label does not opt out of hit testing, for the same class of reason: a
/// label with hit testing off leaves the button with nothing to hit, so the entry
/// lights up under the pointer and ignores the click.
struct AppearanceSidebarMenu: View {
    let selection: AppSettings.Appearance
    let onSelect: (AppSettings.Appearance) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            SidebarPreferenceLabel(symbolName: icon, title: selection.titleKey.localized)
                .foregroundStyle(isPresented ? SiftColor.actionGreen : SiftColor.secondaryText)
        }
        .buttonStyle(SiftPressButtonStyle())
        // The row lights while its picker is up, and takes no indicator: it is a
        // control, not the page the window is showing (`05 §5`).
        .siftSidebarRowChrome(isSelected: isPresented, showsMark: false)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            picker
        }
        .accessibilityIdentifier("sidebar.appearance")
        .accessibilityLabel(Text(LocalizationKey.settingsGroupAppearance.localized))
        .accessibilityValue(Text(selection.titleKey.localized))
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
            // `mainText`, not `.primary`: the picker is a list of sentences and
            // only the checkmark column carries the state.
            .foregroundStyle(isSelected ? SiftColor.actionGreen : SiftColor.mainText)
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
        isSelected ? SiftColor.selectedWash : .clear
    }
}
