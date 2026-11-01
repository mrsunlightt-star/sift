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
            XCTAssertFalse(
                ProtectedPaths.forbiddenRuleDirectories.contains(rule.relativePath),
                "rule `\(rule.id)` targets a directory of every application's data"
            )
            XCTAssertNotEqual(
                rule.category,
                .applicationResidue,
                "rule `\(rule.id)` claims residue; only the scanner may, because only it knows what is installed"
            )
        }
    }

    /// A rule file may not name a directory holding every application's data.
    ///
    /// The shipped table is asserted against the same list, but a rule the user
    /// wrote reached the scanner untouched: `Application Support` with
    /// `childDirectories` and `risk: safe` used to offer every installed
    /// application's live data as one pre-selected item. The Rust loader refuses
    /// the same three names from the same constants.
    func test_aRuleFileCannotNameAContainerOfEveryApplication() {
        for directory in ProtectedPaths.forbiddenRuleDirectories {
            for spelling in [directory, directory.lowercased()] {
                let overlay = """
                {"schemaVersion":1,"rules":[
                  {"id":"wide","category":"temporaryFiles","risk":"safe","root":"homeLibrary",
                   "relativePath":"\(spelling)","matchSpec":"childDirectories","explanationKey":"k"}
                ]}
                """
                XCTAssertThrowsError(try RuleEngine.decode(Data(overlay.utf8)), spelling) { error in
                    guard case RuleEngine.RuleError.forbiddenRuleDirectory = error else {
                        return XCTFail("expected forbiddenRuleDirectory for \(spelling), got \(error)")
                    }
                }
            }
        }

        // One level deeper is a different directory and stays usable: the
        // containment the invariant protects is the container itself.
        let deeper = """
        {"schemaVersion":1,"rules":[
          {"id":"deep","category":"temporaryFiles","risk":"review","root":"homeLibrary",
           "relativePath":"Application Support/com.example.app/Cache",
           "matchSpec":"directory","explanationKey":"k"}
        ]}
        """
        XCTAssertNoThrow(try RuleEngine.decode(Data(deeper.utf8)))
    }

    /// `anyFile` with no age is "every file under this root".
    func test_aRuleFileCannotMatchEveryFileWithoutAnAge() {
        let wide = """
        {"schemaVersion":1,"rules":[
          {"id":"wide","category":"temporaryFiles","risk":"review","root":"homeLibrary",
           "relativePath":"Caches","matchSpec":"anyFile","explanationKey":"k"}
        ]}
        """
        XCTAssertThrowsError(try RuleEngine.decode(Data(wide.utf8))) { error in
            guard case RuleEngine.RuleError.anyFileWithoutMinAge = error else {
                return XCTFail("expected anyFileWithoutMinAge, got \(error)")
            }
        }

        let aged = """
        {"schemaVersion":1,"rules":[
          {"id":"aged","category":"logs","risk":"review","root":"homeLibrary",
           "relativePath":"Caches","matchSpec":"anyFile","minAgeDays":30,"explanationKey":"k"}
        ]}
        """
        XCTAssertNoThrow(try RuleEngine.decode(Data(aged.utf8)))
    }

    /// `minAgeDays` has one domain, and both engines have to agree on it.
    ///
    /// The Rust loader reads the field as a `u32` and refuses a negative one, so
    /// a value this decoder accepted and that engine could not parse failed the
    /// whole scan with `invalidRequest` — the app showed "scan failed" with
    /// nothing pointing at the rule file.
    func test_aRuleFileCannotStateAnAgeOutsideTheSharedRange() throws {
        for days in [-1, ProtectedPaths.maximumMinAgeDays + 1, 9_999_999] {
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"aged","category":"logs","risk":"review","root":"homeLibrary",
               "relativePath":"Caches","matchSpec":"childDirectories",
               "minAgeDays":\(days),"explanationKey":"k"}
            ]}
            """
            XCTAssertThrowsError(try RuleEngine.decode(Data(overlay.utf8)), "\(days)") { error in
                guard case RuleEngine.RuleError.invalidMinAgeDays = error else {
                    return XCTFail("expected invalidMinAgeDays for \(days), got \(error)")
                }
            }
        }

        let boundary = """
        {"schemaVersion":1,"rules":[
          {"id":"aged","category":"logs","risk":"review","root":"homeLibrary",
           "relativePath":"Caches","matchSpec":"childDirectories",
           "minAgeDays":\(ProtectedPaths.maximumMinAgeDays),"explanationKey":"k"}
        ]}
        """
        XCTAssertNoThrow(try RuleEngine.decode(Data(boundary.utf8)))
    }

    /// A rule this build did not ship is offered at `review`, not `safe`.
    ///
    /// `safe` is the level that arrives pre-selected, and only a rule a release
    /// reviewed earns it. The rule still runs, so the feature stays useful; what
    /// it loses is the right to be queued without the user looking.
    func test_aRuleThisBuildDidNotShipIsOfferedAtReview() {
        let fixture = TemporaryDirectory(tag: "rule-clamp")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"my-junk","category":"temporaryFiles","risk":"safe","root":"homeLibrary",
           "relativePath":"Caches/MyApp","matchSpec":"childDirectories","explanationKey":"k"}
        ]}
        """
        try? overlay.data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        let added = engine.rules.first { $0.id == "my-junk" }
        XCTAssertEqual(added?.risk, .review, "an unshipped rule may not say safe")

        // A shipped rule keeps the level its release gave it, and an overlay
        // that retunes one keeps the level the overlay states: retuning a
        // reviewed rule is what the feature is for.
        let shipped = engine.rules.first { $0.id == "user-cache" }
        XCTAssertEqual(shipped?.risk, .safe)
    }

    /// A `*` component is expanded against the disk, one root per directory.
    ///
    /// The platform generates the middle component of a sandboxed application's
    /// container, so a rule cannot spell it and a rule per bundle identifier
    /// would go stale on the next install. The Rust core expands the same
    /// wildcard (`a_wildcard_expands_to_one_root_per_directory`).
    func test_aWildcardResolvesToOneRootPerDirectory() {
        let fixture = TemporaryDirectory(tag: "wildcard-roots")
        let one = fixture.directory("Library/Containers/com.one/Data/Library/Caches")
        let two = fixture.directory("Library/Containers/com.two/Data/Library/Caches")
        fixture.directory("Library/Containers/com.three/Data/Library/Preferences")

        let rule = RuleEngine.Rule(
            id: "container-caches",
            category: .applicationCache,
            risk: .safe,
            root: .homeLibrary,
            relativePath: "Containers/*/Data/Library/Caches",
            matchSpec: .directory,
            // The same exclusion the shipped rule carries: it names the
            // directory the `*` matched, so expansion drops that root.
            excludes: ["com.apple"],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.cache",
            isEnabled: true
        )
        let engine = RuleEngine(rules: [rule] + RuleEngine.builtInRules, homeDirectory: fixture.url)

        // The roots are spelled the way the engine normalises them (`/var` and
        // `/private/var` are one directory), and a container without the named
        // directory contributes a path that does not exist — the scanner skips
        // it, which is what `a_wildcard_expands_to_one_root_per_directory`
        // asserts on the Rust side.
        let roots = Set(engine.resolvedRoots(for: rule).map(\.path))
        XCTAssertTrue(
            roots.isSuperset(of: [one, two].map { RuleEngine.normalize($0.path) }),
            "one root per container that holds the named directory: \(roots)"
        )
        XCTAssertFalse(
            roots.contains(
                RuleEngine.normalize(
                    fixture.url
                        .appendingPathComponent(
                            "Library/Containers/com.three/Data/Library/Preferences"
                        )
                        .path
                )
            ),
            "the wildcard matches one component, not a subtree"
        )

        // The same question asked of a path rather than of the disk: `risk(for:)`
        // matches the pattern structurally, because a pre-flight asks it once per
        // row.
        // A `directory` rule claims the directory itself; a file inside it is
        // something no rule offered, so it stays at the level that asks the user.
        XCTAssertEqual(engine.risk(for: one.path), .safe)
        // The shipped rule excludes `com.apple`, and the exclusion names the
        // directory the `*` matched — the same step at which the scanner drops
        // the root, so the two answers stay one answer.
        XCTAssertEqual(
            engine.risk(
                for: fixture.url
                    .appendingPathComponent(
                        "Library/Containers/com.apple.Safari/Data/Library/Caches"
                    )
                    .path
            ),
            .review,
            "an exclusion on the wildcard's own directory is honoured by matching too"
        )
        XCTAssertEqual(
            engine.risk(for: one.appendingPathComponent("blob.bin").path),
            .review,
            "a file inside the directory is not the item the rule names"
        )
        XCTAssertEqual(
            engine.risk(
                for: fixture.url
                    .appendingPathComponent("Library/Containers/com.three/Data/Library/Preferences/p")
                    .path
            ),
            .review,
            "a sibling of the named directory is not claimed by the rule"
        )
    }

    /// A wildcard that would span an anchor's own children is refused.
    ///
    /// `*/…` under `~/Library` is one rule over every application's data root,
    /// which is the shape `FORBIDDEN_RULE_DIRECTORIES` exists to prevent.
    func test_aLeadingOrPartialWildcardIsRefused() {
        for refused in ["*/Caches", "Containers/com.apple.*", "Containers/**"] {
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"wide","category":"applicationCache","risk":"review","root":"homeLibrary",
               "relativePath":"\(refused)","matchSpec":"childDirectories","explanationKey":"k"}
            ]}
            """
            XCTAssertThrowsError(try RuleEngine.decode(Data(overlay.utf8)), refused)
        }

        // The two shapes the shipped table uses parse.
        for accepted in [
            "Containers/*/Data/Library/Caches",
            "Application Support/*/Cache",
        ] {
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"fine","category":"applicationCache","risk":"review","root":"homeLibrary",
               "relativePath":"\(accepted)","matchSpec":"directory","explanationKey":"k"}
            ]}
            """
            XCTAssertNoThrow(try RuleEngine.decode(Data(overlay.utf8)), accepted)
        }
    }

    /// `Containers/*` is one item per installed application, with or without a
    /// wildcard spelled into it.
    func test_aWildcardDirectlyInsideAContainerIsRefused() {
        for refused in ["Containers/*", "Application Support/*", "Group Containers/*"] {
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"wide","category":"applicationCache","risk":"review","root":"homeLibrary",
               "relativePath":"\(refused)","matchSpec":"childDirectories","explanationKey":"k"}
            ]}
            """
            XCTAssertThrowsError(try RuleEngine.decode(Data(overlay.utf8)), refused) { error in
                guard case RuleEngine.RuleError.forbiddenRuleDirectory = error else {
                    return XCTFail("expected forbiddenRuleDirectory for \(refused), got \(error)")
                }
            }
        }
    }

    /// A name set is `childDirectories` with the filter written in the rule.
    ///
    /// One rule covers `Cache`, `Caches`, `GPUCache` and `Code Cache` instead of
    /// one rule per spelling, and the name is compared without case because that
    /// is how the volume compares it. The Rust core applies the same set.
    func test_aNameSetSelectsTheChildDirectoriesItNames() {
        let rule = RuleEngine.Rule(
            id: "named",
            category: .applicationCache,
            risk: .safe,
            root: .homeLibrary,
            relativePath: "Application Support/*",
            matchSpec: .directoriesNamed(["Cache", "Caches"]),
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.cache",
            isEnabled: true
        )
        let engine = RuleEngine(rules: [rule], homeDirectory: home)

        for claimed in [
            "/Users/example/Library/Application Support/com.example.app/Cache",
            "/Users/example/Library/Application Support/com.example.app/Caches",
            "/Users/example/Library/Application Support/com.example.app/cache",
        ] {
            XCTAssertEqual(engine.risk(for: claimed), .safe, "\(claimed)")
        }
        for unclaimed in [
            "/Users/example/Library/Application Support/com.example.app/State",
            "/Users/example/Library/Application Support/com.example.app/Cache/Sub",
        ] {
            XCTAssertEqual(engine.risk(for: unclaimed), .review, "\(unclaimed)")
        }
    }

    /// A name set that cannot match a directory is refused where the file is read.
    func test_aNameSetWithoutAUsableNameIsRefused() {
        for names in ["[]", #"[""]"#, #"["Cache/Sub"]"#, #"["*"]"#, #"[".."]"#] {
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"named","category":"applicationCache","risk":"review","root":"homeLibrary",
               "relativePath":"Application Support/*","matchSpec":"directoriesNamed",
               "names":\(names),"explanationKey":"k"}
            ]}
            """
            XCTAssertThrowsError(try RuleEngine.decode(Data(overlay.utf8)), names) { error in
                guard case RuleEngine.RuleError.directoriesNamedWithoutNames = error else {
                    return XCTFail("expected directoriesNamedWithoutNames for \(names), got \(error)")
                }
            }
        }

        let accepted = """
        {"schemaVersion":1,"rules":[
          {"id":"named","category":"applicationCache","risk":"review","root":"homeLibrary",
           "relativePath":"Application Support/*","matchSpec":"directoriesNamed",
           "names":["Cache","GPUCache"],"explanationKey":"k"}
        ]}
        """
        XCTAssertNoThrow(try RuleEngine.decode(Data(accepted.utf8)))
    }

    /// The shipped table carries the three new families, at the levels they were
    /// reviewed at.
    func test_theShippedTableCarriesTheNewRuleFamilies() throws {
        let engine = RuleEngine(homeDirectory: home)
        let risks = Dictionary(uniqueKeysWithValues: engine.rules.map { ($0.id, $0.risk) })

        for id in [
            "container-caches",
            "app-support-caches",
            "xcode-derived-data",
            "xcode-device-support",
            "xcode-simulator-caches",
        ] {
            XCTAssertNotNil(risks[id], "rule `\(id)` is missing from the shipped table")
        }
        XCTAssertEqual(risks["container-caches"], .safe, "a sandboxed app's cache is rebuildable")
        XCTAssertEqual(
            risks["app-support-caches"],
            .review,
            "the same name can hold state the app cannot rebuild"
        )
        XCTAssertEqual(risks["xcode-derived-data"], .safe)
    }

    /// Both decoders accept and refuse the same documents.
    ///
    /// The Swift engine validates a user rule file and then hands the document
    /// to the Rust core, which parses it again. A document one accepts and the
    /// other refuses fails the whole scan with `invalidRequest`, and nothing in
    /// that error points at the rule file — so the corpus and the verdict live
    /// in `Tests/Fixtures/Rules`, and `the_shared_rule_fixtures_are_decided_the_same_way`
    /// in `sift-rules` runs the same files through `RuleSet::from_json`.
    func test_theSharedRuleFixturesAreDecidedTheSameWay() throws {
        let root = try Self.sharedRuleFixturesDirectory()
        let manager = FileManager.default

        var checked = 0
        for (directory, mustAccept) in [("accept", true), ("reject", false)] {
            let folder = root.appendingPathComponent(directory)
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertFalse(files.isEmpty, "the \(directory) corpus must not be empty")

            for file in files {
                let data = try Data(contentsOf: file)
                let name = "\(directory)/\(file.lastPathComponent)"
                if mustAccept {
                    XCTAssertNoThrow(try RuleEngine.decode(data), "\(name) must be accepted")
                } else {
                    XCTAssertThrowsError(try RuleEngine.decode(data), "\(name) must be refused")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 14, "the corpus is the point; keep it populated")
    }

    /// Locates `Tests/Fixtures/Rules` from wherever this file is being run.
    ///
    /// The suite runs from the source tree under `swift test` and from a
    /// rewritten copy under `.build/test-run/transformed` in the shim runner, so
    /// the corpus is found by walking up to the first directory that holds it
    /// rather than by assuming a fixed depth below `#filePath`.
    private static func sharedRuleFixturesDirectory() throws -> URL {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            for candidate in [
                directory.appendingPathComponent("Fixtures/Rules"),
                directory.appendingPathComponent("Tests/Fixtures/Rules"),
            ] where manager.fileExists(atPath: candidate.appendingPathComponent("accept").path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SiftTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Tests/Fixtures/Rules was not found above #filePath"]
        )
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

    /// Which paths a running application owns, and which it does not.
    ///
    /// The same table the Rust core asserts, because this predicate decides
    /// whether a `safe` item keeps its pre-selection: an engine that answers
    /// differently from the other moves a cache directory out from under a live
    /// process in one build and refuses to in the next.
    func test_aRunningApplicationOwnsThePathsThatNameIt() {
        let tokens = [
            "com.apple.safari", "com.spotify.client", "firefox", "visual studio code",
        ]

        for owned in [
            "/Users/x/Library/Containers/com.apple.Safari/Data/Library/Caches",
            "/Users/x/Library/Caches/com.apple.Safari",
            "/Users/x/Library/Caches/com.spotify.client",
            "/Users/x/Library/Caches/Firefox",
            "/Users/x/Library/Application Support/Visual Studio Code/Code Cache",
            "/Users/x/Library/Caches/com.apple.Safari.SafeBrowsing",
            "/Users/x/Library/Saved Application State/com.apple.Safari.savedState",
        ] {
            XCTAssertTrue(
                RuleEngine.isOwnedByRunningApplication(owned, tokens: tokens),
                "\(owned) belongs to a running application"
            )
        }

        for unowned in [
            "/Users/x/Library/Caches/Firefox Developer Edition",
            "/Users/x/Library/Caches/com.apple.SafariServices",
            "/Users/x/Library/Containers/com.example.other/Data/Library/Caches",
            "/Users/x/Library/Caches/Homebrew",
        ] {
            XCTAssertFalse(
                RuleEngine.isOwnedByRunningApplication(unowned, tokens: tokens),
                "\(unowned) must not be attributed to a running application"
            )
        }

        XCTAssertFalse(
            RuleEngine.isOwnedByRunningApplication("/Users/x/Library/Caches/com.apple.Safari", tokens: []),
            "no running applications is the ordinary case and must downgrade nothing"
        )
        XCTAssertFalse(
            RuleEngine.isOwnedByRunningApplication(
                "/Users/x/Library/Caches/com.apple.Safari",
                tokens: ["   "]
            ),
            "an empty alias cannot match a path component"
        )
    }

    /// The session root carries one spelling, the one the scan root uses.
    ///
    /// `confstr` answers `/var/folders/...`, whose `/var` is a symlink to
    /// `/private/var`. If the engine matched one spelling while the request named
    /// the other, the two engines would report one directory under two paths — and
    /// the authorisation check that keeps a rule inside its root would compare a
    /// prefix against a path that never starts with it.
    func test_theSessionRootResolvesBeforeItBecomesTheAnchor() {
        guard let root = RuleEngine.darwinUserTempRoot() else {
            // A process with no per-user temporary directory: nothing to assert.
            return
        }
        XCTAssertEqual(
            root.path,
            root.resolvingSymlinksInPath().path,
            "the anchor is already resolved"
        )
        XCTAssertTrue(
            RuleEngine.isPrefix(root.path, root.appendingPathComponent("C").path),
            "the rule root sits inside the scan root, whichever engine asks"
        )
    }

    /// A `userTemp` rule resolves under the session root the engine was given.
    ///
    /// `/var/folders/<xx>/<hash>` is generated per login session, so the engine
    /// carries the resolved path instead of computing it. Without one the anchor
    /// resolves to nothing — never to `/var/folders`, which holds every session on
    /// the machine.
    func test_theUserTempAnchorResolvesUnderTheSessionRootTheEngineWasGiven() {
        let fixture = TemporaryDirectory(tag: "user-temp-anchor")
        fixture.write("C/com.example.app/blob.bin", bytes: 4096)
        let rule = RuleEngine.Rule(
            id: "user-temp-caches",
            category: .temporaryFiles,
            risk: .review,
            root: .userTemp,
            relativePath: "C",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: 7,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.temporary",
            isEnabled: true
        )

        let engine = RuleEngine(rules: [rule], homeDirectory: home, userTempDirectory: fixture.url)
        XCTAssertEqual(
            engine.resolvedRoots(for: rule).map { RuleEngine.normalize($0.path) },
            [RuleEngine.normalize(fixture.url.appendingPathComponent("C").path)],
            "the anchor is the session root, so the rule's root is `C` inside it"
        )

        let withoutSession = RuleEngine(rules: [rule], homeDirectory: home, userTempDirectory: nil)
        XCTAssertTrue(
            withoutSession.resolvedRoots(for: rule).isEmpty,
            "an engine with no session root must not reach one"
        )
    }

    /// The shipped table says which rules own one application's data.
    ///
    /// The flag is what makes the running-application check apply at all, so it
    /// belongs to the table rather than to a call site: `user-cache` is `safe`
    /// and its items belong to whichever application wrote them, while the
    /// installer rule finds files no application owns.
    func test_theRulesThatOwnApplicationDataAskForTheApplicationToBeClosed() {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)

        for path in [
            "\(home.path)/Library/Caches/com.apple.Safari",
            "\(home.path)/Library/Containers/com.example.app/Data/Library/Caches",
            "\(home.path)/Library/Application Support/discord/GPUCache",
            "\(home.path)/Library/Saved Application State/com.apple.Safari.savedState",
        ] {
            XCTAssertTrue(engine.requiresAppClosed(for: path), "\(path)")
        }

        for path in [
            "\(home.path)/Downloads/old.dmg",
            "\(home.path)/Library/Logs/SomeApp",
            "\(home.path)/Documents/report.pages",
        ] {
            XCTAssertFalse(engine.requiresAppClosed(for: path), "\(path)")
        }
    }

    /// A rule file that says nothing about the flag claims no application.
    ///
    /// The default has to be `false`: a document written before the flag existed
    /// must not silently start refusing items while an application runs.
    func test_aRuleFileThatOmitsTheFlagDoesNotOwnApplicationData() throws {
        let document = """
        {"schemaVersion":1,"rules":[
          {"id":"plain","category":"applicationCache","risk":"safe","root":"homeLibrary",
           "relativePath":"Caches","matchSpec":"childDirectories",
           "explanationKey":"cleanup.explanation.cache"}
        ]}
        """
        let rules = try RuleEngine.decode(Data(document.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(rules[0].needsAppClosed)

        let engine = RuleEngine(rules: rules, homeDirectory: home)
        XCTAssertFalse(engine.requiresAppClosed(for: "\(home.path)/Library/Caches/com.example.app"))
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
