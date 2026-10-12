"""replay: real toolkit sessions, replayed request for request.

captures/<app>/*.xcap.gz were recorded from real apps under mslgd
(MSL_X11_CAPTURE_DIR, see X11Capture.swift, bundled with
trim_captures.py): GTK2 (Sylpheed, xzgv), GTK3 (Mousepad, GIMP, Firefox),
GTK4 (Nautilus, GNOME Chess), Qt5 (Krita), Qt6 (FeatherPad, Qalculate),
Tk (IDLE) and Xt/Xaw/Xmu (xcalc, xterm, xeyes, xlogo). Each replay runs
under its own process name, so it gets a fresh app host just like the app
did, and ids are remapped onto the replay's own range.

PASS = the host survived and every error it answered is one a real server
also gives (captures/baseline.json). A GTK2 app died at startup on one
BadImplementation (XI1 ListInputDevices); Qt apps got BadCursor for every
freed theme cursor. Both would have shown up here as a FAIL.
"""
import json
import os
import subprocess
import tempfile

from xhell import test, Fail, Skip

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURES = os.path.join(HERE, "captures")
NEVER_OK = ("BadImplementation", "BadRequest", "BadLength")


def _baseline():
    try:
        with open(os.path.join(CAPTURES, "baseline.json")) as f:
            return json.load(f)
    except OSError:
        return {}


def _apps():
    if not os.path.isdir(CAPTURES):
        return []
    return sorted(d for d in os.listdir(CAPTURES) if os.path.isdir(os.path.join(CAPTURES, d)))


def _make(app):
    @test("replay", app, 2, doc="replay the recorded %s session" % app)
    def fn(ctx):
        with tempfile.NamedTemporaryFile(suffix=".json") as out:
            cmd = 'exec -a "xreplay-%s" python3 "%s" "%s" --json "%s"' % (
                app, os.path.join(HERE, "xreplay.py"), os.path.join(CAPTURES, app), out.name)
            proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=300)
            try:
                rep = json.load(open(out.name))
            except ValueError:
                raise Fail("replayer produced no report: %s" % (proc.stderr.strip()[-300:] or proc.stdout[-300:]))
        ctx.metric("requests", rep["total"])
        ctx.metric("seconds", rep["seconds"], "s")
        if rep["outcome"] != "ok":
            raise Fail("%s: %s" % (rep["outcome"], rep["detail"]))
        base = _baseline()
        allowed = set(base.get("*", {})) | set(base.get(app, {}))
        bad = ["%s (x%d)" % (k, v["count"]) for k, v in sorted(rep["errors"].items())
               if k not in allowed or k.endswith(NEVER_OK)]
        if bad:
            raise Fail("unexpected errors: " + "; ".join(bad))
    return fn


for _app in _apps():
    _make(_app)
if not _apps():
    @test("replay", "captures-present", 2)
    def _none(ctx):
        raise Skip("no captures/ directory")
