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
    @State private var analysis: StorageAnalysis = .empty
    @State private var report: StorageDiagnosticReport = .empty
    @State private var isAnalyzing = false
    /// Off by default: the volume-level pass reads the whole disk and takes about
    /// a minute, which is not what opening the page should cost.
    @State private var includeVolumeRoot = false
    @State private var showAllFiles = false
    @State private var showAllDirectories = false
    @State private var cancellation = CancellationFlag()
    @State private var analysisTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .storageTitle) {
                    Button {
                        Task { await analyze() }
                    } label: {
                        Label(
                            LocalizationKey.storageAnalyze.localized,
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isAnalyzing)
                }

                scopeRow

                if isAnalyzing {
                    HStack(spacing: SiftMetrics.spacingM) {
                        ProgressView().controlSize(.small)
                        Text(LocalizationKey.storageAnalysing.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasResult {
                    coverageNotice
                    volumeCard
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
                    SiftEmptyState(symbolName: "chart.pie", titleKey: .storageNotAuthorized)
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .task { await analyze() }
        .onDisappear {
            cancellation.isCancelled = true
            analysisTask?.cancel()
            analysisTask = nil
        }
    }

    private var hasResult: Bool {
        report.providerCount > 0
    }

    /// One scope control for the whole page.
    private var scopeRow: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Toggle(
                LocalizationKey.storageIncludeVolume.localized,
                isOn: $includeVolumeRoot
            )
            .toggleStyle(.checkbox)
            .disabled(isAnalyzing)

            Spacer(minLength: SiftMetrics.spacingS)

            Text(LocalizationKey.storageScopeNote.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
            HStack(alignment: .center, spacing: SiftMetrics.spacingXL) {
                if let volume = report.primaryVolume {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.formattedUsage)
                                .font(SiftFont.metricLarge)
                            Text(volume.name)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        UsageBar(
                            fraction: volume.usedFraction,
                            tint: volume.usedFraction > 0.9 ? SiftColor.review : SiftColor.safe,
                            height: 10
                        )
                        Text(LocalizationKey.dashboardDiskFree.localized(volume.formattedFree))
                            .font(SiftFont.bodyEmphasis)
                    }
                }
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(LocalizationKey.storageReclaimable.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Text(SiftFormat.bytes(analysis.reclaimableBytes))
                        .font(SiftFont.metric)
                        .foregroundStyle(SiftColor.safe)
                    Text(
                        LocalizationKey.scanCheckedFiles.localized(
                            SiftFormat.count(Int(report.measuredFiles))
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
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

    // MARK: - Analysis

    /// Runs both halves of the page under one button and one cancellation flag.
    ///
    /// The byte-level view comes from the storage analyzer, the meaning of what it
    /// found from the diagnostics engine. They share a scope: the home folder and
    /// the locations the user granted, plus the volume root when it was asked for.
    private func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let analyzer = environment.storageAnalyzer
        let diagnostics = environment.diagnostics
        let rules = environment.rules
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let scanRoots = await environment.makeScanRequest(includeDuplicates: false).roots
        let diagnosticRoots = environment.diagnosticRoots(includeVolumeRoot: includeVolumeRoot)
        cancellation.isCancelled = false
        let flag = cancellation

        let task = Task(priority: .userInitiated) { () -> Void in
            let measured = (try? await analyzer.analyze(
                roots: scanRoots,
                cancelled: { flag.isCancelled }
            )) ?? .empty
            guard !flag.isCancelled else { return }
            let diagnosed = await diagnostics.analyze(
                roots: diagnosticRoots,
                homeDirectory: home,
                rules: rules,
                isCancelled: { flag.isCancelled }
            )
            guard !flag.isCancelled else { return }
            await MainActor.run {
                analysis = measured
                report = diagnosed
            }
        }
        analysisTask = task
        await task.value
        analysisTask = nil
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
