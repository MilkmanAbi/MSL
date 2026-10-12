"""events: what every toolkit waits for, delivered exactly.

GTK, Qt, Tk and Xt all block on events the server owes them: the Expose
after a map, the ConfigureNotify after a resize, the PropertyNotify that
carries a server timestamp, and the selection dance behind every copy and
paste (two clients, SelectionRequest -> property -> SelectionNotify). A
missing event is not an error a client can see - it is a toolkit waiting
forever, a clipboard that never pastes, a window that never draws.
"""
import struct

from xwire import Op, CW, EM
from xhell import test, Fail

KeyPress, Expose, CreateNotify, DestroyNotify = 2, 12, 16, 17
UnmapNotify, MapNotify, ReparentNotify, ConfigureNotify = 18, 19, 21, 22
PropertyNotify, SelectionClear, SelectionRequest, SelectionNotify, ClientMessage = 28, 29, 30, 31, 33
STRING = 31


def code(ev):
    return ev[0] & 0x7F


def u32(ev, off):
    return struct.unpack_from("<I", ev, off)[0]


def want(c, kind, what, pred=None, timeout=3):
    ev = c.wait_event(lambda e: code(e) == kind and (pred is None or pred(e)), timeout)
    if ev is None:
        raise Fail("%s: no event %d arrived (got codes %s)" % (what, kind, [code(e) for e in c.events][:12]))
    return ev


def none_of(c, kind, what, pred=None, timeout=0.5):
    c.sync()
    ev = c.wait_event(lambda e: code(e) == kind and (pred is None or pred(e)), timeout)
    if ev is not None:
        raise Fail("%s: unexpected event %d" % (what, kind))


def top(c, mask, w=120, h=90):
    """An override-redirect top-level (no title bar, no focus stealing)."""
    return c.create_window(x=40, y=40, w=w, h=h, attrs={CW.BackPixel: 0xFFFFFF, CW.OverrideRedirect: 1,
                                                        CW.EventMask: mask})


def select(c, wid, mask):
    c.request(Op.ChangeWindowAttributes, struct.pack("<II", wid, CW.EventMask) + struct.pack("<I", mask))


def change_prop(c, wid, prop, data, mode=0, type_=STRING):
    return c.request(Op.ChangeProperty, struct.pack("<IIIBxxxI", wid, prop, type_, 8, len(data)) + data,
                     detail=mode)


def get_prop(c, wid, prop, delete=0):
    r = c.call(Op.GetProperty, struct.pack("<IIIII", wid, prop, 0, 0, 1 << 20), detail=delete)
    n = u32(r, 16)
    fmt = r[1]
    return r[32:32 + n * max(1, fmt // 8)]


@test("events", "map-notify-and-expose", 1)
def map_expose(ctx):
    """MapWindow on a selected top-level: MapNotify, then an Expose for it."""
    c = ctx.conn()
    w = top(c, EM.StructureNotify | EM.Exposure)
    c.map(w)
    want(c, MapNotify, "MapNotify", lambda e: u32(e, 8) == w)
    ev = want(c, Expose, "Expose after map", lambda e: u32(e, 4) == w)
    ex, ey, ew, eh = struct.unpack_from("<HHHH", ev, 8)
    ctx.expect(ew > 0 and eh > 0 and ex + ew <= 120 and ey + eh <= 90, "Expose rect %r inside the window" % ((ex, ey, ew, eh),))
    c.destroy(w)


@test("events", "child-expose-on-map", 1)
def child_expose(ctx):
    """A child mapped inside a mapped parent gets its own Expose."""
    c = ctx.conn()
    w = top(c, 0)
    c.map(w)
    ch = c.create_window(parent=w, x=10, y=10, w=30, h=20, attrs={CW.BackPixel: 0xFF0000, CW.EventMask: EM.Exposure})
    c.map(ch)
    want(c, Expose, "child Expose", lambda e: u32(e, 4) == ch)
    c.destroy(w)


@test("events", "configure-notify-both-masks", 1)
def configure(ctx):
    """Resize a child: ConfigureNotify to the child's StructureNotify AND the
    parent's SubstructureNotify, both with the new size."""
    c = ctx.conn()
    p = top(c, EM.SubstructureNotify)
    ch = c.create_window(parent=p, x=5, y=5, w=20, h=20, attrs={CW.EventMask: EM.StructureNotify})
    c.drain_events()
    c.request(Op.ConfigureWindow, struct.pack("<IHxxII", ch, 0x4 | 0x8, 55, 33))
    got = []
    for _ in range(2):
        ev = want(c, ConfigureNotify, "ConfigureNotify", lambda e: u32(e, 8) == ch)
        got.append((u32(ev, 4), struct.unpack_from("<HH", ev, 20)))
    events_on = sorted(g[0] for g in got)
    ctx.expect(events_on == sorted([ch, p]), "one to the child, one to the parent: %r" % events_on)
    ctx.expect(all(g[1] == (55, 33) for g in got), "new size in both: %r" % got)
    c.destroy(p)


@test("events", "destroy-notify-inferiors-first", 1)
def destroy_order(ctx):
    """Destroying a parent: DestroyNotify for the child before the parent."""
    c = ctx.conn()
    root_watch = top(c, EM.SubstructureNotify)
    p = c.create_window(parent=root_watch, w=40, h=40, attrs={CW.EventMask: EM.StructureNotify | EM.SubstructureNotify})
    ch = c.create_window(parent=p, w=10, h=10, attrs={CW.EventMask: EM.StructureNotify})
    c.drain_events()
    c.destroy(p)
    order = []
    while True:
        ev = c.wait_event(lambda e: code(e) == DestroyNotify, 1)
        if ev is None:
            break
        order.append(u32(ev, 8))
    ctx.expect(ch in order and p in order, "DestroyNotify for both (%r)" % order)
    if ch in order and p in order:
        ctx.expect(order.index(ch) < order.index(p), "child first: %r" % order)
    c.destroy(root_watch)


@test("events", "unmap-and-reparent-notify", 1)
def unmap_reparent(ctx):
    c = ctx.conn()
    a = top(c, 0)
    b = top(c, 0)
    ch = c.create_window(parent=a, w=10, h=10, attrs={CW.EventMask: EM.StructureNotify})
    c.map(ch)
    want(c, MapNotify, "MapNotify of the child", lambda e: u32(e, 8) == ch)
    c.request(Op.UnmapWindow, struct.pack("<I", ch))
    want(c, UnmapNotify, "UnmapNotify", lambda e: u32(e, 8) == ch)
    c.request(Op.ReparentWindow, struct.pack("<IIhh", ch, b, 3, 4))
    ev = want(c, ReparentNotify, "ReparentNotify", lambda e: u32(e, 8) == ch)
    ctx.expect(u32(ev, 12) == b, "new parent in the event")
    c.destroy(a)
    c.destroy(b)


@test("events", "property-notify-new-and-deleted", 1)
def property_notify(ctx):
    """ChangeProperty -> PropertyNotify NewValue; DeleteProperty -> Deleted;
    deleting a property that isn't there -> nothing. Toolkits get their
    server timestamps this way (GTK's gdk_x11_get_server_time)."""
    c = ctx.conn()
    w = c.create_window(attrs={CW.EventMask: EM.PropertyChange})
    atom = c.intern("XHELL_PN")
    change_prop(c, w, atom, b"x")
    ev = want(c, PropertyNotify, "PropertyNotify NewValue", lambda e: u32(e, 4) == w)
    ctx.expect(u32(ev, 8) == atom and ev[16] == 0, "atom + state NewValue")
    ctx.expect(u32(ev, 12) != 0, "a real timestamp (GTK uses it as server time)")
    c.request(Op.DeleteProperty, struct.pack("<II", w, atom))
    ev = want(c, PropertyNotify, "PropertyNotify Deleted", lambda e: u32(e, 4) == w)
    ctx.expect(ev[16] == 1, "state Deleted")
    c.request(Op.DeleteProperty, struct.pack("<II", w, atom))
    none_of(c, PropertyNotify, "deleting a missing property", lambda e: u32(e, 4) == w)


@test("events", "property-notify-zero-length-append", 1)
def zero_append(ctx):
    """GTK's server-time trick: append ZERO bytes to a property. The value
    doesn't change, but a PropertyNotify must still come - GTK blocks on it."""
    c = ctx.conn()
    w = c.create_window(attrs={CW.EventMask: EM.PropertyChange})
    atom = c.intern("GDK_TIMESTAMP_PROP")
    change_prop(c, w, atom, b"", mode=2)
    want(c, PropertyNotify, "PropertyNotify for a zero-length append", lambda e: u32(e, 4) == w)


@test("events", "get-property-delete-notifies", 1)
def get_delete(ctx):
    """GetProperty(delete=1) of the whole value deletes it, with a
    PropertyNotify Deleted - the INCR/selection receiver's ack."""
    c = ctx.conn()
    w = c.create_window(attrs={CW.EventMask: EM.PropertyChange})
    atom = c.intern("XHELL_GD")
    change_prop(c, w, atom, b"payload")
    want(c, PropertyNotify, "NewValue", lambda e: u32(e, 4) == w)
    ctx.expect(get_prop(c, w, atom, delete=1) == b"payload", "value returned")
    ev = want(c, PropertyNotify, "Deleted after GetProperty(delete)", lambda e: u32(e, 4) == w)
    ctx.expect(ev[16] == 1, "state Deleted")
    ctx.expect(get_prop(c, w, atom) == b"", "gone")


@test("events", "event-sequence-number", 1)
def event_seq(ctx):
    """An event carries the sequence number of the last request processed
    before it was generated; Xlib uses it to order errors vs events."""
    c = ctx.conn()
    w = c.create_window(attrs={CW.EventMask: EM.PropertyChange})
    atom = c.intern("XHELL_SEQ")
    seq = change_prop(c, w, atom, b"s")
    ev = want(c, PropertyNotify, "PropertyNotify", lambda e: u32(e, 4) == w)
    got = struct.unpack_from("<H", ev, 2)[0]
    ctx.expect(got == seq & 0xFFFF, "event seq %d == request seq %d" % (got, seq & 0xFFFF))


@test("events", "property-notify-flood-in-order", 2)
def prop_flood(ctx):
    """5000 ChangeProperty requests: 5000 PropertyNotify, none lost, in order."""
    c = ctx.conn(timeout=30)
    w = c.create_window(attrs={CW.EventMask: EM.PropertyChange})
    atoms = [c.intern("XHELL_FLOOD_%d" % i) for i in range(50)]
    sent = []
    for i in range(5000):
        a = atoms[i % 50]
        change_prop(c, w, a, b"%d" % i)
        sent.append(a)
    c.sync()
    got = []
    while len(got) < 5000:
        ev = c.wait_event(lambda e: code(e) == PropertyNotify, 3)
        if ev is None:
            break
        got.append(u32(ev, 8))
    ctx.metric("events", len(got))
    ctx.expect(got == sent, "all 5000 in order (got %d)" % len(got))


@test("events", "cross-client-property-watch", 1)
def cross_watch(ctx):
    """Client B selects PropertyChange on A's window; A changes a property;
    B hears it (event masks are per client - the WM/pager pattern)."""
    a = ctx.conn()
    b = ctx.conn()
    w = a.create_window()
    a.sync()
    select(b, w, EM.PropertyChange)
    b.sync()
    atom = a.intern("XHELL_WATCH")
    change_prop(a, w, atom, b"hi")
    a.sync()
    want(b, PropertyNotify, "B's PropertyNotify for A's window", lambda e: u32(e, 4) == w)
    none_of(a, PropertyNotify, "A did not select it")


@test("events", "selection-round-trip", 1)
def selection(ctx):
    """Copy/paste between two clients, the way every toolkit does it:
    A owns CLIPBOARD; B converts; A gets SelectionRequest, writes the
    property on B's window, SendEvents SelectionNotify; B reads it."""
    a = ctx.conn()
    b = ctx.conn()
    wa = a.create_window()
    wb = b.create_window()
    sel = a.intern("CLIPBOARD")
    utf8 = a.intern("UTF8_STRING")
    prop = b.intern("XHELL_PASTE")
    a.request(Op.SetSelectionOwner, struct.pack("<III", wa, sel, 0))
    a.sync()
    r = b.call(Op.GetSelectionOwner, struct.pack("<I", sel))
    ctx.expect(u32(r, 8) == wa, "B sees A as the owner")
    b.request(Op.ConvertSelection, struct.pack("<IIIII", wb, sel, utf8, prop, 0))
    b.sync()
    req = want(a, SelectionRequest, "A's SelectionRequest")
    owner, requestor, s, t, p = struct.unpack_from("<IIIII", req, 8)
    ctx.expect((owner, requestor, s, t, p) == (wa, wb, sel, utf8, prop),
               "SelectionRequest fields %r" % ((owner, requestor, s, t, p),))
    change_prop(a, wb, prop, "héllo".encode(), type_=utf8)
    notify = struct.pack("<BxxxIIIII", SelectionNotify, 0, wb, sel, utf8, prop) + b"\0" * 8
    a.request(Op.SendEvent, struct.pack("<II", wb, 0) + notify)
    a.sync()
    ev = want(b, SelectionNotify, "B's SelectionNotify")
    ctx.expect(ev[0] & 0x80, "marked as sent (SendEvent bit)")
    ctx.expect(get_prop(b, wb, prop) == "héllo".encode(), "B reads the pasted text")


@test("events", "selection-clear-on-steal", 1)
def selection_clear(ctx):
    a = ctx.conn()
    b = ctx.conn()
    wa = a.create_window()
    wb = b.create_window()
    sel = a.intern("XHELL_SEL")
    a.request(Op.SetSelectionOwner, struct.pack("<III", wa, sel, 0))
    a.sync()
    b.request(Op.SetSelectionOwner, struct.pack("<III", wb, sel, 0))
    b.sync()
    ev = want(a, SelectionClear, "A's SelectionClear")
    ctx.expect(u32(ev, 8) == wa and u32(ev, 12) == sel, "owner window + selection")
    r = a.call(Op.GetSelectionOwner, struct.pack("<I", sel))
    ctx.expect(u32(r, 8) == wb, "B owns it now")


@test("events", "selection-owner-gone-on-disconnect", 1)
def owner_gone(ctx):
    """The owner's client disconnects: ownership reverts to None. A
    clipboard manager that still sees the dead owner hangs every paste."""
    a = ctx.conn()
    b = ctx.conn()
    sel = a.intern("XHELL_SEL_GONE")
    wa = a.create_window()
    a.request(Op.SetSelectionOwner, struct.pack("<III", wa, sel, 0))
    a.sync()
    a.close()
    import time
    for _ in range(20):
        r = b.call(Op.GetSelectionOwner, struct.pack("<I", sel))
        if u32(r, 8) == 0:
            return
        time.sleep(0.05)
    raise Fail("owner still %#x after its client disconnected" % u32(r, 8))


@test("events", "convert-unowned-selection", 1)
def convert_unowned(ctx):
    """ConvertSelection with no owner: the SERVER answers with a
    SelectionNotify whose property is None. Without it, paste hangs."""
    c = ctx.conn()
    w = c.create_window()
    sel = c.intern("XHELL_NOBODY_OWNS_THIS")
    prop = c.intern("XHELL_P")
    c.request(Op.ConvertSelection, struct.pack("<IIIII", w, sel, STRING, prop, 0))
    ev = want(c, SelectionNotify, "server-generated SelectionNotify")
    ctx.expect(u32(ev, 8) == w and u32(ev, 20) == 0, "requestor w, property None")


@test("events", "sendevent-empty-mask-goes-to-creator", 1)
def sendevent_creator(ctx):
    """SendEvent with event-mask 0 goes to the window's CREATOR (spec), even
    when another client sends it - how WM_PROTOCOLS / _NET_WM_PING reach
    an app, and how GTK talks to its own windows."""
    a = ctx.conn()
    b = ctx.conn()
    w = a.create_window()
    a.sync()
    atom = b.intern("XHELL_MSG")
    ev = struct.pack("<BBHII", ClientMessage, 32, 0, w, atom) + struct.pack("<5I", 1, 2, 3, 4, 5)
    b.request(Op.SendEvent, struct.pack("<II", w, 0) + ev)
    b.sync()
    got = want(a, ClientMessage, "ClientMessage at the creator")
    ctx.expect(got[0] & 0x80, "SendEvent bit set")
    ctx.expect(struct.unpack_from("<5I", got, 12) == (1, 2, 3, 4, 5), "payload intact")
    none_of(b, ClientMessage, "the sender does not get a copy")


@test("events", "sendevent-mask-to-selectors", 1)
def sendevent_mask(ctx):
    """SendEvent with a mask goes to every client selecting it on the
    window (the _NET_WM_STATE-to-root pattern), not to the creator."""
    a = ctx.conn()
    b = ctx.conn()
    w = a.create_window()
    a.sync()
    select(b, w, EM.StructureNotify)
    b.sync()
    ev = struct.pack("<BBHII", ClientMessage, 32, 0, w, 1) + b"\0" * 20
    a.request(Op.SendEvent, struct.pack("<II", w, EM.StructureNotify) + ev)
    a.sync()
    want(b, ClientMessage, "delivered to the selecting client")
    none_of(a, ClientMessage, "not to the creator, who didn't select it")
