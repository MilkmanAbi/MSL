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
    static let pointSize: CGFloat = 13
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
}
