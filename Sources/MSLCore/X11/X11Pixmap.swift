import CoreGraphics

/// An off-screen `PIXMAP` drawable - X11's other kind of drawable besides
/// a `WINDOW` (see `X11Drawable`'s doc comment). Confirmed live this is
/// NOT optional: this project's own `xterm` build renders its (Xft/
/// freetype, client-side-rasterized) glyphs into a scratch pixmap via
/// `CreatePixmap` + `PutImage`, then `CopyArea`s the result onto its real
/// window - `ImageText8`/core-font text drawing (`X11FakeFont`) is a
/// fallback path some other client might still use, not what this one
/// actually does for its own terminal cells.
///
/// No `NSView`/window-server involvement at all - just a bitmap sitting
/// in memory until something copies from it, matching what a real X
/// server's pixmap is (server-side memory, never itself shown anywhere
/// on its own).
final class X11Pixmap: X11Drawable {
    let bitmapContext: CGContext
    let pixelWidth: Int
    let pixelHeight: Int

    /// `CreatePixmap`'s depth (1, 8, 24 or 32). Storage is always RGBA; this
    /// only decides what `GetImage` hands back - alpha for a depth-32 (ARGB)
    /// pixmap, the zero pad for depth 24. See `X11Connection.zPixmapBytes`.
    let depth: UInt8

    init(width: Int, height: Int, depth: UInt8 = 24) {
        self.depth = depth
        pixelWidth = max(1, width)
        pixelHeight = max(1, height)
        bitmapContext = makeFlippedBitmapContext(width: pixelWidth, height: pixelHeight)
    }

    func notifyChanged() {} // nothing on-screen to redraw until a CopyArea pulls from this
}
