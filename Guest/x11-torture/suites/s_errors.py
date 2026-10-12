"""errors: every bad input gets the right X error, and the server lives.

A client with a stale id is routine (a window destroyed by another thread,
a pixmap freed early). The server's job is a precise error; anything else -
silence, the wrong code, or a crash - is a bug a real app will eventually hit.
"""
import struct

from xwire import Op, GCv
from xhell import test, Fail

FOREIGN = 0x7FFFFFF0  # an id in nobody's range


def stale(c):
    """An id from the client's OWN range that was never created: the
    realistic bad id (a window this client already destroyed)."""
    return c.id_base | 0x1ABCDE


def expect(ctx, c, code, what):
    errs = c.sync()
    names = [e.name for e in errs]
    if code not in names:
        raise Fail("%s: expected %s, got %s" % (what, code, names or "nothing"))


def _case(name, code, build, level=1):
    @test("errors", name, level, doc="%s -> %s" % (name, code))
    def fn(ctx):
        c = ctx.conn()
        build(c)
        expect(ctx, c, code, name)
    return fn


_case("map-bad-window", "BadWindow", lambda c: c.request(Op.MapWindow, struct.pack("<I", stale(c))))
_case("destroy-bad-window", "BadWindow", lambda c: c.request(Op.DestroyWindow, struct.pack("<I", stale(c))))
_case("geometry-bad-drawable", "BadDrawable", lambda c: c.request(Op.GetGeometry, struct.pack("<I", stale(c))))
_case("query-tree-bad-window", "BadWindow", lambda c: c.request(Op.QueryTree, struct.pack("<I", stale(c))))
_case("property-on-bad-window", "BadWindow", lambda c: c.request(
    Op.ChangeProperty, struct.pack("<IIIBxxxI", stale(c), 1, 31, 8, 4) + b"test", detail=0))
_case("get-property-bad-window", "BadWindow", lambda c: c.request(
    Op.GetProperty, struct.pack("<IIIII", stale(c), 1, 31, 0, 10)))
_case("atom-name-zero", "BadAtom", lambda c: c.request(Op.GetAtomName, struct.pack("<I", 0)))
_case("atom-name-huge", "BadAtom", lambda c: c.request(Op.GetAtomName, struct.pack("<I", 0x0FFFFFFF)))
_case("free-bad-pixmap", "BadPixmap", lambda c: c.request(Op.FreePixmap, struct.pack("<I", stale(c))))
_case("free-bad-gc", "BadGC", lambda c: c.request(Op.FreeGC, struct.pack("<I", stale(c))))
_case("draw-with-bad-gc", "BadGC", lambda c: c.fill_rects(c.create_pixmap(4, 4), stale(c), [(0, 0, 1, 1)]))
_case("draw-on-bad-drawable", "BadDrawable", lambda c: c.fill_rects(stale(c), c.create_gc(c.root), [(0, 0, 1, 1)]))
_case("close-bad-font", "BadFont", lambda c: c.request(Op.CloseFont, struct.pack("<I", stale(c))))
_case("free-bad-cursor", "BadCursor", lambda c: c.request(Op.FreeCursor, struct.pack("<I", stale(c))))
_case("free-bad-colormap", "BadColor", lambda c: c.request(Op.FreeColormap, struct.pack("<I", stale(c))))
_case("pixmap-depth-7", "BadValue", lambda c: c.create_pixmap(4, 4, depth=7))
_case("pixmap-zero-size", "BadValue", lambda c: c.create_pixmap(0, 0))
_case("window-zero-size", "BadValue", lambda c: c.create_window(w=0, h=0))
_case("window-bad-class", "BadValue", lambda c: c.create_window(cls=7))
_case("window-bad-parent", "BadWindow", lambda c: c.create_window(parent=stale(c)))
_case("pixmap-huge", "BadAlloc", lambda c: c.create_pixmap(32767, 32767, depth=32), level=2)


@test("errors", "id-outside-range", 1)
def id_outside(ctx):
    """Creating a resource with an id outside the client's range: BadIDChoice."""
    c = ctx.conn()
    c.request(Op.CreatePixmap, struct.pack("<IIHH", 0x00000100, c.root, 4, 4), detail=24)
    expect(ctx, c, "BadIDChoice", "pixmap id outside range")


@test("errors", "id-reused", 1)
def id_reused(ctx):
    """Creating a second resource with an id already in use: BadIDChoice."""
    c = ctx.conn()
    p = c.create_pixmap(4, 4)
    c.request(Op.CreatePixmap, struct.pack("<IIHH", p, c.root, 4, 4), detail=24)
    expect(ctx, c, "BadIDChoice", "reused pixmap id")


@test("errors", "id-reused-across-types", 1)
def id_cross_type(ctx):
    """A GC created with a pixmap's id: BadIDChoice (ids are one namespace)."""
    c = ctx.conn()
    p = c.create_pixmap(4, 4)
    c.request(Op.CreateGC, struct.pack("<III", p, c.root, 0))
    expect(ctx, c, "BadIDChoice", "gc with a pixmap's id")


@test("errors", "destroy-twice", 1)
def destroy_twice(ctx):
    """DestroyWindow on a window already destroyed: BadWindow the second time."""
    c = ctx.conn()
    w = c.create_window()
    c.destroy(w)
    ctx.expect_no_errors(c, "first destroy")
    c.destroy(w)
    expect(ctx, c, "BadWindow", "second destroy")


@test("errors", "copy-area-depth-mismatch", 1)
def depth_mismatch(ctx):
    """CopyArea from a depth-32 pixmap to a depth-24 one: BadMatch."""
    c = ctx.conn()
    a = c.create_pixmap(8, 8, depth=32)
    b = c.create_pixmap(8, 8, depth=24)
    g = c.create_gc(b)
    c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", a, b, g, 0, 0, 0, 0, 8, 8))
    expect(ctx, c, "BadMatch", "cross-depth CopyArea")


@test("errors", "reparent-into-own-child", 1)
def reparent_cycle(ctx):
    """Reparenting a window into its own descendant would make a cycle: BadMatch."""
    c = ctx.conn()
    a = c.create_window()
    b = c.create_window(parent=a)
    cc = c.create_window(parent=b)
    c.request(Op.ReparentWindow, struct.pack("<IIhh", a, cc, 0, 0))
    expect(ctx, c, "BadMatch", "reparent into descendant")


@test("errors", "reparent-into-self", 1)
def reparent_self(ctx):
    """Reparenting a window into itself: BadMatch."""
    c = ctx.conn()
    a = c.create_window()
    c.request(Op.ReparentWindow, struct.pack("<IIhh", a, a, 0, 0))
    expect(ctx, c, "BadMatch", "reparent into self")


@test("errors", "draw-on-input-only", 1)
def input_only(ctx):
    """Drawing on an InputOnly window: BadMatch."""
    c = ctx.conn()
    w = c.create_window(cls=2)
    g = c.create_gc(c.root)
    c.fill_rects(w, g, [(0, 0, 4, 4)])
    expect(ctx, c, "BadMatch", "fill on InputOnly")


@test("errors", "get-image-outside", 1)
def get_image_outside(ctx):
    """GetImage of a rectangle that runs off a pixmap: BadMatch."""
    c = ctx.conn()
    p = c.create_pixmap(8, 8)
    c.request(Op.GetImage, struct.pack("<IhhHHI", p, 4, 4, 8, 8, 0xFFFFFFFF), detail=2)
    expect(ctx, c, "BadMatch", "GetImage out of bounds")


@test("errors", "property-bad-format", 1)
def property_format(ctx):
    """ChangeProperty with format 7 (only 8, 16, 32 exist): BadValue."""
    c = ctx.conn()
    w = c.create_window()
    c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", w, 1, 31, 7, 1) + b"x", detail=0)
    expect(ctx, c, "BadValue", "format 7")


@test("errors", "property-bad-mode", 1)
def property_mode(ctx):
    """ChangeProperty with mode 9 (Replace/Prepend/Append are 0-2): BadValue."""
    c = ctx.conn()
    w = c.create_window()
    c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", w, 1, 31, 8, 1) + b"x", detail=9)
    expect(ctx, c, "BadValue", "mode 9")


@test("errors", "gc-bad-function", 1)
def gc_function(ctx):
    """ChangeGC function 99 (0-15 exist): BadValue."""
    c = ctx.conn()
    g = c.create_gc(c.root)
    c.change_gc(g, {GCv.Function: 99})
    expect(ctx, c, "BadValue", "GC function 99")


@test("errors", "error-storm-then-reply", 2)
def storm(ctx):
    """10,000 requests that each raise an error, then one real query: the
    reply must still arrive, correctly sequenced."""
    c = ctx.conn()
    for _ in range(10000):
        c.request(Op.MapWindow, struct.pack("<I", stale(c)))
    seq = c.request(Op.GetInputFocus)
    r = c.wait_reply(seq)
    errs = c.sync()
    ctx.expect(r[0] == 1, "no reply after the storm")
    ctx.metric("errors_received", len(errs) + len(c.errors))


@test("errors", "foreign-ids-always-answered", 1)
def foreign_policy(ctx):
    """mslgd's deliberate policy: ids from OTHER clients' ranges are let
    through (each app runs in its own host, so another app's windows do not
    exist here even when they would on a real server, and Xlib's default
    error handler exits the app). What must never happen is silence: every
    reply-bearing request has to be answered, or the client blocks forever."""
    import xwire
    c = ctx.conn()
    cases = [(Op.GetGeometry, struct.pack("<I", FOREIGN), 0),
             (Op.QueryTree, struct.pack("<I", FOREIGN), 0),
             (Op.GetWindowAttributes, struct.pack("<I", FOREIGN), 0),
             (Op.GetProperty, struct.pack("<IIIII", FOREIGN, 1, 0, 0, 10), 0),
             (Op.TranslateCoordinates, struct.pack("<IIhh", FOREIGN, c.root, 0, 0), 0),
             (Op.GetImage, struct.pack("<IhhHHI", FOREIGN, 0, 0, 1, 1, 0xFFFFFFFF), 2)]
    for op, body, detail in cases:
        try:
            c.wait_reply(c.request(op, body, detail=detail))
        except xwire.XError:
            pass
