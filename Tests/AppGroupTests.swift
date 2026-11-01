import Foundation
import XCTest
@testable import Core

/// The entitlement map behind the uninstaller's shared-container rows.
///
/// The interesting properties are all about what the registry refuses to invent:
/// it answers only for groups an installed bundle declares, it reads each bundle
/// once, and it never names the application whose page is open.
final class AppGroupTests: XCTestCase, @unchecked Sendable {
    private var fixture: TemporaryDirectory!
    /// How many bundles the reader was asked about. Read from the test only.
    private let reads = Counter()
    /// What each bundle declares. Mutable so a test can install an application
    /// after the registry was built, which is the case the fingerprint exists for.
    private let declarations = Declarations()

    override func setUp() {
        super.setUp()
        fixture = TemporaryDirectory(tag: "appgroups")
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    private var applicationsDirectory: URL {
        fixture.url.appendingPathComponent("Applications", isDirectory: true)
    }

    private func makeRegistry(_ starting: [String: Set<String>]) -> AppGroupRegistry {
        for (name, groups) in starting {
            install(name, groups)
        }
        return AppGroupRegistry(
            applicationDirectories: [applicationsDirectory],
            read: { url in
                self.reads.value += 1
                return self.declarations.groups(of: url.lastPathComponent)
            }
        )
    }

    /// Creates one application bundle and records what it declares.
    private func install(_ name: String, _ groups: Set<String>) {
        declarations.set(groups, for: name)
        try? FileManager.default.createDirectory(
            at: applicationsDirectory.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func test_theApplicationsDeclaringAGroupAreListedInNameOrder() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.notes", "group.com.vendor.helper"],
        ])

        XCTAssertEqual(
            registry.applications(declaring: "group.com.vendor.notes"),
            ["Notes", "Notes Helper"]
        )
        XCTAssertFalse(registry.applications(declaring: "group.com.vendor.notes").isEmpty)
        XCTAssertTrue(registry.applications(declaring: "group.com.vendor.unknown").isEmpty)
    }

    /// A group id is a file name, so the case it is written in is not significant.
    func test_aGroupIsMatchedWhateverCaseItIsWrittenIn() {
        let registry = makeRegistry(["Notes.app": ["GROUP.com.vendor.Notes"]])

        XCTAssertFalse(registry.applications(declaring: "group.com.vendor.notes").isEmpty)
        XCTAssertEqual(
            registry.applications(declaring: "Group.Com.Vendor.Notes", excluding: nil),
            ["Notes"]
        )
    }

    /// The application whose page is open is never named as another sharer.
    func test_theExcludedApplicationIsDropped() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.notes"],
        ])

        XCTAssertEqual(
            registry.applications(declaring: "group.com.vendor.notes", excluding: "notes"),
            ["Notes Helper"],
            "the exclusion is by name and case-insensitive"
        )
    }

    /// Every bundle is read once, not once per question.
    func test_theSignatureIsReadOncePerBundle() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.helper"],
        ])

        _ = registry.applications(declaring: "group.com.vendor.notes")
        _ = registry.applications(declaring: "group.com.vendor.helper")
        _ = registry.applications(declaring: "group.com.vendor.notes")

        XCTAssertEqual(reads.value, 2, "two bundles, two signature reads, however many questions")
    }

    /// No declarations means no cost paid: the map is built on first use only.
    func test_theMapIsNotBuiltUntilItIsAskedFor() {
        _ = makeRegistry(["Notes.app": ["group.com.vendor.notes"]])
        XCTAssertEqual(reads.value, 0, "constructing the registry reads nothing")
    }

    /// The map is not rebuilt while the installed applications are unchanged.
    ///
    /// It costs a signature read per bundle, and a session asks many times: the
    /// scan request, every uninstaller page, every group container row.
    func test_anUnchangedMachineIsNotRebuilt() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.helper"],
        ])

        _ = registry.declaredGroups()
        _ = registry.declaredGroups()
        _ = registry.applications(declaring: "group.com.vendor.notes")

        XCTAssertEqual(registry.buildCount, 1, "three questions, one build")
        XCTAssertEqual(reads.value, 2, "and one read per bundle, not one per question")
    }

    /// Installing an application changes the answer without a relaunch.
    ///
    /// The session outlives the installation: a user who installs an application
    /// and then scans must not get the declarations of the application set that
    /// existed when Sift started.
    func test_aNewlyInstalledApplicationIsReadOnTheNextQuestion() {
        let registry = makeRegistry(["Notes.app": ["group.com.vendor.notes"]])
        XCTAssertEqual(registry.declaredGroups().identifiers, ["group.com.vendor.notes"])

        // A new bundle in the same directory is what an installation looks like
        // from here. It adds an entry, so the fingerprint changes.
        install("Notes Helper.app", ["group.com.vendor.helper"])

        XCTAssertEqual(
            registry.declaredGroups().identifiers,
            ["group.com.vendor.helper", "group.com.vendor.notes"],
            "the newly installed application's groups are part of the answer"
        )
        XCTAssertEqual(registry.buildCount, 2, "the map was rebuilt once")
    }

    /// A read that runs out of time says so instead of returning half a set.
    ///
    /// Both engines stop reporting group-container residue when the set is
    /// incomplete, because a container whose owner was not read answers "nothing
    /// declares this" and would be offered as a leftover.
    func test_aDeadlineReturnsAnIncompleteAnswerInsteadOfAPartialOne() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.helper"],
        ])

        let late = registry.declaredGroups(deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(late.identifiers.isEmpty, "half a set is not an answer")
        XCTAssertFalse(late.isComplete, "and it says so")
        XCTAssertEqual(registry.buildCount, 0, "nothing partial is cached")

        let complete = registry.declaredGroups()
        XCTAssertEqual(complete.identifiers, ["group.com.vendor.helper", "group.com.vendor.notes"])
        XCTAssertTrue(complete.isComplete, "a read that finished is complete")
        XCTAssertEqual(registry.buildCount, 1)
    }

    /// An in-place update that only rewrites files inside the bundle is noticed.
    ///
    /// Replacing `Contents/Info.plist` does not necessarily touch the bundle
    /// directory's own timestamp, and a session outlives an application update.
    /// The second signal is the one file every bundle has.
    func test_anInPlaceUpdateIsReadOnTheNextQuestion() {
        let registry = makeRegistry(["Notes.app": ["group.com.vendor.notes"]])
        let contents = applicationsDirectory
            .appendingPathComponent("Notes.app/Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        try? Data("<plist/>".utf8).write(to: plist)

        XCTAssertEqual(registry.declaredGroups().identifiers, ["group.com.vendor.notes"])
        XCTAssertEqual(registry.buildCount, 1)

        // A newer Info.plist and the new entitlements it would carry. The bundle
        // directory itself is untouched: writing a file does not change its
        // parent's modification date.
        declarations.set(["group.com.vendor.renamed"], for: "Notes.app")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: plist.path
        )

        XCTAssertEqual(
            registry.declaredGroups().identifiers,
            ["group.com.vendor.renamed"],
            "the updated application's declarations replace the old ones"
        )
        XCTAssertEqual(registry.buildCount, 2)
    }

    /// Removing an application takes its declarations with it.
    func test_aRemovedApplicationStopsDeclaringItsGroups() {
        let registry = makeRegistry([
            "Notes.app": ["group.com.vendor.notes"],
            "Notes Helper.app": ["group.com.vendor.helper"],
        ])
        XCTAssertEqual(registry.declaredGroups().identifiers.count, 2)

        try? FileManager.default.removeItem(
            at: applicationsDirectory.appendingPathComponent("Notes Helper.app")
        )

        XCTAssertEqual(
            registry.declaredGroups().identifiers,
            ["group.com.vendor.notes"],
            "an uninstalled application declares nothing"
        )
    }
}

/// What each fixture bundle declares, mutable across a build.
private final class Declarations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Set<String>] = [:]

    func set(_ groups: Set<String>, for name: String) {
        lock.lock()
        storage[name] = groups
        lock.unlock()
    }

    func groups(of name: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage[name] ?? []
    }
}

/// A box the reader closure can increment.
///
/// The registry calls its reader from whichever thread asks first, so the counter
/// is guarded rather than assumed to be single-threaded.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
