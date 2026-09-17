#!/bin/sh
# Builds images for several distros in a row, one log per distro, and prints
# a summary at the end. Sequential on purpose: each build is a full package
# install plus a compile, and OrbStack's VM has one pool of CPU and memory.
#
#   image-build/build-all.sh KERNEL_DIR OUT_DIR [DISTRO...]
#
# With no DISTRO arguments, builds everything in distros.sh.
set -u
[ $# -ge 2 ] || { echo "usage: $0 KERNEL_DIR OUT_DIR [DISTRO...]" >&2; exit 2; }
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
KERNEL_DIR=$1; OUT=$2; shift 2
# shellcheck source=distros.sh
. "$HERE/distros.sh"
[ $# -gt 0 ] || set -- $MSL_DISTROS
mkdir -p "$OUT/logs"
summary=""
for d in "$@"; do
    started=$(date +%s)
    echo "build-all: $d ..."
    if sh "$HERE/build-rootfs.sh" "$d" "$KERNEL_DIR" "$OUT" > "$OUT/logs/$d.log" 2>&1; then
        result="ok    $(grep '^content:' "$OUT/$d.info" | awk '{print $2, $3}')"
    else
        result="FAILED (see logs/$d.log)"
    fi
    summary="$summary
  $(printf '%-9s' "$d") $result  $(( ($(date +%s) - started) / 60 )) min"
    echo "build-all: $d $result"
done
echo "build-all: summary$summary"
