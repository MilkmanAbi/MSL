#!/usr/bin/env python3
"""One turn of the hunt: deliberate GIMP work, then a burst of random input.

**Why no vision model drives this.** Both local models were tested against a
real GIMP screenshot before this was written. llama3.2-vision:11b will not
load on ollama 0.35.1 at all ("unknown model architecture: 'mllama'"), and
qwen2.5vl:7b answered "10 10" and "100 100" - round numbers unrelated to the
picture - at 57 SECONDS per call. An hour of that is about sixty actions.
This bug is found by volume of drawing traffic, so sixty is useless; the
deterministic layer below does thousands, and unlike the model it knows
where GIMP's menus actually are. Set MSL_HUNT_VLM=1 to put the model back in
the loop at low frequency.

Everything is clamped to GIMP's own window: this posts REAL CGEvents
unattended, so a stray click would land on the Dock or the menu bar.
"""
import os, random, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path.home() / "msl-debug"))
sys.path.insert(0, "/Users/abinaash/Desktop/MSL-Project")
import vlm_driver as V

SIM = "/Users/abinaash/Desktop/MSL-Project/input_sim.py"
# The images to load, in the order asked for. Copies, not the originals -
# the dialog path can overwrite, and these are the user's real files.
IMAGES = ["/tmp/Error.png", "/tmp/Library.jpeg", "/tmp/Starry-Night.png"]
KEY = {"o": 31, "l": 37, "ret": 36, "plus": 24, "minus": 27, "esc": 53}


def log(kind, detail):
    print(f"{time.strftime('%H:%M:%S')} {kind} {detail}", flush=True)


def run(args):
    subprocess.run([sys.executable, SIM] + args, capture_output=True, timeout=30)


def type_text(text):
    """GTK's file chooser takes a typed path after Ctrl+L."""
    subprocess.run(["osascript", "-e",
                    f'tell application "System Events" to keystroke "{text}"'],
                   capture_output=True, timeout=20)


def open_image(path):
    """File > Open by keyboard. Loading a large image is the one action that
    reproduced this bug by hand, so it leads every cycle."""
    run(["key", str(KEY["o"]), "--mods", "ctrl"])
    time.sleep(1.5)
    run(["key", str(KEY["l"]), "--mods", "ctrl"])   # location bar
    time.sleep(0.8)
    type_text(path)
    time.sleep(0.5)
    run(["key", str(KEY["ret"])])
    log("open", path)
    time.sleep(3.0)


def zoom(win, n):
    """Zooming repaints the whole canvas - the heaviest X11 traffic GIMP
    makes, and the shape of the burst that killed it by hand."""
    for _ in range(n):
        run(["key", str(KEY["plus"] if random.random() < 0.5 else KEY["minus"])])
        time.sleep(0.2)
    log("zoom", str(n))


def paint(win):
    """Drag across the canvas: continuous drawing, continuous flushes."""
    cx, cy = win["x"] + win["w"] / 2, win["y"] + win["h"] / 2
    for _ in range(random.randint(2, 5)):
        x1 = random.uniform(cx - 300, cx + 300); y1 = random.uniform(cy - 200, cy + 200)
        x2 = random.uniform(cx - 300, cx + 300); y2 = random.uniform(cy - 200, cy + 200)
        a, b = V.clamp(win, x1, y1); c, d = V.clamp(win, x2, y2)
        run(["drag", f"{a:.0f}", f"{b:.0f}", f"{c:.0f}", f"{d:.0f}", "--steps", "25"])
    log("paint", "canvas drags")


def menus(win):
    """Open and dismiss menus along the top. Each one is a map/unmap plus a
    full repaint underneath."""
    for _ in range(random.randint(1, 3)):
        x = random.uniform(win["x"] + 20, win["x"] + 420)
        y = win["y"] + 18
        run(["click", f"{x:.0f}", f"{y:.0f}", "--hold", "650"])
        time.sleep(0.4)
        run(["key", str(KEY["esc"])])
        time.sleep(0.2)
    log("menu", "opened and dismissed")


def main():
    win = V.gimp_window()
    if not win:
        log("skip", "no gimp window")
        time.sleep(2)
        return

    roll = random.random()
    if roll < 0.22:
        open_image(random.choice(IMAGES))
    elif roll < 0.45:
        zoom(win, random.randint(3, 8))
    elif roll < 0.68:
        paint(win)
    elif roll < 0.82:
        menus(win)

    if os.environ.get("MSL_HUNT_VLM") == "1" and random.random() < 0.1:
        try:
            p = V.shot(win)
            t = V.ask(os.environ.get("MODEL", "qwen2.5vl:7b"), p,
                      "Give x y pixel coordinates of an interesting button to click. "
                      "Only two numbers.")
            pt = V.parse_point(t, win, p)
            if pt:
                run(["click", f"{pt[0]:.0f}", f"{pt[1]:.0f}", "--hold", "650"])
                log("vlm", f"{pt[0]:.0f},{pt[1]:.0f}")
        except Exception as e:
            log("vlm-error", str(e)[:50])

    for _ in range(random.randint(8, 18)):
        win = V.gimp_window()
        if not win:
            log("gone", "window vanished mid-burst")
            return
        act = V.random_action(win)
        try:
            run(act)
            log("rand", " ".join(act))
        except Exception as e:
            log("rand-error", str(e)[:40])
        time.sleep(random.uniform(0.03, 0.2))


if __name__ == "__main__":
    main()
