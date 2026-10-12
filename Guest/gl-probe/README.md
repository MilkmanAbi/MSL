# GL probes for mslgd's GLX

- `glxprobe.c`: conformance checks for the paths real apps use. It covers
  glXChooseVisual (single-buffered, alpha), one visual per config, SGIX
  pbuffers and context-with-config, GLX 1.3 pbuffers + glXQueryDrawable,
  texture-from-pixmap, and the window visual round trip.
  `gcc -o /tmp/glxprobe glxprobe.c -lGL -lX11` (needs `libgl-dev libx11-dev`), then
  `msl gui-native <inst> /tmp/glxprobe`. Prints `RESULT: 0 failures`.
- `vendornames.c`: asks for `GLX_VENDOR_NAMES_EXT` over raw xcb, the way
  libglvnd does (`glXQueryServerString` can't ask for it). Expect `mesa`.
  `gcc -o /tmp/vn vendornames.c -lxcb -lxcb-glx`.

To compare with a real server: `apt install xvfb`, run `Xvfb :7`, and point the
same tools (or `glxinfo -v`) at `DISPLAY=:7`.
