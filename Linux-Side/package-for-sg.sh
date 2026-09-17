#!/bin/sh
# Makes a self-contained tarball of this folder, for carrying into a guest.
#
#   ./package-for-sg.sh [output.tar.gz]
#
# The daemon sources and bootstrap tools in here are SYMLINKS into
# ../MSL, deliberately - that is what stops them going stale
# the way daemons/fileopsd.c did. But a symlink pointing out of the folder
# is useless the moment the folder travels anywhere: confirmed the fast
# way, by bind-mounting this directory into a container, where every one of
# them dangled and the provision run failed before it started.
#
# `tar -h` (--dereference) writes the pointed-at file's contents instead of
# the link, which is exactly what is wanted here and nowhere else.

set -eu
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OUT="${1:-$SELF_DIR/../msl-linux-side.tar.gz}"

cd "$SELF_DIR"
for f in daemons/shellinit.c daemons/fileopsd.c daemons/x11tunnel.c daemons/msl-maintenance.sh; do
    [ -r "$f" ] || { echo "package-for-sg: $f does not resolve - is the repo checkout next door?" >&2; exit 1; }
done

tar -czhf "$OUT" \
    --exclude='.DS_Store' \
    --exclude='*.o' \
    -C "$SELF_DIR/.." "$(basename "$SELF_DIR")"

echo "package-for-sg: wrote $OUT"
echo "  verify it is self-contained:  tar -tzf \"$OUT\" | head"
echo "  in the guest:                 tar -xzf msl-linux-side.tar.gz && Linux-Side/provision/provision-msl.sh"
