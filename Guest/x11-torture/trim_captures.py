#!/usr/bin/env python3
"""Bundles raw captures into captures/<app>/ for the replay suite.

    python3 trim_captures.py SESSION_DIR... [--max 4000]

Keeps the first N requests of each connection (startup + first frames is
where toolkits exercise the most distinct requests) and gzips them, so a
50 MB Firefox session becomes a few hundred KB in the repo.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xreplay  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("sessions", nargs="+")
ap.add_argument("--max", type=int, default=4000)
ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "captures"))
args = ap.parse_args()
for d in args.sessions:
    app = os.path.basename(d.rstrip("/")).rsplit("-", 1)[0].lower()
    dest = os.path.join(args.out, app)
    os.makedirs(dest, exist_ok=True)
    for n, f in enumerate(xreplay.session_files([d]), 1):
        header, reqs = xreplay.read_capture(f)
        out = os.path.join(dest, "%s-%d.xcap.gz" % (app, n))
        xreplay.write_capture(out, header, reqs[:args.max])
        print("%-40s %6d requests -> %7d bytes" % (os.path.relpath(out), min(len(reqs), args.max), os.path.getsize(out)))
