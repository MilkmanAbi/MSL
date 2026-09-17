#!/usr/bin/env python3
import subprocess, datetime
from pathlib import Path

# Outside the repo: a test run's screenshots are throwaway.
SAVE_DIR   = Path("/tmp/mslgd-screenshots")
SAVE_DIR.mkdir(exist_ok=True)

ts   = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
path = SAVE_DIR / f"screenshot_{ts}.png"

subprocess.run(["screencapture", "-x", str(path)])
print(f"Saved → {path}")
