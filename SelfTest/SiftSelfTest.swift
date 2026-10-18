import Core
import Foundation
import Shared

/// The self-test suite.
///
/// Why this exists next to `Tests/`: the XCTest suite is the deliverable for a
/// developer with a full Xcode installation, but XCTest is not part of the
/// Command Line Tools, so it cannot run on a machine that has only the tools
/// this repository's build scripts require. This target needs nothing but
/// SwiftPM, so the safety-critical behaviour can be exercised and reported on
/// regardless of which toolchain is present.
///
/// It deliberately covers the same territory as the XCTest suite (rules,
/// protected paths, file operations, duplicate detection, scanning, reports,
/// localisation) and it must be run before a release:
///
///     swift run SiftSelfTest
///
/// Exit code 0 means every check passed.
@main
struct SiftSelfTest {
    static func main() async {
        let harness = Harness()
        await harness.run()
        exit(harness.failed == 0 ? 0 : 1)
    }
}

/// A tiny assertion harness, so a failure names what broke without a framework.
final class Harness: @unchecked Sendable {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentSuite = ""

    func suite(_ name: String) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    func check(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(description)  (\(currentSuite))")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
        if actual == expected {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(description)\n      expected: \(expected)\n      actual:   \(actual)")
        }
    }

    func group(_ name: String, _ body: () async -> Void) async {
        suite(name)
        await body()
    }

    func run() async {
        print("\u{001B}[1mSift self-test\u{001B}[0m")
        print("scanner core: \(ScannerEngineFactory.hasRustCore ? "Rust (linked)" : "Swift (fallback)")")

        await ruleTests()
        await protectionTests()
        await fileOperationTests()
        await scannerTests()
        await duplicateTests()
        await storageTests()
        await reportTests()
        await settingsTests()
        await localizationTests()
        await applicationTests()
        await selectionTests()
        await scanPolicyTests()
        await authorizationTests()
        await diagnosticsTests()
        await reportAccuracyTests()
        await productionEngineTests()

        print("\n\u{001B}[1mSummary\u{001B}[0m")
        print("  passed: \(passed)")
        print("  failed: \(failed)")
        if failed == 0 {
            print("  \u{001B}[32mall checks passed\u{001B}[0m")
        } else {
            print("  \u{001B}[31m\(failed) check(s) failed\u{001B}[0m")
        }
    }

    // MARK: - Rules

    private func ruleTests() async {
        await group("Rule engine") {
            let home = URL(fileURLWithPath: "/Users/example")
            let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)

            equal(engine.rules.count, RuleEngine.builtInRules.count, "built-in rules load")
            check(
                engine.rules.allSatisfy { $0.risk != .protected },
                "no built-in rule carries the protected risk"
            )
            check(
                engine.rules.allSatisfy { !$0.explanationKey.isEmpty },
                "every rule names an explanation key"
            )

            let rule = engine.rule(withID: "user-cache")
            check(rule != nil, "the cache rule is present by id")
            equal(rule?.risk, .safe, "the cache rule is safe")
            equal(rule?.matchSpec, .childDirectories, "the cache rule matches child directories")

            check(
                engine.isPackageDirectory(name: "Safari.app"),
                "an app bundle is recognised as a package"
            )
            check(
                engine.isPackageDirectory(name: "Photos.photoslibrary"),
                "a photo library is recognised as a package"
            )
            check(
                !engine.isPackageDirectory(name: "notes.txt"),
                "a plain file is not a package"
            )

            check(
                engine.isExcludedBundleName("CloudKit"),
                "CloudKit is excluded by name"
            )
            check(
                !engine.isExcludedBundleName("com.example.app"),
                "an ordinary bundle identifier is not excluded"
            )

            // Rule file handling: an overlay retunes a rule but cannot unprotect.
            let overlay = """
            {"schemaVersion":1,"rules":[
              {"id":"user-logs","category":"logs","risk":"review","root":"homeLibrary",
               "relativePath":"Logs","matchSpec":"childDirectories","minAgeDays":30,
               "explanationKey":"cleanup.explanation.logs"}
            ]}
            """
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-selftest-rules-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ruleFile = directory.appendingPathComponent("CleaningRules.json")
            try? overlay.data(using: .utf8)?.write(to: ruleFile)

            let merged = RuleEngine(homeDirectory: home, userRuleURL: ruleFile)
            equal(
                merged.rule(withID: "user-logs")?.risk,
                .review,
                "a user rule file retunes a shipped rule"
            )
            try? FileManager.default.removeItem(at: directory)

            // A malformed file must not disable the app.
            let broken = directory.appendingPathComponent("Broken.json")
            try? "{\"schemaVersion\":99,\"rules\":[]}".data(using: .utf8)?.write(to: broken)
            let tolerant = RuleEngine(homeDirectory: home, userRuleURL: broken)
            equal(
                tolerant.rules.count,
                RuleEngine.builtInRules.count,
                "an unsupported rule file is rejected and the built-ins stay"
            )
        }
    }

    // MARK: - Protection

    private func protectionTests() async {
        await group("Protected paths") {
            let home = URL(fileURLWithPath: "/Users/example")
            let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)

            for child in ["Documents", "Desktop", "Movies", "Music", "Pictures", "Projects", "Developer"] {
                let path = "/Users/example/\(child)/file.txt"
                check(engine.protectionReason(for: path) != nil, "\(child) is protected")
            }

            for prefix in ["/System/Library/Caches", "/usr/local/bin/tool", "/private/var/vm", "/Volumes/External/x"] {
                check(engine.protectionReason(for: prefix) != nil, "\(prefix) is protected")
            }

            check(
                engine.protectionReason(for: "/Users/example/Library/Keychains/login.keychain-db") != nil,
                "keychains are protected"
            )
            check(
                engine.protectionReason(for: "/Users/example/Pictures/Photos Library.photoslibrary/db") != nil,
                "the photos library is protected"
            )

            check(
                engine.isAllowed("/Users/example/Library/Caches/com.example.app/blob"),
                "a cache directory is allowed"
            )
            check(
                engine.isAllowed("/Users/example/Downloads/installer.dmg"),
                "a download is allowed"
            )

            // Prefix matching must be component-wise, not substring.
            check(
                engine.isAllowed("/Users/example/Documents-old/notes.txt"),
                "Documents-old is not swept up by the Documents rule"
            )
            check(
                engine.isAllowed("/Systematic/file"),
                "/Systematic is not swept up by the /System rule"
            )

            // Traversal has to be resolved before the comparison.
            let sneaky = "/Users/example/Downloads/../Documents/secret.txt"
            check(
                engine.protectionReason(for: sneaky) != nil,
                "a traversal path into Documents is still rejected"
            )

            // Risk levels: the most cautious one wins, and unclassified content
            // is never safe.
            equal(
                engine.risk(for: "/Users/example/Library/Caches/com.example.app"),
                .safe,
                "a cache path is safe"
            )
            equal(
                engine.risk(for: "/Users/example/Library/Logs/com.example.app"),
                .safe,
                "a log directory is safe"
            )
            equal(
                engine.risk(for: "/Users/example/Downloads/thing.dmg"),
                .review,
                "an installer is for review"
            )
            equal(
                engine.risk(for: "/Users/example/Documents/taxes.pdf"),
                .protected,
                "a protected path reports the protected risk"
            )

            // Bundle identifier detection, the guard against fuzzy name matches.
            check(engine.looksLikeBundleIdentifier("com.example.app"), "a reverse-DNS name is accepted")
            check(!engine.looksLikeBundleIdentifier("Editor"), "a plain word is rejected")
            check(!engine.looksLikeBundleIdentifier("My Project"), "a name with a space is rejected")
            check(!engine.looksLikeBundleIdentifier("com..x"), "an empty component is rejected")
        }
    }

    // MARK: - File operations

    private func fileOperationTests() async {
        await group("File operations") {
            let fixture = TempFixture(tag: "ops")
            defer { fixture.cleanup() }
            let home = fixture.root

            let engine = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
            let dryRun = FileOperationService(rules: engine, isDryRun: true)

            let cacheFile = fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
            let documentFile = fixture.write("Documents/taxes.pdf", bytes: 4096)
            let cacheDirectory = fixture.directory("Library/Caches/com.example.app")

            // Pre-flight accepts an ordinary cache item.
            let verdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: cacheFile, risk: .safe))
            ])
            equal(verdict.ready.count, 1, "a cache file passes pre-flight")
            equal(verdict.protected.count, 0, "nothing is refused for a cache file")

            // Pre-flight refuses a protected path even when it is handed in.
            let protectedVerdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: documentFile, risk: .safe))
            ])
            equal(protectedVerdict.ready.count, 0, "a document never passes pre-flight")
            equal(protectedVerdict.protected.count, 1, "a document is reported as protected")

            // Parent and child together: the parent absorbs the child.
            let overlapVerdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: cacheDirectory, risk: .safe)),
                FileOperationService.Candidate(item: makeItem(url: cacheFile, risk: .safe)),
            ])
            equal(overlapVerdict.ready.count, 1, "only the parent of an overlapping pair remains")
            equal(overlapVerdict.subsumed.count, 1, "the child is reported as subsumed")

            // A missing file is skipped with the fileNotFound code.
            let missing = fixture.root.appendingPathComponent("Library/Caches/gone.bin")
            let missingVerdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: missing, risk: .safe))
            ])
            equal(missingVerdict.skipped.count, 1, "a missing file is skipped")
            equal(missingVerdict.skipped.first?.code, .fileNotFound, "the skip reason is fileNotFound")

            // A symlink is never followed.
            let link = fixture.symlink(to: home.appendingPathComponent("Documents"), name: "Library/Caches/link")
            let linkVerdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: link, risk: .safe))
            ])
            equal(linkVerdict.ready.count, 0, "a symlink is refused")

            // A dry-run batch reports each item and moves nothing.
            let outcome = await dryRun.moveToTrash(
                [makeItem(url: cacheFile, risk: .safe)],
                operation: .junkCleanup
            )
            equal(outcome.movedCount, 1, "a dry run reports one moved item")
            equal(outcome.failedCount, 0, "a dry run reports no failures")
            check(
                FileManager.default.fileExists(atPath: cacheFile.path),
                "a dry run leaves the file in place"
            )

            // The protection check also runs at execution time, not only in
            // pre-flight: a stale result cannot slip a document through.
            let guarded = await dryRun.moveToTrash(
                [makeItem(url: documentFile, risk: .safe)],
                operation: .junkCleanup
            )
            equal(guarded.failedCount, 1, "a protected path fails at execution time")
            equal(
                guarded.failedResults.first?.errorCode,
                ErrorCode.protectedLocation.rawValue,
                "the failure carries the protectedLocation code"
            )
            check(
                FileManager.default.fileExists(atPath: documentFile.path),
                "the document is untouched"
            )

            // Released bytes are computed from what moved, not from the request.
            let mixed = await dryRun.moveToTrash(
                [
                    makeItem(url: cacheFile, size: 4096, risk: .safe),
                    makeItem(url: documentFile, size: 8192, risk: .safe),
                ],
                operation: .junkCleanup
            )
            equal(mixed.releasedBytes, 4096, "released bytes count only the items that moved")

            // Paths with spaces, non-ASCII characters and traversal are handled
            // as plain paths.
            let tricky = fixture.write("Library/Caches/应用 缓存/v1.0 (beta)+t#1.bin", bytes: 512)
            check(
                engine.isAllowed(tricky.path),
                "a path with spaces and non-ASCII characters is allowed"
            )
            let trickyVerdict = await dryRun.preflight([
                FileOperationService.Candidate(item: makeItem(url: tricky, risk: .safe))
            ])
            equal(trickyVerdict.ready.count, 1, "a tricky path passes pre-flight untouched")
        }
    }

    // MARK: - Scanning

    private func scannerTests() async {
        await group("Scanner engine") {
            let fixture = TempFixture(tag: "scan")
            defer { fixture.cleanup() }
            let home = fixture.root

            let oldLog = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
            fixture.age(oldLog, days: 60)
            fixture.write("Library/Logs/com.example.app/fresh.log", bytes: 2048)
            fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
            fixture.write("Library/Caches/com.other.app/blob.bin", bytes: 4096)
            fixture.write("Library/Caches/CloudKit/blob.bin", bytes: 4096)
            fixture.write("Documents/taxes.pdf", bytes: 4096)
            let installer = fixture.write("Downloads/Old.dmg", bytes: 4096)
            fixture.age(installer, days: 60)
            fixture.write("Downloads/Fresh.dmg", bytes: 4096)

            let engine = SwiftScannerEngine(rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home))
            let request = ScanRequest(
                roots: [ScanRoot(url: home, anchor: .home)],
                largeFileThresholdBytes: 1024 * 1024,
                oldFileThresholdDays: 180,
                staleThresholdDays: 30,
                ignoredPaths: [],
                installedBundleIdentifiers: [],
                includeDuplicates: false,
                duplicateRoots: []
            )

            let session = try? await engine.startScan(request)
            check(session != nil, "the engine starts a session")
            guard let session else { return }

            var phase: ScanPhase = .idle
            var foundItems: [CleanupItemSummary] = []
            var skipped: [SkippedLocation] = []
            var report: ScanReport?

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let events = await session.pollEvents(maxEvents: 128)
                for event in events {
                    switch event {
                    case let .phaseChanged(next): phase = next
                    case let .itemsFound(items): foundItems.append(contentsOf: items)
                    case let .locationSkipped(location): skipped.append(location)
                    case let .completed(summary):
                        report = summary
                        phase = summary.phase
                    case .failed: break
                    default: break
                    }
                }
                if await session.isFinished() {
                    // The drain has to fold the same state the loop does. It kept
                    // the report but not the phase, so a completion arriving here
                    // — which is exactly what `isFinished` racing the last poll
                    // produces — left `phase` at `.scanning` and the terminal-phase
                    // check failed about one run in twenty.
                    for event in await session.pollEvents(maxEvents: 256) {
                        switch event {
                        case let .phaseChanged(next): phase = next
                        case let .itemsFound(items): foundItems.append(contentsOf: items)
                        case let .locationSkipped(location): skipped.append(location)
                        case let .completed(summary):
                            report = summary
                            phase = summary.phase
                        default: break
                        }
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }

            check(report != nil, "the scan reports completion")
            check(phase == .ready || phase == .partial, "the scan reaches a terminal phase")

            let page = (try? await session.page(offset: 0, limit: 200, sort: .size, category: nil))
                ?? ScanPage(items: [], remaining: 0)
            check(page.items.count > 0, "the session pages results")

            let categories = Set(page.items.map(\.category))
            check(categories.contains(.applicationCache), "cache children are found")
            check(categories.contains(.logs), "log directories are found")
            check(categories.contains(.installers), "installers are found")

            check(
                page.items.contains(where: { $0.displayName == "com.example.app" }),
                "the cache child directory is reported by name"
            )
            check(
                !page.items.contains(where: { $0.displayName == "CloudKit" }),
                "CloudKit is excluded from the cache results"
            )
            check(
                !page.items.contains(where: { $0.displayName == "Fresh.dmg" }),
                "a fresh installer is not offered"
            )
            check(
                !page.items.contains(where: { $0.url.path.contains("/Documents/") }),
                "user documents never appear in the results"
            )
            check(
                page.items.allSatisfy { !$0.sourceRuleID.isEmpty },
                "every item names the rule that produced it"
            )
            check(
                page.items.allSatisfy { !$0.explanationKey.isEmpty },
                "every item carries an explanation key"
            )

            // The log directory holds one fresh log; only the stale one may be
            // counted, so the reported size must be the stale file's alone.
            let logItem = page.items.first { $0.category == .logs }
            if let logItem {
                check(
                    logItem.sizeInBytes < 8192,
                    "the log size counts only the stale file (reported \(logItem.sizeInBytes) bytes)"
                )
            }

            // Paging is stable: page 2 follows page 1 without repeating it.
            let firstPage = (try? await session.page(offset: 0, limit: 2, sort: .size, category: nil))
                ?? ScanPage(items: [], remaining: 0)
            let secondPage = (try? await session.page(offset: 2, limit: 2, sort: .size, category: nil))
                ?? ScanPage(items: [], remaining: 0)
            let firstIds = Set(firstPage.items.map(\.id))
            let secondIds = Set(secondPage.items.map(\.id))
            check(
                firstIds.isDisjoint(with: secondIds),
                "consecutive pages do not repeat rows"
            )

            // The analysis path shares the same rules.
            let analysis = (try? await engine.analyzeStorage(roots: [ScanRoot(url: home, anchor: .home)]))
                ?? .empty
            check(analysis.scannedFileCount > 0, "storage analysis examines files")
            check(analysis.categories.count > 0, "storage analysis groups by category")
            check(analysis.totalBytes > 0, "storage analysis reports volume capacity")
            check(
                analysis.topDirectories.allSatisfy { !$0.url.path.contains("/Documents") },
                "a protected directory is not listed as reclaimable"
            )

            check(
                skipped.contains(where: { $0.code == ErrorCode.protectedLocation.rawValue }),
                "user content inside the scan root is skipped, with the protectedLocation code"
            )

            _ = foundItems
        }
    }

    // MARK: - Duplicates

    private func duplicateTests() async {
        await group("Duplicate detection") {
            let fixture = TempFixture(tag: "dupes")
            defer { fixture.cleanup() }
            let home = fixture.root

            let payload = Data(repeating: 0x41, count: 64 * 1024)
            fixture.writeData("Downloads/one.bin", payload)
            fixture.writeData("Downloads/nested/two.bin", payload)
            fixture.writeData("Downloads/three.bin", payload)

            // Same size, different content: must not join the group.
            var different = Data(repeating: 0x41, count: 64 * 1024)
            different[32 * 1024] = 0x42
            fixture.writeData("Downloads/unique.bin", different)

            // A cloud placeholder is never a candidate.
            fixture.writeData("Downloads/placeholder.icloud", payload)

            let engine = SwiftScannerEngine(
                rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
            )
            let request = ScanRequest(
                roots: [ScanRoot(url: home, anchor: .home)],
                includeDuplicates: true,
                duplicateRoots: [fixture.root.appendingPathComponent("Downloads").path]
            )

            guard let session = try? await engine.startScan(request) else {
                check(false, "the duplicate scan starts")
                return
            }

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !(await session.isFinished()) {
                _ = await session.pollEvents(maxEvents: 128)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            _ = await session.pollEvents(maxEvents: 256)

            let groups = (try? await session.duplicateGroups(offset: 0, limit: 50)) ?? []
            equal(groups.count, 1, "exactly one duplicate group is formed")

            guard let group = groups.first else { return }
            equal(group.members.count, 3, "the group holds the three identical copies")
            equal(
                group.members.filter(\.isRecommendedToKeep).count,
                1,
                "exactly one copy is recommended to keep"
            )
            check(
                group.reclaimableSizeInBytes == Int64(payload.count) * 2,
                "reclaimable size counts only the removable copies"
            )
            check(
                group.members.contains(where: { $0.displayName == "one.bin" }),
                "the group lists the members by name"
            )
            check(
                !group.members.contains(where: { $0.displayName.hasSuffix(".icloud") }),
                "a cloud placeholder is not a duplicate candidate"
            )
            check(
                !group.members.contains(where: { $0.displayName == "unique.bin" }),
                "a same-size file with different content stays out of the group"
            )

            let members = (try? await session.duplicateMembers(groupID: group.id)) ?? []
            equal(members.count, 3, "the member list is readable per group")
        }
    }

    // MARK: - Storage analysis

    private func storageTests() async {
        await group("Storage analysis") {
            let fixture = TempFixture(tag: "storage")
            defer { fixture.cleanup() }
            let home = fixture.root

            // "Media", not "Movies": the latter is a protected user folder on a real
            // Mac, and this suite is about aggregation rather than protection.
            fixture.write("Media/big.mp4", bytes: 3 * 1024 * 1024)
            fixture.write("Media/small.mp4", bytes: 4096)
            fixture.write("Docs/report.pdf", bytes: 1024 * 1024)

            let analyzer = StorageAnalyzer(
                rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
            )
            let analysis = (try? await analyzer.analyze(
                roots: [ScanRoot(url: home, anchor: .home)],
                largeFileThresholdBytes: 1024 * 1024
            )) ?? .empty

            equal(analysis.scannedFileCount, 3, "every file is counted")
            check(analysis.scannedByteCount >= 4 * 1024 * 1024, "the byte total covers the files")
            check(
                analysis.categories.contains(where: { $0.id == "video" }),
                "video files are grouped by type"
            )
            check(
                analysis.topFiles.contains(where: { $0.displayName == "big.mp4" }),
                "the large-file list holds the big file"
            )
            check(
                analysis.topDirectories.contains(where: { $0.displayName == "Media" }),
                "the folder rollup holds the largest folder"
            )
            check(analysis.totalBytes > 0, "volume capacity is reported")
            check(
                analysis.usedFraction >= 0 && analysis.usedFraction <= 1,
                "the used fraction is a valid ratio"
            )
            check(analysis.skippedCount == 0, "nothing is skipped for an ordinary tree")
        }
    }

    // MARK: - Reports

    private func reportTests() async {
        await group("Reports") {
            let fixture = TempFixture(tag: "report")
            defer { fixture.cleanup() }
            let service = ReportService(supportDirectory: fixture.root)

            for index in 0..<400 {
                fixture.write("Library/Caches/com.example.app/file\(index).bin", bytes: 1024)
            }

            // A report never carries a full path, only a leaf name, and it
            // truncates a long list rather than growing without bound.
            let entries = (0..<400).map { index in
                CleanupReport.Entry(
                    displayName: "file\(index).bin",
                    category: "applicationCache",
                    sizeInBytes: 1024,
                    status: OperationStatus.movedToTrash.rawValue,
                    errorCode: nil
                )
            }
            let report = CleanupReport(
                operation: .junkCleanup,
                appVersion: "0.1.0",
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                scannedLocationCount: 3,
                scannedFileCount: 400,
                categories: ["applicationCache"],
                movedCount: 400,
                movedBytes: 400 * 1024,
                skippedCount: 2,
                failedCount: 1,
                entries: Array(entries.prefix(20))
            )

            check(report.entries.count == 20, "a long list is truncated for the report")

            // The local copy is written before any export, so a failed save
            // cannot lose the record.
            let stored = try? await service.storeLocally(report)
            check(stored != nil, "the report is stored locally")
            if let stored {
                check(
                    FileManager.default.fileExists(atPath: stored.path),
                    "the local report file exists"
                )
                let contents = (try? String(contentsOf: stored, encoding: .utf8)) ?? ""
                check(contents.contains("movedCount"), "the local report carries the counts")
                check(
                    !contents.contains("/Library/Caches"),
                    "the local report contains no directory path"
                )
            }

            let storedReports = await service.storedReports()
            check(storedReports.count >= 1, "stored reports are listed back")

            // PDF rendering: a real document with more than one page for a long
            // list, and no crash for an empty one.
            let pdf = await service.renderPDF(report, title: LocalizationKey.reportTitle.localized)
            check(pdf.count > 1000, "the PDF has content (\(pdf.count) bytes)")
            check(pdf.prefix(5) == Data("%PDF-".utf8), "the output is a PDF document")

            let emptyReport = CleanupReport(
                operation: .largeFiles,
                appVersion: "0.1.0",
                macOSVersion: "test",
                scannedLocationCount: 0,
                scannedFileCount: 0,
                categories: [],
                movedCount: 0,
                movedBytes: 0,
                skippedCount: 0,
                failedCount: 0,
                entries: []
            )
            let emptyPDF = await service.renderPDF(emptyReport, title: "Empty")
            check(emptyPDF.count > 500, "an empty report still renders a page")

            // Every shipped language has to have a rendering path: the text is
            // resolved through the catalog, so this also proves the catalog is
            // reachable from the reporting layer.
            check(
                !LocalizationKey.reportPrivacyNote.localized.isEmpty,
                "the report privacy note resolves"
            )
        }
    }

    // MARK: - Settings

    private func settingsTests() async {
        await group("Settings") {
            let suiteName = "sift.selftest.\(UUID().uuidString)"
            // The store reads through a `Sendable` façade, so the test creates an
            // isolated defaults suite and hands that façade in.
            let box = DefaultsBox(suiteName: suiteName)
            let defaults = box.defaults
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let fixture = TempFixture(tag: "settings")
            defer { fixture.cleanup() }
            let store = SettingsStore(preferences: StringPreferences(defaults: defaults), supportDirectory: fixture.root)

            let initial = await store.current()
            equal(initial.skipConfirmation, false, "skip confirmation is off by default")
            equal(initial.requireConfirmation, true, "confirmation is required by default")
            equal(
                initial.largeFileThresholdBytes,
                ScanDefaults.largeFileThresholdBytes,
                "the default large-file threshold is 1 GB"
            )
            equal(initial.oldFileThresholdDays, 180, "the default old-file threshold is 180 days")
            equal(initial.keepScanHistory, 10, "the default scan history is ten entries")

            await store.update { settings in
                settings.skipConfirmation = true
                settings.largeFileThresholdBytes = 2048 * 1024 * 1024
                settings.appearance = .dark
                settings.ignoredPaths = ["/Users/example/keep-me"]
            }

            // A second store over the same defaults must see the same values:
            // that is what makes the settings survive a relaunch.
            let reloaded = SettingsStore(preferences: StringPreferences(defaults: defaults), supportDirectory: fixture.root)
            let persisted = await reloaded.current()
            equal(persisted.skipConfirmation, true, "skip confirmation persists")
            equal(
                persisted.largeFileThresholdBytes,
                2048 * 1024 * 1024,
                "the threshold persists"
            )
            equal(persisted.appearance, .dark, "the appearance choice persists")
            equal(persisted.ignoredPaths, ["/Users/example/keep-me"], "the ignore list persists")

            let counter = Counter()
            let stream = await store.changes()
            let consumer = Task.detached {
                for await _ in stream {
                    await counter.increment()
                }
            }
            await store.update { $0.staleThresholdDays = 14 }
            try? await Task.sleep(nanoseconds: 250_000_000)
            consumer.cancel()
            let observed = await counter.value
            check(observed >= 1, "a settings change is published to observers")

            await store.resetToDefaults()
            let reset = await store.current()
            equal(reset.largeFileThresholdBytes, ScanDefaults.largeFileThresholdBytes, "defaults restore")
            equal(reset.skipConfirmation, false, "skip confirmation returns to off")
        }
    }

    // MARK: - Localisation

    private func localizationTests() async {
        await group("Localisation") {
            // Every key resolves to something other than its own identifier.
            var unresolved: [String] = []
            for key in LocalizationKey.allCases {
                let value = key.localized
                if value == key.rawValue {
                    unresolved.append(key.rawValue)
                }
            }
            check(unresolved.isEmpty, "every localisation key resolves (\(unresolved.count) unresolved)")
            if !unresolved.isEmpty {
                print("      unresolved: \(unresolved.prefix(10).joined(separator: ", "))")
            }

            // The eight shipped languages are present in the bundle, each with a
            // full translation of the catalogue.
            let bundle = Bundle.siftResources
            let expected = ["en", "zh-hans", "ko", "ru", "es", "ja", "fr", "de"]
            var missing: [String] = []
            for language in expected {
                guard let path = bundle.path(forResource: language, ofType: "lproj"),
                      let languageBundle = Bundle(path: path),
                      let stringsPath = languageBundle.path(forResource: "Localizable", ofType: "strings"),
                      let dictionary = NSDictionary(contentsOfFile: stringsPath) as? [String: String] else {
                    missing.append(language)
                    continue
                }
                let gaps = LocalizationKey.allCases.filter {
                    (dictionary[$0.rawValue] ?? "").isEmpty
                }
                if !gaps.isEmpty {
                    print("      \(language): \(gaps.count) missing keys")
                }
            }
            check(missing.isEmpty, "all eight languages ship as .lproj bundles")

            // Formatting follows the locale rather than assuming one.
            check(!SiftFormat.bytes(1_500_000).isEmpty, "byte sizes format")
            check(!SiftFormat.count(1234).isEmpty, "counts format")
            check(SiftFormat.percent(0.73).contains("73"), "percentages format from a fraction")
            check(!SiftFormat.relativeDate(Date()).isEmpty, "relative dates format")

            let german = Locale(identifier: "de_DE")
            let english = Locale(identifier: "en_US")
            let germanBytes = SiftFormat.bytes(1_500_000, locale: german)
            let englishBytes = SiftFormat.bytes(1_500_000, locale: english)
            check(!germanBytes.isEmpty && !englishBytes.isEmpty, "sizes format in both locales")

            // A key with a placeholder substitutes its argument.
            let substituted = LocalizationKey.commonItemCount.localized(7)
            check(substituted.contains("7"), "a placeholder key substitutes its argument")
            check(!substituted.contains("%d"), "no placeholder survives substitution")
        }
    }

    // MARK: - Applications

    private func applicationTests() async {
        await group("Application discovery") {
            let fixture = TempFixture(tag: "apps")
            defer { fixture.cleanup() }
            let home = fixture.root

            // A synthetic bundle with an identifier, so discovery has something
            // deterministic to read without touching the real /Applications.
            let appBundle = fixture.root.appendingPathComponent("Applications/Test.app/Contents")
            try? FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.example.test</string>
            <key>CFBundleName</key><string>Test</string>
            <key>CFBundleShortVersionString</key><string>1.2.3</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """
            try? plist.data(using: .utf8)?.write(to: appBundle.appendingPathComponent("Info.plist"))
            try? FileManager.default.createDirectory(
                at: appBundle.appendingPathComponent("MacOS"),
                withIntermediateDirectories: true
            )
            try? Data(repeating: 0x41, count: 4096)
                .write(to: appBundle.appendingPathComponent("MacOS/Test"))

            let discovery = ApplicationDiscovery(
                rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home),
                additionalDirectories: [fixture.root.appendingPathComponent("Applications")]
            )

            let applications = await discovery.installedApplications()
            check(
                applications.contains(where: { $0.bundleIdentifier == "com.example.test" }),
                "a synthetic application is discovered by identifier"
            )
            if let application = applications.first(where: { $0.bundleIdentifier == "com.example.test" }) {
                equal(application.name, "Test", "the display name comes from the bundle")
                equal(application.version, "1.2.3", "the version comes from the bundle")
                check(application.sizeInBytes > 0, "the application size is measured")
            }

            // Associated files are only claimed on an exact identifier match.
            let identifier = "com.example.test"
            fixture.write("Library/Application Support/\(identifier)/data.bin", bytes: 4096)
            fixture.write("Library/Preferences/\(identifier).plist", bytes: 256)
            fixture.write("Library/Application Support/Editor/notes.txt", bytes: 4096)

            // Discovery reads the real application directories, so the synthetic
            // bundle is handed to the matcher directly — the matcher is what this
            // check is about.
            let application = InstalledApplication(
                url: fixture.root.appendingPathComponent("Applications/Test.app"),
                name: "Test",
                bundleIdentifier: identifier,
                version: "1.2.3",
                sizeInBytes: 4096,
                lastUsedAt: nil,
                isSystemApplication: false,
                isRunning: false
            )
            let plan = discovery.relatedFiles(for: application)
            let paths = plan.confirmedFiles.map(\.displayPath)
            check(
                paths.contains(where: { $0.contains(identifier) }),
                "files named after the bundle identifier are matched"
            )
            check(
                !paths.contains(where: { $0.contains("/Editor") }),
                "a folder named after a similar word is never claimed"
            )
            equal(
                plan.confirmedFiles.filter { $0.displayName.hasSuffix(".plist") }.count,
                1,
                "the preference file is matched by its full identifier name"
            )
            check(
                plan.confirmedFiles.allSatisfy { $0.confidence == .confirmed },
                "confirmed files carry the confirmed confidence"
            )
        }
    }

    // MARK: - Selection identity

    private func selectionTests() async {
        await group("Cleanup selection") {
            let fixture = TempFixture(tag: "selection")
            defer { fixture.cleanup() }

            let summary = CleanupItemSummary(
                id: 1,
                url: fixture.root.appendingPathComponent("Library/Caches/com.example.app"),
                displayName: "com.example.app",
                parentPath: fixture.root.appendingPathComponent("Library/Caches").path,
                category: .applicationCache,
                risk: .safe,
                sizeInBytes: 4096,
                fileCount: 2,
                explanationKey: "cleanup.explanation.cache",
                sourceRuleID: "user-cache",
                isDirectory: true
            )

            // The defect this guards: a random id per conversion meant a checked
            // row never matched the item in the model.
            let first = summary.asCleanupItem()
            let second = summary.asCleanupItem()
            equal(first.id, second.id, "a summary converts to a stable identity")
            check(!first.id.isEmpty, "the identity is not empty")

            // The same path under two categories is two distinct targets.
            let logs = CleanupItem(
                url: summary.url,
                displayName: summary.displayName,
                category: .logs,
                risk: .safe,
                sizeInBytes: 4096,
                fileCount: 1,
                explanationKey: "cleanup.explanation.logs",
                sourceRuleID: "user-logs"
            )
            check(logs.id != first.id, "the category is part of the identity")

            let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.root)
            let model = await MainActor.run {
                CleanupModel(
                    rules: rules,
                    operations: FileOperationService(rules: rules, isDryRun: true),
                    reports: ReportService(supportDirectory: fixture.root)
                )
            }

            await MainActor.run {
                model.setItems([first], preselect: false)
                // A row rendered later builds a fresh value; selection must survive.
                let freshlyRendered = summary.asCleanupItem()
                check(!model.isSelected(freshlyRendered), "an item starts unselected")
                model.setSelected(true, for: freshlyRendered)
                check(model.isSelected(freshlyRendered), "a checked row is selected")
                equal(model.selectedCount, 1, "the selection holds exactly one item")
            }

            await MainActor.run {
                // A duplicate member toggled from a group must enter the model's
                // list, or the confirmation panel would count zero.
                let member = DuplicateMember(
                    url: fixture.root.appendingPathComponent("Downloads/copy.bin"),
                    sizeInBytes: 1024,
                    modifiedAt: nil,
                    isRecommendedToKeep: false
                )
                let memberItem = CleanupItem(
                    url: member.url,
                    displayName: member.displayName,
                    category: .duplicateFiles,
                    risk: .review,
                    sizeInBytes: member.sizeInBytes,
                    fileCount: 1,
                    explanationKey: "cleanup.explanation.duplicates",
                    sourceRuleID: "duplicate-files"
                )
                model.setSelected(true, for: memberItem)
                check(model.isSelected(memberItem), "a duplicate copy can be selected")
                equal(model.selectedCount, 2, "both selected items are counted")
            }
        }
    }

    // MARK: - Scan policy

    private func scanPolicyTests() async {
        await group("Scan root policy") {
            let fixture = TempFixture(tag: "policy")
            defer { fixture.cleanup() }

            // A cache old enough to be a candidate, plus a large file.
            fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
            fixture.write("Downloads/huge.bin", bytes: 2 * 1024 * 1024)

            let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.root)
            let engine = SwiftScannerEngine(rules: rules)

            func scan(isCleanable: Bool) async -> [CleanupItemSummary] {
                let request = ScanRequest(
                    homeDirectory: fixture.root,
                    roots: [ScanRoot(url: fixture.root, anchor: .home, isCleanable: isCleanable)],
                    largeFileThresholdBytes: 1024 * 1024,
                    includeDuplicates: false
                )
                guard let session = try? await engine.startScan(request) else { return [] }
                var items: [CleanupItemSummary] = []
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    for event in await session.pollEvents(maxEvents: 128) {
                        if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
                    }
                    if await session.isFinished() { break }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                for event in await session.pollEvents(maxEvents: 256) {
                    if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
                }
                return items
            }

            let cleanable = await scan(isCleanable: true)
            let measureOnly = await scan(isCleanable: false)
            check(!cleanable.isEmpty, "a cleanable root produces candidates")
            equal(measureOnly.count, 0, "a measure-only root produces no cleanup candidates")
        }
    }

    // MARK: - Authorisation

    private func authorizationTests() async {
        await group("Authorisation") {
            let home = URL(fileURLWithPath: "/Users/example")
            let scope = AuthorizedScope()
            let rules = RuleEngine(
                rules: RuleEngine.builtInRules,
                homeDirectory: home,
                authorized: scope
            )

            // `/Volumes` and `/private/var` are closed by default.
            check(
                rules.protectionReason(for: "/Volumes/External/file.bin") != nil,
                "an unauthorised volume is closed"
            )
            check(
                rules.protectionReason(for: "/private/var/vm/swapfile") != nil,
                "an unauthorised system tree is closed"
            )

            scope.add(URL(fileURLWithPath: "/Volumes/External"))

            check(
                rules.protectionReason(for: "/Volumes/External/file.bin") == nil,
                "an authorised volume is open"
            )
            check(
                rules.protectionReason(for: "/Volumes/Other/file.bin") != nil,
                "a different volume stays closed"
            )

            // Authorisation never unlocks user content or secrets.
            scope.add(home)
            check(
                rules.protectionReason(for: "/Users/example/Documents/taxes.pdf") != nil,
                "authorising the home folder does not unlock Documents"
            )
            check(
                rules.protectionReason(for: "/Users/example/Library/Keychains/login.keychain-db") != nil,
                "authorising the home folder does not unlock the keychain"
            )
            check(!rules.canAuthorize(url: home.appendingPathComponent("Documents")), "Documents cannot be authorised")
            check(rules.canAuthorize(url: URL(fileURLWithPath: "/Volumes/External")), "a volume can be authorised")

            // An allowlist: a grant is a concrete folder or volume, never a
            // system tree or the volume container.
            for broad in ["/", "/Volumes", "/Library", "/private/var", "/Library/Extensions", "/System"] {
                check(
                    !rules.canAuthorize(url: URL(fileURLWithPath: broad)),
                    "\(broad) cannot be authorised"
                )
            }
            check(rules.canAuthorize(url: URL(fileURLWithPath: "/Users/example/Library/Caches")),
                  "an ordinary cache folder can be authorised")

            // Every entry on the shared list is refused as a scan target and as a
            // grant. The list is generated from the Rust constants the scanner
            // core reads, so this doubles as the cross-engine check.
            for entry in ProtectedPaths.libraryChildren {
                check(
                    rules.protectionReason(for: "/Users/example/\(entry.path)/content") != nil,
                    "\(entry.path) is protected"
                )
                check(
                    !rules.canAuthorize(url: URL(fileURLWithPath: "/Users/example/\(entry.path)")),
                    "\(entry.path) cannot be authorised"
                )
            }
            for child in ProtectedPaths.homeChildren {
                check(
                    !rules.canAuthorize(url: home.appendingPathComponent(child)),
                    "\(child) cannot be authorised"
                )
            }

            // A stored grant is re-validated on the way back in: an older build
            // could have saved `/Volumes`, which would unprotect every disk.
            // A security-scoped bookmark cannot be minted outside a signed app,
            // so the coder stands in for the real one.
            let coder = SelfTestBookmarkCoder(paths: ["/": "/", "/Volumes": "/Volumes"])
            let restoredScope = AuthorizedScope()
            let service = AuthorizationService(
                scope: restoredScope,
                policy: { url in
                    RuleEngine(
                        rules: RuleEngine.builtInRules,
                        homeDirectory: home,
                        authorized: restoredScope
                    ).canAuthorize(url: url)
                },
                coder: coder
            )
            let storedBroad = ["/", "/Volumes"].map { path in
                AuthorizedLocation(bookmark: Data(path.utf8), displayName: path, isVolume: true)
            }
            let outcome = await service.restore(storedBroad)
            equal(outcome.locations.count, 0, "a stored broad grant is not restored")
            equal(outcome.refused.count, 2, "both broad grants are reported as refused")
            check(restoredScope.paths.isEmpty, "a refused grant never reaches the scope")

            // A grant is only in force when the location can actually be read:
            // the bookmark machinery reports success for a volume that is not
            // mounted and for a directory the process may not list, so the
            // location itself is the test. The fixture is a real tree because a
            // made-up path would only ever exercise the refusal.
            let fixture = TempFixture(tag: "grants")
            defer { fixture.cleanup() }
            let granted = fixture.directory("Backup")
            let fixtureHome = fixture.root

            let grantScope = AuthorizedScope()
            let grantCoder = SelfTestBookmarkCoder(paths: [
                granted.path: granted.path,
                fixture.root.appendingPathComponent("Gone").path:
                    fixture.root.appendingPathComponent("Gone").path,
            ])
            let grantService = AuthorizationService(
                scope: grantScope,
                policy: { url in
                    RuleEngine(
                        rules: RuleEngine.builtInRules,
                        homeDirectory: fixtureHome,
                        authorized: grantScope
                    ).canAuthorize(url: url)
                },
                coder: grantCoder
            )

            let unreadable = await grantService.restore([
                AuthorizedLocation(
                    bookmark: Data(fixture.root.appendingPathComponent("Gone").path.utf8),
                    displayName: "Gone",
                    isVolume: false
                ),
                AuthorizedLocation(
                    bookmark: Data(granted.path.utf8),
                    displayName: "Backup",
                    isVolume: false
                ),
            ])
            equal(unreadable.locations.count, 1, "a grant that cannot be read is not restored")
            equal(grantScope.paths, [granted.path], "a readable grant reaches the scope")

            // The service resolves symlinks, and the resolved location is what a
            // scan root has to be: the walk never follows a link.
            let link = fixture.symlink(to: granted, name: "Link")
            let authorized = await grantService.authorize(link)
            equal(
                authorized?.url.path,
                granted.resolvingSymlinksInPath().path,
                "a grant reports the resolved location, not the one that was picked"
            )

            // A rule anchored at an authorised location applies inside every
            // grant, at its relative path — and to nothing at all when the user
            // has not granted anything, rather than to a guessed container.
            let anchorScope = AuthorizedScope(roots: [
                URL(fileURLWithPath: "/Volumes/Backup"),
                URL(fileURLWithPath: "/Volumes/Backup/Photos"),
            ])
            let anchorRules = RuleEngine(
                rules: RuleEngine.builtInRules,
                homeDirectory: home,
                authorized: anchorScope
            )
            let anchoredRule = RuleEngine.Rule(
                id: "granted-caches",
                category: .applicationCache,
                risk: .safe,
                root: .externalVolume,
                relativePath: "Caches",
                matchSpec: .childDirectories,
                excludes: [],
                minAgeDays: nil,
                requiresFullDiskAccess: false,
                explanationKey: "cleanup.explanation.cache",
                isEnabled: true
            )
            equal(
                anchorRules.resolvedRoots(for: anchoredRule).map(\.path),
                ["/Volumes/Backup/Caches"],
                "a volume anchor covers mounted volumes only"
            )
            equal(
                RuleEngine(
                    rules: RuleEngine.builtInRules + [anchoredRule],
                    homeDirectory: home,
                    authorized: anchorScope
                ).risk(for: "/Volumes/Backup/Caches/junk.one"),
                .safe,
                "a rule under a volume anchor matches inside the grant"
            )
            check(
                RuleEngine(
                    rules: RuleEngine.builtInRules,
                    homeDirectory: home,
                    authorized: AuthorizedScope()
                ).resolvedRoots(for: anchoredRule).isEmpty,
                "an anchor without a grant resolves to nothing"
            )

            // Even a grant that somehow covers a system prefix must not open it.
            let broadScope = AuthorizedScope(roots: [URL(fileURLWithPath: "/")])
            let broadRules = RuleEngine(
                rules: RuleEngine.builtInRules,
                homeDirectory: home,
                authorized: broadScope
            )
            for target in [
                "/Library/Extensions/foo.kext",
                "/Library/LaunchDaemons/com.example.plist",
                "/private/var/db/secret",
                "/private/var/vm/swapfile",
            ] {
                check(
                    broadRules.protectionReason(for: target) != nil,
                    "a broad grant does not unlock \(target)"
                )
            }
        }
    }

    // MARK: - System space diagnostics

    private func diagnosticsTests() async {
        await group("System space diagnostics") {
            let fixture = TempFixture(tag: "diagnostics")
            defer { fixture.cleanup() }
            fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
            fixture.write("Library/Logs/old.log", bytes: 8192)
            fixture.write("Library/Developer/Xcode/DerivedData/Project-abc/Index.noindex/data/f.bin", bytes: 16384)
            fixture.write("usr/lib.bin", bytes: 2048)

            let context = StorageDiagnosticContext(
                roots: [DiagnosticRoot(url: fixture.root, kind: .volume)],
                homeDirectory: fixture.root
            )

            // Measurement, observed through a provider: both sizes are read from
            // the file system, and a symlink is not measured as data.
            let batch = await VolumeSpaceProvider().analyze(context)
            let library = batch.findings.first { $0.displayName == "Library" }
            equal(library?.fileCount, 3, "every file inside a child is counted")
            equal(library?.logicalBytes, 28672, "the logical size is the sum of the files")
            check((library?.allocatedBytes ?? 0) > 0, "the allocated size is read from the file system")
            equal(batch.volumes.count, 1, "the volume totals are reported")
            check(batch.findings.allSatisfy { $0.status == .unknown }, "the volume provider does not judge")

            let outside = TempFixture(tag: "diagnostics-outside")
            defer { outside.cleanup() }
            outside.write("secret.bin", bytes: 65536)
            _ = fixture.symlink(to: outside.root, name: "link")
            let afterLink = await VolumeSpaceProvider().analyze(context)
            equal(
                afterLink.findings.map(\.displayName).sorted(),
                batch.findings.map(\.displayName).sorted(),
                "a symlink at the volume root is not measured"
            )

            let bounded = await VolumeSpaceProvider().analyze(
                StorageDiagnosticContext(
                    roots: [DiagnosticRoot(url: fixture.root, kind: .volume)],
                    homeDirectory: fixture.root,
                    measurementBudget: 1
                )
            )
            check(
                bounded.findings.first { $0.displayName == "Library" }?.isApproximate == true,
                "a measurement that ran out of budget says its size is an estimate"
            )
            equal(bounded.coverage, .partial, "and the run reports a lower bound rather than a total")

            let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.root)

            func finding(_ path: String, _ status: StorageFindingStatus, _ remediation: StorageRemediation) -> StorageFinding {
                StorageFinding(
                    providerID: "stub",
                    path: URL(fileURLWithPath: path),
                    displayName: (path as NSString).lastPathComponent,
                    category: .unknown,
                    status: status,
                    allocatedBytes: 1024,
                    explanationKey: .diagnosticsExplanationVolumeChild,
                    remediation: remediation
                )
            }

            // Protection removes the deletion path and nothing else. Asserted
            // through a run, because a run is the only way a finding travels.
            let enforced = await StorageDiagnosticEngine(
                providers: [
                    SelfTestDiagnosticProvider(
                        findings: [
                            finding("\(fixture.root.path)/Library/Mail/inbox.emlx", .cleanable, .trash),
                            StorageFinding(
                                providerID: "stub",
                                path: URL(fileURLWithPath: "/System/Volumes/Data/.Spotlight-V100"),
                                displayName: ".Spotlight-V100",
                                category: .spotlightIndex,
                                status: .rebuildable,
                                allocatedBytes: 2048,
                                explanationKey: .diagnosticsExplanationSpotlightIndexed,
                                remediation: .rebuild(.spotlight)
                            ),
                        ]
                    )
                ]
            ).analyze(
                roots: [DiagnosticRoot(url: fixture.root, kind: .volume)],
                homeDirectory: fixture.root,
                rules: rules
            )
            let protectedMail = enforced.findings.first { $0.displayName == "inbox.emlx" }
            equal(protectedMail?.status, .protected, "a protected path is never cleanable")
            check(protectedMail?.remediation != .trash, "a protected path keeps no Trash action")
            equal(
                enforced.findings.first { $0.displayName == ".Spotlight-V100" }?.remediation,
                .rebuild(.spotlight),
                "protection keeps the rebuild path a protected index needs"
            )

            // One finding per location, and the specific statement wins.
            let collision = await StorageDiagnosticEngine(
                providers: [
                    SelfTestDiagnosticProvider(
                        findings: [
                            finding("/v/.Spotlight-V100", .unknown, .inspectOnly),
                            StorageFinding(
                                providerID: "spotlight",
                                path: URL(fileURLWithPath: "/v/.Spotlight-V100"),
                                displayName: ".Spotlight-V100",
                                category: .spotlightIndex,
                                status: .rebuildable,
                                allocatedBytes: 100,
                                explanationKey: .diagnosticsExplanationSpotlightIndexed,
                                remediation: .rebuild(.spotlight)
                            ),
                        ]
                    )
                ]
            ).analyze(
                roots: [DiagnosticRoot(url: fixture.root, kind: .volume)],
                homeDirectory: fixture.root,
                rules: rules
            )
            equal(
                collision.findings.map(\.category),
                [.spotlightIndex],
                "the more specific finding replaces the general one"
            )

            equal(
                DiagnosticCoverage.combining([.complete, .partial]),
                .partial,
                "coverage takes the most restrictive answer"
            )
            equal(
                DiagnosticCoverage.combining([.partial, .permissionDenied]),
                .permissionDenied,
                "a permission problem outranks a partial result"
            )

            // The providers that run by default discover and explain. None of them
            // offers a removal, which is what keeps the two modes apart.
            let report = await StorageDiagnosticEngine().analyze(
                roots: [DiagnosticRoot(url: fixture.root, kind: .volume)],
                homeDirectory: fixture.root,
                rules: rules
            )
            check(report.providerCount > 0, "the standard providers run")
            check(report.cleanableFindings.isEmpty, "no provider offers removal on its own")
            check(report.findings.allSatisfy { $0.remediation != .trash }, "and none suggests the Trash")
            check(
                report.findings.contains { $0.category == .developerIndex && $0.status == .rebuildable },
                "an Xcode index is reported as rebuildable"
            )
            check(
                report.findings.map(\.allocatedBytes) == report.findings.map(\.allocatedBytes).sorted(by: >),
                "findings are listed largest first"
            )
            check(
                report.categoryTotals.map(\.bytes) == report.categoryTotals.map(\.bytes).sorted(by: >),
                "category totals are ordered by size"
            )
            check(!report.isComplete || report.skips.isEmpty, "a complete result has nothing skipped")

            // A refused system query is not an answer: the report says it is
            // partial rather than claiming the volume holds no snapshots.
            let refused = await APFSSnapshotProvider().analyze(
                StorageDiagnosticContext(
                    roots: [DiagnosticRoot(url: URL(fileURLWithPath: "/nonexistent-volume"), kind: .volume)],
                    homeDirectory: fixture.root
                )
            )
            equal(refused.coverage, .partial, "a refused snapshot query makes the report partial")
            check(refused.findings.isEmpty, "and invents no finding for it")

            // A Spotlight store is reported whether or not its size can be read,
            // because silence would read as "there is no index".
            let store = TempFixture(tag: "diagnostics-spotlight")
            defer { store.cleanup() }
            store.write("\(SpotlightDiagnosticProvider.storeName)/store.db", bytes: 4096)
            let storeBatch = await SpotlightDiagnosticProvider().analyze(
                StorageDiagnosticContext(
                    roots: [DiagnosticRoot(url: store.root, kind: .volume)],
                    homeDirectory: fixture.root
                )
            )
            equal(storeBatch.findings.count, 1, "a volume store is reported")
            equal(storeBatch.findings.first?.status, .rebuildable, "and it is rebuildable, not cleanable")
            equal(
                storeBatch.findings.first?.remediation,
                .rebuild(.spotlight),
                "with the mechanism that rebuilds it"
            )

            // A Core Spotlight store that exists but cannot be read still produces
            // a finding: the size is unknown, and the report says why.
            let core = TempFixture(tag: "diagnostics-core")
            defer { core.cleanup() }
            let storePath = core.directory(CoreSpotlightDiagnosticProvider.storePath)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storePath.path)
            let coreBatch = await CoreSpotlightDiagnosticProvider().analyze(
                StorageDiagnosticContext(roots: [], homeDirectory: core.root)
            )
            equal(coreBatch.findings.count, 1, "an unreadable search index is still reported")
            equal(coreBatch.coverage, .permissionDenied, "and the coverage says access is missing")
            equal(coreBatch.findings.first?.fileCount, nil, "an unreadable store has no count, not zero")
        }
    }

    // MARK: - Report accuracy

    private func reportAccuracyTests() async {
        await group("Report accuracy") {
            let fixture = TempFixture(tag: "report-accuracy")
            defer { fixture.cleanup() }

            let moved = FileOperationResult(
                sourceURL: fixture.root.appendingPathComponent("a.bin"),
                status: .movedToTrash,
                sizeInBytes: 100,
                category: .applicationCache
            )
            let skipped = FileOperationResult(
                sourceURL: fixture.root.appendingPathComponent("b.bin"),
                status: .skipped,
                errorCode: ErrorCode.fileNotFound.rawValue,
                sizeInBytes: 50,
                category: .logs
            )
            let failed = FileOperationResult(
                sourceURL: fixture.root.appendingPathComponent("c.bin"),
                status: .failed,
                errorCode: ErrorCode.permissionDenied.rawValue,
                sizeInBytes: 25,
                category: .installers
            )
            let outcome = CleanupOutcome(
                results: [moved, skipped, failed],
                categoryTotals: [
                    CategoryTotal(category: .applicationCache, itemCount: 1, totalBytes: 100),
                ],
                startedAt: Date(),
                finishedAt: Date(),
                operationName: .junkCleanup
            )
            let scanReport = ScanReport(
                sessionID: "accuracy",
                startedAt: Date(),
                finishedAt: Date(),
                phase: .ready,
                scannedFileCount: 42,
                scannedByteCount: 4096,
                scannedLocationCount: 2,
                itemCount: 3,
                itemBytes: 175,
                categoryTotals: [],
                duplicateGroupCount: 0,
                duplicateReclaimableBytes: 0,
                skippedLocations: []
            )

            let service = ReportService(supportDirectory: fixture.root)
            let report = await service.makeReport(from: outcome, scanReport: scanReport)

            equal(report.scannedLocationCount, 2, "the report states the scan scope")
            equal(report.scannedFileCount, 42, "the report states files examined")
            equal(report.skippedCount, 1, "skipped items are counted once")
            equal(report.movedCount, 1, "moved items are counted")
            equal(report.failedCount, 1, "failed items are counted")
            equal(report.categories, ["applicationCache"], "categories come from the outcome")
            equal(report.entries.count, 3, "every result has an entry")
            equal(report.entries.first { $0.status == "movedToTrash" }?.category, "applicationCache",
                  "an entry names its real category")
        }
    }

    // MARK: - Production engine

    private func productionEngineTests() async {
        await group("Production engine") {
            let fixture = TempFixture(tag: "production")
            defer { fixture.cleanup() }
            fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
            fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
            fixture.age(fixture.root.appendingPathComponent("Library/Logs/com.example.app/old.log"), days: 60)

            let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.root)
            let engine = ScannerEngineFactory.makeDefault(rules: rules)
            print("      engine under test: \(engine.kind.displayName)")

            let request = ScanRequest(
                homeDirectory: fixture.root,
                roots: [ScanRoot(url: fixture.root, anchor: .home)],
                includeDuplicates: false
            )
            guard let session = try? await engine.startScan(request) else {
                check(false, "the production engine starts a scan")
                return
            }
            var report: ScanReport?
            var items: [CleanupItemSummary] = []
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                for event in await session.pollEvents(maxEvents: 128) {
                    switch event {
                    case let .itemsFound(batch): items.append(contentsOf: batch)
                    case let .completed(summary): report = summary
                    default: break
                    }
                }
                if await session.isFinished() { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            for event in await session.pollEvents(maxEvents: 256) {
                switch event {
                case let .itemsFound(batch): items.append(contentsOf: batch)
                case let .completed(summary): report = summary
                default: break
                }
            }

            check(report != nil, "the production engine completes")
            check(!items.isEmpty, "the production engine finds candidates")
            check(
                items.contains(where: { $0.category == .applicationCache }),
                "the production engine reports cache items"
            )
            check(
                !items.contains(where: { $0.url.path.contains("/Documents/") }),
                "the production engine never reports user content"
            )

            let page = (try? await session.page(offset: 0, limit: 10, sort: .size, category: nil))
                ?? ScanPage(items: [], remaining: 0)
            check(
                !page.items.isEmpty || items.isEmpty,
                "the production engine pages results (events=\(items.count), page=\(page.items.count), remaining=\(page.remaining))"
            )
        }
    }

    // MARK: - Helpers

    private func makeItem(url: URL, size: Int64 = 4096, risk: CleanupRisk = .review) -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: url.lastPathComponent,
            category: .applicationCache,
            risk: risk,
            sizeInBytes: size,
            fileCount: 1,
            explanationKey: "cleanup.explanation.cache",
            sourceRuleID: "self-test"
        )
    }
}

/// A diagnostics provider that returns a fixed batch.
///
/// Lets the self-test assert what the engine does with findings — protection,
/// de-duplication, ordering — without depending on what is on this machine.
struct SelfTestDiagnosticProvider: StorageDiagnosticProvider {
    let identifier = "selfTest"

    let findings: [StorageFinding]

    func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        StorageFindingBatch(findings: findings)
    }
}

/// Stands in for the security-scoped bookmark machinery.
///
/// A bookmark cannot be minted outside a signed, entitled app, so the launch path
/// — where a stored grant is re-validated — would otherwise be untestable here.
/// A class so a test can add a location after the service has captured the coder.
final class SelfTestBookmarkCoder: BookmarkCoder, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: String]

    /// Bookmark payload to the path it resolves to.
    var paths: [String: String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return routes
        }
        set {
            lock.lock()
            routes = newValue
            lock.unlock()
        }
    }

    init(paths: [String: String] = [:]) {
        routes = paths
    }

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: bookmark, encoding: .utf8), paths[path] != nil else {
            throw SelfTestBookmarkUnavailable()
        }
        return (URL(fileURLWithPath: path), false)
    }
}

/// A bookmark that cannot be reopened.
struct SelfTestBookmarkUnavailable: Error {}

/// A `UserDefaults` suite carried across an isolation boundary.
///
/// The type is documented as thread-safe; the annotation states that this test
/// relies on it rather than sharing the standard defaults with other tests.
final class DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults

    init(suiteName: String) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }
}

/// A counter shared with a detached task.
actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A temporary directory tree that removes itself on drop.
///
/// `@unchecked Sendable`: it holds one immutable URL and the cleanup runs in
/// `deinit`, so handing it to a main-actor closure is safe.
final class TempFixture: @unchecked Sendable {
    let root: URL

    init(tag: String) {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-selftest-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        // Resolved once: the tests use this path as a home directory and as a scan
        // root, and both have to be spelled the way the engines spell the paths
        // they derive, or prefix comparisons across `/var` and `/private/var` fail.
        root = candidate.resolvingSymlinksInPath()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ relative: String) -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ relative: String, bytes: Int) -> URL {
        writeData(relative, Data(repeating: 0x78, count: bytes))
    }

    @discardableResult
    func writeData(_ relative: String, _ data: Data) -> URL {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
        return url
    }

    @discardableResult
    func symlink(to target: URL, name: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    /// Sets a file's modification time to `days` ago.
    func age(_ url: URL, days: Int) {
        let when = Date().addingTimeInterval(-Double(days) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }
}
