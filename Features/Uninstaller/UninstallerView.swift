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
    @State private var sort: SortOrder = .size
    @State private var selected: InstalledApplication?
    @State private var plan: UninstallPlan?
    @State private var isLoadingPlan = false
    @State private var isConfirming = false
    @State private var outcome: CleanupOutcome?
    @State private var includeReviewFiles = false
    @State private var quitFailure: String?
    @State private var showsAllApps = false

    /// How the application list is ordered (§5.3).
    enum SortOrder: String, CaseIterable {
        case name
        case size
        case lastUsed

        var titleKey: LocalizationKey {
            switch self {
            case .name: .uninstallSortName
            case .size: .uninstallSortSize
            case .lastUsed: .uninstallSortLastUsed
            }
        }
    }

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
                    value: LocalizationKey.commonItemCount.localized(environment.installedApplications.count),
                    tint: SiftColor.accent
                )
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

    private var statusLine: String {
        LocalizationKey.appsStatus.localized(
            environment.installedApplications.count,
            staleApplicationCount
        )
    }

    private var staleApplicationCount: Int {
        let cutoff = Date().addingTimeInterval(-180 * 86_400)
        return environment.installedApplications.filter {
            !$0.isSystemApplication && ($0.lastUsedAt ?? .distantPast) < cutoff
        }.count
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
                            SiftFormat.bytes(environment.installedApplications.reduce(0) { $0 + $1.sizeInBytes })
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, SiftMetrics.spacingM)

                HStack(spacing: SiftMetrics.spacingM) {
                    searchField
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
        .frame(height: 34)
        .background(
            Capsule().fill(Color.white.opacity(0.045))
        )
        .overlay {
            Capsule().strokeBorder(SiftColor.glassBorder, lineWidth: 1)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button {
                    sort = order
                } label: {
                    Text(order.titleKey.localized)
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
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.045)))
            .overlay {
                Capsule().strokeBorder(SiftColor.glassBorder, lineWidth: 1)
            }
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

    private func secondaryLine(_ application: InstalledApplication) -> String {
        let version = application.version ?? LocalizationKey.commonNotAvailable.localized
        let lastUsed: String
        if let date = application.lastUsedAt {
            lastUsed = LocalizationKey.appsLastOpened.localized(SiftFormat.relativeDate(date))
        } else {
            lastUsed = LocalizationKey.appsNeverOpened.localized
        }
        return "\(version) · \(lastUsed)"
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
        switch sort {
        case .name:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return matching.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .lastUsed:
            return matching.sorted {
                ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
        }
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
            return LocalizationKey.commonItemCount.localized(filteredApplications.count)
        }
        if showsAllApps {
            return LocalizationKey.commonItemCount.localized(total)
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
                .tracking(0.6)
                .foregroundStyle(SiftColor.accent)

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
    }

    private func uninstallButton(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            SiftPrimaryButton(
                title: LocalizationKey.appsUninstallAndClean.localized(
                    plan.formattedTotal(includeReviewFiles: includeReviewFiles)
                ),
                isEnabled: !plan.application.isSystemApplication && !environment.cleanup.isWorking
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
                        plan.formattedTotal(includeReviewFiles: includeReviewFiles)
                    )
                    + " · " + plan.application.name
                )
                .font(SiftFont.bodyEmphasis)
                NoticeBanner(level: .information, titleKey: .cleanupConfirmUndoNotice)
            }
            HStack {
                Spacer()
                Button { isConfirming = false } label: {
                    Text(LocalizationKey.cleanupConfirmCancel.localized)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    isConfirming = false
                    Task { await performUninstall() }
                } label: {
                    Text(LocalizationKey.cleanupConfirmTitle.localized)
                }
                .buttonStyle(.borderedProminent)
                .tint(SiftColor.accent)
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
                    report: nil as CleanupReport?,
                    onAcknowledge: { self.outcome = nil },
                    onExport: {},
                    onOpenTrash: { Task { await environment.openTrash() } },
                    onRevealFailed: { url in Task { await environment.reveal(url) } },
                    onRequestPurchase: onRequestPurchase,
                    statusMessage: nil
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
        guard await environment.canClean() else {
            onRequestPurchase()
            return
        }
        isConfirming = true
    }

    private func performUninstall() async {
        guard let plan else { return }
        let items = plan.selectedItems(includeReviewFiles: includeReviewFiles)
        let candidates = items.map(FileOperationService.Candidate.init(item:))
        let preflight = await environment.operations.preflight(candidates)
        let result = await environment.operations.moveToTrash(
            preflight.ready,
            categoryTotals: [
                CategoryTotal(
                    category: .applicationResidue,
                    itemCount: preflight.ready.count,
                    totalBytes: preflight.ready.reduce(0) { $0 + $1.sizeInBytes }
                )
            ],
            operation: .uninstall,
            // Whatever the pre-flight refused — the running application, a
            // related file that is already gone — is reported on the result page
            // with its reason instead of disappearing from the batch.
            refusedByPreflight: preflight.refusedResults
        )
        outcome = result
        RecentHistory.recordCleanup(result)
        environment.invalidateApplications()
        await environment.loadApplications(force: true)
        selected = nil
        self.plan = nil
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
