#!/usr/bin/env python3
"""Pixel-compares two PNGs for the Layer-0 X11 conformance harness
(Scripts/x11-test.sh). Exit 0 = match, 1 = mismatch, 2 = usage/load error.

A small per-channel tolerance (default 8/255) absorbs font
hinting/antialiasing rounding differences between runs without masking a
real rendering bug - exact-match tests (solid fills, geometric shapes) still
fail on any difference above that.
"""
import sys
from PIL import Image

TOLERANCE = 8

def main():
    if len(sys.argv) != 3:
        print("usage: pngdiff.py <actual.png> <reference.png>", file=sys.stderr)
        return 2
    actual_path, ref_path = sys.argv[1], sys.argv[2]
    try:
        actual = Image.open(actual_path).convert("RGBA")
        ref = Image.open(ref_path).convert("RGBA")
    except Exception as e:
        print(f"pngdiff: couldn't load an image: {e}", file=sys.stderr)
        return 2

    if actual.size != ref.size:
        print(f"pngdiff: size mismatch actual={actual.size} ref={ref.size}", file=sys.stderr)
        return 1

    a = actual.load()
    r = ref.load()
    w, h = actual.size
    worst = 0
    worst_at = None
    mismatches = 0
    for y in range(h):
        for x in range(w):
            pa, pr = a[x, y], r[x, y]
            delta = max(abs(pa[i] - pr[i]) for i in range(4))
            if delta > TOLERANCE:
                mismatches += 1
                if delta > worst:
                    worst = delta
                    worst_at = (x, y, pa, pr)

    if mismatches:
        x, y, pa, pr = worst_at
        print(f"pngdiff: {mismatches} pixels exceed tolerance {TOLERANCE}; "
              f"worst at ({x},{y}) actual={pa} ref={pr} delta={worst}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
