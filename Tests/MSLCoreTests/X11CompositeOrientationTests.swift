import XCTest
import CoreGraphics
@testable import MSLCore

/// RENDER Composite masks and image sources used to be cropped in a
/// vertically flipped space, which mirrored and shifted anything that
/// wasn't a whole, symmetric tile (GIMP's tool-option labels rendered
/// upside down). These pin the X11 semantics directly on the same flipped
/// contexts the server draws into:
///   destination row = destY + (sourceRow - sampleY)
final class X11CompositeOrientationTests: XCTestCase {
    private let white = CGColor(colorSpace: x11DeviceRGB, components: [1, 1, 1, 1])!
    private let red = CGColor(colorSpace: x11DeviceRGB, components: [1, 0, 0, 1])!

    /// Column-0 red value of every row that has any, top-left row numbers.
    private func redRows(_ context: CGContext) -> [Int: Int] {
        let image = context.makeImage()!
        let data = image.dataProvider!.data! as Data
        var rows: [Int: Int] = [:]
        for y in 0..<image.height where data[y * image.bytesPerRow] > 0 {
            rows[y] = Int(data[y * image.bytesPerRow])
        }
        return rows
    }

    private func composeThroughMask(maskHeight: Int, fullRow: Int, halfRow: Int, maskY: Int, height: Int, destY: Int) -> [Int: Int] {
        let mask = makeFlippedBitmapContext(width: 4, height: maskHeight)
        mask.setFillColor(white)
        mask.fill(CGRect(x: 0, y: fullRow, width: 4, height: 1))
        mask.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.5, 0.5, 0.5, 0.5])!)
        mask.fill(CGRect(x: 0, y: halfRow, width: 4, height: 1))

        let dst = makeFlippedBitmapContext(width: 4, height: 40)
        let dstRect = CGRect(x: 0, y: destY, width: 4, height: height)
        guard let rects = imageSampleRects(sourceWidth: 4, sourceHeight: maskHeight, sampleX: 0, sampleY: maskY, destRect: dstRect),
              let crop = mask.makeImage()?.cropping(to: rects.source) else { return [:] }
        dst.saveGState()
        clipToMaskTopLeftOriented(crop, in: rects.destination, on: dst)
        dst.setFillColor(red)
        dst.fill(dstRect)
        dst.restoreGState()
        return redRows(dst)
    }

    func testMaskSubRegionIsNeitherMirroredNorShifted() {
        // Mask rows 20 (full) and 25 (half) sampled from maskY=18 onto y=5.
        XCTAssertEqual(composeThroughMask(maskHeight: 40, fullRow: 20, halfRow: 25, maskY: 18, height: 10, destY: 5), [7: 255, 12: 128])
    }

    func testWholeMaskKeepsItsOrientation() {
        // The old code got this wrong too (full@13, half@8).
        XCTAssertEqual(composeThroughMask(maskHeight: 10, fullRow: 1, halfRow: 6, maskY: 0, height: 10, destY: 5), [6: 255, 11: 128])
    }

    func testClipSurvivesForLaterDrawsWithTheNormalTransform() {
        // Mask covers only its top half; an image drawn afterwards with the
        // usual helper must be clipped there and not flipped twice.
        let mask = makeFlippedBitmapContext(width: 4, height: 10)
        mask.setFillColor(white)
        mask.fill(CGRect(x: 0, y: 0, width: 4, height: 5))
        let source = makeFlippedBitmapContext(width: 4, height: 10)
        source.setFillColor(red)
        source.fill(CGRect(x: 0, y: 0, width: 4, height: 2)) // red top rows only

        let dst = makeFlippedBitmapContext(width: 4, height: 30)
        let dstRect = CGRect(x: 0, y: 5, width: 4, height: 10)
        dst.saveGState()
        clipToMaskTopLeftOriented(mask.makeImage()!, in: dstRect, on: dst)
        drawImageTopLeftOriented(source.makeImage()!, in: dstRect, on: dst)
        dst.restoreGState()
        XCTAssertEqual(redRows(dst), [5: 255, 6: 255])
    }

    func testImageSampleRectsInsideAndOutsideTheSource() {
        let dest = CGRect(x: 0, y: 10, width: 4, height: 17)
        // Whole 17-high tile.
        XCTAssertEqual(imageSampleRects(sourceWidth: 4, sourceHeight: 17, sampleX: 0, sampleY: 0, destRect: dest)?.source,
                       CGRect(x: 0, y: 0, width: 4, height: 17))
        // Negative src-y (GTK corner stamps): the top 4 rows don't exist, so
        // the drawn part starts 4 rows down and is 13 high - never stretched.
        let negative = imageSampleRects(sourceWidth: 4, sourceHeight: 17, sampleX: 0, sampleY: -4, destRect: dest)
        XCTAssertEqual(negative?.source, CGRect(x: 0, y: 0, width: 4, height: 13))
        XCTAssertEqual(negative?.destination, CGRect(x: 0, y: 14, width: 4, height: 13))
        // Hanging off the bottom: rows 6..16 land at the top of dest.
        let offBottom = imageSampleRects(sourceWidth: 4, sourceHeight: 17, sampleX: 0, sampleY: 6, destRect: dest)
        XCTAssertEqual(offBottom?.source, CGRect(x: 0, y: 6, width: 4, height: 11))
        XCTAssertEqual(offBottom?.destination, CGRect(x: 0, y: 10, width: 4, height: 11))
        // No overlap at all.
        XCTAssertNil(imageSampleRects(sourceWidth: 4, sourceHeight: 17, sampleX: 0, sampleY: 40, destRect: dest))
    }

    func testImageSourceRowsLandWhereX11PutsThem() {
        let source = makeFlippedBitmapContext(width: 4, height: 17)
        source.setFillColor(red)
        source.fill(CGRect(x: 0, y: 3, width: 4, height: 1))
        source.setFillColor(CGColor(colorSpace: x11DeviceRGB, components: [0.5, 0, 0, 1])!)
        source.fill(CGRect(x: 0, y: 9, width: 4, height: 1))
        func draw(sampleY: Int, height: Int) -> [Int: Int] {
            let dst = makeFlippedBitmapContext(width: 4, height: 40)
            let dstRect = CGRect(x: 0, y: 10, width: 4, height: height)
            if let rects = imageSampleRects(sourceWidth: 4, sourceHeight: 17, sampleX: 0, sampleY: sampleY, destRect: dstRect),
               let crop = source.makeImage()?.cropping(to: rects.source) {
                drawImageTopLeftOriented(crop, in: rects.destination, on: dst)
            }
            return redRows(dst)
        }
        XCTAssertEqual(draw(sampleY: 0, height: 17), [13: 255, 19: 128])
        XCTAssertEqual(draw(sampleY: 2, height: 10), [11: 255, 17: 128])
        XCTAssertEqual(draw(sampleY: -4, height: 17), [17: 255, 23: 128])
        XCTAssertEqual(draw(sampleY: 6, height: 17), [13: 128])
    }
}
