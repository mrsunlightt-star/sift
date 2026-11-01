#if canImport(Darwin)
import Darwin
#endif
import Foundation
import OSLog
import Shared

/// The cleaning rule engine (§8.4).
///
/// This is the Swift-side authority on three questions the UI must answer before
/// anything is shown or acted on:
///
///  1. **Is this path protected?** The compiled-in list wins over every rule
///     file, so a bad or malicious rule file cannot unprotect user documents.
///  2. **What risk does this item carry?** The most cautious level for a path is
///     the one reported.
///  3. **What does it mean?** Every risk maps to an explanation the user reads.
///
/// The Rust scanner applies the same rules for discovery. Keeping a second
/// implementation here is deliberate: it is the check that runs on the Swift
/// side immediately before a file operation, which is what §13.3 requires
/// ("删除前重新验证 URL，不能只信任旧扫描结果").
public struct RuleEngine: Sendable {
    /// A rule loaded from `CleaningRules.json`.
    public struct Rule: Sendable, Hashable {
        public let id: String
        public let category: CleanupCategory
        public let risk: CleanupRisk
        public let root: RootAnchor
        public let relativePath: String
        public let matchSpec: MatchSpec?
        public let excludes: [String]
        public let minAgeDays: Int?
        /// Whether the user's stale threshold replaces `minAgeDays`.
        ///
        /// §5.2 gives the user one age at which a log or installer counts as
        /// stale. A rule that says so here follows that setting; one that does
        /// not keeps the age it states, so the archive rule stays at 90 days
        /// however the setting is moved.
        public let usesStaleThreshold: Bool
        public let requiresFullDiskAccess: Bool
        /// Whether the items this rule finds belong to one application, so that
        /// application must not be running while they are removed.
        ///
        /// A cache directory is not locked the way an `.app` bundle is: the move
        /// succeeds and the application keeps writing into the path it
        /// remembers, so the directory comes back — or loses the state it was in
        /// the middle of writing. The Rust core reads the same flag and applies
        /// the same test, so both engines call the same item `review`.
        public let needsAppClosed: Bool
        public let explanationKey: String
        public let isEnabled: Bool

        public init(
            id: String,
            category: CleanupCategory,
            risk: CleanupRisk,
            root: RootAnchor,
            relativePath: String,
            matchSpec: MatchSpec?,
            excludes: [String],
            minAgeDays: Int?,
            usesStaleThreshold: Bool = false,
            requiresFullDiskAccess: Bool,
            needsAppClosed: Bool = false,
            explanationKey: String,
            isEnabled: Bool
        ) {
            self.id = id
            self.category = category
            self.risk = risk
            self.root = root
            self.relativePath = relativePath
            self.matchSpec = matchSpec
            self.excludes = excludes
            self.minAgeDays = minAgeDays
            self.usesStaleThreshold = usesStaleThreshold
            self.requiresFullDiskAccess = requiresFullDiskAccess
            self.needsAppClosed = needsAppClosed
            self.explanationKey = explanationKey
            self.isEnabled = isEnabled
        }

        /// The age threshold this rule applies for a scan, in days.
        ///
        /// The Rust core resolves this identically from the same request field,
        /// so both engines treat the same file as stale. A threshold of zero
        /// leaves the rule's own age in force: a setting that was never stored
        /// must not make every file instantly stale.
        public func effectiveMinAgeDays(staleThresholdDays: Int) -> Int? {
            guard usesStaleThreshold, minAgeDays != nil, staleThresholdDays > 0 else {
                return minAgeDays
            }
            return staleThresholdDays
        }

        /// The same rule at a different risk level.
        ///
        /// Used when a merged table has to be brought down to what this build
        /// reviewed; every other field, including the explanation key the user
        /// reads, is preserved.
        public func withRisk(_ risk: CleanupRisk) -> Rule {
            Rule(
                id: id,
                category: category,
                risk: risk,
                root: root,
                relativePath: relativePath,
                matchSpec: matchSpec,
                excludes: excludes,
                minAgeDays: minAgeDays,
                usesStaleThreshold: usesStaleThreshold,
                requiresFullDiskAccess: requiresFullDiskAccess,
                needsAppClosed: needsAppClosed,
                explanationKey: explanationKey,
                isEnabled: isEnabled
            )
        }
    }

    /// Where a rule's relative path is anchored.
    public enum RootAnchor: String, Sendable, CaseIterable, Codable {
        case home
        case homeLibrary
        case applications
        case systemLibrary
        /// The per-user temporary root macOS gives this login session.
        ///
        /// `/var/folders/<two>/<hash>` — the parent of `$TMPDIR`, holding `T`
        /// (the temporary directory) and `C` (the per-user cache directory).
        /// Unlike every other fixed anchor it is not derived from the home
        /// directory, so the engine carries the resolved path (`userTempDirectory`)
        /// rather than computing it: `confstr` answers on macOS, and the value has
        /// to be the same one the Rust core is handed.
        ///
        /// `T` is deliberately out of the shipped rules: live processes keep
        /// their sockets and mach ports there (`T/com.apple.launchd.*`), and a
        /// rule can only look at a name or an age.
        case userTemp
        case authorized
        case externalVolume
    }

    /// What a rule considers a match.
    public enum MatchSpec: Sendable, Hashable {
        case directory
        case childDirectories
        case filesByExtension([String])
        case anyFile
        /// Direct child directories whose own name is in the set.
        ///
        /// `childDirectories` with the filter in the rule instead of in the path:
        /// an application names its cache directory `Cache`, `Caches`, `GPUCache`
        /// or `Code Cache` depending on the framework it was built with, and one
        /// rule per spelling is a list that grows with every framework. The Rust
        /// loader reads the same `names` field.
        case directoriesNamed([String])
    }

    /// Rule file schema version understood by this build.
    public static let supportedSchemaVersion = 1

    // The protection list itself lives in `ProtectedPaths`, which
    // `Scripts/generate-protection.py` writes for both this engine and the Rust
    // scanner core. Nothing here may restate it: a second literal is how the two
    // engines drift apart.

    /// Extensions treated as one unit rather than individual files.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "mpkg", "photoslibrary",
        "pkg", "plugin", "prefpane", "qlgenerator", "xcodeproj", "xcworkspace",
    ]

    /// Bundle identifiers whose data must never be offered for deletion.
    public static let excludedBundleNames: Set<String> = [
        "CloudKit", "com.apple.bird", "com.apple.iCloud", "com.apple.cloudd", "FamilyCircle",
        "com.apple.security.cloudkeychainproxy",
    ]

    public let rules: [Rule]
    /// The user's rule file, exactly as it was accepted, for the Rust core.
    ///
    /// The Rust scanner discovers candidates and never sees this engine's
    /// `[Rule]`, so a rule the user wrote has to travel to it as the document it
    /// came from. Stored only once `decode` has accepted it, so the Rust core is
    /// handed a document this engine has already validated rather than raw bytes
    /// that might fail the scan with `invalidRequest`.
    public let userRulesJSON: String?
    /// Locations the user explicitly authorised in settings.
    ///
    /// Authorisation only lifts the blanket `/Volumes` and `/private/var` prefixes
    /// that exist to stop Sift scanning those trees by default. It never unlocks
    /// user content, keychains or a photos library.
    private let authorized: AuthorizedScope
    /// The grants captured when a scan started, when this engine is a run
    /// snapshot. A live engine reads the shared scope; a scan must not see a
    /// grant added halfway through its walk.
    private let authorizedSnapshot: [String]?
    /// The per-user temporary root a `userTemp` rule is anchored to.
    ///
    /// Resolved once, by whichever process builds the engine, and handed to the
    /// Rust core in the request's roots: the path is generated per login session,
    /// so a rule cannot spell it and the two engines must not each work it out.
    /// `nil` when this process has no such directory, in which case a `userTemp`
    /// rule resolves to nothing.
    public let userTempDirectory: String?

    /// The home directory every path comparison is made against.
    ///
    /// Exposed because the scanners, the storage analysis and the file
    /// operations must all compare against the same root. A component that fell
    /// back to the process home would apply the wrong protection set to a scan of
    /// any other tree.
    public let homeDirectory: String

    private static let logger = SiftLog.make("Rules")

    /// Loads the shipped rules merged with an optional user rule file.
    ///
    /// A malformed or unknown-version user file is rejected as a whole; the
    /// shipped rules are still used, so the app remains functional.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userRuleURL: URL? = nil,
        authorized: AuthorizedScope = AuthorizedScope(),
        authorizedSnapshot: [String]? = nil,
        userTempDirectory: URL? = RuleEngine.darwinUserTempRoot()
    ) {
        // Resolved on the way in so every later comparison uses one spelling of
        // the path. `URL.resolvingSymlinksInPath` is used rather than
        // `FileManager` so a path that does not exist yet still resolves.
        self.homeDirectory = Self.normalize(homeDirectory.resolvingSymlinksInPath().path)
        self.userTempDirectory = userTempDirectory.map { Self.normalize($0.path) }
        self.authorized = authorized
        self.authorizedSnapshot = authorizedSnapshot?.map(Self.normalize)

        var table = Self.bundledRules()
        var acceptedUserRules: String?
        if let userRuleURL, let data = try? Data(contentsOf: userRuleURL) {
            do {
                let overlay = try Self.decode(data)
                table = Self.merge(base: table, overlay: overlay)
                // Kept verbatim: the Rust core merges the same document onto the
                // same built-ins, so re-encoding it here could only introduce a
                // second shape for the two engines to disagree about.
                acceptedUserRules = String(data: data, encoding: .utf8)
                Self.logger.info("Loaded \(overlay.count) extra rules from the user rule file")
            } catch {
                // Fail soft: the shipped rules stay in force, and the reason is
                // logged without the file's path. Nothing is handed to the Rust
                // core either, so both engines keep the same rule set.
                Self.logger.error(
                    "User rule file rejected (\(String(describing: error)); keeping built-in rules)"
                )
            }
        }
        self.rules = table
        self.userRulesJSON = acceptedUserRules
    }

    /// Test and preview initialiser with an explicit rule list.
    public init(
        rules: [Rule],
        homeDirectory: URL,
        authorized: AuthorizedScope = AuthorizedScope(),
        userRulesJSON: String? = nil,
        authorizedSnapshot: [String]? = nil,
        userTempDirectory: URL? = RuleEngine.darwinUserTempRoot()
    ) {
        self.rules = rules
        self.homeDirectory = Self.normalize(homeDirectory.path)
        self.userTempDirectory = userTempDirectory.map { Self.normalize($0.path) }
        self.authorized = authorized
        self.userRulesJSON = userRulesJSON
        self.authorizedSnapshot = authorizedSnapshot?.map(Self.normalize)
    }

    /// A copy of this engine whose grants are frozen at the paths given.
    ///
    /// The scan path builds one of these per run. The engine that pre-flights
    /// the result keeps using the live scope, so a grant added while a scan is
    /// running is honoured by the next run and by a pre-flight of the current
    /// result only once it is in force.
    public func snapshottingAuthorization(_ paths: [String]) -> RuleEngine {
        RuleEngine(
            rules: rules,
            homeDirectory: URL(fileURLWithPath: homeDirectory),
            authorized: authorized,
            userRulesJSON: userRulesJSON,
            authorizedSnapshot: paths,
            userTempDirectory: userTempDirectory.map { URL(fileURLWithPath: $0) }
        )
    }

    /// The grants in force for this engine: the run snapshot when one exists,
    /// the shared scope otherwise.
    private var effectiveAuthorizedPaths: [String] {
        authorizedSnapshot ?? authorized.paths
    }

    /// The grants in force, for callers that hand paths to another engine.
    ///
    /// The Rust storage analysis applies the same protection list as a scan, so
    /// it needs the same grants; without them an authorised volume would be
    /// measured as a protected `/Volumes` tree.
    public var authorizedRoots: [String] { effectiveAuthorizedPaths }

    // MARK: - The per-user temporary root

    /// `/var/folders/<two>/<hash>` for this login session, or `nil`.
    ///
    /// The parent of the process's own temporary directory. `confstr` is asked
    /// rather than `$TMPDIR`, because the variable is inherited: a shell that
    /// exports its own `TMPDIR` would point the rule at a directory that belongs
    /// to no session, and the Rust core — handed this same value — would then
    /// scan the tree the app named while a rule claimed a different one.
    public static func darwinUserTempRoot() -> URL? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return nil }
        // `String(cString:)` is deprecated for an array buffer; truncating at the
        // terminator and decoding explicitly says the same thing without it.
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        // The temporary directory itself is `…/T/`; the root the rules anchor to
        // is the session directory above it. Resolved, so the path this engine
        // matches against and the scan root the Rust core is handed are the same
        // string: `confstr` answers `/var/folders/…`, whose `/var` is a symlink to
        // `/private/var`, and two spellings of one directory would make the two
        // engines report the same item under different paths.
        let root = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return root
        #else
        return nil
        #endif
    }

    // MARK: - Protection

    /// Why a path may not be touched, or `nil` when it may be.
    public enum ProtectionReason: Sendable, Equatable {
        case userContent(String)
        case systemPath(String)
        case secrets(String)
        case photosLibrary

        /// The code reported to the UI and the report.
        public var code: ErrorCode { .protectedLocation }

        /// A sentence the user can act on, without exposing the whole path.
        public var explanation: String {
            switch self {
            case .userContent:
                LocalizationKey.scanSkippedReasonProtectedLocation.localized
            case .systemPath, .secrets, .photosLibrary:
                LocalizationKey.scanSkippedReasonProtectedLocation.localized
            }
        }
    }

    /// Classifies a path against the compiled-in protection list.
    ///
    /// This is the function the confirmation panel, the pre-flight check and the
    /// file operations service all call before acting.
    public func protectionReason(for path: String) -> ProtectionReason? {
        let resolved = Self.normalize(path)

        // Protection names are literals and macOS volumes are case-insensitive
        // by default, so `~/documents` is the user's Documents directory. The
        // comparison folds case; rule matching keeps the exact `isPrefix`.
        for child in ProtectedPaths.homeChildren
        where Self.isProtectedPrefix("\(homeDirectory)/\(child)", resolved) {
            return .userContent(child)
        }
        for entry in ProtectedPaths.libraryChildren
        where Self.isProtectedPrefix("\(homeDirectory)/\(entry.path)", resolved) {
            switch entry.kind {
            case .userContent: return .userContent(entry.path)
            case .secrets: return .secrets(entry.path)
            }
        }
        if Self.isPhotoLibrary(resolved) {
            return .photosLibrary
        }
        // A recycle bin is refused wherever it appears: `~/.Trash`, an item
        // already inside it, and the `.Trashes` a volume keeps at its root. The
        // product's undo *is* the Trash, so offering its contents turns "moved
        // to the Trash" into "moved into the bin it was in", and the next empty
        // makes that unrecoverable. Checked before the `/Volumes` grant below,
        // because a grant opens a subtree and the bin inside it is the place
        // the user's undo lives.
        if let bin = Self.recycleBinComponent(resolved) {
            return .userContent(bin)
        }
        // A grant may lift the blanket `/Volumes` guard for exactly the subtree
        // the user added. It must never lift a real system prefix: granting
        // `/Library` or `/private/var` would otherwise expose launch daemons and
        // the system database, so authorisation is consulted only here.
        if Self.isProtectedPrefix("/Volumes", resolved) {
            if effectiveAuthorizedPaths.contains(where: { Self.isProtectedPrefix($0, resolved) }) {
                return nil
            }
            return .systemPath("/Volumes")
        }

        // Everything else in the protection list is a hard rule.
        for prefix in ProtectedPaths.prefixes
        where prefix != "/Volumes" && Self.isProtectedPrefix(prefix, resolved) {
            return .systemPath(prefix)
        }
        return nil
    }

    /// True when the user may grant access to this path.
    ///
    /// User content, keychains and a photo library are never authorisable: the
    /// grant exists to reach volumes and system trees the app does not scan by
    /// default, not to unlock a Documents folder.
    public func canAuthorize(url: URL) -> Bool {
        let path = Self.normalize(url.resolvingSymlinksInPath().path)
        let components = path.split(separator: "/")

        // A grant that the protection list would then ignore leaves the settings
        // page showing access the user does not actually have. A recycle bin is
        // refused by `protectionReason` before any grant is consulted, so it is
        // refused here as well — including the `.Trashes` of a volume the user
        // may otherwise add.
        if Self.recycleBinComponent(path) != nil { return false }

        // An explicit allowlist: a grant is either one concrete volume or a
        // folder inside the user's own home. Nothing else is authorisable, which
        // is what keeps `/`, `/Library` and `/private/var` out of reach.
        if Self.isProtectedPrefix("/Volumes", path) {
            // `/Volumes` itself is the container of every disk, not a grant.
            guard path != "/Volumes", components.count >= 2 else { return false }
            // A network share has no meaningful local size, no per-syscall
            // timeout, and no Trash the user can undo after unmounting. The
            // volume list already hides them; the allowlist must refuse them
            // even when the panel hands one back.
            let resolved = url.resolvingSymlinksInPath()
            if let isLocal = try? resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal,
               isLocal == false {
                return false
            }
            return true
        }
        guard Self.isPrefix(homeDirectory, path), path != homeDirectory else {
            return false
        }

        // Every compiled-in rule that `protectionReason` refuses is also
        // unauthorisable: accepting a grant that the protection list would then
        // ignore would leave the settings page showing access the user does not
        // actually have. The list comes from the shared table for that reason.
        for child in ProtectedPaths.homeChildren
        where Self.isProtectedPrefix("\(homeDirectory)/\(child)", path) {
            return false
        }
        for entry in ProtectedPaths.libraryChildren
        where Self.isProtectedPrefix("\(homeDirectory)/\(entry.path)", path) {
            return false
        }
        if Self.isPhotoLibrary(path) {
            return false
        }
        return true
    }


    /// True when the path is safe to scan and clean.
    public func isAllowed(_ path: String) -> Bool {
        protectionReason(for: path) == nil
    }

    /// The risk level for a path: the most cautious level any matching rule assigns.
    ///
    /// Returns `protected` for a protected path, so a caller that only looks at
    /// the risk level still refuses to act. A path inside an excluded
    /// application's data (`~/Library/Caches/CloudKit`) is `protected` too: no
    /// rule may offer it, and answering `safe` here while the scanner and the
    /// pre-flight both refuse it is how the two sides came to disagree about
    /// one path.
    public func risk(for path: String) -> CleanupRisk {
        if protectionReason(for: path) != nil { return .protected }
        if isInExcludedLocation(path) { return .protected }
        let matching = rules.filter { matches(rule: $0, path: path) }
        guard let mostCautious = matching.map(\.risk).max(by: { rank($0) < rank($1) }) else {
            // No rule claims the path: unclassified content is never `safe`.
            return .review
        }
        return mostCautious
    }

    /// The rule that produced an item, used to look up its explanation.
    public func rule(withID id: String) -> Rule? {
        rules.first { $0.id == id }
    }

    /// True when a rule that owns application data claims this path.
    ///
    /// The scanner uses this to decide whether an item needs a running-
    /// application check at all, and the pre-flight uses it together with
    /// [`isOwnedByRunningApplication`] to refuse an item whose owner is running.
    /// A path no rule claims is `false`: an item nothing checked is already at
    /// `review`, so there is no pre-selection to take away.
    public func requiresAppClosed(for path: String) -> Bool {
        rules.contains { $0.needsAppClosed && matches(rule: $0, path: path) }
    }

    /// Suffixes a directory name keeps on top of the application it belongs to.
    ///
    /// `~/Library/Saved Application State/com.apple.Safari.savedState` belongs to
    /// Safari, not to an application called `com.apple.Safari.savedState`. The
    /// Rust core carries the same list.
    public static let appOwnedNameSuffixes = [".savedstate", ".savedapplicationstate"]

    /// True when one of `tokens` names `path`, judged by the path's components.
    ///
    /// `tokens` are the aliases of the applications running right now: bundle
    /// identifiers, the Finder name, the executable name. The Rust core is handed
    /// exactly this list in the scan request, so both engines downgrade exactly
    /// the same items.
    ///
    /// Two comparisons, and the difference matters:
    ///
    ///  * **equality**, case-folded, against every component — macOS names a
    ///    cache directory after the application that writes it;
    ///  * **prefix**, only for aliases containing a dot, so `com.apple.Safari`
    ///    also claims `com.apple.Safari.SafeBrowsing`, while the name `Firefox`
    ///    does not claim `Firefox Developer Edition`.
    ///
    /// Every component is compared rather than the last one, because the shape
    /// differs by rule: the wildcard component in
    /// `Containers/*/Data/Library/Caches` is the owner, while in
    /// `Caches/<bundle-id>` the last component is. Matching too much costs a
    /// `safe` item its pre-selection; matching too little moves a directory out
    /// from under a running application.
    public static func isOwnedByRunningApplication(_ path: String, tokens: [String]) -> Bool {
        let aliases = tokens
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        return normalize(path).split(separator: "/").contains { component in
            let name = String(component).lowercased()
            // A suffixed name is compared both as it is written and without the
            // suffix, so `com.apple.Safari.savedState` matches the identifier.
            let trimmed = Self.appOwnedNameSuffixes
                .first { name.hasSuffix($0) }
                .map { String(name.dropLast($0.count)) }
            func owned(_ candidate: String) -> Bool {
                aliases.contains { alias in
                    candidate == alias
                        || (alias.contains(".") && candidate.hasPrefix("\(alias)."))
                }
            }
            if owned(name) { return true }
            return trimmed.map(owned) ?? false
        }
    }

    /// True when the path is a macOS package that must be handled as one unit.
    public func isPackageDirectory(name: String) -> Bool {
        guard let extensionPart = name.split(separator: ".").last.map(String.init)?.lowercased() else {
            return false
        }
        return Self.packageExtensions.contains(extensionPart)
    }

    /// True for a bundle identifier whose data must never be offered for removal.
    public func isExcludedBundleName(_ name: String) -> Bool {
        Self.excludedBundleNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// True when any component of `path` is an excluded application's data.
    ///
    /// Excluding a directory is not excluding what is inside it: a large or old
    /// file found by a threshold scan has its own name, so the check has to walk
    /// the ancestors rather than look at the last component. The same predicate
    /// guards the walk, the pre-flight check and the move, so a path cannot enter
    /// the queue through one entry point and be refused by another.
    public func isInExcludedLocation(_ path: String) -> Bool {
        let resolved = Self.normalize(path)
        return resolved
            .split(separator: "/")
            .contains { isExcludedBundleName(String($0)) }
    }

    /// True when a rule's `excludes` covers any component below its root.
    ///
    /// A rule that excludes a directory means the subtree, not only an entry
    /// whose own name happens to match: `~/Library/Caches/CloudKit` excluded from
    /// a `Caches` rule must also drop `CloudKit/db.bin` when the rule scans files.
    /// Both engines apply this from the same shape.
    public func isExcludedByRule(_ rule: Rule, path: String, under root: String) -> Bool {
        guard !rule.excludes.isEmpty else { return false }
        let pathComponents = Self.normalize(path).split(separator: "/")
        let rootComponents = Self.normalize(root).split(separator: "/")
        guard pathComponents.starts(with: rootComponents) else { return false }
        let relative = pathComponents.dropFirst(rootComponents.count)
        return relative.contains { component in
            let name = String(component)
            return rule.excludes.contains { name == $0 || name.hasPrefix($0 + ".") }
        }
    }

    /// True when offering the children of `relativePath` would expose the data
    /// root of an application.
    ///
    /// The loader already refuses a rule whose *item* is a container, and
    /// `<container>/*` with anything but `directoriesNamed`. Those two checks do
    /// not cover the shape a generated draft uses — `childDirectories` over
    /// `Application Support/<vendor>` offers `Application Support/<vendor>/<app>`,
    /// which is an application's whole data root — so a draft asks this before it
    /// is written, and the page refuses instead of handing over a rule that would
    /// move someone's browser profile in one item.
    public static func childrenWouldExposeApplicationData(_ relativePath: String) -> Bool {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let first = components.first else { return false }
        let isContainer = ProtectedPaths.forbiddenRuleDirectories.contains {
            $0.caseInsensitiveCompare(first) == .orderedSame
        }
        // One component: the items are the container's children. Two: the items are
        // the products inside a vendor folder, which is the same shape one level
        // down.
        return isContainer && components.count <= 2
    }

    /// True when the path names a photo library package.
    ///
    /// Case-insensitive on purpose. A protection rule that only matched
    /// `.photoslibrary` exactly could be sidestepped by renaming the package to
    /// `.PhotosLibrary` on a case-insensitive volume; the suffix is a safety net,
    /// so it errs on the side of refusing. The Rust core applies the same rule.
    public static func isPhotoLibrary(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let suffix = ProtectedPaths.photosLibrarySuffix.lowercased()
        return lowered.hasSuffix(suffix) || lowered.contains("\(suffix)/")
    }

    /// The recycle-bin component a path names, or `nil` when it names none.
    ///
    /// Whole-component and case-folded, like the Rust check: `.Trash` and
    /// `.Trashes` are two names of one thing, `/Volumes/Backup/.Trashes/501` is
    /// the same bin as the one in the home folder, and a folder called
    /// `.Trash-notes` is an ordinary folder.
    public static func recycleBinComponent(_ path: String) -> String? {
        normalize(path).split(separator: "/").lazy
            .map(String.init)
            .first { component in
                ProtectedPaths.recycleBinNames.contains {
                    $0.caseInsensitiveCompare(component) == .orderedSame
                }
            }
    }

    /// The forbidden directory a rule's relative path names, if it names one.
    ///
    /// These hold the live data of *every* application at once, and a rule can
    /// only match a name shape or an age — it cannot know whether an
    /// application is installed. The shipped table is asserted against this
    /// list; `decode` refuses a rule file that names one, so the same invariant
    /// covers a rule this build does not ship. The Rust loader reads the list
    /// from the same constants.
    public static func forbiddenRuleDirectory(
        _ relativePath: String,
        matchSpec: MatchSpec? = nil
    ) -> String? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .map(String.init)
        let forbidden: (String) -> String? = { name in
            ProtectedPaths.forbiddenRuleDirectories.first {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        // The container is the item — `Containers`, or any path ending in it.
        if let last = components.last, let name = forbidden(last) { return name }
        // `<container>/*`: the container's own children, one item per installed
        // application — unless the specification names what to look for inside
        // them, which is what `directoriesNamed` does. `Application Support/*`
        // with `childDirectories` offers every application's data root; with
        // `directoriesNamed ["Cache"]` it offers one named cache directory per
        // application, which is the rule this build ships.
        if components.count == 2, components[1] == ProtectedPaths.relativePathWildcard,
           case .directoriesNamed = matchSpec {
            return nil
        }
        if components.count == 2, components[1] == ProtectedPaths.relativePathWildcard,
           let name = forbidden(components[0]) {
            return name
        }
        return nil
    }

    /// True when a `directoriesNamed` rule's name set can match a directory.
    ///
    /// One or more names, each a single path component: no separator, no
    /// wildcard. An empty set matches nothing and a name carrying `/` or `*` is a
    /// path the author meant to put in `relativePath`, so both are refused where
    /// the file is read rather than silently finding nothing.
    public static func directoryNameSetIsValid(_ names: [String]) -> Bool {
        !names.isEmpty && names.allSatisfy { name in
            !name.isEmpty
                && !name.contains("/")
                && !name.contains("*")
                && name != "."
                && name != ".."
        }
    }

    /// True when a `relativePath` uses only the wildcard this build understands.
    ///
    /// A component is either a literal name or exactly `*`, matching one
    /// directory name. Partial shapes (`com.apple.*`), recursive shapes (`**`)
    /// and a leading wildcard are refused: the first two say something the
    /// scanner cannot enumerate safely, and a leading `*` would make one rule
    /// span every child of its anchor. The Rust loader applies the same rule.
    public static func relativePathGlobIsValid(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return true }
        guard first != ProtectedPaths.relativePathWildcard else { return false }
        return components.allSatisfy {
            !$0.contains("*") || $0 == ProtectedPaths.relativePathWildcard
        }
    }

    /// True when a name can only be a reverse-DNS bundle identifier.
    ///
    /// Used before treating a folder as application residue: a folder the user
    /// created (`~/Library/Application Support/Editor`) must never match (§5.3).
    public func looksLikeBundleIdentifier(_ name: String) -> Bool {
        guard !name.contains(" ") else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard parts[0].count >= 2, parts[0].allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        guard parts[1].count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
    }

    /// Resolves a rule anchor to the directories it applies under.
    ///
    /// Most anchors name one directory that can be resolved when the rule is
    /// written. The two authorised anchors cannot: they mean "the locations the
    /// user granted", which a rule file never sees, so they resolve to every
    /// grant with the rule's `relativePath` applied inside each. The result is
    /// empty when nothing has been authorised, which is what keeps a rule from
    /// widening itself onto a tree nobody opened.
    ///
    /// `externalVolume` covers mounted volumes only. A folder inside a volume and
    /// a folder inside home are grants, but they are not volumes, and treating
    /// them as one would apply a volume-wide rule to a folder.
    public func resolvedRoots(for rule: Rule) -> [URL] {
        let isExcluded = { (name: String) in
            rule.excludes.contains { name == $0 || name.hasPrefix($0 + ".") }
        }
        let roots: [URL]
        switch rule.root {
        case .home:
            roots = Self.roots(
                under: homeDirectory,
                relativePath: rule.relativePath,
                isExcluded: isExcluded
            )
        case .homeLibrary:
            roots = Self.roots(
                under: "\(homeDirectory)/Library",
                relativePath: rule.relativePath,
                isExcluded: isExcluded
            )
        case .applications:
            roots = Self.roots(
                under: "/Applications",
                relativePath: rule.relativePath,
                isExcluded: isExcluded
            )
        case .systemLibrary:
            roots = Self.roots(
                under: "/Library",
                relativePath: rule.relativePath,
                isExcluded: isExcluded
            )
        case .userTemp:
            // The session directory, resolved once by the process and handed to
            // the Rust core in the request's roots. `nil` means this session has
            // no such directory, which resolves to nothing rather than to a
            // guess: `/var/folders` holds every user's session.
            roots = (userTempDirectory.map { [$0] } ?? []).flatMap { base in
                Self.roots(
                    under: base,
                    relativePath: rule.relativePath,
                    isExcluded: isExcluded
                )
            }
        case .authorized, .externalVolume:
            // Never guessed from a mount point name: only roots the user
            // actually authorised are considered (§8.3).
            let grants = rule.root == .externalVolume
                ? effectiveAuthorizedPaths.filter { Self.isMountedVolume($0) }
                : effectiveAuthorizedPaths
            roots = grants.sorted().flatMap { grant in
                Self.roots(
                    under: grant,
                    relativePath: rule.relativePath,
                    isExcluded: isExcluded
                )
            }
        }
        // An anchor is a place to look inside, never a cleanup item. This also
        // catches `root: home, relativePath: "Library"`, which is spelled as a
        // descendant but resolves to the container.
        return roots.filter { !isCleanupContainer($0.path) }
    }

    /// True when `path` is a container rather than a cleanup target.
    ///
    /// `~/Library` and the other containers remain scannable (the product lives
    /// inside them), but they are never a single item: moving one would take
    /// every application's data with it.
    public func isCleanupContainer(_ path: String) -> Bool {
        Self.isCleanupContainer(path, home: homeDirectory)
    }

    static func isCleanupContainer(_ path: String, home: String) -> Bool {
        // Case-folded: `~/library` is `~/Library` on a default APFS volume.
        let path = normalize(path).lowercased()
        let home = normalize(home).lowercased()
        return path == home
            || path == "\(home)/library"
            || path == "\(home)/applications"
            || ["/", "/volumes", "/applications", "/library"].contains(path)
    }

    /// The roots inside `base` that `relativePath` names, collapsed.
    ///
    /// Empty when the relative path would leave `base`, or when it is empty: an
    /// anchor is not a cleanup item. `decode` already refuses such a file, so
    /// this is the second line rather than the only one: it also covers the
    /// built-in table, and it is what makes the path the engine walks the same
    /// one the protection check judges. Without it
    /// `/Users/alice/Library/../../Shared` is checked as `/Users/Shared` and
    /// walked as written.
    ///
    /// Only lexical collapsing — `.`, `..`, duplicate separators — plus the
    /// `*` expansion described below. The alias mapping stays out of it:
    /// rewriting `/var/folders/...` to its `/private` spelling here would leave a
    /// root that no longer matches the request that authorised it.
    ///
    /// A `*` component is expanded against the disk: one directory listing per
    /// wildcard, never a substring or a recursive match, so
    /// `Containers/*/Data/Library/Caches` is one root per installed application.
    /// The enumerated names are the only thing this adds to the path, so a rule
    /// still cannot reach outside its anchor. The Rust core expands the same
    /// wildcard with the same bound (`expand_relative_path`).
    /// - Parameter isExcluded: names the rule's `excludes` list covers, checked
    ///   against every component the rule itself supplies. A wildcard is part of
    ///   the path a rule names, so `excludes: ["com.apple"]` has to cover the
    ///   directory the `*` matched, not only what is inside it.
    static func roots(
        under base: String,
        relativePath: String,
        isExcluded: (String) -> Bool = { _ in false }
    ) -> [URL] {
        // An absolute relative path is not a descendant. The join here is
        // textual, so it *reads* as a child named `etc`, while on the Rust side
        // `Path::join` replaces the anchor with it outright: refusing it is what
        // keeps one rule from meaning two things.
        guard !relativePath.hasPrefix("/") else { return [] }
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return [] }

        let basePath = collapse(base)
        var current = [basePath]
        for component in components {
            if component == ProtectedPaths.relativePathWildcard {
                var next: [String] = []
                for directory in current {
                    next.append(
                        contentsOf: childDirectories(of: directory).filter { path in
                            !isExcluded((path as NSString).lastPathComponent)
                        }
                    )
                    if next.count >= ProtectedPaths.maximumRuleRoots { break }
                }
                current = next
            } else {
                if isExcluded(component) { return [] }
                current = current.map { collapse("\($0)/\(component)") }
            }
            if current.isEmpty { break }
        }
        return current
            .filter { isPrefix(basePath, $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The directories directly inside `directory`, sorted, symlinks excluded.
    ///
    /// A link inside `Containers` is not a container, and following one would put
    /// a root outside the tree the rule named. An unreadable directory
    /// contributes nothing: the rule simply finds nothing there.
    static func childDirectories(of directory: String) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().compactMap { name in
            let path = collapse("\(directory)/\(name)")
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let attributes = try? manager.attributesOfItem(atPath: path),
                  (attributes[.type] as? FileAttributeType) != .typeSymbolicLink
            else { return nil }
            return path
        }
    }

    /// True for the mount point of a volume rather than a folder on one.
    static func isMountedVolume(_ path: String) -> Bool {
        guard isPrefix("/Volumes", path) else { return false }
        return (path as NSString).deletingLastPathComponent == "/Volumes"
    }

    // MARK: - Rule matching

    /// True when `rule` claims `path`.
    ///
    /// Matched against the rule's *pattern* rather than against roots resolved on
    /// disk: `risk(for:)` runs for every row of a pre-flight, and resolving a
    /// wildcard there would list directories once per candidate. The components
    /// compared are the ones `resolvedRoots` walks, so both agree on what a rule
    /// covers — one by naming roots, the other by matching a path against them.
    private func matches(rule: Rule, path: String) -> Bool {
        guard rule.isEnabled, rule.risk != .protected else { return false }

        let pattern = rule.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        // An empty relative path names the anchor, which is a container rather
        // than an item: `resolvedRoots` answers nothing for it, and so does this.
        guard !pattern.isEmpty else { return false }

        let pathComponents = Self.normalize(path).split(separator: "/").map(String.init)

        for base in anchorBases(for: rule) {
            let baseComponents = Self.normalize(base).split(separator: "/").map(String.init)
            guard pathComponents.count >= baseComponents.count,
                  Array(pathComponents.prefix(baseComponents.count)) == baseComponents
            else { continue }

            let relative = Array(pathComponents.dropFirst(baseComponents.count))
            guard let matchedCount = Self.matchedComponents(pattern, against: relative) else {
                continue
            }

            let rootPath = Self.path(
                from: baseComponents + Array(relative.prefix(matchedCount))
            )
            // The rule's own components count as well: an exclusion naming the
            // directory a `*` matched (`com.apple`) has to drop the whole root,
            // exactly as `resolvedRoots` drops it.
            if isExcludedByRule(rule, path: rootPath, under: base) { return false }
            if isExcludedByRule(rule, path: path, under: rootPath) { return false }

            switch rule.matchSpec {
            case .directory:
                return Self.normalize(path) == rootPath
            case .childDirectories:
                return relative.count == pattern.count + 1
            case let .directoriesNamed(names):
                guard relative.count == pattern.count + 1 else { return false }
                guard let name = relative.last else { return false }
                return names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case let .filesByExtension(extensions):
                let fileExtension = (path as NSString).pathExtension.lowercased()
                return extensions.contains(fileExtension)
            case .anyFile:
                return true
            case nil:
                // Default follows the rule shape: a relative path means the
                // directory itself, no relative path means its children (which
                // the guard above already refused as a container).
                return Self.normalize(path) == rootPath
            }
        }
        return false
    }

    /// The anchor directories a rule can apply under, as paths.
    ///
    /// The two authorised anchors mean "the locations the user granted", which a
    /// rule file never sees; the rest are fixed. Nothing is read from the disk:
    /// this is the set the filesystem expansion starts from.
    private func anchorBases(for rule: Rule) -> [String] {
        switch rule.root {
        case .home:
            return [homeDirectory]
        case .homeLibrary:
            return ["\(homeDirectory)/Library"]
        case .applications:
            return ["/Applications"]
        case .systemLibrary:
            return ["/Library"]
        case .userTemp:
            return userTempDirectory.map { [$0] } ?? []
        case .authorized:
            return effectiveAuthorizedPaths.sorted()
        case .externalVolume:
            return effectiveAuthorizedPaths.filter { Self.isMountedVolume($0) }.sorted()
        }
    }

    /// How many components of `pattern` match `relative`, or `nil` when they do
    /// not.
    ///
    /// A `*` component matches exactly one directory name. The returned count is
    /// the length of the pattern, so the caller can turn the matched prefix back
    /// into the root path the rule names.
    static func matchedComponents(_ pattern: [String], against relative: [String]) -> Int? {
        guard relative.count >= pattern.count else { return nil }
        for (expected, actual) in zip(pattern, relative) {
            if expected == ProtectedPaths.relativePathWildcard {
                if actual.isEmpty { return nil }
                continue
            }
            guard expected == actual else { return nil }
        }
        return pattern.count
    }

    /// A filesystem path from its components, spelled the way `normalize` spells
    /// one.
    static func path(from components: [String]) -> String {
        "/" + components.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func rank(_ risk: CleanupRisk) -> Int {
        switch risk {
        case .safe: 0
        case .review: 1
        case .protected: 2
        }
    }

    // MARK: - Loading

    private static func bundledRules() -> [Rule] {
        if let url = Bundle.module.url(forResource: "CleaningRules", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            if let rules = try? decode(data) {
                return sanitized(rules)
            }
            logger.error("The bundled rule file could not be decoded; using the built-in table")
        }
        return builtInRules
    }

    /// The fallback table, used when the bundled rule file cannot be read.
    ///
    /// Generated from the Rust table by `Scripts/generate-rules.py`, so this and
    /// the shipped file are the same rules rather than two transcriptions of one
    /// list — the two had drifted, and the engines then recognised different sets
    /// of files while sharing one protection list.
    public static let builtInRules: [Rule] = BuiltInRules.table

    /// Decodes a rule file, rejecting unknown schema versions.
    ///
    /// Nothing is filtered out here. A rule the file switches off, or marks
    /// `protected`, has to reach [`merge`] so that it *replaces* the shipped rule
    /// of the same id and is dropped with it. Filtering first would drop the
    /// override instead and leave the shipped rule running, which is the opposite
    /// of what the file asked for — and it is what the Rust core, which merges
    /// before it filters, would not do.
    static func decode(_ data: Data) throws -> [Rule] {
        let decoder = JSONDecoder()
        let file = try decoder.decode(RuleFile.self, from: data)
        guard file.schemaVersion == supportedSchemaVersion else {
            throw RuleError.unsupportedSchemaVersion(file.schemaVersion)
        }
        var seen = Set<String>()
        for rule in file.rules {
            guard !rule.id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw RuleError.emptyRuleID
            }
            guard seen.insert(rule.id).inserted else {
                throw RuleError.duplicateRuleID(rule.id)
            }
            guard Self.relativePathStaysInsideAnchor(rule.relativePath) else {
                throw RuleError.escapingRelativePath(rule.relativePath)
            }
            // The three checks below are what keeps a rule file from describing
            // a rule the shipped table is not allowed to hold. They are refused
            // here, where the user is told the reason, rather than dropped when
            // the table is merged, where a rule would silently stop applying.
            // The Rust loader performs the same three checks against the same
            // constants, because a document one engine accepts and the other
            // refuses fails the whole scan.
            if let age = rule.minAgeDays, !(0...ProtectedPaths.maximumMinAgeDays).contains(age) {
                throw RuleError.invalidMinAgeDays(age)
            }
            if let forbidden = Self.forbiddenRuleDirectory(
                rule.relativePath,
                matchSpec: rule.matchSpec
            ) {
                throw RuleError.forbiddenRuleDirectory(forbidden)
            }
            if case let .directoriesNamed(names) = rule.matchSpec,
               !Self.directoryNameSetIsValid(names) {
                throw RuleError.directoriesNamedWithoutNames
            }
            guard Self.relativePathGlobIsValid(rule.relativePath) else {
                throw RuleError.unsupportedRelativePathWildcard(rule.relativePath)
            }
            if rule.matchSpec == .anyFile, rule.minAgeDays == nil {
                // `anyFile` with no age is "every file under this root": no
                // install of this product has a place where that is safe.
                throw RuleError.anyFileWithoutMinAge
            }
        }
        return file.rules
    }

    /// True when a `relativePath` only ever descends from its anchor.
    ///
    /// An absolute path does not descend at all — `Path::join` replaces the base
    /// and `appendingPathComponent` can escape it — and a `..` component climbs
    /// out: `/Users/alice/Library/../../Shared` reads as though it sits under the
    /// home directory and resolves to `/Users/Shared`. The check is per component,
    /// so a folder genuinely named `..notes` is still allowed. The Rust parser
    /// refuses the same two shapes.
    static func relativePathStaysInsideAnchor(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .allSatisfy { $0 != ".." && $0 != "." }
    }

    /// Merges an overlay on top of the base rules, replacing matching ids, then
    /// applies the enable/risk filter to the result.
    ///
    /// The order matters and matches `RuleSet::merge` in the Rust core: replace
    /// first, filter second. That is what lets a rule file switch a shipped rule
    /// off, and what stops one from retuning a rule into `protected` and leaving
    /// a hole where the shipped rule used to be.
    static func merge(base: [Rule], overlay: [Rule]) -> [Rule] {
        var merged = base
        for rule in overlay {
            if let index = merged.firstIndex(where: { $0.id == rule.id }) {
                merged[index] = rule
            } else {
                merged.append(rule)
            }
        }
        return sanitized(merged)
    }

    /// The rules that may run: enabled, not `protected`, naming no forbidden
    /// directory, and never a `safe` level this build did not review.
    ///
    /// `decode` already refuses a file that names a forbidden directory or
    /// pairs `anyFile` with no age, so this is the second line rather than the
    /// only one: it also covers the shipped table, which arrives as a literal
    /// rather than through a decoder. The Rust core applies the same three
    /// checks in `effective_rules` via `enforce_rule_invariants`.
    ///
    /// The clamp is the part that needs to know what this build ships. `safe`
    /// is the level that arrives pre-selected, and only a rule a release
    /// reviewed earns it: a rule the user added is offered at `review`, which
    /// still lets it find things and leaves the decision with the user. A rule
    /// that *replaces* a shipped id keeps its level — retuning a reviewed rule
    /// is what an overlay is for.
    ///
    /// The explicit-rule initialiser (`init(rules:homeDirectory:)`) bypasses
    /// this on purpose: it is the preview and test entry point, and a caller
    /// that hands the engine a table is the one deciding what it holds.
    private static func sanitized(_ rules: [Rule]) -> [Rule] {
        let shipped = Set(builtInRules.map(\.id))
        return rules.compactMap { rule in
            guard rule.isEnabled, rule.risk != .protected else { return nil }
            guard Self.forbiddenRuleDirectory(rule.relativePath, matchSpec: rule.matchSpec) == nil
            else { return nil }
            guard !(rule.matchSpec == .anyFile && rule.minAgeDays == nil) else { return nil }
            if case let .directoriesNamed(names) = rule.matchSpec,
               !Self.directoryNameSetIsValid(names) {
                return nil
            }
            guard rule.risk == .safe, !shipped.contains(rule.id) else { return rule }
            return rule.withRisk(.review)
        }
    }

    /// Errors a malformed rule file can produce.
    public enum RuleError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case escapingRelativePath(String)
        case emptyRuleID
        case duplicateRuleID(String)
        /// A `matchSpec` string this build does not understand.
        ///
        /// It is refused rather than treated as absent: deriving the default from
        /// the rule's shape would turn a misspelled `filesByExtension` into a
        /// rule over every file below the root, changing what the rule means
        /// instead of reporting that it could not be read.
        case unknownMatchSpec(String)
        /// A `minAgeDays` outside the range both engines accept.
        ///
        /// The Rust loader reads the field as a `u32` and refuses a negative
        /// one, so a value this decoder accepted and that engine could not
        /// parse would fail the whole scan with `invalidRequest` — the app would
        /// show "scan failed" with nothing pointing at the rule file.
        case invalidMinAgeDays(Int)
        /// A rule that targets a directory holding every application's data.
        case forbiddenRuleDirectory(String)
        /// A rule that matches every file with no age to limit it.
        case anyFileWithoutMinAge
        /// A `relativePath` wildcard this build does not understand.
        case unsupportedRelativePathWildcard(String)
        /// A `directoriesNamed` rule with no usable name.
        case directoriesNamedWithoutNames
    }

    // MARK: - Path helpers

    /// Collapses `.`, `..`, duplicate separators and well-known macOS symlink
    /// aliases, without touching the disk.
    ///
    /// The alias handling matters: `/var` is a symlink to `/private/var`, and
    /// `/tmp` to `/private/tmp`, so a path that arrives as `/var/folders/...`
    /// would otherwise never match a `/private/var` prefix in the protection
    /// list. The mapping is the fixed set macOS documents, so this stays a pure
    /// string transformation.
    static func normalize(_ path: String) -> String {
        let collapsed = collapse(path)
        // Read from the generated table rather than a literal here: the Rust
        // core normalises with the same list, and a private copy is how the two
        // engines came to disagree about `/var/db/...`.
        for entry in ProtectedPaths.symlinkAliases {
            // Compared on collapsed forms, never through `isPrefix`: that calls
            // `normalize` itself, and recursing here would not terminate.
            if collapsed == entry.alias {
                return entry.target
            }
            if collapsed.hasPrefix(entry.alias + "/") {
                return entry.target + collapsed.dropFirst(entry.alias.count)
            }
        }
        return collapsed
    }

    /// Collapses `.`, `..` and duplicate separators only.
    private static func collapse(_ path: String) -> String {
        var parts: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(segment))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when `prefix` is `path` or an ancestor of it.
    ///
    /// Both sides are normalised, and the comparison is component-wise so
    /// `/System` never matches `/Systematic`.
    ///
    /// This must not be called from `normalize`, which would not terminate:
    /// `normalize` performs the alias comparison itself, longhand.
    static func isPrefix(_ prefix: String, _ path: String) -> Bool {
        let prefix = normalize(prefix)
        let path = normalize(path)
        if prefix == "/" { return true }
        if path == prefix { return true }
        return path.hasPrefix(prefix + "/")
    }

    /// The protection list's comparison: case-folded, because macOS volumes are
    /// case-insensitive by default.
    ///
    /// `~/documents` and `~/library/keychains` resolve to the protected
    /// directories. Only the protection check folds case; rule matching keeps
    /// `isPrefix`, so a case-sensitive volume does not start matching a
    /// differently-cased sibling.
    static func isProtectedPrefix(_ prefix: String, _ path: String) -> Bool {
        let prefix = normalize(prefix).lowercased()
        let path = normalize(path).lowercased()
        if prefix == "/" { return true }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Component depth of `path` below `root`, or `nil` when outside it.
    static func relativeDepth(of path: String, under root: String) -> Int? {
        guard isPrefix(root, path) else { return nil }
        if path == root { return 0 }
        let remainder = path.dropFirst(root == "/" ? 1 : root.count + 1)
        return remainder.split(separator: "/").count
    }
}

/// The on-disk rule file shape (§8.4).
struct RuleFile: Decodable {
    let schemaVersion: Int
    let rules: [RuleEngine.Rule]
}

extension RuleEngine.Rule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case category
        case risk
        case root
        case relativePath
        case matchSpec
        case extensions
        case names
        case excludes
        case minAgeDays
        case usesStaleThreshold
        case requiresFullDiskAccess
        case needsAppClosed
        case explanationKey
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(CleanupCategory.self, forKey: .category)
        risk = try container.decode(CleanupRisk.self, forKey: .risk)
        root = try container.decode(RuleEngine.RootAnchor.self, forKey: .root)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        excludes = try container.decodeIfPresent([String].self, forKey: .excludes) ?? []
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
        usesStaleThreshold = try container.decodeIfPresent(Bool.self, forKey: .usesStaleThreshold) ?? false
        requiresFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .requiresFullDiskAccess) ?? false
        needsAppClosed = try container.decodeIfPresent(Bool.self, forKey: .needsAppClosed) ?? false
        explanationKey = try container.decode(String.self, forKey: .explanationKey)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        // The match specification is a string with the extension list beside it.
        // An unknown value is a decoding error, not "no specification": the
        // fallback derived from `relativePath` would quietly widen a misspelled
        // `filesByExtension` rule to every file under its root.
        let extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        let names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        if let spec = try container.decodeIfPresent(String.self, forKey: .matchSpec) {
            switch spec {
            case "directory":
                matchSpec = .directory
            case "childDirectories":
                matchSpec = .childDirectories
            case "filesByExtension":
                matchSpec = .filesByExtension(extensions.map { $0.lowercased() })
            case "anyFile":
                matchSpec = .anyFile
            case "directoriesNamed":
                matchSpec = .directoriesNamed(names)
            default:
                throw RuleEngine.RuleError.unknownMatchSpec(spec)
            }
        } else {
            matchSpec = nil
        }
    }
}
