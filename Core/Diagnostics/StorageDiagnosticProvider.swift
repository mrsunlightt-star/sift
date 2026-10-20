import Foundation
import Shared

/// What one provider reports.
public struct StorageFindingBatch: Sendable {
    public let findings: [StorageFinding]
    public let skips: [DiagnosticSkip]
    /// How much of what this provider was asked to look at it actually saw.
    public let coverage: DiagnosticCoverage
    public let measuredBytes: Int64
    public let measuredFiles: Int64
    /// Volume information, when the provider read it.
    public let volumes: [VolumeInfo]

    public init(
        findings: [StorageFinding] = [],
        skips: [DiagnosticSkip] = [],
        coverage: DiagnosticCoverage = .complete,
        measuredBytes: Int64 = 0,
        measuredFiles: Int64 = 0,
        volumes: [VolumeInfo] = []
    ) {
        self.findings = findings
        self.skips = skips
        self.coverage = coverage
        self.measuredBytes = measuredBytes
        self.measuredFiles = measuredFiles
        self.volumes = volumes
    }

    public static let empty = StorageFindingBatch()
}

/// What a provider needs to do its work.
///
/// No rule engine and no file operations: a provider reports what occupies space.
/// Whether a location is protected, and what may be done about it, is decided
/// afterwards in one place (`StorageDiagnosticEngine`), so a new provider cannot
/// introduce a second opinion about safety.
public struct StorageDiagnosticContext: Sendable {
    /// Every location the run covers, in the order the caller asked for.
    public let roots: [DiagnosticRoot]
    /// The home directory paths are compared against.
    public let homeDirectory: URL
    /// Checked between entries; a run must stop promptly when the user cancels.
    public let isCancelled: @Sendable () -> Bool
    /// How many directory entries the whole run may visit before it stops and
    /// reports an estimate. Keeps a whole-volume analysis responsive.
    public let measurementBudget: Int
    /// The same budget as a counter shared by every provider. A per-measurement
    /// limit let ten locations each spend the full allowance, so a "two million
    /// entry" run could read twenty million.
    public let budget: DiagnosticBudget

    public init(
        roots: [DiagnosticRoot],
        homeDirectory: URL,
        measurementBudget: Int = StorageDiagnostics.defaultMeasurementBudget,
        budget: DiagnosticBudget? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.roots = roots
        self.homeDirectory = homeDirectory
        self.measurementBudget = measurementBudget
        self.budget = budget ?? DiagnosticBudget(measurementBudget)
        self.isCancelled = isCancelled
    }

    /// Roots that are whole volumes.
    public var volumeRoots: [URL] { roots.filter { $0.kind == .volume }.map(\.url) }

    /// True when the run covers this volume.
    public func covers(volume url: URL) -> Bool {
        volumeRoots.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
}

/// One source of diagnostic findings.
///
/// A provider answers a narrow question about one kind of data and nothing else.
/// It never deletes, never moves, and never decides that something is safe: the
/// worst it can say is that a location is a candidate for the cleanup chain,
/// which then applies its own rules, protection checks and confirmation.
public protocol StorageDiagnosticProvider: Sendable {
    /// Stable identifier, recorded on every finding this provider produces.
    var identifier: String { get }
    func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch
}
