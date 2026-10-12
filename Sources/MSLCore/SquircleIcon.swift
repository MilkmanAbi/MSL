import AppKit

/// Puts a Linux app's icon in a clean macOS squircle.
///
/// Linux icons are free-form - GIMP's Wilber, Krita's swirl, XTerm's two
/// letters - and a macOS app icon is a tile. macOS 26 deals with a free-form
/// icon in a bundle by shrinking it into a grey squircle of its own (the
/// "icon jail"), and does nothing at all for one set at runtime, so a Dock of
/// Linux apps was a mix of jailed logos and bare shapes. MSL can't compile a
/// real Icon Composer icon for each Linux app (that needs Xcode's actool on
/// the user's Mac), so it draws the tile itself, on Apple's icon grid:
///
/// - a **free-form logo** goes, unchanged, onto a light (or dark) gradient
///   tile with the standard drop shadow;
/// - an icon that is **already a tile** (the Calculators) is only fitted to
///   the grid and clipped to the squircle - framing it again would put a tile
///   inside a tile.
public enum SquircleIcon {
    /// Apple's macOS icon grid: a 1024 canvas with an 824-point body.
    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    /// How much of the body a free-form logo may fill.
    static let logoFraction: CGFloat = 0.74

    public static func framed(_ image: NSImage, dark: Bool = false) -> NSImage {
        let analysis = analyse(image)
        let tileLike = analysis.tileLike
        // The logo's visible part, so an icon drawn small in a big
        // transparent canvas (XTerm's) isn't framed as a speck.
        let source = analysis.visible.map { unit in
            CGRect(x: unit.minX * image.size.width, y: unit.minY * image.size.height,
                   width: unit.width * image.size.width, height: unit.height * image.size.height)
        } ?? CGRect(origin: .zero, size: image.size)
        let size = NSSize(width: canvas, height: canvas)
        return NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = squircle(in: body)

            // The tile and its shadow.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                              color: NSColor.black.withAlphaComponent(dark ? 0.5 : 0.28).cgColor)
            context.addPath(shape)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(shape)
            context.clip()
            let colors = dark
                ? [NSColor(white: 0.24, alpha: 1).cgColor, NSColor(white: 0.09, alpha: 1).cgColor]
                : [NSColor(white: 1.0, alpha: 1).cgColor, NSColor(srgbRed: 0.87, green: 0.885, blue: 0.90, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
            }
            if tileLike {
                image.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                let target = fit(source.size, into: body.insetBy(
                    dx: body.width * (1 - logoFraction) / 2, dy: body.height * (1 - logoFraction) / 2))
                image.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
            }
            context.restoreGState()

            // A hairline edge, as on Apple's own tiles.
            context.addPath(shape)
            context.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.08).cgColor)
            context.setLineWidth(2)
            context.strokePath()
            return true
        }
    }

    /// A continuous-corner squircle (superellipse, n = 5), close to the
    /// shape macOS draws, rather than a plain rounded rectangle.
    static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let n: CGFloat = 5
        let steps = 256
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = center.x + a * copysign(pow(abs(c), 2 / n), c)
            let y = center.y + b * copysign(pow(abs(s), 2 / n), s)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    static func fit(_ size: NSSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Whether the icon already is a tile: its opaque area spans nearly the
    /// whole canvas both ways and is mostly solid, rather than a shape with
    /// air around it.
    static func looksLikeTile(_ image: NSImage) -> Bool { analyse(image).tileLike }

    /// `visible` is the opaque bounding box as fractions of the image
    /// (origin bottom-left, as `NSImage.draw(in:from:)` wants it).
    static func analyse(_ image: NSImage) -> (tileLike: Bool, visible: CGRect?) {
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return (false, nil) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return (false, nil) }
        var minX = side, minY = side, maxX = -1, maxY = -1, opaque = 0
        for y in 0..<side {
            for x in 0..<side where data[(y * side + x) * 4 + 3] > 128 {
                opaque += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (false, nil) }
        let w = maxX - minX + 1, h = maxY - minY + 1
        let spansCanvas = Double(w) >= Double(side) * 0.78 && Double(h) >= Double(side) * 0.78
        let solid = Double(opaque) / Double(w * h) >= 0.86
        // Bitmap rows run top-down; the image's y runs bottom-up. One pixel
        // of margin so antialiased edges aren't shaved.
        let s = CGFloat(side)
        let visible = CGRect(x: CGFloat(max(minX - 1, 0)) / s, y: CGFloat(max(side - 1 - maxY - 1, 0)) / s,
                             width: CGFloat(min(w + 2, side)) / s, height: CGFloat(min(h + 2, side)) / s)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return (spansCanvas && solid, visible)
    }
}
