"""fuzz: seeded structured request fuzzing, with shrinking.

Every other suite asks a question it already knows the answer to. This one
doesn't: it sends thousands of core requests with honest framing but
random contents - real ids from a pool of live resources mixed with stale
and garbage ones, random value masks, random coordinates - and asks only
"is the server still alive and in step?". When it isn't, the failing run
is shrunk (prefix bisection, then chunk deletion) to the fewest requests
that still kill it, and that list is printed as hex so it can become a
regression test.

Fenced so a run can't touch the Mac: no top-level windows (every window is
created under an unmapped container), and nothing with effects outside
the server - pointer warps, bells, KillClient, keyboard/pointer/screensaver
configuration, access control.

    xhell.py -k fuzz --seed 7          # a different corpus
"""
import random
import struct

import xwire
import xreplay
from xwire import Op
from xhell import test, Fail

EXCLUDED = {41, 100, 102, 104, 105, 107, 109, 111, 112, 113, 115, 116, 118,   # effects outside the server
            36, 37}                                                          # GrabServer: fine, but it serialises the fuzz
OPCODES = [o for o in range(1, 128) if o not in EXCLUDED]


class Corpus:
    """Generates requests; `ids` is a pool of resources this client made."""

    def __init__(self, c, rng):
        self.c, self.rng = c, rng
        self.container = None
        self.ids = []

    def setup(self):
        c = self.c
        self.container = c.create_window(w=300, h=300)          # never mapped
        for _ in range(4):
            self.ids.append(c.create_window(parent=self.container, w=50, h=50))
        for _ in range(3):
            self.ids.append(c.create_pixmap(32, 32))
        self.ids.append(c.create_pixmap(16, 16, depth=1))
        self.ids.append(c.create_gc(self.ids[-1]))
        self.ids.append(c.create_gc(self.ids[0]))
        c.sync()

    def an_id(self):
        r = self.rng.random()
        if r < 0.75:
            return self.rng.choice(self.ids)
        if r < 0.85:
            return self.c.id_base | self.rng.randrange(0x1000, 0x1FFFFF)   # stale, own range
        if r < 0.9:
            return 0
        return self.rng.getrandbits(32) & ~0x1FFFFF | 0x1FFFFE             # someone else's, not root

    def word(self):
        r = self.rng.random()
        if r < 0.4:
            return self.an_id()
        if r < 0.7:
            return self.rng.choice([0, 1, 2, 3, 0xFFFF, 0x7FFF, 0x8000, 0xFFFFFFFF, 0x80000000])
        return self.rng.getrandbits(32)

    def request(self):
        """One request as raw bytes, honest length, header + body."""
        rng = self.rng
        op = rng.choice(OPCODES)
        words = rng.choice([0, 1, 2, 3, 4, 5, 6, 8, 12, 20])
        body = [self.word() for _ in range(words)]
        if op == Op.CreateWindow and words >= 2:
            body[0] = self.c.id_base | rng.randrange(0x100000, 0x1FFFFF)     # fresh id
            body[1] = self.container                                         # parent: never the root
        if op in (Op.ReparentWindow,) and words >= 2:
            body[1] = rng.choice([self.container] + self.ids[:4])
        if op in (Op.MapWindow, Op.MapSubwindows, Op.ConfigureWindow, Op.CirculateWindow) and words >= 1:
            if body[0] == self.container or body[0] == self.c.root:
                body[0] = self.ids[0]
        if op == Op.SendEvent and words >= 1 and body[0] == self.c.root:
            body[0] = self.ids[0]
        detail = rng.getrandbits(8) if rng.random() < 0.5 else rng.choice([0, 1, 2])
        data = b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in body)
        return struct.pack("<BBH", op, detail, 1 + words) + data


GEN = {}   # the generating connection's id base and mask, for remapping


def run(reqs, timeout=8):
    """Sends `reqs` on a fresh connection; returns None or a failure string.
    Ids are moved from the generating client's range onto this one's, the
    way xreplay does, so the pool built here matches the one generated."""
    try:
        c = xwire.Conn(timeout=timeout)
    except Exception as e:  # noqa: BLE001 - the host is gone
        return "connect: %s" % e
    try:
        Corpus(c, random.Random(0)).setup()   # same creation order -> same ids
        for i, raw in enumerate(reqs):
            c.raw(xreplay.remap(raw, GEN["base"], c.id_base, GEN["mask"], False))
            if i % 200 == 199:
                c.sync()
        c.sync()
        return None
    except (xwire.Died, xwire.Hang) as e:
        return "%s: %s" % (type(e).__name__, e)
    finally:
        c.close()


def alive():
    try:
        c = xwire.Conn(timeout=5)
        c.sync()
        c.close()
        return True
    except Exception:  # noqa: BLE001
        return False


def shrink(reqs):
    """Smallest sublist that still fails: prefix bisection, then ddmin-ish."""
    lo, hi = 1, len(reqs)
    while lo < hi:
        mid = (lo + hi) // 2
        if run(reqs[:mid]):
            hi = mid
        else:
            lo = mid + 1
    reqs = reqs[:lo]
    chunk = max(1, len(reqs) // 2)
    while chunk >= 1 and len(reqs) > 1:
        i, removed = 0, False
        while i < len(reqs):
            trial = reqs[:i] + reqs[i + chunk:]
            if trial and run(trial):
                reqs, removed = trial, True
            else:
                i += chunk
        if not removed:
            chunk //= 2
    return reqs


def _fuzz(ctx, n, seed_offset):
    seed = ctx.args.seed * 1000 + seed_offset
    rng = random.Random(seed)
    c = ctx.conn(timeout=10)
    corpus = Corpus(c, rng)
    corpus.setup()
    # Regenerate against the pool the replayer will build (same order, same
    # client-relative ids), so a failure reproduces in `run`.
    reqs = [corpus.request() for _ in range(n)]
    GEN.update(base=c.id_base, mask=c.id_mask)
    c.close()
    ctx.metric("requests", n)
    ctx.metric("seed", seed)
    err = run(reqs)
    if err is None and alive():
        return
    minimal = shrink(reqs) if err else reqs
    for raw in minimal[:12]:
        ctx.note("  %s" % raw[:48].hex())
    raise Fail("%s (seed %d; shrunk to %d request(s), listed above)" % (err or "host died afterwards", seed, len(minimal)))


@test("fuzz", "core-2k", 2, doc="2000 random core requests")
def fuzz_small(ctx):
    _fuzz(ctx, 2000, 1)


@test("fuzz", "core-20k-a", 3)
def fuzz_a(ctx):
    _fuzz(ctx, 20000, 2)


@test("fuzz", "core-20k-b", 3)
def fuzz_b(ctx):
    _fuzz(ctx, 20000, 3)


@test("fuzz", "core-20k-c", 3)
def fuzz_c(ctx):
    _fuzz(ctx, 20000, 4)
