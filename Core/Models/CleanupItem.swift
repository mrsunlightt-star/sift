import Foundation
import Shared

/// A cleanup category (§7.1).
///
/// The raw values are the identifiers the Rust scanner emits, so they cross the
/// FFI boundary without a translation table.
public enum CleanupCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case applicationCache
    case logs
    case installers
    case temporaryFiles
    case largeFiles
    case oldFiles
    case duplicateFiles
    case applicationResidue

    public var id: String { rawValue }

    /// Localisation key for the category name.
    public var titleKey: LocalizationKey {
        switch self {
        case .applicationCache: .cleanupCategoryApplicationCache
        case .logs: .cleanupCategoryLogs
        case .installers: .cleanupCategoryInstallers
        case .temporaryFiles: .cleanupCategoryTemporaryFiles
        case .largeFiles: .cleanupCategoryLargeFiles
        case .oldFiles: .cleanupCategoryOldFiles
        case .duplicateFiles: .cleanupCategoryDuplicateFiles
        case .applicationResidue: .cleanupCategoryApplicationResidue
        }
    }

    /// SF Symbol shown in the category row.
    public var symbolName: String {
        switch self {
        case .applicationCache: "shippingbox"
        case .logs: "doc.text.magnifyingglass"
        case .installers: "arrow.down.doc"
        case .temporaryFiles: "clock.arrow.circlepath"
        case .largeFiles: "doc.zipper"
        case .oldFiles: "calendar.badge.clock"
        case .duplicateFiles: "doc.on.doc"
        case .applicationResidue: "questionmark.folder"
        }
    }

    /// Index into `SiftColor.categoryPalette`, so category colours stay stable.
    public var paletteIndex: Int {
        switch self {
        case .applicationCache: 0
        case .logs: 1
        case .installers: 2
        case .temporaryFiles: 3
        case .applicationResidue: 4
        case .largeFiles: 5
        case .oldFiles: 6
        case .duplicateFiles: 7
        }
    }

    /// Order results are grouped in, matching the Rust index.
    public var displayOrder: Int {
        switch self {
        case .applicationCache: 0
        case .logs: 1
        case .installers: 2
        case .temporaryFiles: 3
        case .applicationResidue: 4
        case .largeFiles: 5
        case .oldFiles: 6
        case .duplicateFiles: 7
        }
    }
}

/// Risk level of a cleanup item (§5.2).
public enum CleanupRisk: String, Codable, Sendable, CaseIterable {
    case safe
    case review
    case protected

    /// Bridges to the design system's colour and symbol carrier.
    public var level: RiskLevel {
        switch self {
        case .safe: .safe
        case .review: .review
        case .protected: .protected
        }
    }

    /// The localisable explanation of what this risk level means.
    public var detailKey: LocalizationKey { level.detailKey }

    /// Only `safe` and `review` items may enter a deletion queue.
    ///
    /// The scanner and the FFI layer both enforce this; the check is repeated
    /// here because the confirmation panel is the last place a `protected` item
    /// could slip through.
    public var isCleanable: Bool { level.isCleanable }

    /// `safe` items are pre-selected; everything else starts unselected.
    public var isSelectedByDefault: Bool { level.isSelectedByDefault }

    /// The caution order the engine uses when two rules match one path: the
    /// higher value wins.
    public var severity: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .protected: 2
        }
    }
}

/// One cleanup item (§7.1).
///
/// `CleanupItem` is the domain model the UI binds to. Paged results arrive as
/// `CleanupItemSummary` values, which are lighter: they omit the fields the
/// scanner fills in only for the detail view.
public struct CleanupItem: Identifiable, Hashable, Sendable {
    /// Stable identity, derived from the cleanup target rather than allocated
    /// per call.
    ///
    /// A random id here was a real defect: views rebuild a `CleanupItem` on every
    /// render, so a selection recorded one id and the next render looked up
    /// another, and a checked row never entered the selection. Two entries for
    /// the same file under different categories are distinct cleanup targets, so
    /// the category is part of the key.
    public let id: String
    public let url: URL
    public let displayName: String
    public let category: CleanupCategory
    public let risk: CleanupRisk
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let explanationKey: LocalizationKey?
    /// Raw explanation key from the scanner, kept so an unknown key degrades to
    /// the category's generic explanation instead of an empty row.
    public let rawExplanationKey: String
    public let relatedBundleID: String?
    public let isRestorable: Bool
    public let sourceRuleID: String
    public let modifiedAt: Date?
    public let isDirectory: Bool
    /// True when the scanner recommends selecting this item.
    public let isSelectedByDefault: Bool
    /// Set when the item overlaps another one, or needs manual confirmation.
    public let note: String?

    public init(
        url: URL,
        displayName: String,
        category: CleanupCategory,
        risk: CleanupRisk,
        sizeInBytes: Int64,
        fileCount: Int,
        explanationKey: String,
        relatedBundleID: String? = nil,
        isRestorable: Bool = true,
        sourceRuleID: String,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false,
        isSelectedByDefault: Bool? = nil,
        note: String? = nil
    ) {
        self.id = Self.stableID(category: category, url: url)
        self.url = url
        self.displayName = displayName
        self.category = category
        self.risk = risk
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.explanationKey = LocalizationKey(rawValue: explanationKey)
        self.rawExplanationKey = explanationKey
        self.relatedBundleID = relatedBundleID
        self.isRestorable = isRestorable
        self.sourceRuleID = sourceRuleID
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isSelectedByDefault = isSelectedByDefault ?? risk.isSelectedByDefault
        self.note = note
    }

    /// The sentence shown under the item name.
    ///
    /// Falls back to the category's generic explanation when the rule's own key
    /// is not in the catalog, so a new rule never produces a blank row.
    public func explanation() -> String {
        if let explanationKey, explanationKey.localized != explanationKey.rawValue {
            return explanationKey.localized
        }
        return Self.genericExplanation(for: category)
    }

    private static func genericExplanation(for category: CleanupCategory) -> String {
        let key: LocalizationKey
        switch category {
        case .applicationCache: key = .cleanupExplanationCache
        case .logs: return LocalizationKey.cleanupExplanationLogs.localized(30)
        case .installers: key = .cleanupExplanationInstallers
        case .temporaryFiles: key = .cleanupExplanationTemporary
        case .largeFiles:
            return LocalizationKey.cleanupExplanationLargeFiles
                .localized(SiftFormat.bytes(1024 * 1024 * 1024))
        case .oldFiles: return LocalizationKey.cleanupExplanationOldFiles.localized(180)
        case .duplicateFiles: key = .cleanupExplanationDuplicates
        case .applicationResidue: key = .cleanupExplanationResidue
        }
        return key.localized
    }

    /// The path as shown to the user: home-relative, so the row is readable and
    /// the user's account name is not repeated on every line.
    public var displayPath: String {
        Self.abbreviate(url.path)
    }

    /// The stable identity of a cleanup target.
    public static func stableID(category: CleanupCategory, url: URL) -> String {
        "\(category.rawValue)|\(url.standardizedFileURL.path)"
    }

    /// Replaces the home directory prefix with `~`.
    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The human-readable size.
    public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
}

/// A lighter result row, as paged out of the scanner index.
public struct CleanupItemSummary: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let url: URL
    public let displayName: String
    public let parentPath: String
    public let category: CleanupCategory
    public let risk: CleanupRisk
    public let sizeInBytes: Int64
    public let fileCount: Int
    public let explanationKey: String
    public let sourceRuleID: String
    public let relatedBundleID: String?
    public let modifiedAt: Date?
    public let isDirectory: Bool

    public init(
        id: Int64,
        url: URL,
        displayName: String,
        parentPath: String,
        category: CleanupCategory,
        risk: CleanupRisk,
        sizeInBytes: Int64,
        fileCount: Int,
        explanationKey: String,
        sourceRuleID: String,
        relatedBundleID: String? = nil,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.parentPath = parentPath
        self.category = category
        self.risk = risk
        self.sizeInBytes = sizeInBytes
        self.fileCount = fileCount
        self.explanationKey = explanationKey
        self.sourceRuleID = sourceRuleID
        self.relatedBundleID = relatedBundleID
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }

    /// Promotes the row to a full domain item.
    public func asCleanupItem() -> CleanupItem {
        CleanupItem(
            url: url,
            displayName: displayName,
            category: category,
            risk: risk,
            sizeInBytes: sizeInBytes,
            fileCount: fileCount,
            explanationKey: explanationKey,
            relatedBundleID: relatedBundleID,
            sourceRuleID: sourceRuleID,
            modifiedAt: modifiedAt,
            isDirectory: isDirectory
        )
    }

    public var displayPath: String { CleanupItem.abbreviate(url.path) }
    public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
}

/// One member of a duplicate group (§7.1).
public struct DuplicateMember: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let sizeInBytes: Int64
    public let modifiedAt: Date?
    /// True for the copy Sift recommends keeping.
    public let isRecommendedToKeep: Bool

    public init(url: URL, sizeInBytes: Int64, modifiedAt: Date?, isRecommendedToKeep: Bool) {
        self.id = url.path
        self.url = url
        self.sizeInBytes = sizeInBytes
        self.modifiedAt = modifiedAt
        self.isRecommendedToKeep = isRecommendedToKeep
    }

    public var displayName: String { url.lastPathComponent }
    public var displayPath: String { CleanupItem.abbreviate(url.path) }
    public var formattedSize: String { SiftFormat.bytes(sizeInBytes) }
}

/// A group of identical files (§7.1).
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let contentHash: String
    public let fileSizeInBytes: Int64
    public let members: [DuplicateMember]
    public let reclaimableSizeInBytes: Int64

    public init(
        id: Int64,
        contentHash: String,
        fileSizeInBytes: Int64,
        members: [DuplicateMember],
        reclaimableSizeInBytes: Int64
    ) {
        self.id = id
        self.contentHash = contentHash
        self.fileSizeInBytes = fileSizeInBytes
        self.members = members
        self.reclaimableSizeInBytes = reclaimableSizeInBytes
    }

    /// Copies the user chose to remove. The keeper is excluded by construction.
    public var removableMembers: [DuplicateMember] {
        members.filter { !$0.isRecommendedToKeep }
    }

    public var formattedSize: String { SiftFormat.bytes(fileSizeInBytes) }
    public var formattedReclaimable: String { SiftFormat.bytes(reclaimableSizeInBytes) }
}

/// A location the scanner could not read (§7.2).
public struct SkippedLocation: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL?
    public let code: String
    public let message: String
    /// True when granting Full Disk Access would fix this.
    public let needsFullDiskAccess: Bool

    public init(url: URL?, code: String, message: String, needsFullDiskAccess: Bool) {
        self.id = "\(code):\(url?.path ?? message)"
        self.url = url
        self.code = code
        self.message = message
        self.needsFullDiskAccess = needsFullDiskAccess
    }

    /// A localised explanation for the code, per the product error table (§14).
    public var reasonKey: LocalizationKey {
        switch code {
        case "permissionDenied": .scanSkippedReasonPermissionDenied
        case "protectedLocation": .scanSkippedReasonProtectedLocation
        case "fileNotFound": .scanSkippedReasonFileNotFound
        case "timedOut": .scanSkippedReasonTimedOut
        default: .scanSkippedReasonPartialFailure
        }
    }

    /// Home-relative path for display; the report uses the same form.
    public var displayPath: String {
        guard let url else { return message }
        return CleanupItem.abbreviate(url.path)
    }

    /// The path's top-level directory, e.g. `~/Library` for
    /// `~/Library/Caches/com.apple.Safari`.
    ///
    /// A location the grouping cannot split (no URL, or a path the labels do
    /// not cover) groups under its own display string.
    public var topLevelDirectoryLabel: String {
        guard let url else { return message }
        let path = displayPath
        if path.hasPrefix("~/") {
            let parts = path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
            return parts.isEmpty ? path : "~/" + parts[0]
        }
        if path.hasPrefix("/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count > 1 ? "/" + parts[0] : path
        }
        return path
    }

    /// Locations rolled up by top-level directory, largest group first.
    ///
    /// A scan that cannot read ~/Library reports two dozen children, and a
    /// flat list buries the shape of the problem: one directory the user could
    /// grant once. The groups answer that shape; the card expands a group for
    /// the location-level detail.
    public static func groupedByTopLevelDirectory(
        _ locations: [SkippedLocation]
    ) -> [SkippedLocationGroup] {
        var byLabel: [String: [SkippedLocation]] = [:]
        for location in locations {
            byLabel[location.topLevelDirectoryLabel, default: []].append(location)
        }
        return byLabel
            .map { SkippedLocationGroup(label: $0.key, locations: $0.value) }
            .sorted {
                $0.locations.count != $1.locations.count
                    ? $0.locations.count > $1.locations.count
                    : $0.label < $1.label
            }
    }
}

/// One top-level directory's worth of skipped locations.
public struct SkippedLocationGroup: Identifiable, Hashable, Sendable {
    /// The directory the group is named after, e.g. `~/Library`.
    public let label: String
    public let locations: [SkippedLocation]

    public var id: String { label }

    /// The reason every member shares, when they share one.
    public var sharedReasonKey: LocalizationKey? {
        let keys = Set(locations.map(\.reasonKey))
        return keys.count == 1 ? keys.first : nil
    }
}

/// Live progress while a scan runs.
public struct ScanProgress: Sendable, Equatable {
    public var phase: ScanPhase
    public var filesSeen: Int
    public var bytesSeen: Int64
    public var itemsFound: Int
    /// Leaf name of the item currently being examined, never a full path.
    public var currentItemName: String

    public init(
        phase: ScanPhase = .idle,
        filesSeen: Int = 0,
        bytesSeen: Int64 = 0,
        itemsFound: Int = 0,
        currentItemName: String = ""
    ) {
        self.phase = phase
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.itemsFound = itemsFound
        self.currentItemName = currentItemName
    }
}

/// One category's totals inside a scan summary.
public struct CategoryTotal: Identifiable, Hashable, Sendable {
    public let category: CleanupCategory
    public let itemCount: Int
    public let totalBytes: Int64

    public var id: String { category.rawValue }

    public init(category: CleanupCategory, itemCount: Int, totalBytes: Int64) {
        self.category = category
        self.itemCount = itemCount
        self.totalBytes = totalBytes
    }

    public var formattedSize: String { SiftFormat.bytes(totalBytes) }
}

public extension Array where Element == CategoryTotal {
    /// The totals a page shows.
    ///
    /// One scan feeds every results page, and each page owns a few categories:
    /// junk cleanup the four junk kinds, file cleanup one of large, old or
    /// duplicate files. Without this a page titled "Large files" listed whatever
    /// the last scan happened to find.
    func limited(to categories: [CleanupCategory]?) -> [CategoryTotal] {
        guard let categories else { return self }
        return filter { categories.contains($0.category) }
    }
}

/// The finished scan (§7.2).
public struct ScanReport: Identifiable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let phase: ScanPhase
    public let scannedFileCount: Int
    public let scannedByteCount: Int64
    /// How many roots the scan was asked to visit, so a report can state its
    /// scope without listing paths.
    public let scannedLocationCount: Int
    public let itemCount: Int
    public let itemBytes: Int64
    public let categoryTotals: [CategoryTotal]
    public let duplicateGroupCount: Int
    public let duplicateReclaimableBytes: Int64
    public let skippedLocations: [SkippedLocation]

    public init(
        id: UUID = UUID(),
        sessionID: String,
        startedAt: Date,
        finishedAt: Date?,
        phase: ScanPhase,
        scannedFileCount: Int,
        scannedByteCount: Int64,
        scannedLocationCount: Int = 0,
        itemCount: Int,
        itemBytes: Int64,
        categoryTotals: [CategoryTotal],
        duplicateGroupCount: Int,
        duplicateReclaimableBytes: Int64,
        skippedLocations: [SkippedLocation]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.phase = phase
        self.scannedFileCount = scannedFileCount
        self.scannedByteCount = scannedByteCount
        self.scannedLocationCount = scannedLocationCount
        self.itemCount = itemCount
        self.itemBytes = itemBytes
        self.categoryTotals = categoryTotals
        self.duplicateGroupCount = duplicateGroupCount
        self.duplicateReclaimableBytes = duplicateReclaimableBytes
        self.skippedLocations = skippedLocations
    }

    /// Total space the scan believes can be released, including duplicates.
    public var estimatedReclaimableBytes: Int64 {
        itemBytes + duplicateReclaimableBytes
    }

    public var formattedReclaimable: String { SiftFormat.bytes(estimatedReclaimableBytes) }

    /// True when at least one location could not be read in full.
    public var isPartial: Bool { phase == .partial }
}

/// A directory the user allowed Sift to scan.
public struct AuthorizedLocation: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Security-scoped bookmark data, persisted so the grant survives relaunch.
    public let bookmark: Data
    public let displayName: String
    /// True for a whole volume the user selected rather than a folder.
    public let isVolume: Bool
    public let addedAt: Date

    public init(id: UUID = UUID(), bookmark: Data, displayName: String, isVolume: Bool, addedAt: Date = Date()) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.isVolume = isVolume
        self.addedAt = addedAt
    }
}
