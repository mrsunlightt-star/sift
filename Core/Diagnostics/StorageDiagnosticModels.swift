import Foundation
import Shared

/// System space diagnostics: what occupies the disk, what it is, and what may be
/// done about it.
public enum StorageDiagnostics {
    /// How many directory entries one measurement may visit before it stops and
    /// reports an estimate.
    ///
    /// A whole-volume analysis has to stay responsive and cancellable, so a
    /// measurement is bounded rather than exhaustive. When the budget runs out the
    /// finding says its size is approximate instead of quietly reporting a partial
    /// total as a whole one.
    public static let defaultMeasurementBudget = 200_000
}

/// A finding: something that occupies space, what it is, and what may be done
/// about it.
///
/// Deliberately a different model from a cleanup item. A cleanup item is a
/// promise that a file may be moved to the Trash; a finding is a statement about
/// a location, most of which Sift will never touch. The two must not be
/// conflated: `StorageFinding` carries no selection state, no risk level and no
/// route into `CleanupModel`, so widening what the product can *see* cannot widen
/// what it may remove.
public struct StorageFinding: Sendable, Identifiable, Hashable {
    /// Stable identity derived from the provider and the location, never a fresh
    /// random value: re-running the analysis must produce the same list.
    public let id: String
    /// Which provider reported it.
    public let providerID: String
    /// The location, when the finding is about one.
    public let path: URL?
    public let displayName: String
    public let category: StorageFindingCategory
    public let status: StorageFindingStatus
    /// Space the file system actually allocated. Zero when it could not be read,
    /// which `fileCount == nil` distinguishes from a genuinely empty location.
    public let allocatedBytes: Int64
    /// Sum of the file sizes. Differs from `allocatedBytes` for sparse files,
    /// clones and compressed files.
    public let logicalBytes: Int64?
    /// Files inside the location, when it could be measured.
    public let fileCount: Int64?
    /// When the location was last changed, when the system reports it.
    public let modifiedAt: Date?
    /// The sentence the user reads. A key rather than a string so a typo cannot
    /// reach the UI as a raw identifier.
    public let explanationKey: LocalizationKey
    public let remediation: StorageRemediation
    /// True when the compiled-in protection list refuses this path. Set by the
    /// engine rather than by a provider: a provider states what it found, and the
    /// protection decision is made in one place.
    public let isProtected: Bool
    /// True when the size is an estimate.
    ///
    /// APFS clones and sparse files make allocated sizes non-additive, and a
    /// measurement that hit its budget is incomplete. The UI says so rather than
    /// presenting an approximation as a fact.
    public let isApproximate: Bool

    public init(
        providerID: String,
        path: URL?,
        displayName: String,
        category: StorageFindingCategory,
        status: StorageFindingStatus,
        allocatedBytes: Int64,
        logicalBytes: Int64? = nil,
        fileCount: Int64? = nil,
        modifiedAt: Date? = nil,
        explanationKey: LocalizationKey,
        remediation: StorageRemediation,
        isProtected: Bool = false,
        isApproximate: Bool = false
    ) {
        self.providerID = providerID
        self.path = path
        self.displayName = displayName
        self.category = category
        self.status = status
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.explanationKey = explanationKey
        self.remediation = remediation
        self.isProtected = isProtected
        self.isApproximate = isApproximate
        self.id = "\(providerID):\(path?.path ?? displayName)"
    }
}

/// What kind of data a finding describes.
public enum StorageFindingCategory: String, Sendable, CaseIterable, Hashable {
    /// The volume-level Spotlight store (`.Spotlight-V100`).
    case spotlightIndex
    /// The per-user Core Spotlight store (`~/Library/Metadata/CoreSpotlight`).
    case coreSpotlightIndex
    /// An index a development tool maintains.
    case developerIndex
    /// A database an application owns.
    ///
    /// Reserved: no provider reports this yet. It exists so a future
    /// app-database provider (spec §5.5) does not have to invent a category, and
    /// the specification requires such a provider to identify data by application
    /// and a fixed path pattern rather than by a name that looks similar.
    case applicationDatabase
    /// An APFS local snapshot.
    case filesystemSnapshot
    /// Rebuildable system storage that is not an index.
    case systemCache
    /// System data that may not be touched: the operating system, its libraries.
    case systemData
    /// The user's own data.
    case userData
    /// Nothing reliable could be said about it.
    case unknown

    /// How specific the category is, used to settle a collision on one path.
    ///
    /// Several providers can see the same directory — the volume provider lists
    /// every child of a volume root, including `.Spotlight-V100`, which the
    /// Spotlight provider knows more about. The more specific statement wins,
    /// because "this is the Spotlight index" is more useful than "this is a
    /// directory".
    var specificity: Int {
        switch self {
        case .unknown: 0
        case .systemData, .userData, .systemCache: 1
        case .spotlightIndex, .coreSpotlightIndex, .developerIndex,
             .applicationDatabase, .filesystemSnapshot: 2
        }
    }
}

/// What may be done with a finding.
public enum StorageFindingStatus: String, Sendable, CaseIterable, Hashable {
    /// May be offered for the Trash, subject to the existing cleanup chain.
    case cleanable
    /// The system or its owning application regenerates it. Removing the
    /// directory by hand is not the supported way to reclaim the space.
    case rebuildable
    /// Shown and explained only. It never enters a deletion queue.
    case protected
    /// Cannot be judged reliably.
    case unknown

    /// True only for `cleanable`: the one status that may precede a Trash action.
    public var allowsTrashAction: Bool { self == .cleanable }
}

/// What the user can do about a finding.
public enum StorageRemediation: Sendable, Hashable {
    /// Move it to the Trash through the existing cleanup chain, item by item.
    case trash
    /// Have the index rebuilt by the mechanism that owns it.
    case rebuild(StorageRebuildMechanism)
    /// Nothing to do through Sift: the finding explains what the space is.
    case inspectOnly
}

/// The mechanism that rebuilds an index.
///
/// Named rather than executed. This build only explains: running a maintenance
/// command is phase three of the design and needs its own confirmation flow, so a
/// finding states which mechanism applies and Sift does not touch the system.
public enum StorageRebuildMechanism: String, Sendable, CaseIterable, Hashable {
    /// Spotlight's own reindex command, `mdutil -E <volume>`.
    case spotlight
    /// The index belongs to an application, which rebuilds it.
    case owningApplication
}

/// How much of the requested scope the analysis actually saw.
///
/// The distinction is the point: reporting "no large folders" when the answer is
/// "these locations could not be read" is the failure this exists to prevent.
public enum DiagnosticCoverage: String, Sendable, CaseIterable, Hashable {
    /// Every requested location was read.
    case complete
    /// Some locations were skipped; the totals are a lower bound.
    case partial
    /// A location needs Full Disk Access.
    case permissionDenied
    /// A volume is not mounted or is no longer available.
    case volumeUnavailable

    /// Ordering used when several providers report different states: the most
    /// restrictive answer is the one the user needs to see.
    var severity: Int {
        switch self {
        case .complete: 0
        case .partial: 1
        case .permissionDenied: 2
        case .volumeUnavailable: 3
        }
    }

    /// The single state that describes a set of provider results.
    public static func combining(_ values: some Sequence<DiagnosticCoverage>) -> DiagnosticCoverage {
        values.max { $0.severity < $1.severity } ?? .complete
    }
}

/// Why a location could not be read.
public enum DiagnosticSkipReason: String, Sendable, CaseIterable, Hashable {
    case permissionDenied
    case unreadable
    case volumeUnavailable

    /// True when granting Full Disk Access is what would lift it. The UI uses
    /// this to offer the System Settings button instead of a vague error.
    public var needsFullDiskAccess: Bool { self == .permissionDenied }
}

/// A location the analysis could not read.
public struct DiagnosticSkip: Sendable, Hashable, Identifiable {
    public let path: URL
    public let reason: DiagnosticSkipReason

    public var id: String { "\(reason.rawValue):\(path.path)" }
    public var displayName: String { path.lastPathComponent }

    public init(path: URL, reason: DiagnosticSkipReason) {
        self.path = path
        self.reason = reason
    }
}

/// A location the diagnostics may read.
///
/// Deliberately not a `ScanRoot`: that type carries `isCleanable`, and a
/// read-only diagnostic root handed to a scan would be one flag away from
/// offering cleanup candidates. This type has no such flag, and no function in
/// the diagnostics module produces anything a scan can consume.
public struct DiagnosticRoot: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The user's home directory.
        case home
        /// A mounted volume the whole analysis looks at.
        case volume
        /// A location the user granted in settings.
        case authorized
    }

    public let url: URL
    public let kind: Kind

    public var id: String { "\(kind.rawValue):\(url.path)" }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Everything one run of the diagnostics produced.
public struct StorageDiagnosticReport: Sendable {
    public let generatedAt: Date
    /// What the analysis was asked to look at.
    public let roots: [DiagnosticRoot]
    /// How complete the answer is.
    public let coverage: DiagnosticCoverage
    public let volumes: [VolumeInfo]
    /// Every finding, largest first.
    public let findings: [StorageFinding]
    /// Locations that could not be read, deduplicated.
    public let skips: [DiagnosticSkip]
    /// Space the analysis accounted for.
    public let measuredBytes: Int64
    public let measuredFiles: Int64
    /// How many providers contributed, so a run that produced nothing can be
    /// distinguished from a run that never happened.
    public let providerCount: Int

    public init(
        generatedAt: Date,
        roots: [DiagnosticRoot],
        coverage: DiagnosticCoverage,
        volumes: [VolumeInfo],
        findings: [StorageFinding],
        skips: [DiagnosticSkip],
        measuredBytes: Int64,
        measuredFiles: Int64,
        providerCount: Int
    ) {
        self.generatedAt = generatedAt
        self.roots = roots
        self.coverage = coverage
        self.volumes = volumes
        self.findings = findings
        self.skips = skips
        self.measuredBytes = measuredBytes
        self.measuredFiles = measuredFiles
        self.providerCount = providerCount
    }

    public static let empty = StorageDiagnosticReport(
        generatedAt: .distantPast,
        roots: [],
        coverage: .complete,
        volumes: [],
        findings: [],
        skips: [],
        measuredBytes: 0,
        measuredFiles: 0,
        providerCount: 0
    )

    /// The volume the analysis started from, when one was requested.
    public var primaryVolume: VolumeInfo? { volumes.first }

    /// True when nothing had to be skipped or guessed at.
    public var isComplete: Bool { coverage == .complete }

    /// True when any size in the report is an estimate.
    public var hasApproximateSizes: Bool { findings.contains(\.isApproximate) }

    /// Space the findings account for, which is a lower bound on what they hold.
    public var findingsBytes: Int64 { findings.reduce(0) { $0 + $1.allocatedBytes } }

    /// Totals per category, largest first. The categories card reads this.
    public var categoryTotals: [(category: StorageFindingCategory, bytes: Int64, count: Int)] {
        var totals: [StorageFindingCategory: (bytes: Int64, count: Int)] = [:]
        for finding in findings {
            var entry = totals[finding.category] ?? (0, 0)
            entry.bytes += finding.allocatedBytes
            entry.count += 1
            totals[finding.category] = entry
        }
        return totals
            .map { (category: $0.key, bytes: $0.value.bytes, count: $0.value.count) }
            .sorted {
                $0.bytes == $1.bytes ? $0.category.rawValue < $1.category.rawValue : $0.bytes > $1.bytes
            }
    }

    /// Large items Sift will never remove, shown so the space is explained.
    public var protectedFindings: [StorageFinding] {
        findings.filter { $0.status == .protected }
    }

    /// Items the system or their owner rebuilds.
    public var rebuildableFindings: [StorageFinding] {
        findings.filter { $0.status == .rebuildable }
    }

    /// Items the cleanup chain may be asked about.
    ///
    /// Being listed here is not a recommendation: an item still has to be
    /// selected, confirmed and checked by the cleanup chain like any other.
    public var cleanableFindings: [StorageFinding] {
        findings.filter { $0.status.allowsTrashAction }
    }

    public var snapshotFindings: [StorageFinding] {
        findings.filter { $0.category == .filesystemSnapshot }
    }

    /// Locations the user may need to grant access to.
    public var permissionSkips: [DiagnosticSkip] {
        skips.filter { $0.reason.needsFullDiskAccess }
    }
}

private extension Array {
    /// `contains(where:)` for a key path, which reads better at the call site.
    func contains(_ keyPath: KeyPath<Element, Bool>) -> Bool {
        contains { $0[keyPath: keyPath] }
    }
}
