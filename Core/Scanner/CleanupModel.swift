import Foundation
import OSLog
import Shared

/// Selection, confirmation and execution of a cleanup (§5.2, §9).
///
/// This type owns the safety boundary that matters most in the app:
///
///  * a `protected` item can never be selected, whatever the caller asks,
///  * the confirmation panel always shows the real action and the real size,
///  * the executable set is the *pre-flighted* set, so an item that vanished or
///    is held open never reaches the file operations service,
///  * the result is per item, so one failure cannot hide the successes.
@MainActor
public final class CleanupModel: ObservableObject {
    /// The items under consideration, already paged in from the scanner.
    @Published public private(set) var items: [CleanupItem] = []
    /// Ids of the selected items.
    @Published public private(set) var selection: Set<String> = []
    /// The pre-flight verdict, populated when the user asks to clean.
    @Published public private(set) var preflight: PreflightReport?
    /// The confirmation panel's visibility.
    ///
    /// Opening and closing it is the model's decision (`prepareCleanup` and
    /// `cancelConfirmation`); the page observes but does not write, so a view
    /// cannot open the panel without a verdict behind it.
    @Published public private(set) var isConfirming = false
    /// True while a batch is running.
    @Published public private(set) var isWorking = false
    /// True while a pre-flight pass is in flight.
    ///
    /// Pre-flight awaits the file-operation service. Without a flag claimed
    /// before that suspension, a second request could enter while the first was
    /// judging its candidates, and the two verdicts would race to describe what
    /// the confirmation panel shows.
    @Published public private(set) var isPreparingCleanup = false
    /// The finished outcome, shown on the result page.
    @Published public private(set) var outcome: CleanupOutcome?
    /// The report written for the last outcome.
    @Published public private(set) var report: CleanupReport?
    /// A failure that stopped the flow before any file operation.
    @Published public private(set) var failure: (code: ErrorCode, message: String)?

    private let rules: RuleEngine
    private let operations: FileOperationService
    private let reports: ReportService
    private let logger = SiftLog.cleanup
    /// Whether rows appended after the first page follow the scan's default
    /// selection. Set by `setItems`, so a page that presents items for review
    /// (file cleanup) never preselects a later page either.
    private var preselectsAppendedItems = true
    /// The operation the panel is describing. The shell executes the prepared
    /// plan after the panel closes, and the report must name the operation the
    /// user actually started rather than a default.
    public private(set) var preparedOperation: CleanupOperationName = .junkCleanup
    /// Identifies the item list a pre-flight verdict belongs to.
    ///
    /// A scan resets the model while a pre-flight pass may still be awaiting the
    /// file-operation service. The verdict then describes items that no longer
    /// exist in this list, so it is discarded instead of committed.
    private var preparationGeneration = 0

    public init(rules: RuleEngine, operations: FileOperationService, reports: ReportService) {
        self.rules = rules
        self.operations = operations
        self.reports = reports
    }

    // MARK: - Selection

    /// Replaces the item list, keeping only selections that still exist and are
    /// still cleanable.
    public func setItems(_ newItems: [CleanupItem], preselect: Bool = true) {
        items = newItems
        preselectsAppendedItems = preselect
        var next: Set<String> = []
        for item in newItems where preselect && item.isSelectedByDefault && item.risk.isCleanable {
            next.insert(item.id)
        }
        selection = next
    }

    /// Adds items to the list without disturbing the current selection.
    ///
    /// Items are keyed by their stable identity, so a page that overlaps a
    /// previous one cannot duplicate a row. New items follow the same default
    /// selection as the first screenful: the result list pages its rows, and a
    /// safe item that happened to sort onto page two must start selected for the
    /// same reason a safe item on page one does.
    public func appendItems(_ newItems: [CleanupItem]) {
        // Insert as the batch is filtered. Checking only the pre-existing ids
        // let a batch that named the same target twice append both rows.
        var known = Set(items.map(\.id))
        let added = newItems.filter { known.insert($0.id).inserted }
        items.append(contentsOf: added)
        guard preselectsAppendedItems else { return }
        for item in added where item.isSelectedByDefault && item.risk.isCleanable {
            selection.insert(item.id)
        }
    }

    public func isSelected(_ item: CleanupItem) -> Bool {
        selection.contains(item.id)
    }

    /// Selects or deselects one item.
    ///
    /// A protected item is refused here as well as in the UI: the model is what
    /// the confirmation panel reads, so it must not be able to hold an item the
    /// engine marked protected.
    public func setSelected(_ selected: Bool, for item: CleanupItem) {
        guard item.risk.isCleanable else {
            logger.notice("Ignored a selection change for a protected item")
            return
        }
        if selected {
            // A row the user checked must be part of the list the confirmation
            // panel reads, even when it came from a source that pages lazily
            // (a duplicate group, for example).
            if !items.contains(where: { $0.id == item.id }) {
                items.append(item)
            }
            selection.insert(item.id)
        } else {
            selection.remove(item.id)
        }
    }

    /// Selects every cleanable item in a group.
    public func selectAll(in newItems: [CleanupItem]) {
        for item in newItems where item.risk.isCleanable {
            if !items.contains(where: { $0.id == item.id }) {
                items.append(item)
            }
            selection.insert(item.id)
        }
    }

    /// Clears the selection entirely.
    public func deselectAll() {
        selection.removeAll()
    }

    /// Drops items whose files no longer exist, keeping the list and the
    /// selection consistent after a partial cleanup.
    public func removeItems(at urls: Set<URL>) {
        let removed = Set(items.filter { urls.contains($0.url) }.map(\.id))
        items.removeAll { urls.contains($0.url) }
        selection.subtract(removed)
    }

    /// The selected items, in list order.
    public var selectedItems: [CleanupItem] {
        items.filter { selection.contains($0.id) }
    }

    public var selectedCount: Int { selectedItems.count }

    /// Bytes of the current selection, computed from the items themselves so the
    /// button label cannot drift from the list.
    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    public var formattedSelectedBytes: String { SiftFormat.bytes(selectedBytes) }

    /// The confirmation button's label: the action and the size, spelled out
    /// (§5.2 requires both).
    public var confirmActionTitle: String {
        let count = selectedCount
        let size = formattedSelectedBytes
        return count == 1
            ? LocalizationKey.cleanupConfirmMoveCountOne.localized(size)
            : LocalizationKey.cleanupConfirmMoveCount.localized(count, size)
    }

    /// Selection broken down by category for the confirmation panel.
    public var selectedByCategory: [CategoryTotal] {
        Self.categoryTotals(for: selectedItems)
    }

    private static func categoryTotals(for items: [CleanupItem]) -> [CategoryTotal] {
        var totals: [CleanupCategory: (count: Int, bytes: Int64)] = [:]
        for item in items {
            var entry = totals[item.category] ?? (0, 0)
            entry.count += 1
            entry.bytes += item.sizeInBytes
            totals[item.category] = entry
        }
        return totals
            .map { CategoryTotal(category: $0.key, itemCount: $0.value.count, totalBytes: $0.value.bytes) }
            .sorted { $0.category.displayOrder < $1.category.displayOrder }
    }

    // MARK: - The approved plan

    /// The set the confirmation panel is describing.
    ///
    /// Once pre-flight has run, the panel and the execution read this set and
    /// not the live selection: the user approves what pre-flight approved, and a
    /// selection change after that point must not make the summary and the move
    /// describe two different batches.
    public var approvedItems: [CleanupItem] {
        preflight?.ready ?? selectedItems
    }

    public var approvedCount: Int { approvedItems.count }

    public var approvedBytes: Int64 {
        approvedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    public var approvedByCategory: [CategoryTotal] {
        Self.categoryTotals(for: approvedItems)
    }

    public var approvedIncludesItemsNeedingReview: Bool {
        approvedItems.contains { $0.risk == .review }
    }

    /// The confirmation button's label, over the approved set.
    public var approvedConfirmActionTitle: String {
        let count = approvedCount
        let size = SiftFormat.bytes(approvedBytes)
        return count == 1
            ? LocalizationKey.cleanupConfirmMoveCountOne.localized(size)
            : LocalizationKey.cleanupConfirmMoveCount.localized(count, size)
    }

    // MARK: - Flow

    /// How a prepared cleanup should continue.
    public enum Preparation: Sendable, Equatable {
        /// The confirmation panel describes a plan the user must approve.
        case awaitingConfirmation
        /// Confirmation is disabled, so the caller may execute the plan now.
        case readyToExecute
        /// There was no selection, or nothing survived pre-flight.
        case nothingToDo
    }

    /// Runs the pre-flight pass and, when confirmation is enabled, opens the
    /// panel. Execution is deliberately a separate step so the entitlement gate
    /// can run immediately before the move.
    ///
    /// The preference is passed in rather than read here so the model stays free
    /// of the settings store; the caller is the view that knows the user's
    /// choice.
    public func prepareCleanup(
        requiresConfirmation: Bool = true,
        operation: CleanupOperationName = .junkCleanup
    ) async -> Preparation {
        // A result already on screen and a confirmation panel are two modal
        // layers; only one may exist. `isPreparingCleanup` is claimed before the
        // first suspension, so a rapid second request cannot pass the same
        // guard while the first pre-flight is still running, and an open panel
        // keeps the plan it is describing.
        guard outcome == nil, !isWorking, !isPreparingCleanup,
              !isConfirming, !selectedItems.isEmpty else { return .nothingToDo }
        failure = nil
        preparedOperation = operation
        isPreparingCleanup = true
        let generation = preparationGeneration
        defer { isPreparingCleanup = false }

        let candidates = selectedItems.map(FileOperationService.Candidate.init(item:))
        let verdict = await operations.preflight(candidates)
        // The list was replaced while pre-flight ran (a new scan, a reset). The
        // verdict belongs to a selection this model no longer shows.
        guard generation == preparationGeneration else { return .nothingToDo }

        // The panel describes exactly what pre-flight approved. The operation
        // passed in is the one the plan is built for; testing with a default
        // operation judged a different plan than the one that would run.
        guard verdict.ready.isEmpty == false,
              verdict.makeApprovedPlan(operation: operation) != nil else {
            // Nothing executable: report why instead of opening a panel that
            // could not do anything.
            preflight = nil
            failure = (
                .partialFailure,
                verdict.protected.isEmpty
                    ? LocalizationKey.cleanupFailureFileNotFound.localized
                    : LocalizationKey.cleanupFailureProtectedLocation.localized
            )
            return .nothingToDo
        }
        // One commit: the approved set and the panel become visible together.
        //
        // "Skip confirmation" is an explicit opt-in for the safe, preselected
        // set. It must not also skip the panel for a review item: that is
        // exactly the row the user has to look at. Safe cache directories stay
        // covered by the setting, or it would never apply to a normal junk run.
        let needsConfirmation = requiresConfirmation
            || verdict.ready.contains { $0.risk == .review }
        preflight = verdict
        isConfirming = needsConfirmation
        return needsConfirmation ? .awaitingConfirmation : .readyToExecute
    }

    /// Hides the confirmation panel without executing the plan.
    public func cancelConfirmation() {
        isConfirming = false
    }

    /// Performs the cleanup with the plan pre-flight approved.
    ///
    /// This method does not check entitlement; the caller is the composition
    /// root, which checks it immediately before calling here.
    ///
    /// Internal on purpose: a feature page must go through
    /// `AppEnvironment.confirmCleanup`, which owns the entitlement gate and the
    /// destructive slot. Self-test and unit tests reach it with `@testable`.
    @discardableResult
    func executePrepared(
        operation: CleanupOperationName? = nil,
        scanReport: ScanReport? = nil
    ) async -> CleanupOutcome? {
        guard let preflight, !isWorking else { return nil }
        let operation = operation ?? preparedOperation
        guard let plan = preflight.makeApprovedPlan(operation: operation) else {
            // The selection or the identity map changed after pre-flight. The
            // safest answer is to refuse the batch rather than execute a plan
            // this model cannot vouch for.
            isConfirming = false
            failure = (.itemChanged, LocalizationKey.cleanupFailureItemChanged.localized)
            return nil
        }
        isConfirming = false
        isWorking = true
        defer { isWorking = false }

        let outcome = await operations.execute(plan)
        self.outcome = outcome

        do {
            let report = await reports.makeReport(from: outcome, scanReport: scanReport)
            try await reports.storeLocally(report)
            self.report = report
        } catch {
            // A report failure must not hide the cleanup result.
            logger.error("The report could not be stored locally")
        }

        // Drop the items that moved: leaving them selected would let a second
        // click act on paths that no longer exist.
        removeItems(at: Set(outcome.results.filter { $0.status == .movedToTrash }.map(\.sourceURL)))
        return outcome
    }

    /// Clears everything before a new scan, so a stale selection can never
    /// survive into a different result set.
    public func resetForNewScan() {
        preparationGeneration &+= 1
        items = []
        selection = []
        preflight = nil
        isConfirming = false
        failure = nil
        outcome = nil
        report = nil
    }

    /// Clears the result so the next cleanup starts fresh.
    public func acknowledgeOutcome() {
        outcome = nil
        report = nil
        // The plan described the batch just finished. Keeping it would let the
        // confirmation panel describe that batch under a new selection.
        preflight = nil
    }
}
