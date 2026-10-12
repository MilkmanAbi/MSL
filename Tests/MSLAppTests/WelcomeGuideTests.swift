import SwiftUI
import XCTest
@testable import MSLApp
@testable import MSLCore

/// The welcome guide, drawn offscreen.
///
/// Same reasoning as `CardRenderingTests`: this is the first thing a new
/// Mac ever sees, and `swift build` succeeding says it compiles, not that a
/// page lays out or that the photo is actually found. `ImageRenderer` draws
/// them for real.
///
/// `MSL_CARD_SNAPSHOT_DIR=/some/path swift test` writes each page out as a
/// PNG, which is how a person (or a model) looks at them without launching
/// the app.
@MainActor
final class WelcomeGuideTests: XCTestCase {

    private func save(_ image: NSImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MSL_CARD_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: directory),
                                                 withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: - The pages themselves

    func testEveryPageIsWorthShowing() {
        XCTAssertEqual(WelcomeGuide.pages.count, 6)
        var seen = Set<String>()
        for page in WelcomeGuide.pages {
            XCTAssertTrue(seen.insert(page.id).inserted, "duplicate page id \(page.id)")
            XCTAssertFalse(page.title.isEmpty, "\(page.id) has no title")
            XCTAssertFalse(page.subtitle.isEmpty, "\(page.id) has no subtitle")
            // A page with one bullet is a paragraph with decoration.
            XCTAssertGreaterThanOrEqual(page.points.count, 2, "\(page.id) has too little on it")
            for point in page.points {
                XCTAssertFalse(point.title.isEmpty, "\(page.id) has an unnamed point")
                XCTAssertFalse(point.detail.isEmpty, "\(page.id)/\(point.title) says nothing")
            }
        }
    }

    func testTitlesFitTheBanner() {
        // The banner is one line at 26pt in a 660pt sheet. A title that
        // wraps there pushes itself off the bottom of the photo.
        for page in WelcomeGuide.pages {
            XCTAssertLessThanOrEqual(page.title.count, 34, "\(page.id): \"\(page.title)\" is too long for the banner")
        }
    }

    func testTheMarkdownInTheCopyActuallyParses() {
        // The lead and the details are rendered as markdown so `msl` comes
        // out monospaced. A stray backtick would silently drop the rest of
        // a sentence rather than showing it.
        for page in WelcomeGuide.pages {
            XCTAssertNoThrow(try AttributedString(markdown: page.lead), "\(page.id) lead")
            for point in page.points {
                XCTAssertNoThrow(try AttributedString(markdown: point.detail),
                                 "\(page.id)/\(point.title)")
            }
            // Backticks must be balanced, or markdown quietly renders the
            // rest of the string as plain text and the code voice is lost.
            XCTAssertEqual(page.lead.filter { $0 == "`" }.count % 2, 0, "\(page.id) lead has an odd backtick")
        }
    }

    func testEveryLinkedArticleExists() {
        // A welcome page offering an article that is not in the guide is a
        // dead end on the first screen somebody ever sees.
        let known = Set(HelpGuide.chapters.flatMap(\.articles).map(\.id))
        for page in WelcomeGuide.pages {
            guard let article = page.article else { continue }
            XCTAssertTrue(known.contains(article.id),
                          "\(page.id) links to \"\(article.id)\", which is not an article")
        }
    }

    func testTheGuideEndsByOfferingPermissions() {
        // The whole point of the last page: macOS has to be told to let MSL
        // work, and a first-time user has no reason to go hunting in a
        // sidebar for that. A guide that explains everything and then drops
        // you at a window with nothing to do is the failure here.
        let last = WelcomeGuide.pages.last
        XCTAssertEqual(last?.action, .openPermissions,
                       "the last page should hand off to Permissions & Startup")
        XCTAssertEqual(last?.action?.label, "Open Permissions & Startup")
    }

    func testNoOtherPageGrabsAtTheUser() {
        // One action, on the page that earns it. A button on every page
        // turns a guide into a series of demands.
        let withActions = WelcomeGuide.pages.filter { $0.action != nil }
        XCTAssertEqual(withActions.count, 1, "only the last page should have an action button")
    }

    // MARK: - The photo

    func testTheBannerPhotoIsBundled() {
        // MSLAsset returns nil rather than trapping when a resource is
        // missing, so without this the welcome would just quietly show a
        // flat gradient and nobody would notice until a user did.
        let url = MSLAsset.url("Welcome_Banner", extension: "jpg")
        XCTAssertNotNil(url, "Welcome_Banner.jpg is not reachable through MSLAsset")
        guard let url, let image = NSImage(contentsOf: url) else { return }
        XCTAssertGreaterThan(image.size.width, 600, "the banner photo is too small to fill a 660pt sheet at 2x")
        // Shipped uncropped, so it is still the 4:3 frame it was taken in.
        XCTAssertEqual(image.size.width / image.size.height, 4.0 / 3.0, accuracy: 0.02,
                       "the banner photo has been cropped away from its original frame")
    }

    // MARK: - Rendering

    func testEveryPageRenders() {
        for (index, page) in WelcomeGuide.pages.enumerated() {
            let view = WelcomeView(done: {}, startingAt: index)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                XCTFail("page \(page.id) rendered nothing at all")
                continue
            }
            save(image, "welcome-\(index + 1)-\(page.id)")
            // The view declares a fixed 660x620 frame; anything much under
            // that means a section collapsed rather than laid out.
            XCTAssertEqual(image.size.width, 660, accuracy: 2, "\(page.id) is the wrong width")
            XCTAssertEqual(image.size.height, 620, accuracy: 2, "\(page.id) is the wrong height")
        }
    }

    func testThePageIsNotMostlyEmpty() {
        // A guard against the failure this whole file exists for: a view
        // that "renders" as a correctly-sized rectangle of nothing. The
        // banner photo alone should put plenty of non-background pixels on
        // the top third.
        let renderer = ImageRenderer(content: WelcomeView(done: {}, startingAt: 0))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("the first page did not render")
        }
        var distinct = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let key = UInt32(colour.redComponent * 31) << 10
                    | UInt32(colour.greenComponent * 31) << 5
                    | UInt32(colour.blueComponent * 31)
                distinct.insert(key)
            }
        }
        XCTAssertGreaterThan(distinct.count, 60,
                             "the page has only \(distinct.count) distinct colours - it probably drew nothing")
    }

    // MARK: - Showing it once

    func testItShowsOnceAndThenNeverOnItsOwn() {
        // An in-memory store, not a `UserDefaults` suite. A suite leaves a
        // plist in ~/Library/Preferences that nothing in this process can
        // reliably remove - `cfprefsd` writes the domain out after the test
        // has exited, so `removeSuite`, `removePersistentDomain` and
        // deleting the file by hand all lose the race. Six such files had
        // accumulated from earlier runs of this test.
        let store = UserDefaults(suiteName: nil)!
        let original = WelcomeGuide.store
        WelcomeGuide.store = store
        defer {
            WelcomeGuide.store = original
            store.removeObject(forKey: WelcomeGuide.seenKey)
        }

        store.removeObject(forKey: WelcomeGuide.seenKey)
        XCTAssertFalse(WelcomeGuide.hasBeenSeen, "a Mac that has never run MSL has not seen it")
        WelcomeGuide.hasBeenSeen = true
        XCTAssertTrue(WelcomeGuide.hasBeenSeen, "and it stays seen")
        XCTAssertEqual(store.bool(forKey: "msl.welcome.seen"), true,
                       "written under the key the uninstaller has to clear")
    }

}
