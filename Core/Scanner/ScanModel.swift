import Foundation
import Shared

/// The scanner's observable state.
///
/// The view layer reads this and nothing else: every filesystem touch, every FFI
/// call and every paging request happens here or below. Events arrive as batches
/// and are folded into a bounded list, so a scan of a full disk never builds an
/// unbounded Swift object graph.
@MainActor
public final class ScanModel: ObservableObject {
    /// The current phase, driving the whole scan page.
    @Published public private(set) var phase: ScanPhase = .idle
    @Published public private(set) var progress = ScanProgress()
    /// The first screenful of results, as the scanner reported them.
    @Published public private(set) var recentItems: [CleanupItemSummary] = []
    /// Per-category totals, refreshed when the scan completes.
    @Published public private(set) var categoryTotals: [CategoryTotal] = []
    /// Locations the scan could not read.
    @Published public private(set) var skippedLocations: [SkippedLocation] = []
    @Published public private(set) var report: ScanReport?
    @Published public private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published public private(set) var failure: (code: ErrorCode, message: String)?

    /// How many of the scanner's item batches are kept for the live list.
    ///
    /// The full set stays in the engine's index and is paged on demand; this is
    /// only what the running scan shows while it works.
    private let liveItemLimit = 400

    private let engine: any ScannerEngine
    private let rules: RuleEngine
    private var session: (any ScanSession)?
    private var pollTask: Task<Void, Never>?

    /// Identifies the run the visible state belongs to.
    ///
    /// Cancelling cannot interrupt a poll that is already in flight, so the
    /// events it finally returns arrive after the next run has cleared the state
    /// and started. A pump may only write into the run it was started for, or a
    /// cancelled scan's results appear under the new scan's heading.
    private var generation = 0

    public init(engine: any ScannerEngine, rules: RuleEngine) {
        self.engine = engine
        self.rules = rules
    }

    /// The engine performing scans, shown in diagnostics.
    public var engineKind: ScannerEngineKind { engine.kind }

    public var isRunning: Bool { phase.isRunning }

    public var hasResults: Bool { phase.hasResults }

    /// True once the run has reached a phase no further event will leave.
    private var isSettled: Bool {
        switch phase {
        case .ready, .partial, .cancelled, .failed: true
        default: false
        }
    }

    /// Waits until the current run has finished, failed or been cancelled.
    ///
    /// `start` returns when the engine has a session, not when the session has
    /// results. A caller that pages immediately can read an empty index or the
    /// first few items of a scan still in progress, and then preselect a set that
    /// describes an unfinished run. This is the completion gate that makes the
    /// result pages read one settled scan.
    public func waitUntilSettled() async {
        while session != nil, !isSettled {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Total bytes the scan believes can be released.
    public var reclaimableBytes: Int64 {
        report?.estimatedReclaimableBytes ?? categoryTotals.reduce(0) { $0 + $1.totalBytes }
    }

    public var formattedReclaimable: String { SiftFormat.bytes(reclaimableBytes) }

    // MARK: - Lifecycle

    /// Starts a scan, replacing any scan already running.
    public func start(_ request: ScanRequest) async {
        await cancel()
        reset()

        generation &+= 1
        let run = generation
        do {
            let session = try await engine.startScan(request)
            self.session = session
            beginPolling(session, run: run)
        } catch let error as ScannerError {
            failure = (error.code, error.message)
            phase = .failed
        } catch {
            failure = (.internalError, LocalizationKey.commonUnknownError.localized)
            phase = .failed
        }
    }

    /// Requests cancellation. The engine stops within its next checkpoint.
    ///
    /// The run is retired before anything is awaited, so whatever the pump is
    /// holding comes back to a model that no longer wants it, and the phase is
    /// settled here: the engine's own final event is dropped with the retired
    /// run, and a scan left in `scanning` would offer a cancel button forever.
    public func cancel() async {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        guard let session else {
            if phase.isRunning { phase = .cancelled }
            return
        }
        await session.cancel()
        self.session = nil
        phase = .cancelled
    }

    /// Clears the previous run so a new scan starts from a clean slate.
    public func reset() {
        phase = .idle
        progress = ScanProgress()
        recentItems = []
        categoryTotals = []
        skippedLocations = []
        duplicateGroups = []
        report = nil
        failure = nil
    }

    // MARK: - Paging

    /// Reads one page of results from the engine's index.
    public func page(
        offset: Int,
        limit: Int,
        sort: ScanSort = .size,
        category: CleanupCategory? = nil
    ) async -> ScanPage {
        guard let session else {
            return ScanPage(items: [], remaining: 0)
        }
        return (try? await session.page(offset: offset, limit: limit, sort: sort, category: category))
            ?? ScanPage(items: [], remaining: 0)
    }

    /// How many duplicate groups one page holds.
    ///
    /// A scan of a full disk can find thousands, and each group carries its
    /// members, so the list is paged rather than loaded whole.
    public static let duplicateGroupsPageSize = 200

    /// How many groups the scan found in total.
    ///
    /// The report's count, not the loaded list's: the difference between the two
    /// is what the page has to show, and a list that quietly stopped at one page
    /// would read as the whole result.
    public var duplicateGroupsTotal: Int {
        report?.duplicateGroupCount ?? duplicateGroups.count
    }

    /// True when the engine holds more groups than the list is showing.
    public var hasMoreDuplicateGroups: Bool {
        duplicateGroups.count < duplicateGroupsTotal
    }

    /// Loads the first page of duplicate groups, once a scan has finished.
    public func loadDuplicateGroups(limit: Int = ScanModel.duplicateGroupsPageSize) async {
        guard let session else { return }
        duplicateGroups = (try? await session.duplicateGroups(offset: 0, limit: limit)) ?? []
    }

    /// Appends the next page of duplicate groups.
    ///
    /// Appends rather than replaces: the ids are the index's, so a group already
    /// on screen keeps its expansion and its selection.
    public func loadMoreDuplicateGroups(limit: Int = ScanModel.duplicateGroupsPageSize) async {
        guard let session, hasMoreDuplicateGroups else { return }
        let next = (try? await session.duplicateGroups(
            offset: duplicateGroups.count,
            limit: limit
        )) ?? []
        // A page that repeats what is already loaded would leave the button
        // offering a load that never advances.
        let known = Set(duplicateGroups.map(\.id))
        duplicateGroups.append(contentsOf: next.filter { !known.contains($0.id) })
    }

    /// Loads the members of one duplicate group.
    public func duplicateMembers(for group: DuplicateGroup) async -> [DuplicateMember] {
        guard let session else { return group.members }
        return (try? await session.duplicateMembers(groupID: group.id)) ?? group.members
    }

    // MARK: - Event pump

    /// Drains the event stream until the scan reports completion.
    ///
    /// Polling rather than callbacks: the engine is free to publish from any
    /// thread, and a single pump keeps event ordering trivial to reason about.
    ///
    /// Every write is guarded by `run`, and the pump clears its own handle only
    /// while it is still the current one: a task that finished after being
    /// replaced must not take the new run's handle with it, or cancelling would
    /// find nothing to cancel.
    private func beginPolling(_ session: any ScanSession, run: Int) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let events = await session.pollEvents(maxEvents: 64)
                guard self.isCurrent(run) else { return }
                self.apply(events)
                if await session.isFinished() {
                    guard self.isCurrent(run) else { return }
                    self.apply(await session.pollEvents(maxEvents: 256))
                    break
                }
                // A short sleep keeps the pump from spinning while the scanner
                // works on a large directory.
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self?.retirePump(run)
        }
    }

    /// True while `run` is still the scan the model is showing.
    private func isCurrent(_ run: Int) -> Bool { run == generation }

    /// Clears the pump handle when it still belongs to `run`.
    private func retirePump(_ run: Int) {
        guard isCurrent(run) else { return }
        pollTask = nil
    }

    private func apply(_ events: [ScanEvent]) {
        for event in events {
            switch event {
            case let .phaseChanged(phase):
                self.phase = phase

            case let .progress(progress):
                self.progress = progress
                self.phase = progress.phase

            case let .itemsFound(items):
                recentItems.append(contentsOf: items)
                if recentItems.count > liveItemLimit {
                    recentItems.removeFirst(recentItems.count - liveItemLimit)
                }

            case let .duplicateGroupFound(_, memberCount, reclaimableBytes):
                // The group list is loaded in full once the scan finishes; this
                // keeps a running count without holding every member.
                progress.itemsFound += memberCount
                progress.bytesSeen += reclaimableBytes

            case let .locationSkipped(location):
                if !skippedLocations.contains(where: { $0.id == location.id }) {
                    skippedLocations.append(location)
                }

            case let .completed(report):
                self.report = report
                self.phase = report.phase
                self.categoryTotals = report.categoryTotals
                if !report.skippedLocations.isEmpty {
                    self.skippedLocations = report.skippedLocations
                }
                self.progress.filesSeen = report.scannedFileCount
                self.progress.bytesSeen = report.scannedByteCount

            case let .failed(code, message):
                self.failure = (code, message)
                self.phase = .failed
            }
        }
    }
}
