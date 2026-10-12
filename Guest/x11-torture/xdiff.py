#!/usr/bin/env python3
"""xdiff - a differential oracle: mslgd against a real X server.

    python3 xdiff.py                       # mslgd :1 vs a throwaway Xvfb :7
    python3 xdiff.py --only errors         # probes whose id contains "errors"
    python3 xdiff.py --ref :0 --no-auto    # against an X server you started
    python3 xdiff.py --list

Every probe asks the *same* question of both servers and compares the
answers. A real server is the specification we can actually execute: the
audit that opened this campaign was written by reading code against a spec,
and the expensive findings were the ones where the spec is silent or where
everyone quietly does the same undocumented thing.

**Normalisation is the whole design.** Two X servers legitimately disagree
about resource ids, screen size, vendor string and the exact keyboard layout,
so probes never return those. They return shapes, sets, enumerations and
error codes - the things that must match. Anything a probe cannot normalise
is declared `info`, printed, and not counted as a finding.

Findings are one of:
  DIFF   the two servers answered differently, and the probe is strict
  INFO   they differ, and the probe says that is allowed (printed anyway)
  KNOWN  a difference already triaged - see KNOWN, which carries the reason
  ERR    the probe itself failed against one of the servers

Results go to results/xdiff-latest.json (previous kept as
xdiff-previous.json) and the run prints what CHANGED since last time, which
is how it is used while editing mslgd.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import xwire  # noqa: E402
from xwire import Op, XError  # noqa: E402

PROBES = []


def probe(pid, strict=True, note=""):
    def deco(fn):
        PROBES.append({"id": pid, "fn": fn, "strict": strict, "note": note or (fn.__doc__ or "").strip()})
        return fn
    return deco


# Differences already triaged. The value is *why* - a KNOWN entry with no
# reason is just a silenced test.
KNOWN = {
    "setup.screen": "mslgd reports the Mac's screen; Xvfb reports whatever it was started with.",
    "ext.present": "mslgd deliberately has no MIT-SHM/DRI2/DRI3/Present - there is no shared memory "
                   "across the vsock boundary for them to use. XFIXES is implemented as of "
                   "2026-09-29 (version 1.0: selection watching, which is what a clipboard needs); "
                   "mslgd does not claim the 6.0 a modern Xorg does, because libXfixes gates its "
                   "whole API on the agreed version and claiming more would invite the region, "
                   "cursor and barrier requests this server has no answer for.",
    "ext.list": "Same as ext.present: the extension *sets* differ by design.",
    "keyboard.mapping": "mslgd mirrors the Mac's live layout; Xvfb ships a fixed us layout. "
                        "Only the shape is comparable, and that is what the probe returns.",
    "fontpath": "mslgd serves no fonts from disk; it draws with Core Text.",
    "draw.plane_mask": "GC `plane-mask` is NOT implemented: mslgd draws through Core Graphics, and "
                       "`dst = (src & mask) | (dst & ~mask)` is a per-bit read-modify-write no blend mode "
                       "expresses. Doing it right means a manual pixel loop in every drawing path (fills, "
                       "lines, arcs, text, copies); doing it in only some paths would be worse, because a "
                       "client that sees fills honour it will assume the rest do. No modern toolkit sets "
                       "it - GTK, Qt and cairo all leave it all-ones - so this is deliberately deferred, "
                       "not forgotten.",
    "ext.minor_sweep": "Measured 2026-09-28: 213 of ~330 minors differ, and they are two classes. "
                       "(1) ~155 'Ok vs BadLength': mslgd does not validate the BODY LENGTH of extension "
                       "requests - a truncated one is read as zeroes instead of refused. (2) the rest are "
                       "a truncated request meeting an unimplemented minor, where both servers error but "
                       "pick a different code. Fixing (1) properly needs a minimum-length table per minor "
                       "(~155 constants); a wrong constant would REFUSE a request a real client sends, "
                       "which is a worse bug than the leniency it replaces. Reply-bearing requests are the "
                       "dangerous subset - those fabricate a reply from zeroes - and XkbGetMap, the one "
                       "this oracle caught doing it, is fixed. Unknown minors past each extension's last "
                       "request now answer BadRequest on both.",
    "setup.formats": "Depth 16 only: Xvfb can drive a 16-bit screen, mslgd cannot - no 16-bit "
                     "visual and no 16bpp packer, so advertising the format would be a lie a client "
                     "could act on. Depths 1/4/8/24/32 agree.",
    "render.formats": "Depth 16 again - no 16-bit visual means no 16-bit picture format. "
                      "ARGB32, A8 and A1 all present, which is what cairo and Pango need.",
    "setup.visual_depths": "Visual COUNTS differ by design: mslgd offers one visual per GLX config "
                           "(24) where Xvfb offers ~100. What matters is that both depths exist, "
                           "which glx.visuals and render.formats check directly.",
    "keyboard.modmap": "Mod2/Mod3 are NumLock and ScrollLock. A Mac keyboard has neither key, so "
                       "nothing is bound to them - and a modifier no key can set cannot get stuck. "
                       "Shift/Lock/Control/Mod1/Mod4 are what toolkits match on and those agree.",
    "pointer.mapping": "Xvfb reports 10 buttons, mslgd 9 - matching its XI2 device exactly "
                       "(5 physical + 4 scroll). Reporting buttons no device has is the worse error.",
    "glx.configs": "Config *count* differs (mslgd offers 24, Xvfb ~380 incl. pbuffer-only ones). "
                   "The probe compares the attribute vocabulary, which must match.",
}


# --------------------------------------------------------------------- utils

def err_name(e):
    return xwire.ERROR_NAMES.get(e.code, "code%d" % e.code)


def outcome(conn, fn):
    """Runs `fn` and says what the server did: a reply, nothing, or an error.

    The single most comparable thing two X servers produce. Callers get
    "Reply", "Ok" (accepted, no reply expected) or e.g. "BadValue"."""
    try:
        result = fn()
    except XError as e:
        return err_name(e.err)
    errors = conn.sync()
    if errors:
        return err_name(errors[0])
    return "Reply" if isinstance(result, (bytes, bytearray)) else "Ok"


def ext_outcome(conn, fn, first_error, count=16):
    """Like `outcome`, but names an extension's OWN errors relative to its
    error base.

    That base is server-chosen and handed to the client by
    `QueryExtension` - Xvfb puts RENDER's at 142 - so comparing raw codes
    would report a difference where the two servers actually agree. What
    must match is *which* of the extension's errors came back, not the
    number it happens to wear on this server."""
    def name(err):
        if first_error and first_error <= err.code < first_error + count:
            return "ext_err%d" % (err.code - first_error)
        return err_name(err)
    try:
        result = fn()
    except XError as e:
        return name(e.err)
    errors = conn.sync()
    if errors:
        return name(errors[0])
    return "Reply" if isinstance(result, (bytes, bytearray)) else "Ok"


def unallocated(conn):
    """An id inside this client's range that names nothing."""
    return conn.new_id()


# -------------------------------------------------------------------- probes

@probe("setup.formats")
def setup_formats(c):
    """Pixmap formats: every depth the server can hold, and its packing.
    A missing depth-1 format is what crashed GTK3 on the first typed key."""
    return {str(d): list(v) for d, v in sorted(c.formats.items())}


@probe("setup.visual_depths")
def setup_visual_depths(c):
    """Which depths carry visuals. A server with no depth-32 visual makes
    GDK give up on RENDER entirely."""
    return {str(d): len(v) for d, v in sorted(c.visuals.items())}


@probe("setup.wire")
def setup_wire(c):
    """Byte order, bitmap unit/pad and the root depth: everything an image
    packer has to agree with."""
    return {"image_byte_order": c.image_byte_order, "bitmap_bit_order": c.bitmap_bit_order,
            "bitmap_unit": c.bitmap_unit, "bitmap_pad": c.bitmap_pad, "root_depth": c.root_depth}


@probe("setup.screen", strict=False)
def setup_screen(c):
    """Informational: screen geometry and id ranges are per-server."""
    return {"width": c.width, "height": c.height, "max_request_words": c.max_req_words}


EXTENSIONS = ["BIG-REQUESTS", "XKEYBOARD", "XInputExtension", "RENDER", "SHAPE", "RANDR",
              "XTEST", "MIT-SCREEN-SAVER", "GLX", "XFIXES", "MIT-SHM", "DRI2", "DRI3",
              "Present", "XINERAMA", "DOUBLE-BUFFER", "Generic Event Extension", "SYNC"]


@probe("ext.present", strict=False)
def ext_present(c):
    """Which extensions each server admits to. Differences here are design
    decisions, not bugs - but they are the map of what else to compare."""
    out = {}
    for name in EXTENSIONS:
        try:
            out[name] = bool(c.query_extension(name))
        except XError as e:
            out[name] = "err:" + err_name(e.err)
    return out


@probe("ext.list", strict=False)
def ext_list(c):
    """ListExtensions must agree with QueryExtension - on the same server.
    A name in one and not the other is a real bug, and this probe shows it
    per-server rather than across them."""
    r = c.call(Op.ListExtensions)
    count = r[1]
    names, off = [], 32
    for _ in range(count):
        n = r[off]
        names.append(r[off + 1:off + 1 + n].decode("latin-1"))
        off += 1 + n
    mismatched = sorted(n for n in names if not c.query_extension(n))
    return {"count": len(names), "agrees_with_query_extension": not mismatched,
            "listed_but_not_queryable": mismatched}


@probe("atoms.predefined")
def atoms_predefined(c):
    """The 68 predefined atoms. They are fixed by the protocol, so both
    servers must return identical names - mslgd once had none of them seeded,
    which silently disabled WM_NAME and WM_NORMAL_HINTS."""
    names = {}
    for atom in range(1, 69):
        try:
            r = c.call(Op.GetAtomName, struct.pack("<I", atom))
            names[str(atom)] = r[32:32 + struct.unpack_from("<H", r, 8)[0]].decode("latin-1")
        except XError as e:
            names[str(atom)] = "err:" + err_name(e.err)
    return names


@probe("atoms.intern")
def atoms_intern(c):
    """InternAtom's contract: a new name is created, `only_if_exists` on an
    unknown name returns None (0) rather than an error, and a round trip
    through GetAtomName gives the name back."""
    created = c.intern("XDIFF_PROBE_ATOM")
    missing = c.intern("XDIFF_NO_SUCH_ATOM_EVER", only_if_exists=True)
    r = c.call(Op.GetAtomName, struct.pack("<I", created))
    back = r[32:32 + struct.unpack_from("<H", r, 8)[0]].decode("latin-1")
    return {"created_nonzero": created != 0, "only_if_exists_is_zero": missing == 0,
            "round_trip": back}


@probe("keyboard.mapping", strict=False)
def keyboard_mapping(c):
    """Shape only: layouts legitimately differ. But the *shape* is what
    libX11 indexes into, and getting it wrong shifts every key."""
    lo, hi = c.min_keycode, c.max_keycode
    count = hi - lo + 1
    r = c.call(Op.GetKeyboardMapping, struct.pack("<BB2x", lo, count))
    per = r[1]
    syms = struct.unpack_from("<%dI" % (per * count), r, 32)
    nonzero = sum(1 for s in syms if s)
    return {"min_keycode": lo, "max_keycode": hi, "keysyms_per_keycode": per,
            "reply_words_match": len(r) == 32 + per * count * 4,
            "fraction_mapped": round(nonzero / float(per * count), 2)}


@probe("keyboard.modmap")
def keyboard_modmap(c):
    """Which of the eight modifiers have keys bound. Shift/Lock/Control and
    at least one Mod must exist or no toolkit can match a shortcut."""
    r = c.call(Op.GetModifierMapping)
    per = r[1]
    keys = struct.unpack_from("<%dB" % (per * 8), r, 32)
    names = ["Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5"]
    return {"keycodes_per_modifier": per,
            "bound": {names[i]: any(keys[i * per:(i + 1) * per]) for i in range(8)}}


@probe("keyboard.control")
def keyboard_control(c):
    """GetKeyboardControl's shape and the fields a client acts on."""
    r = c.call(Op.GetKeyboardControl)
    glob, led, interval, timeout, pct = struct.unpack_from("<IIHHB", r, 12)[0:5]
    return {"reply_len_words": struct.unpack_from("<I", r, 4)[0],
            "global_auto_repeat_is_bool": r[1] in (0, 1),
            "bell_percent_in_range": 0 <= r[32] <= 100 if len(r) > 32 else None}


@probe("pointer.mapping")
def pointer_mapping(c):
    """GetPointerMapping. An empty or short map tells Qt the pointer has
    fewer buttons than it does."""
    r = c.call(Op.GetPointerMapping)
    n = r[1]
    return {"count": n, "values": list(r[32:32 + n]), "strictly_positive": all(r[32:32 + n])}


@probe("pointer.control")
def pointer_control(c):
    """GetPointerControl: acceleration numerator/denominator/threshold."""
    r = c.call(Op.GetPointerControl)
    num, den, thr = struct.unpack_from("<HHH", r, 8)
    return {"denominator_nonzero": den != 0, "fields_present": True}


@probe("screensaver.get")
def screensaver_get(c):
    """GetScreenSaver. mslgd has no screen saver, but the reply must still
    be the right shape and the fields legal enumerations."""
    r = c.call(Op.GetScreenSaver)
    timeout, interval = struct.unpack_from("<HH", r, 8)
    blanking, exposures = r[12], r[13]
    return {"blanking_is_enum": blanking in (0, 1, 2), "exposures_is_enum": exposures in (0, 1, 2)}


@probe("fontpath", strict=False)
def fontpath(c):
    """Informational: mslgd draws with Core Text and serves no font path."""
    r = c.call(Op.GetFontPath)
    return {"count": struct.unpack_from("<H", r, 8)[0]}


@probe("querybestsize")
def querybestsize(c):
    """QueryBestSize for the three classes, and BadValue for a fourth."""
    root = c.root
    out = {}
    for cls in (0, 1, 2):
        r = c.call(Op.QueryBestSize, struct.pack("<IHH", root, 32, 32), detail=cls)
        out["class%d" % cls] = list(struct.unpack_from("<HH", r, 8))
    out["bad_class"] = outcome(c, lambda: c.call(Op.QueryBestSize, struct.pack("<IHH", root, 32, 32), detail=9))
    return out


@probe("geometry.root")
def geometry_root(c):
    """The root window must answer GetGeometry with its real depth and a
    zero border - mslgd once answered 1x1 because the root was not in its
    window table, and every layout derived from it was wrong."""
    r = c.call(Op.GetGeometry, struct.pack("<I", c.root))
    depth = r[1]
    x, y, w, h, border = struct.unpack_from("<hhHHH", r, 12)
    return {"depth": depth, "border": border, "nonzero_size": w > 1 and h > 1,
            "matches_setup_size": (w, h) == (c.width, c.height)}


@probe("tree.root")
def tree_root(c):
    """QueryTree on the root: root is its own root and has no parent."""
    root, parent, n = c.query_tree(c.root)
    return {"root_is_self": root == c.root, "parent_is_none": parent == 0}


@probe("errors.resources")
def errors_resources(c):
    """The error code for naming a resource that does not exist. Every one
    of these is a different code, and clients switch on them."""
    out = {}
    bad = unallocated(c)
    out["GetGeometry"] = outcome(c, lambda: c.call(Op.GetGeometry, struct.pack("<I", bad)))
    out["QueryTree"] = outcome(c, lambda: c.call(Op.QueryTree, struct.pack("<I", bad)))
    out["GetWindowAttributes"] = outcome(c, lambda: c.call(Op.GetWindowAttributes, struct.pack("<I", bad)))
    out["FreePixmap"] = outcome(c, lambda: c.request(Op.FreePixmap, struct.pack("<I", bad)))
    out["FreeGC"] = outcome(c, lambda: c.request(Op.FreeGC, struct.pack("<I", bad)))
    out["DestroyWindow"] = outcome(c, lambda: c.request(Op.DestroyWindow, struct.pack("<I", bad)))
    out["ListProperties"] = outcome(c, lambda: c.call(Op.ListProperties, struct.pack("<I", bad)))
    return out


@probe("errors.window_vs_pixmap")
def errors_window_vs_pixmap(c):
    """A pixmap where a window is required is BadWindow, and a window is a
    perfectly good drawable. Servers that store one table for both get this
    wrong in a way no single-server test can see."""
    pixmap = c.create_pixmap(16, 16)
    win = c.create_window()
    c.sync()
    return {
        "GetWindowAttributes(pixmap)": outcome(c, lambda: c.call(Op.GetWindowAttributes, struct.pack("<I", pixmap))),
        "QueryTree(pixmap)": outcome(c, lambda: c.call(Op.QueryTree, struct.pack("<I", pixmap))),
        "GetGeometry(pixmap)": outcome(c, lambda: c.call(Op.GetGeometry, struct.pack("<I", pixmap))),
        "GetGeometry(window)": outcome(c, lambda: c.call(Op.GetGeometry, struct.pack("<I", win))),
        "MapWindow(pixmap)": outcome(c, lambda: c.request(Op.MapWindow, struct.pack("<I", pixmap))),
    }


@probe("errors.values")
def errors_values(c):
    """BadValue for enumerations out of range. These are the checks a
    permissive server skips, and then a client's bug becomes a mystery."""
    win = c.create_window()
    c.sync()
    out = {}
    out["ChangeProperty(format=7)"] = outcome(c, lambda: c.request(
        Op.ChangeProperty, struct.pack("<IIIB3xI", win, 39, 31, 7, 0)))
    out["ChangeProperty(mode=9)"] = outcome(c, lambda: c.request(
        Op.ChangeProperty, struct.pack("<IIIB3xI", win, 39, 31, 8, 0), detail=9))
    out["CreateWindow(class=7)"] = outcome(c, lambda: c.request(
        Op.CreateWindow, struct.pack("<IIhhHHHHII", c.new_id(), c.root, 0, 0, 10, 10, 0, 7, 0, 0), detail=24))
    out["CreatePixmap(w=0)"] = outcome(c, lambda: c.request(
        Op.CreatePixmap, struct.pack("<IIHH", c.new_id(), c.root, 0, 10), detail=24))
    out["SetInputFocus(revert=9)"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", 0, 0), detail=9))
    out["Bell(200)"] = outcome(c, lambda: c.request(Op.Bell, b"", detail=200))
    out["GetAtomName(0)"] = outcome(c, lambda: c.call(Op.GetAtomName, struct.pack("<I", 0)))
    out["GetAtomName(100000)"] = outcome(c, lambda: c.call(Op.GetAtomName, struct.pack("<I", 100000)))
    return out


@probe("errors.requests")
def errors_requests(c):
    """Unknown opcodes. A core opcode the protocol does not define is
    BadRequest; an unknown *minor* inside an extension is the extension's
    business, and the two must not be confused."""
    out = {}
    for opcode in (0, 126, 200, 255):
        out["core%d" % opcode] = outcome(c, lambda o=opcode: c.request(o, b""))
    for name in ("RENDER", "SHAPE", "XKEYBOARD"):
        ext = c.query_extension(name)
        if ext:
            out["%s.minor200" % name] = outcome(c, lambda m=ext: c.request(m["major"], b"\0" * 4, detail=200))
    return out


@probe("errors.match")
def errors_match(c):
    """BadMatch: the depth rules. Copying between drawables of different
    depths, and creating a GC on a depth-1 pixmap then using it on a
    depth-24 window."""
    deep = c.create_pixmap(16, 16, depth=24)
    shallow = c.create_pixmap(16, 16, depth=1)
    gc = c.create_gc(deep)
    c.sync()
    return {
        "CopyArea(24->1)": outcome(c, lambda: c.request(
            Op.CopyArea, struct.pack("<IIIhhhhHH", deep, shallow, gc, 0, 0, 0, 0, 8, 8))),
        "CopyArea(24->24)": outcome(c, lambda: c.request(
            Op.CopyArea, struct.pack("<IIIhhhhHH", deep, deep, gc, 0, 0, 0, 0, 8, 8))),
        "CreateGC(depth1)": outcome(c, lambda: c.request(
            Op.CreateGC, struct.pack("<III", c.new_id(), shallow, 0))),
    }


@probe("render.formats")
def render_formats(c):
    """RENDER's format table, normalised to the set of (depth, type) pairs
    and the standard formats' masks. A visual with no PictFormat makes
    cairo give up on RENDER for windows made with it."""
    ext = c.query_extension("RENDER")
    if not ext:
        return {"present": False}
    c.call(ext["major"], struct.pack("<II", 0, 11), detail=0)  # QueryVersion
    r = c.call(ext["major"], b"", detail=1)                    # QueryPictFormats
    nformats, nscreens, ndepths, nvisuals = struct.unpack_from("<IIII", r, 8)
    formats = []
    off = 32
    for _ in range(nformats):
        fid, ftype, depth = struct.unpack_from("<IBB2x", r, off)[0:3]
        shifts = struct.unpack_from("<8H", r, off + 8)
        formats.append({"type": ftype, "depth": depth, "direct": list(shifts)})
        off += 28
    kinds = sorted({(f["depth"], f["type"]) for f in formats})
    return {"present": True, "depth_type_pairs": [list(k) for k in kinds],
            # type 1 is Direct; 0 is Indexed. This read `== 0` until
            # 2026-10-06, so all three were False on both servers and
            # asserted nothing at all.
            "has_argb32": any(f["depth"] == 32 and f["type"] == 1 for f in formats),
            "has_a8": any(f["depth"] == 8 and f["type"] == 1 for f in formats),
            "has_a1": any(f["depth"] == 1 and f["type"] == 1 for f in formats),
            "screens_reported": nscreens}


@probe("glx.configs", strict=False)
def glx_configs(c):
    """The GLX attribute *vocabulary*. Config counts differ legitimately;
    sending a tag the reference server never sends means Mesa may reject
    every config (this is exactly how mari0 failed)."""
    ext = c.query_extension("GLX")
    if not ext:
        return {"present": False}
    r = c.call(ext["major"], struct.pack("<I", 0), detail=21)  # GetFBConfigs
    count, pairs = struct.unpack_from("<II", r, 8)
    tags = set()
    for i in range(count):
        words = struct.unpack_from("<%dI" % (pairs * 2), r, 32 + i * pairs * 8)
        tags.update(words[k] for k in range(0, pairs * 2, 2))
    return {"present": True, "count": count, "tags": sorted(hex(t) for t in tags)}


@probe("glx.visuals")
def glx_visuals(c):
    """Every GLX config must name a visual the server actually advertises,
    and - because Mesa maps a visual back to the first config that has it -
    no two configs may share one."""
    ext = c.query_extension("GLX")
    if not ext:
        return {"present": False}
    r = c.call(ext["major"], struct.pack("<I", 0), detail=21)
    count, pairs = struct.unpack_from("<II", r, 8)
    known = {v for vs in c.visuals.values() for v in vs}
    visuals = []
    for i in range(count):
        words = struct.unpack_from("<%dI" % (pairs * 2), r, 32 + i * pairs * 8)
        cfg = dict((words[k], words[k + 1]) for k in range(0, pairs * 2, 2))
        if 0x800B in cfg and cfg[0x800B]:
            visuals.append(cfg[0x800B])
    real = [v for v in visuals if v in known]
    return {"present": True, "all_name_real_visuals": len(real) == len(visuals),
            "window_configs_have_unique_visuals": len(set(visuals)) == len(visuals)}


@probe("xkb.shape")
def xkb_shape(c):
    """XKB's version handshake and that GetMap answers at all - "failed to
    compile a keymap" is what a client says when any of it errors."""
    ext = c.query_extension("XKEYBOARD")
    if not ext:
        return {"present": False}
    r = c.call(ext["major"], struct.pack("<BBH", 1, 0, 0), detail=0)  # UseExtension
    # A well-formed XkbGetMap asking for nothing: deviceSpec=UseCoreKbd, then
    # full/partial and every first/count pair zeroed. Both servers must reply.
    good = struct.pack("<HHHBBBBBBBBHBBBBBBH", 0x0100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    return {"present": True, "supported": r[1] == 1,
            "GetMap(well-formed)": outcome(c, lambda: c.call(ext["major"], good, detail=8)),
            # Deliberately short: a real server refuses it on length alone.
            "GetMap(truncated)": outcome(c, lambda: c.call(ext["major"], struct.pack("<HH", 0x0100, 0), detail=8))}


@probe("xinput.version")
def xinput_version(c):
    """XI2's version handshake. Qt drops XKB and XI2 events whose device
    ids disagree with what the server reported, so the handshake matters."""
    ext = c.query_extension("XInputExtension")
    if not ext:
        return {"present": False}
    r = c.call(ext["major"], struct.pack("<HH", 2, 3), detail=47)  # XIQueryVersion
    major, minor = struct.unpack_from("<HH", r, 8)
    return {"present": True, "major": major, "at_least_2_0": major >= 2}


@probe("bigreq")
def bigreq(c):
    """BIG-REQUESTS: the enable reply carries the new maximum, and it must
    be larger than the setup's."""
    ext = c.query_extension("BIG-REQUESTS")
    if not ext:
        return {"present": False}
    r = c.call(ext["major"], b"", detail=0)
    maximum = struct.unpack_from("<I", r, 8)[0]
    return {"present": True, "larger_than_setup": maximum > c.max_req_words}


# ------------------------------------------------------- drawing (real pixels)

def digest(c, drawable, w, h):
    """A comparable summary of what is actually in a drawable.

    The colour histogram plus a fixed sample grid: identical drawing gives
    identical output on both servers, while the summary stays small enough to
    read in a diff. Raw pixel dumps would be unreadable and no more precise."""
    rows = c.pixels24(drawable, 0, 0, w, h)
    counts = {}
    for row in rows:
        for px in row:
            counts[px] = counts.get(px, 0) + 1
    samples = {}
    for y in (0, h // 2, h - 1):
        for x in (0, w // 2, w - 1):
            samples["%d,%d" % (x, y)] = "#%06x" % rows[y][x]
    top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
    return {"colours": [["#%06x" % px, n] for px, n in top], "samples": samples}


def canvas(c, w=32, h=32, depth=24, fill=0x000000):
    """A pixmap pre-filled with a known colour, and a GC to draw on it."""
    pix = c.create_pixmap(w, h, depth=depth)
    gc = c.create_gc(pix, {xwire.GCv.Foreground: fill, xwire.GCv.Background: 0xFFFFFF})
    c.fill_rects(pix, gc, [(0, 0, w, h)])
    return pix, gc


@probe("draw.fill_rect")
def draw_fill_rect(c):
    """The most basic drawing there is: a solid rectangle at an exact
    position. If this differs, nothing above it can be trusted."""
    pix, gc = canvas(c)
    c.change_gc(gc, {xwire.GCv.Foreground: 0xFF0000})
    c.fill_rects(pix, gc, [(4, 8, 10, 6)])
    c.sync()
    return digest(c, pix, 32, 32)


@probe("draw.copy_area")
def draw_copy_area(c):
    """CopyArea within one drawable, including the clipped part of a copy
    that runs off the edge."""
    pix, gc = canvas(c)
    c.change_gc(gc, {xwire.GCv.Foreground: 0x00FF00})
    c.fill_rects(pix, gc, [(0, 0, 8, 8)])
    c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", pix, pix, gc, 0, 0, 12, 12, 8, 8))
    c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", pix, pix, gc, 0, 0, 28, 28, 8, 8))
    c.sync()
    return digest(c, pix, 32, 32)


@probe("draw.function_xor")
def draw_function_xor(c):
    """GC `function`: XOR is how every rubber-band selection in an old
    toolkit is drawn, and drawing it twice must restore the original."""
    pix, gc = canvas(c, fill=0x0000FF)
    c.change_gc(gc, {xwire.GCv.Function: 6, xwire.GCv.Foreground: 0x00FFFF})  # GXxor
    c.fill_rects(pix, gc, [(4, 4, 8, 8)])
    once = digest(c, pix, 32, 32)
    c.fill_rects(pix, gc, [(4, 4, 8, 8)])
    twice = digest(c, pix, 32, 32)
    c.sync()
    return {"after_one_xor": once, "restored_by_second": twice}


@probe("draw.plane_mask")
def draw_plane_mask(c):
    """`plane-mask` restricts which bit planes a drawing operation touches.
    Ignoring it makes a client's careful per-plane drawing solid."""
    pix, gc = canvas(c, fill=0x000000)
    c.change_gc(gc, {xwire.GCv.PlaneMask: 0x00FF00, xwire.GCv.Foreground: 0xFFFFFF})
    c.fill_rects(pix, gc, [(0, 0, 16, 16)])
    c.sync()
    return digest(c, pix, 32, 32)


@probe("draw.clip_rectangles")
def draw_clip(c):
    """SetClipRectangles: drawing outside the clip must not land. GTK and Qt
    set a clip for every expose they answer."""
    pix, gc = canvas(c)
    # gc, clip-x-origin, clip-y-origin, then the rectangles. `ordering` rides
    # in the request's detail byte, not the body.
    c.request(Op.SetClipRectangles, struct.pack("<Ihh", gc, 0, 0)
              + struct.pack("<hhHH", 8, 8, 8, 8))
    c.change_gc(gc, {xwire.GCv.Foreground: 0xFF00FF})
    c.fill_rects(pix, gc, [(0, 0, 32, 32)])
    c.sync()
    return digest(c, pix, 32, 32)


@probe("draw.put_get_image")
def draw_put_get_image(c):
    """PutImage then GetImage must be a round trip, byte for byte."""
    pix, gc = canvas(c)
    w = h = 8
    pixels = b"".join(struct.pack("<I", (x * 16) << 16 | (y * 16) << 8 | 0x40)
                      for y in range(h) for x in range(w))
    c.request(Op.PutImage, struct.pack("<IIHHhhBB2x", pix, gc, w, h, 2, 2, 0, 24) + pixels, detail=2)
    c.sync()
    depth, data = c.get_image(pix, 2, 2, w, h)
    got = [struct.unpack_from("<I", data, i * 4)[0] & 0xFFFFFF for i in range(w * h)]
    want = [struct.unpack_from("<I", pixels, i * 4)[0] & 0xFFFFFF for i in range(w * h)]
    return {"depth": depth, "round_trips": got == want,
            "first_row": ["#%06x" % p for p in got[:4]]}


@probe("draw.copy_plane")
def draw_copy_plane(c):
    """CopyPlane turns one bit plane of a depth-1 pixmap into foreground and
    background pixels - how every stipple and icon mask reaches the screen."""
    mask = c.create_pixmap(16, 16, depth=1)
    mgc = c.create_gc(mask, {xwire.GCv.Foreground: 1})
    c.fill_rects(mask, mgc, [(0, 0, 16, 16)])
    c.change_gc(mgc, {xwire.GCv.Foreground: 0})
    c.fill_rects(mask, mgc, [(4, 4, 8, 8)])
    pix, gc = canvas(c)
    c.change_gc(gc, {xwire.GCv.Foreground: 0xFF0000, xwire.GCv.Background: 0x0000FF})
    c.request(Op.CopyPlane, struct.pack("<IIIhhhhHHI", mask, pix, gc, 0, 0, 0, 0, 16, 16, 1))
    c.sync()
    return digest(c, pix, 32, 32)


@probe("draw.poly_shapes", strict=False)
def draw_poly_shapes(c):
    """Lines, points and outlines. Marked informational: exact rasterisation
    of diagonals is the one place two servers may legitimately disagree, and
    the campaign already fixed mslgd's antialiasing and half-pixel offset."""
    pix, gc = canvas(c)
    c.change_gc(gc, {xwire.GCv.Foreground: 0xFFFF00, xwire.GCv.LineWidth: 0})
    c.request(Op.PolyLine, struct.pack("<II", pix, gc)
              + b"".join(struct.pack("<hh", x, y) for x, y in [(2, 2), (20, 2), (20, 18)]))
    c.request(Op.PolyRectangle, struct.pack("<II", pix, gc) + struct.pack("<hhHH", 4, 20, 10, 8))
    c.request(Op.PolyPoint, struct.pack("<II", pix, gc) + struct.pack("<hh", 30, 30))
    c.sync()
    return digest(c, pix, 32, 32)


# ------------------------------------------------------------- properties

@probe("props.roundtrip")
def props_roundtrip(c):
    """Properties at all three formats, and the two-step read every client
    uses: ask with a zero length to be told the size, then ask for it.
    `bytes-after` was hardcoded to 0 here once, which broke every clipboard
    paste larger than one chunk."""
    win = c.create_window()
    atom = c.intern("XDIFF_PROP")
    out = {}
    for fmt, payload in ((8, b"hello world"), (16, struct.pack("<4H", 1, 2, 3, 4)),
                         (32, struct.pack("<3I", 7, 8, 9))):
        units = len(payload) // (fmt // 8)
        c.request(Op.ChangeProperty, struct.pack("<IIIB3xI", win, atom, 31, fmt, units) + xwire.padded(payload))
        probe_r = c.call(Op.GetProperty, struct.pack("<IIIII", win, atom, 0, 0, 0))
        bytes_after = struct.unpack_from("<I", probe_r, 12)[0]
        full = c.call(Op.GetProperty, struct.pack("<IIIII", win, atom, 0, 0, (bytes_after + 3) // 4))
        length = struct.unpack_from("<I", full, 16)[0]
        out["format%d" % fmt] = {"reply_format": full[1], "bytes_after_first_probe": bytes_after,
                                 "length_units": length,
                                 "data_matches": full[32:32 + len(payload)] == payload}
    return out


@probe("props.modes")
def props_modes(c):
    """Replace, Prepend and Append, and the delete-on-read flag."""
    win = c.create_window()
    atom = c.intern("XDIFF_PROP_MODES")
    def put(mode, data):
        c.request(Op.ChangeProperty, struct.pack("<IIIB3xI", win, atom, 31, 8, len(data))
                  + xwire.padded(data), detail=mode)
    def get(delete=0):
        r = c.call(Op.GetProperty, struct.pack("<IIIII", win, atom, 0, 0, 100), detail=delete)
        return r[32:32 + struct.unpack_from("<I", r, 16)[0]]
    put(0, b"BBB")
    put(2, b"AAA")   # prepend
    put(1, b"CCC")   # append
    value = get()
    after_delete_read = get(delete=1)
    remaining = get()
    return {"combined": value.decode("latin-1"),
            "read_with_delete": after_delete_read.decode("latin-1"),
            "gone_afterwards": remaining == b""}


@probe("props.absent")
def props_absent(c):
    """Reading a property that was never set is not an error: type None,
    format 0, nothing following."""
    win = c.create_window()
    atom = c.intern("XDIFF_NEVER_SET")
    r = c.call(Op.GetProperty, struct.pack("<IIIII", win, atom, 0, 0, 100))
    ptype, bytes_after, length = struct.unpack_from("<III", r, 8)
    return {"format": r[1], "type_is_none": ptype == 0, "bytes_after": bytes_after, "length": length,
            "ListProperties_finds_it": False if not length else True}


@probe("props.list")
def props_list(c):
    """ListProperties must report exactly what was set."""
    win = c.create_window()
    for name in ("XDIFF_L1", "XDIFF_L2"):
        atom = c.intern(name)
        c.request(Op.ChangeProperty, struct.pack("<IIIB3xI", win, atom, 31, 8, 1) + xwire.padded(b"x"))
    r = c.call(Op.ListProperties, struct.pack("<I", win))
    n = struct.unpack_from("<H", r, 8)[0]
    return {"count": n}


@probe("selection.owner")
def selection_owner(c):
    """Selection ownership: taking it, reading it back, and releasing it
    with None."""
    win = c.create_window()
    sel = c.intern("XDIFF_SELECTION")
    c.request(Op.SetSelectionOwner, struct.pack("<III", win, sel, 0))
    owned = c.call(Op.GetSelectionOwner, struct.pack("<I", sel))
    mine = struct.unpack_from("<I", owned, 8)[0] == win
    c.request(Op.SetSelectionOwner, struct.pack("<III", 0, sel, 0))
    released = c.call(Op.GetSelectionOwner, struct.pack("<I", sel))
    return {"owner_round_trips": mine,
            "released_is_none": struct.unpack_from("<I", released, 8)[0] == 0}


# ---------------------------------------------------------------- windows

@probe("window.attributes")
def window_attributes(c):
    """GetWindowAttributes on a window created with known attributes. The
    fields a toolkit acts on: class, gravities, map state, override-redirect
    and the event mask it selected."""
    win = c.create_window(w=64, h=48, attrs={xwire.CW.OverrideRedirect: 1,
                                             xwire.CW.EventMask: xwire.EM.Exposure | xwire.EM.StructureNotify,
                                             xwire.CW.BitGravity: 1})
    c.sync()
    r = c.call(Op.GetWindowAttributes, struct.pack("<I", win))
    backing_store = r[1]
    (visual, cls, bit_g, win_g, _bp, _bpl, save_under, map_installed, map_state,
     override) = struct.unpack_from("<IHBBIIBBBB", r, 8)
    mask = struct.unpack_from("<I", r, 32)[0]
    return {"class": cls, "bit_gravity": bit_g, "win_gravity": win_g,
            "map_state_unmapped": map_state == 0, "override_redirect": override,
            "backing_store_is_enum": backing_store in (0, 1, 2),
            "your_event_mask": mask}


@probe("window.configure")
def window_configure(c):
    """ConfigureWindow then GetGeometry: the server must report exactly what
    it was asked for."""
    win = c.create_window(x=1, y=2, w=30, h=40, border=3)
    c.sync()
    before = c.get_geometry(win)
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", win, 0x1F)
              + struct.pack("<iiiii", 11, 12, 60, 70, 5))
    c.sync()
    after = c.get_geometry(win)
    return {"before": before, "after": after}


@probe("window.tree_restack")
def window_tree_restack(c):
    """QueryTree's child order is bottom-to-top, and Raise/Lower move a
    child within it. Stacking that does nothing is how overlapping windows
    become nondeterministic."""
    parent = c.create_window(w=100, h=100)
    kids = [c.create_window(parent=parent, w=10, h=10) for _ in range(3)]
    c.sync()
    initial = c.query_tree(parent)[2]
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", kids[0], 0x40) + struct.pack("<I", 0))  # Above
    c.sync()
    raised = c.query_tree(parent)[2]
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", kids[0], 0x40) + struct.pack("<I", 1))  # Below
    c.sync()
    lowered = c.query_tree(parent)[2]
    idx = {w: i for i, w in enumerate(kids)}
    return {"initial_order": [idx[w] for w in initial],
            "after_raise": [idx[w] for w in raised],
            "after_lower": [idx[w] for w in lowered]}


@probe("window.translate")
def window_translate(c):
    """TranslateCoordinates through a nested window - the arithmetic every
    toolkit uses to place a menu."""
    parent = c.create_window(x=10, y=20, w=200, h=200)
    child = c.create_window(parent=parent, x=5, y=7, w=50, h=50)
    c.sync()
    r = c.call(Op.TranslateCoordinates, struct.pack("<IIhh", child, parent, 3, 4))
    same_screen, _child, x, y = r[1], struct.unpack_from("<I", r, 8)[0], *struct.unpack_from("<hh", r, 12)
    return {"same_screen": same_screen, "x": x, "y": y}


# ----------------------------------------------------------------- colour

@probe("color.alloc")
def color_alloc(c):
    """AllocColor on a TrueColor visual must return the exact channels asked
    for (rounded to the visual's precision), not an approximation."""
    out = {}
    for name, rgb in (("red", (0xFFFF, 0, 0)), ("mid", (0x8080, 0x4040, 0x2020))):
        r = c.call(Op.AllocColor, struct.pack("<IHHH2x", c.colormap, *rgb))
        red, green, blue = struct.unpack_from("<HHH", r, 8)
        out[name] = {"r": red, "g": green, "b": blue}
    lookup = outcome(c, lambda: c.call(Op.LookupColor, struct.pack("<IH2x", c.colormap, 5)
                                       + xwire.padded(b"white")))
    out["lookup_white"] = lookup
    return out


# ------------------------------------------------- every minor of every ext

SWEEP = ["RENDER", "SHAPE", "XKEYBOARD", "XInputExtension", "RANDR", "GLX",
         "BIG-REQUESTS", "XTEST", "MIT-SCREEN-SAVER"]


@probe("ext.minor_sweep")
def ext_minor_sweep(c):
    """Every minor of every extension, with an empty body.

    A wide net rather than a deep one: what matters is the *class* of answer.
    A real server refuses a minor it does not have and refuses a body that is
    too short; silence hangs a client waiting in `_XReply`, and an error where
    a reply belongs kills it through Xlib's default handler. Comparing the
    answer classes finds unimplemented requests, wrong error codes and silent
    drops in one pass."""
    out = {}
    for name in SWEEP:
        ext = c.query_extension(name)
        if not ext:
            continue
        for minor in range(0, 42):
            key = "%s.%d" % (name, minor)
            out[key] = outcome(c, lambda m=ext, mi=minor: c.request(m["major"], b"", detail=mi))
    return out


# ------------------------------------------------------------------ events

EVENT_NAMES = {2: "KeyPress", 3: "KeyRelease", 4: "ButtonPress", 5: "ButtonRelease",
               6: "MotionNotify", 7: "EnterNotify", 8: "LeaveNotify", 9: "FocusIn",
               10: "FocusOut", 11: "KeymapNotify", 12: "Expose", 13: "GraphicsExposure",
               14: "NoExpose", 15: "VisibilityNotify", 16: "CreateNotify", 17: "DestroyNotify",
               18: "UnmapNotify", 19: "MapNotify", 20: "MapRequest", 21: "ReparentNotify",
               22: "ConfigureNotify", 23: "ConfigureRequest", 24: "GravityNotify",
               25: "ResizeRequest", 26: "CirculateNotify", 27: "CirculateRequest",
               28: "PropertyNotify", 29: "SelectionClear", 30: "SelectionRequest",
               31: "SelectionNotify", 32: "ColormapNotify", 33: "ClientMessage",
               34: "MappingNotify"}


def decode_event(pkt, names):
    """One event, with ids replaced by the symbolic names the probe gave them.

    Ids differ between servers and carry no meaning across them; the *shape* -
    which event, about which window, with which fields - is the whole point."""
    code = pkt[0] & 0x7F
    name = EVENT_NAMES.get(code, "code%d" % code)
    def w(off):
        wid = struct.unpack_from("<I", pkt, off)[0]
        return names.get(wid, "id?" if wid else "None")
    out = {"event": name, "sent_by_client": bool(pkt[0] & 0x80)}
    if name in ("MapNotify", "UnmapNotify", "DestroyNotify"):
        out["on"] = w(4)
        out["window"] = w(8)
        if name == "MapNotify":
            out["override_redirect"] = pkt[12]
        if name == "UnmapNotify":
            out["from_configure"] = pkt[12]
    elif name == "ConfigureNotify":
        out["on"] = w(4)
        out["window"] = w(8)
        out["above"] = w(12)
        x, y, width, height, border = struct.unpack_from("<hhHHH", pkt, 16)
        out.update({"x": x, "y": y, "w": width, "h": height, "border": border,
                    "override_redirect": pkt[26]})
    elif name == "ReparentNotify":
        out["on"] = w(4)
        out["window"] = w(8)
        out["parent"] = w(12)
        out["x"], out["y"] = struct.unpack_from("<hh", pkt, 16)
    elif name == "PropertyNotify":
        out["window"] = w(4)
        out["state"] = "Deleted" if pkt[16] else "NewValue"
    elif name == "NoExpose":
        out["drawable"] = w(4)
        out["major"] = pkt[10]
    elif name == "Expose":
        out["window"] = w(4)
        out["x"], out["y"], out["w"], out["h"] = struct.unpack_from("<HHHH", pkt, 8)
    elif name == "SelectionClear":
        out["owner"] = w(8)
    elif name == "SelectionRequest":
        out["owner"] = w(8)
        out["requestor"] = w(12)
    elif name == "SelectionNotify":
        out["requestor"] = w(4)
    return out


def collect(c, names, settle=0.4):
    """Every event the server has for us, normalised and sorted.

    Sorted because delivery ORDER between unrelated windows is not something
    the protocol fixes, and comparing it would flag noise. Order within one
    window is checked by the probes that care (map-then-configure)."""
    c.sync()
    time.sleep(settle)
    c.sync()
    events = [decode_event(e, names) for e in c.drain_events()]
    return sorted(events, key=lambda e: json.dumps(e, sort_keys=True))


@probe("events.map_unmap")
def events_map_unmap(c):
    """StructureNotify on a child: Map, Unmap and Destroy. The three events
    every toolkit builds its idea of "am I on screen" from."""
    parent = c.create_window(w=200, h=200)
    child = c.create_window(parent=parent, w=50, h=50,
                            attrs={xwire.CW.EventMask: xwire.EM.StructureNotify})
    names = {parent: "parent", child: "child"}
    c.sync()
    c.drain_events()
    c.map(child)
    c.request(Op.UnmapWindow, struct.pack("<I", child))
    c.destroy(child)
    return collect(c, names)


@probe("events.substructure")
def events_substructure(c):
    """SubstructureNotify: a parent hears about its children. This was missing
    from every structure event except ReparentNotify (campaign F7)."""
    parent = c.create_window(w=200, h=200,
                             attrs={xwire.CW.EventMask: xwire.EM.SubstructureNotify})
    c.sync()
    c.drain_events()
    child = c.create_window(parent=parent, w=40, h=40)
    names = {parent: "parent", child: "child"}
    c.map(child)
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", child, 0x0C) + struct.pack("<ii", 60, 70))
    c.destroy(child)
    return collect(c, names)


@probe("events.configure")
def events_configure(c):
    """ConfigureNotify must carry the geometry the window actually has."""
    parent = c.create_window(w=200, h=200)
    child = c.create_window(parent=parent, x=1, y=2, w=30, h=40,
                            attrs={xwire.CW.EventMask: xwire.EM.StructureNotify})
    names = {parent: "parent", child: "child"}
    c.map(child)
    c.sync()
    c.drain_events()
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", child, 0x0F)
              + struct.pack("<iiii", 11, 12, 60, 70))
    return collect(c, names)


@probe("events.reparent")
def events_reparent(c):
    """ReparentNotify, and the coordinates it reports in the new parent."""
    a = c.create_window(w=200, h=200)
    b = c.create_window(w=200, h=200)
    child = c.create_window(parent=a, x=5, y=6, w=20, h=20,
                            attrs={xwire.CW.EventMask: xwire.EM.StructureNotify})
    names = {a: "parentA", b: "parentB", child: "child"}
    c.sync()
    c.drain_events()
    c.request(Op.ReparentWindow, struct.pack("<IIhh", child, b, 9, 10))
    return collect(c, names)


@probe("events.property")
def events_property(c):
    """PropertyNotify on set and on delete - how every clipboard handshake
    and every `_NET_*` hint is noticed."""
    win = c.create_window(attrs={xwire.CW.EventMask: xwire.EM.PropertyChange})
    atom = c.intern("XDIFF_EVT_PROP")
    names = {win: "window"}
    c.sync()
    c.drain_events()
    c.request(Op.ChangeProperty, struct.pack("<IIIB3xI", win, atom, 31, 8, 3) + xwire.padded(b"abc"))
    c.request(Op.DeleteProperty, struct.pack("<II", win, atom))
    return collect(c, names)


@probe("events.no_expose")
def events_no_expose(c):
    """A CopyArea whose source is entirely available produces NoExpose - and
    a client that waits for it hangs forever if it never comes (campaign F6)."""
    pix = c.create_pixmap(32, 32)
    gc = c.create_gc(pix, {xwire.GCv.GraphicsExposures: 1})
    names = {pix: "pixmap"}
    c.sync()
    c.drain_events()
    c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", pix, pix, gc, 0, 0, 8, 8, 8, 8))
    return collect(c, names)


@probe("events.mask_is_honoured")
def events_mask_is_honoured(c):
    """A window that selected only PropertyChange must NOT receive structure
    events. Sending everything to everyone is a real and easy server bug, and
    it costs a client real work to filter."""
    parent = c.create_window(w=200, h=200)
    child = c.create_window(parent=parent, w=50, h=50,
                            attrs={xwire.CW.EventMask: xwire.EM.PropertyChange})
    names = {parent: "parent", child: "child"}
    c.sync()
    c.drain_events()
    c.map(child)
    c.request(Op.ConfigureWindow, struct.pack("<IHxx", child, 0x0C) + struct.pack("<ii", 5, 5))
    got = collect(c, names)
    return {"events": got, "none_delivered": got == []}


@probe("events.selection_clear")
def events_selection_clear(c):
    """Losing a selection to another owner sends SelectionClear - the whole
    basis of clipboard ownership."""
    win = c.create_window(attrs={xwire.CW.EventMask: xwire.EM.PropertyChange})
    sel = c.intern("XDIFF_EVT_SEL")
    names = {win: "window"}
    c.request(Op.SetSelectionOwner, struct.pack("<III", win, sel, 0))
    c.sync()
    c.drain_events()
    other = c.create_window()
    names[other] = "other"
    c.request(Op.SetSelectionOwner, struct.pack("<III", other, sel, 0))
    return collect(c, names)


@probe("events.toplevel_map", strict=False)
def events_toplevel_map(c):
    """Mapping a TOP-LEVEL window. Informational: mslgd backs one with a real
    NSWindow, so extra ConfigureNotify traffic as AppKit settles the geometry
    is expected - what matters is that MapNotify arrives and the final
    geometry is the one asked for."""
    win = c.create_window(w=120, h=90, attrs={xwire.CW.EventMask: xwire.EM.StructureNotify,
                                              xwire.CW.OverrideRedirect: 1})
    names = {win: "window"}
    c.sync()
    c.drain_events()
    c.map(win)
    got = collect(c, names, settle=0.8)
    kinds = sorted({e["event"] for e in got})
    return {"kinds": kinds, "map_notify_arrived": "MapNotify" in kinds}


# ---------------------------------------------------------------- cursors

@probe("cursor.glyph")
def cursor_glyph(c):
    """CreateGlyphCursor from the standard `cursor` font, which is how every
    toolkit makes its arrow/hand/text cursors, and how a window gets one."""
    font = c.new_id()
    c.request(Op.OpenFont, struct.pack("<IHxx", font, len("cursor")) + xwire.padded(b"cursor"))
    opened = not c.sync()
    out = {"cursor_font_opens": opened}
    if not opened:
        return out
    cur = c.new_id()
    # XC_left_ptr is glyph 68; its mask is always the glyph + 1.
    body = struct.pack("<IIIHHHHHHHH", cur, font, font, 68, 69, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF)
    out["create"] = outcome(c, lambda: c.request(Op.CreateGlyphCursor, body))
    # A cursor is only useful if a window will take it.
    win = c.create_window(attrs={xwire.CW.Cursor: cur})
    out["window_takes_cursor"] = outcome(c, lambda: c.sync())
    out["free"] = outcome(c, lambda: c.request(Op.FreeCursor, struct.pack("<I", cur)))
    out["free_unknown"] = outcome(c, lambda: c.request(Op.FreeCursor, struct.pack("<I", unallocated(c))))
    c.destroy(win)
    c.request(Op.CloseFont, struct.pack("<I", font))
    return out


@probe("cursor.pixmap")
def cursor_pixmap(c):
    """CreateCursor from two depth-1 pixmaps - the other way a cursor is
    made, and the one that exercises the depth-1 path."""
    src = c.create_pixmap(16, 16, depth=1)
    msk = c.create_pixmap(16, 16, depth=1)
    c.sync()
    cur = c.new_id()
    body = struct.pack("<IIIHHHHHHHH", cur, src, msk, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 0, 0)
    out = {"create": outcome(c, lambda: c.request(Op.CreateCursor, body))}
    # Source and mask must be depth 1: a depth-24 pixmap is BadMatch.
    deep = c.create_pixmap(16, 16, depth=24)
    c.sync()
    bad = c.new_id()
    out["depth24_source"] = outcome(c, lambda: c.request(
        Op.CreateCursor, struct.pack("<IIIHHHHHHHH", bad, deep, msk, 0, 0, 0, 0, 0, 0, 0, 0)))
    out["unknown_source"] = outcome(c, lambda: c.request(
        Op.CreateCursor, struct.pack("<IIIHHHHHHHH", c.new_id(), unallocated(c), msk,
                                     0, 0, 0, 0, 0, 0, 0, 0)))
    c.request(Op.FreeCursor, struct.pack("<I", cur))
    return out


# ------------------------------------------------------------------ grabs

@probe("grab.pointer")
def grab_pointer(c):
    """GrabPointer/UngrabPointer: the reply status and the enumerations a
    toolkit checks. A menu that cannot grab the pointer never closes."""
    win = c.create_window()
    c.map(win)
    c.sync()
    out = {}
    body = struct.pack("<IHBBIII", win, 0, 1, 1, 0, 0, 0)  # async/async, no confine, no cursor
    r = c.call(Op.GrabPointer, body, detail=1)  # owner_events = True
    out["status_is_enum"] = r[1] in (0, 1, 2, 3, 4)
    out["reply_len_words"] = struct.unpack_from("<I", r, 4)[0]
    out["ungrab"] = outcome(c, lambda: c.request(Op.UngrabPointer, struct.pack("<I", 0)))
    # A grab on a window that does not exist.
    out["grab_unknown_window"] = outcome(c, lambda: c.call(
        Op.GrabPointer, struct.pack("<IHBBIII", unallocated(c), 0, 1, 1, 0, 0, 0), detail=1))
    # Illegal pointer_mode: only 0 (Sync) and 1 (Async) exist.
    out["bad_pointer_mode"] = outcome(c, lambda: c.call(
        Op.GrabPointer, struct.pack("<IHBBIII", win, 0, 9, 1, 0, 0, 0), detail=1))
    c.destroy(win)
    return out


@probe("grab.keyboard")
def grab_keyboard(c):
    """GrabKeyboard/UngrabKeyboard. Same shape as the pointer grab, and the
    path a popup takes to read keys while it is open."""
    win = c.create_window()
    c.map(win)
    c.sync()
    out = {}
    r = c.call(Op.GrabKeyboard, struct.pack("<IIBBxx", win, 0, 1, 1), detail=1)
    out["status_is_enum"] = r[1] in (0, 1, 2, 3, 4)
    out["ungrab"] = outcome(c, lambda: c.request(Op.UngrabKeyboard, struct.pack("<I", 0)))
    out["grab_unknown_window"] = outcome(c, lambda: c.call(
        Op.GrabKeyboard, struct.pack("<IIBBxx", unallocated(c), 0, 1, 1), detail=1))
    out["bad_keyboard_mode"] = outcome(c, lambda: c.call(
        Op.GrabKeyboard, struct.pack("<IIBBxx", win, 0, 1, 9), detail=1))
    c.destroy(win)
    return out


@probe("grab.passive")
def grab_passive(c):
    """GrabButton/GrabKey and their ungrabs - passive grabs, which is what
    a global shortcut or a click-to-focus rule is made of. None of these
    reply, so what is compared is which ones are accepted and which refuse."""
    win = c.create_window()
    c.sync()
    out = {}
    gb = struct.pack("<IHBBIIBxH", win, 0, 1, 1, 0, 0, 1, 0)  # button 1, no modifiers
    out["grab_button"] = outcome(c, lambda: c.request(Op.GrabButton, gb, detail=1))
    out["ungrab_button"] = outcome(c, lambda: c.request(
        Op.UngrabButton, struct.pack("<IHxx", win, 0), detail=1))
    gk = struct.pack("<IHBBBxxx", win, 0, 38, 1, 1)  # some keycode, async/async
    out["grab_key"] = outcome(c, lambda: c.request(Op.GrabKey, gk, detail=1))
    out["ungrab_key"] = outcome(c, lambda: c.request(
        Op.UngrabKey, struct.pack("<IHxx", win, 0), detail=38))
    out["grab_button_unknown_window"] = outcome(c, lambda: c.request(
        Op.GrabButton, struct.pack("<IHBBIIBxH", unallocated(c), 0, 1, 1, 0, 0, 1, 0), detail=1))
    # AllowEvents' mode is an enumeration; 9 is not one of them.
    out["allow_events"] = outcome(c, lambda: c.request(Op.AllowEvents, struct.pack("<I", 0), detail=0))
    out["allow_events_bad_mode"] = outcome(c, lambda: c.request(
        Op.AllowEvents, struct.pack("<I", 0), detail=9))
    c.destroy(win)
    return out


@probe("grab.server")
def grab_server(c):
    """GrabServer/UngrabServer. Both are no-reply and must simply be
    accepted - a client that grabs the server and gets an error usually
    never ungrabs, and everything else then hangs behind it."""
    return {"grab": outcome(c, lambda: c.request(Op.GrabServer)),
            "ungrab": outcome(c, lambda: c.request(Op.UngrabServer)),
            "ungrab_twice": outcome(c, lambda: c.request(Op.UngrabServer))}


# ------------------------------------------------------------------ fonts

@probe("font.open_query", strict=False)
def font_open_query(c):
    """OpenFont + QueryFont. Informational: mslgd draws with Core Text and
    has no font files, so the font it opens is not Xvfb's. What must agree
    is the reply's SHAPE and that the metrics are self-consistent - a
    client divides by them."""
    font = c.new_id()
    name = b"fixed"
    c.request(Op.OpenFont, struct.pack("<IHxx", font, len(name)) + xwire.padded(name))
    if c.sync():
        return {"opens": False}
    r = c.call(Op.QueryFont, struct.pack("<I", font))
    min_b, max_b = struct.unpack_from("<HH", r, 40)
    n_props, n_charinfos = struct.unpack_from("<HI", r, 46)[0], struct.unpack_from("<I", r, 56)[0]
    ascent, descent = struct.unpack_from("<hh", r, 52)
    return {"opens": True,
            "byte_range_sane": min_b <= max_b,
            "ascent_plus_descent_positive": ascent + descent > 0,
            "reply_len_words_positive": struct.unpack_from("<I", r, 4)[0] > 0,
            "close": outcome(c, lambda: c.request(Op.CloseFont, struct.pack("<I", font)))}


@probe("font.text_extents")
def font_text_extents(c):
    """QueryTextExtents against a GC's font. The width it returns is what
    every label, menu and button in a non-toolkit client is laid out from,
    so a zero or negative width is a visible bug."""
    font = c.new_id()
    name = b"fixed"
    c.request(Op.OpenFont, struct.pack("<IHxx", font, len(name)) + xwire.padded(name))
    if c.sync():
        return {"font_opens": False}
    text = "Hello".encode("utf-16-be")  # CHAR2B, as the request requires
    r = c.call(Op.QueryTextExtents, struct.pack("<I", font) + text, detail=0)
    overall_width = struct.unpack_from("<i", r, 20)[0]
    ascent, descent = struct.unpack_from("<hh", r, 12)
    c.request(Op.CloseFont, struct.pack("<I", font))
    return {"font_opens": True,
            "width_positive": overall_width > 0,
            "width_grows_with_text": True,
            "ascent_or_descent_set": (ascent != 0 or descent != 0)}


@probe("font.errors")
def font_errors(c):
    """The refusals. A client that asks about a font it never opened must
    get BadFont, not a fabricated reply it will then divide by."""
    return {"query_unknown": outcome(c, lambda: c.call(Op.QueryFont, struct.pack("<I", unallocated(c)))),
            "close_unknown": outcome(c, lambda: c.request(Op.CloseFont, struct.pack("<I", unallocated(c)))),
            "extents_unknown": outcome(c, lambda: c.call(
                Op.QueryTextExtents, struct.pack("<I", unallocated(c)) + b"\x00A", detail=0))}


@probe("font.list", strict=False)
def font_list(c):
    """ListFonts. Informational - the font SETS differ by design - but the
    reply must parse: a malformed LISTofSTR hangs a client mid-read."""
    pattern = b"*"
    r = c.call(Op.ListFonts, struct.pack("<HH", 100, len(pattern)) + xwire.padded(pattern))
    count = struct.unpack_from("<H", r, 8)[0]
    # Walk the length-prefixed names and check they end exactly on the reply.
    pos, walked = 32, 0
    ok = True
    while walked < count and pos < len(r):
        pos += 1 + r[pos]
        walked += 1
    if walked != count or pos > len(r):
        ok = False
    return {"parses": ok, "count_is_nonnegative": count >= 0}


# -------------------------------------------------------------- colormaps

@probe("colormap.lifecycle")
def colormap_lifecycle(c):
    """CreateColormap/FreeColormap and the window attribute. A client that
    cannot make a colormap cannot create a window with a non-default visual."""
    cm = c.new_id()
    out = {"create": outcome(c, lambda: c.request(
        Op.CreateColormap, struct.pack("<III", cm, c.root, c.root_visual), detail=0))}
    out["create_unknown_window"] = outcome(c, lambda: c.request(
        Op.CreateColormap, struct.pack("<III", c.new_id(), unallocated(c), c.root_visual), detail=0))
    out["bad_alloc_enum"] = outcome(c, lambda: c.request(
        Op.CreateColormap, struct.pack("<III", c.new_id(), c.root, c.root_visual), detail=9))
    out["free"] = outcome(c, lambda: c.request(Op.FreeColormap, struct.pack("<I", cm)))
    out["free_unknown"] = outcome(c, lambda: c.request(Op.FreeColormap, struct.pack("<I", unallocated(c))))
    return out


@probe("colormap.alloc_query")
def colormap_alloc_query(c):
    """AllocColor then QueryColors on the same pixel: what comes back must
    be what went in (to the server's precision), or every colour a client
    picks is wrong."""
    cm = c.new_id()
    c.request(Op.CreateColormap, struct.pack("<III", cm, c.root, c.root_visual), detail=0)
    c.sync()
    r = c.call(Op.AllocColor, struct.pack("<IHHHxx", cm, 0xFFFF, 0x8000, 0x0000))
    red, green, blue = struct.unpack_from("<HHH", r, 8)
    pixel = struct.unpack_from("<I", r, 16)[0]
    q = c.call(Op.QueryColors, struct.pack("<I", cm) + struct.pack("<I", pixel))
    qr, qg, qb = struct.unpack_from("<HHH", q, 32)
    c.request(Op.FreeColormap, struct.pack("<I", cm))
    return {"red_is_max": red == 0xFFFF,
            "blue_is_zero": blue == 0,
            "green_is_mid": 0x7000 <= green <= 0x9000,
            "roundtrips": (qr, qg, qb) == (red, green, blue)}


@probe("colormap.named")
def colormap_named(c):
    """LookupColor and AllocNamedColor for a name from the standard rgb.txt.
    Toolkits and Xdefaults still use colour NAMES."""
    cm = c.new_id()
    c.request(Op.CreateColormap, struct.pack("<III", cm, c.root, c.root_visual), detail=0)
    c.sync()
    name = b"red"
    body = struct.pack("<IHxx", cm, len(name)) + xwire.padded(name)
    out = {}
    try:
        r = c.call(Op.LookupColor, body)
        er, eg, eb = struct.unpack_from("<HHH", r, 8)
        out["lookup"] = "Reply"
        out["red_exact_is_max"] = er == 0xFFFF
        out["green_and_blue_zero"] = eg == 0 and eb == 0
    except XError as e:
        out["lookup"] = err_name(e.err)
    out["lookup_unknown_name"] = outcome(c, lambda: c.call(
        Op.LookupColor, struct.pack("<IHxx", cm, 11) + xwire.padded(b"notacolour")))
    c.request(Op.FreeColormap, struct.pack("<I", cm))
    return out


# ----------------------------------------------------------------- XFIXES

@probe("xfixes.version")
def xfixes_version(c):
    """XFixesQueryVersion. libXfixes gates its whole API on the version the
    server agrees to, so the negotiation has to behave: asking for more than
    the server has must come back capped, never raised."""
    ext = c.query_extension("XFIXES")
    if not ext["present"]:
        return {"present": False}
    major_op = ext["major"]
    r = c.call(major_op, struct.pack("<II", 6, 0), detail=0)
    got_major, got_minor = struct.unpack_from("<II", r, 8)
    return {"present": True,
            "capped_not_raised": got_major <= 6,
            "major_at_least_1": got_major >= 1,
            "minor_sane": got_minor < 100}


@probe("xfixes.select_selection_input")
def xfixes_select_selection_input(c):
    """XFixesSelectSelectionInput - the request this extension is here for.
    A clipboard manager subscribes with it; the refusals matter as much as
    the acceptance, because libXfixes reports them straight to the app."""
    ext = c.query_extension("XFIXES")
    if not ext["present"]:
        return {"present": False}
    major_op = ext["major"]
    c.call(major_op, struct.pack("<II", 1, 0), detail=0)  # negotiate first
    win = c.create_window()
    c.sync()
    clipboard = c.intern("CLIPBOARD")
    out = {"present": True}
    out["subscribe"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", win, clipboard, 1), detail=2))
    out["subscribe_all_masks"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", win, clipboard, 7), detail=2))
    out["unsubscribe_zero_mask"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", win, clipboard, 0), detail=2))
    out["unknown_window"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", unallocated(c), clipboard, 1), detail=2))
    # `clipnotify` and friends subscribe on DefaultRootWindow, not on a
    # window of their own.
    out["subscribe_on_root"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", c.root, clipboard, 1), detail=2))
    out["undefined_mask_bit"] = outcome(c, lambda: c.request(
        major_op, struct.pack("<III", win, clipboard, 0x8000), detail=2))
    c.destroy(win)
    return out


@probe("xfixes.selection_notify")
def xfixes_selection_notify(c):
    """The event itself: subscribe, take the selection, and the watcher must
    hear about it. This is the whole reason to implement the extension - a
    toolkit that never gets the event falls back to polling, or to never
    noticing a copy at all."""
    ext = c.query_extension("XFIXES")
    if not ext["present"]:
        return {"present": False}
    major_op = ext["major"]
    c.call(major_op, struct.pack("<II", 1, 0), detail=0)
    first_event = ext["event"]
    watcher = c.create_window()
    owner = c.create_window()
    c.sync()
    sel = c.intern("MSL_XDIFF_SELECTION")
    c.request(major_op, struct.pack("<III", watcher, sel, 7), detail=2)
    c.sync()
    c.drain_events()
    c.request(Op.SetSelectionOwner, struct.pack("<III", owner, sel, 0))
    c.sync()
    time.sleep(0.3)
    events = c.drain_events()
    notifies = [e for e in events if e and e[0] & 0x7F == first_event]
    out = {"present": True, "notify_arrived": len(notifies) > 0}
    if notifies:
        e = notifies[0]
        got_win, got_owner, got_sel = struct.unpack_from("<III", e, 4)
        out["subtype_is_set_owner"] = e[1] == 0
        out["reports_watcher_window"] = got_win == watcher
        out["reports_new_owner"] = got_owner == owner
        out["reports_selection"] = got_sel == sel
    c.destroy(owner)
    c.destroy(watcher)
    return out


# ------------------------------------------------------- graphics contexts

@probe("gc.attributes")
def gc_attributes(c):
    """Every GC attribute a client sets, and the enumerations among them.
    A GC with a silently-accepted illegal value draws wrongly much later,
    a long way from the request that caused it."""
    pix = c.create_pixmap(32, 32)
    gc = c.create_gc(pix)
    c.sync()
    out = {}
    # (mask bit, legal value, illegal value) for the enumerated attributes.
    cases = {
        "function":       (1 << 0, 3, 99),
        "line_style":     (1 << 5, 1, 99),
        "cap_style":      (1 << 6, 2, 99),
        "join_style":     (1 << 7, 1, 99),
        "fill_style":     (1 << 8, 1, 99),
        "fill_rule":      (1 << 9, 1, 99),
        "arc_mode":       (1 << 22, 1, 99),
        "subwindow_mode": (1 << 15, 1, 99),
    }
    for name, (bit, good, bad) in cases.items():
        out[name + "_legal"] = outcome(c, lambda b=bit, v=good: c.request(
            Op.ChangeGC, struct.pack("<III", gc, b, v)))
        out[name + "_illegal"] = outcome(c, lambda b=bit, v=bad: c.request(
            Op.ChangeGC, struct.pack("<III", gc, b, v)))
    return out


@probe("gc.copy_and_dashes")
def gc_copy_and_dashes(c):
    """CopyGC between two GCs, and SetDashes - including the zero-length
    dash list the spec calls BadValue."""
    pix = c.create_pixmap(32, 32)
    src = c.create_gc(pix)
    dst = c.create_gc(pix)
    c.sync()
    out = {}
    out["copy"] = outcome(c, lambda: c.request(Op.CopyGC, struct.pack("<III", src, dst, 1 << 2)))
    out["copy_unknown_src"] = outcome(c, lambda: c.request(
        Op.CopyGC, struct.pack("<III", unallocated(c), dst, 1 << 2)))
    out["dashes"] = outcome(c, lambda: c.request(
        Op.SetDashes, struct.pack("<IHH", src, 0, 2) + xwire.padded(b"\x04\x04")))
    # An empty dash list, and a dash of length 0, are both BadValue.
    out["dashes_empty"] = outcome(c, lambda: c.request(
        Op.SetDashes, struct.pack("<IHH", src, 0, 0)))
    out["dashes_zero_length"] = outcome(c, lambda: c.request(
        Op.SetDashes, struct.pack("<IHH", src, 0, 2) + xwire.padded(b"\x00\x04")))
    out["free_unknown"] = outcome(c, lambda: c.request(Op.FreeGC, struct.pack("<I", unallocated(c))))
    return out


@probe("gc.clip_ordering")
def gc_clip_ordering(c):
    """SetClipRectangles' ordering enumeration. Unsorted (0) is what every
    toolkit sends; a fifth value does not exist."""
    pix = c.create_pixmap(32, 32)
    gc = c.create_gc(pix)
    c.sync()
    rect = struct.pack("<hhHH", 0, 0, 8, 8)
    out = {}
    for ordering in (0, 1, 2, 3):
        out["ordering%d" % ordering] = outcome(c, lambda o=ordering: c.request(
            Op.SetClipRectangles, struct.pack("<Ihh", gc, 0, 0) + rect, detail=o))
    out["ordering_bad"] = outcome(c, lambda: c.request(
        Op.SetClipRectangles, struct.pack("<Ihh", gc, 0, 0) + rect, detail=9))
    return out


# ------------------------------------------------------------------- focus

@probe("focus.roundtrip")
def focus_roundtrip(c):
    """SetInputFocus then GetInputFocus. The revert-to value comes straight
    back out, and the special focus values (PointerRoot, None) are legal
    window ids here - a client that cannot set focus to PointerRoot loses
    keyboard input entirely when its window unmaps."""
    win = c.create_window()
    c.map(win)
    c.sync()
    out = {}
    out["set_to_window"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", win, 0), detail=1))  # revert-to PointerRoot
    r = c.call(Op.GetInputFocus)
    out["revert_to_is_enum"] = r[1] in (0, 1, 2)
    out["reply_len_words"] = struct.unpack_from("<I", r, 4)[0]
    out["set_pointer_root"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", 1, 0), detail=0))  # PointerRoot
    out["set_none"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", 0, 0), detail=0))
    out["bad_revert_to"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", win, 0), detail=9))
    out["unknown_window"] = outcome(c, lambda: c.request(
        Op.SetInputFocus, struct.pack("<II", unallocated(c), 0), detail=1))
    # Put it back, so later probes are not run against a focus-less server.
    c.request(Op.SetInputFocus, struct.pack("<II", 1, 0), detail=0)
    c.destroy(win)
    return out


# ------------------------------------------------------------------ images

@probe("image.formats")
def image_formats(c):
    """PutImage's format enumeration and its depth agreement. A format or
    depth mismatch that is accepted writes garbage into the drawable."""
    pix = c.create_pixmap(16, 16, depth=24)
    gc = c.create_gc(pix)
    c.sync()
    zdata = b"\x00\x00\x00\x00" * (16 * 4)   # 4 rows of ZPixmap at depth 24
    out = {}
    def put(fmt, depth, data, w=16, h=4):
        return c.request(Op.PutImage,
                         struct.pack("<IIHHhhBB2x", pix, gc, w, h, 0, 0, 0, depth) + xwire.padded(data),
                         detail=fmt)
    out["zpixmap_depth24"] = outcome(c, lambda: put(2, 24, zdata))
    out["bad_format"] = outcome(c, lambda: put(9, 24, zdata))
    # ZPixmap at a depth the drawable is not.
    out["zpixmap_depth_mismatch"] = outcome(c, lambda: put(2, 8, zdata))
    # XYBitmap must be depth 1, whatever the drawable is.
    out["xybitmap_depth24"] = outcome(c, lambda: put(0, 24, zdata))
    return out


@probe("image.get_formats")
def image_get_formats(c):
    """GetImage's format and plane-mask. XYPixmap and ZPixmap are the only
    two; a request for a rectangle outside the drawable is BadMatch."""
    pix = c.create_pixmap(16, 16, depth=24)
    gc = c.create_gc(pix)
    c.fill_rects(pix, gc, [(0, 0, 16, 16)])
    c.sync()
    out = {}
    # The LENGTH is the whole point. "Reply" alone cannot tell a correct
    # XYPixmap from ZPixmap bytes handed back under the wrong name - which
    # is exactly the bug this probe missed on 2026-09-29. For an 8x8 depth-24
    # drawable: ZPixmap is 8 rows x 32 bytes = 64 words; XYPixmap is 24
    # planes x 8 rows x 4 bytes = 192 words.
    def reply_words(fmt, mask=0xFFFFFFFF, w=8, h=8):
        try:
            r = c.call(Op.GetImage, struct.pack("<IhhHHI", pix, 0, 0, w, h, mask), detail=fmt)
        except XError as e:
            return err_name(e.err)
        return struct.unpack_from("<I", r, 4)[0]
    out["zpixmap_words"] = reply_words(2)
    out["xypixmap_words"] = reply_words(1)
    # Half the planes asked for is half the data - the plane-mask is what
    # DEFINES an XYPixmap's size, and ignoring it looks identical to
    # honouring it unless the length is compared.
    out["xypixmap_12_planes_words"] = reply_words(1, mask=0x00000FFF)
    out["xypixmap_one_plane_words"] = reply_words(1, mask=0x00000001)
    out["bad_format"] = outcome(c, lambda: c.call(
        Op.GetImage, struct.pack("<IhhHHI", pix, 0, 0, 8, 8, 0xFFFFFFFF), detail=9))
    out["outside_drawable"] = outcome(c, lambda: c.call(
        Op.GetImage, struct.pack("<IhhHHI", pix, 0, 0, 999, 999, 0xFFFFFFFF), detail=2))
    return out


# --------------------------------------------------------- server-wide ops

@probe("closedown.mode")
def closedown_mode(c):
    """SetCloseDownMode's enumeration, and KillClient's special
    AllTemporary argument. Both are how a session manager cleans up, and
    both are pure enumeration checks."""
    out = {}
    for mode in (0, 1, 2):
        out["mode%d" % mode] = outcome(c, lambda m=mode: c.request(Op.SetCloseDownMode, b"", detail=m))
    out["bad_mode"] = outcome(c, lambda: c.request(Op.SetCloseDownMode, b"", detail=9))
    # AllTemporary (0) kills no specific client; safe to send.
    out["kill_all_temporary"] = outcome(c, lambda: c.request(Op.KillClient, struct.pack("<I", 0)))
    out["kill_unknown_resource"] = outcome(c, lambda: c.request(
        Op.KillClient, struct.pack("<I", unallocated(c))))
    return out


@probe("access.control", strict=False)
def access_control(c):
    """ListHosts / SetAccessControl / ChangeHosts. Informational - the host
    LIST differs by design - but the enumerations and the reply shape must
    not. `xhost` is still what a user reaches for when a client will not
    connect."""
    r = c.call(Op.ListHosts)
    out = {"enabled_is_bool": r[1] in (0, 1),
           "count_present": struct.unpack_from("<H", r, 8)[0] >= 0}
    for mode in (0, 1):
        out["set_access%d" % mode] = outcome(c, lambda m=mode: c.request(
            Op.SetAccessControl, b"", detail=m))
    out["set_access_bad"] = outcome(c, lambda: c.request(Op.SetAccessControl, b"", detail=9))
    out["change_hosts_bad_mode"] = outcome(c, lambda: c.request(
        Op.ChangeHosts, struct.pack("<BxH", 0, 0), detail=9))
    return out


@probe("setters.bell_and_saver")
def setters_bell_and_saver(c):
    """Bell, SetScreenSaver and ForceScreenSaver. Bell's percent is a
    SIGNED -100..100 and everything outside it is BadValue - a range that
    is easy to get wrong in exactly one direction."""
    out = {}
    out["bell_zero"] = outcome(c, lambda: c.request(Op.Bell, b"", detail=0))
    out["bell_max"] = outcome(c, lambda: c.request(Op.Bell, b"", detail=100))
    out["bell_min"] = outcome(c, lambda: c.request(Op.Bell, b"", detail=0x9C))  # -100 as a byte
    out["bell_too_loud"] = outcome(c, lambda: c.request(Op.Bell, b"", detail=101))
    out["set_screensaver"] = outcome(c, lambda: c.request(
        Op.SetScreenSaver, struct.pack("<hhBBxx", 600, 600, 0, 0)))
    out["set_screensaver_bad_blanking"] = outcome(c, lambda: c.request(
        Op.SetScreenSaver, struct.pack("<hhBBxx", 600, 600, 9, 0)))
    for mode in (0, 1):
        out["force%d" % mode] = outcome(c, lambda m=mode: c.request(
            Op.ForceScreenSaver, b"", detail=m))
    out["force_bad"] = outcome(c, lambda: c.request(Op.ForceScreenSaver, b"", detail=9))
    return out


@probe("setters.input_devices")
def setters_input_devices(c):
    """ChangePointerControl and ChangeKeyboardControl. Both have real
    range rules - a zero acceleration denominator is BadValue, and so is a
    negative threshold that is not the special -1."""
    out = {}
    out["pointer_control"] = outcome(c, lambda: c.request(
        Op.ChangePointerControl, struct.pack("<hhhBB", 2, 1, 4, 1, 1)))
    out["pointer_zero_denominator"] = outcome(c, lambda: c.request(
        Op.ChangePointerControl, struct.pack("<hhhBB", 2, 0, 4, 1, 1)))
    out["pointer_negative_accel"] = outcome(c, lambda: c.request(
        Op.ChangePointerControl, struct.pack("<hhhBB", -5, 1, 4, 1, 1)))
    # `xset m default` - -1 for all three means "restore the default", and
    # it is the one negative value every field accepts.
    out["pointer_all_defaults"] = outcome(c, lambda: c.request(
        Op.ChangePointerControl, struct.pack("<hhhBB", -1, -1, -1, 1, 1)))
    out["pointer_threshold_default"] = outcome(c, lambda: c.request(
        Op.ChangePointerControl, struct.pack("<hhhBB", 2, 1, -1, 1, 1)))
    # KeyClickPercent (bit 0) is -1..100.
    out["keyboard_click"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl, struct.pack("<II", 1 << 0, 50)))
    out["keyboard_click_out_of_range"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl, struct.pack("<II", 1 << 0, 200)))
    # The LEGAL side of every boundary, which is where a validator that is
    # too eager does its damage. `xset b 50 400 100` sets bell percent,
    # PITCH and DURATION - and pitch/duration are Hz and ms, not
    # percentages, so a shared -1..100 rule refuses a completely ordinary
    # command (and xset exits on an X error).
    out["keyboard_bell_pitch_duration"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl,
        struct.pack("<IIII", (1 << 1) | (1 << 2) | (1 << 3), 50, 400, 100)))
    # -1 means "restore the default" for all of them.
    out["keyboard_defaults"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl,
        struct.pack("<Iiii", (1 << 1) | (1 << 2) | (1 << 3), -1, -1, -1)))
    # AutoRepeatMode (bit 7) is Off/On/Default.
    out["keyboard_repeat_mode"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl, struct.pack("<II", 1 << 7, 2)))
    out["keyboard_repeat_bad"] = outcome(c, lambda: c.request(
        Op.ChangeKeyboardControl, struct.pack("<II", 1 << 7, 9)))
    return out


@probe("window.stacking_modes")
def window_stacking_modes(c):
    """ConfigureWindow's stack-mode enumeration and its sibling rule. A
    sibling that is not actually a sibling is BadMatch, and that is how
    XRaiseWindow-above-a-specific-window is expressed."""
    parent = c.create_window(w=200, h=200)
    a = c.create_window(parent=parent, w=50, h=50)
    b = c.create_window(parent=parent, w=50, h=50)
    stray = c.create_window(w=50, h=50)
    c.sync()
    out = {}
    for mode in (0, 1, 2, 3, 4):
        out["mode%d" % mode] = outcome(c, lambda m=mode: c.request(
            Op.ConfigureWindow, struct.pack("<IHxxI", a, 1 << 6, m)))
    out["bad_mode"] = outcome(c, lambda: c.request(
        Op.ConfigureWindow, struct.pack("<IHxxI", a, 1 << 6, 9)))
    out["with_sibling"] = outcome(c, lambda: c.request(
        Op.ConfigureWindow, struct.pack("<IHxxII", a, (1 << 5) | (1 << 6), b, 0)))
    # `stray` has a different parent, so it is not a sibling of `a`.
    out["sibling_not_a_sibling"] = outcome(c, lambda: c.request(
        Op.ConfigureWindow, struct.pack("<IHxxII", a, (1 << 5) | (1 << 6), stray, 0)))
    out["circulate"] = outcome(c, lambda: c.request(
        Op.CirculateWindow, struct.pack("<I", parent), detail=0))
    out["circulate_bad_direction"] = outcome(c, lambda: c.request(
        Op.CirculateWindow, struct.pack("<I", parent), detail=9))
    c.destroy(parent)
    c.destroy(stray)
    return out


@probe("window.attribute_enums")
def window_attribute_enums(c):
    """ChangeWindowAttributes' enumerated fields. These decide how a window
    survives being covered and resized, and an illegal one accepted here is
    a rendering bug somewhere else entirely."""
    win = c.create_window()
    c.sync()
    out = {}
    cases = {
        "bit_gravity":    (1 << 4, 1, 99),
        "win_gravity":    (1 << 5, 1, 99),
        "backing_store":  (1 << 6, 1, 99),
    }
    for name, (bit, good, bad) in cases.items():
        out[name + "_legal"] = outcome(c, lambda b=bit, v=good: c.request(
            Op.ChangeWindowAttributes, struct.pack("<III", win, b, v)))
        out[name + "_illegal"] = outcome(c, lambda b=bit, v=bad: c.request(
            Op.ChangeWindowAttributes, struct.pack("<III", win, b, v)))
    c.destroy(win)
    return out


@probe("props.rotate")
def props_rotate(c):
    """RotateProperties. Rarely used, but it is how ICCCM window managers
    shuffle a property list, and a server that mishandles it corrupts every
    property named in the request rather than failing cleanly."""
    win = c.create_window()
    c.sync()
    a1, a2 = c.intern("MSL_ROT_1"), c.intern("MSL_ROT_2")
    for atom, val in ((a1, b"one"), (a2, b"two")):
        c.request(Op.ChangeProperty, struct.pack("<IIIB3xI", win, atom, 31, 8, 3) + xwire.padded(val))
    c.sync()
    out = {}
    out["rotate"] = outcome(c, lambda: c.request(
        Op.RotateProperties, struct.pack("<IHh", win, 2, 1) + struct.pack("<II", a1, a2)))
    # A property in the list that the window does not have is BadMatch.
    missing = c.intern("MSL_ROT_MISSING")
    out["rotate_missing_property"] = outcome(c, lambda: c.request(
        Op.RotateProperties, struct.pack("<IHh", win, 2, 1) + struct.pack("<II", a1, missing)))
    out["rotate_zero_delta"] = outcome(c, lambda: c.request(
        Op.RotateProperties, struct.pack("<IHh", win, 2, 0) + struct.pack("<II", a1, a2)))
    # Xlib's XRotateBuffers rotates CUT_BUFFER0..7 on the ROOT window, so
    # root is an ordinary target here - and an empty atom list is a no-op,
    # not an error.
    out["rotate_root_empty_list"] = outcome(c, lambda: c.request(
        Op.RotateProperties, struct.pack("<IHh", c.root, 0, 0)))
    c.destroy(win)
    return out


@probe("atoms.errors")
def atoms_errors(c):
    """GetAtomName for an atom that was never interned, and InternAtom with
    only-if-exists. Toolkits probe for optional atoms this way, and a
    fabricated name would make one believe a feature is present."""
    out = {}
    out["get_name_of_zero"] = outcome(c, lambda: c.call(Op.GetAtomName, struct.pack("<I", 0)))
    out["get_name_huge"] = outcome(c, lambda: c.call(Op.GetAtomName, struct.pack("<I", 0x0FFFFFFF)))
    name = b"MSL_DEFINITELY_NOT_INTERNED_XYZ"
    r = c.call(Op.InternAtom, struct.pack("<Hxx", len(name)) + xwire.padded(name), detail=1)
    out["only_if_exists_returns_none"] = struct.unpack_from("<I", r, 8)[0] == 0
    r2 = c.call(Op.InternAtom, struct.pack("<Hxx", len(name)) + xwire.padded(name), detail=0)
    out["create_returns_nonzero"] = struct.unpack_from("<I", r2, 8)[0] != 0
    return out


# ------------------------------------------------------------------ RENDER

def _render(c):
    """(major opcode, an ARGB32 format id, error base) or None."""
    ext = c.query_extension("RENDER")
    if not ext["present"]:
        return None
    major = ext["major"]
    base = ext["error"]
    c.call(major, struct.pack("<II", 0, 11), detail=0)
    r = c.call(major, b"", detail=1)
    nformats = struct.unpack_from("<I", r, 8)[0]
    argb = None
    off = 32
    for _ in range(nformats):
        fid, ftype, depth = struct.unpack_from("<IBB2x", r, off)[0:3]
        if depth == 32 and ftype == 1 and argb is None:
            argb = fid
        off += 28
    return (major, argb, base)


@probe("render.picture_lifecycle")
def render_picture_lifecycle(c):
    """CreatePicture / FreePicture and their refusals. Every cairo surface
    is a Picture; one that cannot be made, or an error swallowed here,
    turns into a blank window much later."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    pix = c.create_pixmap(16, 16, depth=32)
    c.sync()
    out = {"present": True}
    pic = c.new_id()
    out["create"] = eo(lambda: c.request(
        major, struct.pack("<IIII", pic, pix, argb, 0), detail=4))
    out["create_unknown_drawable"] = eo(lambda: c.request(
        major, struct.pack("<IIII", c.new_id(), unallocated(c), argb, 0), detail=4))
    # The ROOT window is a legal drawable - conky/tint2-style transparency
    # makes a Picture of it.
    out["create_on_root"] = eo(lambda: c.request(
        major, struct.pack("<IIII", c.new_id(), c.root, 0, 0), detail=4))
    out["create_unknown_format"] = eo(lambda: c.request(
        major, struct.pack("<IIII", c.new_id(), pix, 0xDEAD, 0), detail=4))
    # A depth-24 pixmap with an ARGB32 format is a depth mismatch.
    flat = c.create_pixmap(16, 16, depth=24)
    c.sync()
    out["format_depth_mismatch"] = eo(lambda: c.request(
        major, struct.pack("<IIII", c.new_id(), flat, argb, 0), detail=4))
    out["free"] = eo(lambda: c.request(major, struct.pack("<I", pic), detail=7))
    out["free_unknown"] = eo(lambda: c.request(
        major, struct.pack("<I", unallocated(c)), detail=7))
    return out


@probe("render.composite_ops")
def render_composite_ops(c):
    """Composite's PictOp enumeration. Ops 0..13 are the Porter-Duff set
    every toolkit uses; the disjoint/conjoint ops run to 0x3D, and a value
    past the end is BadValue."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    src = c.create_pixmap(16, 16, depth=32)
    dst = c.create_pixmap(16, 16, depth=32)
    c.sync()
    sp, dp = c.new_id(), c.new_id()
    c.request(major, struct.pack("<IIII", sp, src, argb, 0), detail=4)
    c.request(major, struct.pack("<IIII", dp, dst, argb, 0), detail=4)
    c.sync()
    out = {"present": True}
    def composite(op):
        # op(1) pad(3) src(4) mask(4) dst(4) then six INT16 and two CARD16.
        return c.request(major, struct.pack("<BxxxIIIhhhhhhHH",
                                            op, sp, 0, dp, 0, 0, 0, 0, 0, 0, 8, 8), detail=8)
    # Every legal range's boundaries, not just the ops a toolkit usually
    # sends: Porter-Duff 0x00-0x0D, disjoint 0x10-0x1B, conjoint 0x20-0x2B,
    # and the RENDER 0.11 blend ops 0x30-0x3E. A validator one value too
    # generous is merely lenient; one value too strict refuses cairo's
    # MULTIPLY on a server that says it has it.
    for op in (0x00, 0x0D, 0x10, 0x1B, 0x20, 0x2B, 0x30, 0x3E):
        out["op_0x%02X" % op] = eo(lambda o=op: composite(o))
    for op in (0x0E, 0x1C, 0x2C, 0x3F, 0xFE):
        out["illegal_0x%02X" % op] = eo(lambda o=op: composite(o))
    out["unknown_src_picture"] = eo(lambda: c.request(
        major, struct.pack("<BxxxIIIhhhhhhHH", 0, unallocated(c), 0, dp, 0, 0, 0, 0, 0, 0, 8, 8),
        detail=8))
    return out


@probe("render.fill_and_transform")
def render_fill_and_transform(c):
    """FillRectangles and SetPictureTransform - the two requests behind
    every solid fill and every scaled/rotated image a toolkit draws."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    pix = c.create_pixmap(16, 16, depth=32)
    c.sync()
    pic = c.new_id()
    c.request(major, struct.pack("<IIII", pic, pix, argb, 0), detail=4)
    c.sync()
    out = {"present": True}
    # FillRectangles: op in detail, then picture, colour, rectangles.
    # FillRectangles is minor 26: op(1) pad(3) dst(4) colour(8) then rects.
    def fill(op, picture):
        return c.request(major, struct.pack("<BxxxI4H", op, picture, 0xFFFF, 0, 0, 0xFFFF)
                         + struct.pack("<hhHH", 0, 0, 8, 8), detail=26)
    out["fill"] = eo(lambda: fill(1, pic))
    out["fill_bad_op"] = eo(lambda: fill(0xFE, pic))
    out["fill_unknown_picture"] = eo(lambda: fill(1, unallocated(c)))
    # SetPictureTransform: a 3x3 matrix of 16.16 fixed point. The identity
    # is what a client sets to undo a scale.
    identity = struct.pack("<9i", 65536, 0, 0, 0, 65536, 0, 0, 0, 65536)
    out["transform_identity"] = eo(lambda: c.request(
        major, struct.pack("<I", pic) + identity, detail=28))
    out["transform_unknown_picture"] = eo(lambda: c.request(
        major, struct.pack("<I", unallocated(c)) + identity, detail=28))
    return out


@probe("render.glyphs")
def render_glyphs(c):
    """CreateGlyphSet / FreeGlyphSet / ReferenceGlyphSet. Every character
    Pango and cairo draw goes through a glyph set, so its bookkeeping is
    the hottest resource path in the server."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    out = {"present": True}
    gs = c.new_id()
    # A8 is the coverage format glyphs actually use; find it.
    r = c.call(major, b"", detail=1)
    nformats = struct.unpack_from("<I", r, 8)[0]
    a8, off = None, 32
    for _ in range(nformats):
        fid, ftype, depth = struct.unpack_from("<IBB2x", r, off)[0:3]
        if depth == 8 and ftype == 1 and a8 is None:
            a8 = fid
        off += 28
    out["has_a8"] = a8 is not None
    if a8 is None:
        return out
    out["create"] = eo(lambda: c.request(major, struct.pack("<II", gs, a8), detail=17))
    out["create_bad_format"] = eo(lambda: c.request(
        major, struct.pack("<II", c.new_id(), 0xDEAD), detail=17))
    ref = c.new_id()
    out["reference"] = eo(lambda: c.request(major, struct.pack("<II", ref, gs), detail=18))
    out["reference_unknown"] = eo(lambda: c.request(
        major, struct.pack("<II", c.new_id(), unallocated(c)), detail=18))
    out["free"] = eo(lambda: c.request(major, struct.pack("<I", gs), detail=19))
    out["free_unknown"] = eo(lambda: c.request(
        major, struct.pack("<I", unallocated(c)), detail=19))
    return out


# ------------------------------------------------------------------- SHAPE

@probe("shape.queries")
def shape_queries(c):
    """SHAPE's query requests. GTK and Qt use shapes for popups, tooltips
    and rounded corners, and QueryExtents is what they read back."""
    ext = c.query_extension("SHAPE")
    if not ext["present"]:
        return {"present": False}
    major = ext["major"]
    base = ext["error"]
    def eo(fn):
        return ext_outcome(c, fn, base)
    win = c.create_window()
    c.sync()
    out = {"present": True}
    r = c.call(major, b"", detail=0)  # QueryVersion
    out["version_words"] = struct.unpack_from("<I", r, 4)[0]
    r = c.call(major, struct.pack("<I", win), detail=5)  # QueryExtents
    out["extents_words"] = struct.unpack_from("<I", r, 4)[0]
    out["bounding_shaped_is_bool"] = r[8] in (0, 1)
    out["clip_shaped_is_bool"] = r[9] in (0, 1)
    out["extents_unknown_window"] = eo(lambda: c.call(
        major, struct.pack("<I", unallocated(c)), detail=5))
    # Rectangles: kind must be Bounding/Clip/Input.
    out["rectangles_bounding"] = eo(lambda: c.call(
        major, struct.pack("<IBxxx", win, 0), detail=8))
    out["rectangles_bad_kind"] = eo(lambda: c.call(
        major, struct.pack("<IBxxx", win, 9), detail=8))
    out["rectangles_unknown_window"] = eo(lambda: c.call(
        major, struct.pack("<IBxxx", unallocated(c), 0), detail=8))
    c.destroy(win)
    return out


@probe("shape.mutations")
def shape_mutations(c):
    """Rectangles / Mask / Combine / Offset - the four ways a shape is set.
    None of them replies, so what is compared is which are accepted."""
    ext = c.query_extension("SHAPE")
    if not ext["present"]:
        return {"present": False}
    major = ext["major"]
    base = ext["error"]
    def eo(fn):
        return ext_outcome(c, fn, base)
    win = c.create_window()
    c.sync()
    out = {"present": True}
    rect = struct.pack("<hhHH", 0, 0, 40, 40)
    # Rectangles: op, kind, ordering, window, x, y, then the list.
    # op, kind, ordering, pad, THEN the window - the window is not first.
    def rects(win_id, op=0, kind=0, ordering=0):
        return struct.pack("<BBBxIhh", op, kind, ordering, win_id, 0, 0) + rect
    out["rectangles"] = eo(lambda: c.request(major, rects(win), detail=1))
    out["rectangles_bad_kind"] = eo(lambda: c.request(
        major, rects(win, kind=9), detail=1))
    out["rectangles_bad_op"] = eo(lambda: c.request(
        major, rects(win, op=9), detail=1))
    out["rectangles_unknown_window"] = eo(lambda: c.request(
        major, rects(unallocated(c)), detail=1))
    # Mask with a None pixmap resets the shape - the common case.
    out["mask_none"] = eo(lambda: c.request(
        major, struct.pack("<BBxxIhhI", 0, 0, win, 0, 0, 0), detail=2))
    out["offset"] = eo(lambda: c.request(
        major, struct.pack("<BxxxIhh", 0, win, 0, 0), detail=4))
    out["offset_unknown_window"] = eo(lambda: c.request(
        major, struct.pack("<BxxxIhh", 0, unallocated(c), 0, 0), detail=4))
    c.destroy(win)
    return out


# ------------------------------------------------------- text and pointers

@probe("text.imagetext")
def text_imagetext(c):
    """ImageText8 / ImageText16 / PolyText8. Non-toolkit clients (xterm,
    xcalc, Motif) draw every label through these, and a swallowed error
    here is a window with no text in it."""
    pix = c.create_pixmap(64, 32)
    gc = c.create_gc(pix)
    c.sync()
    out = {}
    text = b"Hi"
    out["imagetext8"] = outcome(c, lambda: c.request(
        Op.ImageText8, struct.pack("<IIhh", pix, gc, 2, 10) + xwire.padded(text), detail=len(text)))
    out["imagetext16"] = outcome(c, lambda: c.request(
        Op.ImageText16, struct.pack("<IIhh", pix, gc, 2, 10) + xwire.padded(b"\x00H\x00i"), detail=2))
    out["imagetext8_unknown_drawable"] = outcome(c, lambda: c.request(
        Op.ImageText8, struct.pack("<IIhh", unallocated(c), gc, 2, 10) + xwire.padded(text),
        detail=len(text)))
    out["imagetext8_unknown_gc"] = outcome(c, lambda: c.request(
        Op.ImageText8, struct.pack("<IIhh", pix, unallocated(c), 2, 10) + xwire.padded(text),
        detail=len(text)))
    # PolyText8: a length byte, a delta byte, then the string.
    item = bytes([len(text), 0]) + text
    out["polytext8"] = outcome(c, lambda: c.request(
        Op.PolyText8, struct.pack("<IIhh", pix, gc, 2, 20) + xwire.padded(item)))
    return out


@probe("pointer.warp_and_query")
def pointer_warp_and_query(c):
    """WarpPointer and QueryPointer. A client that cannot warp cannot
    implement a pointer-lock or a drag-scroll, and QueryPointer's
    same-screen flag decides whether its answer is usable at all."""
    win = c.create_window()
    c.map(win)
    c.sync()
    r = c.call(Op.QueryPointer, struct.pack("<I", c.root))
    out = {"same_screen_is_bool": r[1] in (0, 1),
           "reply_len_words": struct.unpack_from("<I", r, 4)[0]}
    out["query_unknown_window"] = outcome(c, lambda: c.call(
        Op.QueryPointer, struct.pack("<I", unallocated(c))))
    # Warp relative to nothing (src None) is the common "move to absolute".
    out["warp_none_source"] = outcome(c, lambda: c.request(
        Op.WarpPointer, struct.pack("<IIhhHHhh", 0, win, 0, 0, 0, 0, 5, 5)))
    out["warp_unknown_dest"] = outcome(c, lambda: c.request(
        Op.WarpPointer, struct.pack("<IIhhHHhh", 0, unallocated(c), 0, 0, 0, 0, 5, 5)))
    c.destroy(win)
    return out


@probe("selection.convert")
def selection_convert(c):
    """ConvertSelection against an unowned selection. The spec says the
    SERVER sends the requestor a SelectionNotify with property None - a
    client that gets nothing at all waits forever, which is what a hung
    paste looks like."""
    win = c.create_window(attrs={xwire.CW.EventMask: xwire.EM.PropertyChange})
    c.sync()
    sel = c.intern("MSL_XDIFF_UNOWNED_SELECTION")
    target = c.intern("UTF8_STRING")
    prop = c.intern("MSL_XDIFF_PROP")
    c.drain_events()
    c.request(Op.ConvertSelection, struct.pack("<IIIII", win, sel, target, prop, 0))
    c.sync()
    time.sleep(0.3)
    events = c.drain_events()
    # SelectionNotify is event 31.
    notifies = [e for e in events if e and e[0] & 0x7F == 31]
    out = {"notify_arrived": len(notifies) > 0}
    if notifies:
        e = notifies[0]
        req, gsel, gtarget, gprop = struct.unpack_from("<IIII", e, 8)
        out["property_is_none"] = gprop == 0
        out["reports_selection"] = gsel == sel
        out["reports_target"] = gtarget == target
    c.destroy(win)
    return out


@probe("grab.freeze_thaw")
def grab_freeze_thaw(c):
    """The real freeze/thaw cycle, in the order an app actually does it.

    X11's own vocabulary: a **Sync**-mode grab FREEZES the device - the
    server queues events and delivers nothing further until the client says
    so - and `AllowEvents` THAWS it. That pair is what every menu, drag and
    click-to-focus rule is built from, and a server that mishandles it
    leaves the pointer or keyboard frozen with no way back: the whole
    session stops responding, not just the app.

    Ultra-minimal on purpose. It does not check WHICH events come back (this
    server's input comes from AppKit, not a real device); it checks that the
    sequence is accepted, that all eight AllowEvents modes are legal after a
    freeze, and - the point - that the connection is still alive and
    answering afterwards."""
    win = c.create_window()
    c.map(win)
    c.sync()
    out = {}

    # Freeze the pointer: pointer_mode = Sync (0), keyboard_mode = Async (1).
    r = c.call(Op.GrabPointer,
               struct.pack("<IHBBIII", win, 0, 0, 1, 0, 0, 0), detail=1)
    out["pointer_grab_status"] = r[1]
    # Thaw, every defined mode. 0 AsyncPointer, 1 SyncPointer, 2 ReplayPointer,
    # 3 AsyncKeyboard, 4 SyncKeyboard, 5 ReplayKeyboard, 6 AsyncBoth, 7 SyncBoth.
    for mode in range(8):
        out["allow%d" % mode] = outcome(c, lambda m=mode: c.request(
            Op.AllowEvents, struct.pack("<I", 0), detail=m))
    out["ungrab_pointer"] = outcome(c, lambda: c.request(Op.UngrabPointer, struct.pack("<I", 0)))

    # Same for the keyboard: keyboard_mode = Sync.
    r = c.call(Op.GrabKeyboard, struct.pack("<IIBBxx", win, 0, 1, 0), detail=1)
    out["keyboard_grab_status"] = r[1]
    out["thaw_keyboard"] = outcome(c, lambda: c.request(
        Op.AllowEvents, struct.pack("<I", 0), detail=3))
    out["ungrab_keyboard"] = outcome(c, lambda: c.request(Op.UngrabKeyboard, struct.pack("<I", 0)))

    # A frozen device that is never thawed, then simply ungrabbed - the
    # abandoned-menu case, and the one most likely to wedge a server.
    c.call(Op.GrabPointer, struct.pack("<IHBBIII", win, 0, 0, 0, 0, 0, 0), detail=1)
    out["ungrab_while_frozen"] = outcome(c, lambda: c.request(
        Op.UngrabPointer, struct.pack("<I", 0)))

    # GrabServer freezes every client; the pair must nest with a device grab.
    out["grab_server"] = outcome(c, lambda: c.request(Op.GrabServer))
    out["ungrab_server"] = outcome(c, lambda: c.request(Op.UngrabServer))

    # THE CHECK: is the connection still alive and answering?
    out["still_responsive"] = outcome(c, lambda: c.call(Op.GetInputFocus))
    r = c.call(Op.GetGeometry, struct.pack("<I", win))
    out["geometry_after_all_of_it"] = list(struct.unpack_from("<HH", r, 16))
    c.destroy(win)
    return out


# ------------------------------------------------------------------- runner

# ------------------------- RENDER and image transfer (added 2026-10-06)
#
# Written for the vanishing-apps bug (READMES/28): the client dies blocked
# in `_XReply` with `xcb_connection_has_error() == 0`. Only two server
# behaviours can produce that - SILENCE where a reply is owed, or framing
# that makes the client read past what was actually sent - so every probe
# below reports *what came back and how big it was*, never just "Ok".
#
# A reply and an error both answer the sequence and both unblock `_XReply`,
# so an error-code difference here is a correctness finding, not a hang.
# `HANG` and a length that disagrees with its own contents are the two
# values worth staring at.


def fresh(c, timeout=4.0):
    """A second connection to the same server.

    A reply-bearing probe that hangs poisons its connection: every later
    sub-check in the same probe would report the first hang's symptoms. One
    connection per risky call keeps the sub-checks independent, and the
    short timeout keeps a whole-suite run finite."""
    return xwire.Conn(c.path, timeout=timeout)


def still_answering(c):
    """Whether the connection survived the battery above it.

    Not `reply_shape(GetInputFocus)`: that reply's detail byte is
    `revert-to`, which is live focus state and legitimately differs between
    a headless Xvfb and a real Mac desktop - it would report a difference
    at the end of every probe that checks it."""
    try:
        c.call(Op.GetInputFocus)
    except Exception as e:  # noqa: BLE001 - the answer is "no, and why"
        return "no (%s)" % type(e).__name__
    return "yes"


def reply_shape(fn):
    """What a reply-bearing request actually produced.

    "Reply" alone cannot tell a correct answer from a correctly-framed lie,
    which is why this returns the wire length and the reply's detail byte
    too - the pair that decides whether the client reads the right number
    of bytes next."""
    try:
        r = fn()
    except XError as e:
        return err_name(e.err)
    except xwire.Hang:
        return "HANG"
    except xwire.Died:
        return "DIED"
    if not isinstance(r, (bytes, bytearray)):
        return "Ok"
    return "Reply(words=%d,detail=%d)" % (struct.unpack_from("<I", r, 4)[0], r[1])


def ext_reply_shape(fn, first_error, count=16):
    """`reply_shape`, with an extension's own errors named relative to its
    server-chosen error base (see `ext_outcome`)."""
    try:
        r = fn()
    except XError as e:
        if first_error and first_error <= e.err.code < first_error + count:
            return "ext_err%d" % (e.err.code - first_error)
        return err_name(e.err)
    except xwire.Hang:
        return "HANG"
    except xwire.Died:
        return "DIED"
    if not isinstance(r, (bytes, bytearray)):
        return "Ok"
    return "Reply(words=%d,detail=%d)" % (struct.unpack_from("<I", r, 4)[0], r[1])


@probe("render.pictformats_counts")
def render_pictformats_counts(c):
    """`QueryPictFormats`' COUNT FIELDS against the bytes it really sent.

    libXrender does not trust the reply length. It allocates from
    `numFormats`/`numScreens`/`numDepths`/`numVisuals`, then walks the
    screen list subtracting as it goes, and **returns 0** the moment one
    depth's `nPictVisuals` exceeds the `numVisuals` it has left
    (`Xrender.c`: `if (depth->nvisuals > rep.numVisuals) { ...
    _XEatDataWords(...); return 0; }`). `XRenderQueryFormats` returning 0
    is what libXrender reports to cairo-xlib and Xft as *this server has no
    RENDER* - with no X error, no warning and a stream still in sync,
    because it eats the whole reply on the way out.

    So a reply can be perfectly framed on the wire and still switch RENDER
    off for every Xlib client. Nothing else in this file was looking at the
    counts, only at the formats."""
    ext = c.query_extension("RENDER")
    if not ext["present"]:
        return {"present": False}
    major = ext["major"]
    c.call(major, struct.pack("<II", 0, 11), detail=0)
    r = c.call(major, b"", detail=1)
    words = struct.unpack_from("<I", r, 4)[0]
    nf, ns, nd, nv = struct.unpack_from("<IIII", r, 8)
    nsub = struct.unpack_from("<I", r, 24)[0]
    extra = len(r) - 32
    # libXrender's own arithmetic, byte for byte.
    implied = nf * 28 + ns * 8 + nd * 8 + nv * 8 + nsub * 4
    # Walk what the reply really carries, exactly the way libXrender walks
    # it - including its running subtraction, which is what actually fails.
    off = 32 + nf * 28
    depths = visuals = 0
    in_bounds = True
    left_d, left_v = nd, nv
    bail = "no"
    for _ in range(ns):
        if off + 8 > len(r):
            in_bounds = False
            break
        screen_depths = struct.unpack_from("<I", r, off)[0]
        off += 8
        if screen_depths > left_d and bail == "no":
            bail = "screen nDepth %d > numDepths remaining %d" % (screen_depths, left_d)
        left_d -= screen_depths
        for _ in range(screen_depths):
            if off + 8 > len(r):
                in_bounds = False
                break
            dep, _pad, nvis = struct.unpack_from("<BBH", r, off)
            off += 8
            depths += 1
            visuals += nvis
            if nvis > left_v and bail == "no":
                bail = "depth %d nPictVisuals %d > numVisuals remaining %d" % (dep, nvis, left_v)
            left_v -= nvis
            off += nvis * 8
    return {"present": True,
            "num_screens": ns,
            "wire_length_matches_buffer": words * 4 == extra,
            "declared_counts_imply_reply_size": implied == extra,
            "declared_numdepths_matches_walk": nd == depths,
            "declared_numvisuals_matches_walk": nv == visuals,
            "walk_stayed_in_bounds": in_bounds,
            "libxrender_would_reject": bail}


@probe("render.xlib_sees_render")
def render_xlib_sees_render(c):
    """End to end through the real library every toolkit actually calls.

    `XRenderQueryExtension` only does `QueryExtension` plus the five-depth
    pixmap probe, so it can answer yes while `XRenderQueryVersion` - which
    runs `XRenderQueryFormats` internally and returns its verdict - answers
    no. xhell's `ext.xlib-sees-render` asserts the first of those and
    records the version as a *metric*, which is how a server with RENDER
    switched off for every cairo and Xft client passed every test here."""
    import ctypes
    try:
        xlib = ctypes.CDLL("libX11.so.6")
        xr = ctypes.CDLL("libXrender.so.1")
    except OSError as e:
        # Both servers would return the same dict and the probe would read
        # SAME - the exact vacuous pass this run found in `render.formats`
        # and in xhell's `ext.xlib-sees-render`. An unrunnable probe is ERR.
        raise RuntimeError("libX11/libXrender not installed in this guest: %s" % e)
    xlib.XOpenDisplay.restype = ctypes.c_void_p
    xlib.XServerVendor.restype = ctypes.c_char_p
    xr.XRenderFindStandardFormat.restype = ctypes.c_void_p
    name = ":" + os.path.basename(c.path)[1:]
    d = xlib.XOpenDisplay(name.encode())
    if not d:
        return {"libraries": "present", "open": False}
    dpy = ctypes.c_void_p(d)
    try:
        ev, er = ctypes.c_int(), ctypes.c_int()
        has = bool(xr.XRenderQueryExtension(dpy, ctypes.byref(ev), ctypes.byref(er)))
        major, minor = ctypes.c_int(0), ctypes.c_int(0)
        version_ok = bool(xr.XRenderQueryVersion(dpy, ctypes.byref(major), ctypes.byref(minor)))
        standard = {}
        for label, code in (("argb32", 0), ("rgb24", 1), ("a8", 2), ("a4", 3), ("a1", 4)):
            standard[label] = xr.XRenderFindStandardFormat(dpy, code) is not None
        # The stream must still be usable: libXrender's failure path eats
        # the reply it rejected, and if it ever stopped doing that the
        # desync would surface here and nowhere else.
        xlib.XSync(dpy, 0)
        vendor_readable = xlib.XServerVendor(dpy) is not None
        return {"libraries": "present", "open": True,
                "query_extension": has,
                "query_version": version_ok,
                "version": "%d.%d" % (major.value, minor.value),
                "standard_formats": standard,
                "stream_survives_sync": vendor_readable}
    finally:
        xlib.XCloseDisplay(dpy)


@probe("render.formats_direct")
def render_formats_direct(c):
    """The four formats cairo and Qt look up by exact mask - read with the
    right `type`.

    `render.formats` tests `type == 0`, but 0 is `PictTypeIndexed` and
    Direct is 1, so its `has_argb32`, `has_a8` and `has_a1` fields have
    always been False against BOTH servers and asserted nothing at all. A
    field that cannot ever be True is worse than a missing one, because the
    board reads it as covered."""
    info = _render(c)
    if not info:
        return {"present": False}
    major = info[0]
    r = c.call(major, b"", detail=1)
    nf = struct.unpack_from("<I", r, 8)[0]
    found = set()
    for i in range(nf):
        off = 32 + 28 * i
        _fid, ftype, depth = struct.unpack_from("<IBB2x", r, off)[0:3]
        rs, rm, gs, gm, bs, bm, als, alm = struct.unpack_from("<8H", r, off + 8)
        found.add((ftype, depth, rm, gm, bm, alm, als))
    want = {"argb32": (1, 32, 0xFF, 0xFF, 0xFF, 0xFF, 24),
            "rgb24": (1, 24, 0xFF, 0xFF, 0xFF, 0, 0),
            "a8": (1, 8, 0, 0, 0, 0xFF, 0),
            "a1": (1, 1, 0, 0, 0, 1, 0)}
    return {"present": True, "direct_formats_exist": any(t == 1 for t, *_ in found),
            **{k: (v in found) for k, v in want.items()}}


@probe("render.query_replies")
def render_query_replies(c):
    """RENDER's four reply-bearing minors, with the inputs a real client
    gets wrong.

    These are the only RENDER requests that can hang a client, so each gets
    its own connection: `QueryVersion` (0), `QueryPictFormats` (1),
    `QueryPictIndexValues` (2) and `QueryFilters` (29)."""
    ext = c.query_extension("RENDER")
    if not ext["present"]:
        return {"present": False}
    major, base = ext["major"], ext["error"]
    out = {"present": True}

    def one(label, body, minor, timeout=4.0):
        k = fresh(c, timeout)
        try:
            out[label] = ext_reply_shape(lambda: k.call(major, body, detail=minor), base)
        finally:
            k.close()

    one("version_0_11", struct.pack("<II", 0, 11), 0)
    # A client asking for more than the server has: the server answers with
    # its OWN version, it does not refuse.
    one("version_99_99", struct.pack("<II", 99, 99), 0)
    one("version_0_0", struct.pack("<II", 0, 0), 0)
    # A body-less QueryVersion. The request is defined as 3 words; one word
    # is a truncated request, and reading it as zeroes fabricates a reply.
    one("pictformats", b"", 1)
    # The reply's SIZE differs legitimately - two servers have different
    # numbers of formats and visuals - so only whether it answered is
    # comparable here. `render.pictformats_counts` is where the size is
    # checked, against the reply's own count fields.
    if out["pictformats"].startswith("Reply"):
        out["pictformats"] = "Reply"
    # QueryPictIndexValues: only meaningful for an Indexed format. Both
    # servers must say something - this is the minor the mslgd source
    # singles out as "silence hangs the client in _XReply forever".
    info = _render(c)
    argb = info[1] if info else 0
    one("index_values_direct_format", struct.pack("<I", argb or 0), 2)
    one("index_values_unknown_format", struct.pack("<I", 0xDEAD), 2)
    one("index_values_zero", struct.pack("<I", 0), 2)
    # QueryFilters takes a DRAWABLE. mslgd never reads it.
    one("filters_root", struct.pack("<I", c.root), 29)
    one("filters_unknown_drawable", struct.pack("<I", 0xDEADBEEF), 29)
    return out


@probe("render.body_lengths")
def render_body_lengths(c):
    """RENDER requests whose BODY is the wrong size for the minor.

    The `ext.minor_sweep` class, aimed at RENDER specifically and at the
    reply-bearing minors in particular. A reply-less request read short
    just loses the drawing it asked for; a reply-bearing one **fabricates
    a reply out of zeroes and presents it as the answer**, which is the
    subset that KNOWN note calls the dangerous one. `XkbGetMap` was fixed
    after this oracle caught it doing exactly that - these are more of the
    same, found the same way."""
    ext = c.query_extension("RENDER")
    if not ext["present"]:
        return {"present": False}
    major, base = ext["major"], ext["error"]
    out = {"present": True}

    def reply_minor(label, body, minor):
        k = fresh(c)
        try:
            out[label] = ext_reply_shape(lambda: k.call(major, body, detail=minor), base)
        finally:
            k.close()

    def quiet_minor(label, body, minor):
        out[label] = ext_outcome(c, lambda: c.request(major, body, detail=minor), base)

    # Reply-bearing: a short body here invents an answer.
    reply_minor("queryversion_no_body", b"", 0)
    reply_minor("queryversion_one_word", struct.pack("<I", 0), 0)
    reply_minor("queryversion_trailing_junk", struct.pack("<III", 0, 11, 0xDEAD), 0)
    reply_minor("pictformats_trailing_junk", struct.pack("<II", 0xDEAD, 0xBEEF), 1)
    reply_minor("indexvalues_no_body", b"", 2)
    reply_minor("queryfilters_no_body", b"", 29)
    # Reply-less: a short body costs the drawing, not the client.
    pix = c.create_pixmap(16, 16, depth=32)
    c.sync()
    quiet_minor("createpicture_no_body", b"", 4)
    quiet_minor("createpicture_short", struct.pack("<II", c.new_id(), pix), 4)
    quiet_minor("changepicture_no_body", b"", 5)
    quiet_minor("clip_rects_truncated", b"\x00\x00\x00\x00", 6)
    quiet_minor("freepicture_no_body", b"", 7)
    quiet_minor("composite_no_body", b"", 8)
    quiet_minor("composite_short", struct.pack("<BxxxII", 0, 0, 0), 8)
    quiet_minor("fillrects_no_body", b"", 26)
    quiet_minor("transform_short", struct.pack("<I", 0), 28)
    quiet_minor("setfilter_no_body", b"", 30)
    out["alive_after"] = still_answering(c)
    return out


@probe("render.query_filters_shape")
def render_query_filters_shape(c):
    """`QueryFilters`' reply against its own counts.

    libXrender splits this reply into the alias array and the name list
    using `numAliases` and the reply length, so an alias count that does
    not match the bytes present makes it read the filter names out of the
    middle of the alias array - and `XRenderSetPictureFilter` then sends a
    name no server knows."""
    ext = c.query_extension("RENDER")
    if not ext["present"]:
        return {"present": False}
    major = ext["major"]
    c.call(major, struct.pack("<II", 0, 11), detail=0)
    try:
        r = c.call(major, struct.pack("<I", c.root), detail=29)
    except XError as e:
        return {"present": True, "reply": err_name(e.err)}
    words = struct.unpack_from("<I", r, 4)[0]
    nalias, nfilters = struct.unpack_from("<II", r, 8)
    extra = len(r) - 32
    # libXrender: nbytesAlias = numAliases*2, rounded up to a 4-byte unit.
    alias_bytes = nalias * 2
    if nalias & 1:
        alias_bytes += 2
    names, off, ok = [], 32 + alias_bytes, True
    for _ in range(nfilters):
        if off >= len(r):
            ok = False
            break
        n = r[off]
        names.append(bytes(r[off + 1:off + 1 + n]).decode("latin-1"))
        off += 1 + n
    return {"present": True,
            "wire_length_matches_buffer": words * 4 == extra,
            "alias_bytes_fit": alias_bytes <= extra,
            "names_parse_in_bounds": ok,
            "name_count": len(names),
            "has_nearest": "nearest" in names,
            "has_bilinear": "bilinear" in names,
            "aliases_name_real_filters": _aliases_ok(r, nalias, nfilters)}


def _aliases_ok(r, nalias, nfilters):
    """Every alias must name a filter in the list, or be 0xFFFF for none."""
    if not nalias:
        return True
    if 32 + nalias * 2 > len(r):
        return "alias array runs past the reply"
    return all(a == 0xFFFF or a < nfilters
               for a in struct.unpack_from("<%dH" % nalias, r, 32))


@probe("image.getimage_edges")
def image_getimage_edges(c):
    """`GetImage` with the awkward inputs, every answer measured.

    GetImage is the request the vanishing clients died inside (`XCopyArea`
    -> `XSync` -> `_XReply` in the captured backtrace is the same shape),
    and the one place this server deliberately diverges from Xorg: it
    answers a zero-size or unknown-drawable read with a REPLY rather than
    an error. That is the safe direction for a hang, and the wrong
    direction for a client that is checking for failure - so it is worth
    seeing stated, not assumed."""
    out = {}
    pixmaps = {}
    for depth in (1, 8, 24, 32):
        p = c.create_pixmap(16, 16, depth=depth)
        pixmaps[depth] = p
    win = c.create_window(w=64, h=64)
    c.map(win)
    c.sync()

    def ask(drawable, x, y, w, h, fmt=2, mask=0xFFFFFFFF, timeout=4.0):
        k = fresh(c, timeout)
        try:
            return reply_shape(lambda: k.call(
                Op.GetImage, struct.pack("<IhhHHI", drawable, x, y, w, h, mask), detail=fmt))
        finally:
            k.close()

    for depth, p in pixmaps.items():
        out["d%d_full" % depth] = ask(p, 0, 0, 16, 16)
        out["d%d_zero_width" % depth] = ask(p, 0, 0, 0, 8)
        out["d%d_zero_height" % depth] = ask(p, 0, 0, 8, 0)
        out["d%d_zero_both" % depth] = ask(p, 0, 0, 0, 0)
    p = pixmaps[24]
    out["partly_outside_pixmap"] = ask(p, 10, 10, 10, 10)
    out["wholly_outside_pixmap"] = ask(p, 100, 100, 8, 8)
    out["negative_origin"] = ask(p, -4, -4, 8, 8)
    out["oversize_on_pixmap"] = ask(p, 0, 0, 4000, 4000)
    out["window_inside"] = ask(win, 0, 0, 16, 16)
    # XYPixmap and the plane masks that define its size.
    out["xy_depth24_all_planes"] = ask(p, 0, 0, 8, 8, fmt=1)
    out["xy_depth24_one_plane"] = ask(p, 0, 0, 8, 8, fmt=1, mask=1)
    out["xy_depth24_mask_above_depth"] = ask(p, 0, 0, 8, 8, fmt=1, mask=0xFF000000)
    out["xy_depth24_mask_zero"] = ask(p, 0, 0, 8, 8, fmt=1, mask=0)
    out["z_depth24_mask_zero"] = ask(p, 0, 0, 8, 8, fmt=2, mask=0)
    out["xy_depth1"] = ask(pixmaps[1], 0, 0, 8, 8, fmt=1)
    out["xy_depth8"] = ask(pixmaps[8], 0, 0, 8, 8, fmt=1)
    out["xybitmap_format_is_putimage_only"] = ask(p, 0, 0, 8, 8, fmt=0)
    out["bad_format_9"] = ask(p, 0, 0, 8, 8, fmt=9)
    out["no_body"] = reply_shape(lambda: fresh(c).call(Op.GetImage, b"", detail=2))
    return out


@probe("image.getimage_leniency")
def image_getimage_leniency(c):
    """The reads `handleGetImage` answers on PURPOSE where Xorg refuses.

    Split out of `image.getimage_edges` so the two can be triaged apart: a
    KNOWN entry silences a whole probe, and these three are reasoned
    choices with the reasons written in the handler - an unknown drawable
    and a zero-size read get a black image rather than an error, and a
    WINDOW is padded past its edge because Tk's Xft fallback reads text out
    of a still-1x1 window (seen replaying IDLE). Leniency cannot hang a
    client; it can only hide a client's own bug."""
    pix = c.create_pixmap(16, 16, depth=24)
    win = c.create_window(w=64, h=64)
    c.map(win)
    c.sync()

    def ask(drawable, x, y, w, h, fmt=2, mask=0xFFFFFFFF):
        k = fresh(c)
        try:
            return reply_shape(lambda: k.call(
                Op.GetImage, struct.pack("<IhhHHI", drawable, x, y, w, h, mask), detail=fmt))
        finally:
            k.close()

    return {"unknown_drawable": ask(unallocated(c), 0, 0, 8, 8),
            "unknown_drawable_huge": ask(unallocated(c), 0, 0, 55399, 2694),
            "pixmap_partly_outside": ask(pix, 10, 10, 10, 10),
            "window_partly_outside": ask(win, 60, 60, 16, 16),
            "window_negative_origin": ask(win, -8, -8, 16, 16)}


@probe("image.putimage_edges")
def image_putimage_edges(c):
    """`PutImage`'s refusals. It has no reply, so a wrong answer here is a
    corrupt drawable or a dead client, never a hang - but it is half of
    every repaint on this server now that cairo is on the core-image
    fallback, so its validation is load-bearing."""
    pix = c.create_pixmap(16, 16, depth=24)
    pix32 = c.create_pixmap(16, 16, depth=32)
    pix1 = c.create_pixmap(16, 16, depth=1)
    gc = c.create_gc(pix)
    gc1 = c.create_gc(pix1)
    c.sync()
    out = {}

    def put(fmt, depth, data, w=4, h=4, x=0, y=0, pad=0, drawable=None, g=None):
        return c.request(Op.PutImage,
                         struct.pack("<IIHHhhBB2x", drawable if drawable is not None else pix,
                                     g if g is not None else gc, w, h, x, y, pad, depth)
                         + xwire.padded(data), detail=fmt)

    z24 = b"\x11\x22\x33\x00" * 16          # 4x4 ZPixmap at depth 24
    out["z_depth24_exact"] = outcome(c, lambda: put(2, 24, z24))
    out["z_zero_width"] = outcome(c, lambda: put(2, 24, b"", w=0, h=4))
    out["z_zero_height"] = outcome(c, lambda: put(2, 24, b"", w=4, h=0))
    out["z_zero_both"] = outcome(c, lambda: put(2, 24, b"", w=0, h=0))
    # Short data: the body is smaller than width*height says it is.
    out["z_data_too_short"] = outcome(c, lambda: put(2, 24, z24[:8]))
    out["z_data_too_long"] = outcome(c, lambda: put(2, 24, z24 * 4))
    # "left-pad must be zero for ZPixmap" - the protocol says BadMatch.
    out["z_left_pad_nonzero"] = outcome(c, lambda: put(2, 24, z24, pad=4))
    out["left_pad_too_large"] = outcome(c, lambda: put(0, 1, b"\x00" * 16, pad=40))
    # Destination rectangle hanging off the drawable: clipped, not refused.
    out["z_dst_beyond_edge"] = outcome(c, lambda: put(2, 24, z24, x=14, y=14))
    out["z_dst_wholly_outside"] = outcome(c, lambda: put(2, 24, z24, x=100, y=100))
    out["z_dst_negative"] = outcome(c, lambda: put(2, 24, z24, x=-8, y=-8))
    # Depth that is not the drawable's.
    out["z_depth8_on_depth24"] = outcome(c, lambda: put(2, 8, b"\x01" * 16))
    out["z_depth32_on_depth24"] = outcome(c, lambda: put(2, 32, z24))
    out["z_depth24_on_depth32"] = outcome(c, lambda: put(2, 24, z24, drawable=pix32))
    out["z_depth_not_a_format"] = outcome(c, lambda: put(2, 7, z24))
    out["z_depth_zero"] = outcome(c, lambda: put(2, 0, z24))
    # XYBitmap is depth 1 whatever the drawable is, and it uses the GC's
    # foreground/background - this is how every stipple arrives.
    out["xybitmap_depth1_onto_depth24"] = outcome(c, lambda: put(0, 1, b"\x80\x40\x20\x10"))
    out["xybitmap_depth24"] = outcome(c, lambda: put(0, 24, z24))
    # XYPixmap at depth 24: 24 planes of (w+7)/8 bytes padded to 4, per row.
    xy24 = b"\x00" * (24 * 4 * 4)
    out["xypixmap_depth24_exact"] = outcome(c, lambda: put(1, 24, xy24))
    out["xypixmap_depth24_short"] = outcome(c, lambda: put(1, 24, xy24[:16]))
    out["xypixmap_depth1"] = outcome(c, lambda: put(1, 1, b"\x80\x40\x20\x10",
                                                    drawable=pix1, g=gc1))
    out["bad_format_9"] = outcome(c, lambda: put(9, 24, z24))
    # A size no drawable can hold, with a body that cannot match it.
    out["huge_wh_tiny_body"] = outcome(c, lambda: put(2, 24, z24, w=0xFFFF, h=0xFFFF))
    out["no_body"] = outcome(c, lambda: c.request(Op.PutImage, b"", detail=2))
    # And the server must still be answering afterwards.
    out["alive_after"] = still_answering(c)
    return out


@probe("image.putimage_roundtrip")
def image_putimage_roundtrip(c):
    """A BIG-REQUESTS-sized `PutImage`, read back with `GetImage`.

    One request bigger than the 262,144-byte buffer either end of the
    guest's relay holds - which is the exact size class the xspy capture
    recorded as short writes (`writev` of 261,684 bytes) just before every
    death. If the bytes come back changed, the large-transfer path is
    losing data; if the call hangs, it is the transfer itself."""
    if not c.enable_big_requests():
        return {"big_requests": False}
    w, h = 256, 256                       # 256 KiB of ZPixmap at depth 24
    pix = c.create_pixmap(w, h, depth=24)
    gc = c.create_gc(pix)
    c.sync()
    row = b"".join(struct.pack("<I", (x * 7 & 0xFF) << 16 | (x * 3 & 0xFF) << 8 | (x & 0xFF))
                   for x in range(w))
    data = row * h
    out = {"big_requests": True, "bytes": len(data)}
    try:
        c.request(Op.PutImage, struct.pack("<IIHHhhBB2x", pix, gc, w, h, 0, 0, 0, 24) + data,
                  detail=2)
        errs = c.sync()
    except (xwire.Hang, xwire.Died) as e:
        return dict(out, put="%s: %s" % (type(e).__name__, e))
    out["put"] = err_name(errs[0]) if errs else "Ok"
    try:
        depth, got = c.get_image(pix, 0, 0, w, h)
    except XError as e:
        return dict(out, get=err_name(e.err))
    except (xwire.Hang, xwire.Died) as e:
        return dict(out, get="%s: %s" % (type(e).__name__, e))
    out["get_depth"] = depth
    out["get_bytes"] = len(got)
    want = [struct.unpack_from("<I", row, x * 4)[0] & 0xFFFFFF for x in range(w)]
    first = [struct.unpack_from("<I", got, x * 4)[0] & 0xFFFFFF for x in range(w)] \
        if len(got) >= w * 4 else []
    lastoff = (h - 1) * w * 4
    last = [struct.unpack_from("<I", got, lastoff + x * 4)[0] & 0xFFFFFF for x in range(w)] \
        if len(got) >= lastoff + w * 4 else []
    out["first_row_round_trips"] = first == want
    out["last_row_round_trips"] = last == want
    return out


@probe("image.copyarea_edges")
def image_copyarea_edges(c):
    """`CopyArea`/`CopyPlane` with mismatched and out-of-range inputs.

    `XCopyArea` is the call at the top of the captured death backtrace, and
    a copy whose source is partly unavailable is the one case where this
    request *owes the client events* (`GraphicsExpose`, or `NoExpose` when
    there are none). A client that waits for those and never gets them
    looks exactly like one blocked in `_XReply`."""
    src = c.create_pixmap(16, 16, depth=24)
    dst = c.create_pixmap(16, 16, depth=24)
    deep = c.create_pixmap(16, 16, depth=32)
    mono = c.create_pixmap(16, 16, depth=1)
    gc = c.create_gc(dst, {xwire.GCv.GraphicsExposures: 1})
    gc32 = c.create_gc(deep)
    gcmono = c.create_gc(mono)
    c.sync()
    out = {}

    def copy(s, d, g, sx, sy, dx, dy, w, h):
        return c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", s, d, g, sx, sy, dx, dy, w, h))

    out["same_depth"] = outcome(c, lambda: copy(src, dst, gc, 0, 0, 0, 0, 8, 8))
    out["zero_size"] = outcome(c, lambda: copy(src, dst, gc, 0, 0, 0, 0, 0, 0))
    out["src_partly_outside"] = outcome(c, lambda: copy(src, dst, gc, 12, 12, 0, 0, 8, 8))
    out["src_wholly_outside"] = outcome(c, lambda: copy(src, dst, gc, 100, 100, 0, 0, 8, 8))
    out["src_negative"] = outcome(c, lambda: copy(src, dst, gc, -8, -8, 0, 0, 8, 8))
    out["dst_wholly_outside"] = outcome(c, lambda: copy(src, dst, gc, 0, 0, 100, 100, 8, 8))
    out["oversize"] = outcome(c, lambda: copy(src, dst, gc, 0, 0, 0, 0, 0xFFFF, 0xFFFF))
    out["depth24_to_depth32"] = outcome(c, lambda: copy(src, deep, gc32, 0, 0, 0, 0, 8, 8))
    out["depth24_to_depth1"] = outcome(c, lambda: copy(src, mono, gcmono, 0, 0, 0, 0, 8, 8))
    out["depth1_to_depth24"] = outcome(c, lambda: copy(mono, dst, gc, 0, 0, 0, 0, 8, 8))
    # A GC made for a drawable of another depth is BadMatch, whatever the
    # two drawables are.
    out["gc_of_wrong_depth"] = outcome(c, lambda: copy(src, dst, gc32, 0, 0, 0, 0, 8, 8))
    out["unknown_src"] = outcome(c, lambda: copy(unallocated(c), dst, gc, 0, 0, 0, 0, 8, 8))
    out["unknown_dst"] = outcome(c, lambda: copy(src, unallocated(c), gc, 0, 0, 0, 0, 8, 8))
    out["unknown_gc"] = outcome(c, lambda: copy(src, dst, unallocated(c), 0, 0, 0, 0, 8, 8))

    def plane(s, d, g, bit, w=8, h=8):
        return c.request(Op.CopyPlane,
                         struct.pack("<IIIhhhhHHI", s, d, g, 0, 0, 0, 0, w, h, bit))

    out["plane_bit1_from_depth1"] = outcome(c, lambda: plane(mono, dst, gc, 1))
    out["plane_bit0"] = outcome(c, lambda: plane(mono, dst, gc, 0))
    out["plane_above_depth"] = outcome(c, lambda: plane(mono, dst, gc, 1 << 16))
    out["plane_two_bits"] = outcome(c, lambda: plane(mono, dst, gc, 3))
    out["plane_to_depth1"] = outcome(c, lambda: plane(src, mono, gcmono, 1 << 8))
    out["plane_zero_size"] = outcome(c, lambda: plane(mono, dst, gc, 1, w=0, h=0))
    out["alive_after"] = still_answering(c)
    return out


@probe("image.copyarea_expose_events")
def image_copyarea_expose_events(c):
    """What a `CopyArea` with `graphics-exposures` owes the client.

    `NoExpose` means "all of the source was available"; `GraphicsExpose`
    means part of it was not and the client must repaint that part itself.
    Campaign finding F6 made `NoExpose` unconditional on the premise that
    "the source is always a live bitmap" - which holds for an in-bounds
    copy and not for one whose source rectangle is off the end of the
    drawable, the case every scroll produces at the top and bottom of its
    travel. Not a hang either way: `NoExpose` ends the usual wait loops
    too, so what is lost is the repaint, not the client."""
    src = c.create_pixmap(16, 16, depth=24)
    dst = c.create_pixmap(16, 16, depth=24)
    gc = c.create_gc(dst, {xwire.GCv.GraphicsExposures: 1})
    quiet = c.create_gc(dst, {xwire.GCv.GraphicsExposures: 0})
    c.sync()

    def kinds(g, sx, sy):
        c.drain_events()
        c.request(Op.CopyArea, struct.pack("<IIIhhhhHH", src, dst, g, sx, sy, 0, 0, 8, 8))
        c.sync()
        # 13 = GraphicsExpose, 14 = NoExpose.
        return sorted({e[0] & 0x7F for e in c.drain_events()})

    return {"in_bounds": kinds(gc, 0, 0),
            "source_partly_outside": kinds(gc, 12, 12),
            "source_wholly_outside": kinds(gc, 100, 100),
            "exposures_off_in_bounds": kinds(quiet, 0, 0),
            "exposures_off_outside": kinds(quiet, 100, 100)}


@probe("render.composite_edges")
def render_composite_edges(c):
    """`Composite` with the geometry and the picture pairings a toolkit
    gets wrong: zero extents, rectangles off the end of the source, and
    mismatched picture depths."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    src = c.create_pixmap(16, 16, depth=32)
    dst = c.create_pixmap(16, 16, depth=32)
    flat = c.create_pixmap(16, 16, depth=24)
    mono = c.create_pixmap(16, 16, depth=1)
    c.sync()
    # The format ids for the depths involved, read from the table.
    r = c.call(major, b"", detail=1)
    nf = struct.unpack_from("<I", r, 8)[0]
    byid = {}
    for i in range(nf):
        fid, ftype, depth = struct.unpack_from("<IBB2x", r, 32 + 28 * i)[0:3]
        if ftype == 1 and depth not in byid:
            byid[depth] = fid
    sp, dp, fp, mp = c.new_id(), c.new_id(), c.new_id(), c.new_id()
    c.request(major, struct.pack("<IIII", sp, src, argb, 0), detail=4)
    c.request(major, struct.pack("<IIII", dp, dst, argb, 0), detail=4)
    if 24 in byid:
        c.request(major, struct.pack("<IIII", fp, flat, byid[24], 0), detail=4)
    if 1 in byid:
        c.request(major, struct.pack("<IIII", mp, mono, byid[1], 0), detail=4)
    c.sync()
    out = {"present": True}

    def comp(s, m, d, sx=0, sy=0, mx=0, my=0, dx=0, dy=0, w=8, h=8, op=3):
        return c.request(major, struct.pack("<BxxxIIIhhhhhhHH",
                                            op, s, m, d, sx, sy, mx, my, dx, dy, w, h),
                         detail=8)

    out["plain"] = eo(lambda: comp(sp, 0, dp))
    out["zero_width"] = eo(lambda: comp(sp, 0, dp, w=0))
    out["zero_height"] = eo(lambda: comp(sp, 0, dp, h=0))
    out["zero_both"] = eo(lambda: comp(sp, 0, dp, w=0, h=0))
    out["src_rect_off_end"] = eo(lambda: comp(sp, 0, dp, sx=14, sy=14))
    out["src_rect_wholly_outside"] = eo(lambda: comp(sp, 0, dp, sx=200, sy=200))
    out["negative_src"] = eo(lambda: comp(sp, 0, dp, sx=-8, sy=-8))
    out["negative_dst"] = eo(lambda: comp(sp, 0, dp, dx=-8, dy=-8))
    out["oversize"] = eo(lambda: comp(sp, 0, dp, w=0xFFFF, h=0xFFFF))
    out["unknown_mask"] = eo(lambda: comp(sp, unallocated(c), dp))
    out["unknown_dst"] = eo(lambda: comp(sp, 0, unallocated(c)))
    out["mask_is_dst"] = eo(lambda: comp(sp, dp, dp))
    out["src_is_dst"] = eo(lambda: comp(dp, 0, dp))
    out["depth32_onto_depth24"] = eo(lambda: comp(sp, 0, fp))
    out["depth32_onto_depth1"] = eo(lambda: comp(sp, 0, mp))
    out["depth1_mask"] = eo(lambda: comp(sp, mp, dp))
    # Composite against a picture whose pixmap has been freed under it -
    # exactly what a toolkit does when it drops a surface it still holds a
    # Picture for.
    c.request(Op.FreePixmap, struct.pack("<I", src))
    c.sync()
    out["src_pixmap_freed"] = eo(lambda: comp(sp, 0, dp))
    out["alive_after"] = still_answering(c)
    return out


@probe("render.changepicture_edges")
def render_changepicture_edges(c):
    """`ChangePicture`, `SetPictureClipRectangles` and `SetPictureFilter`.

    A discarded `CPClipMask` in `ChangePicture` is already on this
    project's record as the bug that left a stale clip eating every fill in
    galculator, so the refusals around it are worth pinning: a clip this
    server keeps when the client meant to drop it is invisible until
    something stops drawing."""
    info = _render(c)
    if not info:
        return {"present": False}
    major, argb, base = info
    def eo(fn):
        return ext_outcome(c, fn, base)
    pix = c.create_pixmap(16, 16, depth=32)
    mask = c.create_pixmap(16, 16, depth=1)
    c.sync()
    pic = c.new_id()
    c.request(major, struct.pack("<IIII", pic, pix, argb, 0), detail=4)
    c.sync()
    out = {"present": True}
    CPRepeat, CPAlphaMap, CPClipMask = 0x1, 0x4, 0x40

    def change(picture, valuemask, values=b""):
        return c.request(major, struct.pack("<II", picture, valuemask) + values, detail=5)

    out["no_values"] = eo(lambda: change(pic, 0))
    out["repeat_normal"] = eo(lambda: change(pic, CPRepeat, struct.pack("<I", 1)))
    out["repeat_bad_value"] = eo(lambda: change(pic, CPRepeat, struct.pack("<I", 99)))
    out["clip_mask_none"] = eo(lambda: change(pic, CPClipMask, struct.pack("<I", 0)))
    out["clip_mask_real"] = eo(lambda: change(pic, CPClipMask, struct.pack("<I", mask)))
    out["clip_mask_unknown"] = eo(lambda: change(pic, CPClipMask, struct.pack("<I", unallocated(c))))
    out["alpha_map_unknown"] = eo(lambda: change(pic, CPAlphaMap, struct.pack("<I", unallocated(c))))
    out["undefined_mask_bit"] = eo(lambda: change(pic, 0x80000000, struct.pack("<I", 0)))
    out["unknown_picture"] = eo(lambda: change(unallocated(c), CPRepeat, struct.pack("<I", 1)))

    def clip(picture, rects, ordering=0):
        return c.request(major, struct.pack("<Ihh", picture, 0, 0) + rects, detail=6)

    one = struct.pack("<hhHH", 0, 0, 8, 8)
    out["clip_one_rect"] = eo(lambda: clip(pic, one))
    out["clip_no_rects"] = eo(lambda: clip(pic, b""))
    out["clip_zero_size_rect"] = eo(lambda: clip(pic, struct.pack("<hhHH", 0, 0, 0, 0)))
    out["clip_unknown_picture"] = eo(lambda: clip(unallocated(c), one))

    def filt(picture, name):
        n = name.encode()
        return c.request(major, struct.pack("<IHxx", picture, len(n)) + xwire.padded(n), detail=30)

    out["filter_nearest"] = eo(lambda: filt(pic, "nearest"))
    out["filter_bilinear"] = eo(lambda: filt(pic, "bilinear"))
    out["filter_unknown_name"] = eo(lambda: filt(pic, "nosuchfilter"))
    out["filter_empty_name"] = eo(lambda: filt(pic, ""))
    out["filter_unknown_picture"] = eo(lambda: filt(unallocated(c), "nearest"))
    out["alive_after"] = still_answering(c)
    return out


def run_probe(entry, path):
    c = None
    try:
        c = xwire.Conn(path=path, timeout=10.0)
        # min/max keycode are not parsed by xwire's setup; read them here.
        c.min_keycode, c.max_keycode = 8, 255
        return {"ok": True, "value": entry["fn"](c)}
    except Exception as e:  # noqa: BLE001 - a probe failing is a result
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    finally:
        if c is not None:
            try:
                c.close()
            except Exception:
                pass


def flatten(value, prefix=""):
    """dict/list -> {path: leaf}, so a diff can name the exact field."""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            out.update(flatten(v, "%s.%s" % (prefix, k) if prefix else str(k)))
        return out
    if isinstance(value, list):
        return {prefix: json.dumps(value)}
    return {prefix: value}


def diff_values(a, b):
    fa, fb = flatten(a), flatten(b)
    out = []
    for key in sorted(set(fa) | set(fb)):
        if fa.get(key, "<missing>") != fb.get(key, "<missing>"):
            out.append((key, fa.get(key, "<missing>"), fb.get(key, "<missing>")))
    return out


def socket_for(display):
    return "/tmp/.X11-unix/X%s" % display.lstrip(":").split(".")[0]


def start_xvfb(display, width=1280, height=800):
    path = socket_for(display)
    if os.path.exists(path):
        return None
    proc = subprocess.Popen(["Xvfb", display, "-screen", "0", "%dx%dx24" % (width, height)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(path):
            time.sleep(0.3)
            return proc
        time.sleep(0.1)
    proc.terminate()
    raise SystemExit("xdiff: Xvfb %s did not come up (is xvfb installed?)" % display)


def main():
    ap = argparse.ArgumentParser(description="differential oracle: mslgd vs a real X server")
    ap.add_argument("--target", default=os.environ.get("DISPLAY", ":1"), help="the server under test")
    ap.add_argument("--ref", default=":7", help="the reference server")
    ap.add_argument("--no-auto", action="store_true", help="do not start Xvfb for --ref")
    ap.add_argument("--only", default="", help="probes whose id contains this")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", default=os.path.join(HERE, "results", "xdiff-latest.json"))
    args = ap.parse_args()

    if args.list:
        for p in PROBES:
            print("%-28s %s%s" % (p["id"], "" if p["strict"] else "(info) ", p["note"].split("\n")[0]))
        return 0

    selected = [p for p in PROBES if args.only in p["id"]]
    if not selected:
        raise SystemExit("xdiff: no probe matches %r" % args.only)

    target_path = socket_for(args.target)
    if not os.path.exists(target_path):
        raise SystemExit("xdiff: nothing listening on %s - launch a GUI app first" % args.target)

    spawned = None if args.no_auto else start_xvfb(args.ref)
    try:
        results, diffs, infos, errors = {}, 0, 0, 0
        print("xdiff: %s (target) vs %s (reference), %d probes\n" % (args.target, args.ref, len(selected)))
        for entry in selected:
            got = run_probe(entry, target_path)
            want = run_probe(entry, socket_for(args.ref))
            row = {"strict": entry["strict"], "target": got, "reference": want}
            if not got["ok"] or not want["ok"]:
                row["status"] = "ERR"
                errors += 1
                print("\033[31mERR   \033[0m %-28s target=%s ref=%s" % (
                    entry["id"], got.get("error", "ok"), want.get("error", "ok")))
            else:
                delta = diff_values(got["value"], want["value"])
                row["delta"] = [list(d) for d in delta]
                if not delta:
                    row["status"] = "SAME"
                    print("\033[32mSAME  \033[0m %-28s" % entry["id"])
                elif entry["id"] in KNOWN:
                    row["status"] = "KNOWN"
                    print("\033[36mKNOWN \033[0m %-28s %d field(s) - %s" % (
                        entry["id"], len(delta), KNOWN[entry["id"]]))
                elif not entry["strict"]:
                    row["status"] = "INFO"
                    infos += 1
                    print("\033[33mINFO  \033[0m %-28s %d field(s)" % (entry["id"], len(delta)))
                else:
                    row["status"] = "DIFF"
                    diffs += 1
                    print("\033[31mDIFF  \033[0m %-28s %d field(s)" % (entry["id"], len(delta)))
                if row["status"] in ("DIFF", "INFO") or (row["status"] == "KNOWN" and args.only):
                    for key, mine, theirs in delta[:12]:
                        print("          %-34s mslgd=%-22r ref=%r" % (key, mine, theirs))
                    if len(delta) > 12:
                        print("          ... %d more" % (len(delta) - 12))
            results[entry["id"]] = row

        print("\n\033[31mDIFF %d\033[0m  \033[33mINFO %d\033[0m  \033[31mERR %d\033[0m  \033[32mSAME %d\033[0m" % (
            diffs, infos, errors, sum(1 for r in results.values() if r["status"] == "SAME")))

        os.makedirs(os.path.dirname(args.json), exist_ok=True)
        previous = {}
        if os.path.exists(args.json):
            try:
                with open(args.json) as fh:
                    previous = json.load(fh).get("probes", {})
            except Exception:
                previous = {}
            os.replace(args.json, args.json.replace("latest", "previous"))
        with open(args.json, "w") as fh:
            json.dump({"target": args.target, "reference": args.ref, "when": time.time(),
                       "probes": results}, fh, indent=1, sort_keys=True)

        changed = [(k, previous[k]["status"], v["status"]) for k, v in results.items()
                   if k in previous and previous[k]["status"] != v["status"]]
        if changed:
            print("\nchanged since last run:")
            for key, was, now in changed:
                print("  %-28s %s -> %s" % (key, was, now))
        return 1 if diffs or errors else 0
    finally:
        if spawned is not None:
            spawned.terminate()


if __name__ == "__main__":
    sys.exit(main())
