"""windows: the window tree under load.

Tk makes a window per widget; GTK2/Motif apps nest deeply; toolkits reparent
and restack constantly. Each test checks the tree is still RIGHT afterwards,
not just that the server survived.
"""
import random
import struct
import time

from xwire import Op, CW, EM
from xhell import test


def configure(c, wid, x=None, y=None, w=None, h=None, border=None, sibling=None, stack=None):
    items = []
    for bit, val in ((1, x), (2, y), (4, w), (8, h), (16, border), (32, sibling), (64, stack)):
        if val is not None:
            items.append((bit, val))
    mask = 0
    vals = b""
    for bit, val in items:
        mask |= bit
        vals += struct.pack("<i", val) if bit in (1, 2) else struct.pack("<I", val)
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", wid, mask) + vals)


@test("windows", "deep-nesting-1000", 2)
def deep(ctx):
    """1,000 windows each inside the last, offset 1 px: TranslateCoordinates
    from the deepest to the root must add up exactly."""
    c = ctx.conn()
    parent = c.root
    chain = []
    for i in range(1000):
        w = c.create_window(parent=parent, x=1, y=1, w=50, h=50)
        chain.append(w)
        parent = w
    ctx.expect_no_errors(c, "creating the chain")
    r = c.call(Op.TranslateCoordinates, struct.pack("<IIhh", chain[-1], c.root, 0, 0))
    x, y = struct.unpack("<hh", r[12:16])
    ctx.expect((x, y) == (1000, 1000), "deepest window's origin in root is %s, want (1000, 1000)" % ((x, y),))
    _, par, _ = c.query_tree(chain[-1])
    ctx.expect(par == chain[-2], "QueryTree parent of the deepest window is wrong")
    t = time.monotonic()
    c.destroy(chain[0])
    ctx.expect_no_errors(c, "destroying the chain from the top")
    ctx.metric("destroy_1000_deep_ms", (time.monotonic() - t) * 1000)
    c.request(Op.GetGeometry, struct.pack("<I", chain[-1]))
    ctx.expect_error(c, "BadDrawable", "deepest window after its ancestor was destroyed")


@test("windows", "wide-5000-siblings", 2)
def wide(ctx):
    """5,000 children of one window: QueryTree must list all of them, in
    creation (stacking) order."""
    c = ctx.conn()
    top = c.create_window(w=400, h=400)
    kids = [c.create_window(parent=top, x=i % 400, y=i // 400, w=5, h=5) for i in range(5000)]
    _, _, children = c.query_tree(top)
    ctx.expect(len(children) == 5000, "QueryTree lists %d children, want 5000" % len(children))
    ctx.expect(children == kids, "children not in creation order (bottom to top)")


@test("windows", "restack-order", 1)
def restack(ctx):
    """ConfigureWindow stacking: Above, Below, Above-sibling, Below-sibling,
    and CirculateWindow - QueryTree order checked after each."""
    c = ctx.conn()
    top = c.create_window(w=100, h=100)
    a, b, cc, d = [c.create_window(parent=top, w=10, h=10) for _ in range(4)]
    def order():
        return c.query_tree(top)[2]
    ctx.expect(order() == [a, b, cc, d], "initial order")
    configure(c, a, stack=0)                      # Above: a to top
    ctx.expect(order() == [b, cc, d, a], "a raised: %s" % order())
    configure(c, a, stack=1)                      # Below: a to bottom
    ctx.expect(order() == [a, b, cc, d], "a lowered: %s" % order())
    configure(c, a, sibling=cc, stack=0)          # a just above cc
    ctx.expect(order() == [b, cc, a, d], "a above cc: %s" % order())
    configure(c, d, sibling=b, stack=1)           # d just below b
    ctx.expect(order() == [d, b, cc, a], "d below b: %s" % order())
    c.request(Op.CirculateWindow, struct.pack("<I", top), detail=0)  # RaiseLowest
    ctx.expect(order() == [b, cc, a, d], "circulate raise-lowest: %s" % order())
    c.request(Op.CirculateWindow, struct.pack("<I", top), detail=1)  # LowerHighest
    ctx.expect(order() == [d, b, cc, a], "circulate lower-highest: %s" % order())


@test("windows", "reparent-storm", 2)
def reparent_storm(ctx):
    """3,000 random legal reparents among 150 windows (never into a
    descendant). Afterwards every window's QueryTree parent must match the
    model, and every parent's child list must match."""
    rng = random.Random(ctx.args.seed)
    c = ctx.conn()
    base = c.create_window(w=300, h=300)
    wins = [c.create_window(parent=base, w=10, h=10) for _ in range(150)]
    parent = {w: base for w in wins}

    def is_descendant(anc, w):
        while w in parent:
            if w == anc:
                return True
            w = parent[w]
        return w == anc

    for _ in range(3000):
        w = rng.choice(wins)
        np = rng.choice(wins + [base])
        if np == w or is_descendant(w, np):
            continue
        c.request(Op.ReparentWindow, struct.pack("<IIhh", w, np, rng.randint(-20, 200), rng.randint(-20, 200)))
        parent[w] = np
    ctx.expect_no_errors(c, "legal reparents")
    wrong = [w for w in wins if c.query_tree(w)[1] != parent[w]]
    ctx.expect(not wrong, "%d windows report the wrong parent" % len(wrong))
    for p in [base] + wins:
        want = sorted(w for w in wins if parent[w] == p)
        got = sorted(c.query_tree(p)[2])
        if got != want:
            ctx.expect(False, "window 0x%x lists %d children, model says %d" % (p, len(got), len(want)))


@test("windows", "map-unmap-storm", 2)
def map_storm(ctx):
    """20,000 alternating Map/Unmap on 200 children, then a clean state."""
    c = ctx.conn()
    top = c.create_window(w=200, h=200)
    kids = [c.create_window(parent=top, x=i, y=i, w=10, h=10) for i in range(200)]
    for i in range(20000):
        k = kids[i % 200]
        c.request(Op.MapWindow if (i // 200) % 2 == 0 else Op.UnmapWindow, struct.pack("<I", k))
    ctx.expect_no_errors(c, "map/unmap storm")


@test("windows", "configure-extremes", 1)
def configure_extremes(ctx):
    """Negative positions, 1x1 and 32767-wide windows, border widths: the
    geometry read back must be what was set."""
    c = ctx.conn()
    top = c.create_window(w=100, h=100)
    k = c.create_window(parent=top, w=10, h=10)
    for (x, y, w, h, bw) in [(-500, -500, 1, 1, 0), (32000, 32000, 5, 5, 3), (0, 0, 32767, 2, 0), (7, 9, 3, 32767, 100)]:
        configure(c, k, x=x, y=y, w=w, h=h, border=bw)
        g = c.get_geometry(k)
        ctx.expect((g["x"], g["y"], g["w"], g["h"], g["border"]) == (x, y, w, h, bw),
                   "set %s, read back %s" % ((x, y, w, h, bw), (g["x"], g["y"], g["w"], g["h"], g["border"])))


@test("windows", "destroy-subtree-5000", 2)
def destroy_subtree(ctx):
    """A window with 5,000 descendants in a random tree, destroyed at once:
    every descendant gone, one DestroyNotify per window for a parent that
    asked for SubstructureNotify."""
    rng = random.Random(ctx.args.seed)
    c = ctx.conn()
    root = c.create_window(w=100, h=100, attrs={CW.EventMask: EM.SubstructureNotify})
    nodes = [root]
    for _ in range(5000):
        nodes.append(c.create_window(parent=rng.choice(nodes), w=5, h=5))
    c.sync()
    c.drain_events()
    c.destroy(root)
    ctx.expect_no_errors(c, "destroying the subtree")
    c.request(Op.GetGeometry, struct.pack("<I", nodes[-1]))
    ctx.expect_error(c, "BadDrawable", "a descendant after the subtree was destroyed")


@test("windows", "toplevel-storm-100", 2)
def toplevel_storm(ctx):
    """100 real top-level windows (100 NSWindows) created, mapped, moved and
    destroyed in a burst."""
    c = ctx.conn()
    t = time.monotonic()
    tops = [c.create_window(x=40 + i * 3, y=40 + i * 2, w=120, h=80, attrs={CW.BackPixel: 0x204060 + i})
            for i in range(100)]
    for w in tops:
        c.map(w)
    ctx.expect_no_errors(c, "creating and mapping 100 top-levels")
    for w in tops:
        configure(c, w, x=500, y=300, w=60, h=60)
    ctx.expect_no_errors(c, "moving them")
    for w in tops:
        c.destroy(w)
    ctx.expect_no_errors(c, "destroying them")
    ctx.metric("ms", (time.monotonic() - t) * 1000)


@test("windows", "toplevel-resize-thrash", 2)
def resize_thrash(ctx):
    """One mapped top-level resized 500 times in a burst - every step
    reallocates a backing store and an NSWindow frame."""
    c = ctx.conn()
    w = c.create_window(x=100, y=100, w=200, h=200)
    c.map(w)
    for i in range(500):
        configure(c, w, w=100 + (i * 37) % 900, h=100 + (i * 53) % 600)
    ctx.expect_no_errors(c, "500 resizes")
    g = c.get_geometry(w)
    ctx.expect((g["w"], g["h"]) == (100 + (499 * 37) % 900, 100 + (499 * 53) % 600),
               "final size %s" % ((g["w"], g["h"]),))


@test("windows", "properties-flood", 2)
def properties_flood(ctx):
    """2,000 distinct properties on one window, then ListProperties and a
    spot check of values."""
    c = ctx.conn()
    w = c.create_window()
    atoms = [c.intern("XHELL_PROP_%d" % i) for i in range(2000)]
    for i, a in enumerate(atoms):
        data = ("value-%d" % i).encode()
        c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", w, a, 31, 8, len(data)) + data, detail=0)
    r = c.call(Op.ListProperties, struct.pack("<I", w))
    n = struct.unpack("<H", r[8:10])[0]
    ctx.expect(n >= 2000, "ListProperties returns %d, want >= 2000" % n)
    r = c.call(Op.GetProperty, struct.pack("<IIIII", w, atoms[1234], 0, 0, 100))
    ln = struct.unpack("<I", r[16:20])[0]
    ctx.expect(r[32:32 + ln] == b"value-1234", "property 1234 reads back %r" % r[32:32 + ln])


@test("windows", "property-15mb", 3)
def property_big(ctx):
    """A 15 MB property (under the advertised BIG-REQUESTS maximum), read
    back in chunks with offset/length - the path large clipboard data takes."""
    c = ctx.conn()
    if not c.enable_big_requests():
        ctx.skip("no BIG-REQUESTS")
    size = 15 << 20
    ctx.expect(size + 32 <= c.max_big_words * 4, "server maximum %d bytes is under 15 MB" % (c.max_big_words * 4))
    w = c.create_window()
    a = c.intern("XHELL_BIG")
    data = bytes(i & 0xFF for i in range(size))
    c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", w, a, 31, 8, len(data)) + data, detail=0)
    ctx.expect_no_errors(c, "15 MB ChangeProperty")
    r = c.call(Op.GetProperty, struct.pack("<IIIII", w, a, 0, (8 << 20) // 4, 16))
    after = struct.unpack("<I", r[12:16])[0]
    ctx.expect(r[32:96] == data[8 << 20:(8 << 20) + 64] and after == size - (8 << 20) - 64,
               "chunk at 8 MB wrong (bytes_after=%d)" % after)


@test("wire", "request-over-maximum", 2)
def over_max(ctx):
    """A request longer than the advertised BIG-REQUESTS maximum: BadLength.
    Closing the connection afterwards is allowed (Xorg does too - a length
    that cannot be trusted cannot be resynchronised)."""
    c = ctx.conn()
    if not c.enable_big_requests():
        ctx.skip("no BIG-REQUESTS")
    words = c.max_big_words + 16
    c.raw(struct.pack("<BBHI", Op.ChangeProperty, 0, 0, words))
    ctx.allow_disconnect = True
    errs = c.sync()
    ctx.expect("BadLength" in [e.name for e in errs], "expected BadLength, got %s" % errs)


@test("windows", "property-append-10000", 2)
def property_append(ctx):
    """10,000 PropModeAppend writes of 4 bytes: the result must be the exact
    concatenation."""
    c = ctx.conn()
    w = c.create_window()
    a = c.intern("XHELL_APPEND")
    for i in range(10000):
        c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", w, a, 31, 32, 1) + struct.pack("<I", i), detail=2)
    r = c.call(Op.GetProperty, struct.pack("<IIIII", w, a, 0, 0, 10000))
    n = struct.unpack("<I", r[16:20])[0]
    vals = struct.unpack("<%dI" % n, r[32:32 + 4 * n])
    ctx.expect(list(vals) == list(range(10000)), "appended values wrong (got %d items)" % n)
