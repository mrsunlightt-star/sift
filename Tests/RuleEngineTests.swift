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

    /// The fallback table and the shipped rule file are one table.
    ///
    /// They had drifted: the file held seven rules and the fallback those same
    /// seven, against twelve in the Rust table the shipped scanner actually
    /// applies — so a rule could be running that was invisible in the file a
    /// reviewer reads. Both are generated from the Rust table now; this is the
    /// check that keeps them the same document.
    func test_theFallbackTableIsTheShippedRuleFile() throws {
        let shipped = try RuleEngine.decode(try Data(contentsOf: try Self.shippedRuleFile()))

        XCTAssertFalse(shipped.isEmpty, "the shipped rule file must carry the built-in rules")
        XCTAssertEqual(
            shipped,
            RuleEngine.builtInRules,
            "run Scripts/generate-rules.py: the fallback table and the shipped file must be one table"
        )
        XCTAssertEqual(
            RuleEngine(homeDirectory: home).rules,
            RuleEngine.builtInRules,
            "the table the app loads from the bundle is the generated one"
        )
    }

    /// `Core/Resources/CleaningRules.json`, found from wherever this file runs.
    ///
    /// The suite runs from three places — Xcode, `swift test`, and
    /// `Scripts/run-tests.sh`, which copies the sources under `.build/test-run` —
    /// so the path comes from walking up to the repository rather than from
    /// counting parent directories.
    private static func shippedRuleFile() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent("RustCore/Cargo.toml")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory.appendingPathComponent("Core/Resources/CleaningRules.json")
            }
            directory = directory.deletingLastPathComponent()
        }
        throw NSError(
            domain: "SiftTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "the repository root is not reachable from \(#filePath)"
            ]
        )
    }

    /// Every shipped rule names an explanation the user can read.
    ///
    /// The scanner hands the UI a key rather than a sentence, and nothing used to
    /// connect the two: the Rust core emitted `cleanup.<rule-id>.explanation` for
    /// every rule, no such key existed in the catalog, and each item quietly fell
    /// back to its category's generic line. An explanation is rendered with no
    /// arguments, so a key carrying a placeholder reaches that same outcome from
    /// the other side — the user reads `%d`.
    func test_everyShippedRuleExplanationResolves() throws {
        for rule in RuleEngine.builtInRules {
            let key = try XCTUnwrap(
                LocalizationKey(rawValue: rule.explanationKey),
                "rule `\(rule.id)` names an explanation the catalog does not carry: \(rule.explanationKey)"
            )
            XCTAssertNotEqual(
                key.localized,
                rule.explanationKey,
                "rule `\(rule.id)` has no translation for \(rule.explanationKey)"
            )
            XCTAssertFalse(
                key.localized.contains("%"),
                "an explanation is rendered with no arguments, so no rule may carry a placeholder: \(key.localized)"
            )
        }
    }

    /// No shipped rule offers a container of every application's data.
    ///
    /// A rule matches a name shape or an age and cannot know whether an
    /// application is installed, so the two locations that hold one directory per
    /// application are refused here: `Directory` made one cleanup item out of the
    /// whole store, and `ChildDirectories` offered each application's live data as
    /// junk. Residue is decided by the scanner, which compares names against the
    /// installed bundle identifiers.
    func test_noShippedRuleOffersAContainerOrClaimsResidue() {
        for rule in RuleEngine.builtInRules {
            XCTAssertNotEqual(
                rule.relativePath,
                "Containers",
                "rule `\(rule.id)` targets every sandboxed application's container"
            )
            XCTAssertNotEqual(
                rule.relativePath,
                "Group Containers",
                "rule `\(rule.id)` targets the containers applications share"
            )
            XCTAssertNotEqual(
                rule.category,
                .applicationResidue,
                "rule `\(rule.id)` claims residue; only the scanner may, because only it knows what is installed"
            )
        }
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
