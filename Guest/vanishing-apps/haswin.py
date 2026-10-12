#!/usr/bin/env python3
"""Exit 0 when a GIMP-sized mslgd window is on screen. Errors go to stderr
so the hunt log shows WHY, instead of silently looping forever."""
import sys
sys.path.insert(0, "/Users/abinaash/Desktop/MSL-Project")
try:
    import input_sim
    w = [x for x in input_sim.mslgd_windows() if x["w"] > 200 and x["h"] > 150]
    if w:
        print(f"{w[0]['owner']} {w[0]['w']:.0f}x{w[0]['h']:.0f}")
        sys.exit(0)
    sys.exit(1)
except Exception as e:
    print(f"haswin failed: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(2)
