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
/// it can actually date — and, now that every attribute has two directions, the
/// same rule has to hold at the *other* end of the list too.
final class ApplicationSortOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func application(
        _ name: String,
        identifier: String? = nil,
        size: Int64 = 1_000,
        lastUsed: LastUsedRecord = .unavailable,
        installed: Date? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            name: name,
            bundleIdentifier: identifier ?? "com.vendor.\(name.lowercased())",
            version: "1.0",
            sizeInBytes: size,
            lastUsed: lastUsed,
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

        XCTAssertEqual(
            ApplicationSortOrder.newestInstalled.sorted([old, recent, middle]).map(\.name),
            ["Recent", "Middle", "Old"]
        )
        XCTAssertEqual(
            ApplicationSortOrder.oldestInstalled.sorted([old, recent, middle]).map(\.name),
            ["Old", "Middle", "Recent"]
        )
    }

    func test_anUnknownInstallDateSortsAfterEveryKnownOneInBothDirections() {
        // A volume that records no birth time answers nothing. Treating that as
        // `.distantPast` inside a `>` comparison is how an unknown date ends up
        // ranked as the oldest *or* as the newest, depending on which side of the
        // comparison it lands on; it has to be last either way — which is a
        // different rule from "reverse the comparator".
        let unknown = application("Unknown", installed: nil)
        let oldest = application("Oldest", installed: day(-900))
        let newest = application("Newest", installed: day(-1))

        for order in [ApplicationSortOrder.newestInstalled, .oldestInstalled] {
            for input in [[unknown, oldest, newest], [newest, oldest, unknown], [oldest, unknown, newest]] {
                let ordered = order.sorted(input)
                XCTAssertEqual(ordered.last?.name, "Unknown", "\(order) ranked an unknown date")
            }
        }
    }

    func test_installDateOrderDoesNotReadTheLastUsedDate() {
        // The two dates are independent: an application can have been installed
        // recently and never opened, which is exactly the one worth finding.
        let recentlyInstalled = application(
            "Fresh", lastUsed: .neverOpened, installed: day(-1)
        )
        let openedYesterday = application(
            "Used", lastUsed: .known(day(-1)), installed: day(-300)
        )

        let byInstall = ApplicationSortOrder.newestInstalled.sorted([openedYesterday, recentlyInstalled])
        XCTAssertEqual(byInstall.map(\.name), ["Fresh", "Used"])

        let byUse = ApplicationSortOrder.recentlyUsed.sorted([openedYesterday, recentlyInstalled])
        XCTAssertEqual(byUse.map(\.name), ["Used", "Fresh"])
    }

    func test_theLastUsedOrderHasBothDirections() {
        let today = application("Today", lastUsed: .known(day(-1)))
        let lastMonth = application("Month", lastUsed: .known(day(-40)))
        let unknown = application("Unknown", lastUsed: .unavailable)
        let never = application("Never", lastUsed: .neverOpened)

        let recentFirst = ApplicationSortOrder.recentlyUsed
            .sorted([unknown, lastMonth, never, today])
        XCTAssertEqual(recentFirst.prefix(2).map(\.name), ["Today", "Month"])
        // A bundle with no launch record — read or held — goes last either way.
        XCTAssertEqual(Set(recentFirst.suffix(2).map(\.name)), ["Never", "Unknown"])

        let oldestFirst = ApplicationSortOrder.leastRecentlyUsed
            .sorted([unknown, lastMonth, never, today])
        XCTAssertEqual(oldestFirst.prefix(2), [lastMonth, today])
        XCTAssertEqual(Set(oldestFirst.suffix(2).map(\.name)), ["Never", "Unknown"])
    }

    func test_theSizeAndNameOrdersWorkInBothDirections() {
        let small = application("Alpha", size: 10, lastUsed: .known(day(-5)), installed: day(-5))
        let large = application("Zulu", size: 9_000, lastUsed: .known(day(-1)), installed: day(-1))

        XCTAssertEqual(ApplicationSortOrder.nameAscending.sorted([large, small]).map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(ApplicationSortOrder.nameDescending.sorted([small, large]).map(\.name), ["Zulu", "Alpha"])
        XCTAssertEqual(ApplicationSortOrder.largestFirst.sorted([small, large]).map(\.name), ["Zulu", "Alpha"])
        XCTAssertEqual(ApplicationSortOrder.smallestFirst.sorted([large, small]).map(\.name), ["Alpha", "Zulu"])
    }

    func test_anEqualSizeFallsBackToTheNameSoTheListCannotJitter() {
        // 118 applications, many of a few hundred kilobytes: without a tie-break the
        // rows of equal size come out in whatever order the input had, and the list
        // rearranges itself between renders.
        let first = application("Bravo", size: 500)
        let second = application("Alpha", size: 500)

        XCTAssertEqual(ApplicationSortOrder.largestFirst.sorted([first, second]).map(\.name), ["Alpha", "Bravo"])
        XCTAssertEqual(ApplicationSortOrder.smallestFirst.sorted([first, second]).map(\.name), ["Alpha", "Bravo"])
    }

    func test_everyOrderResolvesToACatalogString() {
        // A missing key renders as its own identifier, which is how a page ends up
        // offering `uninstall.sort.installedAt` in the menu.
        for order in ApplicationSortOrder.allCases {
            XCTAssertNotEqual(
                order.titleKey.localized,
                order.titleKey.rawValue,
                "\(order) has no attribute string in the catalog"
            )
            XCTAssertNotEqual(
                order.directionKey.localized,
                order.directionKey.rawValue,
                "\(order) has no direction string in the catalog"
            )
            XCTAssertTrue(order.title.contains(order.titleKey.localized), "\(order) composes badly")
            XCTAssertTrue(order.title.contains(order.directionKey.localized), "\(order) composes badly")
        }
    }

    func test_eachAttributeOffersExactlyTwoDirections() {
        // The menu is built from `axis`; an attribute with one direction or three
        // would render a group the user cannot read as a pair.
        for axis in ApplicationSortOrder.Axis.allCases {
            let members = ApplicationSortOrder.allCases.filter { $0.axis == axis }
            XCTAssertEqual(members.count, 2, "\(axis) offers \(members.count) orders")
            XCTAssertEqual(Set(members.map(\.directionKey)).count, 2, "\(axis) repeats a direction")
            XCTAssertEqual(Set(members.map(\.titleKey)).count, 1, "\(axis) mixes attributes")
        }
        XCTAssertEqual(
            Set(ApplicationSortOrder.allCases.map(\.title)).count,
            ApplicationSortOrder.allCases.count,
            "two orders read the same, so the menu has a row nobody can tell apart"
        )
    }

    func test_theLaunchRecordDecidesWhetherAnApplicationCountsAsUnused() {
        let known = application("Known", lastUsed: .known(day(-200)), installed: day(-900))
        XCTAssertTrue(known.isUnused(now: now))
        let opened = application("Opened", lastUsed: .known(day(-3)), installed: day(-900))
        XCTAssertFalse(opened.isUnused(now: now))
        // Never opened: judged by the install date, so a fresh install is not
        // reported as six months unused.
        XCTAssertFalse(application("Fresh", lastUsed: .neverOpened, installed: day(-2)).isUnused(now: now))
        XCTAssertTrue(application("Idle", lastUsed: .neverOpened, installed: day(-400)).isUnused(now: now))
        // No record at all is not a claim about use, in either direction.
        XCTAssertFalse(application("Unread", lastUsed: .unavailable, installed: day(-400)).isUnused(now: now))
        // A system application is never advice to uninstall, whatever its record.
        let system = InstalledApplication(
            url: URL(fileURLWithPath: "/System/Applications/Music.app"),
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            version: "1.0",
            sizeInBytes: 4096,
            lastUsed: .known(day(-500)),
            installedAt: day(-2_000),
            isSystemApplication: true,
            isRunning: false
        )
        XCTAssertFalse(system.isUnused(now: now))
    }

    func test_aMissingLaunchRecordIsNotStatedAsNeverOpened() {
        let never = application("Never", lastUsed: .neverOpened)
        let unread = application("Unread", lastUsed: .unavailable)
        XCTAssertEqual(never.formattedLastUsed, LocalizationKey.appsNeverOpened.localized)
        XCTAssertEqual(unread.formattedLastUsed, LocalizationKey.appsLastUsedUnknown.localized)
        XCTAssertNotEqual(never.formattedLastUsed, unread.formattedLastUsed)
    }

    /// Both dates are printed with a year, in one unit.
    ///
    /// The list is read row against row, and it used to print "installed 4 days
    /// ago" on one row and "installed 27 October 2026" on the next: two units in one
    /// column, and the relative one silently dropped the year. The Apps page now
    /// uses the absolute form for both dates, and the relative phrase stays where
    /// recency is the point (a scan that finished a minute ago).
    func test_theTwoDatesArePrintedWithAYearAndNotAsAgoPhrases() {
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: Date())!

        let application = application("Recent", lastUsed: .known(threeDaysAgo), installed: threeDaysAgo)
        XCTAssertEqual(application.formattedInstalledAt, SiftFormat.day(threeDaysAgo))
        XCTAssertEqual(application.formattedLastUsed, SiftFormat.day(threeDaysAgo))
        XCTAssertNotEqual(
            application.formattedInstalledAt,
            SiftFormat.relativeDate(threeDaysAgo),
            "an install date must not be stated as an ago phrase"
        )
        XCTAssertNotEqual(application.formattedInstalledAt, LocalizationKey.commonToday.localized)
        XCTAssertNotEqual(application.formattedLastUsed, LocalizationKey.commonDaysAgo.localized(3))
        XCTAssertTrue(
            application.formattedInstalledAt.contains("\(calendar.component(.year, from: threeDaysAgo))"),
            "the year is the part the relative form left out: \(application.formattedInstalledAt)"
        )
        XCTAssertTrue(
            application.formattedLastUsed.contains("\(calendar.component(.year, from: threeDaysAgo))")
        )
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
