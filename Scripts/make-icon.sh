#!/bin/bash
# Builds MSL.icns from the melon logo.
#
# `Sources/MSLApp/Resources/App_Logo.png` is the single source of truth for
# MSL's identity - it is what the About window shows, and now what the Dock,
# Finder and Cmd-Tab show too. The .icns is a build product derived from it
# and checked in only so `build-app.sh` does not need to regenerate it on
# every run; delete it and this script rebuilds it.
#
#   Scripts/make-icon.sh [--force]
#
# Regenerates when the PNG is newer than the .icns, or on --force.
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE="Sources/MSLApp/Resources/App_Logo.png"
TARGET="Resources/MSLApp/MSL.icns"

[ -f "$SOURCE" ] || { echo "make-icon: missing $SOURCE" >&2; exit 1; }

if [ "${1:-}" != "--force" ] && [ -f "$TARGET" ] && [ "$TARGET" -nt "$SOURCE" ]; then
    echo "make-icon: $TARGET is up to date (pass --force to rebuild)"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PADDED="$WORK/padded.png"

# The artwork runs edge to edge - the stem touches the top, the slice touches
# the bottom right. A free-form icon that reaches its bounds reads oversized
# next to the squircle icons either side of it in the Dock, and the stem is
# the first thing to clip. So inset it onto a transparent canvas first.
#
# Done with CoreGraphics rather than `sips`, which can pad but only with an
# opaque colour - and a white box behind a transparent melon is exactly what
# we are trying not to ship.
INSET_SCALE="${MSL_ICON_SCALE:-0.86}" python3 - "$SOURCE" "$PADDED" <<'PY'
import os, sys
import Quartz
import CoreFoundation

source_path, out_path = sys.argv[1], sys.argv[2]
scale = float(os.environ.get("INSET_SCALE", "0.86"))
size = 1024

url = CoreFoundation.CFURLCreateFromFileSystemRepresentation(
    None, source_path.encode(), len(source_path.encode()), False)
src = Quartz.CGImageSourceCreateWithURL(url, None)
image = Quartz.CGImageSourceCreateImageAtIndex(src, 0, None)

colorspace = Quartz.CGColorSpaceCreateDeviceRGB()
ctx = Quartz.CGBitmapContextCreate(
    None, size, size, 8, 0, colorspace,
    Quartz.kCGImageAlphaPremultipliedLast)
Quartz.CGContextSetInterpolationQuality(ctx, Quartz.kCGInterpolationHigh)

drawn = size * scale
offset = (size - drawn) / 2.0
Quartz.CGContextDrawImage(ctx, Quartz.CGRectMake(offset, offset, drawn, drawn), image)

out = Quartz.CGBitmapContextCreateImage(ctx)
out_url = CoreFoundation.CFURLCreateFromFileSystemRepresentation(
    None, out_path.encode(), len(out_path.encode()), False)
dest = Quartz.CGImageDestinationCreateWithURL(out_url, "public.png", 1, None)
Quartz.CGImageDestinationAddImage(dest, out, None)
Quartz.CGImageDestinationFinalize(dest)
print("make-icon: inset to %d%% on a transparent 1024 canvas" % round(scale * 100))
PY

# iconutil needs every one of these names present; a missing size fails the
# whole conversion rather than degrading.
ICONSET="$WORK/MSL.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$PADDED" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$TARGET"
echo "make-icon: wrote $TARGET ($(du -h "$TARGET" | cut -f1))"
