import Core
import Shared
import SwiftUI

/// The uninstaller (§5.3).
///
/// Left column: installed applications with search and sorting. Right column:
/// the selected application and its related files, split into the ones Sift is
/// confident about and the ones the user must confirm.
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

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcome {
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
            } else {
                header
                Divider()
                HStack(spacing: 0) {
                    applicationList
                        .frame(width: 320)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task { await environment.loadApplications() }
        .sheet(isPresented: $isConfirming) {
            uninstallConfirmation
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizationKey.uninstallTitle.localized)
                    .font(SiftFont.display)
                Text(
                    LocalizationKey.commonItemCount.localized(environment.installedApplications.count)
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(String(), selection: $sort) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.titleKey.localized).tag(order)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(SiftMetrics.spacingXL)
    }

    private var filteredApplications: [InstalledApplication] {
        let matching = search.isEmpty
            ? environment.installedApplications
            : environment.installedApplications.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
            }
        switch sort {
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return matching.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .lastUsed:
            return matching.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(LocalizationKey.uninstallSearch.localized, text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(SiftMetrics.spacingM)

            Divider()

            if environment.isLoadingApplications {
                ProgressView(LocalizationKey.commonLoading.localized)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApplications.isEmpty {
                SiftEmptyState(symbolName: "shippingbox", titleKey: .uninstallNoneInstalled)
            } else {
                List(selection: Binding(
                    get: { selected?.id },
                    set: { id in
                        selected = filteredApplications.first { $0.id == id }
                        Task { await loadPlan() }
                    }
                )) {
                    ForEach(filteredApplications) { application in
                        ApplicationRow(application: application)
                            .tag(application.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let application = selected {
            ScrollView {
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
                    } else if let plan {
                        relatedFilesSection(plan)
                        uninstallButton(plan)
                    }
                }
                .padding(SiftMetrics.spacingXL)
                .frame(maxWidth: 640, alignment: .leading)
            }
        } else {
            SiftEmptyState(
                symbolName: "questionmark.folder",
                titleKey: .uninstallSelectApp
            )
        }
    }

    private func applicationHeader(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack(spacing: SiftMetrics.spacingM) {
                IconTile(symbolName: "app", tint: SiftColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(SiftFont.title)
                    Text(LocalizationKey.uninstallBundleId.localized(application.bundleIdentifier))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: SiftMetrics.spacingL) {
                labeledValue(.uninstallVersion, application.version ?? LocalizationKey.commonNotAvailable.localized)
                labeledValue(.commonSize, application.formattedSize)
                labeledValue(.uninstallSortLastUsed, application.formattedLastUsed)
            }
        }
    }

    private func labeledValue(_ key: LocalizationKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(SiftFont.bodyEmphasis)
        }
        .accessibilityElement(children: .combine)
    }

    private func relatedFilesSection(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            Text(LocalizationKey.uninstallRelatedFiles.localized)
                .font(SiftFont.sectionTitle)

            if plan.confirmedFiles.isEmpty, plan.reviewFiles.isEmpty {
                Text(LocalizationKey.uninstallNoRelatedFiles.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
            }

            if !plan.confirmedFiles.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.uninstallConfirmedRelated.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.safe)
                        ForEach(plan.confirmedFiles) { file in
                            RelatedFileRow(file: file)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !plan.reviewFiles.isEmpty {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                    Toggle(isOn: $includeReviewFiles) {
                        Text(LocalizationKey.uninstallNeedsReview.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.review)
                    }
                    .toggleStyle(.checkbox)
                    ForEach(plan.reviewFiles) { file in
                        RelatedFileRow(file: file, showSelection: includeReviewFiles)
                    }
                }
            }

            HStack(spacing: SiftMetrics.spacingL) {
                labeledValue(.uninstallAppSize, plan.formattedApplicationSize)
                labeledValue(.uninstallRelatedSize, plan.formattedRelatedSize(includeReviewFiles: includeReviewFiles))
                labeledValue(.uninstallTotalSize, plan.formattedTotal(includeReviewFiles: includeReviewFiles))
            }
        }
    }

    private func uninstallButton(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            Button {
                Task { await requestUninstall(plan) }
            } label: {
                Text(LocalizationKey.uninstallUninstallButton.localized(plan.application.name))
                    .font(SiftFont.bodyEmphasis)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(plan.application.isSystemApplication)
            Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var uninstallConfirmation: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            Text(LocalizationKey.cleanupConfirmTitle.localized)
                .font(SiftFont.title)
            if let plan {
                Text(
                    LocalizationKey.uninstallUninstallButton.localized(plan.application.name)
                        + " · " + plan.formattedTotal(includeReviewFiles: includeReviewFiles)
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
            }
        }
        .padding(SiftMetrics.spacingXL)
        .frame(width: 460)
    }

    private func loadPlan() async {
        guard let application = selected else { return }
        isLoadingPlan = true
        plan = environment.applications.relatedFiles(for: application)
        isLoadingPlan = false
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

/// One row in the application list.
struct ApplicationRow: View {
    let application: InstalledApplication

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            IconTile(
                symbolName: application.isSystemApplication ? "lock.fill" : "app",
                tint: application.isSystemApplication ? SiftColor.neutral : SiftColor.accent
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(application.name)
                    .font(SiftFont.body)
                    .lineLimit(1)
                Text(application.formattedSize)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            if application.isSystemApplication {
                Text(LocalizationKey.uninstallSystemApp.localized)
                    .font(SiftFont.badge)
                    .foregroundStyle(.secondary)
            } else if application.isRunning {
                Image(systemName: "play.circle")
                    .foregroundStyle(SiftColor.review)
                    .accessibilityLabel(Text(LocalizationKey.uninstallAppRunning.localized(application.name)))
            }
        }
        .padding(.vertical, 2)
    }
}

/// One related file row.
struct RelatedFileRow: View {
    let file: RelatedFile
    var showSelection: Bool = true

    var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: showSelection ? "checkmark.circle" : "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(file.confidence == .confirmed ? SiftColor.safe : SiftColor.review)
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
                // The match is shown where the user has to judge it. A confirmed
                // file is one macOS names after the application itself, so the
                // sentence would read the same on every row of that list; a file
                // needing review is the case §5.3 asks the reason for.
                if file.confidence == .needsReview {
                    Text(file.reason.titleKey.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.review)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(file.formattedSize)
                .font(SiftFont.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(file.displayName))
        .accessibilityValue(Text(file.formattedSize))
    }
}
