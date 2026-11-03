import Core
import Shared
import SwiftUI

/// The storage page (03 §3).
///
/// Two states, and no third. Before the first run the page is one honest empty
/// state: what a run would look for, which volume it would measure, and the one
/// button that starts it. After a run it is the measurement itself, in the order
/// the specification gives — the number, the map, what can be done about it, the
/// largest items, and what could not be read with the reason each time.
///
/// The page states one primary metric and lets the map carry the detail. Every
/// other number on it is a right-aligned monospaced figure beside a name, because
/// a table of figures that do not line up cannot be compared by eye.
///
/// One page and one analysis button on purpose: two pages answering "what is
/// using my disk" from two engines is how the numbers end up disagreeing.
public struct StorageAnalysisView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// The session state lives in `AppEnvironment`, so returning to this page
    /// shows the last result and never starts a new analysis by itself.
    @ObservedObject private var model: StorageAnalysisModel
    private let onGoClean: () -> Void

    @State private var showAllFiles = false
    @State private var showAllDirectories = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(model: StorageAnalysisModel, onGoClean: @escaping () -> Void = {}) {
        _model = ObservedObject(wrappedValue: model)
        self.onGoClean = onGoClean
    }

    /// Two legend entries side by side, each wide enough for a category name and a
    /// size that already carries its unit.
    private static let legendWidth: CGFloat = 416

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
                    .disabled(isAnalyzing)
                }
            }

            SiftPage {
                scopeRow

                if case let .failed(failure) = model.runOutcome {
                    // The previous result, if any, stays below: this says the new
                    // run did not produce one, rather than replacing it with a
                    // zeroed analysis (invariant 28).
                    NoticeBanner(
                        level: .error,
                        message: failure.message,
                        actionTitle: .commonRetry
                    ) {
                        Task { await environment.analyzeStorage() }
                    }
                }

                if case .cancelled = model.runOutcome {
                    // Cancellation is an outcome, not a silence: the last result
                    // stays, and the page says this run was stopped.
                    NoticeBanner(level: .information, titleKey: .scanPhaseCancelled)
                }

                if isAnalyzing {
                    analyzingRow
                }

                if hasResult {
                    coverageBanners

                    distribution

                    if analysis.reclaimableBytes > 0 {
                        suggestion
                    }

                    findingsSections

                    largestItems

                    skippedLocations

                    notes
                } else if !isAnalyzing {
                    emptyState
                }
            }
            .animation(
                SiftMotion.respectingReduceMotion(SiftMotion.quick, reduceMotion: reduceMotion),
                value: hasResult
            )
            .animation(
                SiftMotion.respectingReduceMotion(SiftMotion.quick, reduceMotion: reduceMotion),
                value: isAnalyzing
            )
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

    /// The whole-volume toggle, and when the last run was.
    ///
    /// It sits above both states because it decides what a run measures, so a
    /// user who wants system diagnostics in the first run does not have to run
    /// once, read a result they did not ask for, and run again. The sentence that
    /// explains it belongs with the numbers it describes, not here.
    private var scopeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingL) {
            Toggle(isOn: $model.includeVolumeRoot) {
                Text(LocalizationKey.storageIncludeVolume.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
            }
            .toggleStyle(.checkbox)
            .disabled(isAnalyzing)
            .accessibilityIdentifier("storage.includeVolume")

            Spacer(minLength: SiftMetrics.spacingS)

            if hasResult, let last = model.lastAnalyzedAt {
                Text(LocalizationKey.storageLastAnalyzed.localized(SiftFormat.relativeDate(last)))
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
            }
        }
    }

    /// One explanation and one action, on the canvas rather than in a card: a card
    /// around "nothing has been measured yet" made the absence look like a result.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            Text(LocalizationKey.storageStartTitle.localized)
                .font(SiftFont.sectionHeading)
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizationKey.storageScopeNote.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)

            SiftPrimaryButton(titleKey: .storageStart, symbolName: "arrow.clockwise") {
                Task { await environment.analyzeStorage() }
            }
            .accessibilityIdentifier("storage.analyze")
            .padding(.top, SiftMetrics.spacingXS)
        }
        .padding(.top, SiftMetrics.spacingS)
        .transition(.opacity)
    }

    /// A run in flight, stated in place rather than over the previous result: the
    /// numbers below it are still the last good measurement, and covering them
    /// with a spinner would make the user wait for something the page already has.
    private var analyzingRow: some View {
        HStack(spacing: SiftMetrics.spacingL) {
            SiftProgressRing(progress: nil, lineWidth: 4)
                .frame(width: 28, height: 28)

            Text(LocalizationKey.storageAnalysing.localized)
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.mainText)

            Spacer(minLength: SiftMetrics.spacingS)

            SiftSecondaryButton(titleKey: .storageCancelAnalysis) {
                environment.cancelStorageAnalysis()
            }
            .keyboardShortcut(.cancelAction)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.analyzing")
    }

    // MARK: - The measurement

    /// The bytes the map's fields add up to: what this run measured.
    ///
    /// Not `totalBytes` — that is the volume's capacity, and printing it here
    /// would answer a question the page never asked.
    private var measuredBytes: Int64 {
        let summed = analysis.categories.reduce(Int64(0)) { $0 + $1.sizeInBytes }
        return summed > 0 ? summed : analysis.scannedByteCount
    }

    private var distribution: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                HStack(alignment: .top, spacing: SiftMetrics.spacingXXL) {
                    measuredMetric
                    categoryLegend
                }

                if analysis.categories.isEmpty {
                    SiftEmptyState(
                        symbolName: "chart.bar.xaxis",
                        titleKey: .diagnosticsEmpty
                    )
                    .frame(height: 180)
                } else {
                    StorageTreemap(categories: analysis.categories)
                        .frame(height: 300)
                }

                usageBar
            }
        }
    }

    /// The one number the page is about, and the sentences that keep it honest:
    /// what the scope covered, and — when the walk hit its budget or the disk's
    /// clones make allocated space non-additive — that it is an estimate
    /// (invariants 15 and 28). A partial measurement is never presented as a
    /// total, so those two sentences sit under the figure and not at the bottom of
    /// the page.
    private var measuredMetric: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(SiftFormat.bytes(measuredBytes))
                .font(SiftFont.metricPrimary)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizationKey.storageScopeNote.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .leading)

            if report.hasApproximateSizes {
                Text(LocalizationKey.diagnosticsNoteApproximate.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.reviewTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The map's legend: the exact value behind every field.
    ///
    /// The map answers "which field is biggest"; only a list can answer "how much
    /// is that". Both read the same `categoryPalette` index, so a category cannot
    /// be one colour in the map and another in the legend.
    private var categoryLegend: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.storageCategoryDetail.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.quietText)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 0), spacing: SiftMetrics.spacingL, alignment: .leading),
                    GridItem(.flexible(minimum: 0), spacing: 0, alignment: .leading),
                ],
                alignment: .leading,
                spacing: SiftMetrics.spacingXS
            ) {
                ForEach(analysis.categories) { category in
                    legendEntry(category)
                }
            }
        }
        .frame(width: Self.legendWidth, alignment: .leading)
    }

    private func legendEntry(_ category: StorageAnalysis.Category) -> some View {
        HStack(spacing: SiftMetrics.spacingS) {
            // The palette index, never the palette itself re-ordered: an index is
            // positional, so a call site that reorders it repaints every other
            // page's category identity.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StorageCategoryTint.tint(for: category.id))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            Text(category.title)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: SiftMetrics.spacingS)

            Text(category.formattedSize)
                .font(SiftFont.monospacedNumber)
                .foregroundStyle(SiftColor.mainText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Used against the whole volume, then what is left free.
    private var usageBar: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            if !usageSegments.isEmpty {
                SegmentedUsageBar(segments: usageSegments, height: 8)
                    .accessibilityHidden(true)
            }

            HStack(spacing: SiftMetrics.spacingL) {
                Text(
                    LocalizationKey.storageUsed.localized(
                        analysis.formattedUsage,
                        analysis.formattedTotal
                    )
                )
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)

                Spacer(minLength: SiftMetrics.spacingS)

                Text(LocalizationKey.storageAvailableSpace.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                Text(analysis.formattedFree)
                    .font(SiftFont.monospacedNumber)
                    .foregroundStyle(SiftColor.mainText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The usage bar accounts for the whole volume: the measured categories, the
    /// part of "used" the analysis could not attribute, and the free space.
    private var usageSegments: [SegmentedUsageBar.Segment] {
        guard analysis.totalBytes > 0 else { return [] }
        let total = Double(analysis.totalBytes)
        var segments: [SegmentedUsageBar.Segment] = analysis.categories.enumerated().map { _, category in
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

    /// What can be reclaimed, and the one action that acts on it. No gradient, no
    /// raised card: the sentence is the emphasis, and it is in the page's accent
    /// only where a sentence is the page's one accent.
    private var suggestion: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.storageSuggestionTitle.localized)
                    .font(SiftFont.sectionHeading)
                    .foregroundStyle(SiftColor.mainText)

                Text(
                    LocalizationKey.storageCleanableHeading.localized(
                        SiftFormat.bytes(analysis.reclaimableBytes)
                    )
                )
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)

                Text(LocalizationKey.storageSuggestionDetail.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SiftPrimaryButton(titleKey: .storageGoClean) {
                    onGoClean()
                }
                .padding(.top, SiftMetrics.spacingXS)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Completeness

    @ViewBuilder
    private var coverageBanners: some View {
        switch report.coverage {
        case .complete:
            // The diagnostic providers can be complete while the category walk
            // could not read a folder. The totals are a lower bound in that case
            // too, so the page must not call them complete.
            if analysis.skippedCount > 0 {
                NoticeBanner(level: .warning, titleKey: .diagnosticsCoveragePartial)
            } else {
                NoticeBanner(level: .success, titleKey: .diagnosticsCoverageComplete)
            }
        case .partial:
            NoticeBanner(level: .warning, titleKey: .diagnosticsCoveragePartial)
        case .permissionDenied:
            // Invariant 43: a TCC refusal is the one refusal a grant lifts, so it
            // is the one that offers the pane. The two others say whose decision
            // it was and offer nothing.
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

    private var notes: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(LocalizationKey.diagnosticsNoteReadOnly.localized)
            Text(LocalizationKey.storageLocalNote.localized)
        }
        .font(SiftFont.supporting)
        .foregroundStyle(SiftColor.quietText)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Findings

    /// Three plain lists, each one claim about what may be done with the space.
    ///
    /// A finding is not a cleanup item (invariant 16): it carries no selection, no
    /// risk level and no route into the cleanup pipeline. Protected findings and
    /// APFS snapshots are reported at full strength and never offered an action
    /// (invariant 34) — the snapshot list links to the pane that owns them
    /// instead, because reclaiming one needs an administrator.
    @ViewBuilder
    private var findingsSections: some View {
        findingsSection(titleKey: .diagnosticsSectionRebuildable, findings: report.rebuildableFindings)

        findingsSection(titleKey: .diagnosticsSectionProtected, findings: report.protectedFindings)

        findingsSection(
            titleKey: .diagnosticsSectionSnapshots,
            findings: report.snapshotFindings,
            actionTitle: .diagnosticsSnapshotsOpenTimeMachine,
            action: { Task { await environment.openTimeMachineSettings() } }
        )
    }

    @ViewBuilder
    private func findingsSection(
        titleKey: LocalizationKey,
        findings: [StorageFinding],
        actionTitle: LocalizationKey? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        if !findings.isEmpty {
            SiftSection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                        Text(titleKey.localized)
                            .font(SiftFont.sectionHeading)
                            .foregroundStyle(SiftColor.mainText)

                        Spacer(minLength: SiftMetrics.spacingS)

                        Text(SiftFormat.bytes(findings.reduce(Int64(0)) { $0 + $1.allocatedBytes }))
                            .font(SiftFont.monospacedNumber)
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                    .padding(.bottom, SiftMetrics.spacingS)

                    SiftHairline()

                    ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                        if index > 0 {
                            SiftHairline()
                        }
                        StorageFindingRow(finding: finding) {
                            guard let path = finding.path else { return }
                            Task { await environment.reveal(path) }
                        }
                    }

                    if let actionTitle, let action {
                        SiftHairline()
                        Button(action: action) {
                            Label(actionTitle.localized, systemImage: "arrow.up.forward.app")
                                .font(SiftFont.supporting)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                        .padding(.top, SiftMetrics.spacingS)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Largest items

    /// Folders and files side by side: the same row shape, so a size in one column
    /// can be compared with a size in the other.
    private var largestItems: some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingXXL) {
            largestDirectories
            largestFiles
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var largestDirectories: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                listHeader(.storageTopDirectories)
                SiftHairline()

                ForEach(visibleDirectories) { directory in
                    StoragePathRow(
                        name: directory.displayName,
                        path: directory.displayPath,
                        detail: SiftFormat.bytes(directory.sizeInBytes),
                        secondary: LocalizationKey.commonFileCount.counted(directory.fileCount)
                    ) {
                        Task { await environment.reveal(directory.url) }
                    }
                }

                if analysis.topDirectories.count > visibleDirectories.count {
                    SiftHairline()
                    showAllButton(
                        shown: visibleDirectories.count,
                        total: analysis.topDirectories.count
                    ) {
                        showAllDirectories = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var largestFiles: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                listHeader(.storageTopFiles)
                SiftHairline()

                ForEach(visibleFiles) { file in
                    StoragePathRow(
                        name: file.displayName,
                        path: file.displayPath,
                        detail: SiftFormat.bytes(file.sizeInBytes),
                        secondary: file.modifiedAt.map { SiftFormat.day($0) } ?? ""
                    ) {
                        Task { await environment.reveal(file.url) }
                    }
                }

                if analysis.topFiles.count > visibleFiles.count {
                    SiftHairline()
                    showAllButton(shown: visibleFiles.count, total: analysis.topFiles.count) {
                        showAllFiles = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func listHeader(_ titleKey: LocalizationKey) -> some View {
        Text(titleKey.localized)
            .font(SiftFont.sectionHeading)
            .foregroundStyle(SiftColor.mainText)
            .padding(.bottom, SiftMetrics.spacingS)
    }

    private func showAllButton(shown: Int, total: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizationKey.commonOf.localized("\(shown)", "\(total)"))
                .font(SiftFont.supporting)
        }
        .buttonStyle(SiftLinkButtonStyle())
        .padding(.top, SiftMetrics.spacingS)
    }

    private var visibleFiles: [StorageAnalysis.FileEntry] {
        showAllFiles ? analysis.topFiles : Array(analysis.topFiles.prefix(6))
    }

    private var visibleDirectories: [StorageAnalysis.DirectoryEntry] {
        showAllDirectories ? analysis.topDirectories : Array(analysis.topDirectories.prefix(6))
    }

    // MARK: - What could not be read

    /// Every directory the run could not read, with the reason it could not.
    ///
    /// The three reasons stay apart (invariant 43): this product's own protection
    /// list, a location whose mode bits refuse this account, and a TCC refusal —
    /// macOS answering. The diagnostic side carries the last two as
    /// `permissionDenied` and `unreadable`; only `permissionDenied` is a grant away
    /// from being read (`needsFullDiskAccess`), which is why only it makes the
    /// section offer the pane. An `unreadable` row states the refusal and offers
    /// nothing, because there is nothing to offer.
    @ViewBuilder
    private var skippedLocations: some View {
        if !report.skips.isEmpty {
            SiftSection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                        Text(LocalizationKey.diagnosticsSectionSkipped.localized)
                            .font(SiftFont.sectionHeading)
                            .foregroundStyle(SiftColor.mainText)

                        Spacer(minLength: SiftMetrics.spacingS)

                        if !report.permissionSkips.isEmpty {
                            Button {
                                Task { await environment.openPermissionSettings() }
                            } label: {
                                Text(LocalizationKey.scanOpenSystemSettings.localized)
                                    .font(SiftFont.supporting)
                            }
                            .buttonStyle(SiftLinkButtonStyle())
                        }
                    }
                    .padding(.bottom, SiftMetrics.spacingS)

                    SiftHairline()

                    ForEach(Array(report.skips.enumerated()), id: \.element.id) { index, skip in
                        if index > 0 {
                            SiftHairline()
                        }
                        skippedRow(skip)
                    }
                }
            }
        }
    }

    private func skippedRow(_ skip: DiagnosticSkip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
            Image(systemName: skip.reason.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    skip.reason.needsFullDiskAccess
                        ? SiftColor.reviewTextColor
                        : SiftColor.quietText
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(skip.reason.localizedTitle)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(skip.displayPath)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: SiftMetrics.spacingS)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Treemap

/// The space map: one field per file type, sized by what it occupies.
///
/// A binary treemap rather than a pie: the eye compares rectangles more accurately
/// than angles, and the largest field has room for a label at the size a pie slice
/// would need a leader line. Fields are a wash of one palette entry each — flat,
/// with a hairline border, no gradient and no lift — because the fill states a
/// category and the area states a size, and a third message in the same field
/// would be one too many. Fields too small for a label are still read out by
/// VoiceOver with their name and size.
struct StorageTreemap: View {
    let categories: [StorageAnalysis.Category]

    var body: some View {
        GeometryReader { geometry in
            let tiles = Self.layout(categories, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    TreemapTileView(tile: tile, tint: StorageCategoryTint.tint(for: tile.category.id))
                        .frame(width: max(tile.rect.width - 6, 0), height: max(tile.rect.height - 6, 0))
                        .offset(x: tile.rect.minX + 3, y: tile.rect.minY + 3)
                }
            }
        }
        .accessibilityElement(children: .contain)
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

/// One field of the space map.
///
/// Hover changes the wash and the border, never the geometry: a field that lifts
/// under the pointer moves its neighbours' edges, and a map is read by comparing
/// them. Under Reduce Motion the change is immediate rather than absent, because
/// the pointer still has to be answered.
private struct TreemapTileView: View {
    let tile: StorageTreemap.StorageTreemapTile
    let tint: Color

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        let showsValue = tile.rect.width > 96 && tile.rect.height > 54
        let showsName = tile.rect.width > 64 && tile.rect.height > 34

        return RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
            .fill(tint.opacity(isHovering ? 0.26 : 0.18))
            .overlay {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .strokeBorder(
                        tint.opacity(isHovering ? 0.60 : 0.40),
                        lineWidth: SiftMetrics.panelBorderWidth
                    )
            }
            .overlay(alignment: .topLeading) {
                if showsName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.category.title)
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.mainText)
                            .lineLimit(2)
                        if showsValue {
                            Text(tile.category.formattedSize)
                                .font(SiftFont.monospacedNumber)
                                .foregroundStyle(SiftColor.secondaryText)
                        }
                    }
                    .padding(SiftMetrics.spacingS)
                }
            }
            .animation(
                SiftMotion.respectingReduceMotion(SiftMotion.hover, reduceMotion: reduceMotion),
                value: isHovering
            )
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(tile.category.title))
            .accessibilityValue(Text(tile.category.formattedSize))
    }
}

// MARK: - Rows

/// One finding: what it is, how much it holds, what may be done with it.
///
/// The status is a word **and** a glyph in the status colour, never the colour
/// alone: the three values mean three different things — this may be cleaned,
/// this can only be rebuilt, this is never touched — and a reader who cannot tell
/// amber from grey must still be able to tell them apart.
private struct StorageFindingRow: View {
    let finding: StorageFinding
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.displayName)
                    .font(SiftFont.bodyEmphasis)
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(finding.explanationKey.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.category.localizedTitle)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: SiftMetrics.spacingS)

            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText)
                    .font(SiftFont.monospacedNumber)
                    .foregroundStyle(SiftColor.mainText)

                HStack(spacing: SiftMetrics.spacingXS) {
                    Image(systemName: finding.status.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(finding.status.localizedTitle)
                        .font(SiftFont.supporting)
                }
                .foregroundStyle(finding.status.textColor)

                Text(remediationKey.localized)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)

            if finding.path != nil {
                SiftIconButton(
                    symbolName: "magnifyingglass.circle",
                    help: LocalizationKey.filesRevealInFinder.localized,
                    action: onReveal
                )
                .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
            }
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .frame(minHeight: SiftMetrics.rowHeight)
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
///
/// Two lines, because a name alone does not say which of several folders it is;
/// the size sits right-aligned in monospaced digits so a column of them lines up
/// and can be read as one column.
struct StoragePathRow: View {
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
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: SiftMetrics.spacingS)

            VStack(alignment: .trailing, spacing: 1) {
                Text(detail)
                    .font(SiftFont.monospacedNumber)
                    .foregroundStyle(SiftColor.mainText)
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)

            SiftIconButton(
                symbolName: "magnifyingglass.circle",
                help: LocalizationKey.filesRevealInFinder.localized,
                action: onReveal
            )
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
        }
        .padding(.vertical, SiftMetrics.spacingXS)
        .frame(minHeight: SiftMetrics.rowHeight)
    }
}

// MARK: - Labels

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

    /// The glyph beside the status word, so the three values are never told apart
    /// by colour alone.
    var symbolName: String {
        switch self {
        case .cleanable: "checkmark.circle.fill"
        case .rebuildable: "arrow.triangle.2.circlepath"
        case .protected: "shield.lefthalf.filled"
        case .unknown: "questionmark.circle"
        }
    }

    /// The status word beside a finding's size. It is only ever read as a caption's
    /// foreground, so it is a text role and takes the text twins of the risk
    /// palette rather than the fills behind them. `rebuildable` is amber because
    /// it names a decision that is the user's; `protected` is the muted token
    /// because it names a refusal that is the product's and will not change.
    var textColor: Color {
        switch self {
        case .cleanable: SiftColor.safeTextColor
        case .rebuildable: SiftColor.reviewTextColor
        case .protected: SiftColor.protectedTextColor
        case .unknown: SiftColor.quietText
        }
    }
}

extension DiagnosticSkipReason {
    /// The sentence that says whose decision the refusal was (invariant 43).
    ///
    /// `unreadable` takes the partial-failure line rather than a claim about
    /// ownership: the engine classified it as neither a TCC refusal nor a
    /// system-restricted directory, and the page does not invent the third answer.
    var localizedTitle: String {
        switch self {
        case .permissionDenied: LocalizationKey.scanSkippedReasonPermissionDenied.localized
        case .unreadable: LocalizationKey.scanSkippedReasonPartialFailure.localized
        case .volumeUnavailable: LocalizationKey.storageDiskDisconnected.localized
        }
    }

    var symbolName: String {
        switch self {
        case .permissionDenied: "lock.fill"
        case .unreadable: "questionmark.circle"
        case .volumeUnavailable: "externaldrive.badge.questionmark"
        }
    }
}

/// One colour assignment for a storage category, shared by the map and the list
/// so the same category cannot be two colours on one page.
///
/// The index is positional: entries are appended to `SiftColor.categoryPalette`,
/// never inserted, so this table and the palette can only grow together.
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
