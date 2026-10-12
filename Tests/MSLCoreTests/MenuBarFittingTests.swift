import AppKit
import XCTest
@testable import MSLCore

/// How many of a Linux application's menus the Mac's menu bar can actually
/// show, and what happens to the rest.
final class MenuBarFittingTests: XCTestCase {
    /// A fixed width per title, so these test the rule rather than the font.
    private let fixed: (String) -> CGFloat = { _ in 100 }

    func testEverythingFitsMeansNoOverflowMenu() {
        let titles = ["File", "Edit", "View"]
        let split = MenuBarFitting.split(titles: titles, available: 1000, width: fixed)
        XCTAssertEqual(split.visible, titles)
        XCTAssertTrue(split.overflow.isEmpty, "a ⋯ with nothing behind it is worse than no ⋯")
    }

    /// The case this exists for: GIMP-sized menu counts on a MacBook, where
    /// the bar ends at the notch and macOS silently drops the rest.
    func testTooManyMenusOverflow() {
        let titles = ["File", "Edit", "Select", "View", "Image", "Layer",
                      "Colours", "Tools", "Filters", "Windows", "Help"]
        let split = MenuBarFitting.split(titles: titles, available: 500, width: fixed)
        XCTAssertEqual(split.visible.count, 4, "500 wide, minus the ⋯ menu's own 100")
        XCTAssertEqual(split.visible.first, "File")
        XCTAssertEqual(split.overflow.count, titles.count - 4)
        XCTAssertEqual(split.visible.count + split.overflow.count, titles.count,
                       "no menu may be lost between the two")
    }

    /// Room for the overflow menu itself comes out of the budget - but only
    /// when there is going to be one. Three titles that fit exactly need no
    /// ⋯ and must not be trimmed to make space for one that is not coming.
    func testTheOverflowMenuPaysForItsOwnSpaceOnlyWhenItExists() {
        let exact = MenuBarFitting.split(titles: ["A", "B", "C"], available: 300, width: fixed)
        XCTAssertEqual(exact.visible.count, 3)
        XCTAssertTrue(exact.overflow.isEmpty)

        // One more than fits: now the ⋯ is real and costs its own width, so
        // two titles show rather than three.
        let overflowing = MenuBarFitting.split(titles: ["A", "B", "C", "D"], available: 300, width: fixed)
        XCTAssertEqual(overflowing.visible, ["A", "B"])
        XCTAssertEqual(overflowing.overflow, ["C", "D"])
    }

    /// What is already in the bar - the Apple menu, the app's own menu -
    /// leaves less for the application.
    func testReservedSpaceCountsAgainstTheBudget() {
        let titles = ["File", "Edit", "View", "Help"]
        let roomy = MenuBarFitting.split(titles: titles, available: 1000, width: fixed)
        let crowded = MenuBarFitting.split(titles: titles, available: 1000, reserved: 700, width: fixed)
        XCTAssertEqual(roomy.visible.count, 4)
        XCTAssertLessThan(crowded.visible.count, 4)
    }

    /// Even absurdly narrow, one real menu stays: a bar that is only a ⋯ is
    /// not a menu bar.
    func testOneMenuAlwaysSurvives() {
        let split = MenuBarFitting.split(titles: ["File", "Edit"], available: 10, width: fixed)
        XCTAssertEqual(split.visible, ["File"])
        XCTAssertEqual(split.overflow, ["Edit"])
    }

    func testNoMenusAtAll() {
        let split = MenuBarFitting.split(titles: [], available: 1000, width: fixed)
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertTrue(split.overflow.isEmpty)
    }

    /// Real measurement: a title has to be wider than nothing and narrower
    /// than a screen, and longer titles wider than short ones.
    func testMeasuredTitlesAreSane() {
        let short = MenuBarFitting.width(ofTitle: "File")
        let long = MenuBarFitting.width(ofTitle: "Filters and Effects")
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThan(long, 400)
    }

    /// The budget must never be the whole screen on a notched Mac, and never
    /// zero on any Mac.
    func testAvailableWidthIsAlwaysUsable() {
        let width = MenuBarFitting.availableWidth(for: NSScreen.main)
        XCTAssertGreaterThan(width, 100)
        if let screen = NSScreen.main {
            XCTAssertLessThanOrEqual(width, screen.frame.width)
        }
    }
}

extension MenuBarFittingTests {
    /// The bar used to read "... Settings Window Help Window": Krita, GIMP
    /// and most of KDE export a Window menu, and MSL adds one of its own.
    /// Titles are compared as someone reads them, so GTK's and Qt's
    /// underline markers do not hide the duplicate.
    func testTheAppsWindowMenuIsRecognisedAsOurs() {
        for title in ["Window", "_Window", "&Window", " window "] {
            XCTAssertEqual(X11GlobalMenu.plainTitle(title), "window", title)
        }
        XCTAssertNotEqual(X11GlobalMenu.plainTitle("Windows"), "window")
    }

    /// And the title compared is the one AppKit draws, which for a
    /// top-level item is its submenu's. MSL's Window item is an
    /// `NSMenuItem()` carrying AppKit's placeholder title - reading that
    /// is what let the duplicate through.
    func testTheDrawnTitleComesFromTheSubmenu() {
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "Window")
        XCTAssertEqual(X11GlobalMenu.barTitle(of: item), "Window")
        XCTAssertNotEqual(item.title, "Window", "the item's own title is not what the bar shows")

        let noSubmenu = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        XCTAssertEqual(X11GlobalMenu.barTitle(of: noSubmenu), "File")
    }
}
