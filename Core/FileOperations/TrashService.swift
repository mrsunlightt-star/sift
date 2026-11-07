import Foundation
import OSLog
import Shared

/// The one place that removes something permanently.
///
/// Everything the cleaner does moves items to the Trash, and the undo the product
/// promises *is* the Trash (§9.1). That promise has a second half the product did
/// not have: the space is not reclaimed until the bin is emptied, so the user ends
/// up in the Finder emptying it by hand — where nothing checks that the bin holds
/// only what Sift put there.
///
/// So this type exists, and it is deliberately small and boring:
///
///  1. **One directory.** The user's own `~/.Trash`. Never another volume's
///     `.Trashes`, never a path assembled from anything but the entries found
///     inside that directory.
///  2. **Enumerated, then removed.** It lists what is there and removes each
///     entry by name. It never accepts a path from a caller, so there is no
///     argument that could point it somewhere else.
///  3. **No rule, no protection check.** Every path under a recycle bin is on the
///     protection list — that is what stops a cleanup from offering the bin's
///     contents — so the protection list cannot be consulted here. What replaces
///     it: the root is a fixed constant, the entries are the root's own children,
///     and the caller has to have shown the user the count and the size first.
///  4. **Reported per entry.** One unremovable item never hides the others, and
///     never aborts the run.
///
/// The service is an actor because two of them emptying the same bin at once
/// would produce two contradictory outcomes for the same files.
public actor TrashService {
    /// One entry in the Trash.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let url: URL
        public let isDirectory: Bool
        public let bytes: Int64
        /// The number of files inside a directory entry; `1` for a file.
        public let fileCount: Int

        public var id: String { url.path }
    }

    /// Why the bin could not be listed.
    ///
    /// The product promise is that emptying the Trash is what reclaims the space
    /// a cleanup freed, so "0 items" and "Sift may not look in the bin" are
    /// opposite statements about the user's disk. The first says there is nothing
    /// to do; the second says the action the user came for cannot be taken, and
    /// the page has to say which of the two it is.
    public enum UnreadableReason: Sendable, Equatable {
        /// The directory exists and this process may not list it, which is the
        /// state a Mac without Full Disk Access is in: `~/.Trash` is one of the
        /// locations macOS withholds until the user grants it.
        case needsFullDiskAccess
        /// The listing failed for another reason — a directory that is not one,
        /// or an I/O error. Reported rather than turned into an empty bin.
        case listingFailed

        /// The heading the page shows.
        public var titleKey: LocalizationKey {
            switch self {
            case .needsFullDiskAccess: .permissionFullDiskAccess
            case .listingFailed: .cleanupFailurePermissionDenied
            }
        }

        /// The sentence that says what to do about it.
        public var detailKey: LocalizationKey {
            switch self {
            case .needsFullDiskAccess: .permissionFullDiskAccessDetail
            case .listingFailed: .cleanupFailurePermissionDenied
            }
        }

        /// Whether the page should offer the shortcut to System Settings.
        public var offersSettingsAction: Bool {
            self == .needsFullDiskAccess
        }
    }

    /// What the Trash holds right now.
    public struct Snapshot: Sendable, Equatable {
        public let entries: [Entry]
        public let totalBytes: Int64
        /// Why the bin could not be listed, when it could not.
        ///
        /// Carried on the snapshot rather than folded into an empty entry list:
        /// every caller already passes the snapshot to the confirmation that
        /// states what is about to be removed, so the state travels with the
        /// number instead of depending on each page asking twice. `nil` means the
        /// answer came from the directory.
        public let unreadable: UnreadableReason?

        public init(entries: [Entry], totalBytes: Int64, unreadable: UnreadableReason? = nil) {
            self.entries = entries
            self.totalBytes = totalBytes
            self.unreadable = unreadable
        }

        public var count: Int { entries.count }
        public var isEmpty: Bool { entries.isEmpty }

        /// True when the bin exists and this process may not list it.
        ///
        /// A page that offers "Empty Trash" must check this first and show
        /// guidance instead: emptying a bin it cannot read would report a success
        /// it cannot verify.
        public var isUnreadable: Bool { unreadable != nil }

        public static let empty = Snapshot(entries: [], totalBytes: 0)

        /// A bin that is there and cannot be read.
        public static func unreadable(_ reason: UnreadableReason) -> Snapshot {
            Snapshot(entries: [], totalBytes: 0, unreadable: reason)
        }
    }

    /// What emptying the Trash did.
    public struct Outcome: Sendable, Equatable {
        public let removedCount: Int
        public let removedBytes: Int64
        /// Entries that could not be removed, with the reason. Non-empty means the
        /// bin still holds something the user has to deal with.
        public let failures: [Failure]

        public struct Failure: Sendable, Equatable {
            public let url: URL
            public let message: String
        }

        public init(removedCount: Int, removedBytes: Int64, failures: [Failure]) {
            self.removedCount = removedCount
            self.removedBytes = removedBytes
            self.failures = failures
        }

        /// Nothing removed, nothing failed — the answer a page that cannot reach
        /// the bin gives rather than an absent one.
        public static let none = Outcome(removedCount: 0, removedBytes: 0, failures: [])

        public var isComplete: Bool { failures.isEmpty }
    }

    private let fileManager: FileManager
    private let logger = SiftLog.operations
    /// Simulated removal, so the test suite can never empty a real Trash.
    private let isDryRun: Bool
    private var simulatedRemovals: [URL] = []

    /// The bin this service acts on.
    ///
    /// `~/.Trash` for the process user's home, spelled through the same
    /// normalisation the rest of the product uses. The home is a parameter so a
    /// test can point at a fixture: production always passes the real one.
    private let trashURL: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        isDryRun: Bool = false
    ) {
        self.fileManager = fileManager
        self.isDryRun = isDryRun
        self.trashURL = homeDirectory
            .appendingPathComponent(".Trash", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// The bin's current contents, measured the way the scanner measures.
    ///
    /// Three outcomes, and the difference between the last two is the point:
    ///
    ///  * no bin at all — a real state (a fresh account, or one that has never
    ///    emptied anything) and an empty answer;
    ///  * a bin that lists — its entries;
    ///  * a bin that exists and cannot be listed. `try?` turned this into `.empty`
    ///    as well, so a Mac without Full Disk Access was told its bin was empty
    ///    while the space it came to reclaim sat in it. The state travels on the
    ///    snapshot so the page can offer the guidance instead of "0 items".
    public func inspect() async -> Snapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trashURL.path, isDirectory: &isDirectory) else {
            return .empty
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: trashURL.path)
        } catch {
            let reason = Self.unreadableReason(for: error)
            logger.notice(
                "The Trash could not be listed (reason=\(String(describing: reason), privacy: .public))"
            )
            return .unreadable(reason)
        }
        var entries: [Entry] = []
        var total: Int64 = 0
        for name in names.sorted() {
            let url = trashURL.appendingPathComponent(name)
            guard let entry = measure(url) else { continue }
            entries.append(entry)
            total += entry.bytes
        }
        return Snapshot(entries: entries, totalBytes: total)
    }

    /// Which guidance an unlistable bin deserves.
    ///
    /// `EPERM` and `EACCES` from `~/.Trash` are the Full Disk Access case rather
    /// than a permissions accident: macOS withholds the bin from a process the
    /// user has not granted it to, and telling the user to check file permissions
    /// on their own Trash sends them looking for a problem that is not there.
    static func unreadableReason(for error: Error) -> UnreadableReason {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case EPERM, EACCES: return .needsFullDiskAccess
            default: return .listingFailed
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return .needsFullDiskAccess
            default: return .listingFailed
            }
        }
        return .listingFailed
    }

    /// Removes every entry the given snapshot reported.
    ///
    /// The snapshot is an argument rather than a re-read, so the batch the caller
    /// confirmed is the batch that goes: an entry that appeared while the
    /// confirmation was open is not removed, and one the user saw is not silently
    /// skipped. Entries the snapshot named that are already gone are not counted
    /// as failures — the user's goal for them is met.
    public func empty(_ snapshot: Snapshot) async -> Outcome {
        var removedCount = 0
        var removedBytes: Int64 = 0
        var failures: [Outcome.Failure] = []

        for entry in snapshot.entries {
            // Only this directory's own children. A snapshot assembled by hand
            // cannot reach anywhere else, because the path is rebuilt from the
            // bin and the entry's last component.
            let target = trashURL.appendingPathComponent(entry.url.lastPathComponent)
            guard target.path == entry.url.path else {
                failures.append(.init(url: entry.url, message: LocalizationKey.commonUnknownError.localized))
                logger.error("Refused a Trash entry outside the bin")
                continue
            }
            guard fileManager.fileExists(atPath: target.path)
                || (try? fileManager.attributesOfItem(atPath: target.path)) != nil
            else {
                continue
            }

            if isDryRun {
                simulatedRemovals.append(target)
                removedCount += 1
                removedBytes += entry.bytes
                continue
            }

            do {
                // `removeItem` unlinks a symlink rather than following it, so an
                // entry that is a link removes the link and leaves its target.
                try fileManager.removeItem(at: target)
                removedCount += 1
                removedBytes += entry.bytes
            } catch {
                // The message a row shows is the product's own sentence, never
                // the raw system error text: Foundation's description carries
                // the entry's name, and the code table already decides what the
                // user reads.
                let code = FileOperationService.classify(error, at: target)
                failures.append(.init(url: target, message: code.localizedTitle.localized))
                logger.error("Could not empty a Trash entry")
            }
        }

        logger.info(
            "Emptied the Trash: removed=\(removedCount) failures=\(failures.count) bytes=\(removedBytes)"
        )
        return Outcome(removedCount: removedCount, removedBytes: removedBytes, failures: failures)
    }

    /// The entries a dry run would have removed, so a test can assert on them.
    public func simulatedOperations() -> [URL] { simulatedRemovals }

    /// One entry's shape and size.
    ///
    /// Measured with allocated size (`st_blocks`), the number the Finder and the
    /// scanner both report: a bin that says 8 KB while the Finder says 12 KB
    /// reads as a lie even when the bytes are real.
    private func measure(_ url: URL) -> Entry? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            // A link to a directory is measured as a link, never followed: the
            // files behind it are not in the bin.
            if let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                return Entry(url: url, isDirectory: false, bytes: 0, fileCount: 1)
            }
            let measured = measureDirectory(url)
            return Entry(url: url, isDirectory: true, bytes: measured.bytes, fileCount: measured.files)
        }
        return Entry(url: url, isDirectory: false, bytes: allocatedSize(url), fileCount: 1)
    }

    private func measureDirectory(_ url: URL) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    private func allocatedSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
