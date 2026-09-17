import XCTest
import CoreGraphics
@testable import MSLCore

/// RENDER picture transforms, checked against pixman's own sampling rule:
/// destination pixel (dx, dy) samples the source at
/// `T * (dx - dstX + srcX + 0.5, dy - dstY + srcY + 0.5)`, nearest pixel
/// `floor(p - epsilon)`.
final class X11PictureTransformTests: XCTestCase {
    private let sourceSize = 6

    /// Every source pixel a unique colour: r = x*40+10, g = y*40+10.
    private func makeSource() -> CGContext {
        let source = makeFlippedBitmapContext(width: sourceSize, height: sourceSize)
        for y in 0..<sourceSize {
            for x in 0..<sourceSize {
                source.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [CGFloat(x * 40 + 10) / 255, CGFloat(y * 40 + 10) / 255, 0.8, 1])!)
                source.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return source
    }

    /// Source pixel (x, y) each painted destination pixel came from.
    private func sourcePixels(_ context: CGContext) -> [Int: (Int, Int)] {
        let image = context.makeImage()!
        let data = image.dataProvider!.data! as Data
        var out: [Int: (Int, Int)] = [:]
        for y in 0..<image.height {
            for x in 0..<image.width where data[y * image.bytesPerRow + x * 4 + 3] > 0 {
                let r = Int(data[y * image.bytesPerRow + x * 4]), g = Int(data[y * image.bytesPerRow + x * 4 + 1])
                out[y * 1000 + x] = ((r - 10) / 40, (g - 10) / 40)
            }
        }
        return out
    }

    private func pixmanNearest(_ t: CGAffineTransform, srcX: Int, srcY: Int, dest: CGRect) -> [Int: (Int, Int)] {
        var out: [Int: (Int, Int)] = [:]
        for dy in Int(dest.minY)..<Int(dest.maxY) {
            for dx in Int(dest.minX)..<Int(dest.maxX) {
                let p = CGPoint(x: CGFloat(dx) - dest.minX + CGFloat(srcX) + 0.5, y: CGFloat(dy) - dest.minY + CGFloat(srcY) + 0.5).applying(t)
                let ix = Int((p.x - 1.0 / 65536).rounded(.down)), iy = Int((p.y - 1.0 / 65536).rounded(.down))
                if ix >= 0, iy >= 0, ix < sourceSize, iy < sourceSize { out[dy * 1000 + dx] = (ix, iy) }
            }
        }
        return out
    }

    private func assertMatchesPixman(_ t: CGAffineTransform, srcX: Int, srcY: Int, dest: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let source = makeSource()
        let dst = makeFlippedBitmapContext(width: 24, height: 24)
        drawTransformedImage(source.makeImage()!, sourceWidth: sourceSize, sourceHeight: sourceSize, transform: t,
                             sampleX: srcX, sampleY: srcY, destRect: dest, repeatNormal: false, nearest: true, on: dst)
        let got = sourcePixels(dst), want = pixmanNearest(t, srcX: srcX, srcY: srcY, dest: dest)
        XCTAssertFalse(want.isEmpty, "test case samples nothing", file: file, line: line)
        XCTAssertEqual(Set(got.keys), Set(want.keys), "painted area differs", file: file, line: line)
        for (key, value) in want {
            XCTAssertTrue(got[key].map { $0 == value } ?? false, "pixel \(key % 1000),\(key / 1000): got \(String(describing: got[key])) want \(value)", file: file, line: line)
        }
    }

    func testUpscaleMatchesPixman() {
        assertMatchesPixman(CGAffineTransform(scaleX: 0.5, y: 0.5), srcX: 0, srcY: 0, dest: CGRect(x: 3, y: 3, width: 12, height: 12))
    }

    func testDownscaleWithNegativeOffsetMatchesPixman() {
        assertMatchesPixman(CGAffineTransform(scaleX: 5.0 / 6, y: 5.0 / 6), srcX: -2, srcY: 0, dest: CGRect(x: 1, y: 1, width: 9, height: 7))
    }

    func testQuarterTurnMatchesPixman() {
        // sx = y, sy = -x + 6
        assertMatchesPixman(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 6), srcX: 0, srcY: 0, dest: CGRect(x: 2, y: 2, width: 6, height: 6))
    }

    func testMatrixParsing() {
        let one: Int32 = 65536
        XCTAssertNil(renderPictureTransform([one, 0, 0, 0, one, 0, 0, 0, one]), "identity is no transform")
        let scale = renderPictureTransform([2 * one, 0, 3 * one, 0, one / 2, -one, 0, 0, one])
        XCTAssertEqual(scale?.a, 2)
        XCTAssertEqual(scale?.d, 0.5)
        XCTAssertEqual(scale?.tx, 3)
        XCTAssertEqual(scale?.ty, -1)
        // Row-major: m12 (index 1) is the y-to-x term, CGAffineTransform's c.
        XCTAssertEqual(renderPictureTransform([0, one, 0, -one, 0, 6 * one, 0, 0, one])?.c, 1)
        XCTAssertNil(renderPictureTransform([one, 0, 0, 0, one, 0, one / 100, 0, one]), "projective")
        XCTAssertNil(renderPictureTransform([one, one, 0, one, one, 0, 0, 0, one]), "singular")
        XCTAssertNil(renderPictureTransform([one, 0, 0]), "short")
    }
}
