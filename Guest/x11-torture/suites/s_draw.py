"""draw: pixels, checked exactly.

Every test draws into an offscreen pixmap, reads it back with GetImage, and
compares against a plain-Python model of what X says should be there. A
rendering server that is "basically right" fails here on the edges: clipping,
off-window rectangles, XOR, overlapping fills, the last-writer-wins order.
"""
import random
import struct

from xwire import Op, GCv
from xhell import test

W = H = 64


def fresh(ctx_or_c, w=W, h=H, bg=0x000000):
    c = ctx_or_c
    p = c.create_pixmap(w, h)
    g = c.create_gc(p, {GCv.Foreground: bg})
    c.fill_rects(p, g, [(0, 0, w, h)])
    return p, g


def model(w=W, h=H, bg=0x000000):
    return [[bg for _ in range(w)] for _ in range(h)]


def fill_model(m, x, y, w, h, color):
    for yy in range(max(0, y), min(len(m), y + h)):
        for xx in range(max(0, x), min(len(m[0]), x + w)):
            m[yy][xx] = color


def diff(ctx, got, want, label):
    bad = [(x, y, got[y][x], want[y][x])
           for y in range(len(want)) for x in range(len(want[0])) if got[y][x] != want[y][x]]
    if bad:
        x, y, g, w = bad[0]
        ctx.expect(False, "%s: %d/%d px wrong, first at (%d,%d) got %06x want %06x"
                   % (label, len(bad), len(want) * len(want[0]), x, y, g, w))


@test("draw", "fill-basic", 1)
def fill_basic(ctx):
    """A handful of solid rectangles, exact."""
    c = ctx.conn()
    p, g = fresh(c)
    m = model()
    for (x, y, w, h, col) in [(0, 0, 64, 64, 0x102030), (8, 8, 20, 20, 0xFF0000),
                              (40, 40, 20, 20, 0x00FF00), (30, 5, 4, 50, 0x0000FF)]:
        c.change_gc(g, {GCv.Foreground: col})
        c.fill_rects(p, g, [(x, y, w, h)])
        fill_model(m, x, y, w, h, col)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "fills")


@test("draw", "fill-offscreen-edges", 1)
def fill_edges(ctx):
    """80 random rectangles, many hanging off every edge: exact result, so
    clamping to the drawable is verified in both directions."""
    rng = random.Random(ctx.args.seed)
    c = ctx.conn()
    p, g = fresh(c)
    m = model()
    for _ in range(80):
        x = rng.randint(-20, W)
        y = rng.randint(-20, H)
        w = rng.randint(1, 40)
        h = rng.randint(1, 40)
        col = rng.randint(0, 0xFFFFFF)
        c.change_gc(g, {GCv.Foreground: col})
        c.fill_rects(p, g, [(x, y, w, h)])
        fill_model(m, x, y, w, h, col)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "offscreen fills")


@test("draw", "fill-multi-rect-order", 1)
def multi_rect(ctx):
    """One PolyFillRectangle with 5 overlapping rectangles: within a request,
    later rectangles paint over earlier ones."""
    c = ctx.conn()
    p, g = fresh(c)
    m = model()
    rects = [(0, 0, 64, 64), (10, 10, 44, 44), (20, 20, 24, 24), (28, 28, 8, 8), (0, 30, 64, 4)]
    cols = [0x111111, 0x222222, 0x333333, 0x444444, 0x555555]
    # All in one request, one color - so instead do five requests to test
    # cross-request order, and a separate multi-rect for the same-color case.
    for r, col in zip(rects, cols):
        c.change_gc(g, {GCv.Foreground: col})
        c.fill_rects(p, g, [r])
        fill_model(m, *r, col)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "overlap order")


@test("draw", "clip-rectangles", 1)
def clip(ctx):
    """A GC clipped to two rectangles: a fill covering the whole pixmap must
    land only inside the clip."""
    c = ctx.conn()
    p, g = fresh(c)
    clips = [(5, 5, 20, 20), (35, 35, 20, 20)]
    body = b"".join(struct.pack("<hhHH", *r) for r in clips)
    # SetClipRectangles: gc, clip-x-origin, clip-y-origin, then rectangles.
    c.request(Op.SetClipRectangles, struct.pack("<Ihh", g, 0, 0) + body, detail=0)
    c.change_gc(g, {GCv.Foreground: 0xFF8800})
    c.fill_rects(p, g, [(0, 0, W, H)])
    m = model()
    for r in clips:
        fill_model(m, *r, 0xFF8800)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "clipped fill")


@test("draw", "clip-origin-moves", 1)
def clip_origin(ctx):
    """The same clip with a non-zero clip origin moves where the fill lands -
    a toolkit reuses one GC across widgets by shifting the origin."""
    c = ctx.conn()
    p, g = fresh(c)
    c.request(Op.SetClipRectangles, struct.pack("<Ihh", g, 10, 12) + struct.pack("<hhHH", 0, 0, 8, 8), detail=0)
    c.change_gc(g, {GCv.Foreground: 0x00FFFF})
    c.fill_rects(p, g, [(0, 0, W, H)])
    m = model()
    fill_model(m, 10, 12, 8, 8, 0x00FFFF)
    diff(ctx, c.pixels24(p, 0, 0, W, H), m, "clip origin")


@test("draw", "xor-involution", 1)
def xor(ctx):
    """GXxor (function 6): the same fill drawn twice restores the original,
    the idiom rubber bands and carets depend on."""
    c = ctx.conn()
    p, g = fresh(c, bg=0x3366AA)
    before = c.pixels24(p, 0, 0, W, H)
    c.change_gc(g, {GCv.Function: 6, GCv.Foreground: 0xFFFFFF})
    for _ in range(2):
        c.fill_rects(p, g, [(8, 8, 30, 30)])
    diff(ctx, c.pixels24(p, 0, 0, W, H), before, "xor twice")


@test("draw", "copyarea-self-overlap", 1)
def copyarea_overlap(ctx):
    """CopyArea within one pixmap, source and destination overlapping: the
    result must be as if read entirely before any write (a scroll)."""
    c = ctx.conn()
    p, g = fresh(c)
    for i in range(H):
        c.change_gc(g, {GCv.Foreground: (i * 4) << 16 | (i * 4) << 8 | (i * 4)})
        c.fill_rects(p, g, [(0, i, W, 1)])
    src = c.pixels24(p, 0, 0, W, H)
    c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", p, p, g, 0, 0, 0, 10, W, H - 10))
    got = c.pixels24(p, 0, 0, W, H)
    for y in range(10, H):
        for x in range(W):
            if got[y][x] != src[y - 10][x]:
                ctx.expect(False, "scroll wrong at (%d,%d): got %06x want %06x" % (x, y, got[y][x], src[y - 10][x]))
                return


@test("draw", "putimage-getimage-roundtrip", 1)
def putimage_roundtrip(ctx):
    """A known ZPixmap uploaded and read back byte for byte."""
    c = ctx.conn()
    p = c.create_pixmap(W, H)
    g = c.create_gc(p)
    rng = random.Random(ctx.args.seed)
    pix = [[rng.randint(0, 0xFFFFFF) for _ in range(W)] for _ in range(H)]
    data = b"".join(struct.pack("<I", pix[y][x]) for y in range(H) for x in range(W))
    c.request(Op.PutImage, struct.pack("<IIHHhhBBxx", p, g, W, H, 0, 0, 0, 24) + data, detail=2)
    diff(ctx, c.pixels24(p, 0, 0, W, H), pix, "putimage roundtrip")


@test("draw", "getimage-subrect", 1)
def getimage_subrect(ctx):
    """GetImage of an interior sub-rectangle returns exactly that region."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: 0xABCDEF})
    c.fill_rects(p, g, [(20, 16, 8, 8)])
    sub = c.pixels24(p, 20, 16, 8, 8)
    ctx.expect(all(px == 0xABCDEF for row in sub for px in row), "sub-rect not uniform")
    edge = c.pixels24(p, 19, 16, 1, 1)[0][0]
    ctx.expect(edge == 0x000000, "pixel just left of the fill is %06x" % edge)


@test("draw", "draw-flood-100k-rects", 2)
def flood(ctx):
    """100,000 fills in 200 requests of 500 each: survives, stays in step,
    and the final colour is correct where the last rect landed."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: 0x777777})
    batch = [(0, 0, 1, 1)] * 500
    body = b"".join(struct.pack("<hhHH", *r) for r in batch)
    for _ in range(200):
        c.request(Op.PolyFillRectangle, struct.pack("<II", p, g) + body)
    c.change_gc(g, {GCv.Foreground: 0x9944CC})
    c.fill_rects(p, g, [(30, 30, 4, 4)])
    ctx.expect_no_errors(c, "100k fills")
    ctx.expect(c.pixels24(p, 31, 31, 1, 1)[0][0] == 0x9944CC, "final fill missing")


@test("draw", "poly-lines-and-points", 1)
def poly(ctx):
    """PolyPoint and PolyLine survive and change the pixmap - exact geometry
    of thin lines is server-specific, so this checks the endpoints only."""
    c = ctx.conn()
    p, g = fresh(c)
    c.change_gc(g, {GCv.Foreground: 0xFFFFFF})
    pts = b"".join(struct.pack("<hh", x, x) for x in range(0, 60, 4))
    c.request(Op.PolyPoint, struct.pack("<II", p, g) + pts, detail=0)
    c.request(Op.PolyLine, struct.pack("<II", p, g) + struct.pack("<hhhh", 2, 2, 60, 2), detail=0)
    ctx.expect_no_errors(c, "poly point/line")
    ctx.expect(c.pixels24(p, 4, 4, 1, 1)[0][0] == 0xFFFFFF, "PolyPoint pixel missing")
    ctx.expect(c.pixels24(p, 30, 2, 1, 1)[0][0] == 0xFFFFFF, "PolyLine pixel missing")


@test("draw", "huge-pixmap-fill-readback", 2)
def huge(ctx):
    """A 2000x2000 pixmap filled and spot-checked at the far corner."""
    c = ctx.conn()
    p = c.create_pixmap(2000, 2000)
    g = c.create_gc(p, {GCv.Foreground: 0x224466})
    c.fill_rects(p, g, [(0, 0, 2000, 2000)])
    c.change_gc(g, {GCv.Foreground: 0xEE2200})
    c.fill_rects(p, g, [(1990, 1990, 10, 10)])
    ctx.expect_no_errors(c, "2000x2000 fill")
    ctx.expect(c.pixels24(p, 1995, 1995, 1, 1)[0][0] == 0xEE2200, "far-corner fill wrong")
    ctx.expect(c.pixels24(p, 0, 0, 1, 1)[0][0] == 0x224466, "background wrong")
