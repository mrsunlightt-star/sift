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
    }

    /// Where a rule's relative path is anchored.
    public enum RootAnchor: String, Sendable, CaseIterable, Codable {
        case home
        case homeLibrary
        case applications
        case systemLibrary
        case authorized
        case externalVolume
    }

    /// What a rule considers a match.
    public enum MatchSpec: Sendable, Hashable {
        case directory
        case childDirectories
        case filesByExtension([String])
        case anyFile
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
        authorizedSnapshot: [String]? = nil
    ) {
        // Resolved on the way in so every later comparison uses one spelling of
        // the path. `URL.resolvingSymlinksInPath` is used rather than
        // `FileManager` so a path that does not exist yet still resolves.
        self.homeDirectory = Self.normalize(homeDirectory.resolvingSymlinksInPath().path)
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
        authorizedSnapshot: [String]? = nil
    ) {
        self.rules = rules
        self.homeDirectory = Self.normalize(homeDirectory.path)
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
            authorizedSnapshot: paths
        )
    }

    /// The grants in force for this engine: the run snapshot when one exists,
    /// the shared scope otherwise.
    private var effectiveAuthorizedPaths: [String] {
        authorizedSnapshot ?? authorized.paths
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

        for child in ProtectedPaths.homeChildren where Self.isPrefix("\(homeDirectory)/\(child)", resolved) {
            return .userContent(child)
        }
        for entry in ProtectedPaths.libraryChildren
        where Self.isPrefix("\(homeDirectory)/\(entry.path)", resolved) {
            switch entry.kind {
            case .userContent: return .userContent(entry.path)
            case .secrets: return .secrets(entry.path)
            }
        }
        if Self.isPhotoLibrary(resolved) {
            return .photosLibrary
        }
        // A grant may lift the blanket `/Volumes` guard for exactly the subtree
        // the user added. It must never lift a real system prefix: granting
        // `/Library` or `/private/var` would otherwise expose launch daemons and
        // the system database, so authorisation is consulted only here.
        if Self.isPrefix("/Volumes", resolved) {
            if effectiveAuthorizedPaths.contains(where: { Self.isPrefix($0, resolved) }) {
                return nil
            }
            return .systemPath("/Volumes")
        }

        // Everything else in the protection list is a hard rule.
        for prefix in ProtectedPaths.prefixes where prefix != "/Volumes" && Self.isPrefix(prefix, resolved) {
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

        // An explicit allowlist: a grant is either one concrete volume or a
        // folder inside the user's own home. Nothing else is authorisable, which
        // is what keeps `/`, `/Library` and `/private/var` out of reach.
        if Self.isPrefix("/Volumes", path) {
            // `/Volumes` itself is the container of every disk, not a grant.
            return path != "/Volumes" && components.count >= 2
        }
        guard Self.isPrefix(homeDirectory, path), path != homeDirectory else {
            return false
        }

        // Every compiled-in rule that `protectionReason` refuses is also
        // unauthorisable: accepting a grant that the protection list would then
        // ignore would leave the settings page showing access the user does not
        // actually have. The list comes from the shared table for that reason.
        for child in ProtectedPaths.homeChildren
        where Self.isPrefix("\(homeDirectory)/\(child)", path) {
            return false
        }
        for entry in ProtectedPaths.libraryChildren
        where Self.isPrefix("\(homeDirectory)/\(entry.path)", path) {
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
    /// the risk level still refuses to act.
    public func risk(for path: String) -> CleanupRisk {
        if protectionReason(for: path) != nil { return .protected }
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
        switch rule.root {
        case .home:
            return Self.roots(under: homeDirectory, relativePath: rule.relativePath)
        case .homeLibrary:
            return Self.roots(
                under: "\(homeDirectory)/Library",
                relativePath: rule.relativePath
            )
        case .applications:
            return Self.roots(under: "/Applications", relativePath: rule.relativePath)
        case .systemLibrary:
            return Self.roots(under: "/Library", relativePath: rule.relativePath)
        case .authorized, .externalVolume:
            // Never guessed from a mount point name: only roots the user
            // actually authorised are considered (§8.3).
            let grants = rule.root == .externalVolume
                ? effectiveAuthorizedPaths.filter { Self.isMountedVolume($0) }
                : effectiveAuthorizedPaths
            return grants.sorted().flatMap { grant in
                Self.roots(under: grant, relativePath: rule.relativePath)
            }
        }
    }

    /// The roots inside `base` that `relativePath` names, collapsed.
    ///
    /// Empty when the relative path would leave `base`. `decode` already refuses
    /// such a file, so this is the second line rather than the only one: it also
    /// covers the built-in table, and it is what makes the path the engine walks
    /// the same one the protection check judges. Without it
    /// `/Users/alice/Library/../../Shared` is checked as `/Users/Shared` and
    /// walked as written.
    ///
    /// Only lexical collapsing — `.`, `..`, duplicate separators. The alias
    /// mapping stays out of it: rewriting `/var/folders/...` to its `/private`
    /// spelling here would leave a root that no longer matches the request that
    /// authorised it.
    static func roots(under base: String, relativePath: String) -> [URL] {
        // An absolute relative path is not a descendant. The join here is
        // textual, so it *reads* as a child named `etc`, while on the Rust side
        // `Path::join` replaces the anchor with it outright: refusing it is what
        // keeps one rule from meaning two things.
        guard !relativePath.hasPrefix("/") else { return [] }
        let basePath = collapse(base)
        let joined = relativePath.isEmpty ? basePath : collapse("\(basePath)/\(relativePath)")
        guard isPrefix(basePath, joined) else { return [] }
        return [URL(fileURLWithPath: joined)]
    }

    /// True for the mount point of a volume rather than a folder on one.
    static func isMountedVolume(_ path: String) -> Bool {
        guard isPrefix("/Volumes", path) else { return false }
        return (path as NSString).deletingLastPathComponent == "/Volumes"
    }

    // MARK: - Rule matching

    private func matches(rule: Rule, path: String) -> Bool {
        guard rule.isEnabled, rule.risk != .protected else { return false }
        // A rule can apply under several roots once it names an authorised
        // anchor; the first one the path sits under decides.
        let rootPaths = resolvedRoots(for: rule).map { Self.normalize($0.path) }
        guard let rootPath = rootPaths.first(where: { Self.isPrefix($0, path) }) else { return false }

        if isExcludedByRule(rule, path: path, under: rootPath) { return false }

        switch rule.matchSpec {
        case .directory:
            return path == rootPath
        case .childDirectories:
            return Self.relativeDepth(of: path, under: rootPath) == 1
        case let .filesByExtension(extensions):
            let fileExtension = (path as NSString).pathExtension.lowercased()
            return extensions.contains(fileExtension)
        case .anyFile:
            return true
        case nil:
            // Default follows the rule shape: a relative path means the directory
            // itself, no relative path means its children.
            return rule.relativePath.isEmpty
                ? Self.relativeDepth(of: path, under: rootPath) == 1
                : path == rootPath
        }
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

    /// The rules that may run: enabled, and not `protected`.
    private static func sanitized(_ rules: [Rule]) -> [Rule] {
        rules.filter { $0.isEnabled && $0.risk != .protected }
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
        case excludes
        case minAgeDays
        case usesStaleThreshold
        case requiresFullDiskAccess
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
        explanationKey = try container.decode(String.self, forKey: .explanationKey)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        // The match specification is a string with the extension list beside it.
        // An unknown value is a decoding error, not "no specification": the
        // fallback derived from `relativePath` would quietly widen a misspelled
        // `filesByExtension` rule to every file under its root.
        let extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
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
            default:
                throw RuleEngine.RuleError.unknownMatchSpec(spec)
            }
        } else {
            matchSpec = nil
        }
    }
}
