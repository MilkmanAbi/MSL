import AppKit

/// Decodes EWMH's `_NET_WM_ICON` into an `NSImage` macOS can use as a Dock
/// tile / minimized-window icon.
///
/// Wire format (EWMH 5.7): a single `CARDINAL[]/32` property holding one or
/// more icons packed back to back, each as `width`, `height`, then
/// `width * height` pixels. Every pixel is `0xAARRGGBB` *in the CARD32's
/// numeric value* - so on the wire it is 4 little-endian bytes, which is
/// why this reads through `X11ByteReader` rather than reinterpreting the
/// byte array directly.
///
/// The alpha is **straight** (not premultiplied); CoreGraphics wants
/// premultiplied for the bitmap layouts it actually accepts, so
/// `decode` multiplies through. Getting that backwards is not a crash, it
/// is a subtle bright halo on every antialiased icon edge - checked here by
/// writing the decoded result out as a PNG whenever `MSL_X11_SNAPSHOT_DIR`
/// is set (`<dir>/icon-<windowID>.png`) and looking at it.
enum X11WindowIcon {
    /// Anything larger than this is downscaled by AppKit anyway (a Dock
    /// tile is 128pt, so 256px on a Retina display) and only costs memory.
    private static let preferredMaxDimension = 256

    /// Returns the best icon in `data`, or `nil` if it holds none usable.
    ///
    /// Every block's declared `width * height` is bounds-checked against
    /// what is actually left in the property before slicing. A client can
    /// set this property to anything at all, including a header claiming
    /// 65535x65535 followed by nothing, and a server that trusted it would
    /// crash on that client's say-so.
    static func decode(_ data: [UInt8], littleEndian: Bool) -> NSImage? {
        let reader = X11ByteReader(data, littleEndian: littleEndian)
        var remainingWords = data.count / 4
        var best: (width: Int, height: Int, pixels: [UInt32])?

        while remainingWords >= 2 {
            let width = Int(reader.readU32())
            let height = Int(reader.readU32())
            remainingWords -= 2
            guard width > 0, height > 0, width <= 16384, height <= 16384 else { break }
            let pixelCount = width * height
            guard pixelCount <= remainingWords else { break } // truncated/bogus - stop, keep whatever came before
            var pixels = [UInt32](repeating: 0, count: pixelCount)
            for index in 0..<pixelCount { pixels[index] = reader.readU32() }
            remainingWords -= pixelCount

            // Prefer the largest icon that is still <= the preferred size;
            // fall back to the smallest oversized one only if every icon is
            // bigger. Picking the FIRST block would land on 16x16 for most
            // real apps, which looks like garbage as a Dock tile.
            if let current = best {
                if betterThan(candidate: (width, height), current: (current.width, current.height)) {
                    best = (width, height, pixels)
                }
            } else {
                best = (width, height, pixels)
            }
        }

        guard let chosen = best else { return nil }
        guard let cgImage = makeImage(width: chosen.width, height: chosen.height, pixels: chosen.pixels) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: chosen.width, height: chosen.height))
    }

    private static func betterThan(candidate: (Int, Int), current: (Int, Int)) -> Bool {
        let candidateSide = max(candidate.0, candidate.1)
        let currentSide = max(current.0, current.1)
        let candidateFits = candidateSide <= preferredMaxDimension
        let currentFits = currentSide <= preferredMaxDimension
        if candidateFits != currentFits { return candidateFits } // a fitting icon always beats an oversized one
        return candidateFits ? candidateSide > currentSide : candidateSide < currentSide
    }

    private static func makeImage(width: Int, height: Int, pixels: [UInt32]) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<pixels.count {
            let value = pixels[index]
            let alpha = UInt32((value >> 24) & 0xFF)
            let red = UInt32((value >> 16) & 0xFF)
            let green = UInt32((value >> 8) & 0xFF)
            let blue = UInt32(value & 0xFF)
            let offset = index * 4
            // Premultiply: EWMH's alpha is straight, and the only 32-bit
            // RGBA layouts `CGImage` reliably accepts are premultiplied.
            rgba[offset] = UInt8(red * alpha / 255)
            rgba[offset + 1] = UInt8(green * alpha / 255)
            rgba[offset + 2] = UInt8(blue * alpha / 255)
            rgba[offset + 3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Debug aid, same opt-in as the window bitmaps: dumps a decoded icon so
    /// the premultiply/byte-order choices above can be checked by eye
    /// rather than reasoned about. Never on a hot path - icons change once
    /// per window, not once per paint.
    static func dumpForDebug(_ image: NSImage, windowID: UInt32) {
        guard let directory = X11Snapshot.directory,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let path = (directory as NSString).appendingPathComponent("icon-\(windowID).png")
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
