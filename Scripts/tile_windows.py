#!/usr/bin/env python3
"""Tile mslgd's on-screen windows so all test apps are visible at once.

Identifies each app's window by its CURRENT size (every app under test has a
distinct default size) rather than by window index - System Events' window
ordering and CGWindowList's ordering do NOT agree, and index-based matching
picked the wrong window repeatedly during earlier testing.
"""
import os
import subprocess
import sys

import AppKit

import Quartz


SHIM_DIR = os.path.expanduser("~/Library/Caches/MSL/AppShims")


def _is_mslgd_owner(pid, name):
    """Whether this window belongs to mslgd.

    Each Linux app now runs in its OWN macOS process, named after the app -
    that is how it gets its own Dock tile - so windows are owned by "Krita",
    "Abiword", ... rather than all by "mslhd". Matching on the name alone
    would also match a real macOS app of the same name, so confirm the
    executable actually lives in the per-app shim directory.
    """
    if name == "mslhd":
        return True
    app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
    url = app.executableURL() if app else None
    return bool(url) and url.path().startswith(SHIM_DIR)


def mslgd_windows():
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    out = []
    for w in wins:
        if not _is_mslgd_owner(w.get("kCGWindowOwnerPID"), w.get("kCGWindowOwnerName")):
            continue
        b = w.get("kCGWindowBounds", {})
        out.append({"id": w.get("kCGWindowNumber"), "owner": w.get("kCGWindowOwnerName", ""),
                    "x": b.get("X", 0), "y": b.get("Y", 0),
                    "w": b.get("Width", 0), "h": b.get("Height", 0)})
    return out


def set_frame(owner, match_w, match_h, x, y, w=None, h=None):
    """Move (and optionally resize) the System Events window whose size matches.

    Matched on the window's CURRENT size, read fresh right before this runs -
    apps resize themselves after mapping (abiword grew 760x552 -> 800x632
    mid-session), so a hardcoded expected size silently matches nothing.

    `owner` is the process that actually owns the window: since each Linux
    app runs in its own macOS process (for its own Dock tile), that is
    "Krita"/"Abiword"/... and no longer always "mslhd".
    """
    resize = ""
    if w and h:
        resize = f'set size of win to {{{int(w)}, {int(h)}}}'
    script = f'''
    tell application "System Events" to tell process "{owner}"
      repeat with win in windows
        set sz to size of win
        if (item 1 of sz) = {int(match_w)} and (item 2 of sz) = {int(match_h)} then
          set position of win to {{{int(x)}, {int(y)}}}
          {resize}
          exit repeat
        end if
      end repeat
    end tell
    '''
    subprocess.run(["osascript", "-e", script], capture_output=True)


# Screen is 1710x1112pt (menu bar owns the top 39). The four apps' natural
# sizes don't tile 2x2 unresized, so each slot below carries an explicit size.
# Slots are filled by AREA RANK (largest first), not by app name or window
# order - CGWindowList order and System Events order disagree, and matching by
# expected pixel size breaks the moment an app resizes itself.
SLOTS = [
    # (x, y, w, h) - rank 0 = largest window
    (855, 575, 845, 525),   # rank 0 (krita)
    (855, 39, 845, 520),    # rank 1 (abiword)
    (0, 575, 845, 525),     # rank 2 (gnome-chess)
    (0, 39, 340, 500),      # rank 3 (galculator, smallest)
]

if __name__ == "__main__":
    wins = sorted(mslgd_windows(), key=lambda d: -(d["w"] * d["h"]))
    for i, w in enumerate(wins):
        print(f"rank{i}: {w['owner']} {w['w']:.0f}x{w['h']:.0f} at ({w['x']:.0f},{w['y']:.0f})")

    for i, w in enumerate(wins[:len(SLOTS)]):
        x, y, tw, th = SLOTS[i]
        # Don't grow a window that's already smaller than its slot (galculator
        # at its own minimum would just get letterboxed); only shrink to fit.
        new_w = tw if w["w"] > tw else None
        new_h = th if w["h"] > th else None
        set_frame(w["owner"], w["w"], w["h"], x, y, new_w, new_h)
    print("tiled")
