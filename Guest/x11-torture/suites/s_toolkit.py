"""toolkit: the core-protocol paths old toolkits live on - Tk, Xt/Xaw, Xlib.

GTK and Qt draw almost everything client side and push images. Tk (IDLE),
Xaw (xcalc, xterm's menus), Motif and plain Xlib programs don't: they use
server-side core fonts (OpenFont/QueryFont/ListFonts/ImageText8), stipples
and tiles, CopyPlane of 1-bit bitmaps, thin lines, named colours, and the
core keymap. Tk's font machinery (wiki.tcl-lang.org "Xft support") still
falls back to core fonts when Xft isn't built in; the X.Org font guide
(x.org/guide/fonts) documents the XLFD names these requests carry.

Pixel tests are exact against the X11 spec's rules (thin lines include
their end point, FillPoly is half-open, stipples use the GC's origin).
"""
import math
import struct

from xwire import Op, GCv, CW, EM
from xhell import test, Fail, Skip

from suites.s_draw import fresh as _fresh, model as _model, fill_model, diff  # noqa: F401

W = H = 32


def fresh(c, w=W, h=H, bg=0x000000):
    return _fresh(c, w, h, bg)


def model(w=W, h=H, bg=0x000000):
    return _model(w, h, bg)


def blend_of(px, a, b, tol=3):
    """True if px lies on the colour segment a..b (antialiasing mslgd uses
    for its one real core font: pixels are a coverage mix of two colours)."""
    ca = [(a >> s) & 0xFF for s in (16, 8, 0)]
    cb = [(b >> s) & 0xFF for s in (16, 8, 0)]
    cp = [(px >> s) & 0xFF for s in (16, 8, 0)]
    ts = [(p - x) / (y - x) for p, x, y in zip(cp, ca, cb) if y != x]
    if not ts:
        return all(abs(p - x) <= tol for p, x in zip(cp, ca))
    t = sum(ts) / len(ts)
    return -0.02 <= t <= 1.02 and all(abs(p - (x + t * (y - x))) <= tol for p, x, y in zip(cp, ca, cb))
FG, BG = 0xFF0000, 0x0000FF


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def open_font(c, name):
    fid = c.new_id()
    n = name.encode()
    c.request(Op.OpenFont, struct.pack("<IHxx", fid, len(n)) + n)
    return fid


def query_font(c, fid):
    r = c.call(Op.QueryFont, struct.pack("<I", fid))
    def charinfo(off):
        return dict(zip(("lsb", "rsb", "width", "ascent", "descent", "attr"), struct.unpack_from("<hhhhhH", r, off)))
    minb, maxb = charinfo(8), charinfo(24)
    min_char, max_char, default_char, nprops = struct.unpack_from("<HHHH", r, 40)
    dir_, min_b1, max_b1, all_exist, ascent, descent, ncharinfo = struct.unpack_from("<BBBBhhI", r, 48)
    return {"min": minb, "max": maxb, "min_char": min_char, "max_char": max_char, "nprops": nprops,
            "ascent": ascent, "descent": descent, "ncharinfo": ncharinfo, "len": len(r)}


def text_extents(c, fid, s):
    chars = b"".join(struct.pack(">H", ord(ch)) for ch in s)   # CHAR2B, big-endian always
    odd = len(s) % 2
    r = c.call(Op.QueryTextExtents, struct.pack("<I", fid) + chars, detail=odd)
    return {"ascent": struct.unpack_from("<h", r, 8)[0], "descent": struct.unpack_from("<h", r, 10)[0],
            "width": struct.unpack_from("<i", r, 16)[0]}


def bitmap_bytes(c, rows):
    """Rows of 0/1 -> depth-1 ZPixmap data, per the server's bit order and pad."""
    out = b""
    for row in rows:
        words = (len(row) + 31) // 32
        bits = bytearray(words * 4)
        for x, v in enumerate(row):
            if v:
                if c.bitmap_bit_order == 0:
                    bits[x // 8] |= 1 << (x % 8)
                else:
                    bits[x // 8] |= 0x80 >> (x % 8)
        out += bytes(bits)
    return out


def bitmap(c, rows):
    w, h = len(rows[0]), len(rows)
    p = c.create_pixmap(w, h, depth=1)
    g = c.create_gc(p, {GCv.Foreground: 1, GCv.Background: 0})
    c.request(Op.PutImage, struct.pack("<IIHHhhBBxx", p, g, w, h, 0, 0, 0, 1) + bitmap_bytes(c, rows), detail=2)
    return p


CHECKER = [[(x + y) % 2 for x in range(4)] for y in range(4)]
CORNER = [[1 if (x < 2 and y < 2) else 0 for x in range(4)] for y in range(4)]


# ------------------------------------------------------------------ fonts

@test("toolkit", "font-open-query-fixed", 1)
def font_fixed(ctx):
    """OpenFont("fixed") + QueryFont: sane bounds, monospaced, and the
    char-info count matches the character range (or is 0 = all equal)."""
    c = ctx.conn()
    f = open_font(c, "fixed")
    q = query_font(c, f)
    ctx.expect(q["ascent"] > 0 and q["descent"] >= 0, "font ascent/descent %d/%d" % (q["ascent"], q["descent"]))
    ctx.expect(q["max"]["width"] > 0, "max width > 0")
    ctx.expect(q["min"]["width"] == q["max"]["width"], "fixed is monospaced (%d vs %d)" % (q["min"]["width"], q["max"]["width"]))
    ctx.expect(q["min_char"] <= 0x20 and q["max_char"] >= 0x7E, "covers ASCII (%d..%d)" % (q["min_char"], q["max_char"]))
    n = q["max_char"] - q["min_char"] + 1
    ctx.expect(q["ncharinfo"] in (0, n), "char infos %d for %d chars" % (q["ncharinfo"], n))
    ctx.expect(q["len"] == 60 + 8 * q["nprops"] + 12 * q["ncharinfo"], "reply length matches its counts")


@test("toolkit", "font-text-extents", 1)
def font_extents(ctx):
    """QueryTextExtents of a fixed font: width = n * char width. Also via a
    GC id (the spec lets a GContext stand in for its font - Xlib does)."""
    c = ctx.conn()
    f = open_font(c, "fixed")
    cw = query_font(c, f)["max"]["width"]
    for s in ["hello", "odd", "x", ""]:
        e = text_extents(c, f, s)
        ctx.expect(e["width"] == cw * len(s), "%r: width %d, want %d" % (s, e["width"], cw * len(s)))
    g = c.create_gc(c.root, {GCv.Font: f})
    e = text_extents(c, g, "abcd")
    ctx.expect(e["width"] == cw * 4, "via GC: width %d" % e["width"])


@test("toolkit", "font-xlfd-names", 1)
def font_xlfd(ctx):
    """The XLFD patterns Xaw/Tk/xterm ask for resolve (x.org font guide)."""
    c = ctx.conn()
    for name in ["fixed", "-misc-fixed-medium-r-normal--13-*-*-*-*-*-iso8859-1",
                 "-*-helvetica-medium-r-normal--12-*", "6x13", "cursor", "variable"]:
        f = open_font(c, name)
        errs = c.sync()
        ctx.expect(not errs, "OpenFont %r: %r" % (name, [e.name for e in errs]))
        c.request(Op.CloseFont, struct.pack("<I", f))


@test("toolkit", "font-any-name-opens", 1)
def font_any(ctx):
    """mslgd's policy (a server with one real font): OpenFont accepts any
    name and QueryFont on it works. Xorg would say BadName; Xlib's
    XLoadQueryFont swallows that and the app falls back - here there is
    nothing better to fall back to, so every name gets the one font."""
    c = ctx.conn()
    f = open_font(c, "-xhell-nonexistent-font-that-cannot-exist-*")
    q = query_font(c, f)
    ctx.expect(q["max"]["width"] > 0, "usable metrics")
    ctx.expect(not c.sync(), "no errors")


def list_fonts(c, pattern, maximum=1000):
    p = pattern.encode()
    r = c.call(Op.ListFonts, struct.pack("<HH", maximum, len(p)) + p)
    n, off, names = u16(r, 8), 32, []
    for _ in range(n):
        ln = r[off]
        names.append(r[off + 1:off + 1 + ln].decode())
        off += 1 + ln
    return names


@test("toolkit", "list-fonts-patterns", 1)
def list_fonts_patterns(ctx):
    """ListFonts: '*' lists something, max is honoured, no-match is empty,
    and every name returned can actually be opened (xcalc/xfontsel trust it)."""
    c = ctx.conn()
    all_ = list_fonts(c, "*")
    ctx.expect(len(all_) >= 1, "'*' lists fonts")
    ctx.expect(len(list_fonts(c, "*", 1)) <= 1, "max-names honoured")
    ctx.expect(list_fonts(c, "-xhell-nothing-*") == [], "no match -> empty")
    for name in all_[:20]:
        open_font(c, name)
    errs = c.sync()
    ctx.expect(not errs, "listed fonts open: %r" % [e.name for e in errs][:5])
    ctx.metric("fonts", len(all_))


@test("toolkit", "list-fonts-with-info-terminates", 1)
def list_with_info(ctx):
    """ListFontsWithInfo (50) answers with one reply per font and a final
    reply with name length 0. Without the terminator the client blocks in
    _XReply forever (Tk and xlsfonts -l use it)."""
    c = ctx.conn()
    p = b"*"
    seq = c.request(50, struct.pack("<HH", 5, len(p)) + p)
    c.sync()
    got = 0
    for _ in range(10):
        r = c.replies.pop(seq, None)
        if r is None:
            break
        if r[1] == 0:
            ctx.metric("fonts", got)
            return
        got += 1
    # Multi-reply: xwire keys replies by sequence, so only the LAST reply for
    # `seq` survives. Its name length must be 0.
    raise Fail("no terminating reply (last reply name length %s)" % (r[1] if r else "none"))


@test("toolkit", "glyph-cursor-from-cursor-font", 1)
def glyph_cursor(ctx):
    """XCreateFontCursor: CreateGlyphCursor from the 'cursor' font (xterm,
    Xaw, Tk all do this for every cursor)."""
    c = ctx.conn()
    f = open_font(c, "cursor")
    cur = c.new_id()
    c.request(Op.CreateGlyphCursor, struct.pack("<IIIHHHHHHHH", cur, f, f, 68, 69, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF))
    c.request(96, struct.pack("<IHHHHHH", cur, 0xFFFF, 0, 0, 0, 0, 0xFFFF))   # RecolorCursor
    c.request(Op.FreeCursor, struct.pack("<I", cur))
    ctx.expect(not c.sync(), "no errors")


# ------------------------------------------------------------------- text

def _text_setup(c):
    f = open_font(c, "fixed")
    q = query_font(c, f)
    p, g = fresh(c, W * 2, H, bg=0x00FF00)
    c.change_gc(g, {GCv.Foreground: FG, GCv.Background: BG, GCv.Font: f})
    return f, q, p, g


@test("toolkit", "image-text8-box", 1)
def image_text(ctx):
    """ImageText8 fills the text's box with the GC background, then draws
    glyphs in the foreground: inside the box only FG/BG, both present;
    outside the box nothing changed (xterm draws every cell this way)."""
    c = ctx.conn()
    f, q, p, g = _text_setup(c)
    x, y, s = 4, 20, b"Hg|"
    c.request(Op.ImageText8, struct.pack("<IIhh", p, g, x, y) + s, detail=len(s))
    px = c.pixels24(p, 0, 0, W * 2, H)
    box_w = q["max"]["width"] * len(s)
    top, bottom = y - q["ascent"], y + q["descent"]
    inside = [px[yy][xx] for yy in range(max(0, top), min(H, bottom)) for xx in range(x, x + box_w)]
    outside = [px[yy][xx] for yy in range(H) for xx in range(W * 2)
               if not (top <= yy < bottom and x <= xx < x + box_w)]
    odd = sorted({"%06x" % v for v in inside if not blend_of(v, BG, FG)})
    ctx.expect(not odd, "box holds only FG/BG and their blends: %s" % odd[:6])
    ctx.expect(FG in inside and BG in inside, "both glyph and background pixels")
    # Glyph ink may overhang the box (descenders, '|'), but only as glyph:
    # foreground or its blend with what was there - never the background.
    stray = [v for v in outside if v != 0x00FF00 and not blend_of(v, 0x00FF00, FG)]
    ctx.expect(not stray, "only glyph overhang outside the box (%d px otherwise)" % len(stray))


@test("toolkit", "poly-text8-no-background", 1)
def poly_text(ctx):
    """PolyText8 draws only glyph pixels, in FG - no background box. Also a
    font-shift item (255 + font id) mid-string, which Xlib emits."""
    c = ctx.conn()
    f, q, p, g = _text_setup(c)
    items = bytes([3, 0]) + b"abc" + bytes([255]) + struct.pack(">I", f) + bytes([2, 2]) + b"de"
    c.request(Op.PolyText8, struct.pack("<IIhh", p, g, 2, 20) + items)
    errs = c.sync()
    ctx.expect(not errs, "no errors: %r" % errs)
    px = c.pixels24(p, 0, 0, W * 2, H)
    colors = {v for row in px for v in row}
    odd = sorted("%06x" % v for v in colors if not blend_of(v, 0x00FF00, FG))
    ctx.expect(not odd, "only FG (and its blend) on the green background: %s" % odd[:6])
    ctx.expect(FG in colors, "some glyph pixels drawn")


@test("toolkit", "text-clipped-to-gc", 1)
def text_clip(ctx):
    """Text honours the GC clip rectangles (Tk clips every widget's text)."""
    c = ctx.conn()
    f, q, p, g = _text_setup(c)
    c.request(Op.SetClipRectangles, struct.pack("<Ihh", g, 0, 0) + struct.pack("<hhHH", 0, 0, 6, H))
    c.request(Op.ImageText8, struct.pack("<IIhh", p, g, 0, 20) + b"MMMMMM", detail=6)
    px = c.pixels24(p, 0, 0, W * 2, H)
    leaked = sum(1 for row in px for xx, v in enumerate(row) if xx >= 6 and v != 0x00FF00)
    ctx.expect(leaked == 0, "%d px drawn outside the clip" % leaked)


# ------------------------------------------------------- bitmaps / fills

@test("toolkit", "copy-plane-bitmap", 1)
def copy_plane(ctx):
    """CopyPlane of a 1-bit bitmap onto a 24-bit pixmap: 1 -> FG, 0 -> BG.
    Xaw icons, Tk bitmaps and xeyes all do this."""
    c = ctx.conn()
    rows = [[1 if (x * 7 + y * 3) % 5 < 2 else 0 for x in range(12)] for y in range(9)]
    bm = bitmap(c, rows)
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG, GCv.Background: BG})
    c.request(Op.CopyPlane, struct.pack("<IIIhhhhHHI", bm, p, g, 0, 0, 5, 6, 12, 9, 1))
    m = model()
    for y, row in enumerate(rows):
        for x, v in enumerate(row):
            m[6 + y][5 + x] = FG if v else BG
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "CopyPlane")


@test("toolkit", "bitmap-getimage-roundtrip", 1)
def bitmap_roundtrip(ctx):
    """PutImage/GetImage on a depth-1 pixmap: the same bits come back
    (shape masks, xterm's cursor bitmaps)."""
    c = ctx.conn()
    rows = [[(x ^ y) & 1 if x < 20 else (y % 3 == 0) for x in range(37)] for y in range(5)]
    rows = [[int(v) for v in r] for r in rows]
    bm = bitmap(c, rows)
    depth, data = c.get_image(bm, 0, 0, 37, 5, fmt=2, plane_mask=1)
    ctx.expect(depth == 1, "depth 1 (got %d)" % depth)
    ctx.expect(data[:len(bitmap_bytes(c, rows))] == bitmap_bytes(c, rows), "bits round-trip")


def _stipple_fill(ctx, style, pattern, want_unset):
    c = ctx.conn()
    st = bitmap(c, pattern)
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG, GCv.Background: BG, GCv.FillStyle: style, GCv.Stipple: st})
    c.fill_rects(p, g, [(3, 5, 10, 7)])
    m = model()
    for y in range(5, 12):
        for x in range(3, 13):
            if pattern[y % 4][x % 4]:
                m[y][x] = FG
            elif want_unset is not None:
                m[y][x] = want_unset
    return c, p, m


@test("toolkit", "fill-stippled", 1)
def stippled(ctx):
    """FillStippled: set bits FG, unset bits untouched; the stipple is
    anchored at the drawable origin (TS origin 0,0), not the rectangle."""
    c, p, m = _stipple_fill(ctx, 2, CHECKER, None)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "stippled")


@test("toolkit", "fill-opaque-stippled", 1)
def opaque_stippled(ctx):
    """FillOpaqueStippled: unset bits BG (Xaw's grey insensitive text)."""
    c, p, m = _stipple_fill(ctx, 3, CORNER, BG)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "opaque stippled")


@test("toolkit", "fill-tiled", 1)
def tiled(ctx):
    """FillTiled with a 3x2 tile, anchored at the drawable origin."""
    c = ctx.conn()
    tile_cols = [[0x112233, 0x445566, 0x778899], [0xAABBCC, 0xDDEEFF, 0x010203]]
    tile = c.create_pixmap(3, 2)
    tg = c.create_gc(tile)
    for y, row in enumerate(tile_cols):
        for x, col in enumerate(row):
            c.change_gc(tg, {GCv.Foreground: col})
            c.fill_rects(tile, tg, [(x, y, 1, 1)])
    p, g = fresh(c)
    c.change_gc(g, {GCv.FillStyle: 1, GCv.Tile: tile})
    c.fill_rects(p, g, [(4, 4, 11, 9)])
    m = model()
    for y in range(4, 13):
        for x in range(4, 15):
            m[y][x] = tile_cols[y % 2][x % 3]
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "tiled")


# --------------------------------------------------------------- lines

@test("toolkit", "thin-line-endpoints", 1)
def thin_lines(ctx):
    """Zero-width PolyLine: axis-aligned segments include both end points
    (CapButt draws the last point for thin lines)."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG})
    c.request(Op.PolyLine, struct.pack("<II", p, g) + struct.pack("<hhhhhh", 2, 5, 12, 5, 12, 15))
    m = model()
    for x in range(2, 13):
        m[5][x] = FG
    for y in range(5, 16):
        m[y][12] = FG
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "polyline")


@test("toolkit", "poly-rectangle-outline", 1)
def poly_rect(ctx):
    """PolyRectangle(2,3,10,6), width 0: outline covers x 2..12, y 3..9 -
    one pixel bigger than the fill of the same rectangle (Xaw borders)."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG})
    c.request(Op.PolyRectangle, struct.pack("<II", p, g) + struct.pack("<hhHH", 2, 3, 10, 6))
    m = model()
    for x in range(2, 13):
        m[3][x] = m[9][x] = FG
    for y in range(3, 10):
        m[y][2] = m[y][12] = FG
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "rectangle outline")


@test("toolkit", "poly-point-and-segment", 1)
def points_segments(ctx):
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG})
    pts = [(0, 0), (31, 31), (7, 9), (40, 3)]   # one off-pixmap
    c.request(Op.PolyPoint, struct.pack("<II", p, g) + b"".join(struct.pack("<hh", *q) for q in pts))
    c.request(Op.PolySegment, struct.pack("<II", p, g) + struct.pack("<hhhh", 20, 1, 20, 4))
    m = model()
    for x, y in pts[:3]:
        m[y][x] = FG
    for y in range(1, 5):
        m[y][20] = FG
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "points + segment")


@test("toolkit", "fill-poly-half-open", 1)
def fill_poly(ctx):
    """FillPoly of the square (4,4)-(14,4)-(14,14)-(4,14) covers exactly
    x 4..13, y 4..13 (pixel centres inside; right/bottom edges excluded)."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG})
    c.request(Op.FillPoly, struct.pack("<IIBBxx", p, g, 2, 0) +
              b"".join(struct.pack("<hh", *q) for q in [(4, 4), (14, 4), (14, 14), (4, 14)]))
    m = model()
    fill_model(m, 4, 4, 10, 10, FG)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "fill poly")


@test("toolkit", "fill-arc-circle", 1)
def fill_arc(ctx):
    """PolyFillArc full circle, 20x20: area within 8% of pi*r^2, symmetric
    left/right and top/bottom, inside its box (xeyes' pupils)."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: FG})
    c.request(Op.PolyFillArc, struct.pack("<II", p, g) + struct.pack("<hhHHhh", 6, 6, 20, 20, 0, 360 * 64))
    px = c.pixels24(p, 0, 0, W, H)
    on = {(x, y) for y in range(H) for x in range(W) if px[y][x] != 0}   # any coverage
    area = sum(((px[y][x] >> 16) & 0xFF) / 255 for x, y in on)             # antialiased: weigh by coverage
    ctx.expect(abs(area - math.pi * 100) / (math.pi * 100) < 0.08, "area %.0f vs %.0f" % (area, math.pi * 100))
    ctx.expect(all(6 <= x < 26 and 6 <= y < 26 for x, y in on), "inside the bounding box")
    asym = sum(1 for (x, y) in on if (31 - x, y) not in on and 6 <= 31 - x < 26)
    ctx.expect(asym <= area * 0.05, "mirror-symmetric (%d asymmetric px)" % asym)


# -------------------------------------------------------------- colours

def alloc_named(c, name):
    n = name.encode()
    r = c.call(Op.AllocNamedColor if hasattr(Op, "AllocNamedColor") else 85,
               struct.pack("<IHxx", c.colormap, len(n)) + n)
    pixel = u32(r, 8)
    exact = struct.unpack_from("<HHH", r, 12)
    visual = struct.unpack_from("<HHH", r, 18)
    return pixel, exact, visual


@test("toolkit", "named-colors", 1)
def named_colors(ctx):
    """AllocNamedColor/LookupColor use the X rgb.txt values; case and
    spaces don't matter ("light goldenrod yellow")."""
    c = ctx.conn()
    table = {"red": (255, 0, 0), "LightGoldenrodYellow": (250, 250, 210),
             "light goldenrod yellow": (250, 250, 210), "gray50": (127, 127, 127), "NavyBlue": (0, 0, 128)}
    for name, rgb in table.items():
        pixel, exact, _ = alloc_named(c, name)
        ctx.expect(exact == tuple(v * 257 for v in rgb), "%s exact %r" % (name, exact))
        ctx.expect(pixel == (rgb[0] << 16 | rgb[1] << 8 | rgb[2]), "%s pixel %06x" % (name, pixel))
    n = b"xhellnotacolor"
    c.request(92, struct.pack("<IHxx", c.colormap, len(n)) + n)
    errs = [e.name for e in c.sync()]
    ctx.expect(errs == ["BadName"], "unknown colour -> BadName, got %r" % errs)


@test("toolkit", "alloc-color-truecolor", 1)
def alloc_color(ctx):
    """TrueColor AllocColor: pixel from the high byte of each channel; the
    returned rgb is what that pixel really shows."""
    c = ctx.conn()
    r = c.call(Op.AllocColor, struct.pack("<IHHHxx", c.colormap, 0x1234, 0x5678, 0x9ABC))
    rgb = struct.unpack_from("<HHH", r, 8)
    pixel = u32(r, 16)
    ctx.expect(pixel == 0x12569A, "pixel %06x" % pixel)
    ctx.expect(rgb == (0x1212, 0x5656, 0x9A9A), "returned rgb %r" % (rgb,))
    q = c.call(Op.QueryColors, struct.pack("<II", c.colormap, 0xFF8000))
    ctx.expect(struct.unpack_from("<HHH", q, 32) == (0xFFFF, 0x8080, 0), "QueryColors ff8000")


# ------------------------------------------------------------- keyboard

@test("toolkit", "core-keymap-sanity", 1)
def keymap(ctx):
    """GetKeyboardMapping over 8..255 has letters, Return and the modifier
    keysyms; GetModifierMapping's Shift/Control rows point at them. Tk and
    Xt build their whole key translation from these two replies."""
    c = ctx.conn()
    r = c.call(Op.GetKeyboardMapping, struct.pack("<BBxx", 8, 248))
    per = r[1]
    syms = struct.unpack_from("<%dI" % (248 * per), r, 32)
    by_code = {8 + i // per: syms[i - i % per:i - i % per + per] for i in range(0, len(syms), per)}
    flat = set(syms)
    for name, ks in [("a", 0x61), ("z", 0x7A), ("Return", 0xFF0D), ("Shift_L", 0xFFE1),
                     ("Control_L", 0xFFE3), ("BackSpace", 0xFF08), ("Left", 0xFF51), ("space", 0x20)]:
        ctx.expect(ks in flat, "%s keysym present" % name)
    m = c.call(Op.GetModifierMapping)
    kpm = m[1]
    rows = [m[32 + i * kpm:32 + (i + 1) * kpm] for i in range(8)]
    shift_syms = {s for kc in rows[0] if kc for s in by_code.get(kc, ())}
    ctrl_syms = {s for kc in rows[2] if kc for s in by_code.get(kc, ())}
    ctx.expect(0xFFE1 in shift_syms or 0xFFE2 in shift_syms, "Shift row maps to a Shift key")
    ctx.expect(0xFFE3 in ctrl_syms or 0xFFE4 in ctrl_syms, "Control row maps to a Control key")


# ------------------------------------------------------------ plumbing

@test("toolkit", "no-operation-with-length", 1)
def noop_len(ctx):
    """NoOperation may carry any length (Xlib pads with it); the server
    skips the body and stays in step."""
    c = ctx.conn()
    for words in [1, 2, 100, 16000]:
        c.request(Op.NoOperation, b"\xAA" * (4 * (words - 1)))
    ctx.expect(not c.sync(), "no errors, still in step")


@test("toolkit", "grab-server-pairs", 1)
def grab_server(ctx):
    """GTK/Tk wrap property juggling in Grab/UngrabServer - 500 pairs, some
    nested, pipelined, with a second client working throughout."""
    a = ctx.conn()
    b = ctx.conn()
    for i in range(500):
        a.request(Op.GrabServer)
        if i % 10 == 0:
            a.request(Op.GrabServer)
            a.request(Op.UngrabServer)
        a.request(Op.UngrabServer)
    a.sync()
    b.sync()


@test("toolkit", "clear-area-exposes", 1)
def clear_area(ctx):
    """ClearArea(exposures=True) on a mapped window generates an Expose
    for the cleared rectangle (Xaw redraws that way)."""
    c = ctx.conn()
    w = c.create_window(x=30, y=30, w=60, h=40, attrs={CW.BackPixel: 0xFFFFFF, CW.OverrideRedirect: 1,
                                                        CW.EventMask: EM.Exposure})
    c.map(w)
    c.sync()
    c.drain_events()
    c.request(Op.ClearArea, struct.pack("<IhhHH", w, 5, 6, 10, 12), detail=1)
    ev = c.wait_event(lambda e: e[0] & 0x7F == 12 and u32(e, 4) == w, 3)
    ctx.expect(ev is not None, "an Expose after ClearArea(exposures)")
    if ev:
        ctx.expect(struct.unpack_from("<HHHH", ev, 8) == (5, 6, 10, 12), "for the cleared rectangle: %r" % (struct.unpack_from("<HHHH", ev, 8),))
    c.destroy(w)
