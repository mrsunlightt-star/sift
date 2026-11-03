import AppKit
import Core
import Shared
import SwiftUI

/// The uninstaller (§5.3), presented as the Apps page.
///
/// Left: the installed applications, with search and sorting. Right: the
/// selected application, what belongs to it, and the one action that removes it.
/// The page is the only place an application is uninstalled; the scan page never
/// offers that, because removing an application is not a cleanup item.
public struct UninstallerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    @State private var search = ""
    @State private var sort: ApplicationSortOrder = .largestFirst
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
    @State private var showsAllApps = false

    /// The list starts with the applications that are worth removing. A 12 MB
    /// helper is not what this page is for, and showing 128 rows of them buries
    /// the ones that matter.
    private let visibleSizeThreshold: Int64 = 200 * 1024 * 1024

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
                    value: LocalizationKey.commonItemCount.counted(environment.installedApplications.count),
                    tone: .accent
                )
            }

            if environment.appManagement == .denied {
                appManagementNotice
                    .padding(.horizontal, SiftMetrics.pagePadding)
                    .padding(.top, SiftMetrics.pageSpacing)
                    .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
            }

            HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                applicationListCard
                    .frame(maxHeight: .infinity)
                detailPane
                    .frame(width: SiftMetrics.summaryColumnWidth)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.pageSpacing)
            .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
                    .font(SiftFont.caption)
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

    // MARK: - List

    private var applicationListCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                    Text(LocalizationKey.appsListTitle.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer(minLength: SiftMetrics.spacingS)
                    Text(
                        LocalizationKey.appsSortSummary.localized(
                            sort.title,
                            SiftFormat.bytes(environment.installedApplications.reduce(0) { $0 + $1.sizeInBytes })
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, SiftMetrics.spacingM)

                HStack(spacing: SiftMetrics.spacingM) {
                    searchField
                    rescanButton
                    sortMenu
                }
                .padding(.bottom, SiftMetrics.spacingM)

                Divider()

                if environment.isLoadingApplications {
                    ProgressView(LocalizationKey.commonLoading.localized)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredApplications.isEmpty {
                    SiftEmptyState(symbolName: "shippingbox", titleKey: .uninstallNoneInstalled)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredApplications) { application in
                                appRow(application)
                            }
                        }
                        .padding(.vertical, SiftMetrics.spacingS)
                    }
                    .frame(maxHeight: .infinity)
                }

                Divider()

                HStack(spacing: SiftMetrics.spacingM) {
                    Text(footerCaption)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: SiftMetrics.spacingS)
                    if hiddenApplicationCount > 0 {
                        Button {
                            showsAllApps = true
                        } label: {
                            Text(LocalizationKey.overviewShowAll.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                }
                .padding(.top, SiftMetrics.spacingM)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(LocalizationKey.uninstallSearch.localized, text: $search)
                .textFieldStyle(.plain)
                .font(SiftFont.body)
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .frame(height: SiftMetrics.fieldHeight)
        .siftFieldSurface()
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
                .foregroundStyle(.secondary)
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
            .font(SiftFont.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SiftMetrics.spacingM)
            .frame(height: SiftMetrics.fieldHeight)
            .siftFieldSurface()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                        .lineLimit(1)
                    Text(secondaryLine(application))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: SiftMetrics.spacingS)

                if application.isSystemApplication {
                    Text(LocalizationKey.uninstallSystemApp.localized)
                        .font(SiftFont.badge)
                        .foregroundStyle(.secondary)
                } else if application.isRunning {
                    Image(systemName: "play.circle")
                        .foregroundStyle(SiftColor.review)
                        .accessibilityLabel(
                            Text(LocalizationKey.uninstallAppRunning.localized(application.name))
                        )
                }

                Text(application.formattedSize)
                    .font(SiftFont.bodyEmphasis)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("apps.row.\(application.id)")
    }

    /// What the row says under the name.
    ///
    /// Both dates are always stated, not only the one the list is ordered by. They
    /// are two different records — the bundle's birth time and the launch
    /// LaunchServices wrote — and the page showed them as one number because it
    /// read one record twice. A row that prints both makes the independence
    /// visible, and it is what lets a person see that an application installed
    /// four days ago was opened this morning.
    ///
    /// The launch record is stated as what it is: a recorded date, "never opened"
    /// when the system holds the bundle and no launch, and "no open record" when
    /// the system holds no record of the bundle at all. The last two are not the
    /// same sentence, because only one of them is a claim about use.
    private func secondaryLine(_ application: InstalledApplication) -> String {
        let version = application.version ?? LocalizationKey.commonNotAvailable.localized
        let installed = application.installedAt.map {
            LocalizationKey.appsInstalledOn.localized(SiftFormat.day($0))
        } ?? LocalizationKey.commonNotAvailable.localized
        let lastUsed: String
        switch application.lastUsed {
        case let .known(date):
            lastUsed = LocalizationKey.appsLastOpened.localized(SiftFormat.day(date))
        case .neverOpened:
            lastUsed = LocalizationKey.appsNeverOpened.localized
        case .unavailable:
            lastUsed = LocalizationKey.appsLastUsedUnknown.localized
        }
        return "\(version), \(installed), \(lastUsed)"
    }

    private var filteredApplications: [InstalledApplication] {
        var matching = search.isEmpty
            ? environment.installedApplications
            : environment.installedApplications.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
            }
        // The size filter is a default for the unfiltered list. A search is an
        // explicit request, so every match is shown whatever its size.
        if !showsAllApps, search.isEmpty {
            matching = matching.filter { $0.sizeInBytes >= visibleSizeThreshold }
        }
        return sort.sorted(matching)
    }

    private var hiddenApplicationCount: Int {
        guard !showsAllApps, search.isEmpty else { return 0 }
        return environment.installedApplications.filter {
            $0.sizeInBytes < visibleSizeThreshold
        }.count
    }

    /// The list's footer says what the list is actually showing: a search
    /// result, the full list, or the default size-filtered list.
    private var footerCaption: String {
        let total = environment.installedApplications.count
        if !search.isEmpty {
            return LocalizationKey.commonItemCount.counted(filteredApplications.count)
        }
        if showsAllApps {
            return LocalizationKey.commonItemCount.counted(total)
        }
        return LocalizationKey.appsFooter.localized(total)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let application = selected {
            SiftGlassCard(padding: SiftMetrics.spacingL) {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                    applicationHeader(application)

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

                    if isLoadingPlan {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let plan {
                        ScrollView {
                            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                                reclaimableBlock(plan)
                                relatedFilesSection(plan)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: .infinity)

                        uninstallButton(plan)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            SiftGlassCard(padding: SiftMetrics.spacingL) {
                SiftEmptyState(
                    symbolName: "questionmark.folder",
                    titleKey: .uninstallSelectApp
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func applicationHeader(_ application: InstalledApplication) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            ApplicationIcon(application: application, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .font(SiftFont.title)
                    .lineLimit(2)
                Text(secondaryLine(application))
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(application.bundleIdentifier)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    /// The big number in the detail column: the application plus the related
    /// files Sift is confident about. The review files are counted separately and
    /// only when the user opts in.
    private func reclaimableBlock(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.appsReclaimable.localized)
                .font(SiftFont.eyebrow)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(SiftColor.accentText)

            Text(plan.formattedTotal(includeReviewFiles: includeReviewFiles))
                .font(SiftFont.metricLarge)
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(
                LocalizationKey.appsAppAndRelated.localized(
                    plan.formattedApplicationSize,
                    plan.formattedRelatedSize(includeReviewFiles: includeReviewFiles)
                )
            )
            .font(SiftFont.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, SiftMetrics.spacingXS)

            Text(LocalizationKey.appsRelatedWillRemove.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relatedFilesSection(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            if plan.confirmedFiles.isEmpty, plan.reviewFiles.isEmpty {
                Text(LocalizationKey.uninstallNoRelatedFiles.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
            }

            ForEach(plan.confirmedFiles) { file in
                relatedFileRow(file, isEnabled: true)
            }

            if !plan.reviewFiles.isEmpty {
                Divider()
                    .padding(.vertical, SiftMetrics.spacingXS)
                Toggle(isOn: $includeReviewFiles) {
                    Text(LocalizationKey.uninstallNeedsReview.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.review)
                }
                .toggleStyle(.checkbox)
                ForEach(plan.reviewFiles) { file in
                    relatedFileRow(file, isEnabled: includeReviewFiles)
                }
            }
        }
    }

    private func relatedFileRow(_ file: RelatedFile, isEnabled: Bool) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
            Image(systemName: file.confidence == .confirmed ? "checkmark.circle" : "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(file.confidence == .confirmed ? SiftColor.safe : SiftColor.review)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(SiftFont.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.displayPath)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.confidence == .needsReview {
                    Text(file.reason.titleKey.localized)
                        .font(SiftFont.badge)
                        .foregroundStyle(SiftColor.review)
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
                    .font(SiftFont.badge)
                    .foregroundStyle(SiftColor.review)
                    .lineLimit(2)
                }
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(file.formattedSize)
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
        }
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
            Text(LocalizationKey.appsRestoreHint.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.top, SiftMetrics.spacingS)
    }

    private var uninstallConfirmation: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            Text(LocalizationKey.cleanupConfirmTitle.localized)
                .font(SiftFont.title)
            if let plan {
                Text(
                    LocalizationKey.appsUninstallAndClean.localized(
                        plan.application.name
                    )
                )
                .font(SiftFont.bodyEmphasis)
            }
            if let preparedSummary {
                Text(
                    "\(LocalizationKey.commonItemCount.counted(preparedSummary.count)) · \(preparedSummary.formattedBytes)"
                )
                .font(SiftFont.body)
                .monospacedDigit()
            }
            if let refused = preparedSummary?.refused, !refused.isEmpty {
                Text(LocalizationKey.cleanupConfirmProtectedCount.localized(refused.count))
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.textColor(for: .review))
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
        .background(SiftColor.canvas)
    }

    // MARK: - Result

    private func outcomeView(_ outcome: CleanupOutcome) -> some View {
        ScrollView {
            SiftGlassCard(surface: .floating, padding: 0) {
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
    /// the list header and a completed uninstall — so a refresh cannot mean one
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
