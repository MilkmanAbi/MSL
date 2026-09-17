#!/bin/bash
# Builds MSL.app - the real, double-clickable macOS application.
#
# `swift build` alone produces a bare Mach-O, which macOS will run but
# treats as an anonymous tool: the wrong name in the Dock and menu bar, no
# icon, no Info.plist. Everything below is the packaging step the Swift
# package deliberately doesn't do (see Package.swift's MSLApp comment).
#
# The four command-line tools are copied into Contents/MacOS alongside the
# app. That is not decoration: `HostToolInstaller.runningBinaryDirectory`
# looks for them next to the running binary, so this is what lets a
# double-clicked MSL.app install a working `msl`, `mslhd`, `mslgui` and
# `msl-applauncher` into ~/Library/Application Support/MSL/bin.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/.build/arm64-apple-macosx/release"
APP="$ROOT/dist/MSL.app"

echo "==> building (release)"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# NOT "MSL": the macOS filesystem is case-insensitive by default, so
# Contents/MacOS/MSL and the `msl` CLI copied in below are the same file -
# the tool silently overwrote the app, and the bundle launched the command
# line client instead of the GUI. The user-visible name comes from
# CFBundleName, not from this filename.
cp "$BUILD/MSLApp" "$APP/Contents/MacOS/MSLApp"
for tool in msl mslhd mslgui msl-applauncher; do
    cp "$BUILD/$tool" "$APP/Contents/MacOS/$tool"
done
# The .icns is derived from Sources/MSLApp/Resources/App_Logo.png, which is
# the one canonical copy of the melon. This is a no-op unless the artwork has
# changed since the icon was last built.
"$ROOT/Scripts/make-icon.sh"
cp "$ROOT/Resources/MSLApp/MSL.icns" "$APP/Contents/Resources/MSL.icns"

# The artwork and the licence text, into the one place that survives being
# copied to another Mac.
#
# Not optional, and not only about images: SwiftPM's generated
# `Bundle.module` resolves against an absolute path into *this* machine's
# .build directory and calls fatalError when that is gone. Without these
# files here, the built app launches on the machine that compiled it and
# dies instantly anywhere else. `MSLAsset` looks here first.
for asset in App_Logo.png Mascot.png Abi_Logo-Light.png Abi_Logo-Dark.png License.md; do
    cp "$ROOT/Assets/$asset" "$APP/Contents/Resources/$asset"
done

# The guest kit MSL copies into Custom Images: provision-msl.sh and the
# daemon sources it builds, so someone making their own image has what an
# MSL guest needs. From Linux-Side (beside the repo) when it's there, else
# straight from the repo's own Guest/init sources. `cp -L`: Linux-Side's
# daemons are symlinks into this repo, and a symlink is useless once copied.
KIT="$APP/Contents/Resources/GuestKit"
rm -rf "$KIT"
mkdir -p "$KIT/daemons"
LINUX_SIDE="$ROOT/../Linux-Side"
if [ -d "$LINUX_SIDE/provision" ]; then
    cp -RL "$LINUX_SIDE/provision" "$KIT/provision"
    cp -L "$LINUX_SIDE/daemons/"*.c "$LINUX_SIDE/daemons/Makefile" "$LINUX_SIDE/daemons/msl-maintenance.sh" "$KIT/daemons/"
else
    echo "    note: $LINUX_SIDE not found - the guest kit has daemon sources but no provision-msl.sh"
    cp "$ROOT/Guest/init/"{shellinit,fileopsd,trafficd,memd,x11tunnel}.c "$ROOT/Guest/init/msl-maintenance.sh" "$KIT/daemons/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MSL</string>
    <key>CFBundleDisplayName</key><string>MSL</string>
    <key>CFBundleIdentifier</key><string>com.msl.app</string>
    <key>CFBundleExecutable</key><string>MSLApp</string>
    <key>CFBundleIconFile</key><string>MSL</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <!-- msl://files?instance=<name>&path=<guest path> opens MSL Files
         there. mslhd sends it when a Linux app asks to show a folder. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.msl.app</string>
            <key>CFBundleURLSchemes</key><array><string>msl</string></array>
        </dict>
    </array>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Mac Subsystem for Linux</string>
    <!-- Without NSAppleEventsUsageDescription macOS refuses Apple events
         without ever asking, so "Open in Terminal" silently did nothing.
         The rest are the prompts the Files window and SSH setup raise;
         the Permissions panel asks for them all at once. -->
    <key>NSAppleEventsUsageDescription</key><string>MSL opens Terminal windows already connected to your Linux instances.</string>
    <key>NSDesktopFolderUsageDescription</key><string>MSL Files shows your Desktop beside your Linux instances so you can move files between them.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>MSL Files shows your Documents beside your Linux instances so you can move files between them.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>MSL Files shows your Downloads beside your Linux instances so you can move files between them.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Each running Linux instance appears as a network volume, which MSL Files browses.</string>
    <key>NSLocalNetworkUsageDescription</key><string>MSL checks that your Linux instances can be reached over SSH.</string>
</dict>
</plist>
PLIST

echo "==> signing"
# The whole bundle is signed with the virtualization entitlement: mslhd
# ships inside it, and an mslhd without that entitlement starts fine and
# then fails the moment anything asks it for a VM.
codesign --force --deep --sign - \
    --entitlements "$ROOT/Resources/MSLApp/MSLApp.entitlements" \
    "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep "$APP" && echo "    signature valid"

echo
echo "built $APP"
echo "run it with:  open '$APP'"
