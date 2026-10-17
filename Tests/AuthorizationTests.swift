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
final class AuthorizationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example")

    private func makeRules(_ scope: AuthorizedScope) -> RuleEngine {
        RuleEngine(rules: RuleEngine.builtInRules, homeDirectory: home, authorized: scope)
    }

    private func stored(_ path: String) -> AuthorizedLocation {
        AuthorizedLocation(
            bookmark: Data(path.utf8),
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            isVolume: path.hasPrefix("/Volumes/")
        )
    }

    /// The service as the app wires it: the allowlist is the rule engine's.
    private func makeService(
        scope: AuthorizedScope,
        coder: FakeBookmarkCoder
    ) -> AuthorizationService {
        let rules = makeRules(scope)
        return AuthorizationService(
            scope: scope,
            policy: { rules.canAuthorize(url: $0) },
            coder: coder
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
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(paths: ["/Volumes/Backup": "/Volumes/Backup"])
        let service = makeService(scope: scope, coder: coder)

        let granted = stored("/Volumes/Backup")
        let outcome = await service.restore([granted])

        XCTAssertEqual(outcome.locations.map(\.id), [granted.id])
        XCTAssertTrue(outcome.refused.isEmpty)
        XCTAssertEqual(scope.paths, ["/Volumes/Backup"])
        XCTAssertNil(
            makeRules(scope).protectionReason(for: "/Volumes/Backup/Photos/a.jpg"),
            "the restored grant is what opens the volume"
        )
        XCTAssertNotNil(
            makeRules(scope).protectionReason(for: "/Volumes/Other/a.jpg"),
            "and it opens nothing else"
        )
    }

    func test_aBookmarkThatNoLongerResolvesIsDroppedWithoutBeingCalledRefused() async {
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(
            paths: ["/Volumes/Backup": "/Volumes/Backup"],
            unresolvable: ["/Volumes/Gone"]
        )
        let service = makeService(scope: scope, coder: coder)

        let outcome = await service.restore([stored("/Volumes/Gone"), stored("/Volumes/Backup")])

        XCTAssertEqual(outcome.locations.count, 1)
        XCTAssertTrue(
            outcome.refused.isEmpty,
            "an unmounted volume is not a policy refusal; settings keeps it so the user can see it"
        )
        XCTAssertEqual(scope.paths, ["/Volumes/Backup"])
    }

    func test_aStaleBookmarkIsRefreshedAfterAccessIsEstablished() async {
        let scope = AuthorizedScope()
        let coder = FakeBookmarkCoder(
            paths: ["/Volumes/Backup": "/Volumes/Backup"],
            stale: ["/Volumes/Backup"]
        )
        let service = makeService(scope: scope, coder: coder)

        let outcome = await service.restore([stored("/Volumes/Backup")])

        XCTAssertNotNil(
            outcome.locations.first?.refreshedBookmark,
            "a stale bookmark must be replaced, or the repair repeats on every launch"
        )
        XCTAssertEqual(
            coder.log.values,
            ["/Volumes/Backup"],
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
