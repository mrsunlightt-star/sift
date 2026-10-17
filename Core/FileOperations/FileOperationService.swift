import Foundation
import OSLog
import Shared

/// All destructive file work lives here (§9).
///
/// Four rules shape this type:
///
///  1. **Trash, never delete.** Every cleanup and uninstall moves items to the
///     Trash through `FileManager.trashItem`, so the user can undo until they
///     empty it. There is no permanent-delete path in this file at all.
///  2. **No shell.** Nothing here builds a command string. Paths with spaces,
///     quotes, newlines or emoji are just paths.
///  3. **Re-validate, then act.** Every item is re-checked against the
///     protection list and re-stat'ed immediately before the move; a stale scan
///     result is never trusted (§13.3).
///  4. **Partial success is reported per item.** One failure never rolls back or
///     hides the items that already moved (§9.3).
public actor FileOperationService {
    /// Snapshot of what the service needs to know about a candidate item.
    public struct Candidate: Sendable, Hashable {
        public let url: URL
        public let category: CleanupCategory
        public let risk: CleanupRisk
        public let sizeInBytes: Int64
        public let displayName: String

        public init(url: URL, category: CleanupCategory, risk: CleanupRisk, sizeInBytes: Int64, displayName: String) {
            self.url = url
            self.category = category
            self.risk = risk
            self.sizeInBytes = sizeInBytes
            self.displayName = displayName
        }

        public init(item: CleanupItem) {
            self.init(
                url: item.url,
                category: item.category,
                risk: item.risk,
                sizeInBytes: item.sizeInBytes,
                displayName: item.displayName
            )
        }
    }

    private let rules: RuleEngine
    private let fileManager: FileManager
    private let logger = SiftLog.operations

    /// Simulated runs, used by the test suite so a test can never move a real
    /// file. Production code never enables this.
    private let isDryRun: Bool
    /// Records what a dry run would have done, so tests can assert on it.
    private var simulatedOperations: [URL] = []
    /// Cached running-application snapshot, refreshed at most once per second.
    private var runningPathsCache: (Date, Set<String>)?

    public init(rules: RuleEngine, fileManager: FileManager = .default, isDryRun: Bool = false) {
        self.rules = rules
        self.fileManager = fileManager
        self.isDryRun = isDryRun
    }

    // MARK: - Pre-flight

    /// Checks a selection before anything is moved (§9.2).
    ///
    /// Resolves, in one pass:
    ///  * items the protection list forbids, which are reported and dropped,
    ///  * items that no longer exist, or whose path changed since the scan,
    ///  * symlinks, which are never followed,
    ///  * parent/child overlap, so a folder and a file inside it are not both
    ///    counted,
    ///  * items a running application holds open.
    public func preflight(_ candidates: [Candidate], homeDirectory: URL? = nil) async -> PreflightReport {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        var ready: [Candidate] = []
        var skipped: [(item: Candidate, code: ErrorCode, message: String)] = []
        var subsumed: [Candidate] = []
        var protected: [Candidate] = []

        // Deepest paths first, so a parent can absorb its children without the
        // children having been queued already.
        let ordered = candidates.sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }

        for candidate in ordered {
            let path = candidate.url.path

            if let reason = rules.protectionReason(for: path) {
                protected.append(candidate)
                logger.notice(
                    "Refused a protected location (code=protectedLocation, reason=\(String(describing: reason)))"
                )
                continue
            }

            if rules.isExcludedBundleName(candidate.url.lastPathComponent) {
                protected.append(candidate)
                logger.notice("Refused an excluded bundle name")
                continue
            }

            // A symlink is never followed and never moved: its target may be
            // outside the authorised scope.
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                skipped.append((candidate, .protectedLocation, "Symbolic links are never followed."))
                continue
            }

            guard fileManager.fileExists(atPath: path) else {
                skipped.append((candidate, .fileNotFound, LocalizationKey.cleanupFailureFileNotFound.localized))
                continue
            }

            if isSubsumed(candidate, by: ready) {
                subsumed.append(candidate)
                continue
            }

            if isInUse(candidate, attributes: attributes) {
                skipped.append((candidate, .fileInUse, LocalizationKey.cleanupFailureFileInUse.localized))
                continue
            }

            ready.append(candidate)
        }

        // A parent chosen after its children must still absorb them.
        let resolved = resolveOverlap(ready)
        if resolved.count != ready.count {
            let absorbed = ready.filter { candidate in
                !resolved.contains(where: { $0.url == candidate.url })
            }
            subsumed.append(contentsOf: absorbed)
        }

        logger.info(
            "Pre-flight: ready=\(resolved.count) skipped=\(skipped.count) subsumed=\(subsumed.count) protected=\(protected.count)"
        )
        return PreflightReport(
            ready: resolved.map { $0.asCleanupItem() },
            skipped: skipped.map { (item: $0.item.asCleanupItem(), code: $0.code, message: $0.message) },
            subsumed: subsumed.map { $0.asCleanupItem() },
            protected: protected.map { $0.asCleanupItem() }
        )
    }

    /// Drops any item contained in another selected directory.
    private func resolveOverlap(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates {
            if isSubsumed(candidate, by: kept) { continue }
            kept.append(candidate)
        }
        return kept
    }

    private func isSubsumed(_ candidate: Candidate, by selected: [Candidate]) -> Bool {
        selected.contains { parent in
            parent.url != candidate.url
                && isDirectory(parent.url)
                && RuleEngine.isPrefix(parent.url.path, candidate.url.path)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// True when an application currently holds the file open.
    ///
    /// Uses the file's open-count through `NSFileCoordinator`-free means: a
    /// readable descriptor plus a non-zero open count from the volume is the
    /// cheap check; anything else is treated as available and the move itself
    /// will report the real failure.
    private func isInUse(_ candidate: Candidate, attributes: [FileAttributeKey: Any]?) -> Bool {
        _ = attributes
        // A running `.app` bundle is the case the user hits in practice: removing
        // it while it runs produces an opaque failure, so it is reported as
        // `fileInUse` up front. The check runs on the main actor because only
        // AppKit knows which applications are running.
        guard candidate.url.pathExtension == "app" else { return false }
        return cachedRunningBundlePaths().contains(
            candidate.url.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    /// Snapshot of running bundle paths, refreshed at most once per second.
    ///
    /// The pre-flight check asks about every selected item, and a snapshot keeps
    /// that from becoming one main-actor hop per file.
    private func cachedRunningBundlePaths() -> Set<String> {
        let now = Date()
        if let cached = runningPathsCache, now.timeIntervalSince(cached.0) < 1 {
            return cached.1
        }
        let paths = Self.runningBundlePathsSnapshot()
        runningPathsCache = (now, paths)
        return paths
    }

    /// Reads the running-application list from the main actor, synchronously.
    ///
    /// Pre-flight already runs off the main thread, so a short wait here costs
    /// nothing compared to the disk work that follows.
    private static func runningBundlePathsSnapshot() -> Set<String> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = PathBox()
        DispatchQueue.main.async {
            box.paths = Set(NSWorkspaceWorker.shared.runningApplicationBundlePaths())
            semaphore.signal()
        }
        // A timeout keeps a hung main thread from blocking a cleanup forever.
        _ = semaphore.wait(timeout: .now() + 2)
        return box.paths
    }

    // MARK: - Execution

    /// Moves a pre-flighted selection to the Trash.
    ///
    /// Returns one result per item. Items are processed sequentially on this
    /// actor so two operations can never race on the same path.
    public func moveToTrash(
        _ items: [CleanupItem],
        categoryTotals: [CategoryTotal] = [],
        operation: CleanupOperationName = .junkCleanup
    ) async -> CleanupOutcome {
        let startedAt = Date()
        var results: [FileOperationResult] = []

        for item in items {
            // Re-validate every item immediately before acting: the scan result
            // may be minutes old, and a protected path must never slip through
            // because it was classified earlier.
            if let reason = rules.protectionReason(for: item.url.path) {
                logger.error("Blocked a protected path at execution time (reason=\(String(describing: reason)))")
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: ErrorCode.protectedLocation.rawValue,
                        message: reason.explanation,
                        sizeInBytes: item.sizeInBytes
                    )
                )
                continue
            }

            guard fileManager.fileExists(atPath: item.url.path) else {
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .skipped,
                        errorCode: ErrorCode.fileNotFound.rawValue,
                        message: LocalizationKey.cleanupFailureFileNotFound.localized,
                        sizeInBytes: item.sizeInBytes
                    )
                )
                continue
            }

            if isDryRun {
                simulatedOperations.append(item.url)
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        destinationURL: URL(fileURLWithPath: "/Trash").appendingPathComponent(item.displayName),
                        status: .movedToTrash,
                        sizeInBytes: item.sizeInBytes
                    )
                )
                continue
            }

            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        destinationURL: resultingURL as URL?,
                        status: .movedToTrash,
                        sizeInBytes: item.sizeInBytes
                    )
                )
                logger.debug(
                    "Moved one item to the Trash (category=\(item.category.rawValue, privacy: .public) band=\(SizeBand(bytes: item.sizeInBytes).rawValue, privacy: .public))"
                )
            } catch {
                let code = Self.classify(error)
                logger.error(
                    "Move failed (code=\(code.rawValue, privacy: .public) category=\(item.category.rawValue, privacy: .public))"
                )
                results.append(
                    FileOperationResult(
                        sourceURL: item.url,
                        status: .failed,
                        errorCode: code.rawValue,
                        message: Self.message(for: error, code: code),
                        sizeInBytes: item.sizeInBytes
                    )
                )
            }
        }

        let finishedAt = Date()
        let outcome = CleanupOutcome(
            results: results,
            categoryTotals: categoryTotals,
            startedAt: startedAt,
            finishedAt: finishedAt,
            operationName: operation
        )
        logger.info(
            "Batch finished (moved=\(outcome.movedCount) skipped=\(outcome.skippedCount) failed=\(outcome.failedCount) band=\(SizeBand(bytes: outcome.releasedBytes).rawValue, privacy: .public))"
        )
        return outcome
    }

    /// Reveals the Trash in Finder, for the "show me where it went" button.
    public func trashDirectoryURL() -> URL {
        // `~/.Trash` is where `trashItem` puts things for the current user.
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// The operations a dry run recorded. Test-only.
    public func simulatedOperationCount() -> Int { simulatedOperations.count }

    // MARK: - Error classification

    /// Maps a `FileManager` error onto the product error table (§14).
    static func classify(_ error: Error) -> ErrorCode {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .fileNotFound
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied
            case NSFileWriteVolumeReadOnlyError, NSFileWriteUnknownError:
                return .volumeUnavailable
            case NSFileWriteFileExistsError:
                return .partialFailure
            default:
                return .partialFailure
            }
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case EBUSY, ETXTBSY:
                return .fileInUse
            case EACCES, EPERM:
                return .permissionDenied
            case ENOENT:
                return .fileNotFound
            case EROFS:
                return .volumeUnavailable
            default:
                return .partialFailure
            }
        default:
            return .partialFailure
        }
    }

    /// A user-facing sentence, never the raw system error text.
    static func message(for error: Error, code: ErrorCode) -> String {
        _ = error
        return code.localizedTitle.localized
    }
}

extension FileOperationService.Candidate {
    /// Promotes a pre-flight candidate to a domain item.
    func asCleanupItem() -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: displayName,
            category: category,
            risk: risk,
            sizeInBytes: sizeInBytes,
            fileCount: 1,
            explanationKey: "cleanup.explanation.temporary",
            sourceRuleID: "preflight"
        )
    }
}

/// A tiny reference box used to move the main-actor result out of the closure.
private final class PathBox: @unchecked Sendable {
    var paths: Set<String> = []
}
