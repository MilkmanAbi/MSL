import XCTest
@testable import MSLCore

/// The connection-setup reply is parsed by every client before it sends a
/// single request, so a miscounted length or a depth listed in one place
/// but not the other fails every app at once. This walks it the way Xlib
/// does.
final class X11ConnectionSetupTests: XCTestCase {
    private func setup(littleEndian: Bool = true) -> [UInt8] {
        X11ConnectionSetup.buildSuccessResponse(.init(
            littleEndian: littleEndian, resourceIdBase: 0x0400_0000, resourceIdMask: 0x001F_FFFF,
            rootWindowID: 0x0400_07FF, colormapID: 0x0400_07FE, visualID: 0x21, argbVisualID: 0x22,
            screenWidthPixels: 1710, screenHeightPixels: 1112))
    }

    func testLengthFieldCoversEveryByte() {
        for littleEndian in [true, false] {
            let bytes = setup(littleEndian: littleEndian)
            let r = X11ByteReader(bytes, littleEndian: littleEndian)
            r.skip(6)
            XCTAssertEqual(8 + Int(r.readU16()) * 4, bytes.count)
        }
    }

    func testEveryAdvertisedDepthHasAPixmapFormat() {
        let bytes = setup()
        let r = X11ByteReader(bytes, littleEndian: true)
        r.skip(8 + 16)
        let vendorLength = Int(r.readU16())
        r.skip(2)
        let screens = Int(r.readU8())
        let formats = Int(r.readU8())
        r.skip(10)
        r.skip(X11Wire.pad(vendorLength))

        var pixmapFormats: [UInt8: UInt8] = [:] // depth -> bits-per-pixel
        for _ in 0..<formats {
            let depth = r.readU8()
            pixmapFormats[depth] = r.readU8()
            XCTAssertEqual(r.readU8(), 32) // scanline-pad
            r.skip(5)
        }
        XCTAssertEqual(pixmapFormats, [1: 1, 24: 32, 32: 32])

        XCTAssertEqual(screens, 1)
        r.skip(39) // SCREEN fields up to number-of-depths
        let depthCount = Int(r.readU8())
        var depths: [UInt8] = []
        for _ in 0..<depthCount {
            let depth = r.readU8()
            r.skip(1)
            let visuals = Int(r.readU16())
            r.skip(4 + visuals * 24)
            depths.append(depth)
            XCTAssertNotNil(pixmapFormats[depth], "depth \(depth) has no pixmap format")
        }
        XCTAssertEqual(Set(depths), [1, 24, 32])
        XCTAssertEqual(r.remaining, 0)
    }

    func testDepthOneBitmapsExpandToCoverage() {
        // 3x2, rows padded to 4 bytes. Row 0 = pixels 0 and 2 set, row 1 = pixel 1.
        let lsb: [UInt8] = [0b101, 0, 0, 0, 0b010, 0, 0, 0]
        XCTAssertEqual(X11Connection.expandBitmap(lsb, width: 3, height: 2, leftPad: 0, lsbFirst: true, rowBytes: 4),
                       [255, 0, 255, 0, 0, 255, 0, 0])
        let msb: [UInt8] = [0b1010_0000, 0, 0, 0, 0b0100_0000, 0, 0, 0]
        XCTAssertEqual(X11Connection.expandBitmap(msb, width: 3, height: 2, leftPad: 0, lsbFirst: false, rowBytes: 4),
                       [255, 0, 255, 0, 0, 255, 0, 0])
        // left-pad skips leading bits of each row.
        XCTAssertEqual(X11Connection.expandBitmap([0b10, 0, 0, 0], width: 1, height: 1, leftPad: 1, lsbFirst: true, rowBytes: 4),
                       [255, 0, 0, 0])
        XCTAssertEqual(X11Connection.expandBitmap([0, 0], width: 1, height: 1, leftPad: 0, lsbFirst: true, rowBytes: 4), [])
    }
}
