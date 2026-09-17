# Planning: cage (Wayland) integration

## STATUS 2026-09-03: Phases 0-2 done. Real, deterministic, working
## Layer-0 tests exist (`Guest/init/wayland-tests/`, `Scripts/cage-
## test.sh`). Everything below "Realistic phases" is now a progress
## log, not speculation - read it before continuing into Phase 3/4.

**The single biggest planning assumption this session overturned**:
"wlroots' dependency chain may assume glibc in places Alpine's musl
doesn't provide - genuinely unverified territory" turned out to be a
non-issue. Alpine's OWN repos ship prebuilt `cage` (0.3.0) and
`wlroots0.20` packages, already built against musl - `apk add cage
wlroots0.20 wlroots0.20-dev` just works, no source build, no meson
patching, nothing like `mslgd-br2`'s XQuartz build effort. Also
available prebuilt and load-bearing for this whole plan: `grim`
(screenshot via `wlr-screencopy`) and `wtype` (synthetic keyboard input
via `zwp_virtual_keyboard_manager_v1`) - both sidestep the plan's
original assumption that reading cage's headless framebuffer would
need custom code (`MSL_X11_SNAPSHOT_DIR`-style). It doesn't: `grim`
already does exactly that job, for real, against any wlroots
compositor, out of the box.

**Phase 0 (build feasibility) - DONE.** `apk add cage wlroots0.20
wlroots0.20-dev wayland-dev wayland-protocols libxkbcommon-dev grim
wtype gcc musl-dev` (plus `weston-clients` for `weston-simple-shm`,
useful for one-off manual debugging but not part of the real test
suite). `cage` runs headless via `WLR_BACKENDS=headless WLR_RENDERER=
pixman` - the pixman SOFTWARE renderer, no GPU/DRM/EGL needed at all,
confirmed genuinely working (not just "starts without crashing" -
real frames render and composite correctly, see Phase 1).

**Phase 1 (static frame round-trip) - DONE, and it's a real regression
test, not just an eyeballed-once check.** `Guest/init/wayland-tests/
01_static_frame.c`: a minimal, from-scratch client (raw `wl_compositor`
+ `wl_shm` + `xdg_wm_base`, no toolkit - the Wayland-side equivalent of
`x11-tests/01_window_lifecycle.c`), drawing four solid 100x75 color
quadrants into a 200x150 buffer and then idling. Needed writing custom,
because the obvious first choice (`weston-simple-shm`, Alpine's own
prebuilt demo client) turned out to be continuously time-animated, not
frame-count-deterministic - two captures at the identical wall-clock
delay differed almost everywhere. A custom static client sidesteps that
entirely. `Scripts/cage-test.sh` compiles it (generating
`xdg-shell-client-protocol.h`/`.c` via `wayland-scanner` from the real
`/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml` - every
Wayland client needs this, there's no core-protocol equivalent on the
X11 side), launches cage headless with it, captures via `grim`, pulls
the PNG across the SAME guest<->host virtiofs share `x11-test.sh`
already uses, and pixel-diffs against a checked-in reference (reusing
`x11-tests/pngdiff.py` verbatim). Confirmed deterministic: 3 consecutive
runs, byte-identical.

**Phase 2 (input round-trip) - DONE, confirmed via a real changed
frame.** `02_input_roundtrip.c`: renders solid BLACK, binds `wl_seat`,
listens for a `wl_keyboard` `key` event, switches to solid WHITE on the
first one. The harness captures a frame before injecting a synthetic
keypress (`wtype a`, using the real `zwp_virtual_keyboard_manager_v1`
protocol - cage/wlroots' actual equivalent of X11 XTEST) and again
after, and the test PASSES only if the AFTER frame differs from BEFORE
(not just "no crash") - the same "confirm via changed content, not just
absence of an error" standard this whole project's X11 crossing-event
work already held itself to.

Two real, non-obvious bugs found and fixed getting Phase 2 working,
both worth remembering for any future Wayland input work:

1. **A synthetic press doesn't necessarily arrive as its own
   `wl_keyboard.key` event at all.** Confirmed via `wev` (a real
   Wayland event dumper, `apk add wev`) run directly against cage+
   `wtype`: by the time a surface actually gains keyboard focus, the
   seat may already consider a just-pressed key held, and reports it
   through `wl_keyboard.enter`'s "already pressed keys" array instead -
   a real, distinct part of the core protocol, not a `key` event at
   all. Only the matching RELEASE showed up as a normal `wl_keyboard.
   key` event in every observed run. Fixed by reacting to ANY `key`
   event (press or release), not press-only - correct given the test's
   actual goal (prove input round-trips at all), not a workaround.
2. **The test client must outlive the harness's own AFTER capture by a
   real margin.** cage is a KIOSK compositor - it exits the instant its
   one wrapped app exits. An early version of the client exited ~300ms
   after redrawing (right after its own key-detected loop condition
   flipped), which raced ahead of the harness's `grim` (run ~1s after
   the synthetic keypress) and made it fail with "failed to create
   display" - not a capture bug, cage (and the client) were just
   already gone. Fixed with a flat `sleep(3)` after redrawing, well
   past the harness's own capture timing.

**A separate, real infrastructure gotcha hit (and fixed) along the
way, unrelated to Wayland/cage specifically but real for ANY future
backgrounded-guest-process work**: `mslhd`'s `DaemonServer` has a
deliberate "WSL-like" idle-suspend feature (`sessionEnded`'s
`suspendDebounce`, 3 seconds - see `Sources/mslhd/DaemonServer.swift`)
that pauses the WHOLE guest VM 3 seconds after the last open `msl --`
session closes. A harness issuing several SEPARATE `msl --` calls with
more than ~3s between any two (this one originally did: compile, then
launch, then a host-side `sleep 1.5`, then a separate capture call)
reliably gets the guest paused mid-test - which looks EXACTLY like "the
backgrounded process silently died," and cost a long, wrong detour
suspecting `SIGHUP`/session/pty semantics before the real cause (this
timer, confirmed by finding zero `msgSystemWillSleep` log lines and
then finding the actual debounce code) was found. Two-part fix, both
needed: (a) hold one long-lived `msl -- "sleep N"` session open in the
HOST-side background for a whole test-suite run (`cage-test.sh`'s own
`start_keepalive`/`cleanup`/`trap EXIT`) so the idle timer never fires
mid-suite, and (b) structure any SINGLE test's own launch+capture+
cleanup sequence as ONE continuous guest-side script in ONE `msl --`
session rather than splitting it across several separate calls with
gaps - confirmed live (an internal watcher polling every 0.25s) that a
backgrounded `setsid`+`disown`'d process reliably survives 10+ seconds
when checked from WITHIN its own continuous session, but was reliably
gone by the time a genuinely SEPARATE, later `msl --` session checked
on it, even with the idle-suspend timer independently ruled out as the
cause. The exact mechanism behind that second part was never fully
root-caused (not plain `SIGHUP` - `setsid` should be immune to that);
what's confirmed and actionable is which shape reliably works.

## Next: Phase 3 (continuous/live) and Phase 4 (visual integration)
are still not started - see "Realistic phases" below for what they
originally meant. Both now have solid, proven building blocks to build
on (real cage+wtype+grim round-trips, a working harness, two known
gotchas already documented) rather than the unverified-everything state
this file described before today.

## Phase 3 progress (2026-09-03, same day): steps 1-2 of 3 done - a
real, working guest->host live frame pipe exists, proven with actual
pixel content, not just "no crash."

**Step 1 (persistent capture loop, no transport) - DONE.**
`03_screencopy_loop.c`: binds `zwlr_screencopy_manager_v1` directly
(not `grim`, which only does ONE-SHOT capture - a persistent client
re-arming `capture_output` on every `ready` event is a genuinely
different code path that can deadlock if a new capture is issued before
the prior one's buffer is fully done with). Captured 30/30 frames
against `01_static_frame`'s output in 0.625s (~48fps), correct pixel
content on every single frame, no stall - confirms the re-arm shape is
sound before anything else got built on top of it. One `wl_buffer` is
allocated once (sized from the first frame's `buffer` event) and reused
every capture - safe ONLY because captures are strictly serialized
(`capture_output` is issued exclusively from inside the previous
capture's own `ready` callback, never pipelined) - noted explicitly in
the code since that invariant would need revisiting before ever trying
to pipeline captures for higher throughput.

**Step 2 (framing + vsock transport, real host receiver) - DONE.**
Extended into `cagebridge.c` (guest) / `CageBridge.swift` (host,
`Sources/MSLCore/CageBridge.swift`) - a real, working live pipe, not a
mockup:
- Wire format: a 20-byte header (`magic`, `width`, `height`, `stride`,
  `format`, all native-endian `uint32`) immediately followed by
  `stride * height` raw pixel bytes, repeated once per frame. No
  compression, no delta encoding - deliberately dumb per the plan.
- New vsock port `5004` (`VMConfiguration.cageVsockPort`) - `5000`-
  `5003` were already owned by `shellVsockPort`/`fileOpsVsockPort`/
  `displayVsockPort`/`mslgdVsockPort`.
- **A real macOS platform constraint discovered here, worth remembering
  for any future host-side vsock work**: the host end of a vsock is
  ONLY reachable through `VZVirtioSocketDevice` on the live, running
  `VZVirtualMachine` - there is no way for a separate, independent
  process to open a raw `AF_VSOCK` listener on macOS the way
  `Guest/init/x11tunnel.c` does on the guest (Linux) side. So the "host
  receiver" cannot be a genuinely separate throwaway script; it has to
  live in `mslhd` (the one process holding the VM), structurally
  cloned from `DisplayBridge.swift` (`init(socketDevice:port:)`,
  `start()`/`stop()`, delegate spawns a plain `Thread` and returns
  immediately - `DisplayBridge`'s own doc comment already documents
  WHY: blocking inside a `VZVirtioSocketListenerDelegate` callback
  hangs the entire process, not just one connection). `CageBridge`'s
  sink is kept deliberately dumb/throwaway in spirit even though it
  can't be a separate process: no decode, no `NSWindow`, no `CGImage` -
  just raw dumps to `/tmp/cageframe_<n>.raw` (+ a `.meta` sidecar) so a
  wrong frame is a byte diff, not a rendering bug to debug at the same
  time.
- `VMManager.startCageBridge()`/`stopCageBridge()` (cloned from
  `startX11Server()`/`stopX11Server()`), a `startCageBridge` case
  through `DaemonProtocol`/`DaemonServer`, and a debug-only `msl
  cage-bridge-test <instance> [num-frames]` subcommand (defaults to 10
  frames) wire it all together end to end.
- **Confirmed working live**, not just compiling: `msl cage-bridge-test
  default 10` streamed 10/10 frames in ~0.18s (~56fps), and the raw
  dumps on the HOST side (`/tmp/cageframe_0.raw`, 1280x720x4 =
  3,686,400 bytes, matching `stride*height` exactly) contain the
  CORRECT pixel content - `(255, 51, 51)` at the top-left, exactly
  `01_static_frame`'s red quadrant, black everywhere else, matching
  Phase 1's own reference PNG. This is real signal, not a
  header-parses-OK check.
- **One real bug found and fixed getting this far, worth remembering**:
  a magic-number constant transcribed with two hex digits swapped
  between the C side (`cagebridge.c`'s `CAGF_MAGIC 0x43414746u`) and
  the Swift side (`CageBridge.swift`'s `magic`, originally written as
  `0x4641_4743` - NOT the same 32-bit value) caused every single frame
  header to fail validation and the host to drop the connection
  immediately - which then showed up on the GUEST side as an opaque
  `SIGPIPE`-killed process (exit 141) with a completely empty log, not
  an informative error, because `write()` raising `SIGPIPE` terminates
  the process at the syscall itself before any subsequent `fprintf` can
  run. Root-caused by checking `mslhd`'s own trace log
  (`/tmp/mslhd_trace.log`), which had the real, specific error
  (`CageBridge: bad frame header, dropping connection`) the whole time
  - the lesson being that an opaque guest-side signal death is worth
  checking the HOST-side daemon log for before chasing guest-side
  timing theories.
- **Also confirmed along the way**: a freshly `swift build`-ed `mslhd`
  binary needs re-signing before it can touch `Virtualization.framework`
  at all (`VZErrorDomain Code=2`, "doesn't have the
  com.apple.security.virtualization entitlement") - see README's own
  `codesign --force --sign - --entitlements
  Resources/MSLApp/MSLApp.entitlements .build/debug/mslhd` command,
  needed after EVERY rebuild of `mslhd` specifically (not `msl`, the
  CLI client - it never touches VZ directly).

**Step 3 (continuous streaming + real host->guest input round trip) -
DONE, same day.** A real, LIVE, continuously-streaming cage session
with real synthetic keyboard/pointer injection now exists and is
verified via an actual captured pixel change, not a mockup.

- **Continuous (not frame-count-bounded) streaming**: `CageBridge`
  (`Sources/MSLCore/CageBridge.swift`) now supports `maxFrames == 0`
  (threaded through `DaemonProtocol`'s `START_CAGE_BRIDGE <instance>
  <maxFrames>` line, `VMManager.startCageBridge(maxFrames:)`, all the
  way from a new `msl cage-input-test <instance>` subcommand) as a
  genuinely different sink shape from the bounded debug-dump mode: it
  overwrites one `/tmp/cageframe_latest.raw` (+ `.meta`) atomically
  (write-to-temp then `rename`) every frame, forever, instead of one
  file per frame index. This matters for a real reason, not just tidiness
  - the bounded sink hitting its cap and `return`-ing closes the
  connection, which SIGPIPE-kills the guest's `cagebridge` on its very
  next write (the exact class of failure step 2 already hit once).
- **Real host->guest input injection - a SEPARATE guest binary/port,
  not a bidirectional extension of `cagebridge`.** `cageinput.c`
  (guest, new vsock port `5005`/`cageInputVsockPort`) binds `wl_seat` +
  `zwp_virtual_keyboard_manager_v1` + `zwlr_virtual_pointer_manager_v1`
  (BOTH confirmed present via `wayland-info` against a live cage
  session before writing any code - wlroots implements both, but
  whether a compositor instantiates either manager is a per-compositor
  choice, so this was checked, not assumed) and blocks reading fixed-
  size commands (`{type, a, b, c, d: uint32}`) from the host, injecting
  each as a real `zwp_virtual_keyboard_v1.key` or
  `zwlr_virtual_pointer_v1.motion_absolute`/`button` request. Kept
  DELIBERATELY separate from `cagebridge`'s frame-stream connection
  (not multiplexed onto the same fd/thread) for a real, measured
  reason: a 1280x720x4 frame is 3.6MB against vsock socket buffers of
  tens of KB, so under sustained streaming `cagebridge`'s own
  `write_all` blocks *inside* its Wayland callback - a single-threaded
  client stuck mid-frame-write cannot also service an input fd no
  matter how it's polled. `CageInputBridge`
  (`Sources/MSLCore/CageInputBridge.swift`, host) is the mirror image:
  retains whichever connection `cageinput` dials in with and exposes
  `sendKey`/`sendPointerMotion`/`sendPointerButton`, callable from any
  thread, writing straight to that connection's fd on demand.
- The virtual keyboard protocol requires a keymap to be set before any
  `key` request (a `no_keymap` protocol error + disconnect otherwise,
  stated in the protocol XML itself) - `cageinput.c` compiles a REAL
  "us" xkb layout with libxkbcommon at startup and hands it over via a
  memfd, the same pattern this project's Wayland clients already use
  for `wl_shm` buffers.
- **Verified live, via a real captured pixel change**: `msl
  cage-input-test <instance>` wraps cage around `02_input_roundtrip.c`
  (reused verbatim - already renders solid BLACK, switches to solid
  WHITE on any real `wl_keyboard` key event), streams continuously,
  injects one synthetic keypress through `CageInputBridge` mid-stream
  (retrying until a connection lands, no fixed sleep guess), and
  confirms the round trip by sampling `/tmp/cageframe_latest.raw`
  before and after: `PASS - real host->guest key injection confirmed
  (black -> white)`. This is the same "confirm via changed content, not
  just absence of an error" standard Phase 2 and this whole project
  already hold themselves to - applied here across a REAL live
  bidirectional pipe, not a single one-shot round trip.
- `wayland-info` also surfaced `zwlr_output_manager_v1` and
  `zxdg_output_manager_v1` as present, confirming the headless output's
  geometry (1280x720, matching everything captured so far) is queryable
  the normal way if Phase 4 ever needs it.

## Phase 4 (visual integration) - DONE, same day as Phases 0-3. A REAL
`NSWindow` on the actual macOS desktop now shows a live cage session and
accepts real mouse/keyboard input, confirmed with screenshots and an
actual synthetic OS-level keystroke - not the debug CLI's direct
`CageInputBridge` shortcut Phase 3 step 3 used.

**The "one NSWindow per Wayland surface vs. one kiosk window" question
this plan always flagged as open is CLOSED - by the capture mechanism
already chosen in Phase 3, not by a design preference.**
`zwlr_screencopy_manager_v1.capture_output` is OUTPUT-scoped, not
per-surface - there is no way to capture one Wayland client surface's
texture in isolation via screencopy; wlroots offers no such thing. The
pipeline built in Phase 3 therefore commits to mirroring cage's entire
composited 1280x720 canvas in ONE window, matching cage's own kiosk
model (wraps exactly one app fullscreen) - per-surface windows would
need a fundamentally different capture mechanism (a nested compositor
presenting each client surface separately), not an option layered on
top of today's pipeline. Written down here so a future session doesn't
re-open this as if it were still undecided.

**What was built:**
- `CageBridge` gained an in-process `onFrame` callback (`FrameHandler`),
  alongside its existing debug file sink - `/tmp/cageframe_latest.raw`
  was right for PROVING the pipe existed (Phase 3), but a live `NSView`
  needs frames PUSHED, not polled from disk. The wire header grew from
  20 to 24 bytes to carry the screencopy `flags` bitfield through
  end-to-end (checked LIVE before writing any drawing code - logged
  `y_invert=0` for every run this project has ever done against cage's
  headless pixman renderer, so no flip-correction is applied for it yet;
  the field is carried opaquely regardless, ready if that ever changes).
- `CageCanvasView` (`Sources/MSLCore/CageCanvasView.swift`) - an
  `NSView` that turns each received frame into a `CGImage` (cheap - no
  actual rendering happens until `draw(_:)` blits it) and shows it,
  coalescing frames under a lock so a redraw is only ever scheduled once
  at a time (at ~50-60fps/3.6MB-per-frame, one `DispatchQueue.main.async`
  PER FRAME would queue up faster than the main thread could drain it -
  dropping frames is correct for a live view). Same flipped-view +
  counter-flip-on-draw shape as `X11CanvasView` (reused, not re-derived -
  see its own long-standing comment on why that dance is needed).
  Forwards real mouse/keyboard directly into a `CageInputBridge`
  reference it holds - no IPC needed, since the view and the bridge live
  in the SAME `mslhd` process (unlike the debug CLI, which is a separate
  process and has to go through a control-request round trip).
- `CageKeyMapping` (`Sources/MSLCore/CageKeyMapping.swift`) - maps
  `NSEvent.keyCode` (Mac virtual keycodes) to REAL Linux evdev codes for
  `zwp_virtual_keyboard_v1.key`. Deliberately NOT a reuse of
  `X11Keyboard`'s `macKeyCode + 8` scheme - that file's own doc comment
  says explicitly it's `mslgd`'s own private, self-consistent numbering
  ("nothing requires them to match real Linux/evdev numbering"), valid
  only because `mslgd` also answers `GetKeyboardMapping` with that same
  made-up scheme. A real compositor's virtual-keyboard protocol wants
  REAL evdev codes (`KEY_A`=30, not `kVK_ANSI_A`=0) - two unrelated
  vendor numbering systems, so this needed its own small explicit table
  (common ANSI-US keys only - letters, digits, space/return/tab/
  backspace/escape/arrows - not a full hardware-independent remap).
- `VMManager.startCageView()`/`stopCageView()` - creates the window/view
  plus dedicated `CageBridge`/`CageInputBridge` instances, wired
  together, with the AppKit object creation done SYNCHRONOUSLY via
  `DispatchQueue.main.sync` from `vmQueue` (safe - `vmQueue` is a
  private queue, never the main queue, so no deadlock) specifically so
  `CageBridge`'s `onFrame` closure can capture the real view directly
  rather than risk a race on a property that might not be set yet when
  the first frame lands.
- New debug-only `msl cage-view <instance> [app]` subcommand - defaults
  to wrapping `weston-simple-shm` (continuously animated - the right
  smoke test for "is this actually LIVE," not a static frame that
  happened to land once), runs for up to 5 minutes.

**Two real bugs found+fixed getting this to actually work, both worth
remembering:**
1. **`CageCanvasView`'s `mouseDown` needed the exact same
   `ensureActivated()` fix `X11CanvasView` already has, and was
   confirmed missing it the hard way.** First attempt: `msl cage-view`
   opened correctly and a real synthetic click (via macOS's own
   Accessibility API, `System Events click at {x,y}`) visibly landed on
   the window and even moved first-responder - but a FOLLOWING
   synthetic keystroke (`System Events keystroke "a"`) never reached the
   guest at all (`02_input_roundtrip` timed out after 8s with no key
   detected, confirmed via its own exit code and cage's log). Root
   cause: `mslhd` runs `.accessory` activation policy, which - exactly
   as `X11CanvasView.ensureActivated()`'s own doc comment already
   explains - does NOT reliably reclaim frontmost-APPLICATION status
   purely from a window being clicked, so `keystroke` (which targets
   whatever process is ACTUALLY frontmost) went nowhere useful. Fixed by
   adding the identical `ensureActivated()` call (guarded the same way,
   to avoid `X11CanvasView`'s own documented "unconditional activate
   disrupts AppKit's own click tracking" problem) to `mouseDown`/
   `rightMouseDown`/`otherMouseDown`. Confirmed fixed with a real
   before/after screenshot pair showing solid black -> a real white
   200x150 rectangle, driven by an ACTUAL synthetic OS keystroke through
   the genuine AppKit responder chain, not the debug CLI's direct
   `CageInputBridge.sendKey` call.
2. **`startCageBridge()`/`startCageInputBridge()`'s own "no-op if
   already started" guard silently reused a STALE, wrong-mode bridge
   across separate debug-command invocations in the same `mslhd`
   session.** Concretely: `msl cage-bridge-test default 10` (bounded,
   `maxFrames=10`) followed by `msl cage-input-test` (wants
   `maxFrames=0`, unbounded) in the same session - the second call's
   `startCageBridge(maxFrames: 0)` saw `cageBridge != nil` from the
   first call and no-op'd, so the FIRST (bounded) bridge kept running;
   the guest's own unbounded `cagebridge` connected to it, got cut off
   after 10 frames, and SIGPIPE-killed itself on its next write - the
   exact class of opaque failure this whole Phase 3/4 arc kept hitting,
   this time from stale state rather than a wire-format bug. Fixed by
   making `startCageBridge()`/`startCageInputBridge()` ALWAYS stop any
   existing bridge and start fresh (matching `startCageView()`'s own
   analogous fix, made for the same reason a moment earlier in this same
   session - these are one-shot debug commands, not a long-lived server
   like `X11Server` that genuinely should just no-op on a repeat call).
   Confirmed fixed: `cage-bridge-test` then `cage-input-test` back to
   back in one session now both pass.

**Verified live, with actual screenshots** (not just log output):
`msl cage-view default` opened a real, correctly-oriented, correctly-
sized window showing `weston-simple-shm`'s animated ripple pattern - two
screenshots ~3s apart show the center color genuinely changing, proving
live streaming rather than one frame rendered once. A second run
wrapping `02_input_roundtrip` and driven with a real synthetic macOS
keystroke (not the debug CLI) showed the window flip from solid black to
a real white rectangle - the complete real path end to end: OS keystroke
-> `CageCanvasView.keyDown` -> `CageKeyMapping` -> `CageInputBridge` ->
`cageinput.c` -> real `zwp_virtual_keyboard_v1.key` -> `02_input_
roundtrip`'s own handler -> redraw -> `zwlr_screencopy` -> `cagebridge`
-> `CageBridge.onFrame` -> `CageCanvasView.updateFrame` -> `CGImage` ->
on screen.

**Real-app proof, not just synthetic test fixtures (2026-09-03, same
day)**: `msl cage-view default /usr/bin/foot` - `foot` (a real,
independently-developed Wayland-native terminal emulator, `apk add
foot`) run under cage, shown live in a real `NSWindow`, with a REAL
command (`echo hello from cage`) typed via actual synthetic keystrokes
and executed by a real shell - the terminal showed the real command
line AND its real output (`hello from cage`) in the next screenshot.
This is qualitatively different from every earlier verification in this
plan (which all used purpose-built test fixtures like `01_static_frame`/
`02_input_roundtrip`) - it's proof an actual, unmodified, real-world
Wayland application runs correctly end to end: real font rendering
(`foot` depends on `libfontconfig`/`libfcft`, both exercised), a real
shell process, real keyboard round-trip through the full
`CageCanvasView`/`CageKeyMapping`/`CageInputBridge`/`cageinput.c` chain,
multi-character text entry (not just a single test keystroke) working
correctly.

## OpenGL investigation (2026-09-03, same day) - real progress, one
remaining blocker, NOT resolved yet. Started because the pixman software
compositor works but gives apps no real GL context at all - some real
apps (games, GL-accelerated toolkit paths) need actual OpenGL ES to
render anything.

**Root cause chain, each link confirmed live, not assumed:**
1. No `/dev/dri` exists at all in the guest (no GPU passthrough) -
   confirmed via `ls /dev/dri`.
2. `cage`'s `WLR_RENDERER=gles2` hard-requires a DRM fd
   (`drmGetDevices2`) with wlroots 0.20.2's headless backend - no
   automatic EGL-surfaceless/swrast fallback. Confirmed by actually
   running it: `Cannot create GLES2 renderer: no DRM FD available`.
3. The standard fix - `vgem`, a virtual DRM render-node driver that lets
   Mesa's software rasterizer (llvmpipe) bind via GBM without a real
   GPU - was missing from this project's shared kernel (Alpine's
   `linux-virt` flavor doesn't build it). Confirmed via `find /lib/
   modules -iname '*vgem*'` coming up empty, `modprobe vgem` failing.
4. **Fixed**: swapped the project's shared kernel/initramfs from
   `linux-virt` to `linux-lts` (which DOES build `vgem` - confirmed by
   fetching Alpine's `linux-lts` .apk directly and inspecting its module
   list before committing to the swap). Done entirely from the ALREADY-
   RUNNING guest (no Docker/OrbStack `provision-disk-image` round trip
   needed): `apk add linux-lts` inside the guest (auto-generates
   `initramfs-lts` via `mkinitfs`'s postinstall hook, and installs
   `/lib/modules/6.18.48-0-lts` onto the SAME persistent disk the
   instance already boots from), copied `vmlinuz-lts`/`initramfs-lts`
   out via the existing `/mnt/mac` virtiofs share, zboot-unwrapped
   `vmlinuz-lts` on the host (same technique as
   `GuestImageTools.extractZbootImage` - find the embedded gzip magic,
   decompress), and overwrote `~/Library/Application Support/MSL/
   disk-Image`/`disk-initramfs-virt` (after backing up the `linux-virt`
   originals as `*.linux-virt.bak`, so this is reversible). Required a
   full `msl --shutdown` + cold boot (a paused/resumed VM keeps the OLD
   kernel in memory) - confirmed working: `uname -r` now reports
   `6.18.48-0-lts`, and BOTH regression suites (x11-test.sh 9/9,
   cage-test.sh 2/2) stayed green after the swap - no boot/vsock/ext4/
   rendering regression from the kernel change itself.
5. `modprobe vgem` now succeeds and creates a real `/dev/dri/card0` +
   `/dev/dri/renderD128`.
6. With `vgem` present, `cage`'s GLES2 renderer ACTUALLY INITIALIZES -
   confirmed via its own log: `GL renderer: llvmpipe (LLVM 22.1.3, 128
   bits)`, a real, full GLES2 extension list. wlroots opens the DRM
   render node, DRI2 fails (expected - vgem has no real DRI2/GBM-modeset
   support), falls back to Mesa's `kms_swrast` path, and that succeeds.
   This is real - genuine software OpenGL ES 2.0 via Mesa, not a stub.

**The remaining blocker, found and root-caused but NOT fixed**: even
with the GLES2 renderer itself working, `cage`'s HEADLESS OUTPUT's own
framebuffer/swapchain allocation fails: `KMS: DRM_IOCTL_MODE_CREATE_DUMB
failed: Permission denied` / `gbm_bo_create failed: Permission denied` -
the output never comes up (`grim` reports `no wl_output`), so nothing
can actually be captured even though rendering itself works.
Root-caused with a small standalone C test program
(`open("/dev/dri/card0")` + `DRM_IOCTL_MODE_CREATE_DUMB` directly, no
wlroots involved): the ioctl fails UNLESS the calling process has first
called `drmSetMaster()` on its own fd - confirmed live, the identical
ioctl succeeds once `drmSetMaster()` precedes it (`drmIsMaster` reads
`1` afterward). `cage`'s headless backend never calls `drmSetMaster()`
at all - reasonably, since it has no real output/mode-setting to do -
but vgem's dumb-buffer allocation demands master status regardless, and
wlroots' GBM allocator has no fallback for a device that's present but
never mastered. This looks like a genuine wlroots headless-backend +
dumb-buffer-fallback (`kms_swrast`) combination gap, not a
config/environment problem - `WLR_DRM_NO_MODIFIERS=1` was tried and
made no difference, ruling out a modifier-negotiation issue
specifically.

**The `LD_PRELOAD` shim was tried - TWO versions, both ruled out
(2026-09-03, later same session)**, so the remaining path is a wlroots
source patch, not a userspace workaround. `Guest/init/wayland-tests/
vgem_master_shim.c` (kept in the repo as a record, excluded from
`cage-test.sh`'s sweep - it's a shared-library shim, not a Wayland
client):
1. **v1** intercepted `open`/`openat` and called `drmSetMaster()` right
   after any `/dev/dri/card*` open. Confirmed via added debug output
   that it DID fire and `drmSetMaster()` DID return success (0) - but
   `cage` still failed with the identical `Permission denied`. `strace
   -f -e trace=openat,ioctl` on the real `cage` process showed why:
   Mesa's GBM/KMS code opens and closes MANY `/dev/dri` fds in quick
   succession (both `card0` and `renderD128`, repeatedly, interleaved
   with unrelated file opens) - with `close()` untraced, matching "the
   fd `DRM_IOCTL_MODE_CREATE_DUMB` actually runs on" back to "the fd my
   shim mastered" by number alone proved unreliable; they were very
   likely different underlying opens.
2. **v2** was more surgical specifically to route around that: intercept
   `ioctl()` itself and call `drmSetMaster(fd)` on whatever fd is about
   to run `DRM_IOCTL_MODE_CREATE_DUMB`/`_DESTROY_DUMB`/`_MAP_DUMB`,
   right at the point of use - no fd-identity tracking needed at all.
   Added the same debug fprintf to confirm firing. **It never fired -
   the debug line never printed, while the `KMS: DRM_IOCTL_MODE_CREATE_
   DUMB failed` errors kept happening.** This means the actual ioctl
   call bypasses the dynamically-linked libc `ioctl` symbol entirely
   (most likely a direct `syscall(SYS_ioctl, ...)` somewhere in Mesa's
   GBM backend or libdrm's own `drmIoctl()`, on this musl build) - `LD_
   PRELOAD` symbol interposition fundamentally cannot intercept a call
   that doesn't go through the dynamic symbol lookup, so no version of
   this shim strategy can work here. Confirmed not viable, not just
   "our attempt was wrong."
3. Also fixed along the way, unrelated but real: this same guest boot
   had its clock stuck at the Unix epoch (`date` reported 1970) after a
   `restore failed - falling back to cold boot` event (see
   [[msl_kernel_linux_lts_swap]] for the boot mechanics) - broke `apk`
   entirely (`TLS: server certificate not trusted`, since any cert looks
   "not yet valid" from 1970) until manually corrected with `date -s
   @$(date +%s)` on the host side. Worth knowing about if `apk`/TLS
   ever mysteriously fails again after an unusual boot path - check
   `date` in the guest before suspecting a real network/cert problem.

**The wlroots patch was tried too (2026-09-03, later same session) -
built and installed clean, fixes something real, but ISN'T where the
actual blocker lives.** Cloned `wlroots` upstream at tag `0.20.2`
(matching the installed `wlroots0.20-0.20.2-r0` apk exactly - confirmed
first via `apk info`, not assumed), patched `render/allocator/
allocator.c`'s `reopen_drm_node()` to call `drmSetMaster(drm_fd)` before
its existing `drmIsMaster(drm_fd)`-gated authentication dance (the exact
function/branch the standalone C test's root-cause pointed at), built
clean with `meson`+`ninja` (`-Dbackends=auto -Drenderers=auto
-Dxwayland=enabled` - a first attempt with `-Dxwayland=disabled` broke
`cage` outright with `Error relocating /usr/bin/cage: wlr_xwayland_*:
symbol not found`, since the PREBUILT `cage` binary links against those
symbols even though no Xwayland binary is actually installed - fixed by
enabling xwayland at configure time and installing `xwayland-dev` for
its headers, no need for Xwayland to actually run). Installed over
`/usr/lib/libwlroots-0.20.so` (original backed up as `*.orig.bak`) -
**both regression suites stayed green** with the patched library in
place for the existing pixman path (x11-test.sh 9/9, cage-test.sh 2/2),
so the patch itself is safe. But launching `cage` with `WLR_RENDERER=
gles2` against it STILL hit the identical `KMS: DRM_IOCTL_MODE_CREATE_
DUMB failed: Permission denied` - the patched function evidently isn't
where the actual failing call happens.

**Root-caused one layer deeper**: the `KMS:` prefix on that error
message doesn't appear anywhere in wlroots' own source (confirmed via
`grep -rn 'KMS:' wlroots/` - nothing) - it's a Mesa-internal debug
string. `grep -rl 'KMS:' /usr/lib/` found it inside `libgallium-26.1.6.so`
(Mesa's shared Gallium megadriver, dynamically loaded by `/usr/lib/dri/
kms_swrast_dri.so` - matches the "falling back to kms_swrast" line seen
in every GLES2 attempt's log). So the actual `DRM_IOCTL_MODE_CREATE_DUMB`
call that fails lives inside MESA's own Gallium KMS winsys code, not
wlroots at all - wlroots hands Mesa an fd via `gbm_create_device()`/
`gbm_bo_create()` and Mesa's own internal code does its own thing with
it from there, evidently not inheriting or re-establishing the master
status wlroots' (now-patched) side correctly set up beforehand.

**Mesa WAS patched and rebuilt too (2026-09-03, later same session) -
real progress, but the root cause turned out to be a genuine multi-fd
DRM master ownership conflict, not a missing single call. Ultimately
reverted; documented in full since the investigation itself is the
valuable part.**

Cloned Mesa upstream at the exact matching tag (`mesa-26.1.6`, confirmed
via `apk info mesa` first). Configured a heavily scoped-down build
(`-Dgallium-drivers=llvmpipe -Dplatforms=wayland`, no vulkan/video-
codecs/rust/other-hardware-drivers - Alpine's own real APKBUILD builds
everything, fetched and read first to know the real working flag set
rather than guessing meson option names from scratch) - needed `py3-mako`,
`py3-yaml`, `llvm-dev` (matching the already-running `LLVM 22.1.3`),
`bison`, and `flex` beyond what cage/wlroots already needed. **First
build attempt OOM-killed** (`dmesg` confirmed: a single `nir_opt_
algebraic.py`-generated compilation unit alone used ~734MB RSS against
this VM's 1GB default) - fixed by temporarily bumping `VMConfiguration.
memorySize` to 4GB in `Sources/mslhd/main.swift`'s `makeConfiguration`
(reverted again once the build was done - this is not a real requirement
for normal use, just headroom for one heavy one-off build). Second
attempt built clean (`-j2`, matching the VM's 2 vCPUs).

Grep for the `KMS:` error string across Mesa's own source (same
technique as before) found it in `src/gallium/winsys/sw/kms-dri/
kms_dri_sw_winsys.c` - patched `kms_dri_create_winsys()`'s fd (matching
the wlroots patch's own shape) - built, installed over `/usr/lib/
libgallium-26.1.6.so` (plus `dri_gbm.so`/`libgbm.so.1.0.0`/
`libEGL.so.1.0.0`/`libGLESv2.so.2.0.0`, all backed up first), **still
failed - identical error**. Root-caused further with `strace -f -e
trace=openat` on the real `cage` process: confirmed `/usr/lib/
libgallium-26.1.6.so` (the freshly patched one) genuinely IS the file
loaded at runtime (ruling out "wrong file got patched"), and along the
way found a SEPARATE real bug in the first Mesa install: my rebuilt
`libgbm.so` looked for its DRI backend at Mesa's build-default
`/usr/local/lib/gbm` while the system convention is `/usr/lib/gbm` -
fixed by also placing a copy at `/usr/local/lib/gbm/dri_gbm.so` (a real,
correct, unrelated fix, encountered and fixed along the way).

Kept digging: `grep -rln DRM_IOCTL_MODE_CREATE_DUMB` across ALL of
Mesa's source (not just the `KMS:`-prefixed one) found a SECOND call
site, `src/gbm/backends/dri/gbm_dri.c`'s `create_dumb()` (gated on
`GBM_BO_USE_CURSOR`/`GBM_BO_USE_SCANOUT` - matches a headless output's
swapchain buffer, which requests scanout capability even though nothing
physically scans out) - patched that too, rebuilt (fast incremental
build, ~3 files), reinstalled. **Still the identical error** - and
critically, the error was still the `KMS:`-prefixed one specifically,
meaning `gbm_dri.c`'s own call site wasn't even the one being hit -
`kms_dri_sw_winsys.c`'s patched `kms_dri_create_winsys()` (called once,
at device-creation time) evidently wasn't keeping the fd mastered by
the time the LATER buffer-creation call ran. Added a SECOND, more
surgical `drmSetMaster()` call directly inside `kms_sw_displaytarget_
create()` itself (the actual function containing the failing
`drmIoctl` call, found via `sed`-viewing the file directly) - same
"fix at the literal point of use" principle that worked for the
gbm_dri.c patch's own reasoning.

**Added temporary debug `fprintf` output directly in the patch to stop
guessing and see ground truth** (a `python3 -c "..."` inline-string
attempt to write it corrupted the file with an unescaped newline inside
a C string literal - fixed by writing the patch as a real `.py` file on
the host and running it through the virtiofs share instead, avoiding
bash->python->C multi-layer escaping entirely - worth remembering for
any future guest-side source patching via `msl --`). The debug output
was the real breakthrough: `drmSetMaster` itself was returning `-1`
(`EACCES`), not just the subsequent `CREATE_DUMB` ioctl - meaning
**something ELSE already held DRM master on a DIFFERENT fd**, and
Linux DRM master is exclusive PER-DEVICE, not per-fd - a second,
different open file description trying to also claim master on the
same device is rejected outright. The prime suspect was the EARLIER
wlroots patch (`reopen_drm_node()`'s own `drmSetMaster()` call, which
by this point in the investigation was still installed and active) -
claiming master on ITS OWN fd first, before Mesa's internal code ever
got a chance to claim it on a DIFFERENT fd for the SAME device.
**Reverted the wlroots patch specifically to test this theory - the
identical `EACCES` STILL happened.** This rules out "wlroots's patch is
the culprit" and points to something earlier and more fundamental:
almost certainly wlroots' OWN, ORIGINAL, un-patched EGL device-query
code (`render/egl.c`, confirmed active earlier in every GLES2 attempt's
log via `Using EGL device /dev/dri/card0`) opens `/dev/dri/card0`
before any of this - and either that open implicitly becomes master
(a known, real Linux DRM behavior: the FIRST-ever open of a DRM primary
node when nobody holds master yet can auto-grant it, depending on
kernel version/config), or some other equally early code path does the
same, ahead of anything this investigation's patches could reach.

**Reverted everything** (wlroots and all 5 Mesa libraries restored from
their `*.orig.bak` backups, backups then deleted since they're now
redundant; the temporary 4GB `memorySize` bump reverted back to
`mslhd`'s normal 1GB default) - confirmed via BOTH regression suites
(x11-test.sh 9/9, cage-test.sh 2/2) AND the Phase 3/4 debug commands
(`cage-bridge-test`, `cage-input-test` - both still pass) that the
system is back to the exact known-good state this whole investigation
started from.

**What a real fix would actually require, if this gets picked up
again**: not another single-point patch, but tracing EVERY fd that
opens `/dev/dri/card0`/`renderD128` across wlroots' `render/egl.c` +
`render/allocator/*.c` AND Mesa's `src/gbm/backends/dri/gbm_dri.c` +
`src/gallium/winsys/sw/kms-dri/kms_dri_sw_winsys.c`, understanding which
ONE of them (if any) should legitimately hold master, and either (a)
preventing the earlier ones from claiming it in the first place, or (b)
switching to the `drmGetMagic`/`drmAuthMagic` model consistently
throughout (the mechanism `reopen_drm_node()` already uses correctly
for ITS OWN re-opened fd) instead of naively calling `drmSetMaster()`
at every layer that happens to hit a permission error. That's a real
architectural fix across two codebases' fd-lifecycle management, not a
few-line patch - genuinely open-ended effort, not a bounded one.

**Not yet done / deliberately out of scope for this pass**: wiring
`CageBridge`/`CageInputBridge`/`CageCanvasView` into a real user-facing
`msl cage <instance> <app>`-style command (today's `cage-view` is
explicitly debug-only, per the advisor's own scoping call - "leave the
user-facing command out of this pass, it'll be shaped by whatever you
learn from the first working window," which is exactly what happened:
the `ensureActivated()` and stale-bridge bugs above were both found
BECAUSE a real window was built first); full keyboard layout coverage
in `CageKeyMapping` (only common ANSI-US keys); any non-XRGB8888
`wl_shm` format; multi-window/multi-instance `cage-view` sessions running
concurrently (each `VMManager` only tracks one `cageWindow` at a time).

---

*(Original planning notes below, written before any of the above was
attempted - still accurate for the parts not superseded above, e.g. the
"why this needs the headless backend at all" transport-layer reasoning.)*

## The vision this serves

Stated goal for the project: `mslgd` (this from-scratch X11 server) runs
the great majority of real Linux GUI apps via X11, and **cage** — a
minimal Wayland *kiosk* compositor (wraps exactly one app, fullscreen, no
window decorations or window management of its own — see
[cage-kiosk/cage](https://github.com/cage-kiosk/cage)) — covers the
remainder: apps that are Wayland-only with no X11/Xwayland fallback.
Not urgent, not started; this file exists so the shape of the problem
and the real blockers are written down once, instead of re-discovered
from scratch whenever this becomes active work.

## Where it fits the existing architecture

`msl`/`mslhd` already has a working split worth reusing exactly as-is:
a lightweight Alpine Linux guest VM (`Virtualization.framework`) runs the
actual client apps, and `mslhd` (native Swift/AppKit on the host) speaks
the X11 protocol to them over a tunnel, rendering into `NSWindow`/
`NSView`. Cage would run **inside that same guest VM**, alongside
whatever X11 apps are already running there — not as a separate VM, not
as something running directly on macOS (cage/wlroots have zero macOS
support; they're Linux-only, and porting wlroots itself is out of scope
here).

## The real blocker: Wayland's transport model doesn't tunnel like X11's

This is the part worth being honest about before committing time to it.
X11 tunnels cleanly because the protocol is a plain byte stream end to
end — even pixel data (`PutImage`) is just bytes on the wire, which is
exactly why the guest→host virtiofs/tunnel setup this project already
has works at all. Wayland's actual, commonly-used path is the opposite:
a client and the compositor share pixel buffers directly via `wl_shm`
(shared memory) or `dmabuf` (GPU buffer handles) — file descriptors
passed over a local Unix socket via `SCM_RIGHTS`. A shared-memory segment
or a GPU buffer handle fundamentally can't cross the guest/host VM
boundary the way a plain byte stream can; there is no equivalent of
"just forward the socket" for the part that actually carries pixels.

So this isn't "implement another protocol handler" the way XRANDR/SHAPE
were this session — it's a genuinely different data-path problem, and
pretending otherwise going in would waste a lot of time discovering that
partway through.

## The way around it: target wlroots' headless backend, not a real one

wlroots (cage's compositor backend) has a **headless backend** — renders
into an offscreen buffer instead of real DRM/KMS output, originally built
for their own CI/testing. That buffer is plain, readable memory *inside
the guest* — no cross-VM buffer-sharing needed. The existing
`MSL_X11_SNAPSHOT_DIR` mechanism (`mslgd` already dumps a drawable's
bitmap to a PNG on change, used by the whole Layer-0 test pyramid) is the
proven template: read cage's headless-backend framebuffer the same way,
write it out, ship it across the exact same guest→host path already
working today. Input goes the other direction the same shape `mslgd`'s
own test scripts already use (synthetic events), via whatever headless-
backend input-injection wlroots exposes for its own testing — needs
checking against the specific wlroots version once this starts for real.

## Realistic phases (roughly in order)

0. **Get cage + wlroots building at all in the Alpine guest.** Real open
   question, not yet checked: wlroots' dependency chain (libdrm,
   libinput, EGL/GBM, pixman, wayland-protocols) may assume glibc in
   places Alpine's musl doesn't provide — this project's existing guest
   apps (galculator, xterm, gtk-tests, qt-tests) are all much lighter
   dependency-wise, so this is genuinely unverified territory, not a
   known-good path like `apk add gtk+3.0-dev` has been all session.
1. **One static frame round-trip**: cage running headless with some
   trivial Wayland client, its framebuffer dumped and pulled to the host
   once, confirmed correct by eye — the Wayland-side equivalent of this
   session's very first `01_window_lifecycle.c` test, deliberately that
   modest in scope.
2. **Input round-trip**: a synthetic click/keypress delivered into cage's
   headless session, confirmed via a changed frame — mirrors the
   CGEventPost-driven live-testing technique this whole session's
   XI2/XKB/menu work depended on.
3. **Continuous/live**, not poll-a-PNG: real frame streaming and input,
   interactive rather than scripted single-shot tests.
4. **Visual integration** — much later, and genuinely open which shape is
   right: one `NSWindow` per Wayland surface (matching how `mslgd`
   already gives each X11 top-level window its own `NSWindow`), or a
   single kiosk-style `NSWindow` showing cage's whole output as one "app"
   window (matching cage's own single-app design more literally, simpler
   but less integrated-feeling alongside X11 windows).

## Before picking this up for real

- Confirm wlroots' headless backend actually still exists/works in
  whatever version is current when this starts (it's existed for years
  but isn't the most-used path, worth a fresh check, not an assumption).
- Confirm Alpine has (or can get) the dependency chain — do this BEFORE
  writing any integration code, the same lesson [[mslgd_br2_reference]]
  already learned the hard way for XQuartz's own build (five small, only-
  found-by-actually-building meson-config patches).
- Decide up front whether this is worth it vs. simply accepting "some
  Wayland-only apps aren't supported" as a permanent limitation — cage
  covers a real but narrow case (Wayland-only, no Xwayland path), and the
  transport-layer work above is substantial for that payoff. Not a
  decision to make in this file; flagging it so it's made deliberately
  later, not by default momentum.
