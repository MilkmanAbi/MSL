#!/bin/sh
# Builds one distro's MSL disk image from its official container image.
#
#   image-build/build-rootfs.sh DISTRO KERNEL_DIR OUT_DIR
#
#   DISTRO      one of the names in distros.sh
#   KERNEL_DIR  build-kernel.sh's output (modules.tar, kernel-release)
#   OUT_DIR     receives DISTRO.img (sparse ext4, label msl-root), DISTRO.info
#
# Three stages, all in throwaway arm64 containers - the Mac needs only
# Docker (OrbStack):
#
#   1. configure  the distro's own container: install its init system, then
#                 run Linux-Side/provision/provision-msl.sh exactly as it
#                 would run in a booted guest (packages, daemons built from
#                 source, units, fstab, users), then strip caches.
#   2. export     `docker export` of that container's filesystem.
#   3. assemble   in Alpine: fix what a container leaves behind (.dockerenv,
#                 bind-mounted resolv.conf/hosts/hostname), add the shared
#                 kernel's modules, and `mke2fs -d` it into an ext4 image.
#
# No VM is booted here. Booting and testing is a separate step, because a
# container is a filesystem with a package manager, not a machine.

set -eu

[ $# -eq 3 ] || { echo "usage: $0 DISTRO KERNEL_DIR OUT_DIR" >&2; exit 2; }
DISTRO=$1
KERNEL_DIR=$(CDPATH='' cd -- "$2" && pwd)
mkdir -p "$3"
OUT=$(CDPATH='' cd -- "$3" && pwd)
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Actual-Project/: mounted whole so Linux-Side's symlinks into ../MSL resolve.
PROJ=$(CDPATH='' cd -- "$HERE/../.." && pwd)
# Nominal size of the ext4 filesystem. Small on purpose: the file is sparse,
# but the installer has to decompress every byte of it, zeros included. The
# host grows the disk and runs resize2fs in the guest (DiskStorage), so this
# only needs to hold the image's own content with room to start working.
IMAGE_SIZE=${IMAGE_SIZE:-4G}

# shellcheck source=distros.sh
. "$HERE/distros.sh"
distro_base_image "$DISTRO" >/dev/null || { echo "build-rootfs: unknown distro '$DISTRO'" >&2; exit 2; }
BASE=$(distro_base_image "$DISTRO")
[ -r "$KERNEL_DIR/modules.tar" ] || { echo "build-rootfs: no modules.tar in $KERNEL_DIR - run build-kernel.sh first" >&2; exit 1; }

CONTAINER="msl-image-build-$DISTRO"
WORK="$OUT/.work-$DISTRO"
rm -rf "$WORK"
mkdir -p "$WORK"
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

log() { echo "build-rootfs[$DISTRO]: $*"; }

log "base image $BASE"
docker pull --platform=linux/arm64 "$BASE"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# --privileged: pacman's Landlock download sandbox fails without it
# ("switching to sandbox user 'alpm' failed!"). Harmless everywhere else.
log "stage 1: configure"
docker run --privileged --platform=linux/arm64 --name "$CONTAINER" \
    -e DISTRO="$DISTRO" -e DEBIAN_FRONTEND=noninteractive \
    -v "$PROJ:/proj:ro" \
    "$BASE" sh /proj/Linux-Side/image-build/rootfs-configure.sh

log "stage 2: export"
docker export -o "$WORK/rootfs.tar" "$CONTAINER"
docker rm -f "$CONTAINER" >/dev/null

log "stage 3: assemble $IMAGE_SIZE ext4 image"
rm -f "$OUT/$DISTRO.img"
docker run --rm --privileged --platform=linux/arm64 \
    -e DISTRO="$DISTRO" -e IMAGE_SIZE="$IMAGE_SIZE" \
    -v "$HERE:/build:ro" \
    -v "$KERNEL_DIR:/kernel:ro" \
    -v "$WORK:/work" \
    -v "$OUT:/out" \
    alpine:3.24 sh /build/rootfs-assemble.sh

log "done: $OUT/$DISTRO.img"
cat "$OUT/$DISTRO.info"
