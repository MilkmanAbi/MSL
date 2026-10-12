#!/bin/bash
# Layer-0 Wayland (cage) conformance harness - the wayland-tests
# equivalent of Scripts/x11-test.sh. See cage-planning.md for the
# overall plan this implements Phase 1/2 of.
#
# Unlike x11-tests (a real X11 server this project itself wrote,
# receiving requests directly), cage/wlroots run ENTIRELY inside the
# guest - this script never talks to mslgd at all. It: compiles a
# minimal raw-Wayland test client, launches `cage` on wlroots'
# HEADLESS backend (no DRM/KMS, no GPU - the pixman software renderer,
# confirmed working in this exact Alpine guest), backgrounds it,
# captures a frame via `grim` (wlr-screencopy protocol) once the client
# has had time to render, pulls the PNG across the SAME guest<->host
# virtiofs share x11-test.sh already uses, and pixel-diffs it against a
# checked-in reference (reusing x11-tests/pngdiff.py verbatim - same
# tolerance-8 policy, same exit-code contract).
#
# Requires: mslhd already running with a booted `default` instance (see
# x11-test.sh's own header comment for the "why real Terminal.app"
# background). Does NOT require MSL_X11_SNAPSHOT_DIR - that's mslgd's
# own mechanism, irrelevant here.
#
# IMPORTANT gotcha this harness works around, worth reading if it ever
# starts failing with "grim capture failed"/cage just not being there
# a moment after it was launched: `mslhd`'s `DaemonServer` has a
# deliberate, documented "WSL-like" idle-suspend feature (see its own
# `sessionEnded`/`suspendDebounce`, 3 SECONDS) - once the last `msl --`
# session to an instance closes, it schedules `suspendLight()` (a real
# `VZVirtualMachine.pause()`) 3 seconds later unless a NEW session
# starts first. Every single `msl -- "cmd"` call is its OWN session
# that closes the instant the command returns - a harness that issues
# several SEPARATE `msl --` calls (compile, launch, capture, ...) with
# more than ~3s between any two of them will get the guest OS itself
# paused mid-test, which reliably looks EXACTLY like "the backgrounded
# process silently died for no reason" (confirmed the hard way: spent a
# long stretch suspecting SIGHUP/session/pty semantics before finding
# the real cause was this timer, not signal delivery at all). Fixed by
# holding one long-lived `msl -- "sleep $KEEPALIVE_SECS"` session open
# in the HOST-side background for this whole script's duration - an
# open session counts as "active" the entire time it's connected, so
# the idle timer never fires while it's up, regardless of gaps between
# this script's own separate `$MSL` calls.
#
# Usage: Scripts/cage-test.sh <test-name> [<test-name> ...]
# With no arguments, runs every *.c file in wayland-tests/.
# First run for a new test saves the actual output as the reference and
# reports REF, not PASS - review it once by hand (same convention as
# x11-test.sh).

set -uo pipefail
cd "$(dirname "$0")/.."

MSL=".build/debug/msl"
INSTANCE="${MSL_TEST_INSTANCE:-default}"
TEST_DIR="Guest/init/wayland-tests"
REF_DIR="$TEST_DIR/references"
GUEST_REPO="/mnt/mac/${PWD#"$HOME"/}"
XDG_RUNTIME="/tmp/xdg-runtime"
KEEPALIVE_SECS=1800

pass=0
fail=0
keepalive_pid=""

cleanup() {
    [ -n "$keepalive_pid" ] && kill "$keepalive_pid" 2>/dev/null
}
trap cleanup EXIT

start_keepalive() {
    "$MSL" -- "sleep $KEEPALIVE_SECS" </dev/null >/dev/null 2>&1 &
    keepalive_pid=$!
    # Give the guest session a moment to actually establish before any
    # real test work starts racing it.
    sleep 0.3
}

# Idempotent - `apk add` no-ops instantly for anything already present.
# Same reasoning as x11-test.sh's own `ensure_display`: a fresh
# `mslhd`/VM boot doesn't persist mid-session installs.
ensure_packages() {
    "$MSL" -- "apk add --no-cache cage wlroots0.20 wlroots0.20-dev wayland-dev wayland-protocols libxkbcommon-dev grim wtype gcc musl-dev" \
        </dev/null >/tmp/cage-test-ensure.log 2>&1
}

# `xdg-shell-client-protocol.h`/`.c` aren't shipped prebuilt - every
# real Wayland client using the (near-universal) xdg-shell protocol
# generates its own glue from the XML spec via `wayland-scanner`,
# same as this project's own X11 side never needed (the X11 CORE
# protocol has no equivalent extension-XML step). Generated fresh each
# run into /tmp - cheap, and avoids a stale-cache class of bug entirely.
generate_xdg_shell_glue() {
    local xml="/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
    "$MSL" -- "wayland-scanner client-header $xml /tmp/xdg-shell-client-protocol.h && wayland-scanner private-code $xml /tmp/xdg-shell-protocol.c" \
        </dev/null >>/tmp/cage-test-ensure.log 2>&1
}

run_test() {
    local name="$1"
    local src="$TEST_DIR/${name}.c"
    local ref="$REF_DIR/${name}.png"
    local guest_src="$GUEST_REPO/$src"
    local build_log="/tmp/cagetest_${name}.build.log"
    local run_log="/tmp/cagetest_${name}.run.log"

    if [ ! -f "$src" ]; then
        echo "FAIL $name (no such test: $src)"
        fail=$((fail + 1)); return
    fi

    if ! "$MSL" -- "mkdir -p $XDG_RUNTIME && chmod 700 $XDG_RUNTIME && \
        gcc -O2 -Wall -I/tmp -I/usr/include -o /tmp/cagetest_${name} \
        '$guest_src' /tmp/xdg-shell-protocol.c -lwayland-client" \
        </dev/null >"$build_log" 2>&1; then
        echo "FAIL $name (compile error - see $build_log)"
        fail=$((fail + 1)); return
    fi

    # `cage` always names its OWN compositor socket "wayland-0" (the
    # wlroots/wayland-server default) regardless of any WAYLAND_DISPLAY
    # value it happens to inherit - that env var is a CLIENT-side
    # "which display to connect to" hint, not something a compositor
    # honors for its own listening socket name (confirmed live: set it
    # to a custom name, cage's own debug log still announced "running
    # on Wayland display wayland-0"). So: no custom display name, just
    # make sure nothing else is still holding wayland-0 first.
    #
    # Launch + settle + capture + cleanup all happen inside ONE guest
    # shell script, in ONE `msl --` session, rather than as separate
    # `$MSL` calls with a HOST-side `sleep` between them. Confirmed the
    # hard way that splitting it doesn't work: even with `setsid` +
    # `disown` + the keepalive session above (ruling out the idle-
    # suspend timer), a background process launched in one `msl --`
    # session was reliably gone by the time a SEPARATE, later `msl --`
    # session checked on it - but the exact same process survived fully
    # (verified via an internal watcher polling every 0.25s) when
    # checked from WITHIN its own single continuous session instead.
    # Never fully root-caused which specific mechanism kills it across
    # a session boundary (not `SIGHUP` in the usual sense - `setsid`
    # alone should be immune to that); the actually-important, confirmed
    # fact is that "one session, start to finish" reliably works and
    # "spans multiple sessions" reliably doesn't, so the harness is
    # built around the one guaranteed-safe shape rather than the
    # mechanism being fully explained.
    rm -f "$TEST_DIR/.captured_${name}.png"
    "$MSL" -- "pkill -9 cage 2>/dev/null; rm -f $XDG_RUNTIME/wayland-0*; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME \
        WLR_BACKENDS=headless WLR_RENDERER=pixman \
        cage -D -- /tmp/cagetest_${name} >$run_log 2>&1 & \
        CAGEPID=\$!; \
        sleep 1.5; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME grim /tmp/cagetest_${name}.png >>$run_log 2>&1; \
        GRIMEXIT=\$?; \
        cp /tmp/cagetest_${name}.png '$GUEST_REPO/$TEST_DIR/.captured_${name}.png' 2>>$run_log; \
        kill \$CAGEPID 2>/dev/null; \
        exit \$GRIMEXIT" \
        </dev/null >/dev/null 2>&1
    local session_exit=$?

    local captured="$TEST_DIR/.captured_${name}.png"
    if [ $session_exit -ne 0 ] || [ ! -f "$captured" ]; then
        echo "FAIL $name (grim capture failed - see $run_log)"
        fail=$((fail + 1)); return
    fi

    if [ ! -f "$ref" ]; then
        mkdir -p "$REF_DIR"
        cp "$captured" "$ref"
        rm -f "$captured"
        echo "REF  $name (saved new reference at $ref - review it, then re-run)"
        return
    fi

    if python3 "Guest/init/x11-tests/pngdiff.py" "$captured" "$ref"; then
        echo "PASS $name"
        pass=$((pass + 1))
        rm -f "$captured"
    else
        local actual_copy="/tmp/cagetest_${name}.actual.png"
        cp "$captured" "$actual_copy"
        rm -f "$captured"
        echo "FAIL $name (pixel mismatch - actual saved to $actual_copy)"
        fail=$((fail + 1))
    fi
}

# Phase 2 of cage-planning.md ("a synthetic click/keypress delivered
# into cage's headless session, confirmed via a changed frame") - a
# distinct shape from `run_test` above (needs a BEFORE capture, a real
# synthetic keypress injected mid-session via `wtype` - the
# `zwp_virtual_keyboard_manager_v1` protocol, cage/wlroots' own
# equivalent of XTEST - and an AFTER capture), so it gets its own
# function rather than overgeneralizing `run_test` for one test.
# `02_input_roundtrip.c` itself renders solid BLACK until a real
# `wl_keyboard` `key` event arrives, then solid WHITE - so a real
# color change between the two captures IS the round-trip proof, not
# just "some diff happened somewhere."
run_input_test() {
    local name="02_input_roundtrip"
    local src="$TEST_DIR/${name}.c"
    local before_ref="$REF_DIR/${name}_before.png"
    local after_ref="$REF_DIR/${name}_after.png"
    local guest_src="$GUEST_REPO/$src"
    local build_log="/tmp/cagetest_${name}.build.log"
    local run_log="/tmp/cagetest_${name}.run.log"

    if [ ! -f "$src" ]; then
        echo "FAIL $name (no such test: $src)"
        fail=$((fail + 1)); return
    fi

    if ! "$MSL" -- "mkdir -p $XDG_RUNTIME && chmod 700 $XDG_RUNTIME && \
        gcc -O2 -Wall -I/tmp -I/usr/include -o /tmp/cagetest_${name} \
        '$guest_src' /tmp/xdg-shell-protocol.c -lwayland-client" \
        </dev/null >"$build_log" 2>&1; then
        echo "FAIL $name (compile error - see $build_log)"
        fail=$((fail + 1)); return
    fi

    rm -f "$TEST_DIR/.captured_${name}_before.png" "$TEST_DIR/.captured_${name}_after.png"
    "$MSL" -- "pkill -9 cage 2>/dev/null; rm -f $XDG_RUNTIME/wayland-0*; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME \
        WLR_BACKENDS=headless WLR_RENDERER=pixman \
        cage -D -- /tmp/cagetest_${name} >$run_log 2>&1 & \
        CAGEPID=\$!; \
        sleep 1.5; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME grim /tmp/cagetest_${name}_before.png >>$run_log 2>&1; \
        BEFOREEXIT=\$?; \
        cp /tmp/cagetest_${name}_before.png '$GUEST_REPO/$TEST_DIR/.captured_${name}_before.png' 2>>$run_log; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME wtype a >>$run_log 2>&1; \
        sleep 1; \
        WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=$XDG_RUNTIME grim /tmp/cagetest_${name}_after.png >>$run_log 2>&1; \
        AFTEREXIT=\$?; \
        cp /tmp/cagetest_${name}_after.png '$GUEST_REPO/$TEST_DIR/.captured_${name}_after.png' 2>>$run_log; \
        kill \$CAGEPID 2>/dev/null; \
        [ \$BEFOREEXIT -eq 0 ] && [ \$AFTEREXIT -eq 0 ]" \
        </dev/null >/dev/null 2>&1
    local session_exit=$?

    local before="$TEST_DIR/.captured_${name}_before.png"
    local after="$TEST_DIR/.captured_${name}_after.png"
    if [ $session_exit -ne 0 ] || [ ! -f "$before" ] || [ ! -f "$after" ]; then
        echo "FAIL $name (capture failed - see $run_log)"
        fail=$((fail + 1)); return
    fi

    if [ ! -f "$before_ref" ] || [ ! -f "$after_ref" ]; then
        mkdir -p "$REF_DIR"
        cp "$before" "$before_ref"
        cp "$after" "$after_ref"
        rm -f "$before" "$after"
        echo "REF  $name (saved new before/after references - review them, then re-run)"
        return
    fi

    local ok=1
    if ! python3 "Guest/init/x11-tests/pngdiff.py" "$before" "$before_ref"; then
        echo "FAIL $name (BEFORE frame doesn't match reference)"
        ok=0
    fi
    if ! python3 "Guest/init/x11-tests/pngdiff.py" "$after" "$after_ref"; then
        echo "FAIL $name (AFTER frame doesn't match reference)"
        ok=0
    fi
    # The actual round-trip proof, independent of the reference PNGs:
    # the injected keypress must have visibly changed something. A
    # pngdiff PASS here (same-image) would mean the key never landed.
    if python3 "Guest/init/x11-tests/pngdiff.py" "$before" "$after" >/dev/null 2>&1; then
        echo "FAIL $name (before/after frames are identical - synthetic keypress had no effect)"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        echo "PASS $name"
        pass=$((pass + 1))
        rm -f "$before" "$after"
    else
        cp "$before" "/tmp/cagetest_${name}_before.actual.png"
        cp "$after" "/tmp/cagetest_${name}_after.actual.png"
        rm -f "$before" "$after"
        fail=$((fail + 1))
    fi
}

start_keepalive
ensure_packages
generate_xdg_shell_glue

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
    for f in "$TEST_DIR"/*.c; do
        [ -e "$f" ] || continue
        name="$(basename "${f%.*}")"
        # 03_screencopy_loop.c, cagebridge.c and cageinput.c (Phase 3 of
        # cage-planning.md) aren't grim-capture-diff shaped - the first
        # streams frames in-process via zwlr_screencopy_manager_v1 (no
        # PNG output at all), the second streams them over a live vsock
        # connection to the host's CageBridge, and the third reads
        # synthetic input commands from the host's CageInputBridge - none
        # of which a host-side grim-capture-diff script can drive alone.
        # All three are validated by their own ad-hoc harnesses instead
        # (see cage-planning.md's STATUS section) - skip them here rather
        # than have this generic sweep report a misleading FAIL.
        [ "$name" = "03_screencopy_loop" ] && continue
        [ "$name" = "cagebridge" ] && continue
        [ "$name" = "cageinput" ] && continue
        # vgem_master_shim.c (OpenGL investigation) is an LD_PRELOAD
        # shared-library shim, not a Wayland client at all - a
        # completely different build shape (gcc -shared -fPIC) this
        # generic sweep has no way to drive meaningfully.
        [ "$name" = "vgem_master_shim" ] && continue
        tests+=("$name")
    done
fi

for t in "${tests[@]}"; do
    if [ "$t" = "02_input_roundtrip" ]; then
        run_input_test
    else
        run_test "$t"
    fi
done

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
