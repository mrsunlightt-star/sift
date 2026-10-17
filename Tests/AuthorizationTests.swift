import Foundation
import XCTest
@testable import Core
import Shared

/// Stands in for the security-scoped bookmark machinery.
///
/// A real bookmark cannot be minted outside a signed, entitled app, so the launch
/// path — which is where a stored grant is re-validated — would otherwise be
/// untestable. This coder maps `Data` to a fixed set of paths, so a test can
/// present the service with exactly the grants an older build could have stored.
private struct FakeBookmarkCoder: BookmarkCoder {
    /// Bookmark payload to the path it resolves to.
    var paths: [String: String]
    /// Paths whose bookmark resolves but is stale.
    var stale: Set<String> = []
    /// Paths whose bookmark no longer resolves at all.
    var unresolvable: Set<String> = []
    /// Records what `makeBookmark` was asked for, in order.
    let log = BookmarkLog()

    func makeBookmark(for url: URL) throws -> Data {
        log.record(url.path)
        return Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: bookmark, encoding: .utf8),
              paths[path] != nil,
              !unresolvable.contains(path) else {
            throw BookmarkUnavailable()
        }
        return (URL(fileURLWithPath: path), stale.contains(path))
    }
}

/// A bookmark that cannot be reopened.
private struct BookmarkUnavailable: Error {}

/// The paths a coder was asked to mint bookmarks for.
private final class BookmarkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ value: String) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// The authorisation path is what turns a user's grant into a lifted `/Volumes`
/// guard, so it is part of the protection promise (§10, §13.3) rather than
/// settings plumbing.
final class AuthorizationTests: XCTestCase, @unchecked Sendable {
    private let home = URL(fileURLWithPath: "/Users/example")

    private func makeRules(_ scope: AuthorizedScope, home: URL? = nil) -> RuleEngine {
        RuleEngine(
            rules: RuleEngine.builtInRules,
            homeDirectory: home ?? self.home,
            authorized: scope
        )
    }

    private func stored(_ path: String) -> AuthorizedLocation {
        AuthorizedLocation(
            bookmark: Data(path.utf8),
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            isVolume: path.hasPrefix("/Volumes/")
        )
    }

    /// A temporary home with one readable folder in it.
    ///
    /// A grant has to point at a location that can actually be opened: the real
    /// service refuses one it cannot read, so a made-up path would only ever
    /// exercise the refusal and never the grant. The fixture is returned because
    /// it deletes its tree when released.
    private func readableHome(tag: String) -> (fixture: TemporaryDirectory, granted: URL) {
        let fixture = TemporaryDirectory(tag: tag)
        let granted = fixture.url.appendingPathComponent("Backup")
        try? FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        return (fixture, granted)
    }

    /// The service as the app wires it: the allowlist is the rule engine's.
    private func makeService(
        scope: AuthorizedScope,
        coder: FakeBookmarkCoder,
        home: URL? = nil
    ) -> AuthorizationService {
        let rules = makeRules(scope, home: home)
        return AuthorizationService(
            scope: scope,
            policy: { rules.canAuthorize(url: $0) },
            coder: coder
        )
    }

    // MARK: - The location a grant actually covers

    func test_aGrantCoversTheResolvedLocationNotTheOneThatWasPicked() async {
        // A symlink can be picked in the panel like any folder, but the walk
        // refuses to follow one. Storing the picked URL would leave a scan root
        // the engine skips, which is how a granted folder produced no results.
        let (fixture, real) = readableHome(tag: "grant-symlink")
        let home = fixture.url
        let link = home.appendingPathComponent("Link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scope = AuthorizedScope()
        let service = makeService(scope: scope, coder: FakeBookmarkCoder(paths: [:]), home: home)

        let authorized = await service.authorize(link)
        XCTAssertNotNil(authorized, "a symlink to a readable folder is authorisable")
        guard let grant = authorized else { return }

        XCTAssertEqual(grant.url.path, real.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(grant.url.path, link.path)
        XCTAssertEqual(
            scope.paths,
            [real.resolvingSymlinksInPath().path],
            "the scope holds the same location the grant reports"
        )
    }

    func test_aGrantThatCannotBeOpenedIsRefused() async {
        // A volume that is not mounted: the path passes the allowlist and the
        // bookmark machinery reports success, but no scan could read it. Storing
        // a bookmark for it would put a row in settings that nothing honours.
        let scope = AuthorizedScope()
        let service = makeService(scope: scope, coder: FakeBookmarkCoder(paths: [:]))

        let missing = URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted")
        let grant = await service.authorize(missing)

        XCTAssertNil(grant)
        XCTAssertTrue(scope.paths.isEmpty)
    }

    func test_aStoredGrantThatCannotBeReadIsNotInForce() async {
        let (fixture, admitted) = readableHome(tag: "grant-unreadable")
        let home = fixture.url
        let blocked = home.appendingPathComponent("Blocked")
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        // A directory the process may own but not list, which is what a TCC
        // refusal and a revoked sandbox extension both look like from here.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: blocked.path
        )

        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(paths: [
            admitted.path: admitted.path,
            blocked.path: blocked.path,
        ])
        let service = makeService(scope: scope, coder: coder, home: home)

        let outcome = await service.restore([stored(blocked.path), stored(admitted.path)])

        XCTAssertEqual(
            outcome.locations.map(\.url.path),
            [admitted.path],
            "a grant that cannot be read is not advertised as available"
        )
        XCTAssertTrue(
            outcome.refused.isEmpty,
            "it stays in settings: a permission can be granted again"
        )
    }

    // MARK: - One grant per location

    func test_theRegistryTreatsOneLocationAsOneGrant() {
        let first = stored("/Volumes/Backup")
        let second = stored("/Volumes/Backup")
        var registry = GrantRegistry()

        XCTAssertNil(registry.identifier(forResolvedPath: "/Volumes/Backup"))
        registry.remember(first.id, url: URL(fileURLWithPath: "/Volumes/Backup"))

        XCTAssertEqual(registry.identifier(forResolvedPath: "/Volumes/Backup"), first.id)
        XCTAssertTrue(registry.isAvailable(first.id))
        // A second bookmark for the same location takes over the existing row
        // rather than adding one that would report itself unavailable.
        XCTAssertNotEqual(registry.identifier(forResolvedPath: "/Volumes/Backup"), second.id)
    }

    func test_theRegistrySurvivesCorruptSettingsWithoutCrashing() {
        let duplicated = [stored("/Volumes/Backup")]
        let locations = [
            RestoredLocation(id: duplicated[0].id, url: URL(fileURLWithPath: "/Volumes/Backup"), refreshedBookmark: nil),
            RestoredLocation(id: duplicated[0].id, url: URL(fileURLWithPath: "/Volumes/Other"), refreshedBookmark: nil),
        ]

        let registry = GrantRegistry(locations)

        XCTAssertEqual(registry.urls.count, 1, "a duplicated identifier is one grant")
        XCTAssertTrue(registry.isAvailable(duplicated[0].id))
    }

    // MARK: - The authorised rule anchors

    func test_authorisedAnchorsResolveAgainstTheGrants() {
        let scope = AuthorizedScope(roots: [
            URL(fileURLWithPath: "/Volumes/Backup"),
            URL(fileURLWithPath: "/Volumes/Backup/Photos"),
            URL(fileURLWithPath: "/Users/example/Library/Caches"),
        ])
        let rules = makeRules(scope)

        let authorised = rules.resolvedRoots(for: rule(anchor: .authorized, relativePath: "Caches"))
        XCTAssertEqual(
            authorised.map(\.path),
            [
                "/Users/example/Library/Caches/Caches",
                "/Volumes/Backup/Caches",
                "/Volumes/Backup/Photos/Caches",
            ]
        )

        let volumes = rules.resolvedRoots(for: rule(anchor: .externalVolume, relativePath: ""))
        XCTAssertEqual(
            volumes.map(\.path),
            ["/Volumes/Backup"],
            "a folder inside a volume, and a folder inside home, are not volumes"
        )
    }

    func test_anAuthorisedAnchorWithoutAGrantResolvesToNothing() {
        // The anchor must not fall back to a container: `/Volumes` or the home
        // directory would silently widen the rule to a tree nobody authorised.
        let engine = makeRules(AuthorizedScope())

        XCTAssertTrue(engine.resolvedRoots(for: rule(anchor: .authorized, relativePath: "Caches")).isEmpty)
        XCTAssertTrue(engine.resolvedRoots(for: rule(anchor: .externalVolume, relativePath: "")).isEmpty)
    }

    func test_aRuleUnderAGrantMatchesInsideThatGrantOnly() {
        let scope = AuthorizedScope(roots: [URL(fileURLWithPath: "/Volumes/Backup")])
        // A distinctive risk, because the engine answers `review` for a path no
        // rule claims: the assertion has to tell "this rule matched" from
        // "nothing matched".
        let scoped = rule(anchor: .externalVolume, relativePath: "Caches", risk: .safe)
        let engine = RuleEngine(
            rules: RuleEngine.builtInRules + [scoped],
            homeDirectory: home,
            authorized: scope
        )

        XCTAssertEqual(engine.risk(for: "/Volumes/Backup/Caches/junk.one"), .safe)
        XCTAssertEqual(
            engine.risk(for: "/Volumes/Backup/Documents/notes.txt"),
            .review,
            "the rule's relative path scopes it inside the grant"
        )
    }

    /// A rule in the shape a user rule file would use.
    private func rule(
        anchor: RuleEngine.RootAnchor,
        relativePath: String,
        risk: CleanupRisk = .review
    ) -> RuleEngine.Rule {
        RuleEngine.Rule(
            id: "granted-caches",
            category: .applicationCache,
            risk: risk,
            root: anchor,
            relativePath: relativePath,
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.cache",
            isEnabled: true
        )
    }

    // MARK: - Re-validating what a previous build stored

    func test_aStoredGrantOutsideTheAllowlistIsRefusedAndReported() async {
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(paths: [
            "/": "/",
            "/Volumes": "/Volumes",
            "/System": "/System",
        ])
        let service = makeService(scope: scope, coder: coder)

        let refused = ["/", "/Volumes", "/System"].map(stored)
        let outcome = await service.restore(refused)

        XCTAssertTrue(outcome.locations.isEmpty, "no legacy grant may be restored")
        XCTAssertEqual(Set(outcome.refused), Set(refused.map(\.id)))
        XCTAssertTrue(
            scope.paths.isEmpty,
            "a refused grant must not reach the scope: `/Volumes` there would lift the guard for every disk"
        )
    }

    func test_aLegacyVolumesGrantWouldOtherwiseUnprotectEveryDisk() {
        // The hazard the re-validation exists for, stated directly: with `/Volumes`
        // in the scope, every volume below it stops being protected.
        let scope = AuthorizedScope()
        let rules = makeRules(scope)
        XCTAssertNotNil(rules.protectionReason(for: "/Volumes/External/file.bin"))

        scope.add(URL(fileURLWithPath: "/Volumes"))
        XCTAssertNil(
            rules.protectionReason(for: "/Volumes/External/file.bin"),
            "this is what a restored broad grant would do, which is why it is refused"
        )
    }

    func test_anAllowedGrantIsRestoredAndEntersTheScope() async {
        let (fixture, granted) = readableHome(tag: "restore-grant")
        let home = fixture.url
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(paths: [granted.path: granted.path])
        let service = makeService(scope: scope, coder: coder, home: home)

        let record = stored(granted.path)
        let outcome = await service.restore([record])

        XCTAssertEqual(outcome.locations.map(\.id), [record.id])
        XCTAssertTrue(outcome.refused.isEmpty)
        XCTAssertEqual(scope.paths, [granted.path])
        XCTAssertNil(
            makeRules(scope, home: home).protectionReason(for: granted.appendingPathComponent("a.jpg").path),
            "the location the grant names is open"
        )
    }

    func test_aBookmarkThatNoLongerResolvesIsDroppedWithoutBeingCalledRefused() async {
        let (fixture, granted) = readableHome(tag: "restore-missing")
        let home = fixture.url
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(
            paths: [granted.path: granted.path],
            unresolvable: [home.appendingPathComponent("Gone").path]
        )
        let service = makeService(scope: scope, coder: coder, home: home)

        let outcome = await service.restore([
            stored(home.appendingPathComponent("Gone").path),
            stored(granted.path),
        ])

        XCTAssertEqual(outcome.locations.count, 1)
        XCTAssertTrue(
            outcome.refused.isEmpty,
            "an unmounted volume is not a policy refusal; settings keeps it so the user can see it"
        )
        XCTAssertEqual(scope.paths, [granted.path])
    }

    func test_aStaleBookmarkIsRefreshedAfterAccessIsEstablished() async {
        let (fixture, granted) = readableHome(tag: "restore-stale")
        let home = fixture.url
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(
            paths: [granted.path: granted.path],
            stale: [granted.path]
        )
        let service = makeService(scope: scope, coder: coder, home: home)

        let outcome = await service.restore([stored(granted.path)])

        XCTAssertNotNil(
            outcome.locations.first?.refreshedBookmark,
            "a stale bookmark must be replaced, or the repair repeats on every launch"
        )
        XCTAssertEqual(
            coder.log.values,
            [granted.path],
            "the replacement is minted for the restored location"
        )
    }

    // MARK: - The allowlist itself

    func test_theAllowlistRefusesEveryBroadOrUserContentPath() {
        let rules = makeRules(AuthorizedScope())
        for broad in ["/", "/Volumes", "/System", "/Library", "/private/var", "/etc"] {
            XCTAssertFalse(
                rules.canAuthorize(url: URL(fileURLWithPath: broad)),
                "\(broad) must not be authorisable"
            )
        }
        for content in ["Documents", "Desktop", "Movies", "Music", "Pictures", "Projects", "Developer", "Public"] {
            XCTAssertFalse(
                rules.canAuthorize(url: home.appendingPathComponent(content)),
                "\(content) is user content and must not be authorisable"
            )
        }
        for secret in ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Accounts"] {
            XCTAssertFalse(
                rules.canAuthorize(url: home.appendingPathComponent(secret)),
                "\(secret) must not be authorisable"
            )
        }
    }

    func test_authorizeItselfRefusesAPathOutsideTheAllowlist() async {
        // The settings page checks the allowlist first, but the service that
        // stores the bookmark must not depend on that: it is the only place a
        // grant enters the scope.
        let scope = AuthorizedScope()
        let service = makeService(scope: scope, coder: FakeBookmarkCoder(paths: [:]))

        let refused = await service.authorize(URL(fileURLWithPath: "/System"))

        XCTAssertNil(refused)
        XCTAssertTrue(scope.paths.isEmpty)
    }

    func test_anOrdinaryFolderOrVolumeIsStillAuthorisable() {
        let rules = makeRules(AuthorizedScope())
        XCTAssertTrue(rules.canAuthorize(url: URL(fileURLWithPath: "/Volumes/Backup")))
        XCTAssertTrue(rules.canAuthorize(url: home.appendingPathComponent("Library/Caches")))
        XCTAssertTrue(rules.canAuthorize(url: home.appendingPathComponent("Downloads")))
        XCTAssertFalse(rules.canAuthorize(url: home), "the home folder itself is not a grant")
    }
}
