import AppKit
import XCTest
@testable import MSLCore

/// The icon pipeline, from guest bytes to the `.icns` that ends up in a
/// generated `.app`.
final class IconBundleTests: XCTestCase {

    private var svg: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
          <rect width="48" height="48" rx="8" fill="#c0392b"/>
          <circle cx="24" cy="24" r="12" fill="#ffffff"/>
        </svg>
        """.utf8)
    }

    /// A 48pt SVG must still produce the 512 and 1024 slots: those are what
    /// the Dock and Finder actually show on a Retina display, and clamping
    /// to the declared size is what made vector icons look no better than
    /// bitmaps.
    func testSVGFillsEveryICNSSize() throws {
        let image = try XCTUnwrap(NSImage(data: svg))
        XCTAssertTrue(image.isValid)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-test-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertTrue(LinuxAppBundle.writeICNS(image, to: output), "iconutil should succeed")

        let written = try XCTUnwrap(NSImage(contentsOf: output))
        let largest = written.representations.reduce(0) { max($0, $1.pixelsWide) }
        XCTAssertGreaterThanOrEqual(largest, 1024, "vector source should reach the 1024 slot")

        // And the art must actually be drawn, not a blank canvas.
        let rep = try XCTUnwrap(written.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) as? NSBitmapImageRep)
        // `colorAt` returns a device-space colour; component accessors
        // require an RGB colour space first.
        func sample(_ x: Int, _ y: Int) throws -> NSColor {
            try XCTUnwrap(XCTUnwrap(rep.colorAt(x: x, y: y)).usingColorSpace(.sRGB))
        }
        let centre = try sample(rep.pixelsWide / 2, rep.pixelsHigh / 2)
        XCTAssertGreaterThan(centre.redComponent, 0.8, "centre should be the white circle")
        XCTAssertGreaterThan(centre.blueComponent, 0.8, "centre should be the white circle")
        let body = try sample(rep.pixelsWide / 2, rep.pixelsHigh / 6)
        XCTAssertGreaterThan(body.redComponent, body.blueComponent + 0.2, "body should be red")
    }

    /// A small bitmap must NOT be upscaled into the big slots - an upscaled
    /// 48px PNG in a 1024 slot looks worse than simply not offering it.
    func testSmallBitmapIsNotUpscaled() throws {
        let bitmap = NSImage(size: NSSize(width: 48, height: 48))
        bitmap.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 48, height: 48).fill()
        bitmap.unlockFocus()

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-test-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(LinuxAppBundle.writeICNS(bitmap, to: output))

        let written = try XCTUnwrap(NSImage(contentsOf: output))
        let largest = written.representations.reduce(0) { max($0, $1.pixelsWide) }
        XCTAssertLessThanOrEqual(largest, 128, "a 48px source should not be blown up to 1024")
    }
}
