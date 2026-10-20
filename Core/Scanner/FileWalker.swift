import Foundation
import OSLog
import Shared

/// Traversal primitives shared by the Swift scanner and the storage analysis.
///
/// These mirror the Rust walker in `crates/sift-scanner-core/src/walker.rs`
/// deliberately: symlinks are never followed, an unreadable directory produces a
/// skip record instead of failing the scan, cancellation is checked on every
/// entry, and package directories are reported as single units.
enum FileWalker {
    /// What a walk collects.
    enum Mode {
        /// Files only, stopping at package directories.
        case files
        /// Directories only, one level below the root.
        case immediateChildren
    }

    struct Options {
        var mode: Mode = .files
        /// The home directory the paths are compared against. Callers pass a
        /// resolved path, so it matches the paths the walker derives.
        var homeDirectory: URL
        var maxDepth: Int?
        var skipDirectoryNames: Set<String> = FileWalker.defaultSkipDirectoryNames
        var skipPaths: [String] = []
        /// Report a package directory as one entry instead of descending into it.
        var stopAtPackages = true
        /// Skip entries whose name starts with `.`.
        ///
        /// The "show hidden files" setting decides what the scan *produces*, not
        /// what the list happens to display: filtering only at display time would
        /// leave the category totals, the report and the rows disagreeing about
        /// the same run.
        var skipHidden = false
    }

    /// Directory names that never hold cleanup targets and are expensive to walk.
    static let defaultSkipDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", ".Trash",
    ]

    struct Entry {
        var url: URL
        var isDirectory: Bool
        /// Allocated size for files; `nil` for directories.
        var sizeBytes: Int64?
        var fileCount: Int
        var modifiedAt: Date?
        var createdAt: Date?
        var isPackage: Bool

        var displayName: String { url.lastPathComponent }
        var parentPath: String { url.deletingLastPathComponent().path }
    }

    struct Skip {
        var url: URL
        var code: ErrorCode
        var message: String
        var needsFullDiskAccess: Bool
    }

    struct Report {
        var entries: [Entry] = []
        var skips: [Skip] = []
        var totalFiles: Int = 0
        var totalBytes: Int64 = 0
        var truncated = false
        var cancelled = false
    }

    /// Walks `root`, honouring cancellation.
    ///
    /// Runs synchronously on the caller's thread: the scanner runs it inside a
    /// detached task, never on the main actor.
    static func walk(
        root: URL,
        options: Options,
        rules: RuleEngine,
        isCancelled: () -> Bool,
        onFile: ((Entry) -> Void)? = nil
    ) -> Report {
        var report = Report()

        // `symlink_metadata` equivalent: never follow the final component.
        let rootAttributes = try? FileManager.default.attributesOfItem(atPath: root.path)
        if let type = rootAttributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            report.skips.append(
                Skip(
                    url: root,
                    code: .fileNotFound,
                    message: "Symbolic links are not followed.",
                    needsFullDiskAccess: false
                )
            )
            return report
        }
        guard let rootAttributes, (rootAttributes[.type] as? FileAttributeType) == .typeDirectory else {
            report.skips.append(
                Skip(
                    url: root,
                    code: .invalidRequest,
                    message: "Scan root is not a directory.",
                    needsFullDiskAccess: false
                )
            )
            return report
        }

        var stack: [(URL, Int)] = [(root, 0)]
        while let (directory, depth) = stack.popLast() {
            if isCancelled() {
                report.cancelled = true
                return report
            }
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: []
                )
            } catch {
                report.skips.append(skip(for: directory, error: error))
                continue
            }

            for url in contents {
                if isCancelled() {
                    report.cancelled = true
                    return report
                }
                if options.skipPaths.contains(where: { RuleEngine.isPrefix($0, url.path) }) {
                    continue
                }
                if rules.protectionReason(for: url.path) != nil {
                    report.skips.append(
                        Skip(
                            url: url,
                            code: .protectedLocation,
                            message: LocalizationKey.scanSkippedReasonProtectedLocation.localized,
                            needsFullDiskAccess: false
                        )
                    )
                    continue
                }
                // An excluded application's data is skipped with its whole
                // subtree. Checking only a candidate's own name would let a large
                // or old file inside `~/Library/Caches/CloudKit` through, because
                // the file is called something else.
                if rules.isInExcludedLocation(url.path) { continue }

                let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
                // A symlink is skipped silently: they are common and a warning
                // per link would drown the real skips.
                if values?.isSymbolicLink == true { continue }

                let isDirectory = values?.isDirectory == true
                let name = url.lastPathComponent
                if options.skipHidden, name.hasPrefix(".") { continue }
                let isPackage = isDirectory && rules.isPackageDirectory(name: name)

                if isDirectory {
                    if options.skipDirectoryNames.contains(name) { continue }
                    if let maxDepth = options.maxDepth, depth + 1 > maxDepth { continue }

                    if options.mode == .immediateChildren, depth <= 1, !isPackage {
                        report.entries.append(
                            Entry(
                                url: url,
                                isDirectory: true,
                                sizeBytes: nil,
                                fileCount: 0,
                                modifiedAt: values?.contentModificationDate,
                                createdAt: values?.creationDate,
                                isPackage: false
                            )
                        )
                    }

                    if isPackage, options.stopAtPackages {
                        // A package is one item: its whole size is what removing it
                        // reclaims, so the hidden filter does not apply inside it.
                        let measured = measure(
                            url: url,
                            rules: rules,
                            skipHidden: false,
                            isCancelled: isCancelled
                        )
                        report.totalFiles += measured.files
                        report.totalBytes += measured.bytes
                        report.entries.append(
                            Entry(
                                url: url,
                                isDirectory: true,
                                sizeBytes: measured.bytes,
                                fileCount: measured.files,
                                modifiedAt: values?.contentModificationDate,
                                createdAt: values?.creationDate,
                                isPackage: true
                            )
                        )
                        continue
                    }
                    stack.append((url, depth + 1))
                } else {
                    guard options.mode != .immediateChildren else { continue }
                    let size = allocatedSize(values: values, url: url)
                    let entry = Entry(
                        url: url,
                        isDirectory: false,
                        sizeBytes: size,
                        fileCount: 1,
                        modifiedAt: values?.contentModificationDate,
                        createdAt: values?.creationDate,
                        isPackage: false
                    )
                    report.totalFiles += 1
                    report.totalBytes += size
                    report.entries.append(entry)
                    onFile?(entry)
                }
            }
        }
        return report
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
    ]

    /// Totals inside a directory, without producing per-file entries.
    ///
    /// `skipHidden` matches the walk's scope, so a measured directory reports the
    /// same bytes the scan would offer to remove.
    static func measure(
        url: URL,
        rules: RuleEngine,
        skipHidden: Bool = false,
        skipPaths: [String] = [],
        isCancelled: () -> Bool
    ) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        var stack = [url]
        while let directory = stack.popLast() {
            if isCancelled() { return (bytes, files) }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: []
            ) else { continue }
            for child in contents {
                let values = try? child.resourceValues(forKeys: Set(resourceKeys))
                if values?.isSymbolicLink == true { continue }
                if skipHidden, child.lastPathComponent.hasPrefix(".") { continue }
                // The user's "never visit" list applies to a measurement as well
                // as to a walk: measuring the ignored subtree would report bytes
                // a move of the parent directory would still take with it.
                if skipPaths.contains(where: { RuleEngine.isPrefix($0, child.path) }) { continue }
                // The walk never descends into an excluded location, so neither
                // may a measurement: otherwise a directory's reported size would
                // count bytes the scan refuses to offer.
                if rules.isInExcludedLocation(child.path) { continue }
                if values?.isDirectory == true {
                    if rules.protectionReason(for: child.path) != nil { continue }
                    stack.append(child)
                } else {
                    bytes += allocatedSize(values: values, url: child)
                    files += 1
                }
            }
        }
        return (bytes, files)
    }

    /// Allocated size when the filesystem reports it, logical size otherwise (§8.3).
    ///
    /// Allocated size is what makes the reported reclaimable space match the free
    /// space the Finder shows after a cleanup.
    static func allocatedSize(values: URLResourceValues?, url: URL) -> Int64 {
        if let allocated = values?.totalFileAllocatedSize, allocated > 0 {
            return Int64(allocated)
        }
        if let allocated = values?.fileAllocatedSize, allocated > 0 {
            return Int64(allocated)
        }
        if let size = values?.fileSize {
            return Int64(size)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Maps a filesystem error onto the product error table.
    static func skip(for url: URL, error: Error) -> Skip {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileReadUnknownError {
            return Skip(
                url: url,
                code: .permissionDenied,
                message: LocalizationKey.scanSkippedReasonPermissionDenied.localized,
                needsFullDiskAccess: true
            )
        }
        if nsError.domain == NSPOSIXErrorDomain, Int32(nsError.code) == EACCES || Int32(nsError.code) == EPERM {
            return Skip(
                url: url,
                code: .permissionDenied,
                message: LocalizationKey.scanSkippedReasonPermissionDenied.localized,
                needsFullDiskAccess: true
            )
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return Skip(
                url: url,
                code: .fileNotFound,
                message: LocalizationKey.scanSkippedReasonFileNotFound.localized,
                needsFullDiskAccess: false
            )
        }
        return Skip(
            url: url,
            code: .partialFailure,
            message: LocalizationKey.scanSkippedReasonPartialFailure.localized,
            needsFullDiskAccess: false
        )
    }
}

/// File identity for the duplicate pipeline.
///
/// Mirrors `FileIdentity` in `crates/sift-hasher`: size, modification time and
/// inode, which together detect that a file changed between two passes.
struct FileIdentity: Equatable {
    let size: Int64
    let modified: Date?
    let inode: UInt64
    /// A file with no allocated blocks but a non-zero length: a cloud
    /// placeholder or a fully sparse file. Never offered for deletion.
    let isPlaceholder: Bool

    init?(url: URL) {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .totalFileAllocatedSizeKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate
        if let identifier = values.fileResourceIdentifier as? NSNumber {
            self.inode = identifier.uint64Value
        } else {
            self.inode = 0
        }
        let allocated = values.totalFileAllocatedSize ?? 0
        self.isPlaceholder = allocated == 0 && size > 0
    }
}
