"""xwire - a raw X11 protocol client for testing mslgd.

Speaks the protocol byte for byte (no Xlib/xcb in the guest), so a test can
send exactly what it wants - including out-of-spec requests a normal
library would never produce. mslgd has to stay up whatever a buggy client
sends, and this is how that gets checked.

Handles, because the tests depend on it:
  * pipelining - requests go out without waiting; replies, errors and
    events are routed back by sequence number whenever they arrive
  * 16-bit sequence wraparound - a full counter is kept and wire values are
    mapped back onto it
  * BIG-REQUESTS - enabled on demand; large requests use the extended form
  * failures - a server that stops answering raises Hang, one that closes
    the connection raises Died
"""
import os
import select
import socket
import struct
import time


class Died(Exception):
    """The server closed the connection."""


class Hang(Exception):
    """The server did not answer within the timeout."""


class XError(Exception):
    """An X error arrived where a reply was expected."""

    def __init__(self, err):
        self.err = err
        super().__init__(repr(err))


ERROR_NAMES = {
    1: "BadRequest", 2: "BadValue", 3: "BadWindow", 4: "BadPixmap", 5: "BadAtom",
    6: "BadCursor", 7: "BadFont", 8: "BadMatch", 9: "BadDrawable", 10: "BadAccess",
    11: "BadAlloc", 12: "BadColor", 13: "BadGC", 14: "BadIDChoice", 15: "BadName",
    16: "BadLength", 17: "BadImplementation",
}


class ErrorPacket:
    __slots__ = ("code", "seq", "value", "minor", "major")

    def __init__(self, code, seq, value, minor, major):
        self.code, self.seq, self.value, self.minor, self.major = code, seq, value, minor, major

    @property
    def name(self):
        return ERROR_NAMES.get(self.code, "Error%d" % self.code)

    def __repr__(self):
        return "%s(major=%d minor=%d value=0x%x seq=%d)" % (
            self.name, self.major, self.minor, self.value, self.seq)


class Op:
    CreateWindow = 1; ChangeWindowAttributes = 2; GetWindowAttributes = 3; DestroyWindow = 4
    DestroySubwindows = 5; ReparentWindow = 7; MapWindow = 8; MapSubwindows = 9
    UnmapWindow = 10; UnmapSubwindows = 11; ConfigureWindow = 12; CirculateWindow = 13
    GetGeometry = 14; QueryTree = 15; InternAtom = 16; GetAtomName = 17; ChangeProperty = 18
    DeleteProperty = 19; GetProperty = 20; ListProperties = 21; SetSelectionOwner = 22
    GetSelectionOwner = 23; ConvertSelection = 24; SendEvent = 25; GrabPointer = 26
    UngrabPointer = 27; GrabButton = 28; UngrabButton = 29; ChangeActivePointerGrab = 30
    GrabKeyboard = 31; UngrabKeyboard = 32; GrabKey = 33; UngrabKey = 34; AllowEvents = 35
    GrabServer = 36; UngrabServer = 37; QueryPointer = 38
    TranslateCoordinates = 40; WarpPointer = 41; SetInputFocus = 42; GetInputFocus = 43
    QueryKeymap = 44; OpenFont = 45; CloseFont = 46; QueryFont = 47; QueryTextExtents = 48
    ListFonts = 49; GetFontPath = 52; CreatePixmap = 53; FreePixmap = 54; CreateGC = 55
    ChangeGC = 56; CopyGC = 57; SetDashes = 58; SetClipRectangles = 59; FreeGC = 60
    ClearArea = 61; CopyArea = 62; CopyPlane = 63; PolyPoint = 64; PolyLine = 65
    PolySegment = 66; PolyRectangle = 67; PolyArc = 68; FillPoly = 69
    PolyFillRectangle = 70; PolyFillArc = 71; PutImage = 72; GetImage = 73
    PolyText8 = 74; ImageText8 = 76; ImageText16 = 77; CreateColormap = 78; FreeColormap = 79
    AllocColor = 84; QueryColors = 91; LookupColor = 92; CreateCursor = 93
    CreateGlyphCursor = 94; FreeCursor = 95; QueryBestSize = 97; QueryExtension = 98
    ListExtensions = 99; GetKeyboardMapping = 101; ChangeKeyboardControl = 102
    GetKeyboardControl = 103; Bell = 104; ChangePointerControl = 105
    GetPointerControl = 106; SetScreenSaver = 107; GetScreenSaver = 108
    ChangeHosts = 109; ListHosts = 110; SetAccessControl = 111; SetCloseDownMode = 112
    KillClient = 113; RotateProperties = 114; ForceScreenSaver = 115
    SetPointerMapping = 116; SetModifierMapping = 118
    GetPointerMapping = 117; GetModifierMapping = 119; NoOperation = 127


class CW:
    BackPixmap = 1 << 0; BackPixel = 1 << 1; BorderPixel = 1 << 3; BitGravity = 1 << 4
    OverrideRedirect = 1 << 9; EventMask = 1 << 11; Colormap = 1 << 13; Cursor = 1 << 14


class GCv:
    Function = 1 << 0; PlaneMask = 1 << 1; Foreground = 1 << 2; Background = 1 << 3
    LineWidth = 1 << 4; LineStyle = 1 << 5; FillStyle = 1 << 8; FillRule = 1 << 9
    Tile = 1 << 10; Stipple = 1 << 11; Font = 1 << 14; SubwindowMode = 1 << 15
    GraphicsExposures = 1 << 16; ClipXOrigin = 1 << 17; ClipYOrigin = 1 << 18


class EM:
    KeyPress = 1 << 0; ButtonPress = 1 << 2; Exposure = 1 << 15
    StructureNotify = 1 << 17; SubstructureNotify = 1 << 19; PropertyChange = 1 << 22


def pad4(n):
    return (4 - n % 4) % 4


def padded(b):
    return b + b"\0" * pad4(len(b))


def value_list(items):
    """{bit: value} -> (mask, bytes): ascending bit order, CARD32 each."""
    mask, out = 0, b""
    for bit in sorted(items):
        mask |= bit
        out += struct.pack("<I", items[bit] & 0xFFFFFFFF)
    return mask, out


def default_socket_path():
    disp = os.environ.get("DISPLAY", ":1")
    num = disp.split(":")[-1].split(".")[0] or "1"
    return "/tmp/.X11-unix/X%s" % num


class Conn:
    """One connection. Every wait is bounded by `timeout`."""

    def __init__(self, path=None, timeout=10.0, byte_order=b"l"):
        self.path = path or default_socket_path()
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(self.path)
        self.order = "<" if byte_order == b"l" else ">"
        self.buf = b""
        self.seq = 0
        self.replies = {}
        self.errors = []
        self.events = []
        self.history = []
        self.big_requests = False
        self.dead = False
        self._next_id = 0
        self._handshake(byte_order)

    # ------------------------------------------------------------- setup

    def _handshake(self, byte_order):
        self._send(struct.pack(self.order + "cxHHHHxx", byte_order, 11, 0, 0, 0))
        head = self._read_exact(8)
        extra = struct.unpack(self.order + "H", head[6:8])[0] * 4
        body = self._read_exact(extra)
        if head[0] != 1:
            reason = body[:head[1]].decode("latin-1", "replace")
            raise Died("setup refused: %s" % reason)
        o = self.order
        (self.release, self.id_base, self.id_mask, _, vlen, self.max_req_words,
         nscreens, nformats) = struct.unpack(o + "IIIIHHBB", body[:22])
        self.image_byte_order = body[22]
        self.bitmap_bit_order = body[23]   # 0 LSBFirst, 1 MSBFirst
        self.bitmap_unit, self.bitmap_pad = body[24], body[25]
        off = 32 + vlen + pad4(vlen)
        self.formats = {}
        for i in range(nformats):
            depth, bpp, spad = struct.unpack(o + "BBB", body[off:off + 3])
            self.formats[depth] = (bpp, spad)
            off += 8
        (self.root, self.colormap, self.white, self.black, _, self.width, self.height,
         _, _, _, _, self.root_visual, _, _, self.root_depth, ndepths) = struct.unpack(
            o + "IIIIIHHHHHHIBBBB", body[off:off + 40])
        off += 40
        self.visuals = {}   # depth -> [visual id]
        for _ in range(ndepths):
            depth, nvis = struct.unpack(o + "BxH", body[off:off + 4])
            off += 8
            for v in range(nvis):
                vid = struct.unpack(o + "I", body[off:off + 4])[0]
                self.visuals.setdefault(depth, []).append(vid)
                off += 24

    def new_id(self):
        # Walk the id space from the top of the mask downward-safe range.
        self._next_id += 1
        return self.id_base | (self._next_id & self.id_mask)

    # -------------------------------------------------------------- I/O

    def _send(self, data):
        """Writes everything, reading whatever the server sends meanwhile.

        A plain sendall deadlocks against any server once the client
        pipelines more reply-bearing requests than the socket buffers hold:
        the server blocks writing replies nobody reads, stops reading, and
        the client blocks writing. Xlib avoids it the same way - select on
        both directions and drain input while output is pending."""
        view = memoryview(data)
        deadline = time.monotonic() + self.timeout
        while view:
            r, w, _ = select.select([self.sock], [self.sock], [], max(0, deadline - time.monotonic()))
            if not r and not w:
                raise Hang("server stopped reading (send blocked %.1fs)" % self.timeout)
            if r:
                try:
                    chunk = self.sock.recv(1 << 20)
                except (ConnectionResetError, OSError) as e:
                    self.dead = True
                    raise Died("recv failed: %s" % e)
                if not chunk:
                    self.dead = True
                    raise Died("server closed the connection")
                self.buf += chunk
                deadline = time.monotonic() + self.timeout
            if w:
                try:
                    n = self.sock.send(view[:1 << 16])
                except (BrokenPipeError, ConnectionResetError, OSError) as e:
                    self.dead = True
                    raise Died("send failed: %s" % e)
                view = view[n:]
                deadline = time.monotonic() + self.timeout

    def _fill(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Hang("no answer within %.1fs" % self.timeout)
        r, _, _ = select.select([self.sock], [], [], remaining)
        if not r:
            raise Hang("no answer within %.1fs" % self.timeout)
        try:
            chunk = self.sock.recv(1 << 20)
        except (ConnectionResetError, OSError) as e:
            self.dead = True
            raise Died("recv failed: %s" % e)
        if not chunk:
            self.dead = True
            raise Died("server closed the connection")
        self.buf += chunk

    def _read_exact(self, n):
        deadline = time.monotonic() + self.timeout
        while len(self.buf) < n:
            self._fill(deadline)
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _full_seq(self, wire):
        # Map a 16-bit wire sequence onto the full counter: the most recent
        # full value with those low bits that is not in the future.
        cand = (self.seq & ~0xFFFF) | wire
        if cand > self.seq:
            cand -= 0x10000
        return cand

    def _parse_available(self):
        o = self.order
        while len(self.buf) >= 32:
            kind = self.buf[0]
            if kind == 1:
                extra = struct.unpack(o + "I", self.buf[4:8])[0] * 4
                if len(self.buf) < 32 + extra:
                    return
                pkt, self.buf = self.buf[:32 + extra], self.buf[32 + extra:]
                wire = struct.unpack(o + "H", pkt[2:4])[0]
                self.replies[self._full_seq(wire)] = pkt
            elif kind == 0:
                pkt, self.buf = self.buf[:32], self.buf[32:]
                code = pkt[1]
                wire, value, minor, major = struct.unpack(o + "HIHB", pkt[2:11])
                self.errors.append(ErrorPacket(code, self._full_seq(wire), value, minor, major))
            else:
                size = 32
                if kind & 0x7F == 35:  # GenericEvent
                    size += struct.unpack(o + "I", self.buf[4:8])[0] * 4
                    if len(self.buf) < size:
                        return
                pkt, self.buf = self.buf[:size], self.buf[size:]
                self.events.append(pkt)

    # ---------------------------------------------------------- requests

    def request(self, opcode, data=b"", detail=0):
        """Sends one request; returns its full sequence number."""
        data = padded(data)
        words = 1 + len(data) // 4
        if words <= 0xFFFF:
            pkt = struct.pack(self.order + "BBH", opcode, detail, words) + data
        elif self.big_requests:
            pkt = struct.pack(self.order + "BBHI", opcode, detail, 0, words + 1) + data
        else:
            raise ValueError("request of %d words needs BIG-REQUESTS" % words)
        return self.raw(pkt, counts=True)

    def raw(self, pkt, counts=True):
        """Sends bytes exactly as given. `counts` says whether the server will
        treat them as one request (for sequence bookkeeping)."""
        self._send(pkt)
        if counts:
            self.seq += 1
        self.history.append((self.seq, pkt[:48]))
        if len(self.history) > 64:
            self.history = self.history[-64:]
        return self.seq

    def wait_reply(self, seq):
        """The reply to request `seq`, or XError if it answered with an error."""
        deadline = time.monotonic() + self.timeout
        while True:
            self._parse_available()
            if seq in self.replies:
                return self.replies.pop(seq)
            for e in self.errors:
                if e.seq == seq:
                    self.errors.remove(e)
                    raise XError(e)
            self._fill(deadline)

    def call(self, opcode, data=b"", detail=0):
        return self.wait_reply(self.request(opcode, data, detail))

    def sync(self):
        """Round trip. Returns (and clears) every error raised so far."""
        self.call(Op.GetInputFocus)
        self._parse_available()
        errs, self.errors = self.errors, []
        return errs

    def drain_events(self):
        self._parse_available()
        ev, self.events = self.events, []
        return ev

    def wait_event(self, pred, timeout=None):
        """The first queued-or-arriving event with pred(pkt) true (it and
        everything before it is consumed), or None when none came in time."""
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        while True:
            self._parse_available()
            for i, ev in enumerate(self.events):
                if pred(ev):
                    self.events = self.events[i + 1:]
                    return ev
            if time.monotonic() >= deadline:
                return None
            try:
                self._fill(min(deadline, time.monotonic() + 0.05))
            except Hang:
                pass

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # ------------------------------------------------------ extensions

    def query_extension(self, name):
        n = name.encode()
        r = self.call(Op.QueryExtension, struct.pack(self.order + "Hxx", len(n)) + padded(n))
        return {"present": r[8], "major": r[9], "event": r[10], "error": r[11]}

    def enable_big_requests(self):
        ext = self.query_extension("BIG-REQUESTS")
        if not ext["present"]:
            return False
        r = self.call(ext["major"], b"", 0)
        self.max_big_words = struct.unpack(self.order + "I", r[8:12])[0]
        self.big_requests = True
        return True

    # --------------------------------------------------------- helpers

    def create_window(self, parent=None, x=0, y=0, w=100, h=100, border=0, cls=1,
                      depth=0, visual=0, attrs=None):
        wid = self.new_id()
        mask, vals = value_list(attrs or {})
        self.request(Op.CreateWindow, struct.pack(
            self.order + "IIhhHHHHII", wid, parent or self.root, x, y, w, h, border, cls,
            visual, mask) + vals, detail=depth)
        return wid

    def create_pixmap(self, w, h, depth=24, drawable=None):
        pid = self.new_id()
        self.request(Op.CreatePixmap, struct.pack(self.order + "IIHH", pid, drawable or self.root, w, h),
                     detail=depth)
        return pid

    def create_gc(self, drawable, attrs=None):
        gid = self.new_id()
        mask, vals = value_list(attrs or {})
        self.request(Op.CreateGC, struct.pack(self.order + "III", gid, drawable, mask) + vals)
        return gid

    def change_gc(self, gc, attrs):
        mask, vals = value_list(attrs)
        self.request(Op.ChangeGC, struct.pack(self.order + "II", gc, mask) + vals)

    def fill_rects(self, drawable, gc, rects):
        body = b"".join(struct.pack(self.order + "hhHH", *r) for r in rects)
        self.request(Op.PolyFillRectangle, struct.pack(self.order + "II", drawable, gc) + body)

    def map(self, wid):
        self.request(Op.MapWindow, struct.pack(self.order + "I", wid))

    def destroy(self, wid):
        self.request(Op.DestroyWindow, struct.pack(self.order + "I", wid))

    def intern(self, name, only_if_exists=False):
        n = name.encode()
        r = self.call(Op.InternAtom, struct.pack(self.order + "Hxx", len(n)) + padded(n),
                      detail=1 if only_if_exists else 0)
        return struct.unpack(self.order + "I", r[8:12])[0]

    def get_image(self, drawable, x, y, w, h, fmt=2, plane_mask=0xFFFFFFFF):
        r = self.call(Op.GetImage, struct.pack(self.order + "IhhHHI", drawable, x, y, w, h, plane_mask),
                      detail=fmt)
        return r[1], r[32:]   # depth, data

    def pixels24(self, drawable, x, y, w, h):
        """GetImage as rows of 0xRRGGBB ints (ZPixmap, 32 bpp)."""
        depth, data = self.get_image(drawable, x, y, w, h)
        bpp = self.formats.get(depth, (32, 32))[0]
        if bpp != 32:
            raise ValueError("expected 32 bpp, got %d at depth %d" % (bpp, depth))
        stride = w * 4
        rows = []
        for yy in range(h):
            row = []
            for xx in range(w):
                px = struct.unpack_from(self.order + "I", data, yy * stride + xx * 4)[0]
                row.append(px & 0xFFFFFF)
            rows.append(row)
        return rows

    def query_tree(self, wid):
        r = self.call(Op.QueryTree, struct.pack(self.order + "I", wid))
        n = struct.unpack(self.order + "H", r[16:18])[0]
        root, parent = struct.unpack(self.order + "II", r[8:16])
        children = list(struct.unpack(self.order + "%dI" % n, r[32:32 + 4 * n]))
        return root, parent, children

    def get_geometry(self, drawable):
        r = self.call(Op.GetGeometry, struct.pack(self.order + "I", drawable))
        root, x, y, w, h, bw = struct.unpack(self.order + "IhhHHH", r[8:22])
        return {"depth": r[1], "x": x, "y": y, "w": w, "h": h, "border": bw}
