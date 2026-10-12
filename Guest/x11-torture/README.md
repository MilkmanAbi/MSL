# xhell — the mslgd torture suite

A raw-protocol test suite that tries to break mslgd the way a buggy, hostile
or merely unusual X client would. It speaks X11 byte for byte (no Xlib, no
xcb — the guest has neither), so it can send exactly what a real library
refuses to produce: truncated requests, stale ids, oversized lengths,
out-of-order stacking, 100k-fill floods.

It is **not** a screenshot test. Every drawing test reads pixels back with
`GetImage` and compares them to a plain-Python model; every window test
checks `QueryTree`/`GetGeometry`/`TranslateCoordinates` against a model of
the tree. "The server survived" is the floor, not the bar.

## Running it

From the Mac, against a running instance (the display must be up — launch any
GUI app first, or the harness will say "no X server answering"):

```
msl Milk python3 /mnt/mac/.../Guest/x11-torture/xhell.py            # levels 1-2
msl Milk python3 .../xhell.py --level 3      # everything, incl. slow/huge
msl Milk python3 .../xhell.py -k draw        # only ids containing "draw"
msl Milk python3 .../xhell.py --list
```

Results are written to `results/latest.json` (previous run kept as
`results/previous.json`), and the run prints what **changed** since last time
— which is how you use it while editing mslgd: run, fix, run, watch FAILs
turn to PASS and nothing regress.

Exit code: 0 all-clean, 1 some FAIL/ERROR, 2 a CRASH/HANG/DOWN happened.

## Outcomes

| | |
|---|---|
| PASS  | did what the protocol says |
| FAIL  | wrong answer — wrong pixels, wrong error code, wrong reply |
| ERROR | an X error the test did not expect |
| CRASH | the server dropped the connection |
| HANG  | the server stopped answering within the timeout |
| DOWN  | the test finished, but a **fresh** connection afterwards could not complete a round trip — the app host behind the display died |
| SKIP  | a precondition was missing (an extension not advertised) |

`DOWN` is the one to watch: it means the failure took the whole per-app host
with it, not just one connection.

## Layout

- `xwire.py` — the raw protocol client: pipelining, 16-bit sequence
  wraparound, BIG-REQUESTS, `Died`/`Hang` on failure. Reusable on its own.
- `xhell.py` — the harness: discovery, per-test connection, the liveness
  check that produces `DOWN`, JSON results and the diff.
- `suites/s_*.py` — the tests. Add a file, decorate functions with
  `@test("suite", "name", level)`, done.
- `smoke.py` — a 10-line sanity check of the client.

## Suites (166 tests)

- **wire** — connection setup (LSB/MSB, trickled, bad version/order, auth),
  request framing (trailing junk, too-short, body-less bodied requests,
  unknown opcodes and minors), sequence wraparound, pipelining, coalesced
  writes, slow-loris, mid-request disconnect, BIG-REQUESTS and length lies.
- **errors** — every bad input gets the *right* X error and the server
  lives: stale ids of each kind, id reuse/cross-type/out-of-range, double
  destroy, depth mismatch, reparent cycles, InputOnly draws, bad
  format/mode/function, a 10k-error storm, and mslgd's own foreign-id policy.
- **windows** — deep nesting (1000), wide siblings (5000), restack +
  circulate order, a 3000-op reparent storm checked against a model, map/
  unmap storm, configure extremes, 5000-window subtree destroy, 100
  top-levels, resize thrash, property flood/append/15 MB.
- **draw** — pixels checked exactly: fills, off-screen clamping, overlap
  order, clip rects + origin, XOR involution, overlapping CopyArea (scroll),
  PutImage/GetImage round trip, sub-rect reads, 100k-fill flood, 2000×2000.
- **events** — what toolkits block on: Expose after map, ConfigureNotify to
  both masks, DestroyNotify order, PropertyNotify (incl. GTK's zero-length
  server-time trick), cross-client selection copy/paste, SelectionClear,
  owner-gone, SendEvent routing by mask.
- **ext** — the handshakes GTK/Qt/Xlib do: extension list consistency, XKB,
  XI1 + XI2 (version negotiation, devices, select round trip), RandR, SHAPE,
  RENDER formats/filters/cursors, and libXrender's depth probe end to end.
- **toolkit** — Tk/Xaw/Xlib core paths: fonts and XLFD lists, ImageText8 /
  PolyText8, CopyPlane, stipples and tiles, thin lines, FillPoly, arcs,
  named colours, the core keymap.
- **replay** — real sessions (GTK2/3/4, Qt5/6, Tk, Xt) replayed request for
  request from `captures/`; any error a real server wouldn't give fails.
- **fuzz** — seeded structured fuzzing with shrinking to a minimal repro.

## Tools

- `xreplay.py` / `replay_as.sh` — replay a capture (`MSL_X11_CAPTURE_DIR`)
  in a fresh app host and attribute every error to its request.
- `xcapstat.py` — request histogram of captures: what apps actually send.
- `trim_captures.py` — bundle raw captures into `captures/`.
- `gtkscroll.py` / `gtkscroll.sh core|xi2 [native]` — a GTK3 widget that
  prints every scroll event GTK hands it (smooth deltas, emulated flag,
  source device). The ground truth for input work.
- `ffmode.sh [core|xi2] [log]` — Firefox in a chosen input mode, with its
  widget log in the shared folder.

## What the first runs found and fixed (2026-09-23/24)

Bugs surfaced by the suite and fixed in mslgd, all now covered:

1. **Host crash on a body-less request.** `DestroyWindow` with no body ran as
   "destroy window 0", recursed through the synthetic root, and overflowed
   the thread stack — one malformed request killed the whole app host. Fixed
   with a request-validation gate (`X11RequestRules`) + an iterative destroy.
2. **Silent acceptance of bad input.** ~30 requests that should raise
   BadWindow/BadDrawable/BadValue/BadMatch/BadIDChoice returned nothing.
   The gate now enforces minimum length, ids, values and matches.
3. **Handoff race → DOWN.** A per-app host that exited between the router's
   connect and its accept swallowed the connection; the client saw a dead
   display. Fixed with an ack on the fd handoff and a decline-when-closing
   path (`X11FDChannel`, `X11AppHost`).
4. **PropModeAppend/Prepend treated as Replace** — 10k appends collapsed to
   one item; INCR-style builders were corrupted.
5. **CirculateWindow unimplemented**, border width dropped, unknown opcodes
   answered BadImplementation instead of BadRequest, extension frees of
   untracked font/cursor/colormap ids silently ignored.
