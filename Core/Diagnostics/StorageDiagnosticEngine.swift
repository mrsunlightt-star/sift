import Foundation
import OSLog
import Shared

/// Runs the diagnostic providers and produces one report.
///
/// The engine is the only place that decides:
///
/// * whether a finding is protected — from the compiled-in list, not from what a
///   provider believes, so a new provider cannot introduce a second opinion about
///   safety;
/// * how complete the answer is — the most restrictive provider result wins;
/// * which of two findings about the same path is kept.
///
/// It deletes nothing, moves nothing and produces nothing the cleanup pipeline
/// consumes. A `cleanable` finding is a statement that the existing cleanup chain
/// may be asked about a location; that chain still applies its own rules, its own
/// protection checks and its own confirmation (§2.2, §8).
public struct StorageDiagnosticEngine: Sendable {
    private let providers: [any StorageDiagnosticProvider]
    private let logger = SiftLog.storage

    public init(providers: [any StorageDiagnosticProvider] = StorageDiagnosticEngine.standardProviders) {
        self.providers = providers
    }

    /// The providers a normal run uses, in the order they contribute.
    ///
    /// The volume provider comes first because it is the most general: everything
    /// it reports about a location a later provider also knows is replaced by the
    /// more specific finding.
    public static var standardProviders: [any StorageDiagnosticProvider] {
        [
            VolumeSpaceProvider(),
            SpotlightDiagnosticProvider(),
            CoreSpotlightDiagnosticProvider(),
            DeveloperIndexDiagnosticProvider(),
            APFSSnapshotProvider(),
        ]
    }

    /// Analyses `roots` and returns everything that was found.
    ///
    /// `rules` is the same rule engine the scans use, so a location that is
    /// protected for a scan is protected here too.
    public func analyze(
        roots: [DiagnosticRoot],
        homeDirectory: URL,
        rules: RuleEngine,
        measurementBudget: Int = StorageDiagnostics.defaultMeasurementBudget,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> StorageDiagnosticReport {
        guard !roots.isEmpty else { return .empty }

        let context = StorageDiagnosticContext(
            roots: roots,
            homeDirectory: homeDirectory,
            measurementBudget: measurementBudget,
            isCancelled: isCancelled
        )

        var findings: [StorageFinding] = []
        var skips: [DiagnosticSkip] = []
        var volumes: [VolumeInfo] = []
        var coverages: [DiagnosticCoverage] = []
        var measuredBytes: Int64 = 0
        var measuredFiles: Int64 = 0
        var contributors = 0

        for provider in providers {
            if isCancelled() { break }
            let batch = await provider.analyze(context)
            contributors += 1
            findings.append(contentsOf: batch.findings)
            skips.append(contentsOf: batch.skips)
            volumes.append(contentsOf: batch.volumes)
            coverages.append(batch.coverage)
            measuredBytes += batch.measuredBytes
            measuredFiles += batch.measuredFiles
        }

        let enforced = enforceProtection(on: findings, rules: rules)
        let deduplicated = deduplicate(enforced)

        let report = StorageDiagnosticReport(
            generatedAt: Date(),
            roots: roots,
            coverage: DiagnosticCoverage.combining(coverages),
            volumes: deduplicateVolumes(volumes),
            findings: deduplicated.sorted {
                $0.allocatedBytes == $1.allocatedBytes
                    ? $0.displayName < $1.displayName
                    : $0.allocatedBytes > $1.allocatedBytes
            },
            skips: deduplicateSkips(skips),
            measuredBytes: measuredBytes,
            measuredFiles: measuredFiles,
            providerCount: contributors
        )
        logger.info(
            "Diagnostics finished (findings=\(report.findings.count) coverage=\(report.coverage.rawValue, privacy: .public) skipped=\(report.skips.count))"
        )
        return report
    }

    /// Applies the compiled-in protection list to every finding.
    ///
    /// Protection removes the *deletion* path and nothing else. A protected path
    /// that occupies space is still explained, and a mechanism that rebuilds it is
    /// still named — what it can never be is `cleanable`, because that is the
    /// status the UI turns into a Trash action (§8).
    func enforceProtection(on findings: [StorageFinding], rules: RuleEngine) -> [StorageFinding] {
        findings.map { finding in
            guard let path = finding.path, rules.protectionReason(for: path.path) != nil else {
                return finding
            }
            return StorageFinding(
                providerID: finding.providerID,
                path: finding.path,
                displayName: finding.displayName,
                category: finding.category,
                status: .protected,
                allocatedBytes: finding.allocatedBytes,
                logicalBytes: finding.logicalBytes,
                fileCount: finding.fileCount,
                modifiedAt: finding.modifiedAt,
                explanationKey: finding.explanationKey,
                remediation: finding.remediation.forbidsTrash,
                isProtected: true,
                isApproximate: finding.isApproximate
            )
        }
    }

    /// Keeps one finding per location: the more specific statement wins.
    ///
    /// The volume provider lists every child of a volume root, including the
    /// stores other providers know the meaning of. "This is the Spotlight index"
    /// is more useful than "this is a hidden directory", and showing both would
    /// double-count the space.
    func deduplicate(_ findings: [StorageFinding]) -> [StorageFinding] {
        var best: [String: StorageFinding] = [:]
        var order: [String] = []
        for finding in findings {
            let key = finding.path?.standardizedFileURL.path ?? "finding:\(finding.id)"
            guard let existing = best[key] else {
                best[key] = finding
                order.append(key)
                continue
            }
            if finding.category.specificity > existing.category.specificity {
                best[key] = finding
            }
        }
        return order.compactMap { best[$0] }
    }

    /// One entry per volume, first mention wins.
    private func deduplicateVolumes(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        var seen = Set<String>()
        return volumes.filter { seen.insert($0.mountPoint.path).inserted }
    }

    private func deduplicateSkips(_ skips: [DiagnosticSkip]) -> [DiagnosticSkip] {
        var seen = Set<String>()
        return skips.filter { seen.insert($0.id).inserted }
    }
}

private extension StorageRemediation {
    /// The same suggestion with the deletion path removed.
    ///
    /// Rebuilding or inspecting survives protection: a protected index can still
    /// be rebuilt by the system that owns it, and saying so is the whole point of
    /// reporting it.
    var forbidsTrash: StorageRemediation {
        switch self {
        case .trash: .inspectOnly
        case .rebuild, .inspectOnly: self
        }
    }
}
