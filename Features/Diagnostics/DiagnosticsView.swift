import Core
import Shared
import SwiftUI

/// The system space diagnostics page (§10).
///
/// Scope at the top, then whether the answer is complete, then the largest
/// categories, and finally the findings grouped by what can be done about them:
/// rebuilt, explained only, or handed to the cleanup flow. Nothing on this page
/// removes anything, and the wording says so — an index is "space that can be
/// rebuilt", never "junk" (§10).
public struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var report: StorageDiagnosticReport = .empty
    @State private var isAnalyzing = false
    @State private var includeVolumeRoot = false
    /// Polled by the running analysis, because a cancelled Swift task cannot be
    /// seen from inside its loops.
    @State private var cancellation = CancellationFlag()
    @State private var analysisTask: Task<StorageDiagnosticReport, Never>?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .diagnosticsTitle) {
                    Button {
                        Task { await analyze() }
                    } label: {
                        Label(
                            LocalizationKey.diagnosticsAnalyze.localized,
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isAnalyzing)
                }

                Text(LocalizationKey.diagnosticsIntro.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                scopeCard

                if isAnalyzing {
                    HStack(spacing: SiftMetrics.spacingM) {
                        ProgressView().controlSize(.small)
                        Text(LocalizationKey.diagnosticsAnalyzing.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if report.providerCount > 0 {
                    coverageNotice

                    if report.findings.isEmpty, report.skips.isEmpty {
                        SiftEmptyState(symbolName: "stethoscope", titleKey: .diagnosticsEmpty)
                    } else {
                        usageCard
                        categoriesCard
                        findingsCard(
                            titleKey: .diagnosticsSectionRebuildable,
                            findings: report.rebuildableFindings
                        )
                        findingsCard(
                            titleKey: .diagnosticsSectionProtected,
                            findings: report.protectedFindings
                        )
                        findingsCard(
                            titleKey: .diagnosticsSectionCleanable,
                            findings: report.cleanableFindings
                        )
                        findingsCard(
                            titleKey: .diagnosticsSectionSnapshots,
                            findings: report.snapshotFindings
                        )
                        skippedCard
                        notes
                    }
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

    // MARK: - Scope

    private var scopeCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.settingsGroupScanScope.localized)
                    .font(SiftFont.sectionTitle)

                ForEach(scopeRoots, id: \.id) { root in
                    HStack(spacing: SiftMetrics.spacingM) {
                        Image(systemName: root.kind == .home ? "house" : "externaldrive")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(root.url.path)
                            .font(SiftFont.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Toggle(
                    LocalizationKey.diagnosticsScopeIncludeVolume.localized,
                    isOn: $includeVolumeRoot
                )
                .toggleStyle(.checkbox)

                Text(LocalizationKey.diagnosticsScopeNote.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the next run would cover, so the scope is visible before it starts.
    private var scopeRoots: [DiagnosticRoot] {
        environment.diagnosticRoots(includeVolumeRoot: includeVolumeRoot)
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

    private var usageCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                if let volume = report.primaryVolume {
                    Text(volume.name)
                        .font(SiftFont.sectionTitle)
                    Text(
                        LocalizationKey.storageUsed.localized(
                            SiftFormat.bytes(volume.usedBytes),
                            SiftFormat.bytes(volume.totalBytes)
                        )
                    )
                    .font(SiftFont.body)
                    .foregroundStyle(.secondary)
                    UsageBar(fraction: volume.usedFraction, tint: SiftColor.accent, height: 10)
                    Text(LocalizationKey.dashboardDiskFree.localized(SiftFormat.bytes(volume.freeBytes)))
                        .font(SiftFont.bodyEmphasis)
                }
                Text(
                    LocalizationKey.scanCheckedFiles.localized(SiftFormat.count(Int(report.measuredFiles)))
                )
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var categoriesCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.diagnosticsSectionCategories.localized)
                    .font(SiftFont.sectionTitle)
                ForEach(Array(report.categoryTotals.enumerated()), id: \.element.category) { index, total in
                    BreakdownBar(
                        label: total.category.localizedTitle,
                        value: SiftFormat.bytes(total.bytes),
                        fraction: fraction(of: total.bytes),
                        tint: SiftColor.categoryPalette[index % SiftColor.categoryPalette.count]
                    )
                }
            }
        }
    }

    private func fraction(of bytes: Int64) -> Double {
        let largest = report.categoryTotals.map(\.bytes).max() ?? 0
        guard largest > 0, bytes > 0 else { return 0 }
        return Double(bytes) / Double(largest)
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

    private func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let engine = environment.diagnostics
        let roots = scopeRoots
        let home = URL(fileURLWithPath: environment.rules.homeDirectory)
        let rules = environment.rules
        cancellation.isCancelled = false
        let flag = cancellation

        // The analysis walks the file system off the main actor, so the page stays
        // responsive and can be left while it runs.
        let task = Task(priority: .userInitiated) { () -> StorageDiagnosticReport in
            await engine.analyze(
                roots: roots,
                homeDirectory: home,
                rules: rules,
                isCancelled: { flag.isCancelled }
            )
        }
        analysisTask = task
        let result = await task.value
        guard !Task.isCancelled else { return }
        report = result
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

    /// An unreadable location has no size, and saying "0 bytes" would be wrong.
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
