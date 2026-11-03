import Foundation
import XCTest
@testable import Core
import Shared

/// Application discovery and the association rules the uninstaller uses (§5.3).
///
/// The uninstaller removes confirmed files without a per-row confirmation, so a
/// fuzzy name match must never reach that set. These tests pin the difference
/// between an identifier match and a plausible one.
final class ApplicationDiscoveryTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "discovery")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private func makeDiscovery() -> ApplicationDiscovery {
        ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            // No signature is read by default: a test that wants the entitlement
            // answer says so with its own reader, so no test depends on what is
            // installed on the machine running it.
            readAppGroups: { _ in [] }
        )
    }

    private func application(
        name: String = "Notes",
        identifier: String = "com.vendor.notes"
    ) -> InstalledApplication {
        InstalledApplication(
            url: fixture.url.appendingPathComponent("Applications/Notes.app"),
            name: name,
            bundleIdentifier: identifier,
            version: "1.0",
            sizeInBytes: 4096,
            lastUsed: .unavailable,
            installedAt: nil,
            isSystemApplication: false,
            isRunning: false
        )
    }

    func test_discoverySearchesTheSystemApplicationDirectories() {
        // System applications are listed and marked uninstallable-protected. A
        // directory that is not searched cannot be listed at all.
        let paths = makeDiscovery().searchDirectories.map(\.path)
        XCTAssertTrue(paths.contains("/System/Applications"))
        XCTAssertTrue(paths.contains("/System/Applications/Utilities"))
    }

    func test_anApplicationNestedInAVendorFolderIsStillInstalled() async {
        _ = fixture.directory("Vendor/Notes.app/Contents")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key><string>com.vendor.notes</string>
          <key>CFBundleName</key><string>Notes</string>
          <key>CFBundleExecutable</key><string>Notes</string>
        </dict>
        </plist>
        """
        fixture.writeBytes("Vendor/Notes.app/Contents/Info.plist", Data(plist.utf8))
        fixture.write("Vendor/Notes.app/Contents/MacOS/Notes", bytes: 0)

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url],
            includeDefaultDirectories: false
        )

        let applications = await discovery.installedApplications()
        XCTAssertTrue(
            applications.contains { $0.bundleIdentifier == "com.vendor.notes" },
            "a nested .app must be listed, or its live data looks like residue"
        )
        let identifiers = await discovery.installedBundleIdentifiers()
        XCTAssertTrue(identifiers.contains("com.vendor.notes"))
    }

    /// The Apps page sorts by install date, so discovery has to report one.
    ///
    /// The bundle directory's birth time is what an install leaves behind. The
    /// fixture writes the bundle itself, so the date it must report is the moment
    /// this test created it — a bundle that reported no date, or the epoch, would
    /// sort every row to the bottom of an "install date" list.
    func test_discoveryReportsWhenTheBundleArrived() async {
        let before = Date()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key><string>com.vendor.fresh</string>
          <key>CFBundleName</key><string>Fresh</string>
          <key>CFBundleExecutable</key><string>Fresh</string>
        </dict>
        </plist>
        """
        fixture.writeBytes("Vendor/Fresh.app/Contents/Info.plist", Data(plist.utf8))

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url],
            includeDefaultDirectories: false
        )

        let applications = await discovery.installedApplications()
        guard let fresh = applications.first(where: { $0.bundleIdentifier == "com.vendor.fresh" }) else {
            return XCTFail("the fixture bundle was not discovered")
        }
        guard let installedAt = fresh.installedAt else {
            return XCTFail("an installed bundle must report when it arrived")
        }
        XCTAssertGreaterThanOrEqual(installedAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(installedAt, Date().addingTimeInterval(60))
    }

    private let freshBundlePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key><string>com.vendor.launch</string>
      <key>CFBundleName</key><string>Launch</string>
      <key>CFBundleExecutable</key><string>Launch</string>
    </dict>
    </plist>
    """

    /// The launch record and the install date are two different facts.
    ///
    /// They used to be read from one object — the bundle directory's birth time and
    /// its access time — and macOS does not update a directory's access time when an
    /// application is launched (the program writes to files *inside* the bundle, and
    /// the volume is mounted without access-time updates). So the page reported the
    /// copy's timestamp twice: an application installed four days ago and opened
    /// this morning said "installed four days ago, last opened four days ago", and
    /// an application opened daily for a year said it had not been opened since it
    /// was installed. The launch is now the record LaunchServices writes, read from
    /// the Spotlight index, and this test pins that the two answers come from two
    /// sources.
    func test_theLaunchRecordIsReadFromTheSystemAndNotFromTheBundlesFileTimes() async {
        fixture.writeBytes("Vendor/Launch.app/Contents/Info.plist", Data(freshBundlePlist.utf8))
        let launch = Date(timeIntervalSince1970: 1_800_000_000)

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url],
            includeDefaultDirectories: false,
            readRecord: { _ in ApplicationDiscovery.SystemRecord(lastUsed: .known(launch)) }
        )

        let applications = await discovery.installedApplications()
        guard let application = applications.first(where: { $0.bundleIdentifier == "com.vendor.launch" }) else {
            return XCTFail("the fixture bundle was not discovered")
        }
        XCTAssertEqual(application.lastUsed, .known(launch))
        XCTAssertEqual(application.lastUsedAt, launch)
        XCTAssertNotEqual(
            application.installedAt,
            application.lastUsedAt,
            "the install date is the bundle's own history, not the launch record"
        )
    }

    /// A bundle the index holds no record of is not a bundle that never ran.
    ///
    /// The two missing answers are kept apart because only one of them is a claim
    /// about use: "never opened" is a statement about the system's record, and an
    /// unindexed volume, indexing turned off or a bundle installed seconds ago
    /// gives no record to make it from.
    func test_aBundleWithNoIndexRecordIsNotReportedAsNeverOpened() async {
        fixture.writeBytes("Vendor/Launch.app/Contents/Info.plist", Data(freshBundlePlist.utf8))

        func discovery(_ record: LastUsedRecord) -> ApplicationDiscovery {
            ApplicationDiscovery(
                rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
                additionalDirectories: [fixture.url],
                includeDefaultDirectories: false,
                readRecord: { _ in ApplicationDiscovery.SystemRecord(lastUsed: record) }
            )
        }

        let unknown = await discovery(.unavailable).installedApplications()
            .first { $0.bundleIdentifier == "com.vendor.launch" }
        XCTAssertEqual(unknown?.lastUsed, .unavailable)
        XCTAssertNil(unknown?.lastUsedAt)
        XCTAssertEqual(unknown?.formattedLastUsed, LocalizationKey.appsLastUsedUnknown.localized)

        let never = await discovery(.neverOpened).installedApplications()
            .first { $0.bundleIdentifier == "com.vendor.launch" }
        XCTAssertEqual(never?.lastUsed, .neverOpened)
        XCTAssertEqual(never?.formattedLastUsed, LocalizationKey.appsNeverOpened.localized)
        XCTAssertNotEqual(unknown?.formattedLastUsed, never?.formattedLastUsed)
    }

    /// The install date comes from the record that survives an update.
    ///
    /// The bundle directory's birth time was the install date, and it answers the
    /// wrong question for the one case users ask about: an application that updates
    /// itself. This test gives the record an arrival date the bundle itself does not
    /// carry — the bundle was written by the fixture, so it was born moments ago —
    /// and the reported install date has to be the arrival, not the birth.
    func test_theInstallDatePrefersTheRecordThatSaysWhenTheItemArrived() async {
        fixture.writeBytes("Vendor/Launch.app/Contents/Info.plist", Data(freshBundlePlist.utf8))
        let arrived = Date(timeIntervalSince1970: 1_700_000_000)

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url],
            includeDefaultDirectories: false,
            readRecord: { _ in ApplicationDiscovery.SystemRecord(lastUsed: .unavailable, dateAdded: arrived) }
        )

        let applications = await discovery.installedApplications()
        guard let application = applications.first(where: { $0.bundleIdentifier == "com.vendor.launch" }) else {
            return XCTFail("the fixture bundle was not discovered")
        }
        XCTAssertEqual(
            application.installedAt,
            arrived,
            "the arrival record must outrank the birth time of the directory an update replaced"
        )
        XCTAssertEqual(application.installedAt, arrived)
    }

    /// An application that updated itself yesterday is not a new installation.
    ///
    /// This is the shape that made the two dates look like one field: an in-place
    /// update rewrites the bundle's contents, and a store update swaps the whole
    /// bundle, so the birth time is "the last time anything touched it" while the
    /// arrival record still says when the user actually installed it. The order the
    /// Apps page offers ("install date, newest first") has to rank by the second.
    func test_anApplicationUpdatedInPlaceIsStillAsOldAsTheDayItArrived() async {
        fixture.writeBytes("Vendor/Launch.app/Contents/Info.plist", Data(freshBundlePlist.utf8))
        let arrived = Date(timeIntervalSinceNow: -400 * 86_400)

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url],
            includeDefaultDirectories: false,
            readRecord: { _ in ApplicationDiscovery.SystemRecord(lastUsed: .neverOpened, dateAdded: arrived) }
        )

        let applications = await discovery.installedApplications()
        guard let application = applications.first(where: { $0.bundleIdentifier == "com.vendor.launch" }) else {
            return XCTFail("the fixture bundle was not discovered")
        }
        XCTAssertEqual(application.installedAt, arrived)
        XCTAssertNotEqual(application.installedAt, application.lastUsedAt)
        XCTAssertTrue(
            application.isUnused(now: Date(), thresholdDays: 180),
            "an application installed 400 days ago and never opened is unused, however new its bundle is"
        )
    }

    func test_onlyAnIdentifierMatchIsConfirmed() {
        fixture.write("Library/Application Support/com.vendor.notes/data.bin", bytes: 4096)
        fixture.write("Library/Application Support/notes/data.bin", bytes: 4096)
        fixture.write("Library/Preferences/com.vendor.notes.plist", bytes: 256)
        _ = fixture.directory("Library/Group Containers/com.vendor.notes")

        let plan = makeDiscovery().relatedFiles(for: application())

        XCTAssertTrue(
            plan.confirmedFiles.contains { $0.displayName == "com.vendor.notes" },
            "the full bundle identifier is an unambiguous match"
        )
        XCTAssertTrue(
            plan.confirmedFiles.contains { $0.displayName == "com.vendor.notes.plist" }
        )
        XCTAssertFalse(
            plan.confirmedFiles.contains { $0.displayName == "notes" },
            "another application can use the same name; it must not be removed automatically"
        )
        XCTAssertTrue(
            plan.reviewFiles.contains { $0.displayName == "notes" },
            "the name match is still shown for the user to judge"
        )
        XCTAssertTrue(
            plan.reviewFiles.contains { $0.displayName == "com.vendor.notes" },
            "a shared container is always a review candidate"
        )
    }

    /// A group container is `<team-id>.<identifier>`, and the uninstaller has to
    /// read that spelling.
    ///
    /// It compared the whole name against the identifier, so the team prefix hid
    /// every group container: the scan knew what the directory was and the
    /// uninstaller did not, which is the one place the two must agree. The
    /// location's own confidence keeps the answer at "review" — two applications
    /// from one team can share a group — but the row is now shown at all.
    func test_aTeamPrefixedGroupContainerBelongsToItsApplication() {
        _ = fixture.directory("Library/Group Containers/6N38VWS5BX.com.vendor.notes")
        _ = fixture.directory("Library/Group Containers/group.com.vendor.notes")
        _ = fixture.directory("Library/Group Containers/6N38VWS5BX.com.other.app")

        let plan = makeDiscovery().relatedFiles(for: application())

        let names = Set(plan.reviewFiles.map(\.displayName))
        XCTAssertTrue(
            names.contains("6N38VWS5BX.com.vendor.notes"),
            "a team-prefixed container names the application after the team id"
        )
        XCTAssertTrue(
            names.contains("group.com.vendor.notes"),
            "an app group prefixes `group.`, which is the same reading"
        )
        XCTAssertFalse(
            names.contains("6N38VWS5BX.com.other.app"),
            "another application's container must not be associated"
        )
        XCTAssertTrue(
            plan.confirmedFiles.allSatisfy { $0.displayName != "6N38VWS5BX.com.vendor.notes" },
            "a shared container is never removed without the user seeing it"
        )
    }

    /// A group container whose name belongs to another installed application
    /// says so on the row.
    ///
    /// A container is matched to an application by name: exactly, by suffix, or
    /// under `<identifier>.`. The last spelling is how a helper's container is
    /// claimed for its parent application — and when the helper is installed
    /// separately, removing the container with the parent takes data the helper
    /// still uses. The row names the other application; it is a fact read from
    /// LaunchServices, not a guess.
    func test_aContainerNamedAfterAnotherInstalledApplicationIsMarkedShared() {
        _ = fixture.directory("Library/Group Containers/com.vendor.notes.Helper")
        _ = fixture.directory("Library/Group Containers/com.vendor.notes")

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            // Readings arrive lower-cased, which is how the scanners compare
            // them; LaunchServices itself does not care about case.
            appNameForBundleIdentifier: { identifier in
                identifier.lowercased() == "com.vendor.notes.helper" ? "Notes Helper" : nil
            },
            readAppGroups: { _ in [] }
        )

        let plan = discovery.relatedFiles(for: application())

        let helper = plan.reviewFiles.first {
            $0.displayName == "com.vendor.notes.Helper"
        }
        XCTAssertEqual(
            helper?.sharedWith,
            ["Notes Helper"],
            "the installed application the container is named after is named on the row"
        )

        let plain = plan.reviewFiles.first { $0.displayName == "com.vendor.notes" }
        XCTAssertEqual(
            plain?.sharedWith,
            [],
            "a container nothing else answers for names no other application"
        )
    }

    /// Only a group container can be shared; a private container is one
    /// application's own data however its name is spelled.
    func test_aPrivateContainerIsNeverMarkedShared() {
        _ = fixture.directory("Library/Containers/com.vendor.notes.Helper")

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            appNameForBundleIdentifier: { _ in "Notes Helper" },
            readAppGroups: { _ in [] }
        )
        let plan = discovery.relatedFiles(for: application())

        XCTAssertTrue(plan.reviewFiles.allSatisfy { $0.sharedWith.isEmpty })
        XCTAssertTrue(plan.confirmedFiles.allSatisfy { $0.sharedWith.isEmpty })
    }

    /// A group container shared by two applications is found through the
    /// entitlement, not through the name.
    ///
    /// The container is named after the group, so neither application is in the
    /// name and no name reading can reach it: this is exactly the case the
    /// identifier lookup cannot answer. The row names the other application
    /// because both bundles declare the group, which is a fact read from their
    /// signatures.
    func test_aGroupContainerSharedByAnotherApplicationIsFoundThroughItsEntitlement() {
        _ = fixture.directory("Library/Group Containers/group.com.vendor.shared")
        _ = fixture.directory("Applications/Notes Helper.app")

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url.appendingPathComponent("Applications")],
            includeDefaultDirectories: false,
            appNameForBundleIdentifier: { _ in nil },
            // Both bundles declare the group — including the application being
            // uninstalled, which must not name itself on its own row.
            readAppGroups: { _ in ["GROUP.com.vendor.shared"] }
        )

        let plan = discovery.relatedFiles(for: application())

        let shared = plan.reviewFiles.first { $0.displayName == "group.com.vendor.shared" }
        XCTAssertEqual(
            shared?.sharedWith,
            ["Notes Helper"],
            "the other application declaring the group is named on the row"
        )
        XCTAssertEqual(
            shared?.confidence,
            .needsReview,
            "a shared container is never removed without the user seeing it"
        )
        XCTAssertEqual(
            shared?.reason,
            .appGroup,
            "the reason names the entitlement rather than a name that does not exist"
        )
        XCTAssertEqual(
            shared?.groupIdentifier,
            "group.com.vendor.shared",
            "the row can show the group id it was matched by"
        )
        XCTAssertNil(
            plan.reviewFiles.first { $0.displayName == "Notes Helper.app" }?.groupIdentifier
        )
    }

    /// A container whose group nothing declares names nobody.
    ///
    /// The entitlement read is an answer, not a guess: when no installed bundle
    /// declares the group, the row keeps its name-only evidence and says nothing
    /// about other applications.
    func test_aContainerWhoseGroupNothingDeclaresNamesNobody() {
        _ = fixture.directory("Library/Group Containers/group.com.vendor.shared")
        _ = fixture.directory("Applications/Notes Helper.app")

        let discovery = ApplicationDiscovery(
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url),
            additionalDirectories: [fixture.url.appendingPathComponent("Applications")],
            includeDefaultDirectories: false,
            appNameForBundleIdentifier: { _ in nil },
            readAppGroups: { _ in [] }
        )

        let plan = discovery.relatedFiles(for: application())
        XCTAssertTrue(plan.reviewFiles.allSatisfy { $0.sharedWith.isEmpty })
    }

    func test_theConfirmationTotalIncludesTheReviewFilesTheUserChose() {
        let plan = UninstallPlan(
            application: application(),
            confirmedFiles: [
                RelatedFile(
                    url: fixture.url.appendingPathComponent("Library/Caches/com.vendor.notes"),
                    sizeInBytes: 100,
                    confidence: .confirmed,
                    reason: .bundleIdentifier
                )
            ],
            reviewFiles: [
                RelatedFile(
                    url: fixture.url.appendingPathComponent("Library/Caches/notes"),
                    sizeInBytes: 250,
                    confidence: .needsReview,
                    reason: .applicationName
                )
            ]
        )

        XCTAssertEqual(plan.totalBytes, 4096 + 100)
        XCTAssertEqual(plan.totalBytes(includeReviewFiles: true), 4096 + 100 + 250)
        XCTAssertEqual(plan.selectedItems(includeReviewFiles: true).count, 3)
    }
}
