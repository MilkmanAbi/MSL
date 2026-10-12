#!/bin/sh
# build.sh - builds MSLUSBDriverHost.app with MSLUSBDriver.dext embedded,
# entirely from the command line (no Xcode project). Run
# ../MSLUSBDriver/build.sh first (or let this script call it).
#
# Usage: ./build.sh
#
# After building, run .build-app/MSLUSBDriverHost.app/Contents/MacOS/MSLUSBDriverHost
# to submit the activation request. Needs `sudo systemextensionsctl developer on`
# (+ reboot) first for a locally ad-hoc-signed dext to have any chance of
# loading without an Apple-issued DriverKit entitlement - see
# ../MSLUSBDriver/README.md.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="$HERE/../MSLUSBDriver"
BUILD="$HERE/.build-app"
APP="$BUILD/MSLUSBDriverHost.app"

echo "== building MSLUSBDriver.dext =="
"$DRIVER_DIR/build.sh"
DEXT="$DRIVER_DIR/.build-dext/MSLUSBDriver.dext"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/SystemExtensions"

echo "== compiling host app =="
swiftc "$HERE/main.swift" -o "$APP/Contents/MacOS/MSLUSBDriverHost"

echo "== assembling app bundle =="
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp -R "$DEXT" "$APP/Contents/Library/SystemExtensions/"

echo "== codesigning app (dext inside was already signed individually) =="
codesign --force --sign - \
  --entitlements "$HERE/MSLUSBDriverHost.entitlements" \
  "$APP"

echo "== done: $APP =="
codesign -dv "$APP" 2>&1
echo
echo "Run this to submit the activation request:"
echo "  $APP/Contents/MacOS/MSLUSBDriverHost"
