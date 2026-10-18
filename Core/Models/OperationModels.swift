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
        summaryOverride: (count: Int, bytes: Int64)? = nil
    ) {
        self.id = id
        self.results = results
        self.categoryTotals = categoryTotals
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.operationName = operationName
        self.summaryOverride = summaryOverride
    }

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

/// The result of pre-flight checking a whole selection.
public struct PreflightReport: Sendable {
    public let ready: [CleanupItem]
    public let skipped: [(item: CleanupItem, code: ErrorCode, message: String)]
    /// Items dropped because a selected directory already contains them.
    public let subsumed: [CleanupItem]
    /// Items the protection list rejects, which must never be acted on.
    public let protected: [CleanupItem]

    public init(
        ready: [CleanupItem],
        skipped: [(item: CleanupItem, code: ErrorCode, message: String)],
        subsumed: [CleanupItem],
        protected: [CleanupItem]
    ) {
        self.ready = ready
        self.skipped = skipped
        self.subsumed = subsumed
        self.protected = protected
    }

    /// Total bytes of the items that will actually be moved.
    public var readyBytes: Int64 { ready.reduce(0) { $0 + $1.sizeInBytes } }

    public var formattedReadyBytes: String { SiftFormat.bytes(readyBytes) }

    public var hasBlockingIssues: Bool { !skipped.isEmpty || !protected.isEmpty }
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

    public let id: String
    public let url: URL
    public let sizeInBytes: Int64
    public let confidence: Confidence
    public let reason: String

    public init(url: URL, sizeInBytes: Int64, confidence: Confidence, reason: String) {
        self.id = url.path
        self.url = url
        self.sizeInBytes = sizeInBytes
        self.confidence = confidence
        self.reason = reason
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
        application.sizeInBytes + confirmedFiles.reduce(0) { $0 + $1.sizeInBytes }
    }

    public var formattedTotal: String { SiftFormat.bytes(totalBytes) }

    public var formattedApplicationSize: String { application.formattedSize }

    public var formattedRelatedSize: String {
        SiftFormat.bytes(confirmedFiles.reduce(0) { $0 + $1.sizeInBytes })
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
            sourceRuleID: "uninstall-related-file",
            note: file.reason
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
