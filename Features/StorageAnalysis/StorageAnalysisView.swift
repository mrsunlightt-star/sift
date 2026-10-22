import Core
import Shared
import SwiftUI

/// The storage page (§5.4).
///
/// It answers the three questions the specification names — which kind of file
/// takes the most space, which folders are largest, which files to handle first —
/// and the system-diagnostics questions that turn out to be the same question.
///
/// One page and one analysis button on purpose. Two pages answering "what is
/// using my disk" from two engines is how the numbers end up disagreeing.
public struct StorageAnalysisView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// The session state lives in `AppEnvironment`, so returning to this page
    /// shows the last result and never starts a new analysis by itself.
    @ObservedObject private var model: StorageAnalysisModel
    private let onGoClean: () -> Void

    @State private var showAllFiles = false
    @State private var showAllDirectories = false

    public init(model: StorageAnalysisModel, onGoClean: @escaping () -> Void = {}) {
        _model = ObservedObject(wrappedValue: model)
        self.onGoClean = onGoClean
    }

    private var analysis: StorageAnalysis { model.analysis }
    private var report: StorageDiagnosticReport { model.report }
    private var isAnalyzing: Bool { model.isAnalyzing }
    private var hasResult: Bool { model.hasResult }

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: LocalizationKey.storageTitle.localized, status: headerStatus) {
                if hasResult {
                    SiftSecondaryButton(titleKey: .storageReanalyze, symbolName: "arrow.clockwise") {
                        Task { await environment.analyzeStorage() }
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                    scopeRow

                    if case let .failed(failure) = model.runOutcome {
                        // The previous result, if any, stays below: this says the
                        // new run did not produce one, rather than replacing it
                        // with a zeroed analysis.
                        NoticeBanner(
                            level: .error,
                            message: failure.message,
                            actionTitle: .commonRetry
                        ) {
                            Task { await environment.analyzeStorage() }
                        }
                    }

                    if case .cancelled = model.runOutcome {
                        // Cancellation is an outcome, not a silence: the last
                        // result stays, and the page says this run was stopped.
                        NoticeBanner(level: .information, titleKey: .scanPhaseCancelled)
                    }

                    if isAnalyzing {
                        analyzingCard
                    }

                    if hasResult {
                        coverageNotice

                        HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                            leftColumn
                            rightColumn
                                .frame(width: SiftMetrics.summaryColumnWidth)
                        }

                        findingsCard(titleKey: .diagnosticsSectionRebuildable, findings: report.rebuildableFindings)
                        findingsCard(titleKey: .diagnosticsSectionProtected, findings: report.protectedFindings)
                        findingsCard(titleKey: .diagnosticsSectionSnapshots, findings: report.snapshotFindings)
                        skippedCard
                        notes
                    } else if !isAnalyzing {
                        startCard
                    }
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.vertical, SiftMetrics.pageSpacing)
                .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - Header and scope

    private var headerStatus: String {
        if let volume = report.primaryVolume {
            return LocalizationKey.storageStatus.localized(
                volume.name,
                volume.formattedUsage,
                volume.formattedTotal
            )
        }
        if let volume = environment.availableVolumes.first(where: { $0.mountPoint.path == "/" }) {
            return LocalizationKey.storageStatus.localized(
                volume.name,
                volume.formattedUsage,
                volume.formattedTotal
            )
        }
        if let last = model.lastAnalyzedAt {
            return LocalizationKey.storageLastAnalyzed.localized(SiftFormat.relativeDate(last))
        }
        return LocalizationKey.storageScopeNote.localized
    }

    /// One scope control for the whole page.
    ///
    /// The toggle and the sentence that explains it share a surface, so the two
    /// halves of the same decision do not sit at opposite edges of the window.
    private var scopeRow: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
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

                if hasResult, let last = model.lastAnalyzedAt {
                    Text(LocalizationKey.storageLastAnalyzed.localized(SiftFormat.relativeDate(last)))
                        .font(SiftFont.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var startCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingXL) {
            HStack(alignment: .top, spacing: SiftMetrics.spacingXL) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(SiftColor.accent)
                    .frame(width: 58, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                            .fill(SiftColor.accent.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                    Text(LocalizationKey.storageStartTitle.localized)
                        .font(SiftFont.title)
                    Text(LocalizationKey.storageScopeNote.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SiftPrimaryButton(titleKey: .storageStart, symbolName: "arrow.clockwise") {
                        Task { await environment.analyzeStorage() }
                    }
                    .accessibilityIdentifier("storage.analyze")
                    .padding(.top, SiftMetrics.spacingXS)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var analyzingCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            HStack(spacing: SiftMetrics.spacingL) {
                SiftProgressRing(progress: nil, lineWidth: 6)
                    .frame(width: 38, height: 38)
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
                .tint(SiftColor.accent)
                .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityIdentifier("storage.analyzing")
    }

    // MARK: - Columns

    private var leftColumn: some View {
        VStack(spacing: SiftMetrics.pageSpacing) {
            distributionCard

            HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                directoriesCard
                filesCard
            }
        }
    }

    private var rightColumn: some View {
        VStack(spacing: SiftMetrics.pageSpacing) {
            categoryCard
            suggestionCard
        }
    }

    private var distributionCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                    Text(LocalizationKey.storageSpaceDistribution.localized)
                        .font(SiftFont.sectionTitle)
                    Text(report.primaryVolume?.name ?? analysis.volumeName)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: SiftMetrics.spacingS)
                    if let volume = report.primaryVolume {
                        Text(LocalizationKey.storageStatus.localized(
                            volume.name,
                            volume.formattedUsage,
                            volume.formattedTotal
                        ))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if analysis.categories.isEmpty {
                    SiftEmptyState(
                        symbolName: "chart.bar.xaxis",
                        titleKey: .diagnosticsEmpty
                    )
                    .frame(height: 260)
                } else {
                    StorageTreemap(categories: analysis.categories)
                        .frame(height: 390)
                }
            }
        }
    }

    private var categoryCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizationKey.storageCategoryDetail.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer()
                    Text(LocalizationKey.storageUsed.localized(analysis.formattedUsage, analysis.formattedTotal))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(analysis.categories) { category in
                    HStack(spacing: SiftMetrics.spacingM) {
                        Circle()
                            .fill(StorageCategoryTint.tint(for: category.id))
                            .frame(width: 7, height: 7)
                        Text(category.title)
                            .font(SiftFont.body)
                            .lineLimit(1)
                        Spacer(minLength: SiftMetrics.spacingS)
                        Text(category.formattedSize)
                            .font(SiftFont.bodyEmphasis)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }

                Divider()

                HStack(spacing: SiftMetrics.spacingM) {
                    Circle()
                        .fill(SiftColor.neutral.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text(LocalizationKey.storageAvailableSpace.localized)
                        .font(SiftFont.body)
                    Spacer(minLength: SiftMetrics.spacingS)
                    Text(analysis.formattedFree)
                        .font(SiftFont.bodyEmphasis)
                        .monospacedDigit()
                }

                Divider()

                Text(LocalizationKey.storageUsageShare.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                SegmentedUsageBar(segments: usageSegments, height: 10)
                    .background(Capsule().fill(SiftColor.neutral.opacity(0.10)))
                HStack(spacing: SiftMetrics.spacingM) {
                    Text(analysis.formattedUsed)
                        .font(SiftFont.badge)
                        .foregroundStyle(SiftColor.accent)
                    Spacer()
                    Text(analysis.formattedFree)
                        .font(SiftFont.badge)
                        .foregroundStyle(.secondary)
                }
                Text(LocalizationKey.storageLocalNote.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingXS)
            }
        }
    }

    /// The usage bar accounts for the whole volume: the measured categories, the
    /// part of "used" the analysis could not attribute, and the free space.
    private var usageSegments: [SegmentedUsageBar.Segment] {
        guard analysis.totalBytes > 0 else { return [] }
        let total = Double(analysis.totalBytes)
        var segments: [SegmentedUsageBar.Segment] = analysis.categories.enumerated().map { index, category in
            SegmentedUsageBar.Segment(
                id: category.id,
                fraction: Double(category.sizeInBytes) / total,
                tint: StorageCategoryTint.tint(for: category.id)
            )
        }
        let measured = analysis.categories.reduce(Int64(0)) { $0 + $1.sizeInBytes }
        let unattributed = max(analysis.usedBytes - measured, 0)
        if unattributed > 0 {
            segments.append(
                SegmentedUsageBar.Segment(
                    id: "other",
                    fraction: Double(unattributed) / total,
                    tint: SiftColor.neutral.opacity(0.55)
                )
            )
        }
        if analysis.freeBytes > 0 {
            segments.append(
                SegmentedUsageBar.Segment(
                    id: "free",
                    fraction: Double(analysis.freeBytes) / total,
                    tint: SiftColor.neutral.opacity(0.20)
                )
            )
        }
        return segments
    }

    private var suggestionCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.storageSuggestionTitle.localized)
                    .font(SiftFont.eyebrow)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(SiftColor.accent)
                Text(
                    LocalizationKey.storageCleanableHeading.localized(
                        SiftFormat.bytes(analysis.reclaimableBytes)
                    )
                )
                .font(SiftFont.title)
                .fixedSize(horizontal: false, vertical: true)
                Text(LocalizationKey.storageSuggestionDetail.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SiftPrimaryButton(titleKey: .storageGoClean) {
                    onGoClean()
                }
                .padding(.top, SiftMetrics.spacingS)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusXL, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SiftColor.accent.opacity(0.12), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - Completeness

    private var coverageNotice: some View {
        Group {
            switch report.coverage {
            case .complete:
                // The diagnostic providers can be complete while the category
                // walk could not read a folder. The totals are a lower bound in
                // that case too, so the page must not call them complete.
                if analysis.skippedCount > 0 {
                    NoticeBanner(level: .warning, titleKey: .diagnosticsCoveragePartial)
                } else {
                    NoticeBanner(level: .success, titleKey: .diagnosticsCoverageComplete)
                }
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

    // MARK: - Largest items

    private var directoriesCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
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
                    .buttonStyle(SiftLinkButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var filesCard: some View {
        SiftGlassCard(padding: SiftMetrics.spacingL) {
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
                    .buttonStyle(SiftLinkButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var visibleFiles: [StorageAnalysis.FileEntry] {
        showAllFiles ? analysis.topFiles : Array(analysis.topFiles.prefix(6))
    }

    private var visibleDirectories: [StorageAnalysis.DirectoryEntry] {
        showAllDirectories ? analysis.topDirectories : Array(analysis.topDirectories.prefix(6))
    }

    // MARK: - Findings

    @ViewBuilder
    private func findingsCard(titleKey: LocalizationKey, findings: [StorageFinding]) -> some View {
        if !findings.isEmpty {
            SiftGlassCard(padding: SiftMetrics.spacingL) {
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
                SiftGlassCard(padding: SiftMetrics.spacingL) {
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
                                Text(skip.displayPath)
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

// MARK: - Treemap

/// The space map: one tile per file type, sized by what it occupies.
///
/// A binary treemap rather than a pie: the eye compares rectangles more
/// accurately than angles, and the largest tile has a readable label at the size
/// a pie slice would need a leader line. Tiles smaller than a readable label are
/// still accessible to VoiceOver with their name and size.
struct StorageTreemap: View {
    let categories: [StorageAnalysis.Category]

    var body: some View {
        GeometryReader { geometry in
            let tiles = Self.layout(categories, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    tileView(tile)
                        .frame(width: max(tile.rect.width - 6, 0), height: max(tile.rect.height - 6, 0))
                        .offset(x: tile.rect.minX + 3, y: tile.rect.minY + 3)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tileView(_ tile: StorageTreemapTile) -> some View {
        let tint = tint(for: tile.category.id)
        let showsLabel = tile.rect.width > 96 && tile.rect.height > 54
        let showsName = tile.rect.width > 64 && tile.rect.height > 34
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.24), tint.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.34), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if showsName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.category.title)
                            .font(SiftFont.caption)
                            .foregroundStyle(tint)
                            .lineLimit(2)
                        if showsLabel {
                            Text(tile.category.formattedSize)
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    .padding(SiftMetrics.spacingM)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(tile.category.title))
            .accessibilityValue(Text(tile.category.formattedSize))
    }

    private func tint(for id: String) -> Color {
        StorageCategoryTint.tint(for: id)
    }

    struct StorageTreemapTile: Identifiable {
        let category: StorageAnalysis.Category
        let rect: CGRect
        var id: String { category.id }
    }

    /// Slice-and-dice along the longer axis. The largest category takes its share
    /// of the current rectangle, and the rest recurse into what remains, so the
    /// map is deterministic and every byte of the frame is assigned once.
    static func layout(_ categories: [StorageAnalysis.Category], in rect: CGRect) -> [StorageTreemapTile] {
        var remaining = categories
            .filter { $0.sizeInBytes > 0 }
            .sorted { $0.sizeInBytes > $1.sizeInBytes }
        guard !remaining.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        var tiles: [StorageTreemapTile] = []
        var current = rect

        while remaining.count > 1 {
            let first = remaining.removeFirst()
            let restBytes = remaining.reduce(Int64(0)) { $0 + $1.sizeInBytes }
            let total = first.sizeInBytes + restBytes
            guard total > 0 else { break }
            let fraction = CGFloat(Double(first.sizeInBytes) / Double(total))

            if current.width >= current.height {
                let width = current.width * fraction
                tiles.append(
                    StorageTreemapTile(
                        category: first,
                        rect: CGRect(x: current.minX, y: current.minY, width: width, height: current.height)
                    )
                )
                current = CGRect(
                    x: current.minX + width,
                    y: current.minY,
                    width: current.width - width,
                    height: current.height
                )
            } else {
                let height = current.height * fraction
                tiles.append(
                    StorageTreemapTile(
                        category: first,
                        rect: CGRect(x: current.minX, y: current.minY, width: current.width, height: height)
                    )
                )
                current = CGRect(
                    x: current.minX,
                    y: current.minY + height,
                    width: current.width,
                    height: current.height - height
                )
            }
        }

        if let last = remaining.first {
            tiles.append(StorageTreemapTile(category: last, rect: current))
        }
        return tiles
    }
}

// MARK: - Rows

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


/// One colour assignment for a storage category, shared by the map and the list
/// so the same category cannot be two colours on one page.
private enum StorageCategoryTint {
    private static let order = [
        "applicationCache", "logs", "installers", "archives", "audio",
        "code", "data", "documents", "images", "video", "other",
    ]

    static func tint(for id: String) -> Color {
        let index = order.firstIndex(of: id) ?? order.count - 1
        return SiftColor.categoryPalette[index % SiftColor.categoryPalette.count]
    }
}
