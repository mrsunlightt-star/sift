import Foundation
import Shared

/// APFS local snapshots.
///
/// Local snapshots are why "the folders add up to less than the disk says is
/// used". They are not files, they cannot be moved to the Trash, and the space
/// they hold is not attributed to any directory — so they are reported as their
/// own category, with a count and the newest date, and never as a cleanup item
/// (§5.6).
///
/// The system does not report a per-snapshot size, so none is invented: the
/// finding says how many there are and that macOS thins them itself.
public struct APFSSnapshotProvider: StorageDiagnosticProvider {
    public let identifier = "apfsSnapshots"

    public init() {}

    public func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        var findings: [StorageFinding] = []
        var coverage: DiagnosticCoverage = .complete

        for root in context.volumeRoots {
            if context.isCancelled() { break }
            let (snapshots, asked) = SystemQuery.localSnapshots(ofVolumeAt: root.path)
            guard asked else {
                // The question could not be answered, so the report may be missing
                // a large space holder: that is a partial answer, not a zero.
                coverage = .combining([coverage, .partial])
                continue
            }
            guard !snapshots.isEmpty else { continue }

            findings.append(
                StorageFinding(
                    providerID: identifier,
                    path: root,
                    displayName: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent,
                    category: .filesystemSnapshot,
                    // Never `cleanable`: snapshots are managed by the system and
                    // hold the state of the disk, not disposable copies of files.
                    status: .protected,
                    allocatedBytes: 0,
                    logicalBytes: nil,
                    fileCount: Int64(snapshots.count),
                    modifiedAt: snapshots.compactMap(\.createdAt).max(),
                    explanationKey: .diagnosticsExplanationSnapshots,
                    remediation: .inspectOnly,
                    isProtected: true,
                    isApproximate: true
                )
            )
        }

        return StorageFindingBatch(findings: findings, coverage: coverage)
    }
}
