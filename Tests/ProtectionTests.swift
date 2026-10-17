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
        // under two spellings; both must be refused.
        XCTAssertNotNil(engine.protectionReason(for: "/private/var/vm/swapfile"))
        XCTAssertNotNil(engine.protectionReason(for: "/var/vm/swapfile"))
        XCTAssertNotNil(engine.protectionReason(for: "/private/etc/hosts"))
        XCTAssertNotNil(engine.protectionReason(for: "/etc/hosts"))
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

    func test_malformedRuleFileLeavesTheBuiltInsInPlace() {
        let fixture = TemporaryDirectory(tag: "rules-broken")
        let ruleFile = fixture.url.appendingPathComponent("CleaningRules.json")
        try? "{\"schemaVersion\":99}".data(using: .utf8)?.write(to: ruleFile)

        let engine = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
        XCTAssertFalse(engine.rules.isEmpty, "the shipped rules must survive a bad file")
        XCTAssertNotNil(engine.protectionReason(for: "/Users/example/Documents/x"))
    }
}
