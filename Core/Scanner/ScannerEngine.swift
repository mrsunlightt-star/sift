import Foundation
import Shared

/// Which engine performs a scan.
///
/// The app ships the Rust engine and falls back to the Swift one when the Rust
/// binary is not linked (a plain `swift build` without the Rust step). Stating
/// this in the UI's diagnostics matters: a user comparing scan times should know
/// which core produced them.
public enum ScannerEngineKind: String, Sendable, CaseIterable {
    case rust
    case swift

    public var displayName: String {
        switch self {
        case .rust: "Rust scanner core"
        case .swift: "Swift scanner core"
        }
    }
}

/// What a scan should look for.
public struct ScanRequest: Sendable {
    /// The home directory the rules are anchored to.
    ///
    /// Explicit rather than implied: a scan of any other tree (a test fixture, a
    /// restored backup) must resolve rules against that tree, not against the
    /// process user's home.
    public var homeDirectory: URL
    /// Directories the scan may visit, resolved from the user's settings.
    public var roots: [ScanRoot]
    /// Large-file threshold in bytes (§5.4 default: 1 GB).
    public var largeFileThresholdBytes: Int64
    /// Old-file threshold in days (§5.4 default: 180).
    public var oldFileThresholdDays: Int
    /// Age at which a log or installer counts as stale (§5.2 default: 30 days).
    public var staleThresholdDays: Int
    /// Paths the user asked Sift never to visit.
    public var ignoredPaths: [String]
    /// Roots the user explicitly authorised.
    ///
    /// The Rust core receives these so its compiled-in `/Volumes` guard can be
    /// lifted for exactly these subtrees, and no others.
    public var authorizedRoots: [String]
    /// Bundle identifiers of installed apps, used for residue detection.
    public var installedBundleIdentifiers: [String]
    /// Whether entries whose name starts with `.` are part of the scan (§5.6).
    ///
    /// A scope, not a display filter: the setting decides what the engines
    /// produce, so the rows, the category totals and the report describe the same
    /// run. Defaults to `true` because a caller that says nothing gets the whole
    /// tree; the app sets it from the user's "show hidden files" preference.
    public var includeHiddenFiles: Bool
    /// Whether to run the duplicate-file pipeline.
    public var includeDuplicates: Bool
    /// Roots the duplicate pipeline may search. Empty means "use `roots`".
    public var duplicateRoots: [String]
    /// Validated extra rule definitions, handed to the Rust engine verbatim.
    ///
    /// The Swift engine reads the same file through `RuleEngine`, so both cores
    /// recognise the same set.
    public var extraRulesJSON: String?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots: [ScanRoot],
        largeFileThresholdBytes: Int64 = ScanDefaults.largeFileThresholdBytes,
        oldFileThresholdDays: Int = ScanDefaults.oldFileThresholdDays,
        staleThresholdDays: Int = ScanDefaults.staleThresholdDays,
        ignoredPaths: [String] = [],
        authorizedRoots: [String] = [],
        installedBundleIdentifiers: [String] = [],
        includeHiddenFiles: Bool = true,
        includeDuplicates: Bool = true,
        duplicateRoots: [String] = [],
        extraRulesJSON: String? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.roots = roots
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.oldFileThresholdDays = oldFileThresholdDays
        self.staleThresholdDays = staleThresholdDays
        self.ignoredPaths = ignoredPaths
        self.authorizedRoots = authorizedRoots
        self.installedBundleIdentifiers = installedBundleIdentifiers
        self.includeHiddenFiles = includeHiddenFiles
        self.includeDuplicates = includeDuplicates
        self.duplicateRoots = duplicateRoots
        self.extraRulesJSON = extraRulesJSON
    }
}

/// One directory a scan may visit.
public struct ScanRoot: Sendable, Hashable {
    public let url: URL
    public let anchor: RuleEngine.RootAnchor
    /// `false` for a root the user only wants measured, never cleaned.
    public let isCleanable: Bool
    public let maxDepth: Int?
    /// Volume identifier, used to report an unplugged external disk.
    public let volumeIdentifier: String?

    public init(
        url: URL,
        anchor: RuleEngine.RootAnchor = .authorized,
        isCleanable: Bool = true,
        maxDepth: Int? = nil,
        volumeIdentifier: String? = nil
    ) {
        self.url = url
        self.anchor = anchor
        self.isCleanable = isCleanable
        self.maxDepth = maxDepth
        self.volumeIdentifier = volumeIdentifier
    }
}

/// Defaults shared by the settings store, the scan request and the UI.
public enum ScanDefaults {
    public static let largeFileThresholdBytes: Int64 = 1024 * 1024 * 1024
    public static let oldFileThresholdDays = 180
    public static let staleThresholdDays = 30
    /// Small files are not worth reporting as duplicates or old files.
    public static let duplicateMinimumBytes: Int64 = 4 * 1024
    /// Files below this size are excluded from the old-file list.
    public static let oldFileMinimumBytes: Int64 = 10 * 1024 * 1024
    /// Caps for the analysis lists (§5.4).
    public static let topFileLimit = 500
    public static let topDirectoryLimit = 100
}

/// A running scan.
///
/// The protocol is deliberately pull-based: the scanner publishes coarse events
/// and the caller pages the detail rows. That is what keeps the Swift side from
/// holding a hundred thousand objects when scanning a full disk (§8.2).
public protocol ScanSession: Sendable {
    var id: String { get }

    /// Drains events produced since the last call.
    func pollEvents(maxEvents: Int) async -> [ScanEvent]
    /// True once the scan stopped producing results.
    func isFinished() async -> Bool
    /// Reads one page of results.
    func page(offset: Int, limit: Int, sort: ScanSort, category: CleanupCategory?) async throws -> ScanPage
    /// Reads duplicate groups, largest reclaimable first.
    func duplicateGroups(offset: Int, limit: Int) async throws -> [DuplicateGroup]
    /// Reads the members of one duplicate group.
    func duplicateMembers(groupID: Int64) async throws -> [DuplicateMember]
    /// Locations that could not be read.
    func skippedLocations() async -> [SkippedLocation]
    /// Requests cancellation. The engine stops at its next checkpoint.
    func cancel() async
}

/// One page of results.
public struct ScanPage: Sendable {
    public let items: [CleanupItemSummary]
    public let remaining: Int

    public init(items: [CleanupItemSummary], remaining: Int) {
        self.items = items
        self.remaining = remaining
    }
}

/// Sort orders the paging interface supports.
public enum ScanSort: String, Sendable, CaseIterable {
    case size
    case name
    case modified
    case category
}

/// Events a scan publishes.
public enum ScanEvent: Sendable {
    case phaseChanged(ScanPhase)
    case progress(ScanProgress)
    case itemsFound([CleanupItemSummary])
    case duplicateGroupFound(index: Int, memberCount: Int, reclaimableBytes: Int64)
    case locationSkipped(SkippedLocation)
    case completed(ScanReport)
    case failed(code: ErrorCode, message: String)
}

/// A scan engine.
///
/// `RustScannerEngine` is the production implementation; `SwiftScannerEngine`
/// produces identical results without the Rust binary and is what the test suite
/// runs against, so the protocol is exercised by both.
public protocol ScannerEngine: Sendable {
    /// Which core is behind this engine.
    var kind: ScannerEngineKind { get }

    /// Starts a scan. The call returns as soon as the engine has a session; the
    /// work continues on its own thread or task.
    func startScan(_ request: ScanRequest) async throws -> any ScanSession

    /// Analyses storage without producing cleanup items.
    ///
    /// `ignoredPaths` carries the user's "never visit" list into the analysis, so
    /// a location excluded from scans is excluded from the storage page too.
    func analyzeStorage(roots: [ScanRoot], ignoredPaths: [String]) async throws -> StorageAnalysis
}

public extension ScannerEngine {
    /// Analysis with no ignore list, for callers that have no settings scope.
    func analyzeStorage(roots: [ScanRoot]) async throws -> StorageAnalysis {
        try await analyzeStorage(roots: roots, ignoredPaths: [])
    }
}

/// Errors a scanner can raise, always carrying a code the UI can act on.
public struct ScannerError: Error, Sendable, LocalizedError {
    public let code: ErrorCode
    public let message: String

    public init(code: ErrorCode, message: String? = nil) {
        self.code = code
        self.message = message ?? code.localizedTitle.localized
    }

    public var errorDescription: String? { message }
}
