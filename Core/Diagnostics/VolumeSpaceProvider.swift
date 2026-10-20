import Foundation
import Shared

/// What a volume holds, at the level of its own root directory.
///
/// This provider only measures (§5.1): it says how much space each top-level
/// directory of a volume occupies and never judges whether any of it may be
/// removed. Whether something is protected, and what may be done about it, is
/// decided by the engine afterwards.
public struct VolumeSpaceProvider: StorageDiagnosticProvider {
    public let identifier = "volumeSpace"

    public init() {}

    public func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        var findings: [StorageFinding] = []
        var skips: [DiagnosticSkip] = []
        var volumes: [VolumeInfo] = []
        var coverage: DiagnosticCoverage = .complete
        var measuredBytes: Int64 = 0
        var measuredFiles: Int64 = 0

        // The volume the analysis reports on. The boot volume is included even
        // when the caller only asked about its home directory, so the page can
        // always show what the disk holds.
        var volumeRoots = context.volumeRoots
        if volumeRoots.isEmpty {
            volumeRoots = [URL(fileURLWithPath: "/")]
        }

        for root in volumeRoots {
            guard let info = readVolumeInfo(root) else {
                coverage = .combining([coverage, .volumeUnavailable])
                skips.append(DiagnosticSkip(path: root, reason: .volumeUnavailable))
                continue
            }
            volumes.append(info)
            guard context.covers(volume: root) else { continue }

            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                coverage = .combining([coverage, .permissionDenied])
                skips.append(DiagnosticSkip(path: root, reason: .permissionDenied))
                continue
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if context.isCancelled() { break }
                if Self.firmlinkMarkers.contains(child.lastPathComponent) { continue }
                let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey])
                // A link is not data: the space belongs to its target, which is
                // either counted where it lives or outside this volume.
                if values?.isSymbolicLink == true { continue }

                let measured = DiagnosticMeasurer.measure(
                    child,
                    budget: context.budget,
                    isCancelled: context.isCancelled
                )
                if context.isCancelled() { break }

                for unreadable in measured.unreadablePaths {
                    skips.append(DiagnosticSkip(path: unreadable, reason: .permissionDenied))
                }
                if measured.unreadableCount > 0 {
                    coverage = .combining([coverage, .permissionDenied])
                }
                if measured.truncated {
                    coverage = .combining([coverage, .partial])
                }

                measuredBytes += measured.allocatedBytes
                measuredFiles += measured.fileCount

                let category = Self.category(for: child, homeDirectory: context.homeDirectory)
                findings.append(
                    StorageFinding(
                        providerID: identifier,
                        path: child,
                        displayName: child.lastPathComponent,
                        category: category,
                        // Deliberately not a judgement: §5.1 says this provider
                        // reports space, and the engine applies the protection
                        // list to whatever comes out of here.
                        status: .unknown,
                        allocatedBytes: measured.allocatedBytes,
                        logicalBytes: measured.logicalBytes,
                        fileCount: measured.fileCount,
                        modifiedAt: DiagnosticMeasurer.latestModification(of: child),
                        explanationKey: category == .systemData
                            ? .diagnosticsExplanationSystemData
                            : .diagnosticsExplanationVolumeChild,
                        remediation: .inspectOnly,
                        isApproximate: measured.truncated
                    )
                )
            }
        }

        return StorageFindingBatch(
            findings: findings,
            skips: skips,
            coverage: coverage,
            measuredBytes: measuredBytes,
            measuredFiles: measuredFiles,
            volumes: volumes
        )
    }

    /// Entries at a volume root that are the file system's own bookkeeping.
    ///
    /// The firmlink markers macOS places beside the data volume: they hold no
    /// data, and a row called `/.file` on the page is noise.
    static let firmlinkMarkers: Set<String> = [".file", ".nofollow", ".resolve"]

    /// Top-level directories macOS owns.
    ///
    /// Used for the display category only, never for the decision: `/Library` has
    /// to be called system data rather than "unclassified" on the page, but what
    /// makes it protected is the compiled-in list, applied by the engine.
    static let systemDirectories: Set<String> = [
        "System", "usr", "bin", "sbin", "etc", "private", "Library", "opt", "var",
        "tmp", "cores",
    ]

    /// The category a child of a volume root is shown under.
    ///
    /// A description, not a judgement: `StorageDiagnosticEngine` decides what is
    /// protected, and this only decides whether the row reads as system data, the
    /// user's own data, or unclassified.
    static func category(for url: URL, homeDirectory: URL) -> StorageFindingCategory {
        let path = url.path
        if url.lastPathComponent.hasPrefix(".") { return .systemData }
        if systemDirectories.contains(url.lastPathComponent) { return .systemData }
        if ProtectedPaths.prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .systemData
        }
        // `/Users` is not the user's content itself, but it is where it lives.
        if homeDirectory.path == path || homeDirectory.path.hasPrefix(path + "/") {
            return .userData
        }
        return .unknown
    }

    /// Volume totals, read with `URLResourceValues` so the numbers match what the
    /// Finder shows for the same disk.
    private func readVolumeInfo(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else {
            return nil
        }
        // `availableCapacityForImportantUsage` is the figure macOS uses to decide
        // whether more data fits; the plain available capacity is the fallback.
        let important = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let free = important > 0
            ? important
            : Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            name: values.volumeName ?? url.lastPathComponent,
            mountPoint: url,
            totalBytes: Int64(total),
            freeBytes: free,
            isExternal: values.volumeIsInternal == false,
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }
}
