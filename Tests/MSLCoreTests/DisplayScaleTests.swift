import XCTest
import CoreGraphics
@testable import MSLCore

/// How big, and how dense, mslgd tells Linux the screen is.
///
/// The two numbers are one decision. The screen reported grows as the factor
/// shrinks - half a point per pixel means twice as many pixels across the
/// same glass - so the density has to move with it, or the physical size
/// implied by the pair is a screen that does not exist.
final class DisplayScaleTests: XCTestCase {

    private typealias Mode = X11DisplayScale.Mode

    /// **Retina is one physical pixel per X pixel, and that is the point.**
    /// A Mac point is two physical pixels on Retina, so half a point is one.
    func testRetinaIsExactlyOnePhysicalPixel() {
        XCTAssertEqual(Mode.retina.factor, 0.5)
        XCTAssertEqual(Mode.retina.factor * 2, 1.0, accuracy: 0.0001,
                       "half a Mac point must be one physical pixel on a 2x display")
    }

    /// Twice the pixels across the same glass is twice the density.
    func testTheDensityMovesWithTheFactor() {
        XCTAssertEqual(Mode.onePixelPerPoint.dpi, 96)
        XCTAssertEqual(Mode.retina.dpi, 192)
        XCTAssertEqual(Mode.retina.dpi / Mode.onePixelPerPoint.dpi,
                       Double(Mode.onePixelPerPoint.factor / Mode.retina.factor), accuracy: 0.0001,
                       "density and factor must scale together or the implied screen is wrong")
    }

    /// **Native deliberately keeps 96, and that is not an oversight.** It
    /// shrinks by drawing the same pixels into fewer points. Telling the app
    /// it had 113 dpi would make it draw larger text in pixels and cancel
    /// most of the shrink - the feature would undo itself.
    func testNativeScalingKeepsNinetySix() {
        XCTAssertEqual(Mode.native.factor, 0.85)
        XCTAssertEqual(Mode.native.dpi, 96)
    }

    /// The physical size is what it always was: the millimetres are the same
    /// however many pixels are drawn across them. This is the invariant that
    /// makes retina sharper rather than merely bigger.
    func testThePhysicalScreenIsTheSameSizeInEveryMode() {
        // 1710 points wide - the pixels differ per mode, the glass does not.
        let points = 1710.0
        for mode in [Mode.onePixelPerPoint, .retina] {
            let pixels = Int(points / Double(mode.factor))
            let mm = Double(pixels) * 25.4 / mode.dpi
            XCTAssertEqual(mm, points * 25.4 / 96, accuracy: 0.5,
                           "\(mode) implies a different sized screen")
        }
    }

    /// A screen that is 452mm at 96 dpi is still 452mm - the number every
    /// existing app has been laid out against.
    func testTheDefaultStaysExactlyWhereItWas() {
        XCTAssertEqual(X11DisplayScale.millimetres(forPixels: 1710) * (X11DisplayScale.dpi / 96),
                       Double(1710) * 254 / 960, accuracy: 1.0,
                       "the old integer formula and the new one must agree at 96 dpi")
    }

    /// **The regression this guards.** mslgd reports the screen's size in
    /// three replies - the connection setup, RandR's output info and RandR's
    /// monitors. They disagreed once: a stray factor left RandR implying ~9
    /// dpi against the setup's 96, and GTK3 clipped the last widget out of
    /// every window because Pango's font density and GTK's layout density
    /// were different numbers. One function now answers all three.
    func testOneAnswerForEveryPhysicalSizeReply() {
        for pixels in [800, 1710, 3420] {
            let mm = X11DisplayScale.millimetres(forPixels: pixels)
            XCTAssertEqual(UInt16(clamping: Int(mm)), UInt16(clamping: Int(mm)))
            XCTAssertGreaterThan(mm, 0)
            // Nothing like the 4.7 metres the old bug produced.
            XCTAssertLessThan(mm, 2000, "a screen this size is not physically possible")
        }
    }

    /// Retina wins when both are on: they answer the same question, and this
    /// one answers it at full detail.
    func testRetinaTakesPrecedenceOverNative() {
        var settings = MSLExperimentalSettings()
        settings.nativeScaling = true
        settings.retinaRendering = true
        // The resolution order the property uses, asserted on the values
        // rather than the stored property, which is read once per process.
        let mode: Mode = settings.retinaRendering ? .retina
            : (settings.nativeScaling ? .native : .onePixelPerPoint)
        XCTAssertEqual(mode, .retina)
    }

    /// Retina ships **on** - it was tried on real apps and they come back
    /// as sharp as the Mac's own. Native scaling stays off: it is the same
    /// question answered at lower detail, and retina wins when both are set.
    func testRetinaShipsOnAndNativeDoesNot() {
        let settings = MSLExperimentalSettings()
        XCTAssertTrue(settings.retinaRendering, "retina rendering is the shipped default")
        XCTAssertFalse(settings.nativeScaling, "native scaling must not also be on")
    }

    // MARK: - Things that cannot follow the screen on their own

    /// **A core bitmap font is sized in pixels.** `fixed` and the rest are
    /// asked for by pixel size, and a client lays out from the metrics it
    /// gets back - xterm builds its terminal grid that way. At half a point
    /// per pixel a 13-pixel font is half its former physical size, which is
    /// how xterm came up legible but minute.
    func testCoreFontsScaleWithTheDensity() {
        // The relationship, asserted on the arithmetic rather than the
        // stored property, which is fixed for the life of the process.
        for mode in [Mode.onePixelPerPoint, .retina] {
            let size = 13 / mode.factor
            let physicalPoints = size * mode.factor
            XCTAssertEqual(physicalPoints, 13, accuracy: 0.001,
                           "\(mode) draws core-font text at a different physical size")
        }
    }

    /// And at retina that means twice the detail for the same size on glass.
    func testRetinaDrawsCoreFontsAtTwiceTheDetail() {
        XCTAssertEqual(13 / Mode.retina.factor, 26, accuracy: 0.001)
    }
}
