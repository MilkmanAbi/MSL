#!/usr/bin/env python3
"""Layer churn: add, remove, re-add, switch back and forth.

This is the user's reproducer, and it is far faster than random clicking -
which makes sense. Adding and removing layers churns DRAWABLES: every layer
and every thumbnail in the Layers dialog is a pixmap created, drawn into
with PutImage, read back with GetImage, and freed. Those are exactly the
opcodes left unanswered in all seven of the clearest recorded deaths
(ChangeGC, PolyFillRectangle, PutImage, GetImage) plus GetInputFocus.
"""
import random, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path.home() / "msl-debug"))
sys.path.insert(0, "/Users/abinaash/Desktop/MSL-Project")
import vlm_driver as V

SIM = "/Users/abinaash/Desktop/MSL-Project/input_sim.py"
# GIMP 3 defaults: new layer, delete layer, duplicate, undo, redo.
K = {"n": 45, "d": 2, "z": 6, "y": 16, "ret": 36, "esc": 53, "o": 31, "l": 37}


def run(a):
    subprocess.run([sys.executable, SIM] + a, capture_output=True, timeout=30)


def log(k, d):
    print(f"{time.strftime('%H:%M:%S')} {k} {d}", flush=True)


def main():
    win = V.gimp_window()
    if not win:
        log("skip", "no window"); time.sleep(2); return

    for _ in range(random.randint(4, 9)):
        win = V.gimp_window()
        if not win:
            log("gone", "window vanished during churn"); return
        pick = random.random()
        if pick < 0.35:
            # New layer: dialog, confirm. Creates a drawable and repaints
            # the layers dialog thumbnails.
            run(["key", str(K["n"]), "--mods", "shift,ctrl"]); time.sleep(0.9)
            run(["key", str(K["ret"])]); time.sleep(0.7)
            log("layer", "new")
        elif pick < 0.6:
            run(["key", str(K["d"]), "--mods", "shift,ctrl"]); time.sleep(0.8)
            log("layer", "duplicate")
        elif pick < 0.85:
            # Undo/redo thrashes the same drawables back and forth, which is
            # the "adding then removing then readding" the user described.
            for _ in range(random.randint(2, 5)):
                run(["key", str(K["z"]), "--mods", "ctrl"]); time.sleep(0.3)
            for _ in range(random.randint(1, 4)):
                run(["key", str(K["y"]), "--mods", "ctrl"]); time.sleep(0.3)
            log("layer", "undo/redo thrash")
        else:
            run(["key", str(K["o"]), "--mods", "ctrl"]); time.sleep(1.2)
            run(["key", str(K["l"]), "--mods", "ctrl"]); time.sleep(0.6)
            subprocess.run(["osascript", "-e",
                            'tell application "System Events" to keystroke "/tmp/Starry-Night.png"'],
                           capture_output=True, timeout=20)
            time.sleep(0.4); run(["key", str(K["ret"])]); time.sleep(2.5)
            log("layer", "re-open image")


if __name__ == "__main__":
    main()
