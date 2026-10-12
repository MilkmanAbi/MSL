"""glx: the setup protocol every classic OpenGL app speaks before it draws.

mslgd renders no GL itself - Mesa does that in the guest and presents the
frame through core X11. What the server owes a client is the *description*:
which framebuffer configurations exist, and context/drawable bookkeeping
around them. Get a field wrong here and nothing errors; apps just fail to
find a usable visual, or die with "failed to create drawable".

Checked against what Mesa's client actually requires (`src/glx`), which is
stricter than the spec in places - see the individual tests.
"""
import struct

from xwire import Op
from xhell import test, Fail, Skip

GLX_VENDOR, GLX_VERSION, GLX_EXTENSIONS = 1, 2, 3
# Requests, from glxproto.h.
QUERY_VERSION, GET_VISUAL_CONFIGS, QUERY_EXTENSIONS_STRING = 7, 14, 18
QUERY_SERVER_STRING, GET_FBCONFIGS, CREATE_NEW_CONTEXT = 19, 21, 24
IS_DIRECT, DESTROY_CONTEXT, CREATE_CONTEXT_ATTRIBS = 6, 4, 34
CREATE_PBUFFER, DESTROY_PBUFFER, QUERY_CONTEXT = 27, 28, 25
# The 18 fixed properties GetVisualConfigs leads with.
MIN_CONFIG_PROPS = 18


def glx(ctx, c):
    e = c.query_extension("GLX")
    if not e["present"]:
        raise Skip("GLX not advertised")
    return e


def string_reply(reply):
    """The `pad, n, pad...` shape GLX string replies share; `n` counts the NUL."""
    n = struct.unpack_from("<I", reply, 12)[0]
    return reply[32:32 + n - 1].decode("latin-1")


@test("glx", "advertised", 1)
def advertised(ctx):
    """Present, with a major opcode and an error base that does not collide
    with the other extensions'."""
    c = ctx.conn()
    e = glx(ctx, c)
    ctx.expect(e["major"] >= 128, "major %d" % e["major"])
    ctx.expect(e["error"] != 0, "GLX defines 14 errors, so it needs an error base")
    # GLX owns 14 consecutive codes from its base. They must fit, and must
    # not overlap another extension's range - XInput's is the only other one
    # here and it owns 5 codes (XIproto.h), so 129..133.
    base = int(e["error"])
    ctx.expect(base + 13 <= 255, "GLX's 14 errors fit below 256 (base %d)" % base)
    xinput = c.query_extension("XInputExtension")
    if xinput["present"] and xinput["error"]:
        xi = int(xinput["error"])
        ctx.expect(base >= xi + 5 or base + 14 <= xi,
                   "GLX %d..%d overlaps XInput's %d..%d" % (base, base + 13, xi, xi + 4))


@test("glx", "query-version", 1)
def query_version(ctx):
    """1.4, and never higher than the client asked for - a 1.2 client must
    not be handed 1.3+ semantics it will not parse."""
    c = ctx.conn()
    e = glx(ctx, c)
    r = c.call(e["major"], struct.pack("<II", 1, 4), detail=QUERY_VERSION)
    major, minor = struct.unpack_from("<II", r, 8)
    ctx.expect((major, minor) == (1, 4), "GLX 1.4, got %d.%d" % (major, minor))
    r = c.call(e["major"], struct.pack("<II", 1, 2), detail=QUERY_VERSION)
    major, minor = struct.unpack_from("<II", r, 8)
    ctx.expect((major, minor) <= (1, 2), "asked 1.2, got %d.%d" % (major, minor))


@test("glx", "server-strings", 1)
def server_strings(ctx):
    """Vendor/version/extensions, and `GLX_ARB_create_context` among them -
    that exact string is what Blender names when it refuses to start."""
    c = ctx.conn()
    e = glx(ctx, c)
    vendor = string_reply(c.call(e["major"], struct.pack("<II", 0, GLX_VENDOR), detail=QUERY_SERVER_STRING))
    version = string_reply(c.call(e["major"], struct.pack("<II", 0, GLX_VERSION), detail=QUERY_SERVER_STRING))
    extensions = string_reply(c.call(e["major"], struct.pack("<II", 0, GLX_EXTENSIONS), detail=QUERY_SERVER_STRING))
    ctx.expect(vendor != "", "a vendor string")
    ctx.expect(version.startswith("1."), "version %r" % version)
    for required in ["GLX_ARB_create_context", "GLX_ARB_create_context_profile"]:
        ctx.expect(required in extensions, "%s advertised" % required)
    also = string_reply(c.call(e["major"], struct.pack("<I", 0), detail=QUERY_EXTENSIONS_STRING))
    ctx.expect(also == extensions, "QueryExtensionsString agrees with QueryServerString")


@test("glx", "visual-configs", 1)
def visual_configs(ctx):
    """`GetVisualConfigs`: exactly 18 properties per config (no tagged
    extras - in this older reply some tags are one word and some are two,
    so appending any is a parsing hazard), each naming a real visual."""
    c = ctx.conn()
    e = glx(ctx, c)
    r = c.call(e["major"], struct.pack("<I", 0), detail=GET_VISUAL_CONFIGS)
    count, props = struct.unpack_from("<II", r, 8)
    ctx.expect(count >= 1, "at least one config")
    ctx.expect(props == MIN_CONFIG_PROPS, "%d properties per config, want %d" % (props, MIN_CONFIG_PROPS))
    ctx.expect(len(r) == 32 + count * props * 4, "reply length matches its counts")
    known = {v for ids in c.visuals.values() for v in ids}
    for i in range(count):
        values = struct.unpack_from("<%dI" % props, r, 32 + i * props * 4)
        ctx.expect(values[0] in known, "config %d names a real visual (%#x)" % (i, values[0]))
        ctx.expect(values[2] == 1, "config %d is RGBA" % i)
        ctx.expect(values[3] == 8 and values[4] == 8 and values[5] == 8, "config %d is 8:8:8" % i)


@test("glx", "fbconfigs", 1)
def fbconfigs(ctx):
    """`GetFBConfigs`: `numAttribs` counts PAIRS - Mesa reads
    `numAttribs * 2` words per config, so being off by two decodes every
    config as garbage. Also checks the tags Mesa needs, and that none is
    one it rejects (it warns "unknown fbconfig attribute from server")."""
    c = ctx.conn()
    e = glx(ctx, c)
    r = c.call(e["major"], struct.pack("<I", 0), detail=GET_FBCONFIGS)
    count, pairs = struct.unpack_from("<II", r, 8)
    ctx.expect(count >= 1, "at least one fbconfig")
    ctx.expect(len(r) == 32 + count * pairs * 8, "reply length matches numAttribs as a PAIR count")
    # Every tag a real server sends, taken from an actual `GetFBConfigs` dump
    # off Xvfb (Mesa 25, 2026-09-28) rather than from reading the spec: the
    # first version of this list was short, and flagged mslgd for sending
    # GLX_OPTIMAL_PBUFFER_WIDTH_SGIX (0x8019) - which Xvfb sends too, and
    # Mesa's glxext.c has a case for.
    accepted = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
                0x20, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
                0x800B, 0x8010, 0x8011, 0x8012, 0x8013, 0x8016, 0x8017, 0x8018,
                0x8019, 0x801A, 0x8028, 0x8060,
                0x20B0, 0x20B1, 0x20B2, 0x20B3, 0x20D0, 0x20D1, 0x20D2, 0x20D3, 0x20D4,
                100000, 100001}
    ids, config_visuals = set(), set()
    visuals = {v for vs in c.visuals.values() for v in vs}
    for i in range(count):
        config = dict(struct.unpack_from("<%dI" % (pairs * 2), r, 32 + i * pairs * 8)[k:k + 2]
                      for k in range(0, pairs * 2, 2))
        for tag in config:
            ctx.expect(tag in accepted, "config %d: tag %#x is not one Mesa accepts" % (i, tag))
        for required in [0x8013, 0x800B, 0x8010, 0x8011, 0x8012]:  # FBCONFIG_ID, VISUAL_ID, DRAWABLE_TYPE, RENDER_TYPE, X_RENDERABLE
            ctx.expect(required in config, "config %d has tag %#x" % (i, required))
        ctx.expect(config.get(0x800B) in visuals, "config %d names a real visual" % i)
        ctx.expect(config[0x8013] not in ids, "fbconfig ids are unique")
        ids.add(config[0x8013])
        # One visual per config, as Xorg does. Mesa maps a visual back to its
        # config by id and takes the FIRST match, so sharing visuals silently
        # hands glXChooseVisual clients the wrong config - a single-buffered
        # request came back double-buffered until 2026-09-28.
        ctx.expect(config[0x800B] not in config_visuals,
                   "config %d reuses visual %#x - glXChooseVisual cannot tell them apart"
                   % (i, config[0x800B]))
        config_visuals.add(config[0x800B])
    ctx.metric("fbconfigs", count)


@test("glx", "context-direct-flag-round-trips", 1)
def context_direct(ctx):
    """`IsDirect` must echo what the client said when it created the
    context: Mesa asks immediately after `CreateContext` and destroys the
    context if the server disagrees (glxcmds.c), so a blanket answer either
    way breaks somebody."""
    c = ctx.conn()
    e = glx(ctx, c)
    fbconfig = first_fbconfig(c, e)
    for direct in (1, 0):
        context = c.new_id()
        c.request(e["major"], struct.pack("<IIIIIBxxx", context, fbconfig, 0, 0x8014, 0, direct),
                  detail=CREATE_NEW_CONTEXT)
        r = c.call(e["major"], struct.pack("<I", context), detail=IS_DIRECT)
        ctx.expect(r[8] == direct, "created direct=%d, IsDirect says %d" % (direct, r[8]))
        c.request(e["major"], struct.pack("<I", context), detail=DESTROY_CONTEXT)
    ctx.expect(not c.sync(), "no errors")


def first_fbconfig(c, e):
    r = c.call(e["major"], struct.pack("<I", 0), detail=GET_FBCONFIGS)
    pairs = struct.unpack_from("<I", r, 12)[0]
    config = dict(struct.unpack_from("<%dI" % (pairs * 2), r, 32)[k:k + 2] for k in range(0, pairs * 2, 2))
    return config[0x8013]


@test("glx", "create-context-attribs-arb", 1)
def create_context_attribs(ctx):
    """The ARB path Blender and every modern GL app use. It is a *checked*
    request on the client (it waits for an error round trip), so it must
    not error - and the attribute list is the guest's business, not ours."""
    c = ctx.conn()
    e = glx(ctx, c)
    fbconfig = first_fbconfig(c, e)
    context = c.new_id()
    attribs = [0x2091, 3, 0x2092, 3, 0x9126, 1]  # MAJOR_VERSION 3, MINOR_VERSION 3, PROFILE_MASK core
    body = struct.pack("<IIIIBxxxI", context, fbconfig, 0, 0, 1, len(attribs) // 2)
    body += struct.pack("<%dI" % len(attribs), *attribs)
    c.request(e["major"], body, detail=CREATE_CONTEXT_ATTRIBS)
    ctx.expect(not c.sync(), "no error for a core-profile 3.3 context")
    r = c.call(e["major"], struct.pack("<I", context), detail=IS_DIRECT)
    ctx.expect(r[8] == 1, "still direct")
    r = c.call(e["major"], struct.pack("<I", context), detail=QUERY_CONTEXT)
    ctx.expect(struct.unpack_from("<I", r, 8)[0] >= 1, "QueryContext returns attributes")


@test("glx", "pbuffer-is-a-real-drawable", 1)
def pbuffer(ctx):
    """A GLX pbuffer must be a real server-side drawable: Mesa sends
    `GetGeometry` for the pbuffer id right after creating it and gives up
    with "failed to create drawable" otherwise. That is exactly how Blender
    starts - a 1x1 pbuffer to get a context before it has a window."""
    c = ctx.conn()
    e = glx(ctx, c)
    fbconfig = first_fbconfig(c, e)
    pbuf = c.new_id()
    attribs = [0x8041, 64, 0x8040, 32]  # GLX_PBUFFER_WIDTH, GLX_PBUFFER_HEIGHT
    body = struct.pack("<IIII", 0, fbconfig, pbuf, len(attribs) // 2)
    body += struct.pack("<%dI" % len(attribs), *attribs)
    c.request(e["major"], body, detail=CREATE_PBUFFER)
    geometry = c.get_geometry(pbuf)
    ctx.expect((geometry["w"], geometry["h"]) == (64, 32),
               "GetGeometry on the pbuffer: %dx%d, want 64x32" % (geometry["w"], geometry["h"]))
    ctx.expect(geometry["depth"] in (24, 32), "a sane depth, got %d" % geometry["depth"])
    c.request(e["major"], struct.pack("<I", pbuf), detail=DESTROY_PBUFFER)
    c.sync()
    c.request(Op.GetGeometry, struct.pack("<I", pbuf))
    errs = [x.name for x in c.sync()]
    ctx.expect(errs == ["BadDrawable"], "destroyed pbuffer is gone, got %r" % errs)


@test("glx", "stale-context-errors", 1)
def stale_context(ctx):
    """A context id that was never created gets GLXBadContext, not silence
    and not a crash."""
    c = ctx.conn()
    e = glx(ctx, c)
    stale = c.id_base | 0x1BCDE
    c.request(e["major"], struct.pack("<I", stale), detail=DESTROY_CONTEXT)
    errs = c.sync()
    ctx.expect(len(errs) == 1, "exactly one error, got %r" % [x.name for x in errs])
    if errs:
        ctx.expect(errs[0].code == e["error"], "GLXBadContext (error base %d), got code %d"
                   % (e["error"], errs[0].code))


@test("glx", "every-minor-answers", 2)
def every_minor(ctx):
    """Every GLX minor with a zeroed body: reply, error or silence, but the
    connection stays in step and the host lives. A reply-bearing request
    answered with silence would hang a real client forever."""
    c = ctx.conn(timeout=5)
    e = glx(ctx, c)
    for minor in range(1, 36):
        if minor in (5, 26):
            continue  # MakeCurrent with a null context: legal, but pointless here
        c.request(e["major"], b"\0" * 32, detail=minor)
        c.sync()
    c.drain_events()
