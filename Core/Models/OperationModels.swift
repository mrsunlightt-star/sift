import Darwin
import Foundation
import Shared

/// Outcome of one file operation (§7.3).
public enum OperationStatus: String, Codable, Sendable {
    case movedToTrash
    case skipped
    case failed

    public var isSuccess: Bool { self == .movedToTrash }
}

/// One item's result inside a batch (§7.3).
public struct FileOperationResult: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationURL: URL?
    public let status: OperationStatus
    /// Stable error code from the product error table (§14).
    public let errorCode: String?
    public let message: String?
    public let sizeInBytes: Int64
    /// The cleanup category the item came from, so a report can name it.
    public let category: CleanupCategory?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL? = nil,
        status: OperationStatus,
        errorCode: String? = nil,
        message: String? = nil,
        sizeInBytes: Int64 = 0,
        category: CleanupCategory? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.status = status
        self.errorCode = errorCode
        self.message = message
        self.sizeInBytes = sizeInBytes
        self.category = category
    }

    /// Localised explanation for the failure code.
    public var failureTitle: String {
        guard let errorCode else { return LocalizationKey.commonUnknownError.localized }
        let key = ErrorCode(rawValue: errorCode)?.localizedTitle ?? .commonUnknownError
        return key.localized
    }

    public var displayPath: String { CleanupItem.abbreviate(sourceURL.path) }
}

/// The batch rollup shown on the cleanup result page (§5.2).
public struct CleanupOutcome: Identifiable, Sendable {
    public let id: UUID
    public let results: [FileOperationResult]
    public let categoryTotals: [CategoryTotal]
    public let startedAt: Date
    public let finishedAt: Date
    /// Which operation produced this outcome.
    public let operationName: CleanupOperationName
    /// How many items the user stopped after, when they stopped a batch.
    ///
    /// A batch that a person interrupted is not a batch that failed: the items
    /// still in the plan were never judged, so they must not be counted as
    /// skipped or as failed. The page reports "stopped after N items" from this
    /// and nothing else.
    public let stoppedAfter: Int?
    /// Counts restored from local history, used when a stored outcome is shown
    /// without its per-item results.
    private let summaryOverride: (count: Int, bytes: Int64)?

    public init(
        id: UUID = UUID(),
        results: [FileOperationResult],
        categoryTotals: [CategoryTotal],
        startedAt: Date,
        finishedAt: Date,
        operationName: CleanupOperationName,
        stoppedAfter: Int? = nil,
        summaryOverride: (count: Int, bytes: Int64)? = nil
    ) {
        self.id = id
        self.results = results
        self.categoryTotals = categoryTotals
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.operationName = operationName
        self.stoppedAfter = stoppedAfter
        self.summaryOverride = summaryOverride
    }

    /// True when the user interrupted the batch.
    public var wasStopped: Bool { stoppedAfter != nil }

    /// Nothing moved and nothing refused — the value a closing sheet renders
    /// for the frame between dismissal and teardown.
    public static let none = CleanupOutcome(
        results: [],
        categoryTotals: [],
        startedAt: Date(),
        finishedAt: Date(),
        operationName: .junkCleanup
    )

    public var movedCount: Int {
        summaryOverride?.count ?? results.filter { $0.status == .movedToTrash }.count
    }

    public var skippedCount: Int { results.filter { $0.status == .skipped }.count }
    public var failedCount: Int { results.filter { $0.status == .failed }.count }

    /// Space actually released, computed from the items that moved rather than
    /// from the estimate the user approved. Reporting the estimate would
    /// overstate the result whenever a batch partially fails.
    public var releasedBytes: Int64 {
        summaryOverride?.bytes ?? results.filter { $0.status == .movedToTrash }.reduce(0) { $0 + $1.sizeInBytes }
    }

    public var formattedReleased: String { SiftFormat.bytes(releasedBytes) }

    public var failedResults: [FileOperationResult] {
        results.filter { $0.status == .failed }
    }

    public var skippedResults: [FileOperationResult] {
        results.filter { $0.status == .skipped }
    }

    /// True when at least one item failed, which is what drives the "partial
    /// failure" presentation (§14).
    public var hasFailures: Bool { failedCount > 0 }
}

/// What putting a batch back produced.
///
/// The undo the product promises is the Trash, and this is that promise made
/// actionable: every item that moved can be put back until the bin is emptied.
/// A restore is a file operation like any other, so it reports per item.
public struct RestoreReport: Sendable {
    public let restored: [URL]
    public let failures: [FileOperationResult]

    public init(restored: [URL], failures: [FileOperationResult]) {
        self.restored = restored
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }
    public var isEmpty: Bool { restored.isEmpty && failures.isEmpty }
}

/// What a running batch has done so far.
///
/// The move reports items, not bytes: a batch of 5,000 entries takes as long as
/// it takes, and a byte percentage would be a number the product invented. The
/// overlay shows "137 of 500" because that is the count it can stand behind.
public struct ExecutionProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let movedBytes: Int64
    /// Leaf name of the item being handled, never a full path.
    public let currentName: String

    public init(done: Int, total: Int, movedBytes: Int64, currentName: String) {
        self.done = done
        self.total = total
        self.movedBytes = movedBytes
        self.currentName = currentName
    }

    public var fraction: Double {
        total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0
    }
}

/// A one-way "stop after the item in hand" flag.
///
/// The page sets it and the file-operation actor reads it, so it has to be safe
/// to touch from two executors; a lock is cheaper than hopping to the main actor
/// once per item and cannot deadlock the move it is trying to interrupt.
public final class StopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Which operation produced an outcome, used by the report's title and by the
/// history list.
public enum CleanupOperationName: String, Codable, Sendable, CaseIterable {
    case smartScan
    case junkCleanup
    case uninstall
    case largeFiles
    case oldFiles
    case duplicateFiles

    public var titleKey: LocalizationKey {
        switch self {
        case .smartScan: .navSmartScan
        case .junkCleanup: .navJunkCleanup
        case .uninstall: .navUninstaller
        case .largeFiles: .filesModeLarge
        case .oldFiles: .filesModeOld
        case .duplicateFiles: .filesModeDuplicates
        }
    }
}

/// Stable error codes shared with the scanner and the product error table (§14).
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case permissionDenied
    case fileNotFound
    case fileInUse
    /// The path no longer resolves to the item the user selected.
    ///
    /// Raised when the item was replaced between the pre-flight check and the
    /// move — by a symlink in particular, because a move follows a link in any
    /// component of the path and would then act on whatever it points at.
    case itemChanged
    case volumeUnavailable
    case protectedLocation
    case partialFailure
    case licenseServiceUnavailable
    case storeUnavailable
    case cancelled
    case invalidRequest
    case internalError = "internal"

    /// The action-oriented sentence the user sees.
    public var localizedTitle: LocalizationKey {
        switch self {
        case .permissionDenied: .cleanupFailurePermissionDenied
        case .fileNotFound: .cleanupFailureFileNotFound
        case .fileInUse: .cleanupFailureFileInUse
        case .itemChanged: .cleanupFailureItemChanged
        case .volumeUnavailable: .cleanupFailureVolumeUnavailable
        case .protectedLocation: .cleanupFailureProtectedLocation
        case .partialFailure: .cleanupFailurePartialFailure
        case .licenseServiceUnavailable: .purchaseNetworkUnavailable
        case .storeUnavailable: .purchaseFailed
        case .cancelled: .scanPhaseCancelled
        case .invalidRequest, .internalError: .commonUnknownError
        }
    }

    /// The next step offered to the user, when there is one.
    ///
    /// §14 requires every error to come with something the user can do, so this
    /// drives whether the UI shows an action button and which one.
    public var suggestedAction: ErrorAction? {
        switch self {
        case .permissionDenied: .openSystemSettings
        case .volumeUnavailable: .retry
        case .itemChanged: .retry
        case .partialFailure: .retry
        case .licenseServiceUnavailable, .storeUnavailable: .retry
        case .fileInUse: .quitApp
        default: nil
        }
    }
}

/// The action a failed operation offers.
public enum ErrorAction: Sendable, Equatable {
    case openSystemSettings
    case retry
    case quitApp

    public var titleKey: LocalizationKey {
        switch self {
        case .openSystemSettings: .permissionOpenSettings
        case .retry: .commonRetry
        case .quitApp: .commonQuitApp
        }
    }
}

/// Pre-flight verdict for one candidate item (§9.2).
public enum PreflightVerdict: Sendable, Equatable {
    /// The item can be moved to the Trash.
    case ready
    /// The item will be skipped, with the reason shown to the user.
    case skip(code: ErrorCode, message: String)
    /// The item was already covered by a selected parent directory.
    case subsumedByParent(URL)

    public var isReady: Bool { self == .ready }
}

/// The object a path named when pre-flight approved it.
///
/// A path is not an identity. Between pre-flight and the move the object at that
/// path can be replaced, and the protection list cannot see the substitution
/// because the path itself is unchanged. Device, inode and file type are read
/// with `lstat`, so a selected symlink is identified as the link rather than as
/// whatever it points at.
public struct FileIdentitySnapshot: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt16

    /// Internal, like `ApprovedPlan.init`: an identity is what pre-flight read
    /// from the disk, and a caller that can mint one can describe an object it
    /// never looked at. `of(path:)` is the only producer.
    init(device: UInt64, inode: UInt64, fileType: UInt16) {
        self.device = device
        self.inode = inode
        self.fileType = fileType
    }

    /// Reads the identity without following a symlink in the final component.
    ///
    /// A symlink in an ancestor is followed: that is the object `trashItem`
    /// would reach, so an ancestor re-pointed to another directory changes this
    /// identity too.
    public static func of(path: String) -> FileIdentitySnapshot? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentitySnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            fileType: info.st_mode & S_IFMT
        )
    }
}

/// A pre-flighted batch that is allowed to reach the Trash.
///
/// The only way to obtain one is `PreflightReport.makeApprovedPlan(operation:)`.
/// The initialiser is internal to `Core` on purpose: a feature page cannot
/// assemble a plan from a live selection, so the risk and identity checks that
/// pre-flight performed cannot be skipped by choosing another entry point.
public struct ApprovedPlan: Sendable {
    public let operation: CleanupOperationName
    public let items: [CleanupItem]
    /// The object each approved path named at pre-flight. Every item has one;
    /// execution refuses an item whose identity is missing or has changed.
    public let identities: [String: FileIdentitySnapshot]
    public let categoryTotals: [CategoryTotal]
    /// Items pre-flight refused, carried into the outcome so the result page
    /// describes the whole batch rather than only the items that moved.
    public let refusedResults: [FileOperationResult]
    public let preparedAt: Date

    init(
        operation: CleanupOperationName,
        items: [CleanupItem],
        identities: [String: FileIdentitySnapshot],
        categoryTotals: [CategoryTotal],
        refusedResults: [FileOperationResult],
        preparedAt: Date = Date()
    ) {
        self.operation = operation
        self.items = items
        self.identities = identities
        self.categoryTotals = categoryTotals
        self.refusedResults = refusedResults
        self.preparedAt = preparedAt
    }

    public var count: Int { items.count }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
    public var formattedBytes: String { SiftFormat.bytes(bytes) }
}

/// The result of pre-flight checking a whole selection.
///
/// The initialiser is the seam an `ApprovedPlan` could have been assembled
/// through without pre-flight. It is still `public` because
/// `SelfTest/SiftSelfTest.swift` builds a forged report on purpose — its case is
/// "execution refuses a protected item", which pre-flight never approves — and
/// that target imports `Core` without `@testable`. Closing it (making this
/// initialiser and `makeApprovedPlan` internal, like `ApprovedPlan.init`) needs
/// that file's four call sites adapted first. What does not depend on the access
/// level is enforced where it matters: `ApprovedPlan.init` is internal,
/// `FileIdentitySnapshot.init` is internal, and
/// `FileOperationService.execute` re-derives the risk of every item before it
/// moves it and refuses a path no rule may offer.
public struct PreflightReport: Sendable {
    public let ready: [CleanupItem]
    public let skipped: [(item: CleanupItem, code: ErrorCode, message: String)]
    /// Items dropped because a selected directory already contains them.
    public let subsumed: [CleanupItem]
    /// Items the protection list rejects, which must never be acted on.
    public let protected: [CleanupItem]
    /// The object each ready item named at pre-flight, keyed by item id.
    ///
    /// Execution compares this snapshot with the object at the path immediately
    /// before the move. Every ready item must have an entry; an item with no
    /// identity is not approved.
    public let identities: [String: FileIdentitySnapshot]

    public init(
        ready: [CleanupItem],
        skipped: [(item: CleanupItem, code: ErrorCode, message: String)],
        subsumed: [CleanupItem],
        protected: [CleanupItem],
        identities: [String: FileIdentitySnapshot] = [:]
    ) {
        self.ready = ready
        self.skipped = skipped
        self.subsumed = subsumed
        self.protected = protected
        self.identities = identities
    }

    /// Total bytes of the items that will actually be moved.
    public var readyBytes: Int64 { ready.reduce(0) { $0 + $1.sizeInBytes } }

    public var formattedReadyBytes: String { SiftFormat.bytes(readyBytes) }

    public var hasBlockingIssues: Bool { !skipped.isEmpty || !protected.isEmpty }

    /// The items pre-flight refused, shaped as results the outcome can carry.
    ///
    /// `moveToTrash` never sees these, so without them the result page would
    /// describe a batch it only half performed: an item dropped because its
    /// application is running, because it was removed while the confirmation
    /// panel was open, or because its path no longer resolves to itself would
    /// simply be missing, and the user could not tell that from an item that was
    /// never selected. Everything refused is reported with the reason pre-flight
    /// found, which is the sentence the row shows.
    ///
    /// `subsumed` items are deliberately not here. They are not refused: the
    /// selected directory that contains them moved, their bytes are already part
    /// of that item's total, and listing them again would report one file twice
    /// under a status that reads like a failure.
    public var refusedResults: [FileOperationResult] {
        skipped.map {
            FileOperationResult(
                sourceURL: $0.item.url,
                status: .skipped,
                errorCode: $0.code.rawValue,
                message: $0.message,
                sizeInBytes: $0.item.sizeInBytes,
                category: $0.item.category
            )
        } + protected.map {
            FileOperationResult(
                sourceURL: $0.url,
                status: .skipped,
                errorCode: ErrorCode.protectedLocation.rawValue,
                message: ErrorCode.protectedLocation.localizedTitle.localized,
                sizeInBytes: $0.sizeInBytes,
                category: $0.category
            )
        }
    }

    /// The batch execution is allowed to act on.
    ///
    /// Returns `nil` when a ready item has no identity or is not cleanable. The
    /// checks repeat what `FileOperationService.preflight` already enforced, so a
    /// report assembled by another caller cannot turn into an executable plan
    /// without at least presenting an identity for every item — and an identity
    /// can only be read from the disk (`FileIdentitySnapshot.init` is internal).
    /// `execute` re-derives each item's risk as well, because a plan is a
    /// snapshot and the rule table it was judged by can have changed since.
    public func makeApprovedPlan(
        operation: CleanupOperationName,
        categoryTotals: [CategoryTotal]? = nil
    ) -> ApprovedPlan? {
        guard !ready.isEmpty else { return nil }
        guard ready.allSatisfy({ $0.risk.isCleanable }) else { return nil }
        guard ready.allSatisfy({ identities[$0.id] != nil }) else { return nil }
        let totals = categoryTotals ?? Self.categoryTotals(for: ready)
        return ApprovedPlan(
            operation: operation,
            items: ready,
            identities: identities,
            categoryTotals: totals,
            refusedResults: refusedResults
        )
    }

    private static func categoryTotals(for items: [CleanupItem]) -> [CategoryTotal] {
        var totals: [CleanupCategory: (count: Int, bytes: Int64)] = [:]
        for item in items {
            var entry = totals[item.category] ?? (0, 0)
            entry.count += 1
            entry.bytes += item.sizeInBytes
            totals[item.category] = entry
        }
        return totals
            .map { CategoryTotal(category: $0.key, itemCount: $0.value.count, totalBytes: $0.value.bytes) }
            .sorted { $0.category.displayOrder < $1.category.displayOrder }
    }
}

/// Storage analysis result for the storage page (§5.4).
public struct StorageAnalysis: Sendable {
    public struct Category: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let sizeInBytes: Int64
        public let fileCount: Int

        public init(id: String, title: String, sizeInBytes: Int64, fileCount: Int) {
            self.id = id
            self.title = title
            self.sizeInBytes = sizeInBytes
            self.fileCount = fileCount
        }

        public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
    }

    public struct FileEntry: Identifiable, Hashable, Sendable {
        public let id: String
        public let url: URL
        public let sizeInBytes: Int64
        public let modifiedAt: Date?

        public init(url: URL, sizeInBytes: Int64, modifiedAt: Date?) {
            self.id = url.path
            self.url = url
            self.sizeInBytes = sizeInBytes
            self.modifiedAt = modifiedAt
        }

        public var displayName: String { url.lastPathComponent }
        public var displayPath: String { CleanupItem.abbreviate(url.path) }
        public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
    }

    public struct DirectoryEntry: Identifiable, Hashable, Sendable {
        public let id: String
        public let url: URL
        public let sizeInBytes: Int64
        public let fileCount: Int

        public init(url: URL, sizeInBytes: Int64, fileCount: Int) {
            self.id = url.path
            self.url = url
            self.sizeInBytes = sizeInBytes
            self.fileCount = fileCount
        }

        public var displayName: String { url.lastPathComponent }
        public var displayPath: String { CleanupItem.abbreviate(url.path) }
        public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
    }

    public let mountPoint: String
    public let volumeName: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64
    public let categories: [Category]
    public let topFiles: [FileEntry]
    public let topDirectories: [DirectoryEntry]
    public let scannedFileCount: Int
    public let scannedByteCount: Int64
    public let skippedCount: Int
    public let isAggregated: Bool

    public init(
        mountPoint: String,
        volumeName: String,
        totalBytes: Int64,
        freeBytes: Int64,
        usedBytes: Int64,
        categories: [Category],
        topFiles: [FileEntry],
        topDirectories: [DirectoryEntry],
        scannedFileCount: Int,
        scannedByteCount: Int64,
        skippedCount: Int,
        isAggregated: Bool
    ) {
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.categories = categories
        self.topFiles = topFiles
        self.topDirectories = topDirectories
        self.scannedFileCount = scannedFileCount
        self.scannedByteCount = scannedByteCount
        self.skippedCount = skippedCount
        self.isAggregated = isAggregated
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    public var formattedTotal: String { SiftFormat.bytes(totalBytes) }
    public var formattedFree: String { SiftFormat.bytes(freeBytes) }
    public var formattedUsed: String { SiftFormat.bytes(usedBytes) }
    public var formattedUsage: String { SiftFormat.percent(usedFraction) }

    /// Space inside the analysed roots that Sift could clean.
    public var reclaimableBytes: Int64 {
        categories
            .filter { ["applicationCache", "logs", "installers", "temporaryFiles"].contains($0.id) }
            .reduce(0) { $0 + $1.sizeInBytes }
    }

    public var formattedReclaimable: String { SiftFormat.bytes(reclaimableBytes) }

    public static let empty = StorageAnalysis(
        mountPoint: "/",
        volumeName: "",
        totalBytes: 0,
        freeBytes: 0,
        usedBytes: 0,
        categories: [],
        topFiles: [],
        topDirectories: [],
        scannedFileCount: 0,
        scannedByteCount: 0,
        skippedCount: 0,
        isAggregated: false
    )
}

/// A volume as reported by the system.
public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let mountPoint: URL
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isExternal: Bool
    public let isReadOnly: Bool

    public init(
        name: String,
        mountPoint: URL,
        totalBytes: Int64,
        freeBytes: Int64,
        isExternal: Bool,
        isReadOnly: Bool
    ) {
        self.id = mountPoint.path
        self.name = name
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isExternal = isExternal
        self.isReadOnly = isReadOnly
    }

    public var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    public var formattedTotal: String { SiftFormat.bytes(totalBytes) }
    public var formattedFree: String { SiftFormat.bytes(freeBytes) }
    public var formattedUsage: String { SiftFormat.percent(usedFraction) }
}

/// An installed application, as discovered for the uninstaller (§5.3).
public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public let version: String?
    public let sizeInBytes: Int64
    public let lastUsedAt: Date?
    public let isSystemApplication: Bool
    /// True while the app is running, which changes the uninstall guidance.
    public let isRunning: Bool

    public init(
        url: URL,
        name: String,
        bundleIdentifier: String,
        version: String?,
        sizeInBytes: Int64,
        lastUsedAt: Date?,
        isSystemApplication: Bool,
        isRunning: Bool
    ) {
        self.id = bundleIdentifier.isEmpty ? url.path : bundleIdentifier
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.sizeInBytes = sizeInBytes
        self.lastUsedAt = lastUsedAt
        self.isSystemApplication = isSystemApplication
        self.isRunning = isRunning
    }

    public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }

    public var formattedLastUsed: String {
        guard let lastUsedAt else { return LocalizationKey.commonNotAvailable.localized }
        return SiftFormat.relativeDate(lastUsedAt)
    }
}

/// A file associated with an application (§5.3).
public struct RelatedFile: Identifiable, Hashable, Sendable {
    /// How confident Sift is that this file belongs to the application.
    public enum Confidence: String, Sendable {
        /// Matched the bundle identifier or an exact application name.
        case confirmed
        /// A plausible match that the user must confirm.
        case needsReview
    }

    /// Why Sift believes the file belongs to the application.
    ///
    /// §5.3 asks for the reason a file was claimed, not the claim alone, and it is
    /// what lets a person judge a match for themselves. A reason rather than a
    /// sentence: the sentence is user-visible text, so it lives in the catalog
    /// with the rest, and the matches the uninstaller accepts are a closed set.
    public enum MatchReason: String, Sendable, Hashable, CaseIterable {
        /// `~/Library/Caches/<bundle-id>`
        case bundleIdentifier
        /// `~/Library/Caches/<bundle-id>.suffix`
        case identifierPrefix
        /// `~/Library/Application Support/<application name>`
        case applicationName
        /// The last component of the bundle identifier, as macOS names some files.
        case identifierSuffix
        /// A group container whose group this application declares in its
        /// entitlements. The name belongs to the group, not to the application, so
        /// nothing about the name can establish this.
        case appGroup

        /// The localisation key of the sentence shown with the file.
        public var titleKey: LocalizationKey {
            switch self {
            case .bundleIdentifier: .uninstallReasonBundleIdentifier
            case .identifierPrefix: .uninstallReasonIdentifierPrefix
            case .applicationName: .uninstallReasonApplicationName
            case .identifierSuffix: .uninstallReasonIdentifierSuffix
            case .appGroup: .uninstallReasonAppGroup
            }
        }
    }

    public let id: String
    public let url: URL
    public let sizeInBytes: Int64
    public let confidence: Confidence
    public let reason: MatchReason
    /// Other installed applications that name the same directory.
    ///
    /// Only a group container can have this: `~/Library/Group Containers/<team-id>.<id>`
    /// is shared by an app group, so removing it with one application can take
    /// data another installed application is still using. Two facts fill it, both
    /// read from the system rather than guessed: the applications LaunchServices
    /// answers for the container's name readings, and the applications whose
    /// entitlements declare the container's group. The row states them before the
    /// user decides.
    public let sharedWith: [String]

    /// The app group whose container this file is, when the match came from the
    /// application's own entitlements.
    ///
    /// The container's name *is* the group, so this repeats the row's own name —
    /// which is the point on the rows that cannot show it: a team-prefixed name is
    /// truncated in the middle, and the group id is the string a user can search
    /// for or read back from `codesign -d --entitlements`.
    public let groupIdentifier: String?

    public init(
        url: URL,
        sizeInBytes: Int64,
        confidence: Confidence,
        reason: MatchReason,
        sharedWith: [String] = [],
        groupIdentifier: String? = nil
    ) {
        self.id = url.path
        self.url = url
        self.sizeInBytes = sizeInBytes
        self.confidence = confidence
        self.reason = reason
        self.sharedWith = sharedWith
        self.groupIdentifier = groupIdentifier
    }

    public var displayName: String { url.lastPathComponent }
    public var displayPath: String { CleanupItem.abbreviate(url.path) }
    public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
}

/// Everything the uninstaller shows for one application (§5.3).
public struct UninstallPlan: Identifiable, Sendable {
    public let id: String
    public let application: InstalledApplication
    public let confirmedFiles: [RelatedFile]
    public let reviewFiles: [RelatedFile]

    public init(application: InstalledApplication, confirmedFiles: [RelatedFile], reviewFiles: [RelatedFile]) {
        self.id = application.id
        self.application = application
        self.confirmedFiles = confirmedFiles
        self.reviewFiles = reviewFiles
    }

    public var totalBytes: Int64 {
        totalBytes(includeReviewFiles: false)
    }

    /// The size of what `selectedItems(includeReviewFiles:)` will move.
    ///
    /// The confirmed-only total is what the plan reports by default; the
    /// confirmation panel asks with the user's current choice, because a review
    /// file the user opted into is part of the batch even though the plan's
    /// baseline does not include it.
    public func totalBytes(includeReviewFiles: Bool) -> Int64 {
        application.sizeInBytes + relatedBytes(includeReviewFiles: includeReviewFiles)
    }

    public func relatedBytes(includeReviewFiles: Bool) -> Int64 {
        let confirmed = confirmedFiles.reduce(0) { $0 + $1.sizeInBytes }
        guard includeReviewFiles else { return confirmed }
        return reviewFiles.reduce(confirmed) { $0 + $1.sizeInBytes }
    }

    public var formattedTotal: String { SiftFormat.bytes(totalBytes) }

    public func formattedTotal(includeReviewFiles: Bool) -> String {
        SiftFormat.bytes(totalBytes(includeReviewFiles: includeReviewFiles))
    }

    public var formattedApplicationSize: String { application.formattedSize }

    public var formattedRelatedSize: String {
        SiftFormat.bytes(relatedBytes(includeReviewFiles: false))
    }

    public func formattedRelatedSize(includeReviewFiles: Bool) -> String {
        SiftFormat.bytes(relatedBytes(includeReviewFiles: includeReviewFiles))
    }

    /// The application bundle plus every related file, as cleanup items.
    ///
    /// Only `confirmed` related files are included: files that need review are
    /// listed for the user but never enter the batch on their own, because the
    /// specification forbids fuzzy name matching (§5.3).
    public func selectedItems(includeReviewFiles: Bool) -> [CleanupItem] {
        var items: [CleanupItem] = [
            CleanupItem(
                url: application.url,
                displayName: application.name,
                category: .applicationResidue,
                risk: .review,
                sizeInBytes: application.sizeInBytes,
                fileCount: 1,
                explanationKey: "cleanup.explanation.residue",
                relatedBundleID: application.bundleIdentifier,
                sourceRuleID: "uninstall-application",
                isDirectory: true
            )
        ]
        for file in confirmedFiles {
            items.append(item(for: file))
        }
        if includeReviewFiles {
            for file in reviewFiles {
                items.append(item(for: file))
            }
        }
        return items
    }

    private func item(for file: RelatedFile) -> CleanupItem {
        CleanupItem(
            url: file.url,
            displayName: file.displayName,
            category: .applicationResidue,
            risk: file.confidence == .confirmed ? .review : .review,
            sizeInBytes: file.sizeInBytes,
            fileCount: 1,
            explanationKey: "cleanup.explanation.residue",
            relatedBundleID: application.bundleIdentifier,
            sourceRuleID: "uninstall-related-file"
        )
    }
}

/// One line of the local cleanup report (§5.7).
public struct CleanupReport: Identifiable, Codable, Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public let displayName: String
        public let category: String
        public let sizeInBytes: Int64
        public let status: String
        public let errorCode: String?

        public init(displayName: String, category: String, sizeInBytes: Int64, status: String, errorCode: String?) {
            self.displayName = displayName
            self.category = category
            self.sizeInBytes = sizeInBytes
            self.status = status
            self.errorCode = errorCode
        }

        public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
    }

    public let id: UUID
    public let generatedAt: Date
    public let operation: CleanupOperationName
    public let appVersion: String
    public let macOSVersion: String
    /// Number of locations examined, not their paths: the report is de-identified.
    public let scannedLocationCount: Int
    public let scannedFileCount: Int
    public let categories: [String]
    public let movedCount: Int
    public let movedBytes: Int64
    public let skippedCount: Int
    public let failedCount: Int
    /// Display names only, and only for the first few entries, so the report
    /// never becomes a file listing (§5.7, §13.2).
    public let entries: [Entry]

    public init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        operation: CleanupOperationName,
        appVersion: String,
        macOSVersion: String,
        scannedLocationCount: Int,
        scannedFileCount: Int,
        categories: [String],
        movedCount: Int,
        movedBytes: Int64,
        skippedCount: Int,
        failedCount: Int,
        entries: [Entry]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.operation = operation
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.scannedLocationCount = scannedLocationCount
        self.scannedFileCount = scannedFileCount
        self.categories = categories
        self.movedCount = movedCount
        self.movedBytes = movedBytes
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.entries = entries
    }

    public var formattedMovedBytes: String { SiftFormat.bytes(movedBytes) }
}
