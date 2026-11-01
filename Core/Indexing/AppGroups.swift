import Foundation
import OSLog
import Security

/// The app groups an application's code signature grants it.
///
/// `com.apple.security.application-groups` is the only statement macOS accepts
/// that two applications may use the same group container. A group container is
/// named after the group, not after either application, so this is the one place
/// the sharing of a container can be read rather than guessed from a name.
public enum AppGroupEntitlements {
    /// The entitlement that names a shared group.
    public static let key = "com.apple.security.application-groups"

    /// Reads the declared group identifiers of one application bundle.
    ///
    /// Injected everywhere it is used, so a test can answer it without a signed
    /// bundle and the signature read stays in one place.
    public typealias Reader = @Sendable (URL) -> Set<String>

    /// Reads an application's declared group identifiers, lower-cased.
    ///
    /// Read from the signature rather than from `Info.plist`: the entitlement is
    /// what macOS actually grants, and an unentitled bundle declares nothing no
    /// matter how its plist is spelled. A bundle whose signature cannot be read
    /// (unsigned, damaged, on a not-yet-mounted volume) returns an empty set —
    /// no entitlement is the ordinary answer, not an error.
    public static func read(_ application: URL) -> Set<String> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
              let code
        else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let groups = entitlements[key] as? [String]
        else { return [] }
        return Set(groups.map { $0.lowercased() })
    }
}

/// The app groups installed applications declare, and whether that is all of them.
public struct DeclaredAppGroups: Sendable, Equatable {
    public let identifiers: [String]
    /// `false` when the read was cut short: the list is then a prefix, not a set,
    /// and nothing may conclude that an unlisted group is unused.
    public let isComplete: Bool

    public init(identifiers: [String], isComplete: Bool) {
        self.identifiers = identifiers
        self.isComplete = isComplete
    }

    public static let empty = DeclaredAppGroups(identifiers: [], isComplete: true)
}

/// Which installed applications declare which app groups.
///
/// Built lazily and then answered from memory: reading it is a signature read per
/// installed bundle (135 bundles take about half a second on a stock Mac), and a
/// page asks about at most a handful of containers. A machine with no group
/// container never pays for it.
///
/// The map does not live forever. Installing, removing or replacing an
/// application changes the answer, and a session outlives all three — so every
/// question is preceded by a *fingerprint* of the application directories (bundle
/// path and its directory timestamp), and a changed fingerprint rebuilds the map.
/// The fingerprint costs a stat per bundle and reads no signature; that is the
/// point, because the alternative is a half-second read on every question.
///
/// `@unchecked Sendable`: the only mutable state is the map and its fingerprint,
/// and they are read and written under `lock`; everything else is set at init.
/// Building happens outside the lock (a signature read is milliseconds of file
/// I/O and two builders produce the same map), which is why the store step
/// re-checks the fingerprint it built for.
public final class AppGroupRegistry: @unchecked Sendable {
    private let applicationDirectories: [URL]
    private let fileManager: FileManager
    private let read: AppGroupEntitlements.Reader
    private let logger = SiftLog.make("AppGroups")
    private let lock = NSLock()
    /// Group identifier -> names of the applications declaring it. `nil` until built.
    private var declarations: [String: [String]]?
    /// The application fingerprint the map was built from.
    private var builtFor: [String]?
    /// `path|stamp` of an application -> the groups it declares.
    private var ownGroups: [String: Set<String>] = [:]
    /// How many times the map has been built. Read by tests.
    private var builds = 0

    public init(
        applicationDirectories: [URL],
        fileManager: FileManager = .default,
        read: @escaping AppGroupEntitlements.Reader = AppGroupEntitlements.read
    ) {
        self.applicationDirectories = applicationDirectories
        self.fileManager = fileManager
        self.read = read
    }

    /// The installed applications that declare `group`.
    ///
    /// `excluding` drops one application by name, which is how the uninstaller
    /// lists *other* applications on a shared container's row. Names are the
    /// bundle file names, the same spelling the application list uses.
    public func applications(declaring group: String, excluding excluded: String? = nil) -> [String] {
        let key = group.lowercased()
        return map(deadline: nil).map[key, default: []].filter {
            guard let excluded else { return true }
            return $0.caseInsensitiveCompare(excluded) != .orderedSame
        }
    }

    /// How long a caller waits for the full set before it says so.
    ///
    /// The read is about half a second for 117 bundles on the development machine
    /// and unbounded on a volume that stops answering. Five seconds is far above
    /// the ordinary cost and far below the point where a scan looks hung.
    public static let defaultDeadline: TimeInterval = 5

    /// Every group an installed application declares, with whether it is all of
    /// them.
    ///
    /// This is what a scan request carries: the container names that belong to
    /// something installed, whatever spelling the container has. `isComplete` is
    /// `false` when the read ran out of time or the task was cancelled, and the
    /// caller must not treat the groups as the whole set — a container whose owner
    /// was not read looks like a leftover, which is the one answer this must never
    /// invent.
    public func declaredGroups(deadline: Date? = nil) -> DeclaredAppGroups {
        let (map, isComplete) = map(deadline: deadline)
        return DeclaredAppGroups(identifiers: map.keys.sorted(), isComplete: isComplete)
    }

    /// The same set, without the completeness question. Test and page use.
    var declaredGroupIdentifiers: [String] {
        declaredGroups().identifiers
    }

    /// The groups one application declares, lower-cased.
    ///
    /// One signature read per application, cached: the uninstaller asks this about
    /// the page it is showing, which is a different (and much cheaper) question
    /// than "who declares this group" — that one reads every installed bundle.
    public func groups(ofApplicationAt application: URL) -> Set<String> {
        // Keyed by the bundle's timestamp as well as its path: an application
        // updated in place must not answer with the groups its previous version
        // declared, and the session can outlive the update.
        let stamp = Self.modificationStamp(of: application)
            + Self.modificationStamp(of: application.appendingPathComponent("Contents/Info.plist"))
        let key = "\(application.standardizedFileURL.path)|\(stamp)"
        lock.lock()
        if let cached = ownGroups[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Read outside the lock: a signature read is milliseconds of file I/O and
        // two callers reading the same bundle produce the same answer.
        let groups = Set(read(application).map { $0.lowercased() })

        lock.lock()
        ownGroups[key] = groups
        lock.unlock()
        return groups
    }

    /// The whole map, rebuilt when the installed applications have changed.
    ///
    /// `isComplete` is the second half of the answer: a map that ran out of time is
    /// never returned as if it were the map.
    private func map(deadline: Date?) -> (map: [String: [String]], isComplete: Bool) {
        let bundles = installedBundles()
        // Sorted: the enumerator's order is not part of the state, and comparing
        // two orderings would rebuild for no reason.
        let fingerprint = bundles.map(\.stamp).sorted()
        lock.lock()
        if let declarations, builtFor == fingerprint {
            lock.unlock()
            return (declarations, true)
        }
        lock.unlock()

        let started = Date()
        var built: [String: [String]] = [:]
        for bundle in bundles {
            // Checked between bundles rather than inside a signature read: one read
            // is milliseconds and cannot be interrupted, and a caller that has
            // waited long enough wants an answer, not a partial one.
            if Task.isCancelled { return ([:], false) }
            if let deadline, Date() >= deadline { return ([:], false) }
            let url = bundle.url
            let name = url.deletingPathExtension().lastPathComponent
            for group in read(url) {
                    // The entitlement's own case is not significant — a group id is
                    // matched against a directory name — so the map is keyed
                    // lower-cased and the reader may answer in any case.
                    var names = built[group.lowercased(), default: []]
                    if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        names.append(name)
                    }
                built[group.lowercased()] = names
            }
        }
        for (group, names) in built {
            built[group] = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        lock.lock()
        // A concurrent builder may have stored a map for the same fingerprint;
        // either answer is the same, and keeping theirs avoids a second reader
        // seeing a map that is newer than the one it asked for.
        if builtFor != fingerprint {
            declarations = built
            builtFor = fingerprint
            builds += 1
        }
        let stored = declarations ?? built
        lock.unlock()

        logger.debug(
            """
            app groups: \(stored.count, privacy: .public) declared by \
            \(bundles.count, privacy: .public) bundles in \
            \(Date().timeIntervalSince(started), privacy: .public)s
            """
        )
        return (stored, true)
    }

    /// How many times this registry has read the signatures. Test-visible.
    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return builds
    }

    /// The installed bundles with the timestamps that stand for their identity.
    ///
    /// A path is added by an installation and dropped by a removal. An in-place
    /// update is subtler: replacing the files inside `Contents` does not
    /// necessarily touch the bundle directory's own timestamp, so `Info.plist` is
    /// read as a second signal — it is the one file every bundle has, and an
    /// update that changes nothing about the application at all is an update whose
    /// entitlements did not change either. Two stats per bundle, no signature.
    private func installedBundles() -> [(url: URL, stamp: String)] {
        var bundles: [(url: URL, stamp: String)] = []
        for directory in applicationDirectories {
            for url in applicationBundleURLs(in: directory) {
                let directoryStamp = Self.modificationStamp(of: url)
                let plistStamp = Self.modificationStamp(
                    of: url.appendingPathComponent("Contents/Info.plist")
                )
                bundles.append((url, "\(url.path)|\(directoryStamp)|\(plistStamp)"))
            }
        }
        return bundles
    }

    /// One file's modification time as a comparable string, or `0` when unknown.
    private static func modificationStamp(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values?.contentModificationDate else { return "0" }
        return String(date.timeIntervalSince1970)
    }

    /// Every `.app` bundle below an application directory, depth-capped.
    ///
    /// The same shape `ApplicationDiscovery` walks: vendors nest one level deeper
    /// (`/Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app`), a bundle
    /// is never descended into, and the cap keeps a stray package tree from
    /// turning this into a full-disk walk.
    private func applicationBundleURLs(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - directory.pathComponents.count
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                urls.append(url)
                enumerator.skipDescendants()
            }
        }
        return urls
    }
}
