#!/usr/bin/env python3
"""xreplay - replay a real app's recorded X session against the server.

    exec -a xreplay-nautilus python3 xreplay.py SESSION_DIR_OR_FILES... [--max N] [--json OUT]

Captures come from mslgd's `MSL_X11_CAPTURE_DIR` (see X11Capture.swift):
one .xcap file per connection. Every connection of one app session is
replayed in order, each on its own connection, all from one process - so
they land in ONE fresh app host, as the original did, and atom numbering
lines up with the original session.

Resource ids are remapped: any 32-bit word in a request whose high bits
match the recorded client's id base is moved onto this client's base
(the root, base|mask, maps onto this client's root the same way).

What it reports, per (major, minor): how many were sent, and every error
the server answered - which is the point. A GTK2 app died at startup on a
single BadImplementation; a replay shows every such answer at once,
without the app's error handler cutting the session short.
"""
import argparse
import gzip
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xwire  # noqa: E402

EXT_NAMES = {150: "RENDER", 151: "BIG-REQUESTS", 152: "XInput", 153: "XKB", 154: "RANDR",
             155: "XC-MISC", 156: "SHAPE", 157: "XTEST", 158: "MIT-SCREEN-SAVER"}


def read_capture(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as f:
        data = f.read()
    magic, rest = data.split(b"\n", 1)
    if magic != b"XCAP1":
        raise ValueError("%s: not an xcap file" % path)
    header_line, rest = rest.split(b"\n", 1)
    header = json.loads(header_line)
    reqs = []
    off = 0
    while off + 4 <= len(rest):
        n = struct.unpack_from("<I", rest, off)[0]
        reqs.append(rest[off + 4:off + 4 + n])
        off += 4 + n
    return header, reqs


def session_files(paths):
    """Expands directories; orders files by their connection counter."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += [os.path.join(p, f) for f in os.listdir(p) if f.endswith((".xcap", ".xcap.gz"))]
        else:
            files.append(p)
    return sorted(files, key=lambda f: int(os.path.basename(f).rsplit("-", 1)[1].split(".")[0]))


def write_capture(path, header, reqs):
    """The inverse of read_capture (gzipped when the name says so)."""
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "wb") as f:
        f.write(b"XCAP1\n" + json.dumps(header, sort_keys=True).encode() + b"\n")
        for q in reqs:
            f.write(struct.pack("<I", len(q)) + q)


def remap(req, old_base, new_base, mask, big):
    """Moves ids from the recorded client's range onto ours."""
    start = 8 if big else 4
    b = bytearray(req)
    hi = ~mask & 0xFFFFFFFF
    for off in range(start, len(b) - 3, 4):
        v = struct.unpack_from("<I", b, off)[0]
        if v and (v & hi) == old_base:
            struct.pack_into("<I", b, off, new_base | (v & mask))
    return bytes(b)


def key_of(req):
    major = req[0]
    minor = req[1] if major >= 128 else None
    return major, minor


def label(major, minor):
    if minor is None:
        return "core %d" % major
    return "%s %d" % (EXT_NAMES.get(major, "ext%d" % major), minor)


def replay(files, max_requests, timeout):
    report = {"connections": [], "sent": {}, "errors": {}, "outcome": "ok", "detail": ""}
    t0 = time.monotonic()
    total = 0
    for path in files:
        header, reqs = read_capture(path)
        if header.get("byteOrder", "l") != "l":
            report["connections"].append({"file": os.path.basename(path), "skipped": "MSB capture"})
            continue
        c = xwire.Conn(timeout=timeout)
        old_base, mask = header["base"], header["mask"]
        seq_to_index = {}
        conn_errors = 0
        try:
            for i, req in enumerate(reqs[:max_requests]):
                big = req[2] == 0 and req[3] == 0 and len(req) >= 8
                data = remap(req, old_base, c.id_base, mask, big)
                if req[0] == 151:              # BIG-REQUESTS Enable: our client must know too
                    c.big_requests = True
                seq = c.raw(data)
                seq_to_index[seq] = i
                k = label(*key_of(req))
                report["sent"][k] = report["sent"].get(k, 0) + 1
                total += 1
                if i % 250 == 249:
                    for e in c.sync():
                        conn_errors += 1
                        _note_error(report, e, seq_to_index, reqs)
                    c.replies.clear()
                    c.events.clear()
            for e in c.sync():
                conn_errors += 1
                _note_error(report, e, seq_to_index, reqs)
        except xwire.Died as e:
            report["outcome"], report["detail"] = "died", "%s after %d requests of %s" % (e, i, os.path.basename(path))
        except xwire.Hang as e:
            report["outcome"], report["detail"] = "hang", "%s after %d requests of %s" % (e, i, os.path.basename(path))
        finally:
            c.close()
        report["connections"].append({"file": os.path.basename(path), "requests": min(len(reqs), max_requests),
                                      "errors": conn_errors})
        if report["outcome"] != "ok":
            break
    report["total"] = total
    report["seconds"] = round(time.monotonic() - t0, 2)
    return report


def _note_error(report, e, seq_to_index, reqs):
    idx = seq_to_index.get(e.seq)
    if idx is not None:
        major, minor = key_of(reqs[idx])
        where = label(major, minor)
    else:
        where = "major %d minor %d (unmapped)" % (e.major, e.minor)
    k = "%s -> %s" % (where, e.name)
    slot = report["errors"].setdefault(k, {"count": 0, "first_index": idx})
    slot["count"] += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--max", type=int, default=40000)
    ap.add_argument("--timeout", type=float, default=15)
    ap.add_argument("--json")
    args = ap.parse_args()
    rep = replay(session_files(args.paths), args.max, args.timeout)
    if args.json:
        json.dump(rep, open(args.json, "w"), indent=1)
    print("outcome=%s total=%d seconds=%s %s" % (rep["outcome"], rep["total"], rep["seconds"], rep["detail"]))
    for k, v in sorted(rep["errors"].items(), key=lambda kv: -kv[1]["count"]):
        print("  %5d  %s" % (v["count"], k))


if __name__ == "__main__":
    main()
