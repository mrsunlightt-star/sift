import Foundation
import XCTest
@testable import Core
import Shared

/// The scan scopes.
///
/// Four pages used to each assemble their own request, so the same button
/// behaved slightly differently depending on where it was pressed and three
/// different flags answered "has a scan run?". The differences are now one
/// value; these tests are what stops them drifting apart again.
final class ScanIntentTests: XCTestCase, @unchecked Sendable {
    func test_everyIntentStatesWhetherItHashesDuplicates() {
        XCTAssertTrue(ScanIntent.everything.includesDuplicates)
        XCTAssertTrue(ScanIntent.files(.duplicates).includesDuplicates)
        XCTAssertFalse(ScanIntent.junk.includesDuplicates)
        XCTAssertFalse(ScanIntent.files(.large).includesDuplicates)
        XCTAssertFalse(ScanIntent.files(.old).includesDuplicates)
    }

    func test_onlyFileCleanupScopesTheLoadedPage() {
        XCTAssertNil(ScanIntent.everything.category)
        XCTAssertNil(ScanIntent.junk.category)
        XCTAssertEqual(ScanIntent.files(.large).category, .largeFiles)
        XCTAssertEqual(ScanIntent.files(.old).category, .oldFiles)
        XCTAssertEqual(ScanIntent.files(.duplicates).category, .duplicateFiles)
    }

    func test_fileCleanupDoesNotPreselectWhatItLoads() {
        // File cleanup presents items for review; the junk page presents a set
        // that is ready to clean (§5.2, §5.5).
        XCTAssertTrue(ScanIntent.everything.preselectsItems)
        XCTAssertTrue(ScanIntent.junk.preselectsItems)
        XCTAssertFalse(ScanIntent.files(.large).preselectsItems)
        XCTAssertFalse(ScanIntent.files(.duplicates).preselectsItems)
    }

    func test_everyFileModeNamesItsOperation() {
        XCTAssertEqual(FileCleanupMode.large.operationName, .largeFiles)
        XCTAssertEqual(FileCleanupMode.old.operationName, .oldFiles)
        XCTAssertEqual(FileCleanupMode.duplicates.operationName, .duplicateFiles)
    }

    func test_junkCleanupOwnsOneDefinedSetOfCategories() {
        // The page and its filter chips read the same list, so the chips can
        // never offer a category the page does not show.
        XCTAssertEqual(
            Set(CleanupCategory.junkCategories),
            [
                .applicationCache, .logs, .installers, .temporaryFiles,
                .applicationResidue, .groupContainerResidue, .developerArtifacts,
            ]
        )
        XCTAssertFalse(CleanupCategory.junkCategories.contains(.largeFiles))
    }

    func test_aPageShowsOnlyItsOwnCategories() {
        let totals = [
            CategoryTotal(category: .logs, itemCount: 1, totalBytes: 10),
            CategoryTotal(category: .largeFiles, itemCount: 1, totalBytes: 20),
            CategoryTotal(category: .duplicateFiles, itemCount: 1, totalBytes: 30),
        ]

        XCTAssertEqual(totals.limited(to: [.logs]).map(\.category), [.logs])
        XCTAssertEqual(totals.limited(to: [.largeFiles, .duplicateFiles]).count, 2)
        XCTAssertEqual(totals.limited(to: nil).count, 3, "nil means no filter")
        XCTAssertTrue(totals.limited(to: []).isEmpty)
    }

    /// The overview's primary button states what the next click does.
    ///
    /// "Start scan" above a finished run is the same defect as "Cleanup finished"
    /// above an item that refused to move: the page names an action that has
    /// already happened, and the user cannot tell whether the results on screen
    /// belong to the scan the button would start.
    func test_theOverviewOffersARerunOnceAResultSetExists() {
        XCTAssertEqual(OverviewScanAction.resolve(hasResults: false, isScanInFlight: false), .start)
        XCTAssertEqual(OverviewScanAction.resolve(hasResults: true, isScanInFlight: false), .rescan)
        XCTAssertEqual(
            OverviewScanAction.resolve(hasResults: true, isScanInFlight: true),
            .viewProgress,
            "a run in flight leaves nothing to start"
        )
        XCTAssertEqual(OverviewScanAction.resolve(hasResults: false, isScanInFlight: true), .viewProgress)

        XCTAssertEqual(OverviewScanAction.start.titleKey, .dashboardStartScan)
        XCTAssertEqual(OverviewScanAction.rescan.titleKey, .scanRescan)
        XCTAssertNotEqual(
            OverviewScanAction.rescan.titleKey,
            OverviewScanAction.start.titleKey,
            "the two states must not share a label"
        )
        XCTAssertTrue(OverviewScanAction.rescan.startsAScan)
        XCTAssertFalse(OverviewScanAction.viewProgress.startsAScan)
    }

    /// One value answers the whole page, so no two regions can disagree.
    ///
    /// The regression this pins: the hero's heading, its sentence, its button and
    /// the header pill each asked `scan.hasResults` separately, and the button
    /// ended up offering a first scan over a finished one. Every label is now a
    /// function of `OverviewState.stage`, and the three stages are exclusive.
    func test_theOverviewResolvesOneStateForEveryLabel() {
        let untouched = OverviewState(hasResults: false, isScanInFlight: false)
        XCTAssertEqual(untouched.stage, .notScanned)
        XCTAssertEqual(untouched.action, .start)
        XCTAssertEqual(untouched.eyebrowKey, .overviewReady)
        XCTAssertEqual(untouched.placeholderKey, .overviewNoResults)
        XCTAssertFalse(untouched.hasResultSet)
        XCTAssertFalse(untouched.isRunning)
        XCTAssertFalse(untouched.offersResultsPage)

        let running = OverviewState(hasResults: false, isScanInFlight: true)
        XCTAssertEqual(running.stage, .scanning)
        XCTAssertEqual(running.action, .viewProgress)
        XCTAssertEqual(running.eyebrowKey, .overviewScanning, "a run in flight is not \"ready to scan\"")
        XCTAssertEqual(running.placeholderKey, .overviewScanningDetail)
        XCTAssertTrue(running.isRunning)
        XCTAssertFalse(running.hasResultSet)

        let finished = OverviewState(hasResults: true, isScanInFlight: false)
        XCTAssertEqual(finished.stage, .scanned)
        XCTAssertEqual(finished.action, .rescan)
        XCTAssertEqual(finished.eyebrowKey, .overviewReclaimableTitle)
        XCTAssertNil(finished.placeholderKey, "a result set has a number, not a sentence")
        XCTAssertTrue(finished.hasResultSet)
        XCTAssertTrue(finished.offersResultsPage)
        XCTAssertFalse(finished.isRunning)

        // The action cannot be derived a second way.
        for hasResults in [true, false] {
            for isScanInFlight in [true, false] {
                let state = OverviewState(hasResults: hasResults, isScanInFlight: isScanInFlight)
                XCTAssertEqual(
                    state.action,
                    OverviewScanAction.resolve(hasResults: hasResults, isScanInFlight: isScanInFlight)
                )
            }
        }
    }
}
