#!/usr/bin/env python3
"""xhell - mslgd's conformance, robustness and stress suite.

    python3 xhell.py                 # normal run (levels 1-2)
    python3 xhell.py --level 3       # everything, including the very slow
    python3 xhell.py -k draw         # only tests whose id contains "draw"
    python3 xhell.py --list
    python3 xhell.py --fuzz 20000 --seed 7

Every test gets its own connection. Outcomes:
  PASS   did what the protocol says
  FAIL   wrong answer (wrong pixels, wrong error code, wrong reply)
  ERROR  an X error the test did not expect
  CRASH  the server dropped the connection
  HANG   the server stopped answering
  DOWN   the test passed or failed, but a NEW connection afterwards could
         not complete a round trip - the host behind the display died
  SKIP   precondition missing (extension not advertised, etc.)

Results go to results/latest.json (previous run kept as results/previous.json)
and the summary lists what changed since last time.
"""
import argparse
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import xwire  # noqa: E402

TESTS = []


class Skip(Exception):
    pass


class Fail(Exception):
    pass


def test(suite, name, level=1, doc=None):
    """Registers a test. level 1 = fast core checks, 2 = normal, 3 = hell."""
    def deco(fn):
        TESTS.append({"id": "%s.%s" % (suite, name), "suite": suite, "fn": fn, "level": level,
                      "doc": (doc or fn.__doc__ or "").strip().split("\n")[0]})
        return fn
    return deco


class Ctx:
    def __init__(self, args):
        self.args = args
        self.conns = []
        self.metrics = {}
        self.notes = []
        self.allow_disconnect = False

    def conn(self, **kw):
        kw.setdefault("timeout", self.args.timeout)
        c = xwire.Conn(**kw)
        self.conns.append(c)
        return c

    def expect(self, cond, msg):
        if not cond:
            raise Fail(msg)

    def expect_error(self, conn, code_name, what):
        errs = conn.sync()
        names = [e.name for e in errs]
        if code_name not in names:
            raise Fail("%s: expected %s, got %s" % (what, code_name, names or "no error"))

    def expect_no_errors(self, conn, what):
        errs = conn.sync()
        if errs:
            raise Fail("%s: unexpected %s" % (what, errs[:4]))

    def metric(self, name, value, unit=""):
        self.metrics[name] = (round(value, 3) if isinstance(value, float) else value, unit)

    def note(self, msg):
        self.notes.append(msg)

    def skip(self, msg):
        raise Skip(msg)

    def close(self):
        for c in self.conns:
            c.close()


def server_alive(timeout):
    try:
        c = xwire.Conn(timeout=timeout)
        c.sync()
        c.close()
        return True
    except Exception:
        return False


C = {"PASS": "\033[32m", "FAIL": "\033[31m", "ERROR": "\033[35m", "CRASH": "\033[1;31m",
     "HANG": "\033[1;33m", "DOWN": "\033[1;41;97m", "SKIP": "\033[90m"}
RESET = "\033[0m"


def run_one(t, args):
    ctx = Ctx(args)
    start = time.monotonic()
    status, detail = "PASS", ""
    try:
        t["fn"](ctx)
    except Skip as e:
        status, detail = "SKIP", str(e)
    except Fail as e:
        status, detail = "FAIL", str(e)
    except xwire.XError as e:
        status, detail = "ERROR", repr(e.err)
    except xwire.Died as e:
        if ctx.allow_disconnect:
            status = "PASS"
        else:
            status, detail = "CRASH", str(e)
            last = [c.history[-3:] for c in ctx.conns if c.dead]
            if last and last[0]:
                detail += " | last requests: " + ", ".join(
                    "#%d %s" % (s, p[:12].hex()) for s, p in last[0])
    except xwire.Hang as e:
        status, detail = "HANG", str(e)
    except Exception as e:
        status, detail = "FAIL", "test bug: %s: %s" % (type(e).__name__, e)
        if args.verbose:
            traceback.print_exc()
    finally:
        ctx.close()
    elapsed = time.monotonic() - start
    if status not in ("SKIP",) and not server_alive(min(args.timeout, 8)):
        detail = "%s -> server not answering afterwards" % (status + (": " + detail if detail else ""))
        status = "DOWN"
        # Give a restarted host a moment before the next test.
        for _ in range(20):
            time.sleep(0.5)
            if server_alive(3):
                break
    return {"id": t["id"], "status": status, "detail": detail, "ms": round(elapsed * 1000),
            "metrics": ctx.metrics, "notes": ctx.notes}


def load_suites():
    # Run as a script this module is __main__; the suites import `xhell`,
    # which would otherwise load a second copy with its own empty registry.
    sys.modules.setdefault("xhell", sys.modules[__name__])
    for name in sorted(os.listdir(os.path.join(HERE, "suites"))):
        if name.startswith("s_") and name.endswith(".py"):
            __import__("suites." + name[:-3])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--level", type=int, default=2)
    ap.add_argument("-k", default="", help="substring filter on test id")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--fuzz", type=int, default=3000, help="fuzz iterations")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--results", default=os.path.join(HERE, "results"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    load_suites()
    chosen = [t for t in TESTS if t["level"] <= args.level and args.k in t["id"]]
    if args.list:
        for t in chosen:
            print("%-44s L%d  %s" % (t["id"], t["level"], t["doc"]))
        print("%d tests" % len(chosen))
        return

    if not server_alive(10):
        sys.exit("no X server answering at %s" % xwire.default_socket_path())

    print("xhell: %d tests, level %d, seed %d\n" % (len(chosen), args.level, args.seed))
    results = []
    for t in chosen:
        r = run_one(t, args)
        results.append(r)
        m = " ".join("%s=%s%s" % (k, v[0], v[1]) for k, v in r["metrics"].items())
        line = "%s%-6s%s %-44s %6dms  %s" % (C.get(r["status"], ""), r["status"], RESET, r["id"],
                                             r["ms"], r["detail"] or m)
        print(line[:300])
        for n in r["notes"]:
            print("         note: %s" % n[:250])
        sys.stdout.flush()

    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print("\n" + "  ".join("%s%s %d%s" % (C.get(k, ""), k, v, RESET) for k, v in sorted(counts.items())))

    os.makedirs(args.results, exist_ok=True)
    latest = os.path.join(args.results, "latest.json")
    previous = os.path.join(args.results, "previous.json")
    old = {}
    if os.path.exists(latest):
        os.replace(latest, previous)
        try:
            old = {r["id"]: r["status"] for r in json.load(open(previous))["results"]}
        except Exception:
            old = {}
    json.dump({"when": time.strftime("%Y-%m-%d %H:%M:%S"), "level": args.level, "seed": args.seed,
               "results": results}, open(latest, "w"), indent=1)
    if old:
        changed = [(r["id"], old[r["id"]], r["status"]) for r in results
                   if r["id"] in old and old[r["id"]] != r["status"]]
        if changed:
            print("\nchanged since last run:")
            for tid, a, b in changed:
                print("  %-44s %s -> %s" % (tid, a, b))
        else:
            print("\nno changes since last run")
    bad = sum(v for k, v in counts.items() if k in ("CRASH", "HANG", "DOWN"))
    sys.exit(2 if bad else (1 if counts.get("FAIL") or counts.get("ERROR") else 0))


if __name__ == "__main__":
    main()
