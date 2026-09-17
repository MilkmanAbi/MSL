import AppKit
import CoreText

/// Shared surface for anything X11 calls a "drawable" - both `WINDOW`s
/// (`X11CanvasView`, on-screen) and `PIXMAP`s (`X11Pixmap`, off-screen -
/// see its doc comment for why these exist as a *second* drawable type at
/// all, not just a simplification this server invented). Most drawing
/// requests (`PolyFillRectangle`, `PutImage`, `CopyArea`, `ImageText8`,
/// ...) accept either kind of ID interchangeably per the protocol, so
/// `X11Connection` resolves "the drawable for this ID" to one shared
/// `X11Drawable` rather than duplicating every handler for windows vs.
/// pixmaps.
protocol X11Drawable: AnyObject {
    var bitmapContext: CGContext { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    /// Hook for "something changed, redraw if you're on-screen" - a real
    /// no-op for `X11Pixmap` (nothing to redisplay until it's later
    /// `CopyArea`'d onto a window), `setNeedsDisplayFromAnyThread` for
    /// `X11CanvasView`.
    func notifyChanged()
}

/// Applies the standard top-left-origin flip (translate by the height,
/// then invert Y) to `context`'s CTM, so every subsequent X11-coordinate
/// (top-left origin, Y down) drawing call - `fill`, `drawText`, an image
/// `draw(in:)` - lands in the visually correct place. Does NOT affect
/// `CGImage.cropping(to:)` - that's raw pixel-buffer addressing (bottom-
/// left origin, unrelated to any CTM ever applied while the image's
/// content was drawn) - see `X11Connection.handleCopyArea`'s explicit
/// Y-flip for that separate case. Shared by both `X11Drawable`
/// conformers' initializers - `NSView.isFlipped` (see `X11CanvasView`)
/// only ever affected AppKit's own graphics context, never a manually
/// created standalone `CGContext` like this one.
func flipContextToTopLeftOrigin(_ context: CGContext, height: Int) {
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
}

/// Draws `image` into `rect` on `context` with the SAME orientation a
/// path-fill (`ctx.fill(rect)`) would have for the identical rect - i.e.
/// `image`'s row 0 (its first row of raw pixel bytes, wherever it came
/// from) lands at `rect`'s X11-top edge, matching the wire protocol's
/// own "row 0 = top" convention for `PutImage` and every RENDER image
/// upload this server parses.
///
/// `CGContext.draw(_:in:)` is NOT simply CTM-driven the way `fill`/
/// `fillPath`/`stroke` are - it has its own extra built-in vertical flip
/// for images specifically (a genuine, documented CoreGraphics quirk,
/// not a bug in this server's own CTM setup). Confirmed live via the
/// Layer-1 harness (`Guest/init/cairo-tests/99_flip_diag.c`, written
/// specifically to isolate this): a `PutImage` upload drawn STRAIGHT
/// onto a window (no `CopyArea` involved at all) came out vertically
/// flipped in total isolation - every previously-"working" `PutImage`
/// test in this whole session happened to ALSO go through exactly one
/// `CopyArea` (itself another `draw(_:in:)` call) before being checked,
/// and two of this same quirk cancel out, which is EXACTLY why the bug
/// went unnoticed for so long: a `PutImage`-filled pixmap round-tripped
/// through `CopyArea` LOOKED correct (2 flips = even = cancels), while a
/// cairo/RENDER-filled one (drawn via `ctx.fill`/`fillPath`/`clip(to:
/// mask:)` - none of which carry this quirk) went through `CopyArea`'s
/// own one flip and came out visibly wrong (1 flip = odd). Every raw-
/// bytes `draw(_:in:)` call site in this file - `PutImage`,
/// `RenderComposite`'s image-src branch, the glyph color-image branch,
/// and `CopyArea`'s own final blit - needs this SAME counter-flip so
/// each is independently, correctly oriented on its own AND stays
/// correct when chained (a `PutImage`-filled pixmap later `CopyArea`'d
/// is then 0+0=0, still correct) - fixing only one call site (tried
/// twice earlier, both reverted) breaks whichever combination used to
/// rely on that site's flip canceling another site's.
func drawImageTopLeftOriented(_ image: CGImage, in rect: CGRect, on context: CGContext) {
    context.saveGState()
    context.translateBy(x: 0, y: rect.origin.y * 2 + rect.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: rect)
    context.restoreGState()
}

/// Clips `context` to `mask` placed at `rect`, in the same top-left
/// orientation `drawImageTopLeftOriented` draws with.
///
/// `clip(to:mask:)` has the same built-in vertical flip as `draw(_:in:)`
/// on these flipped contexts. RENDER `Composite` used to compensate by
/// cropping the mask at `pixelHeight - maskY - height` instead, which is
/// only right when the crop is the whole mask AND the mask is vertically
/// symmetric: any other mask came out shifted and upside-down (measured,
/// 2026-09-15). The transform is undone after clipping - clips live in
/// device space, so the clip stays while whatever draws next (solid fill,
/// gradient, `drawImageTopLeftOriented`) sees the normal CTM.
func clipToMaskTopLeftOriented(_ mask: CGImage, in rect: CGRect, on context: CGContext) {
    let t = rect.origin.y * 2 + rect.height
    context.translateBy(x: 0, y: t)
    context.scaleBy(x: 1, y: -1)
    context.clip(to: rect, mask: mask)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: 0, y: -t)
}

/// The part of a `sourceWidth`x`sourceHeight` drawable that a `destRect`-
/// sized sample starting at (`sampleX`, `sampleY`) actually covers, and
/// where that part lands inside `destRect`. Both rects are top-left
/// origin, the space `makeImage()`/`cropping(to:)` and these contexts
/// share. `nil` when the sample misses the drawable entirely.
///
/// `cropping(to:)` clamps to the image, so an out-of-bounds sample must be
/// clipped in source space and the destination shifted by the same amount,
/// never stretched (`gui-bugs.md` #23, negative `src-y` from GTK's corner
/// stamps). This used to be computed in a vertically FLIPPED source space,
/// which picked the wrong rows for any sample that wasn't the whole tile.
func imageSampleRects(sourceWidth: Int, sourceHeight: Int, sampleX: Int, sampleY: Int, destRect: CGRect) -> (source: CGRect, destination: CGRect)? {
    let wanted = CGRect(x: CGFloat(sampleX), y: CGFloat(sampleY), width: destRect.width, height: destRect.height)
    let available = wanted.intersection(CGRect(x: 0, y: 0, width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)))
    guard !available.isNull, available.width >= 1, available.height >= 1 else { return nil }
    let destination = CGRect(
        x: destRect.minX + (available.minX - wanted.minX), y: destRect.minY + (available.minY - wanted.minY),
        width: available.width, height: available.height
    )
    return (available, destination)
}

/// A RENDER `SetPictureTransform` matrix (9 x FIXED 16.16, row-major:
/// `sx = m11*x + m12*y + m13`, `sy = m21*x + m22*y + m23`) as the
/// destination-to-source `CGAffineTransform`. `nil` for identity, and for
/// what CoreGraphics can't draw: a projective bottom row or a singular
/// matrix. Those keep the untransformed path rather than guessing.
func renderPictureTransform(_ fixed: [Int32]) -> CGAffineTransform? {
    guard fixed.count == 9 else { return nil }
    let m = fixed.map { CGFloat($0) / 65536 }
    guard m[6] == 0, m[7] == 0, m[8] != 0 else { return nil }
    let t = CGAffineTransform(a: m[0] / m[8], b: m[3] / m[8], c: m[1] / m[8], d: m[4] / m[8], tx: m[2] / m[8], ty: m[5] / m[8])
    guard !t.isIdentity, abs(t.a * t.d - t.b * t.c) > 1e-9 else { return nil }
    return t
}

/// Clips `context` to a transformed RENDER mask, sampled the way pixman
/// samples it: coverage at destination pixel `d` is the mask at
/// `T * (d - destRect.origin + sample)`. Outside the mask image there is no
/// coverage (RepeatNone), so a sample that misses draws nothing.
///
/// GTK3 draws the rounded corners of linked buttons (the Page 1|2|3
/// switcher, Left|Middle|Right combos) by uploading ONE 12x12 corner mask
/// and reusing it through mirror transforms (`a=-1, tx=370`, maskX=358).
/// Masks used to ignore the transform, so the sample at (358,3) missed the
/// 12x12 image, no mask was applied at all, and a solid 12x12 square was
/// painted at every mirrored corner.
///
/// The transform is applied, the clip set, and the exact same transform
/// undone - the clip survives in device space, the CTM is left as found.
func clipToTransformedMask(_ mask: CGImage, sourceWidth: Int, sourceHeight: Int, transform: CGAffineTransform,
                           sampleX: Int, sampleY: Int, destRect: CGRect, on context: CGContext) {
    context.clip(to: destRect)
    let applied = transform.inverted()
        .concatenating(CGAffineTransform(translationX: destRect.minX - CGFloat(sampleX), y: destRect.minY - CGFloat(sampleY)))
    context.concatenate(applied)
    // Nearest sampling for the mask itself: with interpolation on, the
    // texel at a mirrored mask's outer edge blended with its neighbour
    // (one pixel of the corner off by a whole texel in the tests).
    let quality = context.interpolationQuality
    context.interpolationQuality = .none
    clipToMaskTopLeftOriented(mask, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight), on: context)
    context.interpolationQuality = quality
    context.concatenate(applied.inverted())
}

/// Draws a transformed RENDER image source the way pixman samples it.
///
/// pixman maps a destination pixel centre `d` (inside `destRect`) to the
/// source point `T * (d - destRect.origin + sample)`, one continuous affine
/// map. So drawing the WHOLE source image under `translate(destRect.origin
/// - sample)` then `T^-1`, clipped to `destRect`, puts every source pixel
/// where pixman would. Verified against a reference sampler: exact for
/// scales, offsets and 90-degree turns, at most one source pixel apart on
/// exact nearest-sampling ties (`X11PictureTransformTests`).
func drawTransformedImage(_ image: CGImage, sourceWidth: Int, sourceHeight: Int, transform: CGAffineTransform,
                          sampleX: Int, sampleY: Int, destRect: CGRect, repeatNormal: Bool, nearest: Bool, on context: CGContext) {
    let w = CGFloat(sourceWidth), h = CGFloat(sourceHeight)
    guard w > 0, h > 0 else { return }
    context.saveGState()
    context.clip(to: destRect)
    context.interpolationQuality = nearest ? .none : .default
    context.translateBy(x: destRect.minX - CGFloat(sampleX), y: destRect.minY - CGFloat(sampleY))
    context.concatenate(transform.inverted())
    if repeatNormal {
        // Tile across the source-space footprint of destRect.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: destRect.width, y: 0),
                       CGPoint(x: 0, y: destRect.height), CGPoint(x: destRect.width, y: destRect.height)]
            .map { CGPoint(x: $0.x + CGFloat(sampleX), y: $0.y + CGFloat(sampleY)).applying(transform) }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let startX = (minX / w).rounded(.down) * w, startY = (minY / h).rounded(.down) * h
        let columns = Int(((maxX - startX) / w).rounded(.up)), rows = Int(((maxY - startY) / h).rounded(.up))
        if columns > 0, rows > 0, columns * rows <= 256 {
            for row in 0..<rows {
                for column in 0..<columns {
                    drawImageTopLeftOriented(image, in: CGRect(x: startX + CGFloat(column) * w, y: startY + CGFloat(row) * h, width: w, height: h), on: context)
                }
            }
        } else {
            drawImageTopLeftOriented(image, in: CGRect(x: 0, y: 0, width: w, height: h), on: context)
        }
    } else {
        drawImageTopLeftOriented(image, in: CGRect(x: 0, y: 0, width: w, height: h), on: context)
    }
    context.restoreGState()
}

/// Every `X11Drawable`'s `bitmapContext` is built against this exact
/// colorspace (see `makeFlippedBitmapContext` below) - every `CGColor`
/// handed to `setFillColor`/`setStrokeColor` on one of those contexts
/// MUST be built against this same instance, not the `CGColor(red:green:
/// blue:alpha:)` convenience initializer. Confirmed live via the Layer-0
/// RENDER harness (`Guest/init/x11-tests/04_render_extension.c`, Part A):
/// that convenience initializer builds its color in an ICC "Generic RGB"
/// profile, not `DeviceRGB` - filling pure blue (0,0,255) through it into
/// a `DeviceRGB` context came out as (4,51,255), a real, client-visible
/// color-accuracy bug (reproduced independently of blend mode - `.normal`
/// and `.copy` were both affected equally), not a snapshot/PNG artifact.
let x11DeviceRGB = CGColorSpaceCreateDeviceRGB()

/// A `CGColor` built in `x11DeviceRGB` - see its doc comment for why this
/// (not `CGColor(red:green:blue:alpha:)`) is the only correct way to turn
/// an `0x00RRGGBB` pixel value into a `CGColor` anywhere in this file.
func x11Color(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: x11DeviceRGB, components: [red, green, blue, alpha])!
}

func makeFlippedBitmapContext(width: Int, height: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: max(1, width), height: max(1, height),
        bitsPerComponent: 8, bytesPerRow: 0, space: x11DeviceRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    flipContextToTopLeftOrigin(context, height: max(1, height))
    return context
}

/// Runs `body` (drawing calls against `context`) with `clipRects`
/// applied, if given - a no-op passthrough when `clipRects` is `nil`.
///
/// Before this helper existed, `SetClipRectangles` (core opcode 59,
/// `X11Connection.handleSetClipRectangles`) was only ever actually
/// APPLIED in `handleCopyArea` - every other drawing request (fills,
/// text, `PutImage`, every RENDER operation) stored the GC's clip via
/// `X11State.GCRecord.clipRectangles` but never consulted it, so a
/// client that clips a GC to a widget's damaged region and then fills/
/// draws-text/composites through it (extremely common - GDK, Qt, and
/// cairo/RENDER all do this routinely for partial-widget redraws) got
/// its content drawn completely unclipped, overflowing into or
/// overdrawing neighboring, already-correct content. This is the
/// generic form of the exact bug `handleCopyArea`'s own doc comment
/// already documents for ITS specific case - the same class of overdraw/
/// ghosting, just for every OTHER request type, confirmed live via real
/// complex apps (Krita, GNOME Chess) showing overlapping/misplaced text
/// and icon content. Every drawing entry point in this file now takes
/// an optional `clip`/`clipRects` parameter threaded from `state.gc(gcId)
/// ?.clipRectangles` and applies it via this same helper, so there's
/// exactly one clip-application code path to get right, not N slightly
/// different ones.
func withClip(_ clipRects: [CGRect]?, on context: CGContext, _ body: () -> Void) {
    guard let clipRects, !clipRects.isEmpty else {
        body()
        return
    }
    context.saveGState()
    context.clip(to: clipRects)
    body()
    context.restoreGState()
}

extension X11Drawable {
    /// Fills the whole canvas (or just `rect`) with a solid
    /// `0x00RRGGBB` color - used for a window's initial `background-
    /// pixel` (`CreateWindow`), `ClearArea`, and `PolyFillRectangle`.
    ///
    /// `clip`, when given, is the calling request's GC's own
    /// `clipRectangles` (set via `SetClipRectangles`, core opcode 59) -
    /// see `withClip(_:on:_:)`'s own doc comment for why this needs to
    /// be threaded through explicitly to every drawing entry point, not
    /// just `CopyArea` (the one place it was originally applied).
    func fillWithColor(_ rgb: UInt32, rect: CGRect? = nil, clip: [CGRect]? = nil) {
        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        withClip(clip, on: bitmapContext) {
            bitmapContext.setFillColor(x11Color(red: red, green: green, blue: blue))
            bitmapContext.fill(rect ?? CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        notifyChanged()
    }

    /// Draws `text` with its baseline at X11's `(x,y)` - top-left origin,
    /// already made correct by `bitmapContext`'s own CTM flip. `background`,
    /// when given, is filled first under the glyphs' advance box: X11's
    /// "Image" text requests (`ImageText8`) always paint an opaque
    /// background before the glyphs; "Poly" text requests (`PolyText8`)
    /// pass `nil` and draw transparently over whatever's already there.
    ///
    /// `CTLineDraw` draws glyphs assuming an UPRIGHT (bottom-left-origin)
    /// text matrix - under `bitmapContext`'s already-flipped CTM they'd
    /// render upside down otherwise, so this locally re-flips just around
    /// the glyph-drawing call, after using the (correct, X11-native)
    /// flipped coordinates to position that local flip's origin.
    func drawText(_ text: String, x: Int16, y: Int16, foreground: UInt32, background: UInt32?, clip: [CGRect]? = nil) {
        guard !text.isEmpty else { return }
        withClip(clip, on: bitmapContext) { drawTextUnclipped(text, x: x, y: y, foreground: foreground, background: background) }
        notifyChanged()
    }

    private func drawTextUnclipped(_ text: String, x: Int16, y: Int16, foreground: UInt32, background: UInt32?) {
        if let background {
            let red = CGFloat((background >> 16) & 0xFF) / 255
            let green = CGFloat((background >> 8) & 0xFF) / 255
            let blue = CGFloat(background & 0xFF) / 255
            let bgRect = CGRect(
                x: CGFloat(x), y: CGFloat(y) - X11FakeFont.ascent,
                width: X11FakeFont.charWidth * CGFloat(text.count),
                height: X11FakeFont.ascent + X11FakeFont.descent
            )
            bitmapContext.setFillColor(x11Color(red: red, green: green, blue: blue))
            bitmapContext.fill(bgRect)
        }
        let fgRed = CGFloat((foreground >> 16) & 0xFF) / 255
        let fgGreen = CGFloat((foreground >> 8) & 0xFF) / 255
        let fgBlue = CGFloat(foreground & 0xFF) / 255
        let color = x11Color(red: fgRed, green: fgGreen, blue: fgBlue)
        let attrs: [NSAttributedString.Key: Any] = [.font: X11FakeFont.ctFont, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))

        bitmapContext.saveGState()
        // Off-screen `CGBitmapContext`s default several of these to
        // `false` (they're normally meant for screen contexts only) -
        // confirmed live that left glyphs looking noticeably rough/
        // jagged compared to any normal on-screen text rendering.
        bitmapContext.setShouldAntialias(true)
        bitmapContext.setAllowsAntialiasing(true)
        bitmapContext.setShouldSmoothFonts(true)
        bitmapContext.setAllowsFontSmoothing(true)
        bitmapContext.setShouldSubpixelPositionFonts(true)
        bitmapContext.setAllowsFontSubpixelPositioning(true)
        bitmapContext.textMatrix = .identity
        bitmapContext.translateBy(x: CGFloat(x), y: CGFloat(y))
        bitmapContext.scaleBy(x: 1, y: -1)
        CTLineDraw(line, bitmapContext)
        bitmapContext.restoreGState()
    }
}
