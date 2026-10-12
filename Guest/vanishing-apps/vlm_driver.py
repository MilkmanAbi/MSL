#!/usr/bin/env python3
"""Drives GIMP with a local vision model, hunting the vanishing-app bug.

The model looks at a screenshot of GIMP and says where to click. Everything
it returns is treated as a suggestion from an untrusted source: coordinates
are clamped to GIMP's own window, keystrokes are filtered against a block
list, and anything unparseable is replaced with a random action rather than
retried. This runs unattended for an hour posting REAL CGEvents, so a stray
click outside the window would land on the Dock, the menu bar, or whatever
else is on screen.

Coordinates are macOS screen POINTS. `screencapture` gives Retina PIXELS, so
every crop is divided by 2 before it reaches input_sim.
"""
import base64, json, random, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, "/Users/abinaash/Desktop/MSL-Project")
import input_sim

OLLAMA = "http://127.0.0.1:11434/api/generate"
SHOTS = Path.home() / "msl-debug" / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)

# Keys that would end the session, hide the app, switch away, or lock the
# screen. The model is told not to ask for these; this is the backstop for
# when it does anyway.
BLOCKED_KEYS = {12, 13, 4, 46, 48, 49, 53}   # q w h m tab space esc
BLOCKED_MODS = {"cmd", "ctrl"}


def gimp_window():
    """GIMP's main window, or None. Dialogs count - they are part of the app."""
    wins = [w for w in input_sim.mslgd_windows() if w["w"] > 200 and w["h"] > 150]
    if not wins:
        return None
    return max(wins, key=lambda w: w["w"] * w["h"])


def shot(win):
    """A PNG of just GIMP, kept in a rolling buffer of 10."""
    path = SHOTS / f"s{int(time.time()*1000)}.png"
    subprocess.run(["screencapture", "-x", "-R",
                    f"{win['x']},{win['y']},{win['w']},{win['h']}", str(path)],
                   capture_output=True)
    old = sorted(SHOTS.glob("s*.png"))[:-10]
    for f in old:
        f.unlink(missing_ok=True)
    return path


def ask(model, path, prompt):
    """One vision call. Returns raw text, or '' on any failure."""
    try:
        img = base64.b64encode(path.read_bytes()).decode()
        body = json.dumps({"model": model, "prompt": prompt,
                           "images": [img], "stream": False,
                           "options": {"temperature": 0.9}})
        # Via a file, never argv: a base64 screenshot is megabytes and
        # blows past ARG_MAX ("Argument list too long").
        req = SHOTS.parent / "req.json"
        req.write_text(body)
        out = subprocess.run(["curl", "-s", "--max-time", "90", OLLAMA,
                              "-d", "@" + str(req)], capture_output=True, text=True)
        return json.loads(out.stdout).get("response", "")
    except Exception:
        return ""


def clamp(win, x, y):
    """Into GIMP's window, with a small inset so no click lands on an edge."""
    return (min(max(x, win["x"] + 6), win["x"] + win["w"] - 6),
            min(max(y, win["y"] + 30), win["y"] + win["h"] - 6))


def random_action(win):
    """The volume layer. A model call takes seconds; this takes none, and
    crash-hunting is mostly a numbers game."""
    x = random.uniform(win["x"] + 10, win["x"] + win["w"] - 10)
    y = random.uniform(win["y"] + 34, win["y"] + win["h"] - 10)
    kind = random.choice(["click", "click", "move", "drag", "scroll", "rclick"])
    if kind == "drag":
        x2 = random.uniform(win["x"] + 10, win["x"] + win["w"] - 10)
        y2 = random.uniform(win["y"] + 34, win["y"] + win["h"] - 10)
        return ["drag", f"{x:.0f}", f"{y:.0f}", f"{x2:.0f}", f"{y2:.0f}"]
    if kind == "scroll":
        return ["scroll", f"{x:.0f}", f"{y:.0f}", str(random.choice([-5, -2, 2, 5]))]
    return [kind, f"{x:.0f}", f"{y:.0f}"]


def run(cmd):
    subprocess.run([sys.executable, "/Users/abinaash/Desktop/MSL-Project/input_sim.py"]
                   + cmd, capture_output=True, timeout=30)


def parse_point(text, win, shot_path):
    """Pull an (x, y) out of the model's reply and map it to screen points.

    The reply is in IMAGE pixels of the crop we sent; the crop is Retina, so
    halve it, then add the window's origin.
    """
    import re
    nums = re.findall(r"-?\d+\.?\d*", text)
    if len(nums) < 2:
        return None
    try:
        px, py = float(nums[0]), float(nums[1])
    except ValueError:
        return None
    return clamp(win, win["x"] + px / 2.0, win["y"] + py / 2.0)
