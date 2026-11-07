import AppKit
import Core
import Shared
import SwiftUI

/// The two subjects the Apps page shows.
///
/// An application that is installed and one that was removed are not two
/// features: they are two answers to "what is on this Mac", and the residue is
/// what the first answer leaves behind. Keeping them in one page means the second
/// answer is one click from the first, and neither needs its own navigation entry.
enum AppsScope: String, CaseIterable, Identifiable {
    case installed
    case leftovers

    var id: String { rawValue }

    /// The chip label.
    ///
    /// The leftovers scope reuses the category's own name — "App leftovers" is
    /// already a reviewed translation in every language, and a second word for the
    /// same rows would describe them differently in the two places they appear.
    var titleKey: LocalizationKey {
        switch self {
        case .installed: .appsScopeInstalled
        case .leftovers: .cleanupCategoryApplicationResidue
        }
    }
}

/// The uninstaller (§5.3), presented as the Apps page.
///
/// Left: the installed applications, with search, scopes and sorting. Right: an
/// inspector for the selected application — what it is, what belongs to it, and
/// the one action that removes it. The page is the only place an application is
/// uninstalled; the scan page never offers that, because removing an application
/// is not a cleanup item.
///
/// V2 draws the two panes as a list and an inspector rather than as two floating
/// cards: a card says "this is a thing", and an inventory of 128 applications is
/// not a thing. The panes are separated by a rule, and neither is a surface.
public struct UninstallerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    @State private var search = ""
    @State private var sort: ApplicationSortOrder = .largestFirst
    @State private var filter: ApplicationFilter = .large
    @State private var selected: InstalledApplication?
    @State private var plan: UninstallPlan?
    @State private var isLoadingPlan = false
    @State private var isConfirming = false
    /// What pre-flight approved, for the panel to state.
    @State private var preparedSummary: AppEnvironment.UninstallPreparation?
    /// Why nothing can be uninstalled right now, when pre-flight refused it all.
    @State private var refusalMessage: String?
    @State private var outcome: CleanupOutcome?
    @State private var outcomeReport: CleanupReport?
    @State private var includeReviewFiles = false
    @State private var quitFailure: String?
    /// Which subject the page is showing. Installed first: removing an
    /// application is what the page is named for, and leftovers are the follow-up
    /// question.
    @State private var scope: AppsScope = .installed

    /// The list starts with the applications that are worth removing. A 12 MB
    /// helper is not what this page is for, and showing 128 rows of them buries
    /// the ones that matter — but the default is now a labelled chip with its own
    /// count, and "Show all" is one click away, instead of an unmentioned
    /// threshold applied to a list that claimed to be the inventory.
    private let visibleSizeThreshold: Int64 = 200 * 1024 * 1024

    private let inspectorWidth: CGFloat = 320

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        Group {
            if let outcome {
                outcomeView(outcome)
            } else {
                page
            }
        }
        .task { await environment.loadApplications() }
        .sheet(isPresented: $isConfirming) {
            uninstallConfirmation
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: LocalizationKey.navApps.localized, status: statusLine) {
                SiftMetricPill(
                    symbolName: "shippingbox",
                    value: LocalizationKey.commonItemCount.counted(
                        environment.installedApplications.count
                    ),
                    tone: .accent
                )
            }

            subjectBar

            if scope == .leftovers {
                ResidueView(onRequestPurchase: onRequestPurchase)
            } else {
                installedContent
            }
        }
    }

    /// The applications that are here.
    ///
    /// Everything the page did before the leftovers scope existed, unchanged: the
    /// list, the inspector and the one action that removes a bundle.
    private var installedContent: some View {
        VStack(spacing: 0) {
            if environment.appManagement == .denied {
                appManagementNotice
                    .padding(.horizontal, SiftMetrics.pagePadding)
                    .padding(.top, SiftMetrics.spacingM)
                    .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                paneRule
                inspector
                    .frame(width: inspectorWidth)
                    .frame(maxHeight: .infinity)
            }
            .padding(.leading, SiftMetrics.pagePadding)
            .padding(.trailing, SiftMetrics.pagePadding)
            .padding(.top, SiftMetrics.spacingL)
            .padding(.bottom, SiftMetrics.spacingXXL)
            .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The page's two subjects: what is installed, and what was left behind.
    ///
    /// One page rather than a fifth navigation entry — an application that is
    /// here and an application that is gone are the same subject, and the person
    /// looking for one often wants the other. The first chip carries the count the
    /// page already knows, so the inventory is stated before it is opened.
    private var subjectBar: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            ForEach(AppsScope.allCases) { candidate in
                SiftFilterChip(
                    title: candidate.titleKey.localized,
                    detail: candidate == .installed
                        ? LocalizationKey.commonItemCount.counted(
                            environment.installedApplications.count
                        )
                        : nil,
                    isSelected: scope == candidate
                ) {
                    scope = candidate
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SiftMetrics.pagePadding)
        .padding(.vertical, SiftMetrics.spacingM)
        .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The gate, stated before the user picks an application.
    ///
    /// This page is the only place an application bundle is moved, and moving
    /// one is governed by App Management rather than by a folder permission. The
    /// page used to find that out from a failed batch; the launch check answers it
    /// first, and the "Check again" control is there because the switch can be
    /// turned on without restarting Sift — the grant is applied when it is made,
    /// unlike Full Disk Access, which macOS reads at launch.
    private var appManagementNotice: some View {
        HStack(alignment: .center, spacing: SiftMetrics.spacingM) {
            NoticeBanner(
                level: .warning,
                message: LocalizationKey.appManagementRequired.localized,
                actionTitle: .permissionOpenSettings,
                action: { Task { await environment.openAppManagementSettings() } }
            )
            Button {
                Task { await environment.recheckAppManagement() }
            } label: {
                Text(LocalizationKey.appManagementRecheck.localized)
                    .font(SiftFont.supporting)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .fixedSize()
            .accessibilityIdentifier("apps.appManagementRecheck")
        }
    }

    private var statusLine: String {
        LocalizationKey.appsStatus.localized(
            environment.installedApplications.count,
            staleApplicationCount
        )
    }

    private var staleApplicationCount: Int {
        environment.installedApplications.filter { $0.isUnused() }.count
    }

    // MARK: - Scopes

    /// What the list is showing.
    ///
    /// Every scope is a chip, so the list's own rule is visible before it is
    /// applied. The counts beside the titles are the rows each scope would show,
    /// which is what makes the default scope a statement rather than a surprise.
    private enum ApplicationFilter: String, CaseIterable, Identifiable {
        case all
        case large
        case unused

        var id: String { rawValue }

        /// The chip's own word, not the scan page's.
        ///
        /// These three scopes filtered applications and were labelled with the
        /// scan page's file vocabulary — "Large" and "Old" beside a list of
        /// `.app` bundles, which read as large *files* and old *files*. An
        /// application is large by its bundle and unused by its launch record,
        /// so it says so.
        var titleKey: LocalizationKey {
            switch self {
            case .all: .scanFilterAll
            case .large: .appsFilterLarge
            case .unused: .appsFilterUnused
            }
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizationKey.appsListTitle.localized)
                .font(SiftFont.sectionHeading)
                .foregroundStyle(SiftColor.mainText)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, SiftMetrics.spacingM)

            toolbar
            scopeBar
            SiftHairline()

            if environment.isLoadingApplications {
                VStack(spacing: SiftMetrics.spacingM) {
                    ForEach(0..<6, id: \.self) { index in
                        SiftSkeletonRow(isFirst: index == 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, SiftMetrics.spacingS)
            } else if filteredApplications.isEmpty {
                SiftEmptyState(
                    symbolName: search.isEmpty ? "shippingbox" : "magnifyingglass",
                    titleKey: search.isEmpty ? .uninstallNoneInstalled : .appsNoMatches
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApplications) { application in
                            appRow(application)
                            SiftHairline(inset: rowRuleInset)
                        }
                    }
                    .padding(.bottom, SiftMetrics.spacingS)
                }
                .frame(maxHeight: .infinity)
            }

            SiftHairline()
            listFooter
        }
        .padding(.trailing, SiftMetrics.spacingXL)
    }

    /// Where a row's rule starts: under the name, not under the icon.
    private var rowRuleInset: CGFloat {
        SiftMetrics.spacingM + 34 + SiftMetrics.spacingM
    }

    private var toolbar: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            searchField
            Spacer(minLength: SiftMetrics.spacingS)
            sortMenu
            rescanButton
        }
        .padding(.vertical, SiftMetrics.spacingM)
    }

    /// The scopes, as chips with the number of rows each would show.
    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SiftMetrics.spacingS) {
                ForEach(ApplicationFilter.allCases) { candidate in
                    SiftFilterChip(
                        title: candidate.titleKey.localized,
                        detail: SiftFormat.count(count(for: candidate)),
                        isSelected: filter == candidate
                    ) {
                        filter = candidate
                    }
                    .accessibilityIdentifier("apps.filter.\(candidate.rawValue)")
                }
            }
            .padding(.bottom, SiftMetrics.spacingM)
        }
    }

    private func count(for candidate: ApplicationFilter) -> Int {
        switch candidate {
        case .all:
            return search.isEmpty
                ? environment.installedApplications.count
                : searched(environment.installedApplications).count
        case .large:
            return search.isEmpty
                ? environment.installedApplications.filter { $0.sizeInBytes >= visibleSizeThreshold }.count
                : searched(environment.installedApplications).count
        case .unused:
            return searched(environment.installedApplications).filter { $0.isUnused() }.count
        }
    }

    private var searchField: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiftColor.secondaryText)
                .accessibilityHidden(true)
            TextField(LocalizationKey.uninstallSearch.localized, text: $search)
                .textFieldStyle(.plain)
                .font(SiftFont.body)
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .frame(height: SiftMetrics.fieldHeight)
        .siftFieldSurface()
        .accessibilityIdentifier("apps.search")
    }

    /// Re-runs discovery, because the list is discovered once and then kept.
    ///
    /// `loadApplications()` answers from memory while it holds a list, so an
    /// application installed — or removed by something other than Sift — while the
    /// app is open would never appear: the page looked like it had no way to look
    /// again. Invalidating first is what makes the second call a discovery instead
    /// of a no-op, and it is the same pair a completed uninstall uses.
    private var rescanButton: some View {
        Button {
            Task { await reloadApplications() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiftColor.secondaryText)
                .padding(.horizontal, SiftMetrics.spacingM)
                .frame(height: SiftMetrics.fieldHeight)
                .siftFieldSurface()
        }
        .buttonStyle(.plain)
        .disabled(environment.isLoadingApplications)
        .help(LocalizationKey.appsRescan.localized)
        .accessibilityLabel(Text(LocalizationKey.appsRescan.localized))
        .accessibilityIdentifier("apps.rescan")
        .fixedSize()
    }

    /// The order menu, grouped by attribute with both directions offered.
    ///
    /// Eight rows in one flat list read as eight unrelated orders; the divider
    /// between attributes is what makes "newest first" and "oldest first" a pair
    /// under "Install date" rather than two menu items that look alike. The
    /// current row carries a checkmark because a menu whose trigger states the
    /// order still has to say which of its own rows that is.
    private var sortMenu: some View {
        Menu {
            ForEach(ApplicationSortOrder.Axis.allCases, id: \.self) { axis in
                if axis != ApplicationSortOrder.Axis.allCases.first {
                    Divider()
                }
                ForEach(ApplicationSortOrder.allCases.filter { $0.axis == axis }, id: \.self) { order in
                    Button {
                        sort = order
                    } label: {
                        if order == sort {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(sort.titleKey.localized)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(SiftFont.supporting)
            .foregroundStyle(SiftColor.secondaryText)
            .padding(.horizontal, SiftMetrics.spacingM)
            .frame(height: SiftMetrics.fieldHeight)
            .siftFieldSurface()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("apps.sort")
    }

    private func appRow(_ application: InstalledApplication) -> some View {
        SiftSelectableRow(
            isSelected: selected?.id == application.id,
            action: {
                selected = application
                Task { await loadPlan() }
            }
        ) {
            HStack(spacing: SiftMetrics.spacingM) {
                ApplicationIcon(application: application, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(SiftFont.bodyEmphasis)
                        .foregroundStyle(SiftColor.mainText)
                        .lineLimit(1)
                    Text(launchLine(application))
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: SiftMetrics.spacingS)

                if application.isSystemApplication {
                    Text(LocalizationKey.uninstallSystemApp.localized)
                        .font(SiftFont.metadata)
                        .foregroundStyle(SiftColor.quietText)
                        .lineLimit(1)
                } else if application.isRunning {
                    Image(systemName: "play.circle")
                        .foregroundStyle(SiftColor.reviewTextColor)
                        .accessibilityLabel(
                            Text(LocalizationKey.uninstallAppRunning.localized(application.name))
                        )
                }

                Text(application.formattedSize)
                    .font(SiftFont.monospacedEmphasis)
                    .foregroundStyle(SiftColor.mainText)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("apps.row.\(application.id)")
    }

    /// What the row says under the name: the launch record, with its year.
    ///
    /// The row states the date the list can be sorted by, and it states which
    /// record it is. "Never opened" and "no open record" are different sentences
    /// because only one of them is a claim about use (invariant 47); the install
    /// date, the version and the bundle id live in the inspector, where there is
    /// room for all three without a row becoming two lines of metadata.
    private func launchLine(_ application: InstalledApplication) -> String {
        switch application.lastUsed {
        case let .known(date):
            return LocalizationKey.appsLastOpened.localized(SiftFormat.day(date))
        case .neverOpened:
            return LocalizationKey.appsNeverOpened.localized
        case .unavailable:
            return LocalizationKey.appsLastUsedUnknown.localized
        }
    }

    private func searched(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        guard !search.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredApplications: [InstalledApplication] {
        sort.sorted(inScope(searched(environment.installedApplications)))
    }

    /// The scope's own rule.
    ///
    /// A search is an explicit request, so the size default does not narrow it —
    /// that is the one relaxation this page has always made, and it stays. The
    /// unused scope is a claim about launches and is not relaxed by typing.
    private func inScope(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        switch filter {
        case .all:
            return applications
        case .large:
            guard search.isEmpty else { return applications }
            return applications.filter { $0.sizeInBytes >= visibleSizeThreshold }
        case .unused:
            return applications.filter { $0.isUnused() }
        }
    }

    private var hiddenApplicationCount: Int {
        guard search.isEmpty else { return 0 }
        return max(environment.installedApplications.count - filteredApplications.count, 0)
    }

    /// The list's footer says what the list is actually showing: a search
    /// result, a scope, or the full inventory.
    private var footerCaption: String {
        let total = environment.installedApplications.count
        if !search.isEmpty {
            return LocalizationKey.commonItemCount.counted(filteredApplications.count)
        }
        switch filter {
        case .all:
            return LocalizationKey.commonItemCount.counted(total)
        case .large:
            return LocalizationKey.appsFooter.localized(total)
        case .unused:
            return LocalizationKey.commonItemCount.counted(filteredApplications.count)
        }
    }

    /// The rows' own footprint, so the list keeps the one number the "Sorted by"
    /// sentence used to carry. It describes what is on screen, not the disk.
    private var shownBytes: String {
        SiftFormat.bytes(filteredApplications.reduce(Int64(0)) { $0 + $1.sizeInBytes })
    }

    private var listFooter: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Text(footerCaption)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
            Text(shownBytes)
                .font(SiftFont.metadata)
                .monospacedDigit()
                .foregroundStyle(SiftColor.quietText)
            Spacer(minLength: SiftMetrics.spacingS)
            if hiddenApplicationCount > 0 {
                Button {
                    filter = .all
                } label: {
                    Text(LocalizationKey.overviewShowAll.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("apps.showAll")
            }
        }
        .frame(minHeight: SiftMetrics.minimumHitTarget, alignment: .center)
    }

    // MARK: - Inspector

    private var paneRule: some View {
        Rectangle()
            .fill(SiftColor.divider)
            .frame(width: SiftMetrics.panelBorderWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var inspector: some View {
        if let application = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                    applicationHeader(application)

                    notices(for: application)

                    if isLoadingPlan {
                        SiftSkeletonRow()
                            .frame(height: SiftMetrics.rowHeightTwoLine)
                    } else if let plan {
                        reclaimableBlock(plan)
                        SiftHairline()
                        relatedFilesSection(plan)
                    } else {
                        SiftEmptyState(
                            symbolName: "questionmark.folder",
                            titleKey: .uninstallSelectApp
                        )
                    }
                }
                .padding(.leading, SiftMetrics.spacingXL)
                .padding(.trailing, SiftMetrics.spacingM)
                .padding(.top, SiftMetrics.spacingL)
                .padding(.bottom, SiftMetrics.spacingXXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isLoadingPlan, let plan {
                    uninstallButton(plan)
                        .padding(.leading, SiftMetrics.spacingXL)
                        .padding(.trailing, SiftMetrics.spacingM)
                        .padding(.vertical, SiftMetrics.spacingM)
                        .background(SiftColor.canvasSurface)
                }
            }
        } else {
            SiftEmptyState(
                symbolName: "questionmark.folder",
                titleKey: .uninstallSelectApp
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, SiftMetrics.spacingXL)
        }
    }

    @ViewBuilder
    private func notices(for application: InstalledApplication) -> some View {
        if application.isSystemApplication {
            NoticeBanner(level: .information, titleKey: .uninstallSystemAppDetail)
        }
        if application.isRunning {
            NoticeBanner(
                level: .warning,
                message: LocalizationKey.uninstallAppRunning.localized(application.name),
                actionTitle: .commonQuitApp
            ) {
                Task { await quit(application) }
            }
        }
        if let refusalMessage {
            NoticeBanner(level: .warning, message: refusalMessage)
        }
        if let quitFailure {
            NoticeBanner(level: .error, message: quitFailure)
        }
    }

    /// The application's identity: what it is, which build, and the two dates.
    ///
    /// Both dates are stated, and both carry their year (`SiftFormat.day`), because
    /// they are two different records — when the item arrived and when it was last
    /// opened — and the page used to print one of them twice. They are read
    /// against one another here, which is why the relative form is not used
    /// (invariant 47).
    private func applicationHeader(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
                ApplicationIcon(application: application, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(SiftFont.sectionHeading)
                        .foregroundStyle(SiftColor.mainText)
                        .lineLimit(2)
                    if let version = application.version {
                        Text(version)
                            .font(SiftFont.monospacedNumber)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(
                    LocalizationKey.appsInstalledOn.localized(
                        application.formattedInstalledAt
                    )
                )
                Text(application.formattedLastUsed)
                Text(application.bundleIdentifier)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(SiftFont.supporting)
            .foregroundStyle(SiftColor.secondaryText)
        }
        .accessibilityElement(children: .contain)
    }

    /// The number the action is about: the application plus the related files
    /// Sift is confident about. The review files are counted separately and only
    /// when the user opts in.
    private func reclaimableBlock(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            // Sentence case, no tracking — `01` retires the all-caps eyebrow.
            Text(LocalizationKey.appsReclaimable.localized)
                .font(SiftFont.eyebrow)
                .foregroundStyle(SiftColor.actionGreen)

            Text(plan.formattedTotal(includeReviewFiles: includeReviewFiles))
                .font(SiftFont.pageTitle)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
                .contentTransition(.numericText())

            Text(
                LocalizationKey.appsAppAndRelated.localized(
                    plan.formattedApplicationSize,
                    plan.formattedRelatedSize(includeReviewFiles: includeReviewFiles)
                )
            )
            .font(SiftFont.supporting)
            .foregroundStyle(SiftColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func relatedFilesSection(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.appsRelatedWillRemove.localized)
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.mainText)

            if plan.confirmedFiles.isEmpty, plan.reviewFiles.isEmpty {
                Text(LocalizationKey.uninstallNoRelatedFiles.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.secondaryText)
            }

            ForEach(plan.confirmedFiles) { file in
                relatedFileRow(file, isEnabled: true)
            }

            if !plan.reviewFiles.isEmpty {
                // Two claims, kept apart: what the page is confident about is
                // already in the list, and what needs a decision sits under its
                // own control. A review file is never removed because it was
                // listed — only because the user said so.
                reviewGroup(plan)
            }
        }
    }

    @ViewBuilder
    private func reviewGroup(_ plan: UninstallPlan) -> some View {
        SiftHairline()
            .padding(.vertical, SiftMetrics.spacingXS)

        HStack(spacing: SiftMetrics.spacingS) {
            SiftCheckbox(isOn: $includeReviewFiles)
                .accessibilityLabel(Text(LocalizationKey.uninstallNeedsReview.localized))
            Text(LocalizationKey.uninstallNeedsReview.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.reviewTextColor)
                .onTapGesture { includeReviewFiles.toggle() }
            Spacer(minLength: 0)
            Text(LocalizationKey.commonItemCount.counted(plan.reviewFiles.count))
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.quietText)
        }

        ForEach(plan.reviewFiles) { file in
            relatedFileRow(file, isEnabled: includeReviewFiles)
        }
    }

    private func relatedFileRow(_ file: RelatedFile, isEnabled: Bool) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
            Image(systemName: file.confidence == .confirmed ? "checkmark.circle" : "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(
                    file.confidence == .confirmed
                        ? SiftColor.safeTextColor
                        : SiftColor.reviewTextColor
                )
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.displayPath)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.confidence == .needsReview {
                    Text(file.reason.titleKey.localized)
                        .font(SiftFont.metadata)
                        .foregroundStyle(SiftColor.reviewTextColor)
                        .lineLimit(2)
                        // The group id is what the entitlement actually says. It is
                        // not printed as a second line because the container's own
                        // name *is* the group — repeating it would be noise — but
                        // it is the string the user can check against
                        // `codesign -d --entitlements`, so it belongs on the row's
                        // hover instead of nowhere.
                        .help(file.groupIdentifier ?? file.reason.titleKey.localized)
                }
                // A group container can be shared by several applications of one
                // team; removing it with this one takes data the others still use.
                // The names come from LaunchServices, so the row states a fact
                // rather than a suspicion.
                if !file.sharedWith.isEmpty {
                    Text(
                        LocalizationKey.uninstallSharedContainer
                            .localized(file.sharedWith.joined(separator: ", "))
                    )
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.reviewTextColor)
                    .lineLimit(2)
                }
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(file.formattedSize)
                .font(SiftFont.supporting)
                .monospacedDigit()
                .foregroundStyle(isEnabled ? SiftColor.secondaryText : SiftColor.quietText)
        }
        .padding(.vertical, SiftMetrics.spacingXS)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        // The same two actions the row can offer, and the group id as something
        // the user can take away: it is the string they can check against
        // `codesign -d --entitlements`, and a tooltip is not copyable.
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label(
                    LocalizationKey.filesRevealInFinder.localized,
                    systemImage: "folder"
                )
            }
            if let group = file.groupIdentifier {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(group, forType: .string)
                } label: {
                    Label(
                        LocalizationKey.uninstallCopyGroupIdentifier.localized,
                        systemImage: "doc.on.doc"
                    )
                }
            }
        }
    }

    private func uninstallButton(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            SiftPrimaryButton(
                title: LocalizationKey.appsUninstallAndClean.localized(
                    plan.formattedTotal(includeReviewFiles: includeReviewFiles)
                ),
                isEnabled: !plan.application.isSystemApplication
                    && !environment.cleanup.isWorking
                    && !environment.isPerformingFileOperation
            ) {
                Task { await requestUninstall(plan) }
            }
            .frame(maxWidth: .infinity)

            Text(LocalizationKey.appsRestoreHint.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.quietText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var uninstallConfirmation: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            Text(LocalizationKey.cleanupConfirmTitle.localized)
                .font(SiftFont.pageTitle)
                .foregroundStyle(SiftColor.mainText)
            if let plan {
                Text(
                    LocalizationKey.appsUninstallAndClean.localized(
                        plan.application.name
                    )
                )
                .font(SiftFont.bodyEmphasis)
                .foregroundStyle(SiftColor.mainText)
            }
            if let preparedSummary {
                Text(
                    "\(LocalizationKey.commonItemCount.counted(preparedSummary.count)) · \(preparedSummary.formattedBytes)"
                )
                .font(SiftFont.body)
                .monospacedDigit()
                .foregroundStyle(SiftColor.secondaryText)
            }
            if let refused = preparedSummary?.refused, !refused.isEmpty {
                Text(LocalizationKey.cleanupConfirmProtectedCount.localized(refused.count))
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.reviewTextColor)
            }
            NoticeBanner(level: .information, titleKey: .cleanupConfirmUndoNotice)
            HStack {
                Spacer()
                SiftSecondaryButton(titleKey: .cleanupConfirmCancel) {
                    isConfirming = false
                }
                .keyboardShortcut(.cancelAction)

                SiftPrimaryButton(
                    title: LocalizationKey.appsUninstallAndClean.localized(
                        plan?.application.name ?? ""
                    )
                ) {
                    isConfirming = false
                    Task { await performUninstall() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("uninstaller.confirm")
            }
        }
        .padding(SiftMetrics.spacingXL)
        .frame(width: 480)
        .background(SiftColor.canvasSurface)
    }

    // MARK: - Result

    private func outcomeView(_ outcome: CleanupOutcome) -> some View {
        ScrollView {
            SiftSection(style: .floating, padding: 0, cornerRadius: SiftMetrics.cornerRadiusL) {
                CleanupResultView(
                    outcome: outcome,
                    report: outcomeReport,
                    onAcknowledge: {
                        self.outcome = nil
                        self.outcomeReport = nil
                    },
                    onExport: {
                        Task {
                            guard await environment.canExportReports() else {
                                onRequestPurchase()
                                return
                            }
                            if let report = outcomeReport {
                                await environment.exportReport(report)
                            }
                        }
                    },
                    onOpenTrash: { Task { await environment.openTrash() } },
                    loadTrash: { await environment.trashSnapshot() },
                    onEmptyTrash: { snapshot in await environment.emptyTrashGated(snapshot) },
                    onRevealFailed: { url in Task { await environment.reveal(url) } },
                    // The page's own advice — grant App Management, quit the
                    // application — used to end there: acting on it meant
                    // finding the application again and starting over.
                    onRetryFailed: { results in
                        Task {
                            switch await environment.retryUninstall(results) {
                            case let .executed(execution):
                                self.outcome = execution.outcome
                                self.outcomeReport = execution.report
                            case .purchaseRequired:
                                onRequestPurchase()
                            case .busy, .nothingToDo, .awaitingConfirmation:
                                break
                            }
                        }
                    },
                    onRequestPurchase: onRequestPurchase,
                    statusMessage: environment.reportExportMessage
                )
                .padding(SiftMetrics.spacingXL)
            }
            .frame(maxWidth: 820)
            .padding(SiftMetrics.spacingXXL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadPlan() async {
        guard let application = selected else { return }
        isLoadingPlan = true
        defer { isLoadingPlan = false }

        // Measuring a related directory walks the whole tree. Doing that on the
        // main actor froze the page before it could show the loading state.
        let discovery = environment.applications
        let requestedID = application.id
        let measuredPlan = await Task.detached(priority: .userInitiated) {
            discovery.relatedFiles(for: application)
        }.value

        // A second selection while the first was being measured must not show
        // the previous application's files under the new one.
        guard selected?.id == requestedID else { return }
        plan = measuredPlan
        includeReviewFiles = false
        quitFailure = nil
    }

    /// Asks the running application to quit, reporting a request that could not
    /// be sent instead of pretending the button did something.
    private func quit(_ application: InstalledApplication) async {
        quitFailure = nil
        guard await environment.quitApplication(application.url) else {
            quitFailure = LocalizationKey.uninstallQuitFailed.localized(application.name)
            return
        }
    }

    private func requestUninstall(_ plan: UninstallPlan) async {
        // The uninstaller asks with the capability the operation itself is
        // gated on, not the generic cleanup one.
        guard await environment.canUninstall() else {
            onRequestPurchase()
            return
        }
        let items = plan.selectedItems(includeReviewFiles: includeReviewFiles)
        // Pre-flight first, panel second: the list the user is asked to approve
        // is the list pre-flight approved. The panel used to be shown before
        // anything was judged, so an application launched since the plan was
        // built — or a related file that had gone — made the batch differ from
        // the one on screen.
        switch await environment.prepareUninstall(items: items) {
        case let .ready(preparation):
            preparedSummary = preparation
            isConfirming = true
        case let .nothingToDo(preparation):
            preparedSummary = preparation
            refusalMessage = preparation.refused.first?.failureTitle
        case .purchaseRequired:
            onRequestPurchase()
        case .busy:
            refusalMessage = nil
        }
    }

    /// Discovers the installed applications again, from scratch.
    ///
    /// One function for the two places that ask for a fresh list — the control in
    /// the list toolbar and a completed uninstall — so a refresh cannot mean one
    /// thing here and another there.
    private func reloadApplications() async {
        environment.invalidateApplications()
        await environment.loadApplications(force: true)
    }

    private func performUninstall() async {
        let result = await environment.confirmUninstall()
        switch result {
        case let .executed(execution):
            outcome = execution.outcome
            outcomeReport = execution.report
            await reloadApplications()
            selected = nil
            self.plan = nil
        case .purchaseRequired:
            onRequestPurchase()
        case .nothingToDo, .busy, .awaitingConfirmation:
            break
        }
        preparedSummary = nil
    }
}

/// The application's own icon.
///
/// The generic SF Symbol made every row look the same; the Finder icon is the
/// one thing a user recognises before reading the name.
struct ApplicationIcon: View {
    let application: InstalledApplication
    var size: CGFloat = SiftMetrics.iconTileSize

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
