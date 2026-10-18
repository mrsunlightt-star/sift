import Foundation
import XCTest
@testable import Core
import Shared

/// Rule matching, risk levels and the protection list (§16.1).
///
/// These are the checks that stand between a bug and a user's Documents folder,
/// so they state the exact path that must be refused rather than sampling.
final class RuleEngineTests: XCTestCase, @unchecked Sendable {
    private let home = URL(fileURLWithPath: "/Users/example")

    func test_builtInRulesAreUsable() {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
        XCTAssertFalse(engine.rules.isEmpty)
        XCTAssertTrue(engine.rules.allSatisfy { $0.risk != .protected })
        XCTAssertNil(engine.userRulesJSON, "an explicit rule list carries no user document")
    }

    /// The document the Rust core is handed.
    ///
    /// The scanner core discovers candidates and cannot see this engine's rule
    /// list, so a user's own rule only reaches it through this string. It must be
    /// the accepted file, and nothing at all when the file was rejected.
    func test_theAcceptedUserRuleFileIsTheDocumentHandedToTheOtherEngine() {
        let fixture = TemporaryDirectory(tag: "user-rules-overlay")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"custom-installers","category":"installers","risk":"review","root":"home",
           "relativePath":"Downloads","matchSpec":"filesByExtension",
           "extensions":["dmg"],"minAgeDays":7,"explanationKey":"k"}
        ]}
        """
        try? overlay.data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertTrue(engine.rules.contains { $0.id == "custom-installers" })
        XCTAssertEqual(engine.userRulesJSON, overlay, "the file must travel verbatim")
    }

    /// The shipped rules and the fallback table must agree on which ages the
    /// user's stale threshold governs, or a scan would depend on which file the
    /// app managed to read.
    func test_theStaleThresholdIsDeclaredAlikeInTheShippedFileAndTheFallback() throws {
        let shipped = RuleEngine(homeDirectory: home).rules
        for table in [shipped, RuleEngine.builtInRules] {
            let logs = try XCTUnwrap(table.first { $0.id == "user-logs" })
            XCTAssertEqual(logs.effectiveMinAgeDays(staleThresholdDays: 14), 14)
            XCTAssertEqual(logs.effectiveMinAgeDays(staleThresholdDays: 90), 90)

            let archives = try XCTUnwrap(table.first { $0.id == "download-archives" })
            XCTAssertEqual(
                archives.effectiveMinAgeDays(staleThresholdDays: 14),
                90,
                "an archive rule with its own age must not follow the setting"
            )
        }
    }

    /// A rule file that switches a shipped rule off must switch it off.
    ///
    /// The overlay has to *replace* the shipped rule before anything is filtered:
    /// filtering first would discard the override instead and leave the shipped
    /// rule running, which is the opposite of what the file asked for. The Rust
    /// core merges before it filters, and
    /// `the_overlay_replaces_before_it_filters` in `sift-rules` asserts the same
    /// document against the same semantics.
    func test_aDisabledOverrideSwitchesTheShippedRuleOff() {
        let fixture = TemporaryDirectory(tag: "rule-disable")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"user-logs","category":"logs","risk":"safe","root":"homeLibrary",
           "relativePath":"Logs","matchSpec":"childDirectories","enabled":false,
           "explanationKey":"cleanup.explanation.logs"}
        ]}
        """
        try? overlay.data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertFalse(
            engine.rules.contains { $0.id == "user-logs" },
            "a disabled override replaces the shipped rule and is then dropped"
        )
        XCTAssertTrue(engine.rules.contains { $0.id == "user-cache" })
    }

    /// And one that marks a shipped rule `protected` leaves no hole behind.
    func test_aProtectedOverrideReplacesTheShippedRuleRatherThanLeavingIt() {
        let fixture = TemporaryDirectory(tag: "rule-protect")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"user-logs","category":"logs","risk":"protected","root":"homeLibrary",
           "relativePath":"Logs","matchSpec":"childDirectories",
           "explanationKey":"cleanup.explanation.logs"}
        ]}
        """
        try? overlay.data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertFalse(
            engine.rules.contains { $0.id == "user-logs" },
            "the shipped rule is replaced by the protected one and filtered out"
        )
        // A path the removed rule used to claim is simply unrecognised now, which
        // is never `safe` and still cannot be removed by any rule.
        XCTAssertEqual(engine.risk(for: "/Users/example/Library/Logs/com.example.app"), .review)
    }

    func test_aRejectedUserRuleFileIsNotHandedToTheOtherEngine() {
        let fixture = TemporaryDirectory(tag: "user-rules-rejected")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        // A schema version this build does not understand.
        try? "{\"schemaVersion\":99,\"rules\":[]}".data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertNil(
            engine.userRulesJSON,
            "an unvalidated document must not reach the Rust core: it fails the scan"
        )
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
