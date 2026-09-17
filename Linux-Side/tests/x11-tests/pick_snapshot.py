#!/usr/bin/env python3
"""Picks "the" snapshot PNG out of a directory that may hold one per
window (subwindows, a WM shell/content split, or - GTK/Qt both confirmed
live - several small internal utility/helper windows created alongside
the real content one). Prints the chosen path, or nothing (exit 1) if
the directory has no PNGs.

Neither newest-mtime nor largest-file-size alone works: GTK/Qt's own
tiny 1x1-ish helper windows routinely get touched LAST (during
shutdown), so newest-mtime picks those over real content; a big blank/
solid-fill window can compress to MORE bytes than a small window with
real content (confirmed live - a solid-white 200x150 fill took 958
bytes, more than a 283-byte 60x50 window with real color/text in it),
so largest-file-size alone is also unreliable.

Bytes-per-pixel (file size / width / height) is the primary signal
instead - it isolates "how much real visual complexity is packed into
this window" from raw dimensions, confirmed live to reliably separate
real content from blank/near-blank utility windows. Multiple windows can
have genuinely close bytes-per-pixel (e.g. two differently-colored but
similarly-sized real content windows, as in `06_subwindows.c`'s two
children) - among candidates within 15% of the best density, newest
mtime breaks the tie, matching a well-structured test's convention of
doing its final/marker draw last.

A tiny (1x1-ish) window's PNG is almost entirely fixed per-file
overhead (headers/chunks, ~100+ bytes regardless of content), which
inflates its bytes-per-pixel far past any real content window's -
confirmed live this made the density heuristic alone pick GTK/Qt's own
1x1 helper windows over actual 200x100 widget content. Filtering out
anything under `MIN_PIXELS` before ranking avoids that distortion
entirely rather than trying to correct for it.
"""

MIN_PIXELS = 2000  # smaller than any real test window; larger than GTK/Qt's own small (confirmed live up to 10x10) internal helper windows
import sys
import glob
import os

from PIL import Image

def main():
    directory = sys.argv[1]
    paths = glob.glob(os.path.join(directory, "*.png"))
    if not paths:
        return 1

    all_candidates = []
    candidates = []
    for path in paths:
        try:
            with Image.open(path) as im:
                w, h = im.size
        except Exception:
            continue
        size = os.path.getsize(path)
        density = size / max(w * h, 1)
        mtime = os.path.getmtime(path)
        entry = (path, density, mtime)
        all_candidates.append(entry)
        if w * h >= MIN_PIXELS:
            candidates.append(entry)

    # Every PNG was tiny (e.g. a genuinely single-window, small test) -
    # fall back to considering all of them rather than reporting nothing.
    if not candidates:
        candidates = all_candidates
    if not candidates:
        return 1

    best_density = max(c[1] for c in candidates)
    threshold = best_density * 0.85
    finalists = [c for c in candidates if c[1] >= threshold]
    finalists.sort(key=lambda c: c[2], reverse=True)  # newest mtime first
    print(finalists[0][0])
    return 0

if __name__ == "__main__":
    sys.exit(main())
