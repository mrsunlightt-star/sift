import Darwin
import Foundation
import XCTest
@testable import Core
import Shared

/// Scanner behaviour against a synthetic home directory (§16.1, §16.2).
///
/// The fixture contains every hazard the specification lists: an unreadable
/// folder, a symlink pointing outside the tree, a package directory, a
/// same-size-different-content pair, and a fresh file next to a stale one.
final class ScannerTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "scan")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeEngine() -> SwiftScannerEngine {
        SwiftScannerEngine(rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url))
    }

    private func makeRequest(includeDuplicates: Bool = false) -> ScanRequest {
        ScanRequest(
            homeDirectory: fixture.url,
            roots: [ScanRoot(url: fixture.url, anchor: .home)],
            largeFileThresholdBytes: 1024 * 1024,
            oldFileThresholdDays: 180,
            staleThresholdDays: 30,
            ignoredPaths: [],
            installedBundleIdentifiers: [],
            includeDuplicates: includeDuplicates,
            duplicateRoots: []
        )
    }

    /// Runs a scan to completion and returns what it found.
    private func runScan(
        _ request: ScanRequest,
        engine: (any ScannerEngine)? = nil
    ) async throws -> (items: [CleanupItemSummary], report: ScanReport?, skipped: [SkippedLocation]) {
        let session = try await (engine ?? makeEngine()).startScan(request)
        var items: [CleanupItemSummary] = []
        var skipped: [SkippedLocation] = []
        var report: ScanReport?

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for event in await session.pollEvents(maxEvents: 256) {
                switch event {
                case let .itemsFound(batch): items.append(contentsOf: batch)
                case let .locationSkipped(location): skipped.append(location)
                case let .completed(summary): report = summary
                default: break
                }
            }
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // `isFinished` can flip between the last poll and the completion event,
        // so the final drain collects every event type.
        for event in await session.pollEvents(maxEvents: 512) {
            switch event {
            case let .itemsFound(batch): items.append(contentsOf: batch)
            case let .locationSkipped(location): skipped.append(location)
            case let .completed(summary): report = summary
            default: break
            }
        }
        return (items, report, skipped)
    }

    /// A measure-only root contributes no cleanup candidates, including the
    /// duplicate pipeline. The empty `allowed` set used to mean "search
    /// everything", so a read-only request still produced groups.
    func test_aMeasureOnlyRootProducesNoDuplicateGroups() async throws {
        fixture.writeBytes("Documents/a.bin", Data(repeating: 0x41, count: 8192))
        fixture.writeBytes("Documents/b.bin", Data(repeating: 0x41, count: 8192))

        let request = ScanRequest(
            homeDirectory: fixture.url,
            roots: [ScanRoot(url: fixture.url, anchor: .home, isCleanable: false)],
            includeDuplicates: true,
            duplicateRoots: [fixture.url.appendingPathComponent("Documents").path]
        )
        let session = try await makeEngine().startScan(request)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = await session.pollEvents(maxEvents: 256)
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let groups = try await session.duplicateGroups(offset: 0, limit: 100)
        XCTAssertTrue(groups.isEmpty)
    }

    /// A cache directory whose application is running is offered at `review`.
    ///
    /// The item is not dropped: the user can still choose it. What it loses is
    /// the pre-selection, because a `safe` item that a live process is writing
    /// into is the one case where "safe" would be a promise the app cannot keep —
    /// the move succeeds, the directory comes back, and the space was never
    /// reclaimed.
    func test_aRunningApplicationTakesItsCacheRowsDownToReview() async throws {
        fixture.write("Library/Caches/com.running.app/blob.bin", bytes: 8192)
        fixture.write("Library/Caches/com.idle.app/blob.bin", bytes: 8192)

        var request = makeRequest()
        request.runningApplicationTokens = ["com.running.app"]
        let (items, _, _) = try await runScan(request)

        let running = items.first { $0.url.lastPathComponent == "com.running.app" }
        let idle = items.first { $0.url.lastPathComponent == "com.idle.app" }
        XCTAssertEqual(running?.risk, .review, "the running application's cache is a review item")
        XCTAssertEqual(idle?.risk, .safe, "an idle application's cache keeps its level")
        XCTAssertEqual(running?.sourceRuleID, "user-cache")
    }

    /// A rule inside a dot-directory follows the "show hidden files" setting.
    ///
    /// The walkers skip hidden entries, but a rule's own `relativePath` never
    /// reaches a walker — so `~/.cache` used to be offered with the setting
    /// turned off, which made the scope depend on which rule asked.
    func test_aRuleUnderAHiddenDirectoryFollowsTheHiddenFileSetting() async throws {
        let jar = fixture.write(".gradle/caches/jars/a.jar", bytes: 4096)
        fixture.age(jar, days: 60)

        var request = makeRequest()
        request.includeHiddenFiles = true
        let (visible, _, _) = try await runScan(request)
        XCTAssertTrue(
            visible.contains { $0.sourceRuleID == "user-gradle-caches" },
            "a dot-directory rule runs while hidden files are in scope"
        )

        request.includeHiddenFiles = false
        let (hidden, _, _) = try await runScan(request)
        XCTAssertFalse(
            hidden.contains { $0.sourceRuleID == "user-gradle-caches" },
            "and contributes nothing when they are out of scope"
        )
    }

    /// The cache rule and the residue scan name the same directory. The page
    /// keeps one row, at the more cautious risk — the Rust core's merge.
    func test_onePathMatchedByTwoRulesIsOneRowAtTheMoreCautiousRisk() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        // An empty installed list now means discovery failed, and residue is
        // skipped; name another application so `com.example.app` is genuinely
        // uninstalled and the residue scan claims the directory too.
        var request = makeRequest()
        request.installedBundleIdentifiers = ["com.other.app"]
        let session = try await makeEngine().startScan(request)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = await session.pollEvents(maxEvents: 256)
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let page = try await session.page(offset: 0, limit: 100, sort: .size, category: nil)
        let rows = page.items.filter { $0.url.lastPathComponent == "com.example.app" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.category, .applicationResidue)
        XCTAssertEqual(rows.first?.risk, .review)
    }

    func test_scanFindsCachesLogsAndInstallers() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        fixture.write("Library/Caches/com.other.app/blob.bin", bytes: 4096)
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)
        let installer = fixture.write("Downloads/Old.dmg", bytes: 4096)
        fixture.age(installer, days: 60)

        let result = try await runScan(makeRequest())
        let categories = Set(result.items.map(\.category))
        XCTAssertTrue(categories.contains(.applicationCache))
        XCTAssertTrue(categories.contains(.logs))
        XCTAssertTrue(categories.contains(.installers))
        XCTAssertNotNil(result.report)
    }

    func test_freshInstallerIsNotOffered() async throws {
        fixture.write("Downloads/JustDownloaded.dmg", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(
            result.items.contains { $0.displayName == "JustDownloaded.dmg" },
            "a download the user may still need must not be pre-selected"
        )
    }

    func test_cloudKitIsNeverOffered() async throws {
        fixture.write("Library/Caches/CloudKit/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.displayName == "CloudKit" })
    }

    func test_aLargeFileInsideExcludedApplicationDataIsNotOffered() async throws {
        // The exclusion belongs to the directory, not to the file. A threshold
        // scan looks at files, so it has to check the ancestors.
        fixture.write("Library/Caches/CloudKit/large.bin", bytes: 2 * 1024 * 1024)
        fixture.write("Downloads/large.bin", bytes: 2 * 1024 * 1024)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(
            result.items.contains { $0.url.path.contains("/CloudKit/") },
            "a file inside CloudKit's data must never be a candidate"
        )
        XCTAssertTrue(
            result.items.contains { $0.displayName == "large.bin" && $0.category == .largeFiles },
            "the ordinary large file is still offered"
        )
    }

    func test_aRuleExcludeCoversFilesBelowTheNamedDirectory() async throws {
        fixture.write("Downloads/private/secret.txt", bytes: 4096)
        fixture.write("Downloads/open.txt", bytes: 4096)
        let rule = RuleEngine.Rule(
            id: "excluded-files",
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
        let rules = RuleEngine(
            rules: RuleEngine.builtInRules + [rule],
            homeDirectory: fixture.url
        )
        let engine = SwiftScannerEngine(rules: rules)
        let session = try await engine.startScan(makeRequest())
        var items: [CleanupItemSummary] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for event in await session.pollEvents(maxEvents: 256) {
                if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
            }
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        for event in await session.pollEvents(maxEvents: 256) {
            if case let .itemsFound(batch) = event { items.append(contentsOf: batch) }
        }
        XCTAssertFalse(items.contains { $0.displayName == "secret.txt" })
        XCTAssertTrue(items.contains { $0.displayName == "open.txt" })
    }

    func test_userDocumentsNeverAppear() async throws {
        fixture.write("Documents/taxes.pdf", bytes: 8192)
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.url.path.contains("/Documents/") })
        XCTAssertTrue(
            result.skipped.contains { $0.code == ErrorCode.protectedLocation.rawValue },
            "the refusal is reported, not hidden"
        )
    }

    func test_aLogDirectoryWithAFreshFileIsNotOffered() async throws {
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)
        fixture.write("Library/Logs/com.example.app/fresh.log", bytes: 2048)

        let result = try await runScan(makeRequest())
        XCTAssertFalse(
            result.items.contains { $0.category == .logs },
            "moving the directory would take the fresh log the threshold did not count"
        )
    }

    /// A directory item is moved whole, so an age filter may only decide whether
    /// it qualifies. A mixed directory must not be offered with a size that
    /// counts only its stale files.
    func test_anAgeFilteredDirectoryRuleDoesNotMoveFreshFiles() async throws {
        let old = fixture.write("Library/Application Support/Mixed/old.bin", bytes: 4096)
        fixture.age(old, days: 60)
        fixture.write("Library/Application Support/Mixed/fresh.bin", bytes: 4096)
        let allOld = fixture.write("Library/Application Support/AllOld/old.bin", bytes: 4096)
        fixture.age(allOld, days: 60)

        let rule = RuleEngine.Rule(
            id: "mixed-age",
            category: .temporaryFiles,
            risk: .review,
            root: .homeLibrary,
            relativePath: "Application Support",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: 30,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.temporary",
            isEnabled: true
        )
        let rules = RuleEngine(rules: [rule], homeDirectory: fixture.url)
        let result = try await runScan(makeRequest(), engine: SwiftScannerEngine(rules: rules))

        let names = Set(result.items.map(\.displayName))
        XCTAssertFalse(names.contains("Mixed"), "a directory with fresh files must not be offered")
        XCTAssertTrue(names.contains("AllOld"), "an entirely stale directory is still eligible")
        XCTAssertEqual(
            result.items.first { $0.displayName == "AllOld" }?.sizeInBytes,
            4096,
            "the reported size is the size of what the move takes"
        )
    }

    func test_theStaleThresholdSettingChangesWhatCountsAsStale() async throws {
        // §5.2: the user sets one age at which a log counts as stale. A 60-day-old
        // log is stale at the default 30 and still fresh at 90, so this fails if
        // the setting never reaches the rule that scans logs.
        let log = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(log, days: 60)

        var request = makeRequest()
        request.staleThresholdDays = 30
        let defaultRun = try await runScan(request)
        XCTAssertEqual(
            defaultRun.items.filter { $0.category == .logs }.count,
            1,
            "60 days is stale at the default threshold"
        )

        request.staleThresholdDays = 90
        let raised = try await runScan(request)
        XCTAssertEqual(
            raised.items.filter { $0.category == .logs }.count,
            0,
            "the same log is still fresh at 90 days"
        )
    }

    func test_theStaleThresholdLeavesARuleWithItsOwnAgeAlone() async throws {
        // The archive rule states 90 days and must not follow the setting, or
        // every zip in Downloads would become stale after a fortnight.
        let archive = fixture.write("Downloads/notes.zip", bytes: 4096)
        fixture.age(archive, days: 30)

        var request = makeRequest()
        request.staleThresholdDays = 14
        let result = try await runScan(request)
        XCTAssertFalse(
            result.items.contains { $0.displayName == "notes.zip" },
            "a fixed-age rule keeps its own threshold"
        )
    }

    func test_theHiddenFileSettingDecidesWhatAScanProduces() async throws {
        // §5.6: the preference is a scan scope, so with it off the dotfile is not
        // a candidate and the bytes it holds are not reported as reclaimable.
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.example.app/.hidden.bin", bytes: 8192)

        var request = makeRequest()
        request.includeHiddenFiles = true
        let shown = try await runScan(request)
        let shownItem = try XCTUnwrap(shown.items.first { $0.category == .applicationCache })

        request.includeHiddenFiles = false
        let hidden = try await runScan(request)
        let hiddenItem = try XCTUnwrap(hidden.items.first { $0.category == .applicationCache })

        XCTAssertLessThan(
            hiddenItem.sizeInBytes,
            shownItem.sizeInBytes,
            "excluding the dotfile must reduce the measured size"
        )
    }

    func test_aHiddenInstallerIsNotOfferedUnlessHiddenFilesAreShown() async throws {
        // The file rules read the same scope as the directory rules.
        let installer = fixture.write("Downloads/.Old.dmg", bytes: 4096)
        fixture.age(installer, days: 60)

        var request = makeRequest()
        request.includeHiddenFiles = false
        let hidden = try await runScan(request)
        XCTAssertFalse(
            hidden.items.contains { $0.displayName == ".Old.dmg" },
            "a dotfile must not appear while the setting is off"
        )

        request.includeHiddenFiles = true
        let shown = try await runScan(request)
        XCTAssertTrue(
            shown.items.contains { $0.displayName == ".Old.dmg" },
            "and it must appear once the user asks to see hidden files"
        )
    }

    func test_symlinkIsNotFollowed() async throws {
        let outside = TemporaryDirectory(tag: "outside")
        outside.write("secret.bin", bytes: 4096)
        let link = fixture.url.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)

        let result = try await runScan(makeRequest())
        XCTAssertFalse(result.items.contains { $0.url.path.contains("secret.bin") })
    }

    func test_packageDirectoryIsMeasuredAsOneUnit() async throws {
        fixture.write("Library/Caches/App.app/Contents/MacOS/App", bytes: 8192)
        fixture.write("Library/Caches/App.app/Contents/Resources/data", bytes: 8192)
        let result = try await runScan(makeRequest())
        let package = result.items.first { $0.displayName == "App.app" }
        XCTAssertNotNil(package, "a bundle is one item")
        XCTAssertGreaterThanOrEqual(package?.fileCount ?? 0, 2)
    }

    func test_ignoredPathsAreNotScanned() async throws {
        fixture.write("Library/Caches/keep/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/skip/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.ignoredPaths = [fixture.url.appendingPathComponent("Library/Caches/skip").path]
        let result = try await runScan(request)
        XCTAssertFalse(result.items.contains { $0.url.path.contains("/skip") })
    }

    func test_pagingIsStableAcrossPages() async throws {
        for index in 0..<12 {
            fixture.write("Library/Caches/com.app\(index)/blob.bin", bytes: 1024 * (index + 1))
        }
        let session = try await makeEngine().startScan(makeRequest())
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let first = try await session.page(offset: 0, limit: 5, sort: .size, category: nil)
        let second = try await session.page(offset: 5, limit: 5, sort: .size, category: nil)
        XCTAssertEqual(first.items.count, 5)
        XCTAssertTrue(first.items[0].sizeInBytes >= first.items[4].sizeInBytes)
        XCTAssertTrue(
            Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))),
            "pages must not repeat rows"
        )
    }

    func test_categoryFilterIsolatesOneCategory() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 8192)
        let stale = fixture.write("Library/Logs/com.example.app/old.log", bytes: 2048)
        fixture.age(stale, days: 60)

        let session = try await makeEngine().startScan(makeRequest())
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, await !session.isFinished() {
            _ = await session.pollEvents(maxEvents: 128)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let page = try await session.page(offset: 0, limit: 50, sort: .size, category: .logs)
        XCTAssertTrue(page.items.allSatisfy { $0.category == .logs })
    }

    func test_cancellationStopsTheScan() async throws {
        for index in 0..<120 {
            fixture.write("Library/Caches/com.app\(index)/blob.bin", bytes: 8192)
        }
        let session = try await makeEngine().startScan(makeRequest())
        await session.cancel()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, await !session.isFinished() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let finished = await session.isFinished()
        XCTAssertTrue(finished, "cancellation must stop the scan")
    }

    func test_unreadableDirectoryIsReportedNotFatal() async throws {
        let locked = fixture.directory("Library/Caches/com.locked")
        fixture.write("Library/Caches/com.locked/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.ok/blob.bin", bytes: 4096)

        var permissions = try FileManager.default.attributesOfItem(atPath: locked.path)
        permissions[.posixPermissions] = 0o000
        try FileManager.default.setAttributes(permissions, ofItemAtPath: locked.path)
        defer {
            var restore = try? FileManager.default.attributesOfItem(atPath: locked.path)
            restore?[.posixPermissions] = 0o755
            if let restore { try? FileManager.default.setAttributes(restore, ofItemAtPath: locked.path) }
        }

        let result = try await runScan(makeRequest())
        XCTAssertNotNil(result.report, "one unreadable folder must not fail the scan")

        // Root ignores the mode bits, so the skip is only observable for a normal
        // user. The unconditional part of this test is that the scan completed.
        if geteuid() != 0 {
            XCTAssertTrue(
                result.skipped.contains { $0.code == ErrorCode.permissionDenied.rawValue },
                "the unreadable folder is reported by code"
            )
        }
    }

    /// The production engine's completion summary is what the page applies
    /// last. A skipped folder must leave it `partial`, not `ready`.
    func test_theProductionEngineReportsASkippedFolderAsPartial() async throws {
        // Root ignores the mode bits, so the skip is only observable for a
        // normal user; without one there is nothing this test can assert.
        guard geteuid() != 0 else { return }

        let locked = fixture.directory("Library/Caches/com.locked")
        fixture.write("Library/Caches/com.locked/blob.bin", bytes: 4096)
        fixture.write("Library/Caches/com.ok/blob.bin", bytes: 4096)
        var permissions = try FileManager.default.attributesOfItem(atPath: locked.path)
        permissions[.posixPermissions] = 0o000
        try FileManager.default.setAttributes(permissions, ofItemAtPath: locked.path)
        defer {
            var restore = try? FileManager.default.attributesOfItem(atPath: locked.path)
            restore?[.posixPermissions] = 0o755
            if let restore { try? FileManager.default.setAttributes(restore, ofItemAtPath: locked.path) }
        }

        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = ScannerEngineFactory.makeDefault(rules: rules)
        let result = try await runScan(makeRequest(), engine: engine)

        XCTAssertEqual(result.report?.phase, .partial)
        XCTAssertEqual(result.report?.isPartial, true)
    }

    func test_everyItemCarriesAnExplanationAndRuleID() async throws {
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)
        let result = try await runScan(makeRequest())
        for item in result.items {
            XCTAssertFalse(item.sourceRuleID.isEmpty)
            XCTAssertFalse(item.explanationKey.isEmpty)
        }
    }

    /// A sandbox container is claimed only when its application is gone.
    ///
    /// `~/Library/Containers/<bundle-id>` is an application's whole data directory,
    /// so no rule matches it: a rule knows a name shape, not whether the
    /// application is installed. The Rust scanner refuses the same two shapes, and
    /// this is what keeps the fallback engine from finding less than it.
    func test_containerResidueNeedsTheApplicationToBeGone() async throws {
        fixture.write("Library/Containers/com.gone.app/Data/blob.bin", bytes: 4096)
        fixture.write("Library/Containers/com.installed.app/Data/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.installedBundleIdentifiers = ["com.installed.app"]
        let residue = try await runScan(request).items
            .filter { $0.category == .applicationResidue }
            .map(\.displayName)

        XCTAssertTrue(residue.contains("com.gone.app"), "the container of a removed app is residue")
        XCTAssertFalse(
            residue.contains("com.installed.app"),
            "the container of an installed app is its data, not leftover"
        )
    }

    /// A container an installed application's app group declares is not residue.
    ///
    /// The container is named after the group, not after either application that
    /// shares it, so no name reading resolves it: without the declared set this
    /// live container was reported as a leftover of an application that is gone.
    /// The set arrives in the request, and the Rust core reads the same field.
    func test_aDeclaredAppGroupContainerIsNotResidue() async throws {
        fixture.write("Library/Group Containers/group.com.vendor.shared/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/group.com.vendor.gone/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.installedBundleIdentifiers = ["com.installed.app"]
        request.appGroupIdentifiers = ["GROUP.com.vendor.shared"]
        let residue = try await runScan(request).items
            .filter { $0.category == .groupContainerResidue }
            .map(\.displayName)

        XCTAssertFalse(
            residue.contains("group.com.vendor.shared"),
            "a declared app group owns its container however its name reads"
        )
        XCTAssertTrue(
            residue.contains("group.com.vendor.gone"),
            "a container nothing declares is still residue"
        )
    }

    /// An incomplete declared set means no group-container residue at all.
    ///
    /// A set that was cut short answers "nothing declares this" for every
    /// container whose owner went unread, which is how a live container becomes a
    /// cleanup row. Reporting nothing for the run is the safe answer, and the
    /// private-container categories keep working.
    func test_anIncompleteDeclaredSetReportsNoGroupContainerResidue() async throws {
        fixture.write("Library/Group Containers/group.com.vendor.gone/blob.bin", bytes: 4096)
        fixture.write("Library/Containers/com.gone.app/Data/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.installedBundleIdentifiers = ["com.installed.app"]
        request.appGroupIdentifiers = []
        request.appGroupIdentifiersComplete = false
        let items = try await runScan(request).items

        XCTAssertFalse(
            items.contains { $0.category == .groupContainerResidue },
            "no container may be called a leftover while the set is unknown"
        )
        XCTAssertTrue(
            items.contains { $0.category == .applicationResidue },
            "the categories that do not depend on the set still report"
        )
    }

    /// A shared container is read in both spellings macOS writes.
    ///
    /// `TEAMID.com.example.app` never equals an installed identifier, so accepting
    /// it on that reading alone offers the shared container of an installed
    /// application for removal.
    func test_groupContainerResidueReadsBothSpellingsOfTheName() async throws {
        fixture.write("Library/Group Containers/TEAM1.com.gone.app/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/TEAM2.com.installed.app/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/com.also-gone.app/blob.bin", bytes: 4096)
        fixture.write("Library/Group Containers/UBF8T346G9.Office/blob.bin", bytes: 4096)

        var request = makeRequest()
        request.installedBundleIdentifiers = ["com.installed.app"]
        let items = try await runScan(request).items
        // A shared container is its own category: it belongs to an app group, so
        // it is not the same claim as a private container and the page keeps the
        // two totals apart.
        let residue = items
            .filter { $0.category == .groupContainerResidue }
            .map(\.displayName)

        XCTAssertTrue(residue.contains("TEAM1.com.gone.app"))
        XCTAssertTrue(
            residue.contains("com.also-gone.app"),
            "a container named after the bundle id alone is residue too"
        )
        XCTAssertFalse(
            residue.contains("TEAM2.com.installed.app"),
            "the reading after the team prefix names an installed application"
        )
        XCTAssertFalse(
            residue.contains("UBF8T346G9.Office"),
            "a name in neither spelling is left alone"
        )
        XCTAssertFalse(
            items.contains { $0.category == .applicationResidue && $0.displayName.hasPrefix("TEAM1") },
            "a shared container is not reported as per-application residue"
        )
    }

    /// The walker stops at a mount point: `/` and `/dev` are different
    /// filesystems, and a nested mount belongs to a volume the user never
    /// authorised for this scan.
    func test_theWalkerCanTellTwoFilesystemsApart() {
        XCTAssertNotEqual(
            FileWalker.device(of: URL(fileURLWithPath: "/")),
            FileWalker.device(of: URL(fileURLWithPath: "/dev"))
        )
    }

    /// The request the app builds is accepted by the production engine.
    ///
    /// `AppEnvironment.makeScanRequest` sends three roots on an ordinary Mac: the
    /// home directory, `/Library/Logs`, and the session's `/var/folders/<xx>/<hash>`
    /// with `anchor: .userTemp`. The Rust core's ABI gate had no branch for the
    /// third one, so every scan the shipped app started was refused with
    /// `invalidRequest` before the engine did any work — and no test noticed,
    /// because a fixture home puts every root inside the tree that the gate
    /// already allows. This asserts the acceptance, nothing about the walk: the
    /// session is cancelled as soon as it exists.
    func test_theRequestTheAppBuildsIsAcceptedByTheProductionEngine() async throws {
        var roots: [ScanRoot] = [ScanRoot(url: fixture.url, anchor: .home)]
        roots.append(
            ScanRoot(
                url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
                anchor: .systemLibrary,
                isCleanable: true,
                includesThresholdFiles: false
            )
        )
        if let userTemp = RuleEngine.darwinUserTempRoot() {
            roots.append(
                ScanRoot(
                    url: userTemp,
                    anchor: .userTemp,
                    isCleanable: true,
                    includesThresholdFiles: false
                )
            )
        }

        let rules = RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        let engine = ScannerEngineFactory.makeDefault(rules: rules)
        let request = ScanRequest(
            homeDirectory: fixture.url,
            roots: roots,
            includeDuplicates: false
        )
        let session = try await engine.startScan(request)
        await session.cancel()
    }

    /// Opening the engine empties its index directory, whatever is in it.
    ///
    /// The index holds every scanned path and file name, and a session removes its
    /// own database when it ends — so what a launch finds is the debris of runs
    /// that died without unwinding. The sweep used to spare anything younger than
    /// a day, which kept exactly that debris: a morning of force-quit runs on this
    /// machine left 60 databases holding 185 MB of full paths, and only a launch
    /// would have deleted them.
    func test_openingTheEngineSweepsTheIndexDirectory() throws {
        #if canImport(SiftScanner)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A database, its WAL and shared-memory files, and one stray file: the
        // sweep is by entry, not by suffix, because everything in this directory
        // was written by this product.
        for name in ["A.sqlite", "A.sqlite-wal", "A.sqlite-shm", "B.sqlite", "stray.txt"] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(name).path,
                    contents: Data("x".utf8)
                ),
                "the fixture file \(name) is created"
            )
        }
        let seeded = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(seeded.count, 5)

        _ = RustScannerEngine(indexDirectory: directory)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(
            remaining,
            [],
            "nothing in the index directory outlives the process that wrote it"
        )
        #endif
    }
}
