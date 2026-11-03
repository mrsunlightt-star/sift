import Foundation
import XCTest
@testable import Core
import Shared

/// The exception an uninstall makes to the `/Applications` protection.
///
/// These tests pin the shape of that exception rather than the feature built on
/// it: the guard is what decides whether a path may leave `/Applications` at all,
/// and it used to answer "yes" for every path under that directory. Each refusal
/// case is produced here by a fixture that really has the shape it names, so a
/// change to the order of the checks or to one of them shows up as a failing
/// test rather than as a wider exception.
///
/// `/Applications` itself cannot be created inside a fixture — it is a real
/// directory on the boot volume, and a test that wrote there would be modifying
/// the machine running it. The parent comparison is therefore exercised through
/// `refusal(for:applicationsDirectory:)`, the internal seam the public entry
/// point delegates to, with the fixture's own directory standing in for it; the
/// paths themselves go through the production code unchanged.
final class ApplicationBundleGuardTests: XCTestCase, @unchecked Sendable {
    private typealias Refusal = ApplicationBundleGuard.Refusal

    private var fixture: TemporaryDirectory!

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "bundle-guard")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A bundle laid out the way macOS lays one out, below the fixture that stands
    /// in for `/Applications`.
    ///
    /// `identifier` is optional so the same helper can produce a bundle whose
    /// `Info.plist` has no `CFBundleIdentifier` at all: the refusal cases differ
    /// only in content, and a second helper would let the two drift.
    private func bundle(
        _ relativePath: String = "Notes.app",
        identifier: String? = "com.vendor.notes"
    ) -> URL {
        fixture.directory("\(relativePath)/Contents")
        if let identifier = identifier {
            fixture.writeBytes("\(relativePath)/Contents/Info.plist", plist(identifier))
        }
        return fixture.url.appendingPathComponent(relativePath)
    }

    private func plist(_ identifier: String) -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(identifier)</string>
        </dict>
        </plist>
        """
        return Data(document.utf8)
    }

    /// The refusal for a URL whose parent is the fixture directory.
    private func refusal(_ url: URL) -> ApplicationBundleGuard.Refusal? {
        ApplicationBundleGuard.refusal(for: url, applicationsDirectory: fixture.url.path)
    }

    /// The refusal for a path spelled against the fixture's own directory, which
    /// is where a fixture bundle actually lives.
    private func refusal(ofFixturePath path: String) -> Refusal? {
        ApplicationBundleGuard.refusal(
            for: URL(fileURLWithPath: path),
            applicationsDirectory: fixture.url.path
        )
    }

    /// The refusal for a path spelled the way an item in the real `/Applications`
    /// arrives, with no disk access behind it.
    private func refusal(ofPath path: String) -> Refusal? {
        ApplicationBundleGuard.refusal(
            for: URL(fileURLWithPath: path),
            applicationsDirectory: "/Applications"
        )
    }

    // MARK: - The accept case

    func test_aBundleDirectlyInsideTheApplicationsDirectoryIsAccepted() {
        let application = bundle()

        XCTAssertNil(refusal(application))
    }

    /// The bundle's name decides the suffix, not the case it is written in.
    ///
    /// macOS volumes are case-insensitive by default, so `Notes.APP` is the same
    /// bundle as `Notes.app` and a case-sensitive suffix test would refuse an
    /// application the Finder shows as an application.
    func test_theBundleSuffixIsMatchedWithoutCase() {
        let application = bundle("Loud.APP")

        XCTAssertNil(refusal(application))
    }

    /// The parent comparison is lexical and collapses the path first.
    ///
    /// An item's path arrives from a scan result rather than from the
    /// `URL(fileURLWithPath:)` a UI would build, so a redundant separator or a
    /// `..` component can be in it. Comparing spellings would refuse a bundle that
    /// is directly inside the directory, which is a refusal the user cannot act
    /// on.
    func test_theParentComparisonCollapsesThePathBeforeMatching() {
        _ = bundle()

        XCTAssertNil(refusal(ofFixturePath: "\(fixture.url.path)//Notes.app"))
        XCTAssertNil(refusal(ofFixturePath: "\(fixture.url.path)/Unused/../Notes.app"))
    }

    // MARK: - The path-shape refusals

    func test_aPathThatDoesNotNameAnApplicationBundleIsRefused() {
        XCTAssertEqual(refusal(ofPath: "/Applications/Utilities"), Refusal.notAnApplicationBundle)
        XCTAssertEqual(refusal(ofPath: "/Applications/notes.txt"), Refusal.notAnApplicationBundle)
    }

    /// A path inside a bundle is not the bundle.
    ///
    /// `/Applications/Foo.app/Contents/MacOS/Foo` is what an associated-file match
    /// sometimes produces, and moving it would take the executable out of a bundle
    /// that stays behind.
    func test_aPathInsideABundleIsNotTheBundle() {
        XCTAssertEqual(
            refusal(ofPath: "/Applications/Foo.app/Contents/MacOS/Foo"),
            .notAnApplicationBundle
        )
        XCTAssertEqual(refusal(ofPath: "/Applications/Foo.app/Contents"), Refusal.notAnApplicationBundle)
    }

    /// A bundle anywhere but directly in `/Applications` is refused, even when
    /// the path looks like one.
    ///
    /// A vendor subfolder, a mounted volume and Apple's own application directory
    /// are the three shapes that arrive this way. The exception is keyed to one
    /// directory, and a second spelling of it would widen the exception without
    /// anybody deciding to.
    func test_aBundleThatIsNotDirectlyInApplicationsIsRefused() {
        for path in [
            "/Applications/Sub/Foo.app",
            "/Volumes/Backup/Foo.app",
            "/System/Applications/Foo.app",
            "/System/Applications/Utilities/Foo.app",
        ] {
            XCTAssertEqual(refusal(ofPath: path), Refusal.notDirectlyInApplications, path)
        }
    }

    // MARK: - The disk identity

    /// A link standing where a bundle was selected is refused.
    ///
    /// The move acts on the object, not on a name that resolves to something else:
    /// `trashItem` follows a link, so a link here would move the bundle it points
    /// at — including one outside `/Applications` that this guard never judged.
    func test_aSymlinkedBundleIsRefused() {
        let real = bundle("Real/Notes.app")
        let link = fixture.url.appendingPathComponent("Notes.app")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(refusal(link), .notADirectory,
                       "the link is the object at the selected path; its target was never the item")
    }

    func test_aBundleThatIsAPlainFileIsNotADirectory() {
        fixture.write("Stray.app", bytes: 4096)

        XCTAssertEqual(refusal(fixture.url.appendingPathComponent("Stray.app")), Refusal.notADirectory)
    }

    // MARK: - The identifier

    func test_aBundleWithoutAnInfoPlistHasNoIdentifier() {
        let application = bundle("Empty.app", identifier: nil)

        XCTAssertEqual(refusal(application), Refusal.missingBundleIdentifier)
    }

    /// An `Info.plist` with no identifier key is as missing as no file at all.
    func test_aPlistWithoutTheIdentifierKeyIsMissingItsIdentifier() {
        fixture.directory("Anonymous.app/Contents")
        fixture.writeBytes(
            "Anonymous.app/Contents/Info.plist",
            Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleName</key><string>Anonymous</string></dict></plist>
            """.utf8)
        )

        XCTAssertEqual(
            refusal(fixture.url.appendingPathComponent("Anonymous.app")),
            Refusal.missingBundleIdentifier
        )
    }

    /// Bytes that are not a property list are a refusal, not a crash.
    ///
    /// A truncated copy is how a damaged bundle actually arrives, and the guard is
    /// called from pre-flight and again before the move: a throw from here would
    /// turn a single unreadable application into a failed batch.
    func test_anUnreadablePlistIsARefusalAndNotACrash() {
        fixture.directory("Damaged.app/Contents")
        fixture.writeBytes("Damaged.app/Contents/Info.plist", Data([0x00, 0x01, 0x02, 0xFF]))

        XCTAssertEqual(
            refusal(fixture.url.appendingPathComponent("Damaged.app")),
            Refusal.missingBundleIdentifier
        )
    }

    /// An identifier that is only whitespace states nothing.
    ///
    /// Trimming is what makes that true: `   ` is not an identifier, and treating
    /// it as one would hand the rest of the uninstaller an empty string to match
    /// associated files against.
    func test_aWhitespaceIdentifierIsMissing() {
        let application = bundle("Blank.app", identifier: "   ")

        XCTAssertEqual(refusal(application), Refusal.missingBundleIdentifier)
    }

    func test_anAppleIdentifierIsRefusedAsASystemApplication() {
        let application = bundle("Safari.app", identifier: "com.apple.Safari")

        XCTAssertEqual(refusal(application), Refusal.systemApplication)
    }

    /// The Apple check folds case, because an identifier is written by hand.
    ///
    /// `COM.APPLE.Notes` names the same application as `com.apple.Notes`, and a
    /// case-sensitive prefix test would offer a system application for removal.
    func test_theAppleIdentifierCheckFoldsCase() {
        let application = bundle("NotesSystem.app", identifier: "COM.APPLE.Notes")

        XCTAssertEqual(refusal(application), Refusal.systemApplication)
    }

    /// A vendor identifier that merely contains `com.apple.` is not Apple's.
    ///
    /// The prefix is the whole test: `com.vendor.com.apple.lookalike` is a
    /// third-party bundle whose name borrows the prefix, and refusing it would
    /// make an installed application impossible to uninstall.
    func test_anIdentifierThatMerelyContainsTheApplePrefixIsAccepted() {
        let application = bundle("Lookalike.app", identifier: "com.vendor.com.apple.lookalike")

        XCTAssertNil(refusal(application))
    }

    // MARK: - The published answers

    func test_isUninstallableIsTheAbsenceOfARefusal() {
        let application = bundle()

        for url in [application, URL(fileURLWithPath: "/etc/hosts"), URL(fileURLWithPath: "/")] {
            XCTAssertEqual(
                ApplicationBundleGuard.isUninstallable(url),
                ApplicationBundleGuard.refusal(for: url) == nil,
                url.path
            )
        }
        XCTAssertFalse(ApplicationBundleGuard.isUninstallable(application),
                       "a fixture bundle is not under the real /Applications")
    }

    /// Every refusal this guard can return is one the tests above produce, and a
    /// new case has to be given a spelling and a test rather than appearing in an
    /// exception nobody re-read.
    func test_theRefusalSetIsTheOneCoveredHere() {
        XCTAssertEqual(
            ApplicationBundleGuard.Refusal.allCases.map(\.rawValue),
            [
                "notAnApplicationBundle",
                "notDirectlyInApplications",
                "notADirectory",
                "missingBundleIdentifier",
                "systemApplication",
            ]
        )
    }
}
