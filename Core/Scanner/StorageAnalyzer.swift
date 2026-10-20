import Foundation
import OSLog
import Shared

/// Storage analysis for the storage page (§5.4).
///
/// It answers the three questions the specification names — which category uses
/// the most space, which folders are largest, and which files to handle first —
/// from plain aggregates. The accumulator keeps bounded memory: at most
/// `topFileLimit` files and `topDirectoryLimit` directories, regardless of how
/// many files the volume holds.
public struct StorageAnalyzer {
    let rules: RuleEngine
    private let logger = SiftLog.storage

    public init(rules: RuleEngine) {
        self.rules = rules
    }

    /// Runs the analysis over `roots`.
    ///
    /// `ignoredPaths` is the user's "never visit" list. It is applied here rather
    /// than only in the UI: a directory the user excluded must not be traversed,
    /// counted or listed, or the storage page would still read what the setting
    /// says Sift never touches.
    public func analyze(
        roots: [ScanRoot],
        ignoredPaths: [String] = [],
        largeFileThresholdBytes: Int64 = ScanDefaults.largeFileThresholdBytes,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> StorageAnalysis {
        // The rule set's home, not the process home: see RuleEngine.homeDirectory.
        let home = URL(fileURLWithPath: rules.homeDirectory)
        // A root only reaches here because the user added it to the scan scope,
        // which is itself the authorisation. The protection list still applies to
        // every entry inside it, checked per file below.
        let searchable = Self.measurementRoots(roots: roots, ignoredPaths: ignoredPaths)
        guard let first = searchable.first else {
            return Self.volumeOnlyAnalysis(for: home)
        }

        // A directory below the root can be another disk's mount point. Walking
        // into it would attribute that disk's bytes to this volume and read a
        // location the user did not authorise for a measurement.
        let mountPoints = Set(
            (FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: [.skipHiddenVolumes]
            ) ?? []).map { $0.resolvingSymlinksInPath().path }
        )

        var categories: [String: (bytes: Int64, files: Int)] = [:]
        var directories: [String: (bytes: Int64, files: Int)] = [:]
        var topFiles: [StorageAnalysis.FileEntry] = []
        var scannedFiles = 0
        var scannedBytes: Int64 = 0
        var skipped = 0

        // A threshold below a megabyte would list thousands of ordinary
        // files, so it is clamped rather than trusted.
        let fileThreshold = max(largeFileThresholdBytes, 1024 * 1024)

        for root in searchable {
            let rootPath = root.path
            var stack = [root]
            while let directory = stack.popLast() {
                if cancelled() { break }
                let keys: [URLResourceKey] = [
                    .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                ]
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: []
                ) else {
                    skipped += 1
                    continue
                }
                for child in contents {
                    let values = try? child.resourceValues(forKeys: Set(keys))
                    if values?.isSymbolicLink == true { continue }
                    if ignoredPaths.contains(where: { RuleEngine.isPrefix($0, child.path) }) {
                        continue
                    }
                    if rules.isInExcludedLocation(child.path) { continue }
                    if rules.protectionReason(for: child.path) != nil {
                        // Protected user content is deliberately out of scope,
                        // not unreadable. Counting it as a failed read made the
                        // totals look incomplete for a complete, safe walk.
                        continue
                    }
                    if values?.isDirectory == true {
                        if mountPoints.contains(child.resolvingSymlinksInPath().path) {
                            continue
                        }
                        let name = child.lastPathComponent
                        if FileWalker.defaultSkipDirectoryNames.contains(name) { continue }
                        if rules.isPackageDirectory(name: name) {
                            // A bundle is one item: its contents are summed, not listed.
                            let measured = FileWalker.measure(
                                url: child,
                                rules: rules,
                                isCancelled: cancelled
                            )
                            record(
                                path: child,
                                size: measured.bytes,
                                files: measured.files,
                                modified: values?.contentModificationDate,
                                threshold: fileThreshold,
                                categories: &categories,
                                directories: &directories,
                                topFiles: &topFiles,
                                rootPath: rootPath
                            )
                            scannedFiles += measured.files
                            scannedBytes += measured.bytes
                            continue
                        }
                        stack.append(child)
                        continue
                    }

                    let size = FileWalker.allocatedSize(values: values, url: child)
                    scannedFiles += 1
                    scannedBytes += size
                    record(
                        path: child,
                        size: size,
                        files: 1,
                        modified: values?.contentModificationDate,
                        threshold: fileThreshold,
                        categories: &categories,
                        directories: &directories,
                        topFiles: &topFiles,
                        rootPath: rootPath
                    )
                }
            }
        }

        topFiles.sort { $0.sizeInBytes > $1.sizeInBytes }
        topFiles = Array(topFiles.prefix(ScanDefaults.topFileLimit))

        let directoryEntries = directories
            .map { key, value in
                StorageAnalysis.DirectoryEntry(
                    url: URL(fileURLWithPath: key),
                    sizeInBytes: value.bytes,
                    fileCount: value.files
                )
            }
            .sorted { $0.sizeInBytes > $1.sizeInBytes }
            .prefix(ScanDefaults.topDirectoryLimit)

        let categoryEntries = categories
            .map { key, value in
                StorageAnalysis.Category(
                    id: key,
                    title: Self.title(for: key),
                    sizeInBytes: value.bytes,
                    fileCount: value.files
                )
            }
            .sorted { $0.sizeInBytes > $1.sizeInBytes }

        let volume = try volumeInfo(for: first)
        let analysis = StorageAnalysis(
            mountPoint: volume.mountPoint.path,
            volumeName: volume.name,
            totalBytes: volume.totalBytes,
            freeBytes: volume.freeBytes,
            usedBytes: volume.usedBytes,
            categories: categoryEntries,
            topFiles: topFiles,
            topDirectories: Array(directoryEntries),
            scannedFileCount: scannedFiles,
            scannedByteCount: scannedBytes,
            skippedCount: skipped,
            isAggregated: scannedFiles > 10_000
        )
        logger.info(
            "Storage analysed (files=\(scannedFiles) categories=\(categoryEntries.count) skipped=\(skipped))"
        )
        return analysis
    }

    /// The roots whose bytes may be added to this analysis.
    ///
    /// One volume at a time: the page reports that volume's used and free
    /// figures, so a root on another disk would make the categories exceed the
    /// usage they are drawn against. Roots are resolved through symlinks and
    /// collapsed to the outermost one, because walking `~` and `~/Downloads`
    /// counts the same file twice.
    static func measurementRoots(roots: [ScanRoot], ignoredPaths: [String]) -> [URL] {
        let resolved = roots
            .map { $0.url.resolvingSymlinksInPath() }
            .filter { root in
                root.isFileURL
                    && !ignoredPaths.contains(where: { RuleEngine.isPrefix($0, root.path) })
            }
        guard let first = resolved.first else { return [] }

        let volume = first.volumeRoot.path
        let sameVolume = resolved.filter { $0.volumeRoot.path == volume }
        let ordered = sameVolume.sorted {
            let lhs = $0.pathComponents.count
            let rhs = $1.pathComponents.count
            return lhs == rhs ? $0.path < $1.path : lhs < rhs
        }

        var kept: [URL] = []
        for root in ordered {
            if kept.contains(where: { RuleEngine.isPrefix($0.path, root.path) }) { continue }
            kept.append(root)
        }
        return kept
    }

    /// Adds one file to the category total, the folder rollup and the top list.
    private func record(
        path: URL,
        size: Int64,
        files: Int,
        modified: Date?,
        threshold: Int64,
        categories: inout [String: (bytes: Int64, files: Int)],
        directories: inout [String: (bytes: Int64, files: Int)],
        topFiles: inout [StorageAnalysis.FileEntry],
        rootPath: String
    ) {
        let category = Self.category(for: path)
        var entry = categories[category] ?? (0, 0)
        entry.bytes += size
        entry.files += files
        categories[category] = entry

        if size >= threshold, size > 0 {
            topFiles.append(
                StorageAnalysis.FileEntry(url: path, sizeInBytes: size, modifiedAt: modified)
            )
        }

        // Roll the size up through the ancestors, stopping at the scan root so
        // the folder list stays meaningful.
        var current = path.deletingLastPathComponent()
        while current.path != rootPath, current.path.count > 1 {
            let key = current.path
            var rollup = directories[key] ?? (0, 0)
            rollup.bytes += size
            rollup.files += files
            directories[key] = rollup
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
    }

    /// Maps a file onto a display category by its extension.
    public static func category(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "app", "pkg", "dmg", "xip": "installers"
        case "log", "logarchive", "crash", "diag": "logs"
        case "cache", "tmp", "temp": "applicationCache"
        case "jpg", "jpeg", "png", "heic", "tiff", "gif", "webp", "raw": "images"
        case "mp4", "mov", "m4v", "avi", "mkv", "hevc": "video"
        case "mp3", "m4a", "wav", "aiff", "flac", "aac": "audio"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf":
            "documents"
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar": "archives"
        case "swift", "rs", "js", "ts", "py", "go", "java", "c", "cpp", "h", "sh": "code"
        case "sqlite", "db", "plist", "json", "xml", "yaml", "yml": "data"
        default: "other"
        }
    }

    /// Localised display name for a category identifier.
    public static func title(for identifier: String) -> String {
        switch identifier {
        case "applicationCache": CleanupCategory.applicationCache.titleKey.localized
        case "logs": CleanupCategory.logs.titleKey.localized
        case "installers": CleanupCategory.installers.titleKey.localized
        case "images": LocalizationKey.storageTypeImages.localized
        case "video": LocalizationKey.storageTypeVideo.localized
        case "audio": LocalizationKey.storageTypeAudio.localized
        case "documents": LocalizationKey.storageTypeDocuments.localized
        case "archives": LocalizationKey.storageTypeArchives.localized
        case "code": LocalizationKey.storageTypeCode.localized
        case "data": LocalizationKey.storageTypeData.localized
        default: LocalizationKey.storageTypeOther.localized
        }
    }

    /// Volume information for a path, using `URLResourceValues` rather than a
    /// hand-rolled `statfs` so the values match what the Finder reports.
    public func volumeInfo(for url: URL) throws -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        let total = Int64(values.volumeTotalCapacity ?? 0)
        // `availableCapacityForImportantUsage` is what macOS uses to decide
        // whether more data fits; the plain available capacity is the fallback
        // for filesystems that do not report it.
        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0) > 0
            ? Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            : Int64(values.volumeAvailableCapacity ?? 0)
        let mountPoint = url.volumeRoot
        return VolumeInfo(
            name: values.volumeName ?? mountPoint.lastPathComponent,
            mountPoint: mountPoint,
            totalBytes: total,
            freeBytes: free,
            isExternal: values.volumeIsInternal == false,
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }

    /// Volume-only result, used when the user has authorised no roots yet.
    static func volumeOnlyAnalysis(for url: URL) -> StorageAnalysis {
        var analysis = StorageAnalysis.empty
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else {
            return analysis
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        analysis = StorageAnalysis(
            mountPoint: url.volumeRoot.path,
            volumeName: values.volumeName ?? "",
            totalBytes: total,
            freeBytes: free,
            usedBytes: max(total - free, 0),
            categories: [],
            topFiles: [],
            topDirectories: [],
            scannedFileCount: 0,
            scannedByteCount: 0,
            skippedCount: 0,
            isAggregated: false
        )
        return analysis
    }
}

extension URL {
    /// The volume root this URL lives on.
    ///
    /// `URLResourceValues` does not expose the mount point directly, so the
    /// volume's own resource identifier is used to walk up to it.
    var volumeRoot: URL {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let identifier = try? resourceValues(forKeys: keys).volumeIdentifier else {
            return URL(fileURLWithPath: "/")
        }
        _ = identifier
        // `/` and any mounted volume resolve to themselves or to their mount
        // point; walking up until the identifier changes finds it reliably.
        var current = self
        let rootIdentifier = self.volumeIdentifierValue
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            if parent.volumeIdentifierValue != rootIdentifier { break }
            current = parent
        }
        return current
    }

    private var volumeIdentifierValue: String {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let value = try? resourceValues(forKeys: keys).volumeIdentifier
        return (value as? NSObject)?.description ?? ""
    }
}

/// Enumerates the mounted volumes for the storage page and the scan scope.
public struct VolumeEnumerator {
    let rules: RuleEngine
    private let logger = SiftLog.storage

    /// Volumes eligible to appear in the scan scope.
    ///
    /// Network volumes are excluded by design: the specification's open question
    /// recommends leaving them out, and scanning a network share for cache files
    /// is never what the user means (§19).
    public init(rules: RuleEngine) {
        self.rules = rules
    }

    /// Volumes eligible to appear in the scan scope.
    ///
    /// Network volumes are excluded by design: the specification's open question
    /// recommends leaving them out, and scanning a network share for cache files
    /// is never what the user means (§19).
    public func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .volumeIsLocalKey,
        ]
        let mountRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let candidates =
            [URL(fileURLWithPath: "/")]
            + ((try? FileManager.default.contentsOfDirectory(
                at: mountRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? [])

        var seen = Set<String>()
        var volumes: [VolumeInfo] = []
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsLocal == false {
                logger.notice("Skipped a network volume in the scan scope")
                continue
            }
            let mountPoint = resolved.volumeRoot
            guard seen.insert(mountPoint.path).inserted else { continue }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            volumes.append(
                VolumeInfo(
                    name: resolved.path == "/" ? "Macintosh HD" : (values.volumeName ?? resolved.lastPathComponent),
                    mountPoint: URL(fileURLWithPath: resolved.path),
                    totalBytes: total,
                    freeBytes: free,
                    isExternal: values.volumeIsInternal == false,
                    isReadOnly: values.volumeIsReadOnly ?? false
                )
            )
        }
        return volumes.sorted { $0.mountPoint.path < $1.mountPoint.path }
    }

    /// The user's own top-level folders, offered as scan scope options.
    func homeFolders() -> [URL] {
        // The rule set's home, not the process home: see RuleEngine.homeDirectory.
        let home = URL(fileURLWithPath: rules.homeDirectory)
        return ["Downloads", "Desktop", "Documents", "Movies", "Pictures"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
