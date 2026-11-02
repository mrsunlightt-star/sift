import AppKit
import Shared
import SwiftUI

/// The cleanup result (§5.2).
///
/// Three claims this page must not make, all of them the same mistake in
/// different clothes:
///
///  * "released 10.2 GB" while the bytes are still in the Trash — the space is
///    reclaimed when the bin is emptied, so the page says "moved to the Trash"
///    and states when the space comes back;
///  * "everything succeeded" while rows failed — failures and skips are listed
///    with the reason, and the failed ones can be retried from here;
///  * "you can undo it" without offering the undo — the batch can be put back
///    until the bin is emptied, and the button says so or says why it cannot.
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
    ///
    /// The answer is the gate's verdict rather than the removal, because the
    /// removal is not the only possible answer: `emptyTrash` is the only
    /// permanent deletion in the product, so it claims the destructive slot and
    /// checks the entitlement first, and a page that rendered "0 items" for
    /// either refusal would describe a deletion that never happened.
    let onEmptyTrash: (TrashService.Snapshot) async -> TrashEmptyResult
    let onRevealFailed: (URL) -> Void
    /// Re-runs the failed rows. A retry is a fresh pre-flight, so it may fail
    /// again for the same reason — the page says which reason.
    var onRetryFailed: (([FileOperationResult]) -> Void)?
    /// Puts the batch back where it came from.
    var onUndo: (() -> Void)?
    let onRequestPurchase: () -> Void
    /// A failure the shell hit while exporting; the local report still exists.
    let statusMessage: String?

    /// The Trash as it was when the page appeared.
    @State private var trash: TrashService.Snapshot = .empty
    @State private var isConfirmingEmptyTrash = false
    @State private var isTrashBusy = false
    /// What emptying the bin produced, when it left something behind.
    ///
    /// The bin reports per entry, and the page used to collapse that into one
    /// sentence: the user was told "partly completed" and left with no idea
    /// which of two dozen files had refused to go.
    @State private var emptyTrashLeftovers: [TrashService.Outcome.Failure] = []
    @State private var emptyTrashFailed = false
    /// The volume's available capacity, measured after the move.
    ///
    /// This is the only number that can honestly be called "released", so it is
    /// measured rather than computed from the sizes the plan expected.
    @State private var availableNow: Int64?
    @State private var copiedReason: UUID?

    public init(
        outcome: CleanupOutcome,
        report: CleanupReport?,
        onAcknowledge: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onOpenTrash: @escaping () -> Void,
        loadTrash: @escaping () async -> TrashService.Snapshot = { .empty },
        onEmptyTrash: @escaping (TrashService.Snapshot) async -> TrashEmptyResult = { _ in .executed(.none) },
        onRevealFailed: @escaping (URL) -> Void,
        onRetryFailed: (([FileOperationResult]) -> Void)? = nil,
        onUndo: (() -> Void)? = nil,
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
        self.onRetryFailed = onRetryFailed
        self.onUndo = onUndo
        self.onRequestPurchase = onRequestPurchase
        self.statusMessage = statusMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
            header
            metrics
            if outcome.wasStopped {
                NoticeBanner(
                    level: .information,
                    message: LocalizationKey.cleanupResultStopped.localized(outcome.movedCount)
                )
            }
            if outcome.hasFailures {
                failureList
            }
            if !outcome.skippedResults.isEmpty {
                skippedList
            }
            footer
        }
        .padding(SiftMetrics.spacingXL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            trash = await loadTrash()
            availableNow = Self.availableCapacity()
        }
        .alert(
            LocalizationKey.trashEmptyAction.localized,
            isPresented: $isConfirmingEmptyTrash
        ) {
            Button(LocalizationKey.trashEmptyConfirmAction.localized, role: .destructive) {
                Task { await emptyTrash() }
            }
            Button(LocalizationKey.commonClose.localized, role: .cancel) {}
        } message: {
            Text(LocalizationKey.trashEmptyMessage.localized(trashSummary))
        }
    }

    /// Free space of the volume the user's home lives on, in bytes.
    static func availableCapacity() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let exact = values?.volumeAvailableCapacityForImportantUsage {
            return exact
        }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))
            .flatMap { $0.volumeAvailableCapacity.map(Int64.init) }
    }

    /// "12 items · 1.2 GB", the sentence the confirmation is about.
    private var trashSummary: String {
        let items = LocalizationKey.commonItemCount.counted(trash.count)
        let bytes = SiftFormat.bytes(trash.totalBytes)
        return "\(items) · \(bytes)"
    }

    private func emptyTrash() async {
        isTrashBusy = true
        defer { isTrashBusy = false }
        let result = await onEmptyTrash(trash)
        switch result {
        case .busy:
            return
        case .purchaseRequired:
            emptyTrashLeftovers = []
            emptyTrashFailed = false
            onRequestPurchase()
            return
        case let .executed(outcome):
            trash = await loadTrash()
            availableNow = Self.availableCapacity()
            emptyTrashLeftovers = outcome.failures
            emptyTrashFailed = !outcome.isComplete
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: outcome.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(SiftColor.textColor(for: outcome.hasFailures ? .review : .safe))
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

    // MARK: - Metrics

    /// Three facts, none of them overstated.
    ///
    /// "Released" is the one word that must not appear here while the bin still
    /// holds the bytes: it is only true once the Trash is empty, and the page
    /// either knows that from the bin it just read or does not claim it.
    private var metrics: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack(spacing: SiftMetrics.spacingM) {
                metric(
                    outcome.formattedReleased,
                    caption: trash.isEmpty
                        ? LocalizationKey.dashboardCleanupCompleted.localized
                        : LocalizationKey.reportMoved.localized,
                    symbolName: trash.isEmpty ? "internaldrive" : "trash",
                    tint: trash.isEmpty ? SiftColor.safeText : SiftColor.accentText
                )
                metric(
                    SiftFormat.count(outcome.movedCount),
                    caption: LocalizationKey.commonItemCount.counted(outcome.movedCount),
                    symbolName: "checkmark.circle",
                    tint: SiftColor.safeText
                )
                metric(
                    SiftFormat.count(outcome.failedCount),
                    caption: LocalizationKey.reportFailed.localized,
                    symbolName: "exclamationmark.triangle",
                    tint: outcome.failedCount > 0 ? SiftColor.reviewText : SiftColor.subtleText
                )
            }
            // Only while the space has not been reclaimed: the sentence states
            // what emptying the bin will do, and what the disk says right now.
            if !trash.isEmpty {
                Text(spaceSentence)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var spaceSentence: String {
        let reclaim = LocalizationKey.cleanupResultReclaimAfterEmpty.localized(
            SiftFormat.bytes(outcome.releasedBytes)
        )
        guard let availableNow else { return reclaim }
        let measured = LocalizationKey.dashboardDiskFree.localized(SiftFormat.bytes(availableNow))
        return "\(reclaim) · \(measured)"
    }

    private func metric(
        _ value: String,
        caption: String,
        symbolName: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            IconTile(symbolName: symbolName, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(SiftFont.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SiftMetrics.spacingM)
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                .fill(SiftColor.subtleFill)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Failures

    private var failureList: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizationKey.reportFailed.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer(minLength: SiftMetrics.spacingS)
                    if let onRetryFailed {
                        Button {
                            onRetryFailed(outcome.failedResults)
                        } label: {
                            Text(
                                LocalizationKey.cleanupResultRetryCount
                                    .localized(outcome.failedResults.count)
                            )
                            .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                        .accessibilityIdentifier("result.retryFailed")
                    }
                }
                Divider()
                ForEach(outcome.failedResults) { result in
                    resultRow(result, symbolName: "exclamationmark.triangle.fill", tint: SiftColor.reviewText)
                }
            }
        }
    }

    /// One item that was not moved, and why.
    ///
    /// Shared by both lists so a skipped item and a failed one are described the
    /// same way: the path, the reason from the product error table, its size, and
    /// the three things a user can do about it — look at it, try it again, or
    /// take the reason somewhere.
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

            // Reachable without a context menu: a failed row is exactly the row
            // a user wants to look at, and the page used to render a stored
            // `onRevealFailed` that nothing ever called.
            Button {
                onRevealFailed(result.sourceURL)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SiftLinkButtonStyle())
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "\(result.displayPath) — \(result.failureTitle)",
                    forType: .string
                )
                copiedReason = result.id
            } label: {
                Image(systemName: copiedReason == result.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SiftLinkButtonStyle())
            .help(LocalizationKey.commonCopyReason.localized)
            .accessibilityLabel(Text(LocalizationKey.commonCopyReason.localized))
        }
        .accessibilityElement(children: .combine)
    }

    /// What was left alone, listed rather than only counted.
    private var skippedList: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.reportSkipped.localized)
                    .font(SiftFont.sectionTitle)
                Text(LocalizationKey.reportSkippedDetail.localized(outcome.skippedResults.count))
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                if !outcome.skippedResults.isEmpty {
                    Divider()
                    ForEach(Array(outcome.skippedResults.prefix(20))) { result in
                        resultRow(result, symbolName: "minus.circle.fill", tint: SiftColor.subtleText)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            if let statusMessage {
                NoticeBanner(level: .warning, message: statusMessage)
            }
            if emptyTrashFailed {
                NoticeBanner(
                    level: .warning,
                    message: LocalizationKey.cleanupFailurePartialFailure.localized
                )
                if !emptyTrashLeftovers.isEmpty {
                    SiftPanel {
                        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                            ForEach(Array(emptyTrashLeftovers.prefix(5).enumerated()), id: \.offset) { _, leftover in
                                HStack(spacing: SiftMetrics.spacingS) {
                                    Text(leftover.url.lastPathComponent)
                                        .font(SiftFont.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: SiftMetrics.spacingS)
                                    Text(leftover.message)
                                        .font(SiftFont.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if emptyTrashLeftovers.count > 5 {
                                Text(
                                    LocalizationKey.overviewMoreItems.localized(
                                        emptyTrashLeftovers.count - 5,
                                        ""
                                    )
                                )
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.subtleText)
                            }
                        }
                    }
                }
            }
            HStack(spacing: SiftMetrics.spacingM) {
                if let onUndo {
                    SiftSecondaryButton(
                        title: LocalizationKey.cleanupResultUndoAction.localized,
                        symbolName: "arrow.uturn.backward"
                    ) {
                        onUndo()
                    }
                    .disabled(outcome.movedCount == 0)
                    .accessibilityIdentifier("result.undo")
                }

                SiftSecondaryButton(
                    title: LocalizationKey.cleanupResultShowTrash.localized,
                    symbolName: "trash"
                ) {
                    onOpenTrash()
                }

                if let unreadable = trash.unreadable {
                    Text(unreadable.titleKey.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    if unreadable.offersSettingsAction {
                        Button {
                            Task { await WorkspaceActions.openFullDiskAccessSettings() }
                        } label: {
                            Text(LocalizationKey.scanOpenSystemSettings.localized)
                                .font(SiftFont.caption)
                        }
                        .buttonStyle(SiftLinkButtonStyle())
                    }
                } else if !trash.isEmpty {
                    SiftSecondaryButton(
                        title: LocalizationKey.trashEmptyAction.localized,
                        symbolName: "trash.slash"
                    ) {
                        isConfirmingEmptyTrash = true
                    }
                    .disabled(isTrashBusy)
                }

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
                .foregroundStyle(SiftColor.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
