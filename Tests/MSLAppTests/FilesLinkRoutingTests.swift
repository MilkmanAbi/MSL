import XCTest
@testable import MSLApp

/// Which window an `msl-files://` link lands in.
///
/// MSL Files is three things, and they must not fight over one window:
/// a file browser opened from the Dock, "show me this instance's files"
/// opened from MSL, and the Open/Save dialog a Linux app asks for. The third
/// has its own window already; the first two used to share whichever window
/// answered a broadcast first.
@MainActor
final class FilesLinkRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = MSLFilesLink.take(firstAppearance: true)   // start empty
    }

    private func link(_ instance: String) -> URL {
        URL(string: "msl-files://files?instance=\(instance)&path=/home/u")!
    }

    /// **The bug.** Opening an instance's files while MSL Files is already
    /// open took over the window in use - and which window that was depended
    /// on the order listeners happened to fire in.
    func testAWindowAlreadyOnScreenDoesNotTakeALinkMeantForANewOne() {
        MSLFilesLink.deliver(link("work"))
        XCTAssertNil(MSLFilesLink.take(firstAppearance: false),
                     "a window already on screen must leave this link alone")
        XCTAssertEqual(MSLFilesLink.take(firstAppearance: true), link("work"),
                       "the new window gets it")
    }

    /// Taking it consumes it, so a second window never re-navigates to a
    /// folder the first one already opened.
    func testALinkIsTakenOnlyOnce() {
        MSLFilesLink.deliver(link("work"))
        XCTAssertNotNil(MSLFilesLink.take(firstAppearance: true))
        XCTAssertNil(MSLFilesLink.take(firstAppearance: true))
    }

    /// The safety net: when `reopen()` revives the window prewarming hid
    /// rather than making a new one, that window has already appeared and
    /// will not appear again, so the link has to be released to it or "show
    /// this folder" does nothing at all.
    func testAReleasedLinkCanBeTakenByAWindowAlreadyOnScreen() {
        MSLFilesLink.deliver(link("work"))
        MSLFilesLink.releaseToAnyWindow()
        XCTAssertEqual(MSLFilesLink.take(firstAppearance: false), link("work"))
    }

    func testReleasingNothingIsHarmless() {
        MSLFilesLink.releaseToAnyWindow()
        XCTAssertNil(MSLFilesLink.take(firstAppearance: true))
    }

    /// A link that explicitly does not want its own window - nothing sends
    /// one today, but the distinction is what the routing turns on.
    func testALinkNotWantingItsOwnWindowGoesToWhateverIsThere() {
        MSLFilesLink.deliver(link("work"), toNewWindow: false)
        XCTAssertEqual(MSLFilesLink.take(firstAppearance: false), link("work"))
    }

    /// A pick is the third mode and must never be routed as a browser link:
    /// a Linux app is blocked waiting for the answer.
    func testPickTokensAreRecognisedAndNotBrowserLinks() {
        let pick = URL(string: "msl-files://pick?token=abc123")!
        XCTAssertEqual(MSLFilesLink.pickToken(in: pick), "abc123")
        XCTAssertNil(MSLFilesLink.pickToken(in: link("work")))
        XCTAssertNil(MSLFilesLink.pickToken(in: URL(string: "msl-files://pick?token=")!),
                     "an empty token is not a pick")
    }
}
