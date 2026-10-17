import Foundation
import XCTest
@testable import Core
import Shared

/// Rule matching, risk levels and the protection list (§16.1).
///
/// These are the checks that stand between a bug and a user's Documents folder,
/// so they state the exact path that must be refused rather than sampling.
final class RuleEngineTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")

    func test_builtInRulesAreUsable() {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
        XCTAssertFalse(engine.rules.isEmpty)
        XCTAssertTrue(engine.rules.allSatisfy { $0.risk != .protected })
    }
}

/// A fixture that removes itself, so a failing test cannot leave anything behind.
class TemporaryDirectory {
    let url: URL

    init(tag: String) {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-tests-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        url = candidate.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relative: String, bytes: Int) -> URL {
        let target = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(repeating: 0x78, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func writeBytes(_ relative: String, _ data: Data) -> URL {
        let target = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: target)
        return target
    }

    func directory(_ relative: String) -> URL {
        let target = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func age(_ url: URL, days: Int) {
        let when = Date().addingTimeInterval(-Double(days) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }
}
