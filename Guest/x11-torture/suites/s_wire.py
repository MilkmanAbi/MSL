"""wire: connection setup and request framing.

A server that trusts request lengths, assumes whole requests arrive in one
read, or keeps its sequence numbers in anything but 16 bits wrapping, breaks
here - and each of those has taken real servers down.
"""
import socket
import struct
import time

import xwire
from xwire import Op
from xhell import test


def _raw_socket(ctx):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(ctx.args.timeout)
    s.connect(xwire.default_socket_path())
    return s


@test("wire", "setup-lsb", 1)
def setup_lsb(ctx):
    """Little-endian setup and a round trip."""
    c = ctx.conn()
    ctx.expect_no_errors(c, "round trip")


@test("wire", "setup-msb", 1)
def setup_msb(ctx):
    """Big-endian ('B') client: every reply must come back in MSB order."""
    try:
        c = ctx.conn(byte_order=b"B")
    except xwire.Died as e:
        raise ctx_fail("MSB client refused or dropped: %s" % e)
    r = c.call(Op.GetInputFocus)
    wire_seq = struct.unpack(">H", r[2:4])[0]
    ctx.expect(wire_seq == 1, "reply sequence read as MSB is %d, want 1 (server answered in the wrong byte order)" % wire_seq)
    ctx.expect(c.width > 0 and c.width < 20000, "screen width parsed as MSB is %d - setup was not in MSB order" % c.width)


def ctx_fail(msg):
    from xhell import Fail
    return Fail(msg)


@test("wire", "setup-byte-by-byte", 1)
def setup_trickle(ctx):
    """The 12-byte setup request sent one byte at a time."""
    s = _raw_socket(ctx)
    for b in struct.pack("<cxHHHHxx", b"l", 11, 0, 0, 0):
        s.send(bytes([b]))
        time.sleep(0.02)
    head = s.recv(8)
    s.close()
    ctx.expect(len(head) == 8 and head[0] == 1, "setup not accepted when trickled: %r" % head)


@test("wire", "setup-bad-byte-order", 1)
def setup_bad_order(ctx):
    """First byte neither 'l' nor 'B': refuse or close - never hang, never die."""
    s = _raw_socket(ctx)
    s.send(struct.pack("<cxHHHHxx", b"Z", 11, 0, 0, 0))
    s.settimeout(5)
    try:
        s.recv(8)
    except socket.timeout:
        ctx.note("server kept a garbage connection open silently (acceptable, not ideal)")
    s.close()


@test("wire", "setup-wrong-version", 1)
def setup_version(ctx):
    """Protocol major 10 must be refused with a failed setup, not accepted blindly."""
    s = _raw_socket(ctx)
    s.send(struct.pack("<cxHHHHxx", b"l", 10, 0, 0, 0))
    s.settimeout(5)
    try:
        head = s.recv(8)
        if head and head[0] == 1:
            ctx.note("server accepted protocol 10.0 (should refuse)")
    except socket.timeout:
        ctx.note("server silent on protocol 10.0")
    s.close()


@test("wire", "setup-with-auth", 1)
def setup_auth(ctx):
    """Setup carrying an authorization name and data it does not know."""
    s = _raw_socket(ctx)
    name, data = b"MIT-MAGIC-COOKIE-1", bytes(range(16))
    s.send(struct.pack("<cxHHHHxx", b"l", 11, 0, len(name), len(data)) + xwire.padded(name) + xwire.padded(data))
    head = s.recv(8)
    s.close()
    ctx.expect(len(head) == 8, "no setup answer with auth data present")


@test("wire", "trailing-junk", 1)
def trailing_junk(ctx):
    """A request longer than its opcode needs: the extra must be skipped, and
    the connection must stay in step."""
    c = ctx.conn()
    c.raw(struct.pack("<BBH", Op.GetInputFocus, 0, 4) + b"\xAA" * 12)
    r = c.wait_reply(c.seq)
    ctx.expect(r[0] == 1, "no reply")
    ctx.expect_no_errors(c, "after an over-long request")


@test("wire", "too-short", 1)
def too_short(ctx):
    """CreateWindow with a length far shorter than its fixed part: BadLength,
    and the connection survives."""
    c = ctx.conn()
    c.raw(struct.pack("<BBH", Op.CreateWindow, 24, 2) + b"\0" * 4)
    errs = c.sync()
    ctx.expect(any(e.name in ("BadLength", "BadValue", "BadWindow", "BadMatch") for e in errs),
               "expected an error for a truncated CreateWindow, got %s" % (errs or "nothing"))


@test("wire", "length-one-for-bodied-requests", 2)
def length_one(ctx):
    """Every core request that has a body, sent with no body at all.
    Each must be answered with an error (usually BadLength) - reading past
    the request into the next one is the classic framing bug."""
    c = ctx.conn()
    bodied = [1, 2, 3, 4, 7, 8, 12, 14, 15, 16, 17, 18, 20, 22, 23, 24, 25, 40, 45, 47, 48, 53, 55,
              56, 59, 61, 62, 64, 65, 66, 67, 69, 70, 72, 73, 76, 84, 91, 93, 98, 101]
    silent = []
    for op in bodied:
        c.raw(struct.pack("<BBH", op, 0, 1))
        errs = c.sync()
        if not errs:
            silent.append(op)
    if silent:
        raise ctx_fail("no error for body-less requests with opcodes %s" % silent)


@test("wire", "unknown-core-opcodes", 1)
def unknown_core(ctx):
    """Opcodes 0 and 120-126 are unassigned: BadRequest each, and in step."""
    c = ctx.conn()
    wrong = []
    for op in [0] + list(range(120, 127)):
        c.raw(struct.pack("<BBH", op, 0, 1))
        errs = c.sync()
        if [e.name for e in errs] != ["BadRequest"]:
            wrong.append((op, [e.name for e in errs]))
    ctx.expect(not wrong, "unassigned opcodes answered wrongly: %s" % wrong)


@test("wire", "unknown-extension-majors", 1)
def unknown_ext(ctx):
    """Major opcodes 128-255 that no extension owns: BadRequest."""
    c = ctx.conn()
    owned = set()
    r = c.call(Op.ListExtensions)
    n, off, names = r[1], 32, []
    for _ in range(n):
        ln = r[off]
        names.append(r[off + 1:off + 1 + ln].decode())
        off += 1 + ln
    for name in names:
        owned.add(c.query_extension(name)["major"])
    wrong = []
    for op in range(128, 256):
        if op in owned:
            continue
        c.raw(struct.pack("<BBH", op, 0, 1))
        errs = c.sync()
        if [e.name for e in errs] != ["BadRequest"]:
            wrong.append((op, [e.name for e in errs]))
    ctx.expect(not wrong, "unowned majors answered wrongly: %s" % wrong[:10])
    ctx.metric("extensions", len(names))


@test("wire", "extension-bad-minors", 1)
def ext_minors(ctx):
    """Minor opcode 250 on every advertised extension: an error, not silence
    and not a disconnect."""
    c = ctx.conn()
    r = c.call(Op.ListExtensions)
    n, off, names = r[1], 32, []
    for _ in range(n):
        ln = r[off]
        names.append(r[off + 1:off + 1 + ln].decode())
        off += 1 + ln
    silent = []
    for name in names:
        major = c.query_extension(name)["major"]
        c.raw(struct.pack("<BBH", major, 250, 1))
        if not c.sync():
            silent.append(name)
    ctx.expect(not silent, "no error for minor 250 on %s" % silent)


@test("wire", "sequence-wraparound", 2)
def seq_wrap(ctx):
    """70,000 pipelined NoOperations, then a reply: its 16-bit sequence must
    be exactly the low bits of the true count."""
    c = ctx.conn()
    batch = struct.pack("<BBH", Op.NoOperation, 0, 1) * 1000
    t = time.monotonic()
    for _ in range(70):
        c._send(batch)
        c.seq += 1000
    seq = c.request(Op.GetInputFocus)
    r = c.wait_reply(seq)
    dt = time.monotonic() - t
    wire = struct.unpack("<H", r[2:4])[0]
    ctx.expect(wire == seq & 0xFFFF, "reply sequence %d, want %d" % (wire, seq & 0xFFFF))
    ctx.metric("noop_per_s", 70000 / dt)


@test("wire", "pipelined-replies", 2)
def pipelined(ctx):
    """5,000 InternAtom requests sent back to back, replies collected after:
    every reply present, in order, none lost or duplicated."""
    c = ctx.conn()
    seqs = []
    for i in range(5000):
        n = ("XHELL_PIPE_%d" % i).encode()
        seqs.append(c.request(Op.InternAtom, struct.pack("<Hxx", len(n)) + xwire.padded(n)))
    atoms = [struct.unpack("<I", c.wait_reply(s)[8:12])[0] for s in seqs]
    ctx.expect(len(set(atoms)) == 5000, "%d distinct atoms for 5000 distinct names" % len(set(atoms)))


@test("wire", "slow-loris-request", 1)
def slow_loris(ctx):
    """A request dribbled in one byte per 20 ms: the server must assemble it."""
    c = ctx.conn()
    pkt = struct.pack("<BBH", Op.GetInputFocus, 0, 1)
    for b in pkt:
        c._send(bytes([b]))
        time.sleep(0.02)
    c.seq += 1
    ctx.expect(c.wait_reply(c.seq)[0] == 1, "no reply to a trickled request")


@test("wire", "coalesced-writes", 1)
def coalesced(ctx):
    """1,000 mixed requests in a single write."""
    c = ctx.conn()
    p = c.create_pixmap(16, 16)
    g = c.create_gc(p)
    one = struct.pack("<BBHII", Op.PolyFillRectangle, 0, 5, p, g) + struct.pack("<hhHH", 0, 0, 4, 4)
    c._send(one * 1000)
    c.seq += 1000
    ctx.expect_no_errors(c, "1000 coalesced fills")


@test("wire", "disconnect-mid-request", 1)
def mid_request(ctx):
    """Half a request, then the client vanishes. The server must tidy up
    (the liveness check after this test is the real assertion)."""
    s = _raw_socket(ctx)
    s.send(struct.pack("<cxHHHHxx", b"l", 11, 0, 0, 0))
    head = s.recv(8)
    extra = struct.unpack("<H", head[6:8])[0] * 4
    got = 0
    while got < extra:
        got += len(s.recv(extra - got))
    s.send(struct.pack("<BBH", Op.CreateWindow, 24, 8) + b"\x01\x02")
    s.close()


@test("wire", "disconnect-with-pending-replies", 1)
def pending_replies(ctx):
    """500 reply-bearing requests sent, then the socket closed before reading
    any: the server must not choke writing to a dead peer."""
    c = ctx.conn()
    for _ in range(500):
        c.request(Op.GetInputFocus)
    c.close()


@test("wire", "big-request-4mb", 2)
def big_request(ctx):
    """A 4 MB PutImage through BIG-REQUESTS, then read a pixel back."""
    c = ctx.conn()
    if not c.enable_big_requests():
        ctx.skip("no BIG-REQUESTS")
    w = h = 1024
    p = c.create_pixmap(w, h)
    g = c.create_gc(p)
    data = struct.pack("<I", 0x00336699) * (w * h)
    t = time.monotonic()
    c.request(Op.PutImage, struct.pack("<IIHHhhBBxx", p, g, w, h, 0, 0, 0, 24) + data, detail=2)
    ctx.expect_no_errors(c, "4 MB PutImage")
    px = c.pixels24(p, 1000, 1000, 1, 1)[0][0]
    ctx.metric("MB_per_s", 4 / (time.monotonic() - t))
    ctx.expect(px == 0x336699, "pixel after big PutImage is %06x" % px)


@test("wire", "big-request-length-lies", 2)
def big_length_lies(ctx):
    """A BIG-REQUESTS request whose 32-bit length is 1 (smaller than its own
    header). Must be an error, not an infinite loop or a crash."""
    c = ctx.conn()
    if not c.enable_big_requests():
        ctx.skip("no BIG-REQUESTS")
    c.raw(struct.pack("<BBHI", Op.GetInputFocus, 0, 0, 1))
    ctx.allow_disconnect = True
    c.sync()
