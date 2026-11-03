import Foundation
import XCTest
@testable import Core
import Shared

/// The Apps page's ordering (§5.3).
///
/// The list is what a user acts on, and "install date" is the newest way to
/// answer "what did I install and never use". The ordering lives in
/// `ApplicationSortOrder` rather than in the view precisely so these can be
/// asserted without a window: a date that could not be read must not be treated as
/// the newest one, or the page would put an unknown bundle above every application
/// it can actually date.
final class ApplicationSortOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func application(
        _ name: String,
        identifier: String? = nil,
        size: Int64 = 1_000,
        lastUsed: Date? = nil,
        installed: Date? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            name: name,
            bundleIdentifier: identifier ?? "com.vendor.\(name.lowercased())",
            version: "1.0",
            sizeInBytes: size,
            lastUsedAt: lastUsed,
            installedAt: installed,
            isSystemApplication: false,
            isRunning: false
        )
    }

    private func day(_ offset: Int) -> Date {
        now.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    func test_installDateOrderPutsTheNewestInstallFirst() {
        let old = application("Old", installed: day(-400))
        let recent = application("Recent", installed: day(-2))
        let middle = application("Middle", installed: day(-90))

        let ordered = ApplicationSortOrder.installedAt.sorted([old, recent, middle])

        XCTAssertEqual(ordered.map(\.name), ["Recent", "Middle", "Old"])
    }

    func test_anUnknownInstallDateSortsAfterEveryKnownOne() {
        // A volume that records no birth time answers nothing. Treating that as
        // `.distantPast` inside a `>` comparison is how an unknown date ends up
        // ranked as the oldest *or* as the newest, depending on which side of the
        // comparison it lands on; it has to be last either way.
        let unknown = application("Unknown", installed: nil)
        let oldest = application("Oldest", installed: day(-900))
        let newest = application("Newest", installed: day(-1))

        let ordered = ApplicationSortOrder.installedAt.sorted([unknown, oldest, newest])
        XCTAssertEqual(ordered.map(\.name), ["Newest", "Oldest", "Unknown"])

        let reversed = ApplicationSortOrder.installedAt.sorted([newest, oldest, unknown])
        XCTAssertEqual(reversed.map(\.name), ["Newest", "Oldest", "Unknown"])
    }

    func test_installDateOrderDoesNotReadTheLastUsedDate() {
        // The two dates are independent: an application can have been installed
        // recently and never opened, which is exactly the one worth finding.
        let recentlyInstalled = application("Fresh", lastUsed: nil, installed: day(-1))
        let openedYesterday = application("Used", lastUsed: day(-1), installed: day(-300))

        let byInstall = ApplicationSortOrder.installedAt.sorted([openedYesterday, recentlyInstalled])
        XCTAssertEqual(byInstall.map(\.name), ["Fresh", "Used"])

        let byUse = ApplicationSortOrder.lastUsed.sorted([openedYesterday, recentlyInstalled])
        XCTAssertEqual(byUse.map(\.name), ["Used", "Fresh"])
    }

    func test_theOtherOrdersStillDoWhatTheirTitleSays() {
        let small = application("Alpha", size: 10, lastUsed: day(-5), installed: day(-5))
        let large = application("Zulu", size: 9_000, lastUsed: nil, installed: day(-1))

        XCTAssertEqual(ApplicationSortOrder.name.sorted([large, small]).map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(ApplicationSortOrder.size.sorted([small, large]).map(\.name), ["Zulu", "Alpha"])
        XCTAssertEqual(ApplicationSortOrder.lastUsed.sorted([small, large]).map(\.name), ["Alpha", "Zulu"])
    }

    func test_everyOrderResolvesToACatalogString() {
        // A missing key renders as its own identifier, which is how a page ends up
        // offering `uninstall.sort.installedAt` in the menu.
        for order in ApplicationSortOrder.allCases {
            XCTAssertNotEqual(
                order.titleKey.localized,
                order.titleKey.rawValue,
                "\(order) has no string in the catalog"
            )
        }
    }

    func test_theInstallDateSentenceResolvesAndSubstitutes() {
        XCTAssertNotEqual(
            LocalizationKey.appsInstalledOn.localized("2026-03-04"),
            LocalizationKey.appsInstalledOn.rawValue
        )
        XCTAssertFalse(LocalizationKey.appsInstalledOn.localized("2026-03-04").contains("%@"))
        XCTAssertFalse(LocalizationKey.appsRescan.localized.contains("%@"))
    }
}
