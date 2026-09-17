#!/bin/sh
# Compresses built images for publishing and writes the manifest
# `msl install` reads.
#
#   image-build/package-images.sh KERNEL_DIR IMAGES_DIR OUT_DIR BASE_URL [DISTRO...]
#
# OUT_DIR receives, flat:
#   manifest.json
#   SHA256SUMS                                  every file below, `shasum -c` ready
#   msl-kernel-<kver>-arm64.Image.xz            the raw kernel, xz-compressed
#   msl-initramfs-<kver>-arm64.cpio.gz          as built (already gzip - xz gains nothing)
#   msl-<distro>-<release>-arm64.img.xz         each image, xz-compressed
#
# The names carry what a person downloading one needs to know - what it is,
# which release, which architecture - and never a build date, so a link stays
# the same across rebuilds of one release. The build date is the manifest's
# `version`. `msl install` saves every file under its own fixed name
# (`GuestDistro.diskImageFilename`), so these names are for people and
# servers only.
#
# BASE_URL is where OUT_DIR will be served from; every url in the manifest is
# BASE_URL/<file>. Run on the Mac (needs xz and shasum).
#
# xz, not zstd: the Compression framework that ships with macOS decodes xz,
# so MSL unpacks images with no bundled library (ImageDecompressor.swift).
# -9e for the smallest download. -T4 rather than -T0: at -9 each thread holds
# about 700 MB.
set -eu

[ $# -ge 4 ] || { echo "usage: $0 KERNEL_DIR IMAGES_DIR OUT_DIR BASE_URL [DISTRO...]" >&2; exit 2; }
KERNEL=$1; IMAGES=$2; OUT=$3; BASE_URL=${4%/}; shift 4
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=distros.sh
. "$HERE/distros.sh"
[ $# -gt 0 ] || set -- $MSL_DISTROS
XZ=${XZ:-$(command -v xz)}
[ -x "$XZ" ] || { echo "package-images: xz not found (set XZ=)" >&2; exit 1; }

mkdir -p "$OUT"
log() { echo "package-images: $*"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
bytes() { stat -f %z "$1"; }

# artifact VERSION FILE [COMPRESSION INSTALLED_SIZE]
artifact() {
    printf '{"version": "%s", "url": "%s/%s", "sha256": "%s", "size": %s' \
        "$1" "$BASE_URL" "$(basename "$2")" "$(sha "$2")" "$(bytes "$2")"
    [ $# -ge 4 ] && printf ', "compression": "%s", "installedSize": %s' "$3" "$4"
    printf '}'
}

KRELEASE=$(cat "$KERNEL/kernel-release")          # 6.18.50-0-lts
KVER=$(echo "$KRELEASE" | sed 's/-0-/-/')          # 6.18.50-lts
KERNEL_FILE="msl-kernel-$KVER-arm64.Image.xz"
INITRAMFS_FILE="msl-initramfs-$KVER-arm64.cpio.gz"
log "kernel $KRELEASE"
"$XZ" -9e -T4 -c "$KERNEL/Image" > "$OUT/$KERNEL_FILE"
"$XZ" -t "$OUT/$KERNEL_FILE"
cp "$KERNEL/initramfs" "$OUT/$INITRAMFS_FILE"
chmod 644 "$OUT/$INITRAMFS_FILE"

distros_json=""
for d in "$@"; do
    img="$IMAGES/$d.img"
    [ -r "$img" ] || { log "skipping $d - no $img"; continue; }
    release=$(distro_release "$d") || { log "skipping $d - no release tag in distros.sh"; continue; }
    file="msl-$d-$release-arm64.img.xz"
    started=$(date +%s)
    "$XZ" -9e -T4 -c "$img" > "$OUT/$file"
    "$XZ" -t "$OUT/$file"
    version=$(sed -n 's/^built: *//p' "$IMAGES/$d.info" | cut -c1-10)
    entry=$(artifact "$version" "$OUT/$file" xz "$(bytes "$img")")
    distros_json="$distros_json${distros_json:+,
    }\"$d\": $entry"
    log "$file: $(( $(bytes "$OUT/$file") / 1048576 )) MiB, $(( $(date +%s) - started ))s"
done

{
    echo "{"
    printf '  "kernel": %s,\n' "$(artifact "$KRELEASE" "$OUT/$KERNEL_FILE" xz "$(bytes "$KERNEL/Image")")"
    printf '  "initramfs": %s,\n' "$(artifact "$KRELEASE" "$OUT/$INITRAMFS_FILE")"
    printf '  "distros": {\n    %s\n  }\n' "$distros_json"
    echo "}"
} > "$OUT/manifest.json"

# Refuse to hand over a manifest that doesn't parse.
if command -v plutil >/dev/null 2>&1; then
    plutil -convert json -o /dev/null "$OUT/manifest.json" || { echo "package-images: manifest.json is not valid JSON" >&2; exit 1; }
fi

(cd "$OUT" && shasum -a 256 msl-*.xz msl-*.gz > SHA256SUMS)
log "wrote $OUT/manifest.json and SHA256SUMS"
du -sh "$OUT"
