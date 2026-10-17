import Foundation
import OSLog

/// The set of locations the user has explicitly authorised.
///
/// Shared by reference so every component compares against the same list: the
/// rule engine (for the `/Volumes` exemption), the scan request builder, and the
/// file operations service. A value type here would mean a copy per service, and
/// a location added while the app runs would only take effect after a restart.
///
/// The class is `@unchecked Sendable` behind a lock rather than an actor because
/// `RuleEngine` is a value type used from synchronous scanner code.
public final class AuthorizedScope: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String]

    public init(roots: [URL] = []) {
        self.roots = roots.map { Self.normalise($0.path) }
    }

    /// The authorised paths, normalised.
    public var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return roots
    }

    /// Replaces the whole set.
    public func replace(with urls: [URL]) {
        let normalised = urls.map { Self.normalise($0.path) }
        lock.lock()
        roots = normalised
        lock.unlock()
    }

    /// Adds one path, ignoring duplicates.
    public func add(_ url: URL) {
        let candidate = Self.normalise(url.path)
        lock.lock()
        if !roots.contains(candidate) {
            roots.append(candidate)
        }
        lock.unlock()
    }

    /// True when `path` is the authorised root or sits inside one.
    public func contains(_ path: String) -> Bool {
        let candidate = Self.normalise(path)
        lock.lock()
        let snapshot = roots
        lock.unlock()
        return snapshot.contains { root in
            candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    /// Collapses the forms a path can arrive in. Symlinks are resolved by the
    /// caller; this only removes `.`/`..` and duplicate separators.
    private static func normalise(_ path: String) -> String {
        var parts: [String] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(segment))
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// The outcome of reopening one stored bookmark.
public struct RestoredLocation: Sendable {
    public let id: UUID
    public let url: URL
    /// A replacement bookmark when the stored one had gone stale, so the caller
    /// can persist it instead of repeating the repair on every launch.
    public let refreshedBookmark: Data?

    public init(id: UUID, url: URL, refreshedBookmark: Data?) {
        self.id = id
        self.url = url
        self.refreshedBookmark = refreshedBookmark
    }
}

/// What a call to `restore` produced.
public struct RestoredGrants: Sendable {
    /// The grants in force for this launch, in the order they were stored.
    public let locations: [RestoredLocation]
    /// Stored grants the current allowlist refuses, by identifier.
    ///
    /// They are not in force and belong out of settings: a grant the app cannot
    /// honour must not keep appearing as one that works.
    public let refused: [UUID]

    public init(locations: [RestoredLocation], refused: [UUID]) {
        self.locations = locations
        self.refused = refused
    }
}

/// Mints and reopens security-scoped bookmarks.
///
/// A protocol rather than direct `URL` calls so the launch path can be tested.
/// Minting a security-scoped bookmark needs a signed, entitled app, so in a test
/// binary those calls fail for a reason that has nothing to do with the logic
/// under test — which would leave the re-validation of stored grants, the part
/// that keeps a legacy `/Volumes` grant from unprotecting every disk, untested.
public protocol BookmarkCoder: Sendable {
    /// A bookmark for `url` that survives a relaunch.
    func makeBookmark(for url: URL) throws -> Data
    /// Reopens one, reporting whether it is stale and needs replacing.
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
}

/// The real coder, backed by `URL`'s security-scoped bookmark support.
public struct SecurityScopedBookmarkCoder: BookmarkCoder {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

/// Persists and reopens security-scoped bookmarks.
///
/// The App Sandbox build can only touch folders the user picked, and the direct
/// build still needs the same grant for an external volume: a mount point name is
/// not authorisation (§10.1). This type is where that grant lives.
public actor AuthorizationService {
    private let scope: AuthorizedScope
    private let fileManager: FileManager
    /// Decides whether a location may be authorised at all.
    ///
    /// Injected rather than re-implemented here: the settings page, this service
    /// and the rule engine have to answer "may this path be granted?" identically,
    /// and a second copy of the allowlist is how the answers diverge.
    private let policy: @Sendable (URL) -> Bool
    private let coder: any BookmarkCoder
    private let logger = SiftLog.permissions
    /// Open accesses, keyed by path, held for the app's lifetime.
    private var active: [String: URL] = [:]

    public init(
        scope: AuthorizedScope,
        policy: @escaping @Sendable (URL) -> Bool,
        coder: any BookmarkCoder = SecurityScopedBookmarkCoder(),
        fileManager: FileManager = .default
    ) {
        self.scope = scope
        self.policy = policy
        self.coder = coder
        self.fileManager = fileManager
    }

    /// Creates a bookmark for a user-selected folder or volume and starts access.
    ///
    /// The bookmark is created with `.withSecurityScope`, which is what makes the
    /// grant survive a relaunch in the sandboxed build. A volume can be chosen
    /// like any folder; the caller's open panel allows navigating to `/Volumes`.
    public func authorize(_ url: URL) -> AuthorizedLocation? {
        let resolved = url.resolvingSymlinksInPath()
        // The allowlist is enforced here as well as in the UI, so no caller can
        // add a grant the protection list would then refuse to honour.
        guard policy(resolved) else {
            logger.notice("Refused to authorise a location outside the allowlist")
            return nil
        }
        let didStart = resolved.startAccessingSecurityScopedResource()
        defer {
            if didStart { resolved.stopAccessingSecurityScopedResource() }
        }

        do {
            let bookmark = try coder.makeBookmark(for: resolved)
            let isVolume = resolved.path == "/" || resolved.path.hasPrefix("/Volumes/")
            let location = AuthorizedLocation(
                bookmark: bookmark,
                displayName: resolved.lastPathComponent,
                isVolume: isVolume
            )
            scope.add(resolved)
            startAccess(for: resolved)
            logger.notice("Location authorised (volume=\(isVolume, privacy: .public))")
            return location
        } catch {
            // A bookmark can fail for a folder that was already removed, or for a
            // path the process may not read. The user sees a plain refusal
            // instead of a silent no-op.
            logger.error("Could not create a security-scoped bookmark")
            return nil
        }
    }

    /// Reopens every stored bookmark and keeps access for the app's lifetime.
    ///
    /// Called once at launch. A bookmark that no longer resolves is dropped from
    /// the scope: a moved or unmounted volume must not widen or narrow the scan
    /// silently, and the settings page reports what is no longer available.
    ///
    /// A bookmark that still resolves is *re-validated*, not trusted. It was
    /// written by whichever build stored it, against that build's rules: an older
    /// version could hold a grant for `/` or `/Volumes` itself, and restoring it
    /// unchanged would lift the blanket `/Volumes` guard for every disk. A stored
    /// grant is therefore a request, checked against the current allowlist before
    /// it reaches the scope.
    @discardableResult
    public func restore(_ locations: [AuthorizedLocation]) -> RestoredGrants {
        var restored: [RestoredLocation] = []
        var refused: [UUID] = []
        for location in locations {
            guard let resolved = try? coder.resolve(location.bookmark) else {
                logger.notice("A stored bookmark no longer resolves and was dropped")
                continue
            }
            let url = resolved.url

            guard policy(url) else {
                refused.append(location.id)
                logger.notice("A stored grant is outside the allowlist and was dropped")
                continue
            }

            // Access first. Creating a replacement bookmark for a security-scoped
            // resource needs the scope open, so refreshing a stale bookmark before
            // this point fails and the repair repeats on every launch.
            startAccess(for: url)

            var refreshed: Data?
            if resolved.isStale {
                // A stale bookmark still resolves, but it must be replaced or the
                // next launch repeats the repair and it eventually stops working.
                refreshed = try? coder.makeBookmark(for: url)
                logger.notice(
                    "A stored bookmark was stale and \(refreshed == nil ? "could not be refreshed" : "was refreshed", privacy: .public)"
                )
            }

            restored.append(
                RestoredLocation(id: location.id, url: url, refreshedBookmark: refreshed)
            )
        }
        scope.replace(with: restored.map(\.url))
        return RestoredGrants(locations: restored, refused: refused)
    }

    /// Stops every access. Called when the app terminates.
    public func releaseAll() {
        for (path, url) in active {
            url.stopAccessingSecurityScopedResource()
            logger.debug("Released access to an authorised location (\(path.count, privacy: .public) characters)")
        }
        active.removeAll()
        scope.replace(with: [])
    }

    private func startAccess(for url: URL) {
        let key = url.path
        guard active[key] == nil else { return }
        if url.startAccessingSecurityScopedResource() {
            active[key] = url
        }
    }
}
