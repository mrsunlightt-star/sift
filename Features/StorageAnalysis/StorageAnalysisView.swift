import Core
import Shared
import SwiftUI

/// The storage page (§5.4).
///
/// Top: the volume and its usage. Middle: category totals as labelled bars.
/// Bottom: the largest folders and files. No ring charts or sunbursts — the
/// specification ranks accurate lists above elaborate graphics, so the numbers
/// and paths lead and the bars only reinforce them.
public struct StorageAnalysisView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var analysis: StorageAnalysis = .empty
    @State private var isAnalyzing = false
    @State private var showAllFiles = false
    @State private var showAllDirectories = false
    @State private var scanTask: Task<StorageAnalysis, Never>?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .storageTitle) {
                    Button {
                        Task { await analyze() }
                    } label: {
                        Label(LocalizationKey.storageAnalyze.localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(isAnalyzing)
                }

                volumeCard

                if isAnalyzing {
                    HStack(spacing: SiftMetrics.spacingM) {
                        ProgressView().controlSize(.small)
                        Text(LocalizationKey.storageAnalysing.localized)
                            .font(SiftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if analysis.categories.isEmpty, !isAnalyzing {
                    SiftEmptyState(
                        symbolName: "chart.pie",
                        titleKey: .storageNotAuthorized
                    )
                } else {
                    categoriesCard
                    HStack(alignment: .top, spacing: SiftMetrics.spacingL) {
                        directoriesCard
                        filesCard
                    }
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .task { await analyze() }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    private var volumeCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .firstTextBaseline) {
                    Text(analysis.totalBytes > 0 ? analysis.formattedTotal : "—")
                        .font(SiftFont.metricLarge)
                    Spacer()
                    Text(analysis.volumeName.isEmpty ? LocalizationKey.storageVolume.localized : analysis.volumeName)
                        .font(SiftFont.bodyEmphasis)
                }
                Text(
                    LocalizationKey.storageUsed.localized(analysis.formattedUsed, analysis.formattedTotal)
                )
                .font(SiftFont.body)
                .foregroundStyle(.secondary)
                SegmentedUsageBar(segments: segmentedBar)
                HStack {
                    Text(LocalizationKey.dashboardDiskFree.localized(analysis.formattedFree))
                        .font(SiftFont.bodyEmphasis)
                    Spacer()
                    if analysis.reclaimableBytes > 0 {
                        Text(
                            "\(LocalizationKey.storageReclaimable.localized): \(analysis.formattedReclaimable)"
                        )
                        .font(SiftFont.bodyEmphasis)
                        .foregroundStyle(SiftColor.safe)
                    }
                }
                Text(
                    LocalizationKey.scanCheckedFiles.localized(SiftFormat.count(analysis.scannedFileCount))
                )
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
                if analysis.skippedCount > 0 {
                    Text(LocalizationKey.scanPartialNotice.localized(analysis.skippedCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.review)
                }
            }
        }
    }

    /// The stacked bar: the largest categories plus free space.
    private var segmentedBar: [SegmentedUsageBar.Segment] {
        guard analysis.totalBytes > 0 else { return [] }
        var segments: [SegmentedUsageBar.Segment] = analysis.categories.prefix(4).enumerated().map { index, category in
            SegmentedUsageBar.Segment(
                id: category.id,
                fraction: Double(category.sizeInBytes) / Double(analysis.totalBytes),
                tint: SiftColor.categoryPalette[index % SiftColor.categoryPalette.count]
            )
        }
        let used = Double(analysis.usedBytes) / Double(analysis.totalBytes)
        let listed = segments.reduce(0) { $0 + $1.fraction }
        // The remainder is what the analysis did not attribute: system files and
        // locations the user did not authorise. Naming it honestly is better than
        // letting the bar imply the categories cover the whole disk.
        if used - listed > 0.005 {
            segments.append(
                SegmentedUsageBar.Segment(
                    id: "other",
                    fraction: used - listed,
                    tint: SiftColor.neutral
                )
            )
        }
        if 1 - used > 0.005 {
            segments.append(
                SegmentedUsageBar.Segment(id: "free", fraction: 1 - used, tint: SiftColor.border)
            )
        }
        return segments
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
                        Text(LocalizationKey.commonOf.localized("\(visibleDirectories.count)", "\(analysis.topDirectories.count)"))
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
                        Text(LocalizationKey.commonOf.localized("\(visibleFiles.count)", "\(analysis.topFiles.count)"))
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var visibleFiles: [StorageAnalysis.FileEntry] {
        showAllFiles ? analysis.topFiles : Array(analysis.topFiles.prefix(8))
    }

    private var visibleDirectories: [StorageAnalysis.DirectoryEntry] {
        showAllDirectories ? analysis.topDirectories : Array(analysis.topDirectories.prefix(8))
    }

    private func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let roots = await environment.makeScanRequest(includeDuplicates: false).roots
        // The analysis walks the filesystem off the main actor, so the UI stays
        // responsive and the page can be left while it runs.
        let analyzer = environment.storageAnalyzer
        let task = Task(priority: .userInitiated) { () -> StorageAnalysis in
            (try? await analyzer.analyze(roots: roots)) ?? .empty
        }
        scanTask = task
        let result = await task.value
        guard !Task.isCancelled else { return }
        analysis = result
        scanTask = nil
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
