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
    /// What applications that are no longer installed left behind.
    ///
    /// Its own intent rather than a category filter over `.junk`, because the
    /// question is different and so is the cost: the leftovers view answers it by
    /// reading seven known locations one level deep, while a junk scan walks the
    /// home tree and then hashes duplicates. The rows that question produces are
    /// the same `applicationResidue` / `groupContainerResidue` categories a full
    /// scan finds — one strategy, two callers.
    case residue

    /// Whether the scan hashes duplicates — the expensive stage, asked for only by
    /// the views that show duplicates.
    public var includesDuplicates: Bool {
        switch self {
        case .everything, .files(.duplicates): true
        case .junk, .files, .residue: false
        }
    }

    /// Which strategies the engines run for this intent.
    public var scope: ScanScope {
        switch self {
        case .residue: .residue
        case .everything, .junk, .files: .full
        }
    }

    /// The category the page loads into the cleanup set first.
    ///
    /// `nil` for residue: the run produces two categories and the page shows both,
    /// so pinning the first page to one of them would hide half the answer until
    /// something asked for the other.
    public var category: CleanupCategory? {
        if case let .files(mode) = self { return mode.categories.first }
        return nil
    }

    /// Whether that first page is preselected.
    ///
    /// File cleanup presents its items for review rather than as a ready-to-clean
    /// set, which is the one place the selection differs (§5.5). Residue is the
    /// same: every row is `review`, and what a directory contains is a judgement
    /// the user makes, not one the scanner makes for them.
    public var preselectsItems: Bool {
        switch self {
        case .files, .residue: false
        case .everything, .junk: true
        }
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

    /// Delegates to `OverviewState`, which is the one place the two inputs are
    /// turned into a situation. Kept because an action is the thing a caller
    /// usually wants, and because a second mapping here is exactly how the page
    /// came to describe two different runs at once.
    public static func resolve(hasResults: Bool, isScanInFlight: Bool) -> OverviewScanAction {
        OverviewState(hasResults: hasResults, isScanInFlight: isScanInFlight).action
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

/// Everything the overview page states, resolved once.
///
/// The page used to ask "has the scan produced results?" in five places and read
/// the in-flight flag separately, so the header pill, the hero heading, the big
/// number, the sentence under it and the primary button were each their own
/// derivation — and one of them disagreed with the rest. The button said "Start
/// scan" over a 731 MB result set while the pill beside it said "last scan:
/// today".
///
/// One value now answers all of it. `stage` is the whole truth about the page —
/// nothing scanned, a run in flight, or a result set on screen — and every label
/// is a function of it, so a region cannot describe a situation the page is not
/// in. The stages are exclusive because they are: `ScanModel.hasResults` waits
/// for a report, so a run in flight never has a result set behind it.
public struct OverviewState: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        /// Nothing has been scanned in this session, and nothing is running.
        case notScanned
        /// A run is in flight. There is no result set to describe yet.
        case scanning
        /// A result set exists and nothing is running.
        case scanned
    }

    public let stage: Stage

    public init(hasResults: Bool, isScanInFlight: Bool) {
        if isScanInFlight {
            stage = .scanning
        } else {
            stage = hasResults ? .scanned : .notScanned
        }
    }

    /// What the primary button offers, in this stage.
    public var action: OverviewScanAction {
        switch stage {
        case .notScanned: .start
        case .scanning: .viewProgress
        case .scanned: .rescan
        }
    }

    /// Whether a result set is on screen: the totals, the count and the rows.
    public var hasResultSet: Bool { stage == .scanned }

    /// Whether a run is in flight.
    public var isRunning: Bool { stage == .scanning }

    /// The heading above the number. "Ready to scan" over a run in flight was
    /// the same defect as "Start scan" over its results.
    public var eyebrowKey: LocalizationKey {
        switch stage {
        case .notScanned: .overviewReady
        case .scanning: .overviewScanning
        case .scanned: .overviewReclaimableTitle
        }
    }

    /// What the hero says where the total goes, when there is no total to show.
    public var placeholderKey: LocalizationKey? {
        switch stage {
        case .notScanned: .overviewNoResults
        case .scanning: .overviewScanningDetail
        case .scanned: nil
        }
    }

    /// Whether the "view results" control has a page to open.
    public var offersResultsPage: Bool { hasResultSet }
}
