# vanishing-apps

The kit that root-caused MSL's longest-running bug: GUI apps disappearing
with no crash report. Full write-up in `READMES/28-THE-VANISHING-APPS-BUG.md`.

- **`xspy.c`** — the one that cracked it. `LD_PRELOAD` shim that replaces
  GDK's `_exit(1)` I/O error handler with one that dumps state and a
  backtrace, and logs syscalls on the X socket. The decisive evidence (672 MB
  written against 27 MB read, short writes throughout) is below the app at the
  syscall boundary, invisible to mslgd, to gdb and to every log.
  Build with `build-xspy.sh`, run with `run-xspy.sh`, read with `xspy-wait.sh`.
- **`gimp-hunt.sh`** — boots an instance, drives GIMP, detects a death,
  captures gdb + mslgd's wire rings + the last actions, restarts. Honours
  `~/msl-debug/STOP`.
- **`churn.py`** — the fast reproducer: layer add / duplicate / undo-redo
  thrash / re-open a large image. Drawable churn, far faster than random input.
- **`act.py`**, **`vlm_driver.py`**, **`haswin.py`** — the randomized driver
  and window helpers. `vlm_driver` can route actions through a local vision
  model (`MSL_HUNT_VLM=1`), but note both models tested were unusable for
  pointing: llama3.2-vision will not load on ollama 0.35.1 ("unknown model
  architecture: 'mllama'") and qwen2.5vl:7b answered with round numbers
  unrelated to the screenshot at 57s per call.

Everything clamps input to the target window: these post real CGEvents
unattended, and a stray click lands on the Dock or the menu bar.
