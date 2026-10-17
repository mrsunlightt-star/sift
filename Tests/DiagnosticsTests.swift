import Foundation
import XCTest
@testable import Core
import Shared

/// A provider that returns a fixed batch, so the engine's own rules can be tested
/// without touching the file system.
private struct StubProvider: StorageDiagnosticProvider {
    let identifier: String
    let batch: StorageFindingBatch

    init(identifier: String = "stub", batch: StorageFindingBatch) {
        self.identifier = identifier
        self.batch = batch
    }

    func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch { batch }
}

private func finding(
    provider: String = "stub",
    path: String,
    category: StorageFindingCategory = .unknown,
    status: StorageFindingStatus = .unknown,
    bytes: Int64 = 1024,
    remediation: StorageRemediation = .inspectOnly
) -> StorageFinding {
    StorageFinding(
        providerID: provider,
        path: URL(fileURLWithPath: path),
        displayName: URL(fileURLWithPath: path).lastPathComponent,
        category: category,
        status: status,
        allocatedBytes: bytes,
        explanationKey: .diagnosticsExplanationVolumeChild,
        remediation: remediation
    )
}

/// System space diagnostics.
///
/// The feature's promise is that it widens what the product can *see* without
/// widening what it may *remove*, so the tests are mostly about the boundary:
/// what the engine refuses to pass through, and what it refuses to leave out.
final class DiagnosticsTests: XCTestCase, @unchecked Sendable {
    private let home = URL(fileURLWithPath: "/Users/example")

    private func makeRules() -> RuleEngine {
        RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home)
    }

    // MARK: - Measurement

    func test_measurementCountsFilesAndBothSizes() {
        let fixture = TemporaryDirectory(tag: "diag-measure")
        fixture.write("a.bin", bytes: 4096)
        fixture.write("nested/b.bin", bytes: 2048)

        let measured = DiagnosticMeasurer.measure(fixture.url, isCancelled: { false })

        XCTAssertEqual(measured.fileCount, 2)
        XCTAssertGreaterThan(measured.allocatedBytes, 0)
        XCTAssertEqual(measured.logicalBytes, 6144)
        XCTAssertEqual(measured.unreadableCount, 0)
        XCTAssertFalse(measured.truncated)
    }

    func test_measurementDoesNotFollowSymlinks() {
        // A link is not data: counting its target would attribute space to a
        // location the user did not ask about.
        let fixture = TemporaryDirectory(tag: "diag-symlink")
        let outside = TemporaryDirectory(tag: "diag-symlink-target")
        outside.write("secret.bin", bytes: 8192)
        fixture.write("own.bin", bytes: 1024)
        try? FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent("link"),
            withDestinationURL: outside.url
        )

        let measured = DiagnosticMeasurer.measure(fixture.url, isCancelled: { false })

        XCTAssertEqual(measured.fileCount, 1, "the linked tree must not be counted")
        XCTAssertEqual(measured.logicalBytes, 1024)
    }

    func test_measurementReportsAnUnreadableDirectoryInsteadOfStopping() {
        let fixture = TemporaryDirectory(tag: "diag-unreadable")
        fixture.write("readable.bin", bytes: 1024)
        let blocked = fixture.url.appendingPathComponent("blocked")
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)

        let measured = DiagnosticMeasurer.measure(fixture.url, isCancelled: { false })

        XCTAssertEqual(measured.fileCount, 1, "the readable part is still measured")
        XCTAssertEqual(measured.unreadableCount, 1)
        XCTAssertEqual(measured.unreadablePaths.map(\.lastPathComponent), ["blocked"])
    }

    func test_measurementStopsAtItsBudgetAndSaysSo() {
        let fixture = TemporaryDirectory(tag: "diag-budget")
        for index in 0..<40 {
            fixture.write("dir\(index)/file.bin", bytes: 16)
        }

        let measured = DiagnosticMeasurer.measure(fixture.url, budget: 10, isCancelled: { false })

        XCTAssertTrue(measured.truncated, "an incomplete measurement must not look complete")
        XCTAssertLessThan(measured.fileCount, 40)
    }

    func test_measuringAMissingLocationIsNotAnEmptyLocation() {
        let measured = DiagnosticMeasurer.measure(
            URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted"),
            isCancelled: { false }
        )

        XCTAssertFalse(measured.exists)
        XCTAssertEqual(measured.fileCount, 0)
    }

    // MARK: - Protection is applied by the engine, not by a provider

    func test_aProtectedPathCanNeverBeCleanable() {
        let engine = StorageDiagnosticEngine(providers: [])
        let reported = [
            finding(path: "/Users/example/Library/Mail/inbox.emlx", status: .cleanable, remediation: .trash),
            finding(path: "/System/Library/Caches/x", status: .cleanable, remediation: .trash),
            finding(path: "/Volumes/External/anything", status: .cleanable, remediation: .trash),
            finding(path: "/Users/example/Library/Caches/com.example.app", status: .cleanable, remediation: .trash),
        ]

        let enforced = engine.enforceProtection(on: reported, rules: makeRules())

        for item in enforced.prefix(3) {
            XCTAssertEqual(item.status, .protected, "\(item.path?.path ?? "") must be protected")
            XCTAssertTrue(item.isProtected)
            XCTAssertNotEqual(
                item.remediation,
                .trash,
                "protection removes the deletion path, whatever the provider asked for"
            )
            XCTAssertFalse(item.status.allowsTrashAction)
        }
        // The unprotected cache folder keeps what the provider said: this is a
        // protection check, not a blanket refusal.
        XCTAssertEqual(enforced[3].status, .cleanable)
        XCTAssertEqual(enforced[3].remediation, .trash)
    }

    func test_protectionKeepsTheExplanationAndTheRebuildPath() {
        // The point of reporting a protected index is that it can be rebuilt.
        // Protection removes the Trash action and nothing else.
        let engine = StorageDiagnosticEngine(providers: [])
        let enforced = engine.enforceProtection(
            on: [
                finding(
                    path: "/System/Volumes/Data/.Spotlight-V100",
                    category: .spotlightIndex,
                    status: .rebuildable,
                    remediation: .rebuild(.spotlight)
                )
            ],
            rules: makeRules()
        )

        XCTAssertEqual(enforced[0].status, .protected)
        XCTAssertEqual(enforced[0].remediation, .rebuild(.spotlight))
    }

    func test_aFindingWithoutAPathIsLeftAlone() {
        let engine = StorageDiagnosticEngine(providers: [])
        let pathless = StorageFinding(
            providerID: "stub",
            path: nil,
            displayName: "Something",
            category: .unknown,
            status: .unknown,
            allocatedBytes: 0,
            explanationKey: .diagnosticsExplanationVolumeChild,
            remediation: .inspectOnly
        )

        let enforced = engine.enforceProtection(on: [pathless], rules: makeRules())

        XCTAssertFalse(enforced[0].isProtected)
    }

    // MARK: - One finding per location

    func test_theMoreSpecificFindingWinsOnACollision() {
        let engine = StorageDiagnosticEngine(providers: [])
        let deduplicated = engine.deduplicate([
            finding(path: "/v/.Spotlight-V100", category: .unknown, bytes: 900),
            finding(path: "/v/.Spotlight-V100", category: .spotlightIndex, bytes: 900),
        ])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated[0].category, .spotlightIndex)
    }

    // MARK: - Coverage

    func test_coverageTakesTheMostRestrictiveAnswer() {
        XCTAssertEqual(DiagnosticCoverage.combining([.complete, .partial]), .partial)
        XCTAssertEqual(DiagnosticCoverage.combining([.partial, .permissionDenied]), .permissionDenied)
        XCTAssertEqual(
            DiagnosticCoverage.combining([.complete, .permissionDenied, .volumeUnavailable]),
            .volumeUnavailable
        )
        XCTAssertEqual(DiagnosticCoverage.combining([] as [DiagnosticCoverage]), .complete)
    }

    func test_theEngineAggregatesProviderResults() async {
        let providerA = StubProvider(
            identifier: "a",
            batch: StorageFindingBatch(
                findings: [finding(path: "/Users/example/Library/Caches/x", bytes: 100)],
                skips: [DiagnosticSkip(path: URL(fileURLWithPath: "/private/var/db"), reason: .permissionDenied)],
                coverage: .permissionDenied,
                measuredBytes: 100,
                measuredFiles: 1
            )
        )
        let providerB = StubProvider(
            identifier: "b",
            batch: StorageFindingBatch(
                findings: [finding(path: "/Users/example/Downloads/y", bytes: 900)],
                skips: [DiagnosticSkip(path: URL(fileURLWithPath: "/private/var/db"), reason: .permissionDenied)],
                coverage: .partial,
                measuredBytes: 900,
                measuredFiles: 1
            )
        )

        let report = await StorageDiagnosticEngine(providers: [providerA, providerB]).analyze(
            roots: [DiagnosticRoot(url: home, kind: .home)],
            homeDirectory: home,
            rules: makeRules()
        )

        XCTAssertEqual(report.coverage, .permissionDenied, "the most restrictive answer wins")
        XCTAssertEqual(report.providerCount, 2)
        XCTAssertEqual(report.measuredBytes, 1000)
        XCTAssertEqual(report.measuredFiles, 2)
        XCTAssertEqual(report.skips.count, 1, "the same skip from two providers is one entry")
        XCTAssertEqual(report.findings.map(\.allocatedBytes), [900, 100], "largest first")
        XCTAssertFalse(report.isComplete)
    }

    func test_cancellationStopsBeforeAnyProviderRuns() async {
        let provider = StubProvider(batch: StorageFindingBatch(findings: [finding(path: "/x")]))

        let report = await StorageDiagnosticEngine(providers: [provider]).analyze(
            roots: [DiagnosticRoot(url: home, kind: .home)],
            homeDirectory: home,
            rules: makeRules(),
            isCancelled: { true }
        )

        XCTAssertEqual(report.providerCount, 0)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func test_anEmptyScopeProducesAnEmptyReport() async {
        let report = await StorageDiagnosticEngine().analyze(
            roots: [],
            homeDirectory: home,
            rules: makeRules()
        )

        XCTAssertEqual(report.providerCount, 0)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func test_reportGroupsFindingsTheWayThePageShowsThem() {
        let report = StorageDiagnosticReport(
            generatedAt: Date(),
            roots: [],
            coverage: .complete,
            volumes: [],
            findings: [
                finding(path: "/a", category: .spotlightIndex, status: .protected, bytes: 300),
                finding(path: "/b", category: .spotlightIndex, status: .rebuildable, bytes: 200),
                finding(path: "/c", category: .developerIndex, status: .unknown, bytes: 100),
                finding(path: "/d", category: .filesystemSnapshot, status: .protected, bytes: 0),
            ],
            skips: [],
            measuredBytes: 600,
            measuredFiles: 4,
            providerCount: 1
        )

        XCTAssertEqual(report.categoryTotals.map(\.category), [.spotlightIndex, .developerIndex, .filesystemSnapshot])
        XCTAssertEqual(report.categoryTotals[0].bytes, 500)
        XCTAssertEqual(report.protectedFindings.count, 2)
        XCTAssertEqual(report.rebuildableFindings.map(\.path?.path), ["/b"])
        XCTAssertTrue(report.cleanableFindings.isEmpty)
        XCTAssertEqual(report.snapshotFindings.count, 1)
        XCTAssertEqual(report.findingsBytes, 600)
    }

    // MARK: - Providers

    func test_theVolumeProviderMeasuresTheVolumeRootChildren() async {
        let fixture = TemporaryDirectory(tag: "diag-volume")
        fixture.write("Library/cache.bin", bytes: 2048)
        fixture.write("usr/lib.bin", bytes: 4096)
        try? FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent("link"),
            withDestinationURL: fixture.url.appendingPathComponent("Library")
        )

        let context = StorageDiagnosticContext(
            roots: [DiagnosticRoot(url: fixture.url, kind: .volume)],
            homeDirectory: home
        )
        let batch = await VolumeSpaceProvider().analyze(context)

        XCTAssertEqual(batch.volumes.count, 1, "the volume totals are reported")
        XCTAssertEqual(
            Set(batch.findings.map(\.displayName)),
            ["Library", "usr"],
            "every child is measured, and a symlink is not one of them"
        )
        // §5.1: this provider measures and does not judge.
        XCTAssertTrue(batch.findings.allSatisfy { $0.status == .unknown })
        XCTAssertTrue(batch.findings.allSatisfy { $0.remediation == .inspectOnly })
        XCTAssertEqual(batch.measuredFiles, 2)
    }

    func test_theVolumeProviderAlwaysReportsAVolumeForTheUsageCard() async {
        let context = StorageDiagnosticContext(
            roots: [DiagnosticRoot(url: home, kind: .home)],
            homeDirectory: home
        )
        let batch = await VolumeSpaceProvider().analyze(context)

        XCTAssertEqual(batch.volumes.count, 1, "the boot volume is read even for a home-only run")
        XCTAssertTrue(batch.findings.isEmpty, "the volume's own children are not walked")
    }

    func test_coreSpotlightFindsTheStoreAndSaysTheSizeIsUnknown() async {
        let fixture = TemporaryDirectory(tag: "diag-core")
        // A store that exists but cannot be listed, which is what the real one
        // looks like without Full Disk Access.
        let store = fixture.url.appendingPathComponent(
            CoreSpotlightDiagnosticProvider.storePath
        )
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)

        let context = StorageDiagnosticContext(roots: [], homeDirectory: fixture.url)
        let batch = await CoreSpotlightDiagnosticProvider().analyze(context)

        XCTAssertEqual(batch.findings.count, 1)
        let reported = batch.findings[0]
        XCTAssertEqual(reported.category, .coreSpotlightIndex)
        XCTAssertEqual(reported.status, .rebuildable)
        XCTAssertEqual(reported.remediation, .rebuild(.spotlight))
        XCTAssertNil(reported.fileCount, "an unreadable store has no count, not a count of zero")
        XCTAssertEqual(batch.coverage, .permissionDenied)
        XCTAssertEqual(batch.skips.map(\.reason), [.permissionDenied])
        XCTAssertEqual(
            reported.explanationKey,
            .diagnosticsExplanationCoreSpotlightUnreadable,
            "the sentence has to say why the size is missing"
        )
    }

    func test_coreSpotlightReportsNothingWhenTheStoreIsAbsent() async {
        let fixture = TemporaryDirectory(tag: "diag-core-absent")

        let batch = await CoreSpotlightDiagnosticProvider().analyze(
            StorageDiagnosticContext(roots: [], homeDirectory: fixture.url)
        )

        XCTAssertTrue(batch.findings.isEmpty)
        XCTAssertEqual(batch.coverage, .complete)
    }

    func test_developerIndexNeedsTheIndexStructureToCallSomethingRebuildable() async {
        let fixture = TemporaryDirectory(tag: "diag-developer")
        fixture.write(
            "\(DeveloperIndexDiagnosticProvider.derivedDataPath)/Project-abc/Index.noindex/data/file.bin",
            bytes: 4096
        )

        let batch = await DeveloperIndexDiagnosticProvider().analyze(
            StorageDiagnosticContext(roots: [], homeDirectory: fixture.url)
        )

        let index = batch.findings.first { $0.displayName.contains("Index.noindex") }
        XCTAssertNotNil(index)
        XCTAssertEqual(index?.status, .rebuildable)
        XCTAssertEqual(index?.remediation, .rebuild(.owningApplication))
        let container = batch.findings.first { $0.displayName == "DerivedData" }
        XCTAssertEqual(container?.status, .unknown, "the container is shown, not judged removable")
    }

    func test_developerIndexReportsTheContainerWhenThereIsNoIndexInside() async {
        let fixture = TemporaryDirectory(tag: "diag-developer-plain")
        fixture.write(
            "\(DeveloperIndexDiagnosticProvider.derivedDataPath)/Project-abc/Build/products.bin",
            bytes: 4096
        )

        let batch = await DeveloperIndexDiagnosticProvider().analyze(
            StorageDiagnosticContext(roots: [], homeDirectory: fixture.url)
        )

        XCTAssertEqual(batch.findings.map(\.displayName), ["DerivedData"])
        XCTAssertEqual(batch.findings[0].status, .unknown)
    }

    func test_theSpotlightProviderFindsAVolumeStore() async {
        let fixture = TemporaryDirectory(tag: "diag-spotlight")
        fixture.write("\(SpotlightDiagnosticProvider.storeName)/store.db", bytes: 4096)

        let context = StorageDiagnosticContext(
            roots: [DiagnosticRoot(url: fixture.url, kind: .volume)],
            homeDirectory: home
        )
        let batch = await SpotlightDiagnosticProvider().analyze(context)

        XCTAssertEqual(batch.findings.count, 1)
        XCTAssertEqual(batch.findings[0].category, .spotlightIndex)
        XCTAssertEqual(batch.findings[0].status, .rebuildable)
        XCTAssertEqual(batch.findings[0].remediation, .rebuild(.spotlight))
    }

    func test_theSpotlightProviderIgnoresAVolumeWithoutAStore() async {
        let fixture = TemporaryDirectory(tag: "diag-spotlight-absent")

        let batch = await SpotlightDiagnosticProvider().analyze(
            StorageDiagnosticContext(
                roots: [DiagnosticRoot(url: fixture.url, kind: .volume)],
                homeDirectory: home
            )
        )

        XCTAssertTrue(batch.findings.isEmpty)
    }

    func test_snapshotQueriesThatCannotBeAnsweredMakeTheReportPartial() async {
        let batch = await APFSSnapshotProvider().analyze(
            StorageDiagnosticContext(
                roots: [DiagnosticRoot(url: URL(fileURLWithPath: "/nonexistent-volume"), kind: .volume)],
                homeDirectory: home
            )
        )

        // The system refused the question, so the space snapshots hold is simply
        // not accounted for. That is a partial answer, not a clean bill.
        XCTAssertEqual(batch.coverage, .partial)
        XCTAssertTrue(batch.findings.isEmpty)
    }

    func test_aVolumeWithoutSnapshotsProducesNoFinding() async {
        let fixture = TemporaryDirectory(tag: "diag-snapshots")

        let batch = await APFSSnapshotProvider().analyze(
            StorageDiagnosticContext(
                roots: [DiagnosticRoot(url: fixture.url, kind: .volume)],
                homeDirectory: home
            )
        )

        XCTAssertTrue(batch.findings.isEmpty)
        XCTAssertEqual(batch.coverage, .complete, "the query was answered, with nothing to report")
    }

    func test_aSnapshotFindingIsProtectedAndInventsNoSize() {
        let finding = StorageFinding(
            providerID: "apfsSnapshots",
            path: URL(fileURLWithPath: "/"),
            displayName: "Macintosh HD",
            category: .filesystemSnapshot,
            status: .protected,
            allocatedBytes: 0,
            fileCount: 3,
            explanationKey: .diagnosticsExplanationSnapshots,
            remediation: .inspectOnly,
            isProtected: true,
            isApproximate: true
        )

        XCTAssertFalse(finding.status.allowsTrashAction)
        XCTAssertEqual(finding.allocatedBytes, 0, "no per-snapshot size is reported by the system")
        XCTAssertEqual(finding.fileCount, 3)
        XCTAssertTrue(finding.isApproximate)
    }

    func test_theStandardProvidersOfferNothingForRemovalOnTheirOwn() async {
        // None of the phase-one and phase-two providers proposes a Trash action:
        // they discover and explain. A `cleanable` finding has to be an explicit
        // statement, and nothing here makes one (§2.2).
        let fixture = TemporaryDirectory(tag: "diag-standard")
        fixture.write("Library/Caches/com.example.app/blob.bin", bytes: 4096)

        let report = await StorageDiagnosticEngine().analyze(
            roots: [DiagnosticRoot(url: fixture.url, kind: .volume)],
            homeDirectory: fixture.url,
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
        )

        XCTAssertTrue(report.cleanableFindings.isEmpty)
        XCTAssertTrue(report.findings.allSatisfy { $0.remediation != .trash })
    }

    // MARK: - System queries

    func test_snapshotNamesAndDatesAreParsed() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-17-120000.local
        com.apple.TimeMachine.2026-10-16-083000.local
        something-else
        """

        let snapshots = SystemQuery.parseSnapshots(output)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].name, "com.apple.TimeMachine.2026-10-17-120000.local")
        XCTAssertNotNil(snapshots[0].createdAt)
    }

    func test_aMissingToolIsNotAnAnswer() {
        let outcome = SystemQuery.run("/usr/bin/definitely-not-installed", ["-s", "/"])

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.output.isEmpty)
    }

    func test_spotlightStateIsUnknownWhenTheToolCannotAnswer() {
        XCTAssertEqual(
            SystemQuery.spotlightState(ofVolumeAt: "/definitely/not/a/volume"),
            .unknown
        )
        XCTAssertEqual(SystemQuery.spotlightState(ofVolumeAt: "not/absolute"), .unknown)
    }
}
