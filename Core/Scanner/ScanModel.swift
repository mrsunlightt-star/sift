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

    public init(engine: any ScannerEngine, rules: RuleEngine) {
        self.engine = engine
        self.rules = rules
    }

    /// The engine performing scans, shown in diagnostics.
    public var engineKind: ScannerEngineKind { engine.kind }

    public var isRunning: Bool { phase.isRunning }

    public var hasResults: Bool { phase.hasResults }

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

        do {
            let session = try await engine.startScan(request)
            self.session = session
            beginPolling(session)
        } catch let error as ScannerError {
            failure = (error.code, error.message)
            phase = .failed
        } catch {
            failure = (.internalError, LocalizationKey.commonUnknownError.localized)
            phase = .failed
        }
    }

    /// Requests cancellation. The engine stops within its next checkpoint.
    public func cancel() async {
        pollTask?.cancel()
        pollTask = nil
        guard let session else { return }
        await session.cancel()
        self.session = nil
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

    /// Loads the duplicate groups once a scan has finished.
    public func loadDuplicateGroups(limit: Int = 200) async {
        guard let session else { return }
        duplicateGroups = (try? await session.duplicateGroups(offset: 0, limit: limit)) ?? []
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
    private func beginPolling(_ session: any ScanSession) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let events = await session.pollEvents(maxEvents: 64)
                self.apply(events)
                if await session.isFinished() {
                    self.apply(await session.pollEvents(maxEvents: 256))
                    break
                }
                // A short sleep keeps the pump from spinning while the scanner
                // works on a large directory.
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self?.pollTask = nil
        }
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
