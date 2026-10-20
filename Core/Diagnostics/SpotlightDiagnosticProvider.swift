import Foundation
import Shared

/// The volume-level Spotlight index.
///
/// Two stores can exist for one boot volume: `.Spotlight-V100` at the volume root
/// of the data volume, where the index actually lives, and one at the root of a
/// mounted volume. Both are reported when present.
///
/// The finding is `rebuildable`, never `cleanable`: the supported way to reclaim
/// the space is to have Spotlight build the index again, and moving the directory
/// to the Trash would only be a slower, less recoverable version of the same
/// thing. The directory is also inside a protected prefix, so the engine marks it
/// protected as well — the two facts are different and both are shown.
public struct SpotlightDiagnosticProvider: StorageDiagnosticProvider {
    public let identifier = "spotlight"

    public init() {}

    /// Where a volume keeps its index, relative to the volume root.
    public static let storeName = ".Spotlight-V100"

    public func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        var findings: [StorageFinding] = []
        var skips: [DiagnosticSkip] = []
        var coverage: DiagnosticCoverage = .complete
        var measuredBytes: Int64 = 0
        var measuredFiles: Int64 = 0

        for root in context.volumeRoots {
            if context.isCancelled() { break }
            var candidates = [root.appendingPathComponent(Self.storeName)]
            // The data volume carries the real store for the boot volume: a
            // firmlink means `/` and `/System/Volumes/Data` are one volume with
            // two spellings.
            if root.path == "/" {
                candidates.append(
                    URL(fileURLWithPath: "/System/Volumes/Data").appendingPathComponent(Self.storeName)
                )
            }

            for store in candidates {
                if context.isCancelled() { break }
                guard FileManager.default.fileExists(atPath: store.path) else { continue }

                let measured = DiagnosticMeasurer.measure(
                    store,
                    budget: context.budget,
                    isCancelled: context.isCancelled
                )
                measuredBytes += measured.allocatedBytes
                measuredFiles += measured.fileCount

                let unreadable = measured.isUnreadable
                if unreadable {
                    // A root-owned store is the normal case without Full Disk
                    // Access. The finding is still produced: "there is an index
                    // here and you cannot see inside it" is the answer the user
                    // needs, and silence would read as "no index".
                    coverage = .combining([coverage, .permissionDenied])
                    skips.append(DiagnosticSkip(path: store, reason: .permissionDenied))
                }
                if measured.truncated {
                    coverage = .combining([coverage, .partial])
                }

                let state = SystemQuery.spotlightState(ofVolumeAt: root.path)
                findings.append(
                    StorageFinding(
                        providerID: identifier,
                        path: store,
                        displayName: Self.storeName,
                        category: .spotlightIndex,
                        status: .rebuildable,
                        allocatedBytes: measured.allocatedBytes,
                        logicalBytes: unreadable ? nil : measured.logicalBytes,
                        fileCount: unreadable ? nil : measured.fileCount,
                        modifiedAt: DiagnosticMeasurer.latestModification(of: store),
                        explanationKey: Self.explanation(for: state, unreadable: unreadable),
                        remediation: .rebuild(.spotlight),
                        isApproximate: true
                    )
                )
            }
        }

        return StorageFindingBatch(
            findings: findings,
            skips: skips,
            coverage: coverage,
            measuredBytes: measuredBytes,
            measuredFiles: measuredFiles
        )
    }

    /// The sentence for one store, which states both what the store is and what
    /// Spotlight is currently doing with it.
    static func explanation(
        for state: SystemQuery.SpotlightState,
        unreadable: Bool
    ) -> LocalizationKey {
        if unreadable { return .diagnosticsExplanationSpotlightUnreadable }
        switch state {
        case .indexed: return .diagnosticsExplanationSpotlightIndexed
        case .notIndexed: return .diagnosticsExplanationSpotlightNotIndexed
        case .unknown: return .diagnosticsExplanationSpotlightStateUnknown
        }
    }
}
