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
///
/// The page has one primary number and one list per outcome. The number is what
/// moved to the Trash, because that is the only quantity the move actually
/// produced; the counts beside it say how much of the batch that was. A row per
/// item follows, grouped by what happened to it — failed, then skipped — with the
/// remedy the error table names and nothing invented by the view.
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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, SiftMetrics.spacingL)

            SiftHairline()
            primaryMetric
            SiftHairline()

            if outcome.wasStopped {
                NoticeBanner(
                    level: .information,
                    message: LocalizationKey.cleanupResultStopped.localized(outcome.movedCount)
                )
                .padding(.top, SiftMetrics.spacingL)
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

    /// The outcome, one line: what happened, then what is still on the disk.
    ///
    /// The icon and the title come from the same value, so a page cannot show a
    /// green tick beside a refusal. `CleanupOutcome.headline` decides the title;
    /// the view only draws it.
    private var header: some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            Image(systemName: outcome.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(outcome.hasFailures ? SiftColor.reviewTextColor : SiftColor.actionGreen)
                .frame(width: 28, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // The title states the outcome, not the fact that the page
                // opened. "Cleanup finished" above a 2 GB application that
                // refused to move is a sentence the user has to argue with;
                // the warning icon alone did not say which half was true.
                Text(resultTitle.localized)
                    .siftFont(.display)
                    .foregroundStyle(SiftColor.mainText)
                Text(resultSubtitle)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Cleanup finished", "Partially completed" or "Nothing was moved".
    ///
    /// The decision lives in `CleanupOutcome.headline` so it is asserted by a
    /// test instead of being a property of a view body.
    private var resultTitle: LocalizationKey {
        switch outcome.headline {
        case .finished: .cleanupResultTitle
        case .partiallyCompleted: .cleanupResultTitlePartial
        case .nothingMoved: .cleanupResultTitleFailed
        }
    }

    /// What the bin holds and what stayed behind, in that order.
    ///
    /// A failed row is not an error message: it is an item still on the disk,
    /// and the page has to say so before it talks about undo.
    private var resultSubtitle: String {
        guard outcome.hasFailures else { return LocalizationKey.cleanupResultUndoHint.localized }
        return LocalizationKey.cleanupResultKeptInPlace.localized(outcome.failedCount)
    }

    // MARK: - Primary metric

    /// One number, in the slot the eye lands on: the bytes that moved to the
    /// Trash.
    ///
    /// The three tiles this replaces gave the same weight to the successes, the
    /// failures and the bytes, and the bytes are the only one of the three the
    /// user asked about. The counts are stated beside it as facts, not as peers:
    /// "moved" then "not completed", each with its own word, neither reading as
    /// the total.
    private var primaryMetric: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingM) {
                Text(outcome.formattedReleased)
                    .font(SiftFont.metricPrimary)
                    .monospacedDigit()
                    .foregroundStyle(SiftColor.mainText)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Always "Moved to Trash", never "freed": the bytes are in the
                // bin, and the disk still holds them until it is emptied
                // (invariant 46, 02 §6). The sentence about emptying states the
                // only thing that changes when it is.
                Text(LocalizationKey.reportMoved.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: SiftMetrics.spacingS)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: SiftMetrics.spacingM) {
                // The count of what moved, said as such. It used to read
                // "1 items", which next to a green tick and a second tile
                // saying "1 not completed" could be read either way: as the
                // total, or as the successes.
                countFact(
                    symbolName: "checkmark.circle",
                    value: SiftFormat.count(outcome.movedCount),
                    caption: LocalizationKey.reportMoved.localized,
                    tint: SiftColor.actionGreen
                )

                Rectangle()
                    .fill(SiftColor.divider)
                    .frame(width: 1, height: 22)
                    .accessibilityHidden(true)

                countFact(
                    symbolName: "exclamationmark.triangle",
                    value: SiftFormat.count(outcome.failedCount),
                    caption: LocalizationKey.reportFailed.localized,
                    tint: outcome.failedCount > 0 ? SiftColor.reviewTextColor : SiftColor.quietText
                )
                Spacer(minLength: 0)
            }

            // Only while the space has not been reclaimed: the sentence states
            // what emptying the bin will do, and what the disk says right now.
            if !trash.isEmpty {
                Text(spaceSentence)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SiftMetrics.spacingL)
    }

    private var spaceSentence: String {
        let reclaim = LocalizationKey.cleanupResultReclaimAfterEmpty.localized(
            SiftFormat.bytes(outcome.releasedBytes)
        )
        guard let availableNow else { return reclaim }
        let measured = LocalizationKey.dashboardDiskFree.localized(SiftFormat.bytes(availableNow))
        return "\(reclaim) · \(measured)"
    }

    /// A count with its unit and its glyph, so the pair is never read as a pair
    /// of colours.
    private func countFact(
        symbolName: String,
        value: String,
        caption: String,
        tint: Color
    ) -> some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(SiftFont.bodyEmphasis)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
            Text(caption)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Failures

    /// The rows that did not move, each with its own reason and remedy.
    ///
    /// Plain section, hairline between rows: this is a list of items still on the
    /// disk, not a card about an error. The retry control sits in the heading
    /// because it acts on the whole list.
    private var failureList: some View {
        SiftSection(style: .plain) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizationKey.reportFailed.localized)
                        .font(SiftFont.sectionTitle)
                        .foregroundStyle(SiftColor.mainText)
                    Text(LocalizationKey.commonItemCount.counted(outcome.failedResults.count))
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
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
                .padding(.bottom, SiftMetrics.spacingS)

                SiftHairline()

                ForEach(Array(outcome.failedResults.enumerated()), id: \.element.id) { index, result in
                    if index > 0 {
                        SiftHairline(inset: SiftMetrics.spacingM)
                    }
                    resultRow(result, symbolName: "exclamationmark.triangle.fill", tint: SiftColor.reviewTextColor)
                }
            }
        }
        .padding(.top, SiftMetrics.spacingL)
    }

    /// One item that was not moved, and why.
    ///
    /// Shared by both lists so a skipped item and a failed one are described the
    /// same way: the path, the reason from the product error table, its size, and
    /// the three things a user can do about it — look at it, open the switch that
    /// lifts the refusal, or take the reason somewhere.
    private func resultRow(
        _ result: FileOperationResult,
        symbolName: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayPath)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result.failureTitle)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(SiftFormat.bytes(result.sizeInBytes))
                .font(SiftFont.monospacedNumber)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)

            // The remedy comes from the error table, so a refusal the table
            // knows how to lift is offered the switch that lifts it — and a
            // refusal it does not know is offered none. Full Disk Access was
            // hard-coded here once, and it was the wrong switch for every
            // application bundle the system refused to move.
            remedyButton(for: result)

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
        .padding(.vertical, SiftMetrics.spacingS)
        .accessibilityElement(children: .combine)
    }

    /// The switch that lifts this refusal, when the error table names one.
    ///
    /// Full Disk Access was hard-coded here once, and it is the wrong switch for
    /// every application bundle the system refuses to move: that gate is App
    /// Management, and no grant in the Full Disk Access list reaches it.
    @ViewBuilder
    private func remedyButton(for result: FileOperationResult) -> some View {
        switch result.errorCode.flatMap(ErrorCode.init(rawValue:)).flatMap(\.suggestedAction) {
        case .openSystemSettings:
            settingsButton { await WorkspaceActions.openFullDiskAccessSettings() }
        case .openAppManagement:
            settingsButton { await WorkspaceActions.openAppManagementSettings() }
        case .retry, .quitApp, nil:
            EmptyView()
        }
    }

    private func settingsButton(_ open: @escaping () async -> Void) -> some View {
        Button {
            Task { await open() }
        } label: {
            Text(LocalizationKey.scanOpenSystemSettings.localized)
                .font(SiftFont.caption)
        }
        .buttonStyle(SiftLinkButtonStyle())
    }

    /// What was left alone, listed rather than only counted.
    ///
    /// A skipped row is not a failure: the object was already gone when the move
    /// reached it. It is listed for the same reason — the batch is smaller than
    /// the confirmation described, and the difference has to be accountable.
    private var skippedList: some View {
        SiftSection(style: .plain) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizationKey.reportSkipped.localized)
                    .font(SiftFont.sectionTitle)
                    .foregroundStyle(SiftColor.mainText)
                Text(LocalizationKey.reportSkippedDetail.localized(outcome.skippedResults.count))
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .padding(.top, 2)
                SiftHairline()
                    .padding(.vertical, SiftMetrics.spacingS)
                ForEach(Array(outcome.skippedResults.prefix(20).enumerated()), id: \.element.id) { index, result in
                    if index > 0 {
                        SiftHairline(inset: SiftMetrics.spacingM)
                    }
                    resultRow(result, symbolName: "minus.circle.fill", tint: SiftColor.quietText)
                }
            }
        }
        .padding(.top, SiftMetrics.spacingL)
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
                    SiftSection(style: .plain) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(emptyTrashLeftovers.prefix(5).enumerated()), id: \.offset) { index, leftover in
                                if index > 0 {
                                    SiftHairline()
                                }
                                HStack(spacing: SiftMetrics.spacingS) {
                                    Text(leftover.url.lastPathComponent)
                                        .font(SiftFont.caption)
                                        .foregroundStyle(SiftColor.mainText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: SiftMetrics.spacingS)
                                    Text(leftover.message)
                                        .font(SiftFont.caption)
                                        .foregroundStyle(SiftColor.secondaryText)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, SiftMetrics.spacingXS)
                            }
                            if emptyTrashLeftovers.count > 5 {
                                Text(
                                    LocalizationKey.overviewMoreItems.localized(
                                        emptyTrashLeftovers.count - 5,
                                        ""
                                    )
                                )
                                .font(SiftFont.caption)
                                .foregroundStyle(SiftColor.quietText)
                            }
                        }
                    }
                }
            }

            SiftHairline()

            // One row when the window can hold it, two when it cannot. With the
            // undo, the Trash and the report actions plus a Full Disk Access
            // explainer, a single row in a normal window compressed every label
            // into "撤…", "在访达中…", "导出…" — a button nobody can read is a
            // button nobody presses.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SiftMetrics.spacingM) {
                    actionButtons
                    Spacer(minLength: SiftMetrics.spacingM)
                    doneButton
                }
                VStack(alignment: .trailing, spacing: SiftMetrics.spacingM) {
                    HStack(spacing: SiftMetrics.spacingM) {
                        actionButtons
                    }
                    doneButton
                }
            }
            .padding(.top, SiftMetrics.spacingM)

            Text(LocalizationKey.reportPrivacyNote.localized)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.quietText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, SiftMetrics.spacingL)
    }

    /// The secondary actions, each at its natural width.
    @ViewBuilder
    private var actionButtons: some View {
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
                    .foregroundStyle(SiftColor.secondaryText)
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
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var doneButton: some View {
        SiftPrimaryButton(title: LocalizationKey.commonDone.localized) {
            onAcknowledge()
        }
        .keyboardShortcut(.defaultAction)
    }
}
