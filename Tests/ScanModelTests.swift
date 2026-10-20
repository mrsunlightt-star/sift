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
        let page = await model.page(offset: 0, limit: 50, sort: .size, category: nil)
        XCTAssertFalse(
            page.items.isEmpty,
            "the settled index must already hold the items the scan found"
        )
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
}


/// A deterministic session whose terminal phase sits beyond the scan model's
/// ordinary poll batch and one 256-event tail batch.
private struct BurstScannerEngine: ScannerEngine {
    let queuedPhaseEvents: Int
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        BurstScanSession(queuedPhaseEvents: queuedPhaseEvents)
    }

    func analyzeStorage(
        roots: [ScanRoot],
        ignoredPaths: [String]
    ) async throws -> StorageAnalysis {
        throw ScannerError(code: .internalError)
    }
}

private actor BurstScanSession: ScanSession {
    nonisolated let id = "burst-session"
    private var events: [ScanEvent]

    init(queuedPhaseEvents: Int) {
        events = Array(repeating: .phaseChanged(.preparing), count: queuedPhaseEvents)
        events.append(.phaseChanged(.ready))
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

/// An engine that reports its work as finished without ever publishing a phase.
private struct SilentScannerEngine: ScannerEngine {
    var kind: ScannerEngineKind { .swift }

    func startScan(_ request: ScanRequest) async throws -> any ScanSession {
        SilentScanSession()
    }

    func analyzeStorage(
        roots: [ScanRoot],
        ignoredPaths: [String]
    ) async throws -> StorageAnalysis {
        throw ScannerError(code: .internalError)
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
