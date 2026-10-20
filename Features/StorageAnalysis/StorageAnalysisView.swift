import Core
import Shared
import SwiftUI

/// The storage page (§5.4).
///
/// It answers the three questions the specification names — which kind of file
/// takes the most space, which folders are largest, which files to handle first —
/// and the system-diagnostics questions that turn out to be the same question:
/// which of it is an index, a snapshot or system data, whether it can be rebuilt,
/// and how much of the answer could not be read.
///
/// One page and one analysis button on purpose. Two pages answering "what is
/// using my disk" from two engines is how the numbers end up disagreeing.
public struct StorageAnalysisView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// The session state lives in `AppEnvironment`, so returning to this page
    /// shows the last result and never starts a new analysis by itself.
    @ObservedObject private var model: StorageAnalysisModel
    @State private var showAllFiles = false
    @State private var showAllDirectories = false

    public init(model: StorageAnalysisModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var analysis: StorageAnalysis { model.analysis }
    private var report: StorageDiagnosticReport { model.report }
    private var isAnalyzing: Bool { model.isAnalyzing }
    private var hasResult: Bool { model.hasResult }

    public var body: some View {
        SiftPage {
            PageHeader(
                titleKey: .storageTitle,
                eyebrowKey: .navGroupApps,
                subtitle: lastAnalyzedSubtitle
            ) {
                if model.hasResult {
                    Button {
                        Task { await environment.analyzeStorage() }
                    } label: {
                        Label(
                            LocalizationKey.storageReanalyze.localized,
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isAnalyzing)
                    .accessibilityIdentifier("storage.reanalyze")
                }
            }

            scopeRow

            if isAnalyzing {
                analyzingCard
            }

            if hasResult {
                coverageNotice
                HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                    volumeCard
                    reclaimableCard
                        .frame(width: 260)
                }
                categoriesCard
                HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                    directoriesCard
                    filesCard
                }
                findingsCard(titleKey: .diagnosticsSectionRebuildable, findings: report.rebuildableFindings)
                findingsCard(titleKey: .diagnosticsSectionProtected, findings: report.protectedFindings)
                findingsCard(titleKey: .diagnosticsSectionSnapshots, findings: report.snapshotFindings)
                skippedCard
                notes
            } else if !isAnalyzing {
                // Opening the page only shows the scope. The analysis begins
                // when the user presses this button, not when the destination
                // is selected.
                SiftHeroCard(
                    symbolName: "chart.pie",
                    title: LocalizationKey.storageTitle.localized,
                    detail: LocalizationKey.storageScopeNote.localized,
                    tint: SiftColor.categoryPalette[3]
                ) {
                    PrimaryActionButton(
                        titleKey: .storageStart,
                        symbolName: "arrow.clockwise"
                    ) {
                        Task { await environment.analyzeStorage() }
                    }
                    .accessibilityIdentifier("storage.analyze")
                }
            }
        }
    }

    private var lastAnalyzedSubtitle: String? {
        guard let last = model.lastAnalyzedAt else { return nil }
        return LocalizationKey.storageLastAnalyzed.localized(SiftFormat.relativeDate(last))
    }

    /// One scope control for the whole page.
    ///
    /// The toggle and the sentence that explains it share a surface, so the two
    /// halves of the same decision do not sit at opposite edges of the window.
    private var scopeRow: some View {
        SiftPanel(padding: SiftMetrics.spacingL) {
            HStack(alignment: .center, spacing: SiftMetrics.spacingL) {
                Toggle(
                    LocalizationKey.storageIncludeVolume.localized,
                    isOn: $model.includeVolumeRoot
                )
                .toggleStyle(.checkbox)
                .disabled(isAnalyzing)

                Divider()
                    .frame(height: 20)

                Text(LocalizationKey.storageScopeNote.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
    }

    private var analyzingCard: some View {
        SiftPanel {
            HStack(spacing: SiftMetrics.spacingL) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(LocalizationKey.storageAnalysing.localized)
                        .font(SiftFont.sectionTitle)
                    Text(LocalizationKey.storageScopeNote.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    environment.cancelStorageAnalysis()
                } label: {
                    Text(LocalizationKey.storageCancelAnalysis.localized)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityIdentifier("storage.analyzing")
    }

    // MARK: - Completeness

    private var coverageNotice: some View {
        Group {
            switch report.coverage {
            case .complete:
                NoticeBanner(level: .success, titleKey: .diagnosticsCoverageComplete)
            case .partial:
                NoticeBanner(level: .warning, titleKey: .diagnosticsCoveragePartial)
            case .permissionDenied:
                NoticeBanner(
                    level: .warning,
                    message: "\(LocalizationKey.diagnosticsCoveragePermissionDenied.localized) \(LocalizationKey.diagnosticsCoverageNote.localized)",
                    actionTitle: .scanOpenSystemSettings,
                    action: { Task { await environment.openPermissionSettings() } }
                )
            case .volumeUnavailable:
                NoticeBanner(level: .warning, titleKey: .diagnosticsCoverageVolumeUnavailable)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            if report.hasApproximateSizes {
                Text(LocalizationKey.diagnosticsNoteApproximate.localized)
            }
            Text(LocalizationKey.diagnosticsNoteReadOnly.localized)
        }
        .font(SiftFont.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Volume and categories

    private var volumeCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                if let volume = report.primaryVolume {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.formattedUsage)
                            .font(SiftFont.metricLarge)
                        Text(volume.name)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: SiftMetrics.spacingS)
                    }
                    UsageBar(
                        fraction: volume.usedFraction,
                        tint: volume.usedFraction > 0.9 ? SiftColor.review : SiftColor.safe,
                        height: 10
                    )
                    Text(LocalizationKey.dashboardDiskFree.localized(volume.formattedFree))
                        .font(SiftFont.bodyEmphasis)
                } else {
                    Text(LocalizationKey.storageNotAuthorized.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var reclaimableCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.storageReclaimable.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                Text(SiftFormat.bytes(analysis.reclaimableBytes))
                    .font(SiftFont.metric)
                    .foregroundStyle(SiftColor.safe)
                    .contentTransition(.numericText())
                Text(
                    LocalizationKey.scanCheckedFiles.localized(
                        SiftFormat.count(Int(report.measuredFiles))
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var categoriesCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.storageByType.localized)
                    .font(SiftFont.sectionTitle)
                ForEach(Array(analysis.categories.enumerated()), id: \.element.id) { index, category in
                    BreakdownBar(
                        label: category.title,
                        value: category.formattedSize,
                        fraction: fraction(of: category),
                        tint: SiftColor.categoryPalette[index % SiftColor.categoryPalette.count]
                    )
                }
            }
        }
    }

    private func fraction(of category: StorageAnalysis.Category) -> Double {
        let largest = analysis.categories.map(\.sizeInBytes).max() ?? 1
        guard largest > 0 else { return 0 }
        return Double(category.sizeInBytes) / Double(largest)
    }

    // MARK: - Largest items

    private var directoriesCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.storageTopDirectories.localized)
                    .font(SiftFont.sectionTitle)
                Divider()
                ForEach(visibleDirectories) { directory in
                    PathRow(
                        name: directory.displayName,
                        path: directory.displayPath,
                        detail: SiftFormat.bytes(directory.sizeInBytes),
                        secondary: LocalizationKey.commonFileCount.localized(directory.fileCount),
                        onReveal: { Task { await environment.reveal(directory.url) } }
                    )
                }
                if analysis.topDirectories.count > visibleDirectories.count {
                    Button {
                        showAllDirectories = true
                    } label: {
                        Text(
                            LocalizationKey.commonOf.localized(
                                "\(visibleDirectories.count)",
                                "\(analysis.topDirectories.count)"
                            )
                        )
                        .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var filesCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.storageTopFiles.localized)
                    .font(SiftFont.sectionTitle)
                Divider()
                ForEach(visibleFiles) { file in
                    PathRow(
                        name: file.displayName,
                        path: file.displayPath,
                        detail: SiftFormat.bytes(file.sizeInBytes),
                        secondary: file.modifiedAt.map { SiftFormat.relativeDate($0) } ?? "",
                        onReveal: { Task { await environment.reveal(file.url) } }
                    )
                }
                if analysis.topFiles.count > visibleFiles.count {
                    Button {
                        showAllFiles = true
                    } label: {
                        Text(
                            LocalizationKey.commonOf.localized(
                                "\(visibleFiles.count)",
                                "\(analysis.topFiles.count)"
                            )
                        )
                        .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var visibleFiles: [StorageAnalysis.FileEntry] {
        showAllFiles ? analysis.topFiles : Array(analysis.topFiles.prefix(8))
    }

    private var visibleDirectories: [StorageAnalysis.DirectoryEntry] {
        showAllDirectories ? analysis.topDirectories : Array(analysis.topDirectories.prefix(8))
    }

    // MARK: - Findings

    @ViewBuilder
    private func findingsCard(titleKey: LocalizationKey, findings: [StorageFinding]) -> some View {
        if !findings.isEmpty {
            SiftPanel {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                    Text(titleKey.localized)
                        .font(SiftFont.sectionTitle)
                    Divider()
                    ForEach(findings) { finding in
                        FindingRow(
                            finding: finding,
                            onReveal: {
                                guard let path = finding.path else { return }
                                Task { await environment.reveal(path) }
                            }
                        )
                    }
                }
            }
        }
    }

    private var skippedCard: some View {
        Group {
            if !report.skips.isEmpty {
                SiftPanel {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.diagnosticsSectionSkipped.localized)
                            .font(SiftFont.sectionTitle)
                        Divider()
                        ForEach(report.skips) { skip in
                            HStack(spacing: SiftMetrics.spacingM) {
                                Image(systemName: skip.reason.needsFullDiskAccess
                                    ? "lock.fill"
                                    : "questionmark.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(skip.path.path)
                                    .font(SiftFont.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: SiftMetrics.spacingS)
                            }
                            .padding(.vertical, SiftMetrics.spacingXS)
                        }
                    }
                }
            }
        }
    }

}

/// One finding: what it is, how much it holds, and what can be done about it.
private struct FindingRow: View {
    let finding: StorageFinding
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(finding.explanationKey.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.category.localizedTitle)
                    .font(SiftFont.badge)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText)
                    .font(SiftFont.monospacedNumber)
                Text(finding.status.localizedTitle)
                    .font(SiftFont.caption)
                    .foregroundStyle(finding.status.tint)
                Text(remediationKey.localized)
                    .font(SiftFont.badge)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
            if finding.path != nil {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help(LocalizationKey.filesRevealInFinder.localized)
                .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
            }
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .accessibilityElement(children: .combine)
    }

    /// An unreadable location has no size, and "0 bytes" would be a different
    /// answer.
    private var sizeText: String {
        finding.fileCount == nil ? "—" : SiftFormat.bytes(finding.allocatedBytes)
    }

    private var remediationKey: LocalizationKey {
        switch finding.remediation {
        case .trash: .diagnosticsRemediationTrash
        case .rebuild(.spotlight): .diagnosticsRemediationSpotlight
        case .rebuild(.owningApplication): .diagnosticsRemediationOwningApplication
        case .inspectOnly: .diagnosticsRemediationInspectOnly
        }
    }
}

/// A row showing a name, its path, a size and one secondary detail.
struct PathRow: View {
    let name: String
    let path: String
    let detail: String
    let secondary: String
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(SiftFont.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            VStack(alignment: .trailing, spacing: 1) {
                Text(detail)
                    .font(SiftFont.monospacedNumber)
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onReveal) {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
        }
        .padding(.vertical, SiftMetrics.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text("\(detail) \(path)"))
    }
}

extension StorageFindingCategory {
    /// The label the page shows for a category.
    var localizedTitle: String {
        switch self {
        case .spotlightIndex: LocalizationKey.diagnosticsCategorySpotlightIndex.localized
        case .coreSpotlightIndex: LocalizationKey.diagnosticsCategoryCoreSpotlightIndex.localized
        case .developerIndex: LocalizationKey.diagnosticsCategoryDeveloperIndex.localized
        case .applicationDatabase: LocalizationKey.diagnosticsCategoryApplicationDatabase.localized
        case .filesystemSnapshot: LocalizationKey.diagnosticsCategoryFilesystemSnapshot.localized
        case .systemCache: LocalizationKey.diagnosticsCategorySystemCache.localized
        case .systemData: LocalizationKey.diagnosticsCategorySystemData.localized
        case .userData: LocalizationKey.diagnosticsCategoryUserData.localized
        case .unknown: LocalizationKey.diagnosticsCategoryUnknown.localized
        }
    }
}

extension StorageFindingStatus {
    var localizedTitle: String {
        switch self {
        case .cleanable: LocalizationKey.diagnosticsStatusCleanable.localized
        case .rebuildable: LocalizationKey.diagnosticsStatusRebuildable.localized
        case .protected: LocalizationKey.diagnosticsStatusProtected.localized
        case .unknown: LocalizationKey.diagnosticsStatusUnknown.localized
        }
    }

    var tint: Color {
        switch self {
        case .cleanable: SiftColor.safe
        case .rebuildable: SiftColor.accent
        case .protected: SiftColor.review
        case .unknown: SiftColor.neutral
        }
    }
}
