import Foundation
import OSLog
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
    /// When this run began, for the elapsed clock on the running page. Cleared
    /// with the rest of the run's state.
    @Published public private(set) var runStartedAt: Date?

    /// How much of the result is safe to select, how much needs a look, and how
    /// much can never be selected.
    ///
    /// A category is not a risk level: logs hold both safe files and diagnostic
    /// reports, so a per-category guess would describe the overview's two numbers
    /// wrongly. These totals are accumulated from the item events themselves and
    /// therefore describe the whole run, not just the page the list is showing.
    @Published public private(set) var safeBytes: Int64 = 0
    @Published public private(set) var reviewBytes: Int64 = 0
    @Published public private(set) var protectedBytes: Int64 = 0
    @Published public private(set) var safeItemCount = 0
    @Published public private(set) var reviewItemCount = 0
    @Published public private(set) var protectedItemCount = 0
    /// Reclaimable bytes the duplicate pipeline reported. Duplicates arrive as
    /// groups rather than items, so they are counted separately.
    @Published public private(set) var duplicateReclaimableBytes: Int64 = 0
    /// True once the risk split has been read from the finished index. The
    /// overview only states the split when it is complete.
    @Published public private(set) var riskTotalsComplete = false
    /// Why a page read failed, when one did. A failed index read is not an empty
    /// result: the page keeps the previous rows and says the read failed.
    ///
    /// Cleared by `reset()` for a new run, not by a later successful page. A
    /// result page reads several category pages in sequence, and letting the
    /// next page erase the failure hid the one category that could not be read.
    @Published public private(set) var resultLoadFailure: String?

    /// Seconds since this run started, or the finished run's duration.
    public var elapsed: TimeInterval {
        guard let runStartedAt else { return 0 }
        let end = report?.finishedAt ?? Date()
        return max(end.timeIntervalSince(runStartedAt), 0)
    }

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
    /// True once the engine published a verdict — completed, failed, or a
    /// cancellation. A phase event alone is not a verdict: `.ready` can arrive
    /// in one poll batch and its report in the next.
    private var terminalReceived = false

    public init(engine: any ScannerEngine, rules: RuleEngine) {
        self.engine = engine
        self.rules = rules
    }

    /// The engine performing scans, shown in diagnostics.
    public var engineKind: ScannerEngineKind { engine.kind }

    public var isRunning: Bool { phase.isRunning }

    /// True only once the run published its report, not merely its phase.
    ///
    /// `.ready` can arrive in one poll batch and the report in the next. The
    /// page used to show its result branch on the phase alone, so that window
    /// displayed an empty list under a finished heading — and offered a rescan
    /// while the first run was still loading its first page.
    public var hasResults: Bool { phase.hasResults && report != nil }

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
        while session != nil, !terminalReceived {
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
        terminalReceived = false
        runStartedAt = Date()
        do {
            let session = try await engine.startScan(request)
            self.session = session
            // The session exists; say so before the first event arrives, or the
            // page falls back to its idle state between Start and the engine's
            // first progress update.
            phase = .preparing
            beginPolling(session, run: run)
        } catch let error as ScannerError {
            // The engine's sentence is diagnostic text; the banner shows the
            // sentence the code owns, so both engines' failures read the same
            // in every language and the detail stays here.
            SiftLog.scan.error(
                "Scan start failed (code=\(error.code.rawValue, privacy: .public) detail=\(error.message, privacy: .public))"
            )
            failure = (error.code, error.code.localizedTitle.localized)
            phase = .failed
            terminalReceived = true
        } catch {
            failure = (.internalError, LocalizationKey.commonUnknownError.localized)
            phase = .failed
            terminalReceived = true
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
        terminalReceived = true
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
        runStartedAt = nil
        safeBytes = 0
        reviewBytes = 0
        protectedBytes = 0
        safeItemCount = 0
        reviewItemCount = 0
        protectedItemCount = 0
        duplicateReclaimableBytes = 0
        riskTotalsComplete = false
        resultLoadFailure = nil
        terminalReceived = false
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
        do {
            return try await session.page(
                offset: offset,
                limit: limit,
                sort: sort,
                category: category
            )
        } catch {
            // An index that cannot be read is not an empty result. Keep the
            // failure so the page can say what happened instead of rendering
            // "nothing found".
            recordLoadFailure(error)
            return ScanPage(items: [], remaining: 0)
        }
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
        do {
            duplicateGroups = try await session.duplicateGroups(offset: 0, limit: limit)
        } catch {
            recordLoadFailure(error)
        }
    }

    /// Appends the next page of duplicate groups.
    ///
    /// Appends rather than replaces: the ids are the index's, so a group already
    /// on screen keeps its expansion and its selection.
    public func loadMoreDuplicateGroups(limit: Int = ScanModel.duplicateGroupsPageSize) async {
        guard let session, hasMoreDuplicateGroups else { return }
        do {
            let next = try await session.duplicateGroups(
                offset: duplicateGroups.count,
                limit: limit
            )
            // A page that repeats what is already loaded would leave the button
            // offering a load that never advances.
            let known = Set(duplicateGroups.map(\.id))
            duplicateGroups.append(contentsOf: next.filter { !known.contains($0.id) })
        } catch {
            recordLoadFailure(error)
        }
    }

    /// Loads the members of one duplicate group.
    public func duplicateMembers(for group: DuplicateGroup) async -> [DuplicateMember] {
        guard let session else { return group.members }
        do {
            return try await session.duplicateMembers(groupID: group.id)
        } catch {
            recordLoadFailure(error)
            return group.members
        }
    }

    /// Records a failed read for the page, and the specific reason for the log.
    ///
    /// The engines' sentences are diagnostic text the core writes in its own
    /// language. The banner shows the sentence the error code owns, so the
    /// failed read reads the same in all eight languages and the technical
    /// detail stays in the log.
    private func recordLoadFailure(_ error: Error) {
        let scannerError = error as? ScannerError
        let code = scannerError?.code ?? .internalError
        // A non-ScannerError path still owes its description to the log: the
        // banner shows the error code's sentence, so this is the only place
        // the underlying read failure is recorded.
        let detail = scannerError?.message ?? String(describing: error)
        SiftLog.scan.error(
            "A result read failed (code=\(code.rawValue, privacy: .public) detail=\(detail, privacy: .public))"
        )
        resultLoadFailure = code.localizedTitle.localized
    }

    /// Reads the risk split from the finished index.
    ///
    /// The live item stream can report one path twice — two rules match it and
    /// the engine keeps the more cautious row in the index — so accumulating the
    /// stream overstated the safe share. The index is the settled answer, and
    /// its rows are deduplicated by path exactly as the engine decided.
    public func loadRiskTotals(limit: Int = 1_000) async {
        guard let session, report != nil else { return }
        // A newer run may replace this one while the index is being read; its
        // report and totals must not be overwritten by the run that finished
        // first.
        let run = generation
        guard isCurrent(run) else { return }
        riskTotalsComplete = false

        var accumulator = RiskAccumulator()
        var offset = 0
        var complete = false

        while !Task.isCancelled {
            let page: ScanPage
            do {
                page = try await session.page(
                    offset: offset,
                    limit: limit,
                    sort: .size,
                    category: nil
                )
            } catch {
                recordLoadFailure(error)
                return
            }
            if page.items.isEmpty {
                complete = page.remaining == 0
                break
            }
            for item in page.items {
                accumulator.add(item)
            }
            offset += page.items.count
            if page.remaining == 0 {
                complete = true
                break
            }
        }

        guard !Task.isCancelled, isCurrent(run) else { return }
        safeBytes = accumulator.safeBytes
        reviewBytes = accumulator.reviewBytes
        protectedBytes = accumulator.protectedBytes
        safeItemCount = accumulator.safeCount
        reviewItemCount = accumulator.reviewCount
        protectedItemCount = accumulator.protectedCount
        riskTotalsComplete = complete
    }

    /// One entry per path at the most cautious risk the index kept.
    private struct RiskAccumulator {
        var safeBytes: Int64 = 0
        var reviewBytes: Int64 = 0
        var protectedBytes: Int64 = 0
        var safeCount = 0
        var reviewCount = 0
        var protectedCount = 0
        private var byPath: [String: (risk: CleanupRisk, bytes: Int64)] = [:]

        mutating func add(_ item: CleanupItemSummary) {
            let path = item.url.standardizedFileURL.path
            if let existing = byPath[path] {
                guard item.risk.severity > existing.risk.severity else { return }
                subtract(existing.risk, existing.bytes)
            }
            byPath[path] = (item.risk, item.sizeInBytes)
            accumulate(item.risk, item.sizeInBytes, count: 1)
        }

        private mutating func subtract(_ risk: CleanupRisk, _ bytes: Int64) {
            accumulate(risk, bytes, count: -1)
        }

        private mutating func accumulate(_ risk: CleanupRisk, _ bytes: Int64, count: Int) {
            switch risk {
            case .safe:
                safeBytes += bytes
                safeCount += count
            case .review:
                reviewBytes += bytes
                reviewCount += count
            case .protected:
                protectedBytes += bytes
                protectedCount += count
            }
        }
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
                    // The worker can finish while more than one page of item
                    // batches is queued. Drain until empty so the terminal phase
                    // and completion report cannot remain behind an arbitrary
                    // 256-event tail, leaving waitUntilSettled() blocked forever.
                    while true {
                        let pending = await session.pollEvents(maxEvents: 256)
                        guard self.isCurrent(run) else { return }
                        guard !pending.isEmpty else { break }
                        self.apply(pending)
                    }
                    // A session that finished without ever publishing a terminal
                    // event has no verdict to give. Saying so is what keeps
                    // `waitUntilSettled` from waiting forever on a run that can
                    // never settle; a decoded summary that failed is the case
                    // this exists for.
                    if !self.terminalReceived {
                        self.failure = (.internalError, LocalizationKey.commonUnknownError.localized)
                        self.phase = .failed
                        self.terminalReceived = true
                    }
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
                // A failure is a verdict. A later completion event from the same
                // worker must not turn a partial write back into a success.
                guard self.failure == nil else { break }
                self.report = report
                self.phase = report.phase
                self.terminalReceived = true
                self.categoryTotals = report.categoryTotals
                if !report.skippedLocations.isEmpty {
                    self.skippedLocations = report.skippedLocations
                }
                self.progress.filesSeen = report.scannedFileCount
                self.progress.bytesSeen = report.scannedByteCount
                self.duplicateReclaimableBytes = report.duplicateReclaimableBytes

            case let .failed(code, message):
                // The engine's own sentence is diagnostic text, written in the
                // core's language; the page shows the sentence the code owns,
                // and the detail is kept in the log.
                SiftLog.scan.error(
                    "Scan failed (code=\(code.rawValue, privacy: .public) detail=\(message, privacy: .public))"
                )
                self.failure = (code, code.localizedTitle.localized)
                self.phase = .failed
                self.terminalReceived = true
            }
        }
    }
}
