import Foundation
import XCTest
@testable import Core
import Shared

/// The scan model's run lifecycle.
///
/// `ScanModel` owns the only copy of what the scan page shows. Cancelling cannot
/// interrupt a poll that is already in flight, so these are the checks that a
/// cancelled run's events cannot land in the run that replaced it (§5.1).
final class ScanModelTests: XCTestCase, @unchecked Sendable {
    private func makeModel(home: URL) async -> ScanModel {
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
        return await ScanModel(engine: SwiftScannerEngine(rules: rules), rules: rules)
    }

    private func makeRequest(home: URL) -> ScanRequest {
        ScanRequest(
            homeDirectory: home,
            roots: [ScanRoot(url: home, anchor: .home)],
            includeDuplicates: false
        )
    }

    /// Waits until the model reports a phase a scan has finished in.
    ///
    /// A fresh run passes through `idle` before its first event arrives, so
    /// "not running" is not the same as "settled".
    private func waitForFinalPhase(
        _ model: ScanModel,
        timeout: TimeInterval = 30
    ) async -> ScanPhase {
        let deadline = Date().addingTimeInterval(timeout)
        var phase = await model.phase
        while Date() < deadline {
            phase = await model.phase
            switch phase {
            case .ready, .partial, .cancelled, .failed: return phase
            default: break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return phase
    }

    func test_finishedSessionDrainsPastOneTailPageToReachItsFinalPhase() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-event-tail")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = BurstScannerEngine(queuedPhaseEvents: 400)
        let model = await ScanModel(engine: engine, rules: rules)

        await model.start(makeRequest(home: fixture.url))
        let phase = await waitForFinalPhase(model, timeout: 2)

        XCTAssertEqual(
            phase,
            .ready,
            "the final event must be applied even when more than 320 events are queued"
        )
    }

    /// `.ready` is a phase, not a verdict. A session that publishes it and then
    /// finishes without a report leaves the page with no result, so the model
    /// reports a failure instead of waiting forever.
    func test_aReadyPhaseWithoutACompletedEventFails() async {
        let fixture = TemporaryDirectory(tag: "scan-model-ready-only")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let model = await ScanModel(
            engine: BurstScannerEngine(queuedPhaseEvents: 4, includesCompletion: false),
            rules: rules
        )
        await model.start(makeRequest(home: fixture.url))
        await model.waitUntilSettled()
        let phase = await model.phase
        XCTAssertEqual(phase, .failed)
    }

    func test_cancellingAScanSettlesThePhase() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-cancel")
        for index in 0..<20 {
            fixture.write("Library/Caches/com.app\(index)/blob.bin", bytes: 4096 * (index + 1))
        }
        let model = await makeModel(home: fixture.url)
        await model.start(makeRequest(home: fixture.url))

        await model.cancel()
        let phase = await model.phase
        XCTAssertEqual(phase, .cancelled, "a cancelled run must not stay in a running phase")
        let running = await model.isRunning
        XCTAssertFalse(running)

        // The pump may still have been waiting on the engine when it was
        // retired. Nothing it returns afterwards may move the phase on.
        try await Task.sleep(nanoseconds: 400_000_000)
        let settled = await model.phase
        XCTAssertEqual(
            settled,
            .cancelled,
            "the retired run must not publish a completion after the cancel"
        )
    }

    /// A stop keeps what the run had found, and the rows stay pageable.
    ///
    /// The core's worker no longer unlinks its index when it is cancelled, so a
    /// stopped run has the rows a finished one does. This is the invariant the
    /// page's "still cleanable" claim rests on: if the session were torn down, the
    /// list would be empty and the banner would describe nothing.
    ///
    /// Scripted rather than timed: a fixture small enough to be quick is also
    /// small enough to finish before a stop can land, and a test that silently
    /// exercises the finished path proves nothing about the stopped one.
    func test_aStoppedRunKeepsItsSessionAndItsRows() async {
        let fixture = TemporaryDirectory(tag: "scan-model-stopped-rows")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let session = HeldRowsScanSession()
        let model = await ScanModel(engine: HeldRowsScannerEngine(session: session), rules: rules)
        await model.start(makeRequest(home: fixture.url))

        // One item lands, so the run has something to keep.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, await model.progress.itemsFound == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        await model.cancel()

        let phase = await model.phase
        XCTAssertEqual(phase, .cancelled)
        let stopped = await model.hasStoppedResults
        XCTAssertTrue(stopped, "a stopped run with rows says so")
        let held = await model.isHoldingStoppedSession
        XCTAssertTrue(held, "the session is held, so the rows can still be paged")
        let shutDowns = await session.shutDownCount
        XCTAssertEqual(shutDowns, 0, "the index is not released while the page can read it")

        // Releasing is what bounds the index's life. A second cancel with nothing
        // running is that release path.
        await model.cancel()
        let releasedShutDowns = await session.shutDownCount
        let stillHeld = await model.isHoldingStoppedSession
        XCTAssertEqual(releasedShutDowns, 1, "the kept session is released exactly once")
        XCTAssertFalse(stillHeld)
    }

    /// `start` returns before the scan has results; the completion gate is what
    /// makes a page read one settled run.
    ///
    /// The first page used to be requested immediately after `start`, when the
    /// engine had not written anything yet, so a fresh scan could initialise the
    /// cleanup list — and its pre-selection — from an empty index.
    func test_waitUntilSettledMakesTheResultsReadable() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-settled")
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        let model = await makeModel(home: fixture.url)
        await model.start(makeRequest(home: fixture.url))

        await model.waitUntilSettled()

        let phase = await model.phase
        XCTAssertEqual(phase, .ready)
        let hasResults = await model.hasResults
        XCTAssertTrue(hasResults, "a settled run with a report has results")
        let page = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        XCTAssertFalse(
            page.items.isEmpty,
            "the settled index must already hold the items the scan found"
        )
    }


    /// A row a cleanup moved is not a row any more.
    ///
    /// The page used to show it again as soon as the result sheet closed: the
    /// rows come from the core's index, and a move does not rewrite it. The
    /// model now drops what moved, from the list and from the totals both, and
    /// keeps everything the batch did not touch.
    func test_aCleanedItemLeavesThePageAndTheTotals() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-cleanup-sync")
        fixture.write("Library/Caches/com.example.a/blob.bin", bytes: 8192)
        fixture.write("Library/Caches/com.example.b/blob.bin", bytes: 4096)
        let model = await makeModel(home: fixture.url)
        await model.start(makeRequest(home: fixture.url))
        await model.waitUntilSettled()

        let before = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        XCTAssertEqual(before.items.count, 2, "two cache items before the cleanup")
        let reportBefore = await model.report
        let victim = before.items[0]

        await model.applyCleanup([
            FileOperationResult(
                sourceURL: victim.url,
                status: .movedToTrash,
                sizeInBytes: victim.sizeInBytes,
                category: victim.category
            )
        ])

        let after = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        XCTAssertEqual(after.items.count, 1, "the moved item is gone from the list")
        XCTAssertFalse(
            after.items.contains { $0.url.standardizedFileURL.path == victim.url.standardizedFileURL.path },
            "the row that moved must not come back"
        )

        let reportAfter = await model.report
        XCTAssertEqual(reportAfter?.itemCount, (reportBefore?.itemCount ?? 0) - 1)
        XCTAssertEqual(reportAfter?.itemBytes, (reportBefore?.itemBytes ?? 0) - victim.sizeInBytes)
        let totals = await model.categoryTotals
        let cache = totals.first { $0.category == victim.category }
        XCTAssertEqual(cache?.itemCount, 1, "the category total counts only what is still there")
    }

    /// A batch that moved nothing changes nothing.
    func test_aCleanupThatMovedNothingLeavesTheResultAlone() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-cleanup-noop")
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        let model = await makeModel(home: fixture.url)
        await model.start(makeRequest(home: fixture.url))
        await model.waitUntilSettled()

        let before = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        let reportBefore = await model.report
        await model.applyCleanup([
            FileOperationResult(
                sourceURL: before.items[0].url,
                status: .skipped,
                message: "in use"
            )
        ])
        let after = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        XCTAssertEqual(after.items.count, before.items.count)
        let reportAfter = await model.report
        XCTAssertEqual(reportAfter?.itemCount, reportBefore?.itemCount)
    }

    /// A scan that finds more duplicate groups than one page can show.
    ///
    /// The list is paged, so the model has to know the total the scan reported
    /// and be able to reach the rest: a list that stopped at the first page and
    /// looked complete would hide reclaimable space the scan had already found.
    func test_duplicateGroupsArePagedRatherThanCapped() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-duplicates")
        // Three groups of two identical files each, all above the duplicate
        // minimum size so the pipeline looks at them.
        for index in 0..<3 {
            let payload = Data(repeating: UInt8(0x40 + index), count: 64 * 1024)
            fixture.writeBytes("Downloads/pair-\(index)-a.bin", payload)
            fixture.writeBytes("Downloads/pair-\(index)-b.bin", payload)
        }

        let model = await makeModel(home: fixture.url)
        var request = makeRequest(home: fixture.url)
        request.includeDuplicates = true
        request.duplicateRoots = [fixture.url.appendingPathComponent("Downloads").path]
        await model.start(request)

        let phase = await waitForFinalPhase(model)
        XCTAssertEqual(phase, .ready)

        // A page smaller than the result, so the paging path is what runs.
        await model.loadDuplicateGroups(limit: 2)
        let firstPage = await model.duplicateGroups
        XCTAssertEqual(firstPage.count, 2)
        let total = await model.duplicateGroupsTotal
        XCTAssertEqual(total, 3, "the report knows about all three")
        let hasMore = await model.hasMoreDuplicateGroups
        XCTAssertTrue(hasMore)

        await model.loadMoreDuplicateGroups(limit: 2)
        let all = await model.duplicateGroups
        XCTAssertEqual(all.count, 3, "the rest is reachable")
        XCTAssertEqual(Set(all.map(\.id)).count, 3, "and nothing is repeated")
        let stillMore = await model.hasMoreDuplicateGroups
        XCTAssertFalse(stillMore)
    }

    /// `.ready` without a report is not a result the page may act on.
    ///
    /// The two arrive in separate poll batches. Treating the phase alone as
    /// "has results" showed the result branch under a finished heading while the
    /// first page was still unread — and offered a rescan the environment
    /// refuses because the run is still loading.
    func test_aPhaseWithoutAReportIsNotAResult() async {
        let fixture = TemporaryDirectory(tag: "scan-model-phase-only")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let model = await ScanModel(engine: PhaseOnlyScannerEngine(), rules: rules)
        await model.start(makeRequest(home: fixture.url))

        let deadline = Date().addingTimeInterval(2)
        var phase = await model.phase
        while Date() < deadline, phase != .ready {
            try? await Task.sleep(nanoseconds: 20_000_000)
            phase = await model.phase
        }
        XCTAssertEqual(phase, .ready)

        let report = await model.report
        XCTAssertNil(report)
        let hasResults = await model.hasResults
        XCTAssertFalse(hasResults, "a phase event is not a verdict")
        await model.cancel()
    }

    func test_aScanStartedAfterACancelShowsOnlyItsOwnResults() async throws {
        let first = TemporaryDirectory(tag: "scan-model-first")
        for index in 0..<20 {
            first.write("Library/Caches/com.first\(index)/blob.bin", bytes: 8192)
        }
        let second = TemporaryDirectory(tag: "scan-model-second")
        second.write("Library/Caches/com.second/blob.bin", bytes: 4096)

        let model = await makeModel(home: second.url)
        await model.start(makeRequest(home: first.url))
        await model.cancel()
        await model.start(makeRequest(home: second.url))

        let phase = await waitForFinalPhase(model)
        XCTAssertEqual(phase, .ready)

        let items = await model.recentItems
        XCTAssertFalse(items.isEmpty, "the new run must report what it found")
        // Compared through the product's own normalisation: a fixture path can
        // come back with or without the `/private` prefix `/var` resolves to.
        let root = RuleEngine.normalize(second.url.path)
        let stray = items
            .map { RuleEngine.normalize($0.url.path) }
            .filter { !$0.hasPrefix(root) }
        XCTAssertTrue(
            stray.isEmpty,
            "the cancelled run's results must not appear under the new scan: \(stray)"
        )
    }

    /// A session that stops without a terminal event has no verdict to give.
    ///
    /// `waitUntilSettled` is the gate a page reads through, and it waits for a
    /// terminal phase. An engine that finished but never published one used to
    /// leave that gate waiting forever; the model must say the run failed.
    /// One unreadable category page must not be erased by the next page.
    ///
    /// The result list reads its categories in sequence. Clearing the failure on
    /// every successful read hid the category that could not be read, and the
    /// list then looked complete.
    func test_aFailedPageStaysVisibleAfterASuccessfulPage() async {
        let fixture = TemporaryDirectory(tag: "scan-model-page-failure")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let model = await ScanModel(engine: PageFailingScannerEngine(), rules: rules)
        await model.start(makeRequest(home: fixture.url))
        await model.waitUntilSettled()

        _ = await model.page(offset: 0, limit: 10, sort: .size, category: .applicationCache)
        let afterFailure = await model.resultLoadFailure
        XCTAssertNotNil(afterFailure)

        _ = await model.page(offset: 0, limit: 10, sort: .size, category: .logs)
        let afterSuccess = await model.resultLoadFailure
        XCTAssertEqual(afterSuccess, afterFailure, "a later page does not hide the failed one")
    }

    func test_aSessionThatEndsWithoutATerminalEventFails() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-silent")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let model = await ScanModel(engine: SilentScannerEngine(), rules: rules)

        await model.start(makeRequest(home: fixture.url))
        let phase = await waitForFinalPhase(model, timeout: 2)

        XCTAssertEqual(phase, .failed, "a run with no verdict must not read as still running")
        await model.waitUntilSettled()
        let failure = await model.failure
        XCTAssertEqual(failure?.code, .internalError)
    }

    /// The running per-category totals fold every item event, not the bounded
    /// recent window: a strategy whose items were pushed out of the window by a
    /// later one must keep its running total, or the running page reads a
    /// finished strategy as if it had found nothing.
    func test_runningCategoryTotalsSurviveTheRecentWindow() async throws {
        let fixture = TemporaryDirectory(tag: "scan-model-live-totals")
        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let model = await ScanModel(engine: ItemBurstScannerEngine(), rules: rules)

        await model.start(makeRequest(home: fixture.url))
        await model.waitUntilSettled()

        let cacheBytes = await model.liveBytes(for: .applicationCache)
        let largeBytes = await model.liveBytes(for: .largeFiles)
        let foundBytes = await model.liveFoundBytes
        let recentCount = await model.recentItems.count

        XCTAssertEqual(cacheBytes, 380_000, "all cache items count, not just the ones still in the window")
        XCTAssertEqual(largeBytes, 80_000)
        XCTAssertEqual(foundBytes, 460_000)
        XCTAssertEqual(recentCount, 400, "the recent window stays bounded")
    }
}


/// A deterministic session whose terminal phase sits beyond the scan model's
/// ordinary poll batch and one 256-event tail batch.
private struct BurstScannerEngine: ScannerEngine {
    let queuedPhaseEvents: Int
    var includesCompletion = true
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        BurstScanSession(
            queuedPhaseEvents: queuedPhaseEvents,
            includesCompletion: includesCompletion
        )
    }

}

private actor BurstScanSession: ScanSession {
    nonisolated let id = "burst-session"
    private var events: [ScanEvent]

    init(queuedPhaseEvents: Int, includesCompletion: Bool = true) {
        events = Array(repeating: .phaseChanged(.preparing), count: queuedPhaseEvents)
        events.append(.phaseChanged(.ready))
        guard includesCompletion else { return }
        // A phase event is not a verdict: the real engines publish the report
        // after it, and `waitUntilSettled` waits for this event specifically.
        events.append(
            .completed(
                ScanReport(
                    sessionID: "burst-session",
                    startedAt: Date(),
                    finishedAt: Date(),
                    phase: .ready,
                    scannedFileCount: 0,
                    scannedByteCount: 0,
                    scannedLocationCount: 1,
                    itemCount: 0,
                    itemBytes: 0,
                    categoryTotals: [],
                    duplicateGroupCount: 0,
                    duplicateReclaimableBytes: 0,
                    skippedLocations: []
                )
            )
        )
    }

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        let count = min(max(maxEvents, 1), events.count)
        let result = Array(events.prefix(count))
        events.removeFirst(count)
        return result
    }

    func isFinished() async -> Bool { true }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    func cancel() async {}
}

/// An engine whose index answers every category but one.
private struct PageFailingScannerEngine: ScannerEngine {
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        PageFailingScanSession()
    }
}

private actor PageFailingScanSession: ScanSession {
    nonisolated let id = "page-failing-session"
    private var sentCompletion = false

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        guard !sentCompletion else { return [] }
        sentCompletion = true
        return [
            .completed(
                ScanReport(
                    sessionID: id,
                    startedAt: Date(),
                    finishedAt: Date(),
                    phase: .ready,
                    scannedFileCount: 0,
                    scannedByteCount: 0,
                    scannedLocationCount: 1,
                    itemCount: 0,
                    itemBytes: 0,
                    categoryTotals: [],
                    duplicateGroupCount: 0,
                    duplicateReclaimableBytes: 0,
                    skippedLocations: []
                )
            ),
        ]
    }

    func isFinished() async -> Bool { true }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        if category == .applicationCache {
            throw ScannerError(code: .internalError, message: "the index could not be read")
        }
        return ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    func cancel() async {}
}

/// An engine that publishes `.ready` and then keeps running.
/// An engine whose session never finishes on its own: it waits to be cancelled,
/// then reports a stopped run with rows in it.
private struct HeldRowsScannerEngine: ScannerEngine {
    let session: HeldRowsScanSession
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        session
    }
}

private let heldItem = CleanupItemSummary(
    id: 1,
    url: URL(fileURLWithPath: "/tmp/held-rows-session/cache.bin"),
    displayName: "cache.bin",
    parentPath: "/tmp/held-rows-session",
    category: .applicationCache,
    risk: .safe,
    sizeInBytes: 4096,
    fileCount: 1,
    explanationKey: "cleanup.explanation.cache",
    sourceRuleID: "user-cache"
)

private actor HeldRowsScanSession: ScanSession {
    nonisolated let id = "held-rows-session"
    private var cancelled = false
    private var finished = false
    private(set) var shutDownCount = 0

    private var sentItem = false

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        if let pending {
            self.pending = nil
            return [.completed(pending)]
        }
        guard !sentItem, !cancelled else { return [] }
        sentItem = true
        return [.itemsFound([heldItem])]
    }

    func isFinished() async -> Bool { finished }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [heldItem], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    /// The stop answers with the summary a cancelled run produces; the session
    /// itself stays alive until `shutDown`.
    func cancel() async {
        cancelled = true
        finished = true
        pending = ScanReport(
            sessionID: id,
            startedAt: Date(),
            finishedAt: Date(),
            phase: .cancelled,
            scannedFileCount: 42,
            scannedByteCount: 4096,
            itemCount: 1,
            itemBytes: 4096,
            categoryTotals: [],
            duplicateGroupCount: 0,
            duplicateReclaimableBytes: 0,
            skippedLocations: []
        )
    }

    private var pending: ScanReport?

    func shutDown() async {
        shutDownCount += 1
    }
}

private struct PhaseOnlyScannerEngine: ScannerEngine {
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        PhaseOnlyScanSession()
    }
}

private actor PhaseOnlyScanSession: ScanSession {
    nonisolated let id = "phase-only-session"
    private var sentPhase = false

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        guard !sentPhase else { return [] }
        sentPhase = true
        return [.phaseChanged(.ready)]
    }

    func isFinished() async -> Bool { false }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    func cancel() async {}
}

/// An engine that reports its work as finished without ever publishing a phase.
private struct SilentScannerEngine: ScannerEngine {
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        SilentScanSession()
    }

}

private actor SilentScanSession: ScanSession {
    nonisolated let id = "silent-session"

    func pollEvents(maxEvents: Int) async -> [ScanEvent] { [] }

    func isFinished() async -> Bool { true }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    func cancel() async {}
}

/// A deterministic session that streams two categories of items, enough of the
/// first to push its early rows out of the model's recent window once the
/// second arrives.
private struct ItemBurstScannerEngine: ScannerEngine {
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        ItemBurstScanSession()
    }
}

private actor ItemBurstScanSession: ScanSession {
    nonisolated let id = "item-burst-session"
    private var events: [ScanEvent]

    init() {
        func items(_ count: Int, _ category: CleanupCategory, _ bytes: Int64) -> ScanEvent {
            .itemsFound(
                (1...count).map { index in
                    CleanupItemSummary(
                        id: Int64(index),
                        url: URL(fileURLWithPath: "/tmp/\(category.rawValue)-\(index)"),
                        displayName: "\(category.rawValue)-\(index)",
                        parentPath: "/tmp",
                        category: category,
                        risk: .safe,
                        sizeInBytes: bytes,
                        fileCount: 1,
                        explanationKey: "cleanup.explanation.cache",
                        sourceRuleID: "tests",
                        relatedBundleID: nil,
                        modifiedAt: nil,
                        isDirectory: true
                    )
                }
            )
        }
        events = [
            .phaseChanged(.preparing),
            items(380, .applicationCache, 1_000),
            items(40, .largeFiles, 2_000),
            .phaseChanged(.ready),
            .completed(
                ScanReport(
                    sessionID: "item-burst-session",
                    startedAt: Date(),
                    finishedAt: Date(),
                    phase: .ready,
                    scannedFileCount: 0,
                    scannedByteCount: 0,
                    scannedLocationCount: 1,
                    itemCount: 420,
                    itemBytes: 460_000,
                    categoryTotals: [],
                    duplicateGroupCount: 0,
                    duplicateReclaimableBytes: 0,
                    skippedLocations: []
                )
            ),
        ]
    }

    func pollEvents(maxEvents: Int) async -> [ScanEvent] {
        let count = min(max(maxEvents, 1), events.count)
        let result = Array(events.prefix(count))
        events.removeFirst(count)
        return result
    }

    func isFinished() async -> Bool { true }

    func page(
        offset: Int,
        limit: Int,
        sort: ScanSort,
        category: CleanupCategory?
    ) async throws -> ScanPage {
        ScanPage(items: [], remaining: 0)
    }

    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup] { [] }

    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember] { [] }

    func skippedLocations() async -> [SkippedLocation] { [] }

    func cancel() async {}
}
