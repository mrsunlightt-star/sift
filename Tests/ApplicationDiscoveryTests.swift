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
            rules: RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: fixture.url)
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
            lastUsedAt: nil,
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
