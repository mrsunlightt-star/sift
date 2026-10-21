import Foundation
import OSLog
import Shared

#if canImport(SiftScanner)
import SiftScanner
#endif

/// Storage analysis for the storage page (§5.4).
///
/// The walk, the byte accounting, the category rollup and the bounded top-file
/// and directory lists are implemented once, in the Rust scanner core. This type
/// owns the product policy around that engine: which roots may be measured, how
/// the result maps onto the page's model, and how cancellation reaches the
/// blocking FFI call.
public struct StorageAnalyzer {
    let rules: RuleEngine
    /// How many directory rollups the Rust accumulator may retain before it
    /// prunes the smallest. The page renders only the top list, so this is a
    /// memory bound rather than a display choice.
    let directoryRollupLimit: Int
    private let logger = SiftLog.storage

    public init(rules: RuleEngine) {
        self.init(rules: rules, directoryRollupLimit: Self.defaultDirectoryRollupLimit)
    }

    /// Test seam: a small limit makes the pruning path reachable in a fixture.
    init(rules: RuleEngine, directoryRollupLimit: Int) {
        self.rules = rules
        self.directoryRollupLimit = max(directoryRollupLimit, 2)
    }

    /// The default cap on retained directory rollups. The Rust constant
    /// `DEFAULT_DIRECTORY_ROLLUP_LIMIT` carries the same number.
    static let defaultDirectoryRollupLimit = 20_000

    /// Runs the analysis over `roots`.
    ///
    /// `ignoredPaths` is the user's "never visit" list. It is applied inside the
    /// Rust walk rather than only in the UI: a directory the user excluded must
    /// not be traversed, counted or listed, or the storage page would still read
    /// what the setting says Sift never touches.
    public func analyze(
        roots: [ScanRoot],
        ignoredPaths: [String] = [],
        largeFileThresholdBytes: Int64 = ScanDefaults.largeFileThresholdBytes,
        includeHiddenFiles: Bool = true,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> StorageAnalysis {
        // The rule set's home, not the process home: see RuleEngine.homeDirectory.
        let home = URL(fileURLWithPath: rules.homeDirectory)
        // A root only reaches here because the user added it to the scan scope,
        // which is itself the authorisation. The protection list still applies to
        // every entry inside it, and the Rust analysis consults the same grants.
        let searchable = Self.measurementRoots(roots: roots, ignoredPaths: ignoredPaths)
        guard !searchable.isEmpty else {
            return Self.volumeOnlyAnalysis(for: home)
        }

        #if canImport(SiftScanner)
        let request = RustStorageRequest(
            homeDir: rules.homeDirectory,
            roots: searchable.map(\.path),
            ignorePaths: ignoredPaths,
            topFileLimit: UInt32(ScanDefaults.topFileLimit),
            topDirectoryLimit: UInt32(ScanDefaults.topDirectoryLimit),
            directoryRollupLimit: UInt32(directoryRollupLimit),
            largeFileThresholdBytes: UInt64(max(largeFileThresholdBytes, 0)),
            authorizedRoots: rules.authorizedRoots,
            includeHiddenFiles: includeHiddenFiles
        )
        let json = try JSONEncoder().encode(request)
        let options = String(decoding: json, as: UTF8.self)

        let token = StorageCancelToken()
        if cancelled() { token.cancel() }
        // The FFI call is blocking; the watcher is what turns Sift's cancel flag
        // into the Rust atomic while the walk is in progress.
        let watcher = Task.detached(priority: .utility) { [cancelled] in
            while !Task.isCancelled {
                if cancelled() {
                    token.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let box: StorageResultBox = await Task.detached(
            priority: .userInitiated
        ) {
            let buffer = CStringBuffer(options)
            defer { buffer.release() }
            return StorageResultBox(sift_storage_analyse(buffer.value, token.raw))
        }.value
        watcher.cancel()
        _ = await watcher.value

        guard let result = box.pointer else {
            throw ScannerError(
                code: .internalError,
                message: LocalizationKey.commonUnknownError.localized
            )
        }
        defer { sift_storage_analysis_free(result) }
        guard result.pointee.version == UInt32(SIFT_FFI_VERSION) else {
            throw ScannerError(
                code: .internalError,
                message: "The storage core returned an incompatible result."
            )
        }
        guard result.pointee.ok else {
            let message = readString(result.pointee.error)
            throw ScannerError(
                code: .internalError,
                message: message.isEmpty
                    ? LocalizationKey.commonUnknownError.localized
                    : message
            )
        }

        let analysis = Self.convert(result.pointee)
        logger.info(
            "Storage analysed (files=\(analysis.scannedFileCount) categories=\(analysis.categories.count) skipped=\(analysis.skippedCount))"
        )
        return analysis
        #else
        throw ScannerError(
            code: .internalError,
            message: "The Rust scanner core is required for storage analysis."
        )
        #endif
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

    #if canImport(SiftScanner)
    /// Maps the C result onto the page model.
    private static func convert(_ raw: SiftStorageAnalysis) -> StorageAnalysis {
        var categories: [StorageAnalysis.Category] = []
        if let pointer = raw.categories {
            categories.reserveCapacity(raw.category_count)
            for index in 0..<raw.category_count {
                let row = pointer[index]
                let identifier = readString(row.category)
                categories.append(
                    StorageAnalysis.Category(
                        id: identifier,
                        title: title(for: identifier),
                        sizeInBytes: row.total_bytes,
                        fileCount: Int(row.item_count)
                    )
                )
            }
        }

        var files: [StorageAnalysis.FileEntry] = []
        if let pointer = raw.files {
            files.reserveCapacity(raw.file_count)
            for index in 0..<raw.file_count {
                let row = pointer[index]
                files.append(
                    StorageAnalysis.FileEntry(
                        url: URL(fileURLWithPath: readString(row.path)),
                        sizeInBytes: Int64(row.size_bytes),
                        modifiedAt: row.modified_secs > 0
                            ? Date(timeIntervalSince1970: TimeInterval(row.modified_secs))
                            : nil
                    )
                )
            }
        }

        var directories: [StorageAnalysis.DirectoryEntry] = []
        if let pointer = raw.directories {
            directories.reserveCapacity(raw.directory_count)
            for index in 0..<raw.directory_count {
                let row = pointer[index]
                directories.append(
                    StorageAnalysis.DirectoryEntry(
                        url: URL(fileURLWithPath: readString(row.path)),
                        sizeInBytes: Int64(row.size_bytes),
                        fileCount: Int(row.file_count)
                    )
                )
            }
        }

        return StorageAnalysis(
            mountPoint: readString(raw.mount_point),
            volumeName: readString(raw.volume_name),
            totalBytes: Int64(raw.total_bytes),
            freeBytes: Int64(raw.free_bytes),
            usedBytes: Int64(raw.used_bytes),
            categories: categories,
            topFiles: files,
            topDirectories: directories,
            scannedFileCount: Int(raw.scanned_file_count),
            scannedByteCount: Int64(raw.scanned_byte_count),
            skippedCount: Int(raw.skipped_count),
            isAggregated: raw.aggregated
        )
    }
    #endif

    /// The JSON shape the Rust `Options` struct parses.
    private struct RustStorageRequest: Encodable {
        let homeDir: String
        let roots: [String]
        let ignorePaths: [String]
        let topFileLimit: UInt32
        let topDirectoryLimit: UInt32
        let directoryRollupLimit: UInt32
        let largeFileThresholdBytes: UInt64
        let authorizedRoots: [String]
        let includeHiddenFiles: Bool
    }

    #if canImport(SiftScanner)
    /// Owns the Rust cancellation token for one analysis.
    ///
    /// The token is freed by `deinit`: the Rust call borrows it for the length
    /// of the analysis, and the watcher holds this object until it observes the
    /// cancellation or exits.
    private final class StorageCancelToken: @unchecked Sendable {
        fileprivate let raw = sift_storage_cancel_new()

        func cancel() {
            if let raw { sift_storage_cancel(raw) }
        }

        deinit {
            if let raw { sift_storage_cancel_free(raw) }
        }
    }

    /// Carries the result pointer across the task boundary.
    ///
    /// `UnsafeMutablePointer` is not `Sendable`; the box is the explicit escape
    /// hatch for a pointer that is created on the worker and consumed once by
    /// the caller.
    private final class StorageResultBox: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<SiftStorageAnalysis>?

        init(_ pointer: UnsafeMutablePointer<SiftStorageAnalysis>?) {
            self.pointer = pointer
        }
    }
    #endif
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
