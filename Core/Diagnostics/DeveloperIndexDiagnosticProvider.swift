import Foundation
import Shared

/// Indexes a development tool maintains.
///
/// The only tool with a well-known layout is Xcode: it keeps one directory per
/// project under `~/Library/Developer/Xcode/DerivedData`, and each of those holds
/// an `Index.noindex` (older releases: `Index`) directory that can be several
/// gigabytes.
///
/// A directory is only called a rebuildable index when it actually has that
/// structure. DerivedData itself is reported separately as unknown: it also holds
/// build products and logs, deleting it is a normal thing for a developer to do,
/// but Sift does not know what a given project can rebuild, so it says so instead
/// of guessing (§5.4).
public struct DeveloperIndexDiagnosticProvider: StorageDiagnosticProvider {
    public let identifier = "developerIndex"

    public init() {}

    /// Relative to the home directory.
    public static let developerPath = "Library/Developer"
    public static let derivedDataPath = "Library/Developer/Xcode/DerivedData"
    /// The index directory inside one project's derived data, newest name first.
    public static let indexDirectoryNames = ["Index.noindex", "Index"]

    public func analyze(_ context: StorageDiagnosticContext) async -> StorageFindingBatch {
        let derivedData = context.homeDirectory.appendingPathComponent(Self.derivedDataPath)
        guard FileManager.default.fileExists(atPath: derivedData.path) else {
            return .empty
        }

        var findings: [StorageFinding] = []
        var skips: [DiagnosticSkip] = []
        var coverage: DiagnosticCoverage = .complete
        var measuredBytes: Int64 = 0
        var measuredFiles: Int64 = 0

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: derivedData,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return StorageFindingBatch(
                skips: [DiagnosticSkip(path: derivedData, reason: .permissionDenied)],
                coverage: .permissionDenied
            )
        }

        for project in projects.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if context.isCancelled() { break }
            let values = try? project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            for name in Self.indexDirectoryNames {
                let index = project.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: index.path) else { continue }

                let measured = DiagnosticMeasurer.measure(
                    index,
                    budget: context.measurementBudget,
                    isCancelled: context.isCancelled
                )
                if measured.unreadableCount > 0 {
                    coverage = .combining([coverage, .permissionDenied])
                    skips.append(DiagnosticSkip(path: index, reason: .permissionDenied))
                }
                if measured.truncated {
                    coverage = .combining([coverage, .partial])
                }
                measuredBytes += measured.allocatedBytes
                measuredFiles += measured.fileCount

                findings.append(
                    StorageFinding(
                        providerID: identifier,
                        path: index,
                        displayName: "\(project.lastPathComponent) · \(name)",
                        category: .developerIndex,
                        status: .rebuildable,
                        allocatedBytes: measured.allocatedBytes,
                        logicalBytes: measured.logicalBytes,
                        fileCount: measured.fileCount,
                        modifiedAt: DiagnosticMeasurer.latestModification(of: index),
                        explanationKey: .diagnosticsExplanationDeveloperIndex,
                        remediation: .rebuild(.owningApplication),
                        isApproximate: measured.truncated
                    )
                )
                break
            }
        }

        // The container is worth seeing even though its size cannot be called
        // reclaimable: it is what makes a developer Mac lose tens of gigabytes.
        let derivedMeasured = DiagnosticMeasurer.measure(
            derivedData,
            budget: context.measurementBudget,
            isCancelled: context.isCancelled
        )
        if derivedMeasured.truncated {
            coverage = .combining([coverage, .partial])
        }
        findings.append(
            StorageFinding(
                providerID: identifier,
                path: derivedData,
                displayName: "DerivedData",
                category: .developerIndex,
                status: .unknown,
                allocatedBytes: derivedMeasured.allocatedBytes,
                logicalBytes: derivedMeasured.logicalBytes,
                fileCount: derivedMeasured.fileCount,
                modifiedAt: DiagnosticMeasurer.latestModification(of: derivedData),
                explanationKey: .diagnosticsExplanationDeveloperData,
                remediation: .inspectOnly,
                isApproximate: derivedMeasured.truncated
            )
        )
        measuredBytes += derivedMeasured.allocatedBytes
        measuredFiles += derivedMeasured.fileCount

        return StorageFindingBatch(
            findings: findings,
            skips: skips,
            coverage: coverage,
            measuredBytes: measuredBytes,
            measuredFiles: measuredFiles
        )
    }
}
