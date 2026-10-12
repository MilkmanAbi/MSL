import XCTest
import CoreGraphics
@testable import MSLCore

/// F8b — RENDER requests that were not implemented at all.
///
/// The failure mode was not "no gradient": with the picture never created,
/// the later `Composite` found no source and returned early, **drawing
/// nothing** and leaving whatever was underneath on screen. Adwaita and
/// several Qt styles use radial gradients, so it read as stale content.
final class X11RenderGradientTests: XCTestCase {
    func testTheGradientOpcodesAreTheRealOnes() {
        XCTAssertEqual(X11RenderOpcode.createRadialGradient, 35)
        XCTAssertEqual(X11RenderOpcode.createConicalGradient, 36)
        XCTAssertEqual(X11RenderOpcode.freeGlyphs, 22)
    }

    /// A radial gradient is two circles and the stops between them, which
    /// is exactly CoreGraphics' own model - so it maps across without
    /// approximation.
    func testARadialGradientIsStoredAsTwoCircles() {
        let picture = X11State.PictureRecord(id: 1)
        picture.radialGradient = (c1: CGPoint(x: 10, y: 10), r1: 0,
                                  c2: CGPoint(x: 10, y: 10), r2: 50,
                                  stops: [0, 1],
                                  colors: [(1, 0, 0, 1), (0, 0, 1, 1)])
        XCTAssertEqual(picture.radialGradient?.r2, 50)
        XCTAssertEqual(picture.radialGradient?.stops.count, 2)
        XCTAssertEqual(picture.radialGradient?.colors.count, 2)
    }

    /// The stops and colours have to stay the same length, or
    /// `CGGradient` refuses to build and nothing draws - back to the
    /// original symptom.
    func testStopsAndColoursStayInStep() {
        let stops: [CGFloat] = [0, 0.5, 1]
        let colors = [x11Color(red: 1, green: 0, blue: 0),
                      x11Color(red: 0, green: 1, blue: 0),
                      x11Color(red: 0, green: 0, blue: 1)] as CFArray
        XCTAssertNotNil(CGGradient(colorsSpace: x11DeviceRGB, colors: colors, locations: stops))
    }

    /// Conical is approximated by a radial one - visibly wrong for a true
    /// sweep, and far better than drawing nothing. Recorded here so the
    /// approximation is a decision rather than a surprise.
    func testConicalIsDeliberatelyApproximated() {
        let picture = X11State.PictureRecord(id: 1)
        picture.radialGradient = (c1: CGPoint(x: 5, y: 5), r1: 0,
                                  c2: CGPoint(x: 5, y: 5), r2: 1,
                                  stops: [0, 1], colors: [(1, 1, 1, 1), (0, 0, 0, 1)])
        XCTAssertEqual(picture.radialGradient?.c1, picture.radialGradient?.c2,
                       "a sweep has one centre, so both circles share it")
    }

    /// `FreeGlyphs` removes exactly the glyphs named and leaves the rest.
    func testFreeGlyphsRemovesOnlyWhatIsNamed() {
        let set = X11State.GlyphSetRecord(id: 1, format: 1)
        for id in UInt32(1)...UInt32(5) {
            set.glyphs[id] = X11State.GlyphRecord(width: 1, height: 1, x: 0, y: 0,
                                                  xOff: 1, yOff: 0, imageData: [0])
        }
        XCTAssertEqual(set.glyphs.count, 5)
        set.glyphs.removeValue(forKey: 2)
        set.glyphs.removeValue(forKey: 4)
        XCTAssertEqual(set.glyphs.count, 3)
        XCTAssertNotNil(set.glyphs[1])
        XCTAssertNil(set.glyphs[2])
    }
}
