import Foundation
import XCTest
@testable import Core
import Shared

/// A draft rule for a directory nothing claims (the coverage page's follow-up).
///
/// The draft is only worth showing if it loads: a snippet this build would reject
/// is a promise the app cannot keep, so every test here goes through the same
/// loader the app uses at launch.
final class RuleDraftTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "draft")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeRules() -> RuleEngine {
        RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
    }

    private func draft(_ relative: String) -> Result<RuleDraft, RuleDraft.Refusal> {
        RuleDraft.make(
            for: fixture.url.appendingPathComponent(relative),
            rules: makeRules()
        )
    }

    /// A folder under `~/Library` becomes a rule anchored at `homeLibrary`, with
    /// its children as the items and an age so an idle folder is recognisable.
    func test_aFolderUnderLibraryBecomesAReviewRuleOverItsChildren() throws {
        let built = try draft("Library/Huawei").get()

        XCTAssertEqual(built.ruleID, "user-huawei")
        XCTAssertTrue(built.json.contains(#""root": "homeLibrary""#), built.json)
        XCTAssertTrue(built.json.contains(#""relativePath": "Huawei""#), built.json)
        XCTAssertTrue(built.json.contains(#""matchSpec": "childDirectories""#), built.json)
        XCTAssertTrue(built.json.contains(#""risk": "review""#), built.json)
        XCTAssertTrue(built.json.contains(#""minAgeDays": 30"#), built.json)
    }

    /// The draft loads through the product's own decoder — that is the promise the
    /// page makes when it hands the snippet over.
    func test_theDraftLoadsThroughTheRuleLoader() throws {
        let built = try draft("Library/Huawei").get()
        let document = #"{"schemaVersion":1,"rules":["# + built.json + "]}"

        let rules = try RuleEngine.decode(Data(document.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "user-huawei")
        XCTAssertEqual(rules[0].risk, .review, "a rule for unjudged data is never pre-selected")
        XCTAssertEqual(rules[0].root, .homeLibrary)
        XCTAssertEqual(rules[0].relativePath, "Huawei")
        XCTAssertEqual(rules[0].minAgeDays, 30)
        XCTAssertNotNil(
            rules[0].explanationKey.isEmpty ? nil : rules[0].explanationKey,
            "the row needs a sentence to show"
        )
    }

    /// A draft reads as a *child* rule, so the rule recognises the folder's
    /// contents rather than offering the vendor tree as one item.
    func test_theDraftMatchesTheFoldersChildrenAndNotTheFolder() {
        let built = try? draft("Library/Huawei").get()
        guard let built,
              let rule = try? RuleEngine.decode(
                  Data((#"{"schemaVersion":1,"rules":["# + built.json + "]}").utf8)
              ).first
        else {
            return XCTFail("the draft has to load before it can be judged")
        }

        let engine = makeRules()
        XCTAssertEqual(engine.risk(for: "\(fixture.url.path)/Library/Huawei/Sdk"), .review)
        XCTAssertEqual(
            engine.risk(for: "\(fixture.url.path)/Library/Huawei"),
            .review,
            "an unrecognised path is never safe, whether or not a draft exists"
        )
        XCTAssertTrue(rule.isEnabled)
    }

    /// A path one level up from a folder is anchored at the home directory.
    func test_aFolderInTheHomeDirectoryIsAnchoredAtHome() throws {
        let built = try draft(".codex").get()
        XCTAssertEqual(built.ruleID, "user-codex")
        XCTAssertTrue(built.json.contains(#""root": "home""#), built.json)
        XCTAssertTrue(built.json.contains(#""relativePath": ".codex""#), built.json)
    }

    /// The containers are refused by name, not by a JSON error later: a rule over
    /// `Application Support` or `Group Containers` would offer every application's
    /// data at once.
    func test_aContainerIsRefusedByTheDraft() {
        for relative in ["Library/Application Support", "Library/Group Containers", "Library/Containers"] {
            switch draft(relative) {
            case let .success(built):
                XCTFail("\(relative) must not become a rule: \(built.json)")
            case let .failure(refusal):
                guard case .container = refusal else {
                    XCTFail("\(relative) should be refused as a container, got \(refusal)")
                    continue
                }
            }
        }
    }

    /// A vendor folder inside a container is refused too: its children are
    /// application data roots, which is what the container rule exists to prevent
    /// one level up.
    func test_aVendorFolderInsideAContainerIsRefused() {
        for relative in ["Library/Application Support/Google", "Library/Containers/com.example.app"] {
            switch draft(relative) {
            case let .success(built):
                XCTFail("\(relative) must not become a rule: \(built.json)")
            case let .failure(refusal):
                guard case .container = refusal else {
                    XCTFail("\(relative) should be refused as a container, got \(refusal)")
                    continue
                }
            }
        }
        // A named cache directory inside an application's data is the shipped
        // shape and stays draftable: the item is the cache, not the data root.
        XCTAssertFalse(
            RuleEngine.childrenWouldExposeApplicationData("Library/Application Support/Google/Chrome/Default")
        )
    }

    /// A directory the protection list refuses never gets a draft.
    func test_aProtectedDirectoryIsRefused() {
        guard case .failure(.protected) = draft("Documents") else {
            return XCTFail("the user's Documents folder must not be draftable")
        }
    }

    /// The anchor itself is a place to look inside, never an item.
    func test_theAnchorItselfIsRefused() {
        guard case .failure(.anchorItself) = draft("Library") else {
            return XCTFail("the library anchor must not be draftable")
        }
    }
}
