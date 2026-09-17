#!/bin/sh
# build.sh - builds MSLUSBDriver.dext directly from the command line, no
# Xcode project needed. Every step here was verified manually first (see
# README.md's build log) - this just makes it reproducible.
#
# Usage: ./build.sh   (run from this directory)
#
# Requires: a full Xcode install (not just Command Line Tools - the
# DriverKit platform/SDK and `iig` only ship with Xcode itself), SIP
# disabled and `sudo systemextensionsctl developer on` (+ reboot) to
# actually load the result locally without an Apple-approved entitlement.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
XCODE_TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
IIG="$XCODE_TOOLCHAIN/usr/bin/iig"
DRIVERKIT_SDK="$(xcrun --sdk driverkit --show-sdk-path 2>/dev/null || echo "$(xcode-select -p)/Platforms/DriverKit.platform/Developer/SDKs/DriverKit.sdk")"
BUILD="$HERE/.build-dext"
BUNDLE="$BUILD/MSLUSBDriver.dext"

rm -rf "$BUILD"
mkdir -p "$BUILD/include/MSLUSBDriver" "$BUNDLE/Contents/MacOS"

echo "== iig: MSLUSBDriver.iig -> header + dispatch glue =="
"$IIG" \
  --def "$HERE/MSLUSBDriver.iig" \
  --header "$BUILD/include/MSLUSBDriver/MSLUSBDriver.h" \
  --impl "$BUILD/MSLUSBDriver.iig.cpp" \
  --framework-name MSLUSBDriver \
  -- \
  -x c++ -std=c++17 -D__IIG=1 \
  -isysroot "$DRIVERKIT_SDK" \
  -F"$DRIVERKIT_SDK/System/Library/Frameworks"

# Also drop a flat copy for MSLUSBDriver.cpp's quoted #include "MSLUSBDriver.h".
cp "$BUILD/include/MSLUSBDriver/MSLUSBDriver.h" "$BUILD/MSLUSBDriver.h"

echo "== compiling MSLUSBDriver.cpp =="
clang++ -target arm64-apple-driverkit25.0 -isysroot "$DRIVERKIT_SDK" \
  -F"$DRIVERKIT_SDK/System/Library/Frameworks" \
  -I"$BUILD/include" -I"$BUILD" \
  -x c++ -std=c++17 -fno-exceptions -fno-rtti \
  -c "$HERE/MSLUSBDriver.cpp" -o "$BUILD/MSLUSBDriver.o"

echo "== compiling generated dispatch glue =="
clang++ -target arm64-apple-driverkit25.0 -isysroot "$DRIVERKIT_SDK" \
  -F"$DRIVERKIT_SDK/System/Library/Frameworks" \
  -I"$BUILD/include" -I"$BUILD" \
  -x c++ -std=c++17 -fno-exceptions -fno-rtti \
  -c "$BUILD/MSLUSBDriver.iig.cpp" -o "$BUILD/MSLUSBDriver.iig.o"

echo "== linking =="
clang++ -target arm64-apple-driverkit25.0 -isysroot "$DRIVERKIT_SDK" \
  -F"$DRIVERKIT_SDK/System/Library/Frameworks" \
  "$BUILD/MSLUSBDriver.o" "$BUILD/MSLUSBDriver.iig.o" \
  -framework DriverKit -framework USBDriverKit \
  -o "$BUNDLE/Contents/MacOS/MSLUSBDriver"

echo "== assembling bundle =="
cp "$HERE/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "== codesigning (ad-hoc + local entitlements) =="
codesign --force --sign - \
  --entitlements "$HERE/MSLUSBDriver.entitlements" \
  "$BUNDLE"

echo "== done: $BUNDLE =="
codesign -dv "$BUNDLE" 2>&1
