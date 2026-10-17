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
            self.requiresFullDiskAccess = requiresFullDiskAccess
            self.explanationKey = explanationKey
            self.isEnabled = isEnabled
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

    /// Paths that are never scanned or cleaned, as children of the home folder.
    ///
    /// Compiled in: a rule file can widen what Sift *recognises*, never what it
    /// may *remove*.
    public static let protectedHomeChildren: Set<String> = [
        "Documents", "Desktop", "Movies", "Music", "Pictures", "Projects", "Developer", "Public",
    ]

    /// Absolute prefixes that are never scanned or cleaned.
    public static let protectedPrefixes: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr",
        "/etc",
        "/private/etc",
        "/private/var/db",
        "/private/var/vm",
        "/Library/Apple",
        "/Library/Extensions",
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
        "/Library/StagedExtensions",
        "/Volumes",
    ]

    /// Paths inside `~/Library` that hold secrets or user data.
    public static let protectedLibrarySuffixes: [String] = [
        "Library/Keychains",
        "Library/Mobile Documents",
        "Library/Accounts",
        "Library/Messages",
        "Library/Mail",
        "Library/Safari",
        "Library/Cookies",
    ]

    /// Extensions treated as one unit rather than individual files.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "mpkg", "photoslibrary",
        "pkg", "plugin", "prefpane", "qlgenerator", "xcodeproj", "xcworkspace",
    ]

    /// Bundle identifiers whose data must never be offered for deletion.
    public static let excludedBundleNames: Set<String> = [
        "CloudKit", "com.apple.bird", "com.apple.iCloud", "com.apple.cloudd", "FamilyCircle",
    ]

    public let rules: [Rule]
    /// Locations the user explicitly authorised in settings.
    ///
    /// Authorisation only lifts the blanket `/Volumes` and `/private/var` prefixes
    /// that exist to stop Sift scanning those trees by default. It never unlocks
    /// user content, keychains or a photos library.
    private let authorized: AuthorizedScope
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
        authorized: AuthorizedScope = AuthorizedScope()
    ) {
        // Resolved on the way in so every later comparison uses one spelling of
        // the path. `URL.resolvingSymlinksInPath` is used rather than
        // `FileManager` so a path that does not exist yet still resolves.
        self.homeDirectory = Self.normalize(homeDirectory.resolvingSymlinksInPath().path)
        self.authorized = authorized

        var table = Self.bundledRules()
        if let userRuleURL, let data = try? Data(contentsOf: userRuleURL) {
            do {
                let overlay = try Self.decode(data)
                table = Self.merge(base: table, overlay: overlay)
                Self.logger.info("Loaded \(overlay.count) extra rules from the user rule file")
            } catch {
                // Fail soft: the shipped rules stay in force, and the reason is
                // logged without the file's path.
                Self.logger.error(
                    "User rule file rejected (\(String(describing: error)); keeping built-in rules)"
                )
            }
        }
        self.rules = table
    }

    /// Test and preview initialiser with an explicit rule list.
    public init(
        rules: [Rule],
        homeDirectory: URL,
        authorized: AuthorizedScope = AuthorizedScope()
    ) {
        self.rules = rules
        self.homeDirectory = Self.normalize(homeDirectory.path)
        self.authorized = authorized
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

        for child in Self.protectedHomeChildren where Self.isPrefix("\(homeDirectory)/\(child)", resolved) {
            return .userContent(child)
        }
        for suffix in Self.protectedLibrarySuffixes
        where Self.isPrefix("\(homeDirectory)/\(suffix)", resolved) {
            return .secrets(suffix)
        }
        if resolved.hasSuffix(".photoslibrary") || resolved.contains(".photoslibrary/") {
            return .photosLibrary
        }
        // Everything above is a hard rule. Only the blanket prefixes below can be
        // lifted by an explicit grant, which is what makes an external volume the
        // user added usable while `/Volumes` stays closed by default.
        if authorized.contains(resolved) {
            return nil
        }
        for prefix in Self.protectedPrefixes where Self.isPrefix(prefix, resolved) {
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
        if Self.isPrefix("\(homeDirectory)/Documents", path)
            || Self.isPrefix("\(homeDirectory)/Desktop", path)
            || Self.isPrefix("\(homeDirectory)/Movies", path)
            || Self.isPrefix("\(homeDirectory)/Music", path)
            || Self.isPrefix("\(homeDirectory)/Pictures", path)
        {
            return false
        }
        for suffix in Self.protectedLibrarySuffixes
        where Self.isPrefix("\(homeDirectory)/\(suffix)", path) {
            return false
        }
        if path.hasSuffix(".photoslibrary") || path.contains(".photoslibrary/") {
            return false
        }
        // `/System` and its siblings are not merely unauthorised, they are
        // outside what the product may ever touch.
        for prefix in ["/System", "/bin", "/sbin", "/usr", "/etc", "/private/etc"] {
            if Self.isPrefix(prefix, path) { return false }
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

    /// Resolves a rule anchor to a concrete directory.
    public func resolvedRoot(for rule: Rule, authorizedRoots: [URL] = []) -> URL? {
        switch rule.root {
        case .home:
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(rule.relativePath)
        case .homeLibrary:
            URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library")
                .appendingPathComponent(rule.relativePath)
        case .applications:
            URL(fileURLWithPath: "/Applications").appendingPathComponent(rule.relativePath)
        case .systemLibrary:
            URL(fileURLWithPath: "/Library").appendingPathComponent(rule.relativePath)
        case .authorized, .externalVolume:
            // Never guessed from a mount point name: only roots the user
            // actually authorised are considered (§8.3).
            authorizedRoots.first { $0.path.hasPrefix(homeDirectory) == false }
        }
    }

    // MARK: - Rule matching

    private func matches(rule: Rule, path: String) -> Bool {
        guard rule.isEnabled, rule.risk != .protected else { return false }
        guard let root = resolvedRoot(for: rule) else { return false }
        let rootPath = Self.normalize(root.path)
        guard Self.isPrefix(rootPath, path) else { return false }

        let name = (path as NSString).lastPathComponent
        if rule.excludes.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { return false }

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
                return rules
            }
            logger.error("The bundled rule file could not be decoded; using the built-in table")
        }
        return builtInRules
    }

    /// The fallback table, identical in effect to `CleaningRules.json`.
    ///
    /// Present so a packaging mistake cannot leave the app with no rules at all,
    /// which would silently make every scan return nothing.
    public static let builtInRules: [Rule] = [
        Rule(
            id: "user-cache",
            category: .applicationCache,
            risk: .safe,
            root: .homeLibrary,
            relativePath: "Caches",
            matchSpec: .childDirectories,
            excludes: ["CloudKit", "com.apple.bird", "com.apple.iCloud", "FamilyCircle"],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.cache",
            isEnabled: true
        ),
        Rule(
            id: "user-cache-sandboxed",
            category: .applicationCache,
            risk: .review,
            root: .homeLibrary,
            relativePath: "Containers",
            matchSpec: .directory,
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.cache",
            isEnabled: true
        ),
        Rule(
            id: "user-logs",
            category: .logs,
            risk: .safe,
            root: .homeLibrary,
            relativePath: "Logs",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: 30,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.logs",
            isEnabled: true
        ),
        Rule(
            id: "user-saved-state",
            category: .temporaryFiles,
            risk: .safe,
            root: .homeLibrary,
            relativePath: "Saved Application State",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: nil,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.savedState",
            isEnabled: true
        ),
        Rule(
            id: "download-installers",
            category: .installers,
            risk: .review,
            root: .home,
            relativePath: "Downloads",
            matchSpec: .filesByExtension(["dmg", "pkg", "mpkg", "xip", "iso"]),
            excludes: [],
            minAgeDays: 30,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.installers",
            isEnabled: true
        ),
        Rule(
            id: "download-archives",
            category: .installers,
            risk: .review,
            root: .home,
            relativePath: "Downloads",
            matchSpec: .filesByExtension(["zip", "tar", "gz", "tgz"]),
            excludes: [],
            minAgeDays: 90,
            requiresFullDiskAccess: false,
            explanationKey: "cleanup.explanation.installers",
            isEnabled: true
        ),
        Rule(
            id: "system-logs",
            category: .logs,
            risk: .review,
            root: .systemLibrary,
            relativePath: "Logs",
            matchSpec: .childDirectories,
            excludes: [],
            minAgeDays: 30,
            requiresFullDiskAccess: true,
            explanationKey: "cleanup.explanation.systemLogs",
            isEnabled: true
        ),
    ]

    /// Decodes a rule file, rejecting unknown schema versions.
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
        }
        return file.rules.filter { $0.isEnabled && $0.risk != .protected }
    }

    /// Merges an overlay on top of the base rules, replacing matching ids.
    static func merge(base: [Rule], overlay: [Rule]) -> [Rule] {
        var merged = base
        for rule in overlay {
            if let index = merged.firstIndex(where: { $0.id == rule.id }) {
                merged[index] = rule
            } else {
                merged.append(rule)
            }
        }
        return merged
    }

    /// Errors a malformed rule file can produce.
    public enum RuleError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case emptyRuleID
        case duplicateRuleID(String)
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
        for entry in Self.symlinkAliases {
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

    /// One directory alias macOS ships as a symlink.
    ///
    /// A named struct rather than a tuple: a global `let` of tuples is not
    /// `Sendable` under strict concurrency, and the compiler's metadata lookup
    /// for it does not terminate.
    struct SymlinkAlias: Sendable {
        let alias: String
        let target: String
    }

    /// The directory aliases macOS ships as symlinks.
    static let symlinkAliases: [SymlinkAlias] = [
        SymlinkAlias(alias: "/var", target: "/private/var"),
        SymlinkAlias(alias: "/tmp", target: "/private/tmp"),
        SymlinkAlias(alias: "/etc", target: "/private/etc"),
    ]

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
        requiresFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .requiresFullDiskAccess) ?? false
        explanationKey = try container.decode(String.self, forKey: .explanationKey)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        // The match specification is written in one of two shapes: a string for
        // the simple cases, or an object carrying extensions.
        let spec = try container.decodeIfPresent(String.self, forKey: .matchSpec)
        let extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
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
            matchSpec = nil
        }
    }
}
