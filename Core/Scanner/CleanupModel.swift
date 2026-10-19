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
    @Published public var isConfirming = false
    /// True while a batch is running.
    @Published public private(set) var isWorking = false
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
        let known = Set(items.map(\.id))
        let added = newItems.filter { !known.contains($0.id) }
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

    /// True when the selection includes anything the user should double-check.
    public var includesItemsNeedingReview: Bool {
        selectedItems.contains { $0.risk == .review }
    }

    /// Selection broken down by category for the confirmation panel.
    public var selectedByCategory: [CategoryTotal] {
        var totals: [CleanupCategory: (count: Int, bytes: Int64)] = [:]
        for item in selectedItems {
            var entry = totals[item.category] ?? (0, 0)
            entry.count += 1
            entry.bytes += item.sizeInBytes
            totals[item.category] = entry
        }
        return totals
            .map { CategoryTotal(category: $0.key, itemCount: $0.value.count, totalBytes: $0.value.bytes) }
            .sorted { $0.category.displayOrder < $1.category.displayOrder }
    }

    // MARK: - Flow

    /// Runs the pre-flight pass, then either opens the confirmation panel or —
    /// when the user has turned confirmation off — executes immediately.
    ///
    /// The preference is passed in rather than read here so the model stays free
    /// of the settings store; the caller is the view that knows the user's
    /// choice.
    public func prepareCleanup(
        requiresConfirmation: Bool = true,
        operation: CleanupOperationName = .junkCleanup
    ) async {
        failure = nil
        guard !selectedItems.isEmpty else { return }
        let candidates = selectedItems.map(FileOperationService.Candidate.init(item:))
        let verdict = await operations.preflight(candidates)
        preflight = verdict

        if verdict.ready.isEmpty {
            // Nothing executable: report why instead of opening a panel that
            // could not do anything.
            failure = (
                .partialFailure,
                verdict.protected.isEmpty
                    ? LocalizationKey.cleanupFailureFileNotFound.localized
                    : LocalizationKey.cleanupFailureProtectedLocation.localized
            )
            return
        }
        if requiresConfirmation {
            isConfirming = true
        } else {
            // The user opted out. Everything still goes to the Trash, and the
            // result page still appears, but the list is not shown first.
            await confirmCleanup(operation: operation)
        }
    }

    /// Performs the cleanup with the pre-flighted items.
    ///
    /// `keepWindowOpen` is a UI preference only; it never changes what is moved.
    public func confirmCleanup(
        operation: CleanupOperationName = .junkCleanup,
        scanReport: ScanReport? = nil
    ) async {
        guard let preflight else { return }
        isConfirming = false
        isWorking = true
        defer { isWorking = false }

        let outcome = await operations.moveToTrash(
            preflight.ready,
            categoryTotals: selectedByCategory,
            operation: operation,
            refusedByPreflight: preflight.refusedResults
        )
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
    }

    /// Clears everything before a new scan, so a stale selection can never
    /// survive into a different result set.
    public func resetForNewScan() {
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
    }
}
