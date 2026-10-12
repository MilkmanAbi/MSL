"""ext: the extension handshakes GTK, Qt and Xlib do before drawing a pixel.

Sources for what each toolkit requires:
- Qt xcb (qxcbconnection_basic.cpp): RENDER, SHAPE, XKB (UseExtension 1.0),
  XFixes >= 2, SYNC, RandR >= 1.2, MIT-SHM, XInput 2.x - initialised
  unconditionally, used when present.
- GDK3 (gdkdisplay-x11.c): XKB with detectable auto-repeat (PerClientFlags),
  RandR, XFixes, Composite >= 0.4, Damage, SHAPE, XSync.
- GTK2/Xlib: XInput 1 (GetExtensionVersion, ListInputDevices).
- xcb/Xlib everywhere: BIG-REQUESTS.

Each test checks the reply a toolkit parses, not just "no error": the
version it negotiates, the devices it will listen to, the outputs it will
size windows by. Wrong-but-well-framed replies are how apps silently
misbehave (a monitor of size 0, a pointer with no buttons).
"""
import struct

from xwire import Op, CW
from xhell import test, Fail, Skip

ADVERTISED_MUST = ["BIG-REQUESTS", "XKEYBOARD", "RENDER", "RANDR", "SHAPE", "XInputExtension", "XTEST"]
# What real toolkits query that mslgd may not have. Absence is legal (they
# fall back), so it is a metric, not a failure - but it is the to-do list.
WANTED = ["XFIXES", "SYNC", "Composite", "DAMAGE", "MIT-SHM", "Generic Event Extension",
          "XC-MISC", "MIT-SCREEN-SAVER", "GLX", "DRI3", "Present", "XINERAMA", "DOUBLE-BUFFER"]


def ext(ctx, c, name):
    e = c.query_extension(name)
    if not e["present"]:
        raise Skip("%s not advertised" % name)
    return e


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def list_extensions(c):
    r = c.call(Op.ListExtensions)
    n, off, names = r[1], 32, []
    for _ in range(n):
        ln = r[off]
        names.append(r[off + 1:off + 1 + ln].decode())
        off += 1 + ln
    return names


@test("ext", "list-matches-query", 1)
def list_vs_query(ctx):
    """ListExtensions and QueryExtension agree; bases don't collide."""
    c = ctx.conn()
    listed = list_extensions(c)
    majors, events, errors = {}, {}, {}
    for name in listed:
        e = c.query_extension(name)
        ctx.expect(e["present"], "%s listed but QueryExtension says absent" % name)
        ctx.expect(e["major"] >= 128, "%s major %d >= 128" % (name, e["major"]))
        ctx.expect(e["major"] not in majors, "%s shares major %d with %s" % (name, e["major"], majors.get(e["major"])))
        majors[e["major"]] = name
        if e["event"]:
            ctx.expect(e["event"] not in events, "%s first-event %d collides" % (name, e["event"]))
            events[e["event"]] = name
        if e["error"]:
            ctx.expect(e["error"] not in errors, "%s first-error %d collides" % (name, e["error"]))
            errors[e["error"]] = name
    for name in ADVERTISED_MUST:
        ctx.expect(name in listed, "%s is advertised" % name)
    missing = [n for n in WANTED if n not in listed]
    ctx.metric("listed", len(listed))
    ctx.note("toolkits also probe, not provided: " + ", ".join(missing))


@test("ext", "query-unknown-and-case", 1)
def query_unknown(ctx):
    """Unknown names -> present=0 (not an error); names are case-sensitive."""
    c = ctx.conn()
    for name in ["NOT-AN-EXTENSION", "render", "", "X" * 300]:
        ctx.expect(not c.query_extension(name)["present"], "%r reported present" % name[:20])


@test("ext", "big-requests-maximum", 1)
def big_max(ctx):
    c = ctx.conn()
    ctx.expect(c.enable_big_requests(), "BIG-REQUESTS enables")
    ctx.metric("max_words", c.max_big_words)
    ctx.expect(c.max_big_words >= 1 << 20, "maximum >= 4 MB (got %d words)" % c.max_big_words)


@test("ext", "xkb-use-extension", 1)
def xkb_use(ctx):
    """Qt and Xlib: UseExtension(1, 0) -> supported, server version 1.x."""
    c = ctx.conn()
    e = ext(ctx, c, "XKEYBOARD")
    r = c.call(e["major"], struct.pack("<HH", 1, 0), detail=0)
    ctx.expect(r[1] == 1, "supported")
    ctx.expect(u16(r, 8) == 1, "server major 1 (got %d)" % u16(r, 8))


@test("ext", "xkb-detectable-autorepeat", 1)
def xkb_autorepeat(ctx):
    """GDK asks for detectable auto-repeat via PerClientFlags (minor 21).
    The reply's `value` must include the bit, or GTK sees a release/press
    pair per repeat and every held key stutters in text views."""
    c = ctx.conn()
    e = ext(ctx, c, "XKEYBOARD")
    c.call(e["major"], struct.pack("<HH", 1, 0), detail=0)
    DETECTABLE = 1
    body = struct.pack("<HHIIIII", 0x100, 0, DETECTABLE, DETECTABLE, 0, 0, 0)
    r = c.call(e["major"], body, detail=21)
    supported, value = u32(r, 8), u32(r, 12)
    ctx.expect(supported & DETECTABLE, "detectable auto-repeat supported (supported=%#x)" % supported)
    ctx.expect(value & DETECTABLE, "and now on (value=%#x)" % value)


@test("ext", "xkb-get-map-has-keysyms", 1)
def xkb_get_map(ctx):
    """XkbGetMap (minor 8) for key types + syms: a non-empty, well-framed
    reply with min/max keycodes matching the core setup (8..255)."""
    c = ctx.conn()
    e = ext(ctx, c, "XKEYBOARD")
    c.call(e["major"], struct.pack("<HH", 1, 0), detail=0)
    KeyTypes, KeySyms = 1, 2
    body = struct.pack("<HHHHBBBBBBBBBBHBBH", 0x100, KeyTypes | KeySyms, 0, 0, 0, 0, 8, 248, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    r = c.call(e["major"], body, detail=8)
    ctx.expect(r[10] == 8 and r[11] == 255, "min/max keycode 8/255 (got %d/%d)" % (r[10], r[11]))
    ctx.expect(len(r) > 40, "carries a keymap")


@test("ext", "xkb-get-names-and-state", 1)
def xkb_names_state(ctx):
    """GetState (4) and GetNames (17): every GTK/Qt app sends both at startup."""
    c = ctx.conn()
    e = ext(ctx, c, "XKEYBOARD")
    c.call(e["major"], struct.pack("<HH", 1, 0), detail=0)
    c.call(e["major"], struct.pack("<HH", 0x100, 0), detail=4)
    r = c.call(e["major"], struct.pack("<HxxI", 0x100, 0x3FFF), detail=17)
    ctx.expect(r[0] == 1, "GetNames replied")


@test("ext", "xi1-version-and-devices", 1)
def xi1(ctx):
    """GTK2/Xlib XInput 1: GetExtensionVersion + ListInputDevices name the
    core pointer and keyboard (GTK2 aborted when this was BadImplementation)."""
    c = ctx.conn()
    e = ext(ctx, c, "XInputExtension")
    name = b"XInputExtension"
    r = c.call(e["major"], struct.pack("<Hxx", len(name)) + name + b"\0", detail=1)
    ctx.expect(r[0] == 1, "GetExtensionVersion replied")
    r = c.call(e["major"], b"", detail=2)
    ctx.expect(r[8] >= 2, "at least two devices")
    ctx.expect(b"Virtual core pointer" in r and b"Virtual core keyboard" in r, "core devices named")


@test("ext", "xi2-version-negotiation", 1)
def xi2_version(ctx):
    """XIQueryVersion (47): asking 2.4 gets min(asked, server) >= 2.0;
    GTK3 asks 2.3/2.4, Qt 2.2+. The server must never answer HIGHER."""
    for asked in [(2, 0), (2, 2), (2, 4), (3, 0)]:
        c = ctx.conn()   # one negotiation per client: Xorg rejects renegotiating
        e = ext(ctx, c, "XInputExtension")
        r = c.call(e["major"], struct.pack("<HH", *asked), detail=47)
        got = (u16(r, 8), u16(r, 10))
        ctx.expect(got >= (2, 0), "asked %r got %r (>= 2.0)" % (asked, got))
        ctx.expect(got <= asked, "asked %r got %r (not higher)" % (asked, got))


@test("ext", "xi2-query-device-masters", 1)
def xi2_devices(ctx):
    """XIQueryDevice(AllMasterDevices): master pointer 2 + master keyboard
    3, paired with each other, the pointer with buttons + valuators."""
    c = ctx.conn()
    e = ext(ctx, c, "XInputExtension")
    c.call(e["major"], struct.pack("<HH", 2, 2), detail=47)
    r = c.call(e["major"], struct.pack("<Hxx", 1), detail=48)  # AllMasterDevices
    n = u16(r, 8)
    off, devs = 32, {}
    for _ in range(n):
        did, use, att, ncls, nlen = struct.unpack_from("<HHHHH", r, off)
        name = r[off + 12:off + 12 + nlen].decode(errors="replace")
        off += 12 + nlen + (-nlen % 4)
        classes = []
        for _ in range(ncls):
            ctype, clen = struct.unpack_from("<HH", r, off)
            classes.append(ctype)
            off += clen * 4
        devs[did] = (use, att, name, classes)
    ctx.expect(2 in devs and 3 in devs, "devices 2 and 3 (got %r)" % sorted(devs))
    if 2 in devs and 3 in devs:
        ctx.expect(devs[2][0] == 1 and devs[3][0] == 2, "2 = MasterPointer, 3 = MasterKeyboard")
        ctx.expect(devs[2][1] == 3 and devs[3][1] == 2, "paired with each other")
        ctx.expect(1 in devs[2][3], "pointer has a ButtonClass")
        ctx.expect(2 in devs[2][3], "pointer has ValuatorClasses (x/y)")
        ctx.expect(0 in devs[3][3], "keyboard has a KeyClass")
    ctx.expect(off == len(r), "reply fully consumed (%d of %d bytes)" % (off, len(r)))


@test("ext", "xi2-select-get-roundtrip", 1)
def xi2_select(ctx):
    """XISelectEvents then XIGetSelectedEvents returns the same masks."""
    c = ctx.conn()
    e = ext(ctx, c, "XInputExtension")
    c.call(e["major"], struct.pack("<HH", 2, 2), detail=47)
    w = c.create_window()
    mask = (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8)   # button/motion/enter/leave
    c.request(e["major"], struct.pack("<IHxxHH", w, 1, 2, 1) + struct.pack("<I", mask), detail=46)
    r = c.call(e["major"], struct.pack("<I", w), detail=60)
    n = u16(r, 8)
    ctx.expect(n == 1, "one mask back (got %d)" % n)
    if n:
        did, mlen = struct.unpack_from("<HH", r, 32)
        got = u32(r, 36)
        # mslgd keeps one XI2 mask per window (the union over devices) and
        # reports it under XIAllMasterDevices (1); GDK/Qt select on 1 anyway.
        ctx.expect(did in (1, 2) and got == mask, "device 2 mask %#x (got %d %#x)" % (mask, did, got))


@test("ext", "randr-version-and-resources", 1)
def randr(ctx):
    """Qt needs RandR >= 1.2; GetScreenResourcesCurrent -> one CRTC and one
    output; the output is connected and on that CRTC; the CRTC covers the
    screen. Qt sizes every window by this."""
    c = ctx.conn()
    e = ext(ctx, c, "RANDR")
    r = c.call(e["major"], struct.pack("<II", 1, 6), detail=0)
    ver = (u32(r, 8), u32(r, 12))
    ctx.expect(ver >= (1, 2), "RandR >= 1.2 (got %r)" % (ver,))
    r = c.call(e["major"], struct.pack("<I", c.root), detail=25)
    ncrtc, nout, nmode = u16(r, 16), u16(r, 18), u16(r, 20)
    ctx.expect(ncrtc >= 1 and nout >= 1 and nmode >= 1, "crtcs/outputs/modes %d/%d/%d" % (ncrtc, nout, nmode))
    cfg_ts = u32(r, 12)
    crtc = u32(r, 32)
    output = u32(r, 32 + 4 * ncrtc)
    o = c.call(e["major"], struct.pack("<II", output, cfg_ts), detail=9)
    ctx.expect(o[1] == 0, "GetOutputInfo status Success (got %d)" % o[1])
    ctx.expect(o[24] == 0, "output Connected (got %d)" % o[24])
    ctx.expect(u32(o, 12) == crtc, "output on the CRTC")
    ci = c.call(e["major"], struct.pack("<II", crtc, cfg_ts), detail=20)
    w, h = u16(ci, 16), u16(ci, 18)
    ctx.expect((w, h) == (c.width, c.height), "CRTC %dx%d == screen %dx%d" % (w, h, c.width, c.height))


@test("ext", "randr-monitors", 1)
def randr_monitors(ctx):
    """GetMonitors (1.5, GTK3/4): at least one monitor, one primary, sane size."""
    c = ctx.conn()
    e = ext(ctx, c, "RANDR")
    c.call(e["major"], struct.pack("<II", 1, 6), detail=0)
    r = c.call(e["major"], struct.pack("<IBxxx", c.root, 1), detail=42)
    n = u32(r, 12)
    ctx.expect(n >= 1, "monitors: %d" % n)
    if n:
        primary, _, noutput, x, y, w, h, mmw, mmh = struct.unpack_from("<xxxxBBHhhHHII", r, 32)
        ctx.expect(primary == 1, "first monitor primary")
        ctx.expect(w > 0 and h > 0 and mmw > 0 and mmh > 0, "size %dx%d, %dx%dmm" % (w, h, mmw, mmh))


@test("ext", "randr-select-input-notifies", 2)
def randr_select(ctx):
    """RRSelectInput (4) is accepted on the root; no reply, no error."""
    c = ctx.conn()
    e = ext(ctx, c, "RANDR")
    c.call(e["major"], struct.pack("<II", 1, 6), detail=0)
    c.request(e["major"], struct.pack("<IHxx", c.root, 0xF), detail=4)
    errs = c.sync()
    ctx.expect(not errs, "no error (%r)" % errs)


@test("ext", "shape-version-and-roundtrip", 1)
def shape(ctx):
    """SHAPE 1.1; ShapeRectangles then ShapeGetRectangles (8) gives back the
    same rectangles - GTK3 popovers are cut out this way."""
    c = ctx.conn()
    e = ext(ctx, c, "SHAPE")
    r = c.call(e["major"], b"", detail=0)
    ctx.expect((u16(r, 8), u16(r, 10)) >= (1, 1), "SHAPE >= 1.1")
    w = c.create_window(w=100, h=100)
    rects = [(0, 0, 50, 50), (60, 60, 20, 20)]
    body = struct.pack("<BBBxIhh", 0, 0, 0, w, 0, 0) + b"".join(struct.pack("<hhHH", *rr) for rr in rects)
    c.request(e["major"], body, detail=1)   # op Set, kind Bounding, Unsorted
    r = c.call(e["major"], struct.pack("<IBxxx", w, 0), detail=8)
    n = u32(r, 8)
    got = sorted(struct.unpack_from("<hhHH", r, 32 + 8 * i) for i in range(n))
    ctx.expect(got == sorted(rects), "rectangles back: %r" % got)


@test("ext", "shape-query-extents", 1)
def shape_extents(ctx):
    c = ctx.conn()
    e = ext(ctx, c, "SHAPE")
    w = c.create_window(w=100, h=80)
    body = struct.pack("<BBBxIhh", 0, 0, 0, w, 5, 5) + struct.pack("<hhHH", 0, 0, 10, 10)
    c.request(e["major"], body, detail=1)
    r = c.call(e["major"], struct.pack("<I", w), detail=5)
    shaped = r[8]
    bx, by, bw, bh = struct.unpack_from("<hhHH", r, 12)
    ctx.expect(shaped == 1, "bounding shaped")
    ctx.expect((bx, by, bw, bh) == (5, 5, 10, 10), "extents (5,5,10,10), got %r" % ((bx, by, bw, bh),))


@test("ext", "xrender-depth-probe", 1)
def xrender_depths(ctx):
    """libXrender's XRenderHasDepths: pixmaps of depth 1, 4, 8, 24 and 32
    must all be creatable, listed or not - one failure and libXrender tells
    cairo-xlib (GTK2/3) and Xft (Tk) that RENDER doesn't exist. mslgd
    refused depth 4 for a day and every Xlib app lost RENDER without a
    single visible error (the probe's error is swallowed by design)."""
    c = ctx.conn()
    for depth in (1, 4, 8, 24, 32):
        p = c.create_pixmap(1, 1, depth=depth)
        c.request(Op.FreePixmap, struct.pack("<I", p))
    errs = c.sync()
    ctx.expect(not errs, "all five depths creatable: %r" % [(e.name, e.value) for e in errs])


@test("ext", "xlib-sees-render", 1)
def xlib_render(ctx):
    """End to end, through the real libraries: libXrender (what cairo and
    Xft call) must report RENDER present. Skips where there is no libX11."""
    import ctypes
    try:
        x = ctypes.CDLL("libX11.so.6")
        xr = ctypes.CDLL("libXrender.so.1")
    except OSError:
        raise Skip("no libX11/libXrender in this guest")
    x.XOpenDisplay.restype = ctypes.c_void_p
    d = x.XOpenDisplay(None)
    if not d:
        raise Skip("XOpenDisplay failed")
    a, b = ctypes.c_int(), ctypes.c_int()
    ok = xr.XRenderQueryExtension(ctypes.c_void_p(d), ctypes.byref(a), ctypes.byref(b))
    major, minor = ctypes.c_int(), ctypes.c_int()
    xr.XRenderQueryVersion(ctypes.c_void_p(d), ctypes.byref(major), ctypes.byref(minor))
    x.XCloseDisplay(ctypes.c_void_p(d))
    ctx.expect(ok, "XRenderQueryExtension says RENDER is present")
    ctx.metric("version", "%d.%d" % (major.value, minor.value))


@test("ext", "render-formats-toolkits-need", 1)
def render_formats(ctx):
    """cairo/Qt look up ARGB32, RGB24, A8 and A1 by exact masks. Missing A1
    crashed GTK3 on the first typed character (blank cursor)."""
    c = ctx.conn()
    e = ext(ctx, c, "RENDER")
    c.call(e["major"], struct.pack("<II", 0, 11), detail=0)
    r = c.call(e["major"], b"", detail=1)
    nfmt = u32(r, 8)
    have = set()
    for i in range(nfmt):
        fid, typ, depth, rs, rm, gs, gm, bs, bm, as_, am, cmap = struct.unpack_from("<IBBxxHHHHHHHHI", r, 32 + 28 * i)
        have.add((depth, rm, gm, bm, am, as_))
    need = {"ARGB32": (32, 0xFF, 0xFF, 0xFF, 0xFF, 24), "RGB24": (24, 0xFF, 0xFF, 0xFF, 0, 0),
            "A8": (8, 0, 0, 0, 0xFF, 0), "A1": (1, 0, 0, 0, 1, 0)}
    for name, key in need.items():
        ctx.expect(key in have, "%s format present" % name)


@test("ext", "render-query-filters", 1)
def render_filters(ctx):
    """QueryFilters (29): nearest + bilinear present, aliases well-formed.
    Was BadImplementation - fatal under Xlib's default handler."""
    c = ctx.conn()
    e = ext(ctx, c, "RENDER")
    r = c.call(e["major"], struct.pack("<I", c.root), detail=29)
    na, nf = u32(r, 8), u32(r, 12)
    off = 32 + 2 * na + (-2 * na % 4)
    names = []
    for _ in range(nf):
        ln = r[off]
        names.append(r[off + 1:off + 1 + ln].decode())
        off += 1 + ln
    ctx.expect("nearest" in names and "bilinear" in names, "filters %r" % names)
    ctx.expect(na in (0, nf), "aliases count %d vs filters %d" % (na, nf))


@test("ext", "render-cursor-freed-by-core", 1)
def render_cursor(ctx):
    """RENDER CreateCursor then core FreeCursor: no error. Every Qt theme
    cursor got BadCursor here (found by replaying FeatherPad)."""
    c = ctx.conn()
    e = ext(ctx, c, "RENDER")
    p = c.create_pixmap(16, 16, depth=32)
    pic = c.new_id()
    r = c.call(e["major"], b"", detail=1)
    argb = None
    for i in range(u32(r, 8)):
        fid, typ, depth = struct.unpack_from("<IBB", r, 32 + 28 * i)
        if depth == 32:
            argb = fid
    c.request(e["major"], struct.pack("<IIII", pic, p, argb, 0), detail=4)
    cur = c.new_id()
    c.request(e["major"], struct.pack("<IIHH", cur, pic, 0, 0), detail=27)
    c.request(Op.FreeCursor, struct.pack("<I", cur))
    errs = c.sync()
    ctx.expect(not errs, "no errors: %r" % errs)


@test("ext", "xtest-get-version", 1)
def xtest(ctx):
    c = ctx.conn()
    e = ext(ctx, c, "XTEST")
    r = c.call(e["major"], struct.pack("<BxH", 2, 2), detail=0)
    ctx.expect(r[1] == 2, "XTEST major 2 (got %d)" % r[1])


@test("ext", "every-minor-answers-or-errors", 2)
def every_minor(ctx):
    """For every advertised extension, minors 0..63 with a zeroed 8-word
    body: each either replies, errors, or stays silent - but the connection
    must stay in step and the host alive. Requests with effects outside
    the server (fake input, bells, screen/CRTC configuration) are left out."""
    unsafe = {"XTEST": {2}, "XKEYBOARD": {3}, "RANDR": {2, 7, 21, 24, 26, 29, 30}, "BIG-REQUESTS": set(range(64))}
    c = ctx.conn(timeout=5)
    for name in list_extensions(c):
        e = c.query_extension(name)
        for minor in range(64):
            if minor in unsafe.get(name, ()):
                continue
            c.request(e["major"], b"\0" * 32, detail=minor)
        c.sync()
    c.drain_events()
