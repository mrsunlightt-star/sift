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
                .applicationResidue, .groupContainerResidue,
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
}
