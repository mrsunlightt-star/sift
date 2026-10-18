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
}
