import Foundation
import Shared

/// The three file-cleanup views (§5.5).
///
/// They are filters over one scan, not three different scans: the mode decides
/// which category the page shows and which name the operation reports.
public enum FileCleanupMode: String, Sendable, CaseIterable, Hashable {
    case large
    case old
    case duplicates

    public var titleKey: LocalizationKey {
        switch self {
        case .large: .filesModeLarge
        case .old: .filesModeOld
        case .duplicates: .filesModeDuplicates
        }
    }

    /// The name recorded in the report and the history.
    public var operationName: CleanupOperationName {
        switch self {
        case .large: .largeFiles
        case .old: .oldFiles
        case .duplicates: .duplicateFiles
        }
    }

    /// The categories this mode shows.
    public var categories: [CleanupCategory] {
        switch self {
        case .large: [.largeFiles]
        case .old: [.oldFiles]
        case .duplicates: [.duplicateFiles]
        }
    }
}

/// Why a scan is being started.
///
/// The differences between the pages that start one are real but small, and they
/// used to live as four separate copies — each with its own request flags, its own
/// post-scan steps and its own "has a scan run?" state, which is why the same
/// button behaved slightly differently depending on where it was pressed. They
/// live here as one value, and `AppEnvironment.runScan` is the one function that
/// acts on it.
public enum ScanIntent: Sendable, Hashable {
    /// Everything the scan can find, duplicates included. The overview and the
    /// smart scan.
    case everything
    /// The junk categories (§5.2). Duplicates are skipped because the page never
    /// shows them, and hashing every candidate would only make the scan slower.
    case junk
    /// One file-cleanup view (§5.5).
    case files(FileCleanupMode)

    /// Whether the scan hashes duplicates — the expensive stage, asked for only by
    /// the views that show duplicates.
    public var includesDuplicates: Bool {
        switch self {
        case .everything, .files(.duplicates): true
        case .junk, .files: false
        }
    }

    /// The category the page loads into the cleanup set first.
    public var category: CleanupCategory? {
        if case let .files(mode) = self { return mode.categories.first }
        return nil
    }

    /// Whether that first page is preselected.
    ///
    /// File cleanup presents its items for review rather than as a ready-to-clean
    /// set, which is the one place the selection differs (§5.5).
    public var preselectsItems: Bool {
        if case .files = self { return false }
        return true
    }
}

public extension CleanupCategory {
    /// The categories junk cleanup owns (§5.2): caches, logs, old installers and
    /// temporary files, plus the residue a rule scan can find for applications
    /// that are no longer installed.
    ///
    /// Residue is included because the rule scan finds it and this page is where
    /// the user sees junk; the uninstaller reports residue for one chosen
    /// application, which is a different question.
    static let junkCategories: [CleanupCategory] = [
        .applicationCache, .logs, .installers, .temporaryFiles,
        .applicationResidue, .groupContainerResidue, .developerArtifacts,
    ]
}

/// The primary action the overview offers, and the words it puts on it.
///
/// The page used to say "Start scan" whether or not a result set already
/// existed, so a user who had just scanned was told to start over instead of
/// being offered a re-run — the same way the cleanup result page once said
/// "Cleanup finished" above an item that refused to move. The decision is a value
/// here rather than three branches inside a `ViewBuilder` so a test can pin it:
/// the labels, the symbols and whether the button starts anything all come from
/// one place, and a page cannot drift into saying "start" over an existing run.
public enum OverviewScanAction: String, Sendable, CaseIterable {
    /// Nothing has been scanned yet in this session.
    case start
    /// A result set exists: the action is another run, not a first one.
    case rescan
    /// A run is in flight, so there is nothing to start — the button only takes
    /// the user to the progress it is already making.
    case viewProgress

    public static func resolve(hasResults: Bool, isScanInFlight: Bool) -> OverviewScanAction {
        if isScanInFlight { return .viewProgress }
        return hasResults ? .rescan : .start
    }

    /// Whether pressing it begins a scan.
    public var startsAScan: Bool { self != .viewProgress }

    public var titleKey: LocalizationKey {
        switch self {
        case .start: .dashboardStartScan
        case .rescan: .scanRescan
        case .viewProgress: .overviewViewProgress
        }
    }

    public var symbolName: String {
        switch self {
        case .start: "viewfinder"
        case .rescan: "arrow.clockwise"
        case .viewProgress: "arrow.right"
        }
    }
}
