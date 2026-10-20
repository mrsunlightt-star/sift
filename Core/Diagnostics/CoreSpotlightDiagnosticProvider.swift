import Foundation
import Shared

/// The per-user Core Spotlight store.
///
/// `~/Library/Metadata/CoreSpotlight` holds the search metadata the system keeps
/// for the user's own content — mail, messages, notes. It is frequently several
/// gigabytes and it is invisible to a cache scan.
///
/// It requires Full Disk Access to measure. Without it the provider still reports
/// the location: "there is a search index here and its size is unknown" is a
/// truthful answer, and staying silent would tell the user there is nothing to
/// see. The directory is not on the protection list — it is not the user's data —
/// so the status here is `rebuildable` rather than `protected`, and the finding
/// explains that macOS regenerates it.
public struct CoreSpotlightDiagnosticProvider: StorageDiagnosticProvider {
    public let identifier = "coreSpotlight"

    public init() {}

    /// Relative to the home directory.
    public static let storePath = "Library/Metadata/CoreSpotlight"

    public func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        let store = context.homeDirectory.appendingPathComponent(Self.storePath)
        guard FileManager.default.fileExists(atPath: store.path) else {
            return .empty
        }

        let measured = DiagnosticMeasurer.measure(
            store,
            budget: context.budget,
            isCancelled: context.isCancelled
        )
        let unreadable = measured.isUnreadable

        var coverage: DiagnosticCoverage = .complete
        var skips: [DiagnosticSkip] = []
        if unreadable {
            coverage = .permissionDenied
            skips.append(DiagnosticSkip(path: store, reason: .permissionDenied))
        }
        if measured.truncated {
            coverage = .combining([coverage, .partial])
        }

        let finding = StorageFinding(
            providerID: identifier,
            path: store,
            displayName: store.lastPathComponent,
            category: .coreSpotlightIndex,
            status: .rebuildable,
            allocatedBytes: measured.allocatedBytes,
            logicalBytes: unreadable ? nil : measured.logicalBytes,
            fileCount: unreadable ? nil : measured.fileCount,
            modifiedAt: DiagnosticMeasurer.latestModification(of: store),
            explanationKey: unreadable
                ? .diagnosticsExplanationCoreSpotlightUnreadable
                : .diagnosticsExplanationCoreSpotlight,
            remediation: .rebuild(.spotlight),
            isApproximate: true
        )

        return StorageFindingBatch(
            findings: [finding],
            skips: skips,
            coverage: coverage,
            measuredBytes: measured.allocatedBytes,
            measuredFiles: measured.fileCount
        )
    }
}
