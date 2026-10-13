import CoreText
import Foundation

/// The one real font this server ever draws with, regardless of what name
/// a client asked `OpenFont` for (see `X11Connection`'s "Font requests"
/// doc comment - there's no real X core-font glyph data anywhere here).
/// Metrics are measured from the actual `CTFont` at load time, not
/// hand-picked numbers, specifically so `X11Connection.handleQueryFont`'s
/// reply (what a client like `xterm` uses to size its terminal grid) and
/// `X11CanvasView.drawText`'s actual glyph advances agree - a client that
/// trusted a *different*, made-up set of metrics than what really gets
/// drawn would size its cells wrong and either overlap or gap between
/// characters.
enum X11FakeFont {
    /// 13 at 96 dpi, and proportionally more when the screen is denser.
    ///
    /// **A core font is sized in pixels, so it cannot follow the screen on
    /// its own.** These are the old X11 bitmap fonts - `fixed` and the rest
    /// - and a client asks for a size in pixels and lays out its window from
    /// the metrics it gets back. xterm builds its terminal grid this way.
    ///
    /// With Retina rendering a pixel is half a point, so a 13-pixel font
    /// landed at half its former physical size: xterm came up legible but
    /// minute. Scaling here keeps it the same size on the glass and draws it
    /// through CoreText at twice the detail, which is the entire point of
    /// the mode. Toolkits that use Xft instead already follow the density
    /// MSL publishes and need none of this.
    static let pointSize: CGFloat = 13 / X11DisplayScale.factor
    static let ctFont: CTFont = CTFontCreateWithName("Menlo" as CFString, pointSize, nil)

    static let ascent: CGFloat = CTFontGetAscent(ctFont)
    static let descent: CGFloat = CTFontGetDescent(ctFont)

    /// A monospace font's advance width is uniform across ASCII - measured
    /// once from 'M' and reused for every character/string-length
    /// calculation (`QueryTextExtents`, `ImageText8`'s background box).
    static let charWidth: CGFloat = {
        var chars: [UniChar] = [UniChar(UnicodeScalar("M").value)]
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(ctFont, &chars, &glyph, 1) else { return pointSize * 0.6 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        return advance.width
    }()

    /// The integer cell the client is told about (`QueryFont` rounds) and
    /// the grid every glyph is drawn on. Menlo 13's real advance is 7.83:
    /// drawing at that while reporting 8 drifted a line of text 13 px off
    /// an 80-column grid, and a fractional ImageText background box left
    /// half-painted seams between xterm rows and at the end of each run.
    static let cellWidth = Int(charWidth.rounded())
    static let cellAscent = Int(ascent.rounded())
    static let cellDescent = Int(descent.rounded())
}
