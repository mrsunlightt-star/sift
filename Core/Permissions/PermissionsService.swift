import Foundation
import OSLog
import Shared

/// Permission reporting (§10).
///
/// The design decision this type encodes: **Full Disk Access is never a
/// precondition**. Sift always attempts a scan, reports exactly which locations
/// it could not read, and offers the System Settings button. It never invents a
/// vague "system error" to push the user into granting access (§10.2).
public actor PermissionsService {
    /// The state of one location Sift may need.
    public struct LocationAccess: Identifiable, Hashable, Sendable {
        public let id: String
        public let url: URL
        public let title: String
        public let isReadable: Bool
        public let requiresFullDiskAccess: Bool

        public init(url: URL, title: String, isReadable: Bool, requiresFullDiskAccess: Bool) {
            self.id = url.path
            self.url = url
            self.title = title
            self.isReadable = isReadable
            self.requiresFullDiskAccess = requiresFullDiskAccess
        }
    }

    private let fileManager: FileManager
    private let logger = SiftLog.permissions
    private var cachedReport: (Date, [LocationAccess])?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The locations worth reporting on the permissions page.
    ///
    /// Deliberately short: a long list of green ticks is noise. Only locations
    /// where the answer changes what Sift can do are included.
    public static func locations(home: URL) -> [(URL, LocalizationKey, Bool)] {
        [
            (home.appendingPathComponent("Library/Caches"), .cleanupCategoryApplicationCache, false),
            (home.appendingPathComponent("Library/Logs"), .cleanupCategoryLogs, false),
            (home.appendingPathComponent("Downloads"), .filesModeLarge, false),
            (
                URL(fileURLWithPath: "/Library/Logs"),
                .cleanupExplanationSystemLogsItem,
                true
            ),
        ]
    }

    /// Checks every location. The result is cached briefly: the check touches the
    /// disk and the permissions page can be reopened quickly.
    public func accessReport(homeDirectory: URL? = nil, forceRefresh: Bool = false) -> [LocationAccess] {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        if !forceRefresh, let cached = cachedReport, Date().timeIntervalSince(cached.0) < 5 {
            return cached.1
        }
        let report = Self.locations(home: home).map { url, titleKey, needsFullDiskAccess in
            LocationAccess(
                url: url,
                title: titleKey.localized,
                isReadable: isReadable(url),
                // A location that does not exist is not a permission problem.
                requiresFullDiskAccess: needsFullDiskAccess && !fileManager.fileExists(atPath: url.path)
            )
        }
        cachedReport = (Date(), report)
        let denied = report.filter { !$0.isReadable }.count
        logger.info("Permission check: \(report.count) locations, \(denied) not readable")
        return report
    }

    /// True when every reporting location is readable.
    public func hasFullAccess(homeDirectory: URL? = nil) -> Bool {
        accessReport(homeDirectory: homeDirectory).allSatisfy(\.isReadable)
    }

    /// True when Sift can read the user's own Library folders, which is what the
    /// out-of-the-box scan needs.
    public func canScanUserLocations(homeDirectory: URL? = nil) -> Bool {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        return isReadable(home.appendingPathComponent("Library"))
    }

    /// Probes one directory by actually listing it.
    ///
    /// `isReadableFile` is not enough on macOS: a sandboxed or TCC-restricted
    /// directory can report as existing while `read_dir` fails. Listing is the
    /// honest test.
    public func isReadable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return true // Absent is not denied.
        }
        guard isDirectory.boolValue else {
            return fileManager.isReadableFile(atPath: url.path)
        }
        do {
            _ = try fileManager.contentsOfDirectory(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Opens the Full Disk Access pane so the user can grant access themselves.
    ///
    /// The app never grants anything on the user's behalf and never pretends the
    /// grant is a reward; this just opens the pane (§10.2).
    public func openFullDiskAccessSettings() async {
        await WorkspaceActions.openFullDiskAccessSettings()
    }
}
