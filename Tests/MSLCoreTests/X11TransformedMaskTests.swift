import XCTest
import CoreGraphics
@testable import MSLCore

/// RENDER Composite through a TRANSFORMED mask, checked against pixman:
/// coverage at destination pixel (dx, dy) = mask at
/// `T * (dx - dstX + maskX + 0.5, dy - dstY + maskY + 0.5)`, nearest pixel,
/// nothing outside the mask. The transforms are the ones gtk3-widget-factory
/// really sent for a linked button's mirrored corners (trace, 2026-09-15).
///
/// The mirrored results are compared with a CONTROL composite through the
/// identity transform, mirrored in the test. CoreGraphics reads one texel of
/// this synthetic RGBA mask (the 241 at its far corner) as its neighbour's
/// 221 when the image is used as a clip mask - with or without any
/// transform (measured) - so an absolute per-texel expectation tests
/// CoreGraphics, not this code. Against the control, the only thing left
/// under test is where each texel lands, which is what the fix changed.
final class X11TransformedMaskTests: XCTestCase {
    private let size = 12
    private let dest = CGRect(x: 10, y: 10, width: 12, height: 12)

    /// An asymmetric 12x12 mask: alpha = x * 20 + y + 10, so every texel is
    /// distinguishable.
    private func makeMask() -> CGContext {
        let mask = makeFlippedBitmapContext(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let a = CGFloat(x * 20 + y + 10) / 255
                mask.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [a, a, a, a])!)
                mask.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return mask
    }

    /// Composite solid white through the mask; returns the 12x12 alpha grid
    /// at `dest`, indexed [row][column].
    private func coverage(transform: CGAffineTransform, maskX: Int, maskY: Int) -> [[Int]] {
        let dst = makeFlippedBitmapContext(width: 40, height: 40)
        dst.saveGState()
        clipToTransformedMask(makeMask().makeImage()!, sourceWidth: size, sourceHeight: size, transform: transform,
                              sampleX: maskX, sampleY: maskY, destRect: dest, on: dst)
        dst.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!)
        dst.fill(dest)
        dst.restoreGState()
        let image = dst.makeImage()!
        let data = image.dataProvider!.data! as Data
        return (0..<size).map { j in
            (0..<size).map { i in Int(data[(10 + j) * image.bytesPerRow + (10 + i) * 4 + 3]) }
        }
    }

    func testIdentityControlCoversTheWholeMask() {
        // Sanity for the control itself: every texel lands where it was, and
        // all but CoreGraphics' one known corner read match what was written.
        let control = coverage(transform: .identity, maskX: 0, maskY: 0)
        var mismatches = 0
        for j in 0..<size {
            for i in 0..<size where abs(control[j][i] - (i * 20 + j + 10)) > 1 {
                mismatches += 1
            }
        }
        XCTAssertLessThanOrEqual(mismatches, 1)
    }

    func testMirroredCornerFromTheWidgetFactoryTrace() {
        // setPictureTransform [-1 0 370 / 0 1 -3], maskX=358 maskY=3.
        // pixman: sx = 370 - (i + 358 + 0.5) = 11.5 - i -> column 11-i; sy = j.
        let control = coverage(transform: .identity, maskX: 0, maskY: 0)
        let mirrored = coverage(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 370, ty: -3), maskX: 358, maskY: 3)
        for j in 0..<size {
            for i in 0..<size {
                XCTAssertEqual(mirrored[j][i], control[j][11 - i], "dest pixel \(i),\(j)")
            }
        }
    }

    func testVerticallyAndHorizontallyMirroredCorner() {
        // setPictureTransform [-1 0 370 / 0 -1 26], maskX=358 maskY=14.
        // sy = 26 - (j + 14 + 0.5) = 11.5 - j -> row 11-j.
        let control = coverage(transform: .identity, maskX: 0, maskY: 0)
        let mirrored = coverage(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 370, ty: 26), maskX: 358, maskY: 14)
        for j in 0..<size {
            for i in 0..<size {
                XCTAssertEqual(mirrored[j][i], control[11 - j][11 - i], "dest pixel \(i),\(j)")
            }
        }
    }

    func testAMaskThatMissesDrawsNothingNotASolidSquare() {
        // The old failure: sampling missed the 12x12 mask, no mask was
        // applied, and the fill came out as a full opaque square.
        let missed = coverage(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1000, ty: 0), maskX: 358, maskY: 3)
        XCTAssertEqual(missed.flatMap { $0 }.max(), 0)
    }

    func testCTMIsRestoredForLaterDrawing() {
        let dst = makeFlippedBitmapContext(width: 40, height: 40)
        let before = dst.ctm
        dst.saveGState()
        clipToTransformedMask(makeMask().makeImage()!, sourceWidth: size, sourceHeight: size,
                              transform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 370, ty: 26),
                              sampleX: 358, sampleY: 14, destRect: dest, on: dst)
        let after = dst.ctm
        dst.restoreGState()
        XCTAssertEqual(before.a, after.a, accuracy: 1e-9)
        XCTAssertEqual(before.d, after.d, accuracy: 1e-9)
        XCTAssertEqual(before.tx, after.tx, accuracy: 1e-6)
        XCTAssertEqual(before.ty, after.ty, accuracy: 1e-6)
    }
}
