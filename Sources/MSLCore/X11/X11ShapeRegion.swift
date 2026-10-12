import CoreGraphics

/// SHAPE regions as lists of rectangles, and the arithmetic `ShapeRectangles`
/// needs to combine them. Pure, so it is tested directly.
enum X11ShapeRegion {
    /// SHAPE's operations, from `shapeconst.h`.
    static let set: UInt8 = 0, union: UInt8 = 1, intersect: UInt8 = 2, subtract: UInt8 = 3, invert: UInt8 = 4

    static func combine(current: [CGRect], with rects: [CGRect], op: UInt8) -> [CGRect] {
        let incoming = rects.filter { !$0.isEmpty }
        switch op {
        case union: return current + incoming
        case intersect:
            return current.flatMap { a in incoming.compactMap { b -> CGRect? in
                let i = a.intersection(b)
                return i.isNull || i.isEmpty ? nil : i
            } }
        case subtract:
            return incoming.reduce(current) { remaining, cut in remaining.flatMap { subtract(cut, from: $0) } }
        default: // set, and invert (rare, and set is its closest honest reading)
            return incoming
        }
    }

    /// `rect` minus `cut`, as up to four rectangles (above, below, left,
    /// right of the overlap).
    static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        var pieces: [CGRect] = []
        if overlap.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY))
        }
        if overlap.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
        }
        if overlap.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height))
        }
        if overlap.maxX < rect.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces
    }

    static func contains(_ rects: [CGRect], _ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }

    /// An RGBA mask `width` x `height`: alpha 255 inside any rect, 0
    /// outside, row 0 = the top row - the layout `X11CanvasView.shapeMask`
    /// already takes (and has been measured the right way up).
    static func maskRGBA(_ rects: [CGRect], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for rect in rects {
            let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
            let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                var o = (y * width + x0) * 4
                for _ in x0..<x1 {
                    bytes[o] = 255; bytes[o + 1] = 255; bytes[o + 2] = 255; bytes[o + 3] = 255
                    o += 4
                }
            }
        }
        return bytes
    }
}
