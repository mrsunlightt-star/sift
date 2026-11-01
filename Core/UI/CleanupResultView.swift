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
    /// What the Trash holds, read when the page appears.
    ///
    /// The footer only offers to empty the bin when there is something in it, and
    /// the confirmation says how much: an action that permanently removes files
    /// has to state what it is about to remove.
    let loadTrash: () async -> TrashService.Snapshot
    /// Empties exactly the batch the confirmation described.
    let onEmptyTrash: (TrashService.Snapshot) async -> TrashService.Outcome
    let onRevealFailed: (URL) -> Void
    let onRequestPurchase: () -> Void
    /// A failure the shell hit while exporting; the local report still exists.
    let statusMessage: String?

    /// The Trash as it was when the page appeared.
    ///
    /// Empty until the first read, and empty again after a successful emptying:
    /// a button that offers to empty a bin it just emptied is the state this
    /// keeps out of the page.
    @State private var trash: TrashService.Snapshot = .empty
    @State private var isConfirmingEmptyTrash = false
    @State private var isTrashBusy = false
    /// What emptying the bin could not remove, if anything.
    @State private var emptyTrashFailure: String?

    public init(
        outcome: CleanupOutcome,
        report: CleanupReport?,
        onAcknowledge: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onOpenTrash: @escaping () -> Void,
        loadTrash: @escaping () async -> TrashService.Snapshot = { .empty },
        onEmptyTrash: @escaping (TrashService.Snapshot) async -> TrashService.Outcome = { _ in .none },
        onRevealFailed: @escaping (URL) -> Void,
        onRequestPurchase: @escaping () -> Void,
        statusMessage: String? = nil
    ) {
        self.outcome = outcome
        self.report = report
        self.onAcknowledge = onAcknowledge
        self.onExport = onExport
        self.onOpenTrash = onOpenTrash
        self.loadTrash = loadTrash
        self.onEmptyTrash = onEmptyTrash
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
        .task {
            // Read on appear rather than in `init`: the page is built before the
            // files finish moving, and a snapshot taken then would describe the
            // bin before this cleanup filled it.
            trash = await loadTrash()
        }
        .alert(
            LocalizationKey.trashEmptyAction.localized,
            isPresented: $isConfirmingEmptyTrash
        ) {
            Button(LocalizationKey.commonRemove.localized, role: .destructive) {
                Task { await emptyTrash() }
            }
            Button(LocalizationKey.commonClose.localized, role: .cancel) {}
        } message: {
            Text(LocalizationKey.trashEmptyMessage.localized(trashSummary))
        }
    }

    /// "12 items · 1.2 GB", the sentence the confirmation is about.
    private var trashSummary: String {
        let items = LocalizationKey.commonItemCount.localized(trash.count)
        let bytes = SiftFormat.bytes(trash.totalBytes)
        return "\(items) · \(bytes)"
    }

    private func emptyTrash() async {
        isTrashBusy = true
        defer { isTrashBusy = false }
        let outcome = await onEmptyTrash(trash)
        trash = await loadTrash()
        emptyTrashFailure = outcome.isComplete
            ? nil
            : LocalizationKey.cleanupFailurePartialFailure.localized
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
                        .siftFont(.display)
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
            if let emptyTrashFailure {
                NoticeBanner(level: .warning, message: emptyTrashFailure)
            }
            HStack(spacing: SiftMetrics.spacingM) {
                SiftSecondaryButton(
                    title: LocalizationKey.cleanupResultShowTrash.localized,
                    symbolName: "trash"
                ) {
                    onOpenTrash()
                }

                // Emptied here rather than in the Finder: the undo this product
                // promises is the Trash, and the space is only reclaimed when it
                // is emptied — so the step belongs next to the result that filled
                // it, with the count and the size stated before it happens.
                if !trash.isEmpty {
                    SiftSecondaryButton(
                        title: LocalizationKey.trashEmptyAction.localized,
                        symbolName: "trash.slash"
                    ) {
                        isConfirmingEmptyTrash = true
                    }
                    .disabled(isTrashBusy)
                }

                // The uninstaller has no stored report, and a failed local write
                // leaves the cleanup result without one. A button that opens
                // nothing is worse than no button.
                if report != nil {
                    SiftSecondaryButton(
                        title: LocalizationKey.cleanupResultExportReport.localized,
                        symbolName: "doc.text"
                    ) {
                        onExport()
                    }
                }

                Spacer()

                SiftPrimaryButton(title: LocalizationKey.commonDone.localized) {
                    onAcknowledge()
                }
                .keyboardShortcut(.defaultAction)
            }
            Text(LocalizationKey.reportPrivacyNote.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
