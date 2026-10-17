import Foundation
import Shared

/// The result of measuring one location.
public struct DiagnosticMeasurement: Sendable {
    /// Space the file system allocated inside the location.
    public var allocatedBytes: Int64 = 0
    /// Sum of the file sizes inside it.
    public var logicalBytes: Int64 = 0
    public var fileCount: Int64 = 0
    /// Directories that could not be listed. A location can be measurable and
    /// still incomplete.
    public var unreadableCount: Int = 0
    /// The first unreadable directories, for the "could not be read" list. Bounded
    /// so a tree of denied directories cannot grow the report without limit.
    public var unreadablePaths: [URL] = []
    /// True when the budget ran out before the tree was finished.
    public var truncated: Bool = false
    /// False when the location itself does not exist.
    public var exists: Bool = true
    public var isDirectory: Bool = true

    /// True when the location could not be listed at all.
    public var isUnreadable: Bool { exists && isDirectory && unreadableCount > 0 && fileCount == 0 }
}

/// Measures a directory tree for the diagnostics.
///
/// Separate from `FileWalker` on purpose. The walker exists to produce candidates
/// and therefore refuses protected entries, which is exactly what the
/// diagnostics must measure and explain. Rather than adding a flag that would let
/// a scan walk protected trees, the diagnostics get their own measurer whose only
/// output is a byte count: it returns no entries, so nothing it touches can reach
/// the cleanup pipeline.
///
/// Symlinks are never followed, which is what keeps a measurement from leaving
/// the location it was asked about.
enum DiagnosticMeasurer {
    /// How many unreadable paths one measurement reports.
    private static let reportedUnreadableLimit = 20

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Measures `url`, visiting at most `budget` entries.
    ///
    /// Allocated and logical sizes are both collected: the file system may
    /// allocate less than the file's length (sparse, compressed) or share blocks
    /// between clones, so a single number cannot describe both what the disk
    /// holds and what the files say they contain.
    static func measure(
        _ url: URL,
        budget: Int = StorageDiagnostics.defaultMeasurementBudget,
        isCancelled: () -> Bool
    ) -> DiagnosticMeasurement {
        var result = DiagnosticMeasurement()

        let rootValues = try? url.resourceValues(forKeys: Set(keys))
        if rootValues == nil {
            // The location itself cannot be examined: missing, or unreadable
            // before the walk even starts.
            result.exists = FileManager.default.fileExists(atPath: url.path)
            result.isDirectory = false
            if result.exists {
                result.unreadableCount = 1
                result.unreadablePaths = [url]
            }
            return result
        }
        if rootValues?.isSymbolicLink == true {
            // A link is not the data: measuring its target would report space
            // that lives somewhere the user did not ask about.
            result.isDirectory = false
            return result
        }
        if rootValues?.isDirectory == false {
            result.isDirectory = false
            result.fileCount = 1
            result.allocatedBytes = FileWalker.allocatedSize(values: rootValues, url: url)
            result.logicalBytes = Int64(rootValues?.fileSize ?? 0)
            return result
        }

        var visited = 0
        var stack = [url]
        while let directory = stack.popLast() {
            if isCancelled() { return result }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            ) else {
                result.unreadableCount += 1
                if result.unreadablePaths.count < reportedUnreadableLimit {
                    result.unreadablePaths.append(directory)
                }
                continue
            }
            for child in contents {
                if isCancelled() { return result }
                if visited >= budget {
                    result.truncated = true
                    return result
                }
                visited += 1

                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    stack.append(child)
                    continue
                }
                result.fileCount += 1
                result.allocatedBytes += FileWalker.allocatedSize(values: values, url: child)
                result.logicalBytes += Int64(values?.fileSize ?? 0)
            }
        }
        return result
    }

    /// The newest modification time inside a location, checked at the top level.
    ///
    /// A full scan for the newest file would double the work of a measurement for
    /// a value the UI only shows as a hint.
    static func latestModification(of url: URL) -> Date? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return contents.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        .max()
    }
}
