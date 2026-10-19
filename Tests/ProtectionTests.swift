import Foundation
import XCTest
@testable import Core
import Shared

/// The protection list is the product's central safety promise (§8.3, §13.3).
///
/// Each test names a path the user would be upset to lose and asserts it is
/// refused, plus the near-miss paths that must still be allowed so the rules are
/// not so broad they disable the product.
final class ProtectionTests: XCTestCase, @unchecked Sendable {
    private let home = URL(fileURLWithPath: "/Users/example")
    private lazy var engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)

    func test_userContentFoldersAreProtected() {
        for child in ["Documents", "Desktop", "Movies", "Music", "Pictures", "Projects", "Developer"] {
            let path = "/Users/example/\(child)/file.txt"
            XCTAssertNotNil(engine.protectionReason(for: path), "\(child) must be protected")
        }
    }

    func test_systemPrefixesAreProtected() {
        for path in [
            "/System/Library/Caches/com.apple.x",
            "/usr/local/bin/tool",
            "/private/var/vm/swapfile",
            "/Library/Apple/System/x",
            "/Volumes/External/anything",
        ] {
            XCTAssertNotNil(engine.protectionReason(for: path), "\(path) must be protected")
        }
    }

    func test_secretsAndUserLibrariesAreProtected() {
        XCTAssertNotNil(
            engine.protectionReason(for: "/Users/example/Library/Keychains/login.keychain-db")
        )
        XCTAssertNotNil(
            engine.protectionReason(for: "/Users/example/Library/Mobile Documents/com~apple~x/f")
        )
        XCTAssertNotNil(
            engine.protectionReason(for: "/Users/example/Pictures/Photos Library.photoslibrary/db")
        )
    }

    func test_thePhotoLibrarySuffixIsCaseInsensitive() {
        // A rename that only changes case is still the same package on a
        // case-insensitive volume. Protection must not depend on the spelling.
        for path in [
            "/Users/example/Archive/Photos Library.PHOTOSLIBRARY/db",
            "/Users/example/Archive/Archive.PhotosLibrary/db",
            "/Users/example/Library/Photos.PHOTOSLIBRARY",
        ] {
            XCTAssertNotNil(engine.protectionReason(for: path), "\(path) must be protected")
            XCTAssertFalse(engine.canAuthorize(url: URL(fileURLWithPath: path)))
        }
    }

    func test_anExcludedApplicationDirectoryIsRefusedThroughItsAncestors() {
        // The candidate's own name is a log file; the exclusion belongs to an
        // ancestor. Checking only the last component let the file through.
        for path in [
            "/Users/example/Library/Caches/CloudKit/db.bin",
            "/Users/example/Library/Caches/com.apple.bird/data",
            "/Users/example/Downloads/com.apple.iCloud/file",
        ] {
            XCTAssertTrue(engine.isInExcludedLocation(path), "\(path) is inside excluded data")
        }
        XCTAssertFalse(
            engine.isInExcludedLocation("/Users/example/Library/Caches/com.example.app/db.bin")
        )
    }

    func test_ruleExcludesCoverEverythingBelowTheNamedDirectory() {
        let rule = RuleEngine.Rule(
            id: "excluded",
            category: .installers,
            risk: .review,
            root: .home,
            relativePath: "Downloads",
            matchSpec: .filesByExtension(["txt"]),
            excludes: ["private"],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.installers",
            isEnabled: true
        )
        XCTAssertTrue(
            engine.isExcludedByRule(
                rule,
                path: "/Users/example/Downloads/private/secret.txt",
                under: "/Users/example/Downloads"
            )
        )
        XCTAssertTrue(
            engine.isExcludedByRule(
                rule,
                path: "/Users/example/Downloads/private.plist",
                under: "/Users/example/Downloads"
            ),
            "an exclude also covers names that extend it with a suffix"
        )
        XCTAssertFalse(
            engine.isExcludedByRule(
                rule,
                path: "/Users/example/Downloads/open.txt",
                under: "/Users/example/Downloads"
            )
        )
    }

    func test_anUnknownMatchSpecRejectsTheRuleFile() {
        // Treating an unknown value as "absent" would derive a default from the
        // relative path and quietly turn a misspelled `filesByExtension` into a
        // rule over the whole directory.
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"typo","category":"installers","risk":"review","root":"home",
           "relativePath":"Downloads","matchSpec":"filesByExtensionn",
           "explanationKey":"cleanup.explanation.installers"}
        ]}
        """
        do {
            _ = try RuleEngine.decode(Data(overlay.utf8))
            XCTFail("an unknown matchSpec must refuse the file")
        } catch let error as RuleEngine.RuleError {
            XCTAssertEqual(error, .unknownMatchSpec("filesByExtensionn"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // A rule without a matchSpec still defaults from its shape.
        let defaulted = """
        {"schemaVersion":1,"rules":[
          {"id":"defaulted","category":"installers","risk":"review","root":"home",
           "relativePath":"Downloads","explanationKey":"cleanup.explanation.installers"}
        ]}
        """
        XCTAssertNotNil(try? RuleEngine.decode(Data(defaulted.utf8)))
    }

    func test_everyEntryOnTheSharedProtectionListIsProtected() {
        // The list comes from `ProtectedPaths`, which is generated from the Rust
        // constants the scanner core reads. Asserting on the generated list is
        // what keeps the two engines from protecting different sets.
        for entry in ProtectedPaths.libraryChildren {
            XCTAssertNotNil(
                engine.protectionReason(for: "/Users/example/\(entry.path)/content"),
                "\(entry.path) is on the shared protection list"
            )
        }
        for child in ProtectedPaths.homeChildren {
            XCTAssertNotNil(
                engine.protectionReason(for: "/Users/example/\(child)/file.txt"),
                "\(child) is on the shared protection list"
            )
        }
        for prefix in ProtectedPaths.prefixes {
            XCTAssertNotNil(
                engine.protectionReason(for: "\(prefix)/anything"),
                "\(prefix) is on the shared protection list"
            )
        }
    }

    func test_theLibraryItselfAndOrdinaryApplicationStateAreAllowed() {
        // The library is not an entry: almost everything the product cleans lives
        // inside it, so a rule broad enough to cover the whole folder would
        // disable the app rather than protect anything.
        XCTAssertTrue(engine.isAllowed("/Users/example/Library"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Library/Application Support/com.example.app/x"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Library/Accounts-old/settings.json"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Library/Mailbox/data"))
    }

    func test_ordinaryCachesAndDownloadsAreAllowed() {
        XCTAssertTrue(engine.isAllowed("/Users/example/Library/Caches/com.example.app/blob"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Library/Logs/com.example.app/out.log"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Downloads/installer.dmg"))
    }

    func test_similarNamesAreNotSweptUpByPrefixRules() {
        // `/System` must not match `/Systematic`, and `~/Documents` must not match
        // `~/Documents-old`: the comparison is component-wise, not by prefix text.
        XCTAssertTrue(engine.isAllowed("/Systematic/file"))
        XCTAssertTrue(engine.isAllowed("/Users/example/Documents-old/notes.txt"))
        XCTAssertTrue(engine.isAllowed("/usr-local/bin/tool"))
    }

    func test_pathTraversalIsResolvedBeforeTheCheck() {
        let sneaky = "/Users/example/Downloads/../Documents/secret.txt"
        XCTAssertNotNil(engine.protectionReason(for: sneaky))
    }

    func test_symlinkedVariantOfASystemPathIsStillProtected() {
        // `/var` is a symlink to `/private/var`, so the same directory arrives
        // under two spellings; both must be refused. The Rust core asserts the
        // same matrix against the same generated table.
        XCTAssertNotNil(engine.protectionReason(for: "/private/var/vm/swapfile"))
        XCTAssertNotNil(engine.protectionReason(for: "/var/vm/swapfile"))
        XCTAssertNotNil(engine.protectionReason(for: "/private/etc/hosts"))
        XCTAssertNotNil(engine.protectionReason(for: "/etc/hosts"))
    }

    func test_everySymlinkAliasNormalisesToItsTarget() {
        // The table is generated from `SYMLINK_ALIASES`/`SYMLINK_ALIAS_TARGETS`
        // in the Rust source, so this is the Swift half of one shared contract.
        XCTAssertFalse(ProtectedPaths.symlinkAliases.isEmpty, "the alias table must not be empty")
        for entry in ProtectedPaths.symlinkAliases {
            XCTAssertEqual(
                RuleEngine.normalize(entry.alias),
                entry.target,
                "\(entry.alias) must normalise to its target"
            )
            XCTAssertEqual(
                RuleEngine.normalize("\(entry.alias)/child/leaf"),
                "\(entry.target)/child/leaf",
                "\(entry.alias) must normalise as a parent"
            )
            // Aliases are a whole-segment match: a directory whose name merely
            // starts with the alias text is a different place.
            XCTAssertEqual(RuleEngine.normalize("\(entry.alias)file"), "\(entry.alias)file")
        }
        XCTAssertEqual(RuleEngine.normalize("/variables/file"), "/variables/file")
        XCTAssertEqual(RuleEngine.normalize("/etcetera/x"), "/etcetera/x")
    }

    func test_everyAliasedSystemPrefixIsProtected() {
        // A prefix the list spells `/private/...` must also be refused in its
        // `/var/...` spelling, which is the bug this table exists to prevent.
        for prefix in ProtectedPaths.prefixes {
            for entry in ProtectedPaths.symlinkAliases
            where prefix.hasPrefix("\(entry.target)/") {
                let aliased = entry.alias + prefix.dropFirst(entry.target.count)
                XCTAssertNotNil(
                    engine.protectionReason(for: "\(aliased)/anything"),
                    "\(aliased) is \(prefix) under its alias"
                )
            }
        }
    }

    func test_riskIsTheMostCautiousMatchingRule() {
        XCTAssertEqual(engine.risk(for: "/Users/example/Library/Caches/com.example.app"), .safe)
        XCTAssertEqual(engine.risk(for: "/Users/example/Downloads/thing.dmg"), .review)
        XCTAssertEqual(engine.risk(for: "/Users/example/Documents/taxes.pdf"), .protected)
    }

    func test_unclassifiedContentIsNeverSafe() {
        // A path no rule claims must not be pre-selected: the product only
        // pre-selects what it can explain.
        XCTAssertNotEqual(engine.risk(for: "/Users/example/SomeUnknownPlace/file"), .safe)
    }

    func test_bundleIdentifierDetectionRejectsOrdinaryNames() {
        XCTAssertTrue(engine.looksLikeBundleIdentifier("com.example.app"))
        XCTAssertTrue(engine.looksLikeBundleIdentifier("org.mozilla.firefox"))
        XCTAssertFalse(engine.looksLikeBundleIdentifier("Editor"))
        XCTAssertFalse(engine.looksLikeBundleIdentifier("My Project"))
        XCTAssertFalse(engine.looksLikeBundleIdentifier("com..x"))
    }

    func test_packageDirectoriesAreRecognised() {
        XCTAssertTrue(engine.isPackageDirectory(name: "Safari.app"))
        XCTAssertTrue(engine.isPackageDirectory(name: "Photos.photoslibrary"))
        XCTAssertFalse(engine.isPackageDirectory(name: "notes.txt"))
    }

    func test_userRuleFileCannotUnprotectAPath() {
        let fixture = TemporaryDirectory(tag: "rules")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        // A rule that tries to claim Documents and mark it safe.
        let overlay = """
        {"schemaVersion":1,"rules":[
          {"id":"evil","category":"applicationCache","risk":"safe","root":"home",
           "relativePath":"Documents","matchSpec":"directory",
           "explanationKey":"cleanup.explanation.cache"}
        ]}
        """
        try? overlay.data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertNotNil(
            engine.protectionReason(for: "/Users/example/Documents/taxes.pdf"),
            "the protection list must win over a rule file"
        )
        XCTAssertEqual(
            engine.risk(for: "/Users/example/Documents"),
            .protected,
            "a rule cannot downgrade a protected path"
        )
    }

    func test_aUserRuleFileCannotPointOutsideItsAnchor() {
        // `relativePath` is joined under an anchor, and both an absolute path and
        // a `..` component would leave it: `/Users/example/Library/../../Shared`
        // is spelled as though it sits under the home directory and resolves to
        // `/Users/Shared`. The file is refused whole, so the built-ins stay.
        for escaping in ["../../Shared", "../Shared", "/etc", "Logs/../../Shared"] {
            let fixture = TemporaryDirectory(tag: "rule-escape")
            let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"escape","category":"logs","risk":"safe","root":"homeLibrary",
               "relativePath":"\(escaping)","matchSpec":"childDirectories",
               "explanationKey":"cleanup.explanation.logs"}
            ]}
            """
            try? overlay.data(using: .utf8)?.write(to: ruleFile)

            let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
            XCTAssertFalse(
                engine.rules.contains { $0.id == "escape" },
                "\(escaping) must not load"
            )
            XCTAssertNil(engine.userRulesJSON, "\(escaping) must not reach the Rust core either")
            XCTAssertFalse(engine.rules.isEmpty, "the shipped rules must survive a bad file")
        }
    }

    func test_anOrdinaryRelativePathStillResolves() {
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
        let rule = engine.rules.first { $0.id == "user-logs" }!
        XCTAssertEqual(
            engine.resolvedRoots(for: rule).map(\.path),
            ["/Users/example/Library/Logs"]
        )
        // `.` components collapse rather than being refused.
        let nested = RuleEngine.Rule(
            id: "nested",
            category: .logs,
            risk: .review,
            root: .homeLibrary,
            relativePath: "Logs/./DiagnosticReports",
            matchSpec: .anyFile,
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.logs",
            isEnabled: true
        )
        XCTAssertEqual(
            engine.resolvedRoots(for: nested).map(\.path),
            ["/Users/example/Library/Logs/DiagnosticReports"]
        )
    }

    func test_aRootThatWouldLeaveItsAnchorResolvesToNothing() {
        // The second line: a table assembled in code, or one that reached the
        // engine another way, still cannot climb out of its anchor.
        let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
        for escaping in ["../..", "../../Shared", "/etc"] {
            let rule = RuleEngine.Rule(
                id: "climbing",
                category: .logs,
                risk: .review,
                root: .homeLibrary,
                relativePath: escaping,
                matchSpec: .childDirectories,
                excludes: [],
                minAgeDays: nil,
                requiresFullDiskAccess: false,
                explanationKey: "cleanup.explanation.logs",
                isEnabled: true
            )
            XCTAssertTrue(
                engine.resolvedRoots(for: rule).isEmpty,
                "\(escaping) must resolve to no root"
            )
        }
    }

    func test_malformedRuleFileLeavesTheBuiltInsInPlace() {
        let fixture = TemporaryDirectory(tag: "rules-broken")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        try? "{\"schemaVersion\":99}".data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertFalse(engine.rules.isEmpty, "the shipped rules must survive a bad file")
        XCTAssertNotNil(engine.protectionReason(for: "/Users/example/Documents/x"))
    }
}
