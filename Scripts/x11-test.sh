#!/bin/bash
# Layer-0 X11 conformance harness. Compiles a plain-Xlib C test program in
# the guest, runs it against mslgd, and pixel-diffs the window it drew
# against a checked-in reference PNG - no screenshot, no gdb, no manual
# eyeballing.
#
# Requires: mslhd running with MSL_X11_SNAPSHOT_DIR set in ITS OWN
# environment to $SNAPSHOT_DIR below (the server reads that var once,
# lazily, on first paint). With the LaunchAgent-managed daemon:
#   launchctl setenv MSL_X11_SNAPSHOT_DIR /tmp/mslgd-snapshots
#   launchctl kickstart -k gui/$(id -u)/com.msl.mslhd
# (`launchctl unsetenv` and another kickstart turn it off again.)
#
# Usage: Scripts/x11-test.sh <test-name> [<test-name> ...]
#   e.g.: Scripts/x11-test.sh 01_window_lifecycle
# With no arguments, runs every test in $TEST_DIR (below).
# First run for a new test (no reference PNG yet) saves the actual output
# as the reference and reports REF, not PASS - review it once by hand.
#
#   MSL_TEST_INSTANCE=debian   which instance to test (default: default)
#   X11_TEST_DIR=Guest/init/cairo-tests   a different layer, e.g. gtk-tests
#   MSL_BIN=path/to/msl        which msl to drive
#
# Each layer compiles with whatever `pkg-config` package list PKG_LIST
# (below) maps its directory to - real flags/libs straight from the
# guest's own installed dev packages, not hand-guessed -I/-l flags.

set -uo pipefail
cd "$(dirname "$0")/.."

MSL="${MSL_BIN:-.build/arm64-apple-macosx/release/msl}"
INSTANCE="${MSL_TEST_INSTANCE:-default}"
TEST_DIR="${X11_TEST_DIR:-Guest/init/x11-tests}"
REF_DIR="$TEST_DIR/references"
case "$TEST_DIR" in
    *qt-tests)    PKG_LIST="Qt5Widgets" ;;
    *gtk-tests)   PKG_LIST="gtk+-3.0" ;;
    *cairo-tests) PKG_LIST="x11 xrender cairo" ;;
    *)            PKG_LIST="x11 xrender xrandr xext" ;;
esac
SNAPSHOT_DIR="${MSL_X11_SNAPSHOT_DIR:-/tmp/mslgd-snapshots}"
# Path to this repo as seen through the guest's virtiofs share of $HOME.
GUEST_REPO="/mnt/mac/${PWD#"$HOME"/}"

pass=0
fail=0
results=()

# msl's stdin has to stay open for the length of a command - an immediate
# EOF (`</dev/null`) can tear the session down before the output arrives. A
# FIFO held open by a background sleep does that without blocking.
STDIN_FIFO=$(mktemp -u "${TMPDIR:-/tmp}/x11-test.XXXXXX")
mkfifo "$STDIN_FIFO"
sleep 86400 > "$STDIN_FIFO" &
STDIN_HOLDER=$!
trap 'kill $STDIN_HOLDER 2>/dev/null; rm -f "$STDIN_FIFO"' EXIT

# As root: installing dev packages needs it, and an instance whose distro
# has a user account would otherwise run these as that user.
guest() { "$MSL" "$INSTANCE" -u root "$1" < "$STDIN_FIFO"; }

ensure_display() {
    "$MSL" gui-native "$INSTANCE" < "$STDIN_FIFO" >/tmp/x11-test-ensure-display.log 2>&1
    # The dev packages the layers compile against. Idempotent in every
    # package manager here, so it simply runs each time. Whichever manager
    # the guest has decides the spelling.
    guest '
    if command -v apk >/dev/null; then
        apk add --no-cache libx11-dev libxrender-dev libxrandr-dev libxext-dev cairo-dev gtk+3.0-dev qt5-qtbase-dev g++ pkgconf
    elif command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libx11-dev libxrender-dev libxrandr-dev libxext-dev libcairo2-dev libgtk-3-dev qtbase5-dev g++ pkg-config
    elif command -v dnf >/dev/null; then
        dnf install -y -q libX11-devel libXrender-devel libXrandr-devel libXext-devel cairo-devel gtk3-devel qt5-qtbase-devel gcc-c++ pkgconf-pkg-config
    elif command -v pacman >/dev/null; then
        pacman -S --noconfirm --needed libx11 libxrender libxrandr libxext cairo gtk3 qt5-base pkgconf
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install libX11-devel libXrender-devel libXrandr-devel libXext-devel cairo-devel gtk3-devel libqt5-qtbase-devel gcc-c++ pkg-config
    fi' >>/tmp/x11-test-ensure-display.log 2>&1
}

# Qt widgets are C++ (QApplication/QWidget/QPainter); everything else is
# plain C. `qt-tests/*.cpp` + `g++` for that layer, `*.c` + `gcc`
# everywhere else - a MOC-free plain-virtual-method style Qt test (no
# Q_OBJECT/signals/slots) never needs Qt's meta-object compiler at all.
case "$TEST_DIR" in
    *qt-tests) SRC_EXT="cpp"; CC="g++" ;;
    *)         SRC_EXT="c";   CC="gcc" ;;
esac

run_test() {
    local name="$1"
    local src="$TEST_DIR/${name}.${SRC_EXT}"
    local ref="$REF_DIR/${name}.png"
    local guest_src="$GUEST_REPO/$src"
    local build_log="/tmp/xtest_${name}.build.log"
    local run_log="/tmp/xtest_${name}.run.log"

    if [ ! -f "$src" ]; then
        echo "FAIL $name (no such test: $src)"
        results+=("FAIL $name"); fail=$((fail + 1)); return
    fi

    rm -f "$SNAPSHOT_DIR"/*.png 2>/dev/null

    if ! guest "$CC -O2 -Wall \$(pkg-config --cflags $PKG_LIST) -o /tmp/xtest_${name} '$guest_src' \$(pkg-config --libs $PKG_LIST)" \
        >"$build_log" 2>&1; then
        echo "FAIL $name (compile error - see $build_log)"
        results+=("FAIL $name"); fail=$((fail + 1)); return
    fi

    guest "DISPLAY=:1 timeout 5 /tmp/xtest_${name}" >"$run_log" 2>&1
    local run_exit=$?

    # The guest command above already blocked until the test process itself
    # exited, so every snapshot write the test will ever produce has
    # already happened by now - the loop below is just settling margin
    # for the SERVER's own async (main-thread-dispatched) draw handlers to
    # finish flushing to disk, not a wait for "the right window."
    #
    # A test with more than one window (subwindows, a WM shell/content
    # split, or - GTK/Qt both confirmed live - several small internal
    # utility/helper windows created alongside the real content one)
    # writes ONE PNG per window ID, all coexisting in `$SNAPSHOT_DIR` -
    # see `pick_snapshot.py`'s own doc comment for why picking "the"
    # right one needs more than `ls`'s alphabetical order, newest-mtime,
    # or largest-file-size alone (all tried first, all confirmed
    # unreliable in different ways).
    pick_snapshot() { python3 "Guest/init/x11-tests/pick_snapshot.py" "$SNAPSHOT_DIR"; }
    local png=""
    for _ in $(seq 1 30); do
        png=$(pick_snapshot)
        [ -n "$png" ] && break
        sleep 0.2
    done
    if [ -z "$png" ]; then
        echo "FAIL $name (no snapshot produced, guest exit=$run_exit - see $run_log)"
        results+=("FAIL $name"); fail=$((fail + 1)); return
    fi

    # Settle: re-pick and wait until ITS size stops changing (mslgd
    # overwrites a window's own file on every paint to it; a test may
    # paint the same target more than once before its final state).
    local prev_size=-1
    for _ in $(seq 1 15); do
        png=$(pick_snapshot)
        local size
        size=$(stat -f%z "$png" 2>/dev/null || echo -1)
        [ "$size" = "$prev_size" ] && break
        prev_size=$size
        sleep 0.15
    done

    if [ ! -f "$ref" ]; then
        mkdir -p "$REF_DIR"
        cp "$png" "$ref"
        echo "REF  $name (saved new reference at $ref - review it, then re-run)"
        results+=("REF  $name")
        return
    fi

    if python3 "Guest/init/x11-tests/pngdiff.py" "$png" "$ref"; then
        echo "PASS $name"
        results+=("PASS $name"); pass=$((pass + 1))
    else
        local actual_copy="/tmp/xtest_${name}.actual.png"
        cp "$png" "$actual_copy"
        echo "FAIL $name (pixel mismatch - actual saved to $actual_copy)"
        results+=("FAIL $name"); fail=$((fail + 1))
    fi
}

mkdir -p "$SNAPSHOT_DIR"
ensure_display

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
    for f in "$TEST_DIR"/*."$SRC_EXT"; do
        [ -e "$f" ] || continue
        tests+=("$(basename "${f%.*}")")
    done
fi

for t in "${tests[@]}"; do
    run_test "$t"
done

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
