#!/bin/sh
# Builds the kernel every MSL guest boots, and the pieces that go with it.
#
#   image-build/build-kernel.sh OUT_DIR
#
# Produces, in OUT_DIR:
#   Image           raw arm64 kernel (Virtualization's Linux boot loader
#                   needs the raw Image, not Alpine's EFI zboot vmlinuz)
#   initramfs       a small initramfs that can find and mount an ext4 root
#                   on NVMe or virtio-blk - nothing else
#   modules.tar     lib/modules/<version>/, trimmed to what a VM can use,
#                   decompressed, depmod'ed - copied onto every distro disk
#   kernel-release  the version string, e.g. 6.18.50-0-lts
#   config          the kernel's .config, for reference
#
# Source is Alpine's own linux-lts package, the same kernel MSL has booted
# since 2026-09-03 (lts rather than virt because virt lacks vgem and the
# USB/IP host driver). One kernel serves every distro - see GuestDistro's doc
# comment in the repo. Runs in a throwaway arm64 Alpine container, so the
# Mac needs nothing but Docker (OrbStack).

set -eu

[ $# -eq 1 ] || { echo "usage: $0 OUT_DIR" >&2; exit 2; }
mkdir -p "$1"
OUT=$(CDPATH='' cd -- "$1" && pwd)
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ALPINE_VERSION=${ALPINE_VERSION:-3.24}
FLAVOR=${FLAVOR:-lts}

echo "build-kernel: alpine:$ALPINE_VERSION linux-$FLAVOR -> $OUT"
docker run --rm --platform=linux/arm64 \
    -e FLAVOR="$FLAVOR" \
    -v "$HERE:/build:ro" \
    -v "$OUT:/out" \
    "alpine:$ALPINE_VERSION" sh /build/kernel-inner.sh
echo "build-kernel: done"
ls -la "$OUT"
