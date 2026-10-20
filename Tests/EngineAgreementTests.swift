import Foundation
import XCTest
@testable import Core
import Shared

/// The two scanner cores must find the same things (§6.4).
///
/// Rules, path normalisation, the protection list, age thresholds, residue
/// detection and the hidden-file scope all exist twice — once in Rust, once in
/// Swift. Sharing one rule table says the two engines are *given* the same
/// rules; nothing until this file checked what they *do* with them, and the
/// fallback engine is only a fallback if it recognises what the production
/// engine recognises.
///
/// Every field compared here is one the user sees in a row: the path, its
/// category, its risk band, its size, how many files it holds and the sentence
/// it carries. A difference in any of them means the list reads differently on
/// a Mac that fell back to Swift than on one running the Rust core.
///
/// The production engine is taken from `ScannerEngineFactory`, so this compares
/// whatever this build actually ships against the reference implementation. A
/// build that links no Rust core would compare Swift with Swift and prove
/// nothing, which is why the core is required to be present rather than
/// optional: the archive is force-loaded by the test target, so its absence is
/// a broken build and not a reason to soften the check.
final class EngineAgreementTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    /// One row, reduced to what the user can see.
    private struct Row: Hashable, CustomStringConvertible {
        let path: String
        let displayName: String
        let category: String
        let risk: String
        let sizeInBytes: Int64
        let fileCount: Int
        let isDirectory: Bool
        let explanationKey: String
        let relatedBundleID: String?

        var description: String {
            "\(path) [\(category)/\(risk), \(sizeInBytes)B, \(fileCount) files"
                + ", dir=\(isDirectory), \(explanationKey)"
                + (relatedBundleID.map { ", bundle=\($0)" } ?? "") + "]"
        }
    }

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "engines")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    // MARK: - The comparison

    /// The production engine and the reference engine, over one fixture.
    private func compare(
        _ request: ScanRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertTrue(
            ScannerEngineFactory.hasRustCore,
            "this fixture is only meaningful with the Rust core linked: Scripts/bootstrap.sh builds it",
            file: file,
            line: line
        )
        let production = ScannerEngineFactory.makeDefault(rules: makeRules())
        let reference = SwiftScannerEngine(rules: makeRules())

        let fromProduction = try await scan(production, request)
        let fromReference = try await scan(reference, request)

        let productionRows = Set(fromProduction.map(describe))
        let referenceRows = Set(fromReference.map(describe))

        let onlyProduction = productionRows.subtracting(referenceRows).map(\.description).sorted()
        let onlyReference = referenceRows.subtracting(productionRows).map(\.description).sorted()

        XCTAssertEqual(
            onlyProduction, [],
            "the \(production.kind.displayName) found items the Swift core did not: \(onlyProduction.joined(separator: "; "))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            onlyReference, [],
            "the Swift core found items the \(production.kind.displayName) did not: \(onlyReference.joined(separator: "; "))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fromProduction.count, fromReference.count,
            "the two engines reported different numbers of items",
            file: file,
            line: line
        )
    }

    private func describe(_ item: CleanupItemSummary) -> Row {
        // Compared through the product's own normalisation, so the two engines
        // are judged on the item they found and not on how each spells the path
        // to it. `TemporaryDirectory` lives under `/var/folders`, an alias of
        // `/private/var`, and the engines differ on which spelling they report
        // for it — the difference `RuleEngine.normalize` exists to reconcile.
        // Production never meets it: no home directory or granted root is reached
        // through one of the macOS aliases.
        let prefix = RuleEngine.normalize(fixture.url.path)
        let full = RuleEngine.normalize(item.url.path)
        let path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
        return Row(
            path: path,
            displayName: item.displayName,
            category: item.category.rawValue,
            risk: item.risk.rawValue,
            sizeInBytes: item.sizeInBytes,
            fileCount: item.fileCount,
            isDirectory: item.isDirectory,
            explanationKey: item.explanationKey,
            relatedBundleID: item.relatedBundleID
        )
    }

    private func makeRules() -> RuleEngine {
        RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
    }

    private func makeRequest(
        includeHiddenFiles: Bool = true,
        includeDuplicates: Bool = false,
        isCleanable: Bool = true
    ) -> ScanRequest {
        // The home is passed explicitly, and it is the fixture's. The Rust core
        // anchors its rules to `ScanRequest.homeDirectory`; the Swift core
        // anchors them to the `RuleEngine` it was built with, and deliberately
        // ignores the request's. A caller that let the two differ would watch the
        // Rust core find nothing while the Swift one found the fixture — the
        // engines would be scanning different rule sets, not disagreeing about
        // one. `AppEnvironment` builds both from the same `home`, which is what
        // this mirrors.
        ScanRequest(
            homeDirectory: fixture.url,
            roots: [ScanRoot(url: fixture.url, anchor: .home, isCleanable: isCleanable)],
            largeFileThresholdBytes: 1024 * 1024,
            oldFileThresholdDays: 180,
            staleThresholdDays: 30,
            ignoredPaths: [],
            installedBundleIdentifiers: ["com.installed.app"],
            includeHiddenFiles: includeHiddenFiles,
            includeDuplicates: includeDuplicates,
            duplicateRoots: []
        )
    }

    /// Runs one engine to completion and returns everything it found.
    ///
    /// The deadline and the final drain mirror `ScannerTests`: `isFinished` can
    /// flip between the last poll and the completion event, so the collection is
    /// drained once more after the loop.
    private func scan(
        _ engine: any ScannerEngine,
        _ request: ScanRequest
    ) async throws -> [CleanupItemSummary] {
        let session = try await engine.startScan(request)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            _ = await session.pollEvents(maxEvents: 256)
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // The page is the settled answer. The live event stream cannot retract
        // the first row when a later rule replaces the same path at a more
        // cautious risk; both engines' indexes can, and the result page reads
        // the index.
        var items: [CleanupItemSummary] = []
        var offset = 0
        while true {
            let page = try await session.page(
                offset: offset,
                limit: 256,
                sort: .size,
                category: nil
            )
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.remaining == 0 || page.items.isEmpty { break }
        }
        return items
    }

    // MARK: - Fixtures

    /// Everything the two engines have to agree about, in one tree.
    private func writeHazards() {
        // Rule-driven candidates: a cache, two log directories of different ages,
        // and installers past and inside their threshold.
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        fixture.write("Library/Caches/com.other.app/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/.hidden-blob", bytes: 1024)
        fixture.age(fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048), days: 60)
        fixture.write("Library/Logs/com.example.app/new.log", bytes: 1024)
        fixture.age(fixture.write("Downloads/Old.dmg", bytes: 4096), days: 60)
        fixture.write("Downloads/New.dmg", bytes: 4096)

        // Residue: the same five rule-driven locations, the two container
        // directories, a preference file, and one application that is installed.
        fixture.write("Library/Application Support/com.gone.app/data.bin", bytes: 4096)
        fixture.write("Library/Application Support/com.installed.app/data.bin", bytes: 4096)
        fixture.write("Library/Containers/com.gone.app/Data/blob.bin", bytes: 4096)
        fixture.write("Library/Containers/com.installed.app/Data/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/TEAM1.com.gone.app/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/TEAM2.com.installed.app/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/UBF8T346G9.Office/blob.bin", bytes: 4096)
        fixture.write("Library/Saved Application State/com.gone.app/savedState/data.bin", bytes: 4096)
        fixture.write("Library/Preferences/com.gone.app.plist", bytes: 512)
        fixture.write("Library/Preferences/com.installed.app.plist", bytes: 512)

        // A path the protection list refuses, which neither engine may report.
        fixture.write("Documents/taxes.pdf", bytes: 4096)

        // The photo-library suffix is a protection net, not a spelling. A rename
        // that only changes case must be refused by both engines.
        fixture.write("Archive.PHOTOSLIBRARY/db", bytes: 4096)

        // Excluded application data holds a file large enough for the threshold
        // scan. The exclusion belongs to the ancestor, so both engines must skip
        // the subtree rather than only the directory entry.
        fixture.write("Library/Caches/CloudKit/large.bin", bytes: 2 * 1024 * 1024)

        // A symlink pointing out of the tree, which neither engine may follow.
        try? FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent("Library/Caches/link-out"),
            withDestinationURL: fixture.url.appendingPathComponent("Documents")
        )
    }

    // MARK: - Tests

    func test_theTwoEnginesFindTheSameItems() async throws {
        writeHazards()
        try await compare(makeRequest())
    }

    /// The hidden-file preference is a scan scope, so it changes what both
    /// engines produce rather than only what a list shows.
    func test_theTwoEnginesAgreeWhenHiddenFilesAreOutOfScope() async throws {
        writeHazards()
        try await compare(makeRequest(includeHiddenFiles: false))
    }

    /// A measure-only root produces no candidates, in either engine (§9.1).
    func test_aMeasureOnlyRootProducesNothingInEitherEngine() async throws {
        writeHazards()
        let request = makeRequest(isCleanable: false)

        XCTAssertTrue(ScannerEngineFactory.hasRustCore)
        let production = try await scan(ScannerEngineFactory.makeDefault(rules: makeRules()), request)
        let reference = try await scan(SwiftScannerEngine(rules: makeRules()), request)

        XCTAssertTrue(
            production.isEmpty,
            "the Rust core offered \(production.count) candidates for a root the user asked only to measure"
        )
        XCTAssertTrue(
            reference.isEmpty,
            "the Swift core offered \(reference.count) candidates for a measure-only root"
        )
    }

    /// The duplicate pipeline is a second implementation of its own, so it gets
    /// its own comparison: two engines that agree on rules but not on which copy
    /// of a file is the keeper would still show different results.
    func test_theTwoEnginesAgreeOnDuplicateGroups() async throws {
        fixture.writeBytes("Documents/report-copy.pdf", Data(repeating: 0x41, count: 4096))
        fixture.writeBytes("Documents/report-original.pdf", Data(repeating: 0x41, count: 4096))
        fixture.writeBytes("Documents/other-copy.pdf", Data(repeating: 0x42, count: 4096))
        try await compare(makeRequest(includeDuplicates: true))
    }
}
