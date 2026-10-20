import Shared
import SwiftUI

/// The cleanup result (§5.2).
///
/// It reports what moved, what it released, what failed and why, and offers the
/// two follow-up actions the specification names: show the Trash in the Finder,
/// and export the report as PDF.
public struct CleanupResultView: View {
    let outcome: CleanupOutcome
    let report: CleanupReport?
    let onAcknowledge: () -> Void
    let onExport: () -> Void
    let onOpenTrash: () -> Void
    let onRevealFailed: (URL) -> Void
    let onRequestPurchase: () -> Void
    /// A failure the shell hit while exporting; the local report still exists.
    let statusMessage: String?

    @State private var isExporting = false

    public init(
        outcome: CleanupOutcome,
        report: CleanupReport?,
        onAcknowledge: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onOpenTrash: @escaping () -> Void,
        onRevealFailed: @escaping (URL) -> Void,
        onRequestPurchase: @escaping () -> Void,
        statusMessage: String? = nil
    ) {
        self.outcome = outcome
        self.report = report
        self.onAcknowledge = onAcknowledge
        self.onExport = onExport
        self.onOpenTrash = onOpenTrash
        self.onRevealFailed = onRevealFailed
        self.onRequestPurchase = onRequestPurchase
        self.statusMessage = statusMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
            header
            metrics
            if outcome.hasFailures {
                failureList
            }
            if !outcome.skippedResults.isEmpty {
                skippedList
            }
            footer
        }
        .padding(SiftMetrics.spacingXL)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: outcome.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(outcome.hasFailures ? SiftColor.review : SiftColor.safe)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.cleanupResultTitle.localized)
                        .font(SiftFont.display)
                    Text(LocalizationKey.cleanupResultUndoHint.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            StatTile(
                title: .cleanupResultReleased,
                value: outcome.formattedReleased,
                symbolName: "internaldrive",
                tint: SiftColor.safe
            )
            StatTile(
                title: .commonItemCount,
                value: SiftFormat.count(outcome.movedCount),
                symbolName: "trash",
                tint: SiftColor.accent
            )
            StatTile(
                title: .reportFailed,
                value: SiftFormat.count(outcome.failedCount),
                symbolName: "exclamationmark.triangle",
                tint: outcome.failedCount > 0 ? SiftColor.review : SiftColor.neutral
            )
        }
    }

    private var failureList: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.reportFailed.localized)
                    .font(SiftFont.sectionTitle)
                Divider()
                ForEach(outcome.failedResults) { result in
                    resultRow(result, symbolName: "exclamationmark.triangle.fill", tint: SiftColor.review)
                }
            }
        }
    }

    /// One item that was not moved, and why.
    ///
    /// Shared by both lists so a skipped item and a failed one are described the
    /// same way: the path, the reason from the product error table, its size, and
    /// the shortcut to Full Disk Access when that is what stood in the way.
    private func resultRow(
        _ result: FileOperationResult,
        symbolName: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            IconTile(symbolName: symbolName, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayPath)
                    .font(SiftFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result.failureTitle)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(SiftFormat.bytes(result.sizeInBytes))
                .font(SiftFont.monospacedNumber)
            if result.errorCode == ErrorCode.permissionDenied.rawValue {
                Button {
                    Task { await WorkspaceActions.openFullDiskAccessSettings() }
                } label: {
                    Text(LocalizationKey.scanOpenSystemSettings.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
        }
    }

    /// What was left alone, listed rather than only counted.
    ///
    /// The count alone cannot distinguish "the application is still running" from
    /// "the file is already gone", and the row's reason is what tells the user
    /// whether there is anything left for them to do. The detail sentence has
    /// always promised the first 20, so that is how many are shown.
    private var skippedList: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.reportSkipped.localized)
                    .font(SiftFont.sectionTitle)
                Text(
                    LocalizationKey.reportSkippedDetail.localized(
                        outcome.skippedResults.count + outcome.failedCount
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                if !outcome.skippedResults.isEmpty {
                    Divider()
                    ForEach(Array(outcome.skippedResults.prefix(20))) { result in
                        resultRow(result, symbolName: "minus.circle.fill", tint: SiftColor.review)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            if let statusMessage {
                NoticeBanner(level: .warning, message: statusMessage)
            }
            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    onOpenTrash()
                } label: {
                    Label(LocalizationKey.cleanupResultShowTrash.localized, systemImage: "trash")
                }

                Button {
                    isExporting = true
                    onExport()
                } label: {
                    Label(LocalizationKey.cleanupResultExportReport.localized, systemImage: "doc.text")
                }
                .disabled(isExporting)

                Spacer()

                Button {
                    onAcknowledge()
                } label: {
                    Text(LocalizationKey.commonDone.localized)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text(LocalizationKey.reportPrivacyNote.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
