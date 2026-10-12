#!/bin/bash
# Launch every GUI test app against mslgd AT ONCE, tile them, screenshot, and
# summarize each one's stderr.
#
# Exists because fixing apps one at a time kept trading one regression for
# another ("when i fix krita, gcalc breaks") - a change is only really good if
# all four still render, so validate them together, every time.
#
# Usage:
#   ./test_all_apps.sh              # full cycle: restart mslhd, boot, launch, tile, shoot
#   ./test_all_apps.sh --no-restart # reuse the running mslhd/VM (much faster)
#
# mslhd must be launched from a REAL Terminal.app window (VZVirtualMachine
# hangs when started from an agent/tool shell - see the
# msl_background_job_vm_testing memory note); --restart does that via osascript.

set -uo pipefail
# Resolve to an ABSOLUTE path before any cd - `$0` is relative, so a later
# `cd "$(dirname "$0")"` would resolve against the wrong directory.
ROOT="$(cd "$(dirname "$0")" && pwd)"   # MSL/Scripts
cd "$ROOT/.." || exit 1

PROJDIR="$(pwd)"
MSL=".build/arm64-apple-macosx/release/msl"
APPS=(galculator abiword gnome-chess krita)
LOGDIR=/tmp/mslgd-applogs
SNAPDIR=/tmp/mslgd-snapshots
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

mkdir -p "$LOGDIR"; rm -f "$LOGDIR"/*.log

if [ "$RESTART" = "1" ]; then
    echo "== restarting mslhd =="
    pkill -f "sleep 7200" 2>/dev/null
    pkill -f "\.build/debug/mslhd" 2>/dev/null
    # Per-app host processes too, and their shim binaries/sockets. Each
    # Linux app now runs in its OWN macOS process (that is how it gets its
    # own Dock tile - see gui-bugs.md's process-split section), and a host
    # left over from the previous run would happily keep serving, keep its
    # windows on screen, and keep overwriting snapshots. Stale state from
    # exactly this shape cost real time today: four ghost fixture windows,
    # and Layer-0 tests diffing one program's window against another's
    # reference.
    pkill -f "Library/Caches/MSL/AppShims/" 2>/dev/null
    rm -rf "$HOME/Library/Caches/MSL/AppShims"
    sleep 1
    rm -rf "$SNAPDIR"; mkdir -p "$SNAPDIR"
    CMD="cd ${PROJDIR} && export MSL_X11_SNAPSHOT_DIR=${SNAPDIR} && export MSL_X11_TRACE=1 && .build/debug/mslhd 2>&1 | tee /tmp/mslhd.log"
    osascript -e "tell application \"Terminal\" to do script \"$CMD\"" >/dev/null
    # Wait for the daemon to be answering before asking it to boot a VM.
    for _ in $(seq 1 20); do
        [ "$($MSL status 2>&1)" = "OK stopped" ] && break
        sleep 1
    done
    nohup $MSL -- "sleep 7200" > /tmp/msl-keepalive-multi.log 2>&1 &
    for _ in $(seq 1 40); do
        [ "$($MSL status 2>&1)" = "OK running" ] && break
        sleep 3
    done
fi

echo "== VM: $($MSL status 2>&1) =="
$MSL gui-native default </dev/null > "$LOGDIR/_ensure.log" 2>&1

for app in "${APPS[@]}"; do
    nohup $MSL gui-native default "$app" > "$LOGDIR/${app}.log" 2>&1 &
    echo "   launched $app"
    # 14s, not 3s: a first launch of an app now also copies + ad-hoc-signs a
    # 2.3 MB host binary and waits for that process to bind its handoff
    # socket. Measured 8s to be too tight for krita and abiword - they
    # connected, the host was still coming up, and they exited.
    sleep 14
done

echo "== waiting for windows to settle =="
sleep 20

cd "$ROOT"
python3 tile_windows.py
sleep 2
python3 screenshot.py

echo
echo "══════════ app stderr summary ══════════"
for app in "${APPS[@]}"; do
    n=$(grep -ciE "error|critical|warning|fail|assert" "$LOGDIR/${app}.log" 2>/dev/null || echo 0)
    echo "── $app  ($n warning/error lines)"
    grep -iE "error|critical|warning|fail|assert" "$LOGDIR/${app}.log" 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*m//g' | sed 's/^/     /' | sort -u | head -8
done
