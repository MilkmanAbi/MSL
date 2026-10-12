# Virtual GPU — real OpenGL for Linux apps, on the Mac's GPU

Status (2026-09-25): **working proof of concept.** A Linux guest app gets
`OpenGL 4.1 (Apple M2)` and renders on the Mac's real GPU through Metal.
`es2gears` runs at **215 FPS** with correct output and zero software
fallbacks. The renderer is not yet wired into MSL (it is started by hand) —
see "What is left" below. **GLX itself is done and shipped in mslgd**, so
classic GL apps now run on the CPU path out of the box; see "GLX" below.

## How it works

Nothing here emulates a GPU. The guest's own Mesa already ships a driver
for exactly this, `virpipe`, which forwards Gallium commands over a socket
instead of to a kernel DRM device:

```
Linux app → Mesa (GALLIUM_DRIVER=virpipe) → unix socket
   → [Mac] virgl_test_server → virglrenderer → Apple OpenGL 4.1 → Metal → GPU
```

The guest side needs **no changes at all**: Debian's Mesa 25.0.7 already
has `virpipe` compiled in (verified: `VTEST_SOCKET_NAME` and `virpipe`
appear in `libgallium-*.so`). The Mac side is `virglrenderer`, the same
library QEMU/UTM use, built for macOS.

## Building the host renderer

Dependencies come from the community macOS taps (ANGLE-on-Metal builds
used by the QEMU/UTM crowd); they are bottled, so this is minutes not
hours:

```sh
brew trust startergo/virglrenderer startergo/angle startergo/libepoxy startergo/gn
brew tap startergo/virglrenderer && brew install startergo/virglrenderer/virglrenderer
```

That gives `libvirglrenderer` + `virgl_test_server`, but the shipped
server cannot initialise (`EGL is not supported on this platform`). We
build our own from upstream 1.3.0 with the tap's 21 macOS patches plus
`patches/msl-virglrenderer-macos.patch` (ours):

```sh
curl -L "https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.gz?ref_type=tags" | tar xz
cd virglrenderer-1.3.0
for p in /opt/homebrew/Library/Taps/startergo/homebrew-virglrenderer/patches/virglrenderer-*.patch; do patch -p1 -i $p; done
patch -p1 -i .../patches/msl-virglrenderer-macos.patch
python3 -m pip install --user pyyaml            # the gallium subproject needs it
A=/opt/homebrew/opt/angle; E=/opt/homebrew/opt/libepoxy
meson setup build --buildtype=release "-Dc_args=-I$A/include" "-Dcpp_args=-I$A/include" \
  "--pkg-config-path=$A/lib/pkgconfig:$E/lib/pkgconfig" \
  "-Ddrm-renderers=[]" -Dvenus=false -Dtests=false -Dvideo=false -Dtracing=none
ninja -C build
# meson drops our extra link args for the server, so link it by hand with -lEGL
```

## Running it

Since 2026-09-25 the transport is **vsock**, wired into MSL: `GPUBridge`
(`Sources/MSLCore/GPUBridge.swift`) listens on vsock port 5011 and, per
connection, **spawns** a renderer and relays bytes to it. Turn it on with
the `gpuAcceleration` experimental flag and put the renderer where the
bridge looks:

```sh
cp virgl_test_server libvirglrenderer.1.dylib ~/Library/Application\ Support/MSL/bin/
codesign --force --sign - ~/Library/Application\ Support/MSL/bin/virgl_test_server
# then set "gpuAcceleration": true in ~/Library/Application Support/MSL/experimental.json
```

mslhd logs `GPU acceleration available (<path>)` at instance start when it
finds it; without it, GL apps keep rendering on the guest's CPU.

The guest end is `x11tunnel` with `--socket-path` (its relay carries any
stream, not just a display):

```sh
x11tunnel 0 5011 --socket-path /tmp/.virgl_test &     # in the guest
GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=1 <app>
```

`Guest/x11-torture/gputunnel.sh` does the first line. **It is not started
automatically yet**: the shipped images carry an `x11tunnel` from before
`--socket-path` existed, and an old one given that flag would ignore it and
bind a display socket instead - so auto-start waits for the image rebuild
(`IMAGE-REBUILD-SG.md`). Until then, build the current
`Guest/init/x11tunnel.c` into the guest and run it by hand.

No SSH is involved any more. Measured: `glxgears` 88-92 FPS over vsock
against 66 over the old SSH forward.

## What our patch changes, and why

1. **GL context callbacks (`vtest_renderer.c`).** This virglrenderer build
   expects its embedder to own the GL contexts, as QEMU does; without
   them it dies with "EGL is not supported on this platform". We provide
   them two ways, chosen by `MSL_VIRGL_BACKEND`:
   - `cgl` (default): Apple's own OpenGL 4.1 core, on Metal. **This is the
     one that works.** The guest sees GL 4.1.
   - `angle`: ANGLE's EGL (GLES 3 on Metal). Works, but virgl only
     advertises **GL 2.1** to the guest through it, so it is strictly
     worse here. Kept because it is the configuration the tap's macOS
     patches were written for.
2. **One share group.** All contexts share with one root context created
   at init and never handed to virglrenderer (which destroys its first,
   probe context). Sharing with "whatever is current" gave a context
   created with nothing current no sharing at all.
3. **Flush on context switch.** GL only guarantees another context sees
   this one's rendering after a flush. Mesa hosts flush implicitly on a
   switch; Apple's GL batches for Metal and does not, so readbacks from
   the next context returned the frame *before* the draws landed —
   exactly the clear colour, which reads as "nothing rendered".
4. **No fence thread** (`VIRGL_RENDERER_THREAD_SYNC` cleared, override
   with `MSL_VIRGL_THREAD_SYNC=1`). It drives a second shared context
   concurrently and Apple's GL is not safe for that without
   `CGLLockContext`; it aborted inside `AppleMetalOpenGLRenderer` while
   restoring texture data.

## The fork trap — the thing that cost the most time

`virgl_test_server` **forks per client** by default. macOS does not
support using system frameworks in a forked child that has not `exec`d,
so every Metal shader compile in the child failed:

- ANGLE said it plainly: `Unable to reach MTLCompilerService … Connection
  init failed at lookup with error 3`.
- Apple's GL said it obliquely: `buildPipelineState failed` → `Fallback to
  SW vertex processing`, and then drew **nothing**. Clears and
  `gl_VertexID` triangles still worked, so it looked like a bug in vertex
  buffers specifically — it is not, and hours went into chasing swizzles,
  VAO sharing, depth formats and BGRX before the fork turned out to be it.

With `--no-fork` everything works and there are zero fallbacks.
`--multi-clients` re-introduces forking and fails again.

**Consequence for MSL's design:** one renderer process per client,
spawned (not forked) on demand. That is a perfect fit for MSL, which
already runs one `mslgui` host process per Linux app — the GPU server
becomes another per-app process. Sequential clients against one server
were verified clean (3/3, renderer re-inits per client).

## Verified

Pixel-checked from the guest (`Guest/x11-torture/glsurface.py`,
`glinfo.py`), against llvmpipe as the control:

| | llvmpipe (CPU) | virpipe (Mac GPU) |
|---|---|---|
| reported renderer | `llvmpipe (LLVM 19.1.7)` | `virgl (Apple M2)`, GL 4.1 |
| FBO clear + readback | correct | correct |
| shader draw, no attributes | correct | correct |
| draw from a vertex buffer | correct | correct |
| + depth attachment, cull | correct | correct |
| es2gears (800×600, on screen) | 850 FPS | **215 FPS**, correct image |

es2gears is *faster* on llvmpipe only because it is a trivial scene where
the socket round trip dominates; the CPU path collapses on real work,
which is the point of this.

## GLX (done, 2026-09-25)

mslgd now implements GLX (`Sources/MSLCore/X11/X11GLX.swift`), so classic
GL apps start and render. It is the *setup* protocol only - Mesa renders in
the guest and presents through core X11 - which is exactly what lets one
implementation serve both the CPU path and this GPU one:

| | CPU (llvmpipe) | GPU (virpipe) |
|---|---|---|
| `glxgears` | 154 FPS | 66 FPS, `GL_RENDERER = virgl (Apple M2)` |
| Blender 4.3.2 | **runs**, viewport interactive | refuses: needs GL 4.3 |

**Apple's OpenGL caps at 4.1**, so the GPU path tops out there and Blender
(which wants 4.3+) reports "Unsupported hardware"; on the CPU path Mesa
offers 4.5 and it runs. Getting past that means Vulkan rather than GL on
the host - virglrenderer's Venus protocol onto MoltenVK - which is a
separate and larger piece of work.

## Performance: the round trip is the cost, not the GPU (2026-09-25)

Measured with `Guest/x11-torture/glbench.py` (a fragment-heavy shader into
an FBO, timed with and without `glReadPixels`), llvmpipe as the control:

| 1024x1024, heavy shader | render | render + readback |
|---|---|---|
| llvmpipe (CPU) | 231 ms | 229 ms |
| virpipe (Mac GPU) | **6.6 ms** | 20.6 ms |

So the GPU renders ~35x faster, but reading the frame back over the socket
is **68% of the wall-clock** on the GPU path, and it scales linearly with
frame bytes (~395 MB/s after the relay was rewritten to use offset buffers
instead of `removeFirst`; the transport itself is the ceiling). A 4 MB
frame costs ~10 ms no matter how fast it rendered.

**This is why a zero-copy present is the next real win, not more rendering
speed.** The frame is read guest->host over the socket and then pushed
host->guest->host again through X11 `PutImage`; both crossings are pure
copy. The fix is to render into an IOSurface on the Mac and composite it
directly into the app's `NSWindow`, so the pixels never cross vsock. That
needs a present path that bypasses the guest's X11 image upload - larger
than this PoC and not yet started.

## Venus / Vulkan: works on the host, blocked at the transport (2026-09-25)

The pieces are all present and were verified individually:
- **Host:** the renderer builds with `-Dvenus=true`; a real Vulkan loader
  (1.4.357) + MoltenVK give `Apple M2, Vulkan 1.0` on the Mac.
- **Guest:** `mesa-vulkan-drivers` installed - Venus ICD (`virtio_icd.json`)
  and Zink (`zink_dri.so`, GL 4.6 over Vulkan) are both there.
- Venus's own `vkr_library.c` already dlopens `libvulkan.1.dylib`, and its
  vtest transport strings are present.

**But Venus over vtest needs shared memory, and there is none across the VM
boundary.** vtest's shared buffers are `memfd_create` (`vtest_shm.c`) -
Linux-only, and same-host-only even there: the memfd is shared between a
vtest server and a client on the *same kernel*. Venus refuses protocol
version 0 ("vtest protocol version (0) too old") because GL's copy-based
fallback is not enough for it. Real Venus rides virtio-gpu **blob**
resources (guest pages the host maps directly), which is exactly what
Virtualization.framework does not expose.

Getting Vulkan past Apple's GL 4.1 ceiling therefore needs one of: a
custom copy-based Venus transport (large, and it reintroduces the same
readback cost), or a real virtio-gpu device (not available here). The
`--venus` flag is wired in the renderer (in-process on macOS, gated by
`MSL_VIRGL_RENDER_SERVER`) so this is ready to resume, but it is not a
near-term path. Zink-on-Venus would have given GL 4.6; for now GL stays at
4.1 on the GPU and 4.5 on the CPU.

## What is left

1. **Auto-start in the guest** (and exporting `GALLIUM_DRIVER=virpipe` for
   apps), once the images ship an `x11tunnel` that understands
   `--socket-path`.
2. **Present path.** Today the guest reads the rendered frame back over
   the socket and pushes it through X11 as an image. A zero-copy present
   (IOSurface) is the obvious later win.
3. **Venus/MoltenVK** to get past GL 4.1 - blocked at the transport, see above.
4. **ANGLE's low caps** (GL 2.1) if we ever need ANGLE instead of CGL.
5. Tested against `glxgears`, `es2gears`, Blender and our own probes.
