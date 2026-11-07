import Foundation
import Shared

/// The leftovers of one application, as one decision.
///
/// The scan reports a row per location — a cache directory, a container, two
/// preference files — because a location is what gets removed. A person deciding
/// what to delete thinks in applications: seven rows spread across four folders
/// are one decision, not seven, and a list that shows them as seven buries the
/// one fact the page exists to state.
///
/// Everything here is derived from data the scan already attached to each row
/// (`relatedBundleID`), so grouping costs no filesystem read and cannot disagree
/// with the rows it groups.
public struct ResidueGroup: Identifiable, Hashable, Sendable {
    /// The identifier the rows were matched by, spelled as it appears on disk.
    ///
    /// Two spellings can name the same application's files — `com.example.app`
    /// and `com.example.app.helper` — and they are merged into the shorter one
    /// by `ResidueGrouping`, which is why this is the group's identity.
    public let bundleIdentifier: String
    /// The last readable component of the identifier.
    ///
    /// A reading of the identifier, not a claim about which application owned
    /// the files: nothing on the machine can answer that once the bundle is gone,
    /// and inventing a name is the guess this product refuses elsewhere. The full
    /// identifier is always shown beside it so the reading can be checked.
    public let displayName: String
    /// The locations this application left, largest first.
    public let items: [CleanupItem]
    public let totalBytes: Int64
    public let fileCount: Int
    /// When the most recently touched of these locations was last modified.
    ///
    /// The best available answer to "how long has this been sitting here", and
    /// only that: a container macOS migrates can carry a fresh timestamp, so the
    /// date is shown as a hint and never used to decide whether a row is residue.
    public let latestModified: Date?
    /// The distinct categories the locations fall into, in display order.
    public let categories: [CleanupCategory]

    public var id: String { bundleIdentifier }
    public var locationCount: Int { items.count }
    /// True when one of the locations is a shared container, which can belong to
    /// an app group rather than to this application alone.
    public var hasGroupContainer: Bool { categories.contains(.groupContainerResidue) }
    public var formattedSize: String { SiftFormat.bytes(totalBytes) }
}

/// Turns a scan's residue rows into one entry per application.
public enum ResidueGrouping {
    /// The categories that are application leftovers.
    ///
    /// A full scan reports them beside caches and logs; a residue-only run
    /// reports nothing else. Both feed this function, and it keeps only these two
    /// so a caller that passes its whole result set gets groups rather than
    /// mislabelled caches.
    public static let categories: [CleanupCategory] = [
        .applicationResidue, .groupContainerResidue,
    ]

    /// Groups residue rows by the application they belong to.
    ///
    /// - Parameter items: rows from a scan. Rows in other categories are ignored.
    /// - Returns: one group per application, largest total first. A row with no
    ///   identifier is dropped rather than grouped under a made-up one: the
    ///   engines attach an identifier to every residue row they emit, so a row
    ///   without one did not come from them.
    public static func groups(from items: [CleanupItem]) -> [ResidueGroup] {
        let residue = items.filter { categories.contains($0.category) }
        guard !residue.isEmpty else { return [] }

        // Identifier -> spellings seen for it, lower-cased key, original value.
        var originalSpelling: [String: String] = [:]
        for item in residue {
            guard let identifier = item.relatedBundleID, !identifier.isEmpty else { continue }
            let key = identifier.lowercased()
            // The shortest spelling wins as the group's identity: it is the one
            // the other spellings continue.
            if let existing = originalSpelling[key] {
                if identifier.count < existing.count {
                    originalSpelling[key] = identifier
                }
            } else {
                originalSpelling[key] = identifier
            }
        }
        guard !originalSpelling.isEmpty else { return [] }

        // A helper, an updater or a per-version directory is the same
        // application's data, and it is recognised exactly the way the engines
        // recognise an installed application's data: a prefix that ends on a `.`
        // or `-` boundary. `com.example.app` never claims `com.example.appleby`.
        let known = Set(originalSpelling.keys)
        var owner: [String: String] = [:]
        for key in known {
            owner[key] = parent(of: key, in: known) ?? key
        }

        var grouped: [String: [CleanupItem]] = [:]
        for item in residue {
            guard let identifier = item.relatedBundleID, !identifier.isEmpty else { continue }
            let key = identifier.lowercased()
            let root = owner[key] ?? key
            grouped[root, default: []].append(item)
        }

        return grouped.compactMap { root, rows -> ResidueGroup? in
            guard let identifier = originalSpelling[root] else { return nil }
            let sortedRows = rows.sorted { left, right in
                if left.sizeInBytes != right.sizeInBytes {
                    return left.sizeInBytes > right.sizeInBytes
                }
                return left.displayPath.localizedStandardCompare(right.displayPath) == .orderedAscending
            }
            let found = Set(sortedRows.map(\.category))
            return ResidueGroup(
                bundleIdentifier: identifier,
                displayName: shortName(of: identifier),
                items: sortedRows,
                totalBytes: sortedRows.reduce(0) { $0 + $1.sizeInBytes },
                fileCount: sortedRows.reduce(0) { $0 + $1.fileCount },
                latestModified: sortedRows.compactMap(\.modifiedAt).max(),
                categories: categories.filter { found.contains($0) }
            )
        }
        .sorted { left, right in
            if left.totalBytes != right.totalBytes { return left.totalBytes > right.totalBytes }
            return left.bundleIdentifier.localizedStandardCompare(right.bundleIdentifier) == .orderedAscending
        }
    }

    /// The nearest ancestor spelling of `identifier`, if one was seen.
    ///
    /// Only prefixes that end exactly at a separator are considered, which is the
    /// same boundary rule the scanners use: `com.example.app.helper` continues
    /// `com.example.app`, and `com.example.appleby` continues nothing.
    private static func parent(of identifier: String, in known: Set<String>) -> String? {
        var best: String?
        for (index, scalar) in identifier.unicodeScalars.enumerated()
        where scalar == "." || scalar == "-" {
            guard index > 0 else { continue }
            let prefix = String(identifier.prefix(index))
            guard known.contains(prefix) else { continue }
            if best.map({ prefix.count > $0.count }) ?? true {
                best = prefix
            }
        }
        return best
    }

    /// The last component that reads as a name.
    ///
    /// `com.microsoft.Word` reads as `Word`; `com.example.tool.app` reads as
    /// `tool`, because `app` is a shape rather than a name. Nothing here consults
    /// the filesystem or LaunchServices — that would turn a display detail into a
    /// claim about ownership.
    private static func shortName(of identifier: String) -> String {
        var parts = identifier.split(separator: ".").map(String.init)
        let shapes: Set<String> = [
            "app", "mac", "helper", "helpers", "daemon", "agent", "updater",
            "shipit", "bundle", "plugin", "extension",
        ]
        while parts.count > 1, let last = parts.last, shapes.contains(last.lowercased()) {
            parts.removeLast()
        }
        return parts.last ?? identifier
    }
}
