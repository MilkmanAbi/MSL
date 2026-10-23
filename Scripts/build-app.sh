#!/bin/bash
# Builds MSL.app - the real, double-clickable macOS application.
#
# `swift build` alone produces a bare Mach-O, which macOS will run but
# treats as an anonymous tool: the wrong name in the Dock and menu bar, no
# icon, no Info.plist. Everything below is the packaging step the Swift
# package deliberately doesn't do (see Package.swift's MSLApp comment).
#
# The command-line tools are copied into Contents/MacOS alongside the app.
# That is not decoration: `HostToolInstaller.runningBinaryDirectory` looks for
# them next to the running binary, so this is what lets a double-clicked
# MSL.app install a working `msl`, `mslhd`, `mslgui`, `msl-applauncher`,
# `msl-usbd` and `mslod` into ~/Library/Application Support/MSL/bin.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# Ask SwiftPM where it actually put things rather than assuming.
#
# This was hardcoded to `.build/arm64-apple-macosx/release`. Xcode 27's
# build system writes to `.build/out/Products/Release` instead, so the
# script went on assembling a binary from whenever that old directory was
# last written - MSL.app was shipped from 17 September code for days while
# every `swift build` "succeeded". Silent, and invisible in the app itself.
BUILD=$(swift build -c release --show-bin-path 2>/dev/null | tail -1)
[ -n "$BUILD" ] && [ -d "$BUILD" ] || BUILD="$ROOT/.build/arm64-apple-macosx/release"
APP="$ROOT/dist/MSL.app"

echo "==> building (release)"
swift build -c release

# A stale binary is worse than a failed build: it looks like it worked.
#
# Not against all of Sources, which would fail the app for an edit to the
# command line and teach everyone to ignore the check.
#
# Each binary is checked against its own target and **the libraries it
# actually links**, which is not the same list for all of them. A library
# left out ships its changes as a stale binary - the failure this block
# exists to catch, and which once shipped a week-old app while every build
# "succeeded". A library wrongly put *in* is just as bad in the other
# direction: `mslod` deliberately does not link MSLCore, so checking it
# against MSLCore failed the whole build for an edit the observer could not
# possibly contain, which teaches everyone to ignore the check.
for entry in "MSLApp:MSLApp:MSLCore MSLObserver" \
             "msl:msl:MSLCore MSLObserver PublicMSL" \
             "mslhd:mslhd:MSLCore MSLObserver PublicMSL" \
             "mslgui:mslgui:MSLCore MSLObserver" \
             "msl-applauncher:msl-applauncher:MSLCore MSLObserver" \
             "msl-usbd:msl-usbd:MSLCore MSLObserver" \
             "mslod:mslod:MSLObserver"; do
    binary=${entry%%:*}
    rest=${entry#*:}
    target=${rest%%:*}
    libraries=${rest#*:}
    [ -f "$BUILD/$binary" ] || continue
    sources="$ROOT/Sources/$target"
    for library in $libraries; do sources="$sources $ROOT/Sources/$library"; done
    # Unquoted on purpose: $sources is a list of directories to search.
    # shellcheck disable=SC2086
    newer=$(find $sources -name '*.swift' -newer "$BUILD/$binary" -print -quit 2>/dev/null || true)
    if [ -n "$newer" ]; then
        echo "build-app: $BUILD/$binary is older than $newer - the build did not produce what you are shipping" >&2
        exit 1
    fi
done
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# NOT "MSL": the macOS filesystem is case-insensitive by default, so
# Contents/MacOS/MSL and the `msl` CLI copied in below are the same file -
# the tool silently overwrote the app, and the bundle launched the command
# line client instead of the GUI. The user-visible name comes from
# CFBundleName, not from this filename.
cp "$BUILD/MSLApp" "$APP/Contents/MacOS/MSLApp"
for tool in msl mslhd mslgui msl-applauncher msl-usbd mslod; do
    cp "$BUILD/$tool" "$APP/Contents/MacOS/$tool"
done
# App icons, the Apple way for every macOS MSL runs on.
#
# The source is an Icon Composer document (Resources/Icons/<name>.icon: the
# logo as a layer over a light / dark gradient fill). actool compiles it into
# Assets.car - which macOS 26+ reads through CFBundleIconName, and which is
# what gives the icon its squircle, Liquid Glass edge and its dark, clear and
# tinted Dock variants - and, because the deployment target is 14.0, also
# renders a squircle <name>.icns that macOS 14 and 15 read through
# CFBundleIconFile. Before this, the raw PNG was the icon: a melon with no
# tile, sitting unmasked among squircles in a tinted Dock.
#
# Without Xcode's actool (Command Line Tools only) the old flat .icns made by
# make-icon.sh is used instead, so the build never breaks over an icon.
compile_icon() { # <name> <Resources dir> [fallback-png]
    local name="$1" dest="$2"
    local work="$ROOT/.build/icons/$name"
    rm -rf "$work"; mkdir -p "$work"
    if xcrun --find actool >/dev/null 2>&1 \
        && xcrun actool "$ROOT/Resources/Icons/$name.icon" --compile "$work" \
            --output-format human-readable-text --errors \
            --output-partial-info-plist "$work/partial.plist" --app-icon "$name" \
            --include-all-app-icons --enable-on-demand-resources NO --development-region en \
            --target-device mac --minimum-deployment-target 14.0 --platform macosx >"$work/actool.log" 2>&1 \
        && [ -f "$work/Assets.car" ] && [ -f "$work/$name.icns" ]; then
        cp "$work/Assets.car" "$dest/Assets.car"
        cp "$work/$name.icns" "$dest/$name.icns"
    else
        echo "    actool unavailable or failed - using the flat $name.icns (see $work/actool.log)"
        cp "$ROOT/Resources/MSLApp/$name.icns" "$dest/$name.icns"
    fi
}
# The flat fallbacks stay generated from the one canonical copy of each logo.
"$ROOT/Scripts/make-icon.sh"
compile_icon MSL "$APP/Contents/Resources"

# The artwork and the licence text, into the one place that survives being
# copied to another Mac.
#
# Not optional, and not only about images: SwiftPM's generated
# `Bundle.module` resolves against an absolute path into *this* machine's
# .build directory and calls fatalError when that is gone. Without these
# files here, the built app launches on the machine that compiled it and
# dies instantly anywhere else. `MSLAsset` looks here first.
for asset in App_Logo.png MSL_Files_Logo.png Mascot.png Abi_Logo-Light.png Abi_Logo-Dark.png Welcome_Banner.jpg Crash_Screen.png License.md; do
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
    cp "$ROOT/Guest/init/"{shellinit,fileopsd,trafficd,memd,x11tunnel,usbattach}.c "$ROOT/Guest/init/msl-maintenance.sh" "$KIT/daemons/"
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
    <key>CFBundleIconName</key><string>MSL</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
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
    <!-- Camera and microphone are used by MSL Peripherals, not by this app -
         but macOS attributes a privacy request from an app nested inside
         another app's bundle to the ENCLOSING app, and reads the usage
         description from here. Without these, MSL Peripherals was killed
         the instant it asked for the camera, with a crash blaming a
         missing NSCameraUsageDescription that was present in its own
         Info.plist all along. Proven 2026-09-23: the identical helper
         binary was killed when nested in MSL.app and granted when copied
         outside any bundle. -->
    <key>NSCameraUsageDescription</key><string>MSL lends this Mac's camera to the Linux app you allow, as an ordinary webcam. Nothing is shared until you say yes in MSL Peripherals.</string>
    <key>NSMicrophoneUsageDescription</key><string>MSL lends this Mac's microphone to the Linux app you allow, as an ordinary input device. Nothing is shared until you say yes in MSL Peripherals.</string>
    <key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict>
</plist>
PLIST

# ----------------------------------------------------------------------
# MSL Peripherals: the small app that lends the Mac's camera and microphone
# to a Linux instance.
#
# Its own bundle, inside MSL.app, because macOS grants camera and microphone
# access to an application with a bundle and a usage description - never to
# `mslhd`, which is a bare daemon and has no business being able to hold a
# camera. Shipped inside so it travels with MSL and is launched by path.
HELPER="$APP/Contents/Library/MSL Peripherals.app"
echo "==> assembling $(basename "$HELPER")"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp "$BUILD/MSLPeripherals" "$HELPER/Contents/MacOS/MSL Peripherals"
compile_icon MSL "$HELPER/Contents/Resources"
cat > "$HELPER/Contents/Info.plist" <<'HELPERPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MSL Peripherals</string>
    <key>CFBundleDisplayName</key><string>MSL Peripherals</string>
    <key>CFBundleIdentifier</key><string>com.msl.peripherals</string>
    <key>CFBundleExecutable</key><string>MSL Peripherals</string>
    <key>CFBundleIconFile</key><string>MSL</string>
    <key>CFBundleIconName</key><string>MSL</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- What macOS shows in its own prompt. It names the instance's side of
         the deal plainly: this is a camera going to a Linux application. -->
    <key>NSCameraUsageDescription</key>
    <string>MSL shows this Mac's camera to the Linux app you choose, as an ordinary webcam, once you allow it. Sharing stops when you quit MSL Peripherals.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MSL lets the Linux app you choose hear this Mac's microphone, as an ordinary input device, once you allow it. Sharing stops when you quit MSL Peripherals.</string>
    <!-- Required by AVFoundation for any app that lists Continuity Camera
         devices (an iPhone as a webcam). Without it the camera picker's
         discovery session made TCC abort the app the moment camera access
         was requested - with a crash that blamed a missing
         NSCameraUsageDescription that was sitting right here. -->
    <key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict>
</plist>
HELPERPLIST

echo "==> signing"
# The whole bundle is signed with the virtualization entitlement: mslhd
# ships inside it, and an mslhd without that entitlement starts fine and
# then fails the moment anything asks it for a VM.
# **A designated requirement that survives a rebuild.**
#
# Ad-hoc signing defaults the designated requirement to the binary's own
# cdhash, and TCC keys its grants on that - so every rebuild is a brand-new
# application as far as macOS is concerned, and every permission the person
# granted is gone. That is why Local Network access, Automation, Files and
# Folders all have to be granted again after each install, and why
# "192.168.64.229 isn't answering on port 22" came back the moment MSL was
# reinstalled: the app had simply lost permission to reach the local
# network, while the same probe from Terminal kept working.
#
# `-r='designated => identifier "..."'` pins the requirement to the bundle
# identifier instead, so the grants
# persist across rebuilds. It is not a security boundary - an ad-hoc
# signature never was, since anybody can produce one - and it buys back the
# single most irritating thing about running an unsigned build.
IDENTIFIER_REQUIREMENT_APP='designated => identifier "com.msl.app"'
IDENTIFIER_REQUIREMENT_FILES='designated => identifier "com.msl.files"'
IDENTIFIER_REQUIREMENT_PERIPHERALS='designated => identifier "com.msl.peripherals"'

codesign --force --deep --sign - \
    --identifier com.msl.app -r="$IDENTIFIER_REQUIREMENT_APP" \
    --entitlements "$ROOT/Resources/MSLApp/MSLApp.entitlements" \
    "$APP" 2>&1 | sed 's/^/    /'
# The nested helper is signed again, with its own bundle identifier, and
# then the outer bundle is re-sealed without `--deep` so that signature
# survives.
#
# This is not tidiness. `--deep` signs a nested app with an identifier
# derived from its executable name ("MSLPeripherals"), which does not match
# its CFBundleIdentifier - and TCC then refuses to find the usage
# description that is sitting right there in its Info.plist. macOS kills the
# app on the spot: "attempted to access privacy-sensitive data without a
# usage description", with the description present. Signing it explicitly is
# what makes the camera prompt say "MSL Peripherals" and appear at all.
codesign --force --sign - --identifier com.msl.peripherals \
    -r="$IDENTIFIER_REQUIREMENT_PERIPHERALS" "$HELPER" 2>&1 | sed 's/^/    /'
codesign --force --sign - \
    --identifier com.msl.app -r="$IDENTIFIER_REQUIREMENT_APP" \
    --entitlements "$ROOT/Resources/MSLApp/MSLApp.entitlements" \
    "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep "$APP" && echo "    signature valid"

# ----------------------------------------------------------------------
# MSL Files: the file browser as an app of its own - its own Dock tile,
# Launchpad icon and Spotlight entry - installed beside MSL.app.
#
# The same executable as MSL, under a different bundle identifier: main.swift
# reads the identifier at launch and becomes MSL Files (MSLFilesIdentity). So
# there is no second codebase to keep in step, and it talks to the same mslhd
# over the same control socket. It is a sibling of MSL.app rather than nested
# inside it because a nested app gets no Launchpad or Spotlight presence.
FILES_APP="$ROOT/dist/MSL Files.app"
echo "==> assembling $(basename "$FILES_APP")"
rm -rf "$FILES_APP"
mkdir -p "$FILES_APP/Contents/MacOS" "$FILES_APP/Contents/Resources"
cp "$BUILD/MSLApp" "$FILES_APP/Contents/MacOS/MSLFiles"
MSL_ICON_SOURCE="Assets/MSL_Files_Logo.png" MSL_ICON_TARGET="Resources/MSLApp/MSLFiles.icns" \
    MSL_ICON_SCALE=1.0 "$ROOT/Scripts/make-icon.sh" | sed 's/^/    /'
compile_icon MSLFiles "$FILES_APP/Contents/Resources"
for asset in MSL_Files_Logo.png App_Logo.png Mascot.png Abi_Logo-Light.png Abi_Logo-Dark.png License.md; do
    cp "$ROOT/Assets/$asset" "$FILES_APP/Contents/Resources/$asset"
done
cat > "$FILES_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MSL Files</string>
    <key>CFBundleDisplayName</key><string>MSL Files</string>
    <key>CFBundleIdentifier</key><string>com.msl.files</string>
    <key>CFBundleExecutable</key><string>MSLFiles</string>
    <key>CFBundleIconFile</key><string>MSLFiles</string>
    <key>CFBundleIconName</key><string>MSLFiles</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <!-- msl-files://files?instance=<name>&path=<guest path> reveals a folder.
         mslhd sends it when a Linux app asks to show one. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.msl.files</string>
            <key>CFBundleURLSchemes</key><array><string>msl-files</string></array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Mac Subsystem for Linux</string>
    <key>NSAppleEventsUsageDescription</key><string>MSL Files opens Terminal windows at the folder you're looking at, on the Mac or inside Linux.</string>
    <key>NSDesktopFolderUsageDescription</key><string>MSL Files shows your Desktop beside your Linux instances so you can move files between them.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>MSL Files shows your Documents beside your Linux instances so you can move files between them.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>MSL Files shows your Downloads beside your Linux instances so you can move files between them.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Each running Linux instance appears as a network volume, which MSL Files browses.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>MSL Files can browse removable drives alongside your Linux instances.</string>
</dict>
</plist>
PLIST
# Signed with its own identifier so TCC keys its permissions (Desktop,
# Documents, Automation) to MSL Files rather than to a name derived from the
# executable. No virtualization entitlement: MSL Files never runs a VM.
codesign --force --sign - --identifier com.msl.files \
    -r="$IDENTIFIER_REQUIREMENT_FILES" "$FILES_APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep "$FILES_APP" && echo "    signature valid"

# **Keep what we just built out of Launchpad and Spotlight.**
#
# macOS registers any .app it notices, and these two carry the same bundle
# identifiers as the installed copies - so the moment this script finishes,
# Launchpad and Spotlight show "MSL" and "MSL Files" twice, one of them a
# build product in a dist folder. It is not cosmetic: picking the wrong one
# launches week-old code, and that has cost whole debugging sessions.
#
# This has to live here rather than only in build-installer.sh. That script
# cleans up after itself, but the documented workflow is to run *this* one
# after every change and copy the result to /Applications - which leaves
# dist/ registered every single time. (2026-10-04: it did, and both apps
# showed twice.)
#
# The bundles stay on disk; only their registration goes. They are an
# ingredient, never something to launch from Launchpad.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    "$LSREGISTER" -u "$FILES_APP" 2>/dev/null || true
fi

# `--install` puts them in /Applications and then removes what is left here.
#
# **That last part is the point.** A built bundle sitting in dist/ carries
# the same name and identifier as the installed one, and Spotlight indexes
# it by name - so Launchpad shows "MSL" and "MSL Files" twice, and opening
# the wrong one runs whatever was last built instead of what is installed.
# That has cost whole debugging sessions.
#
# Neither `lsregister -u` above nor a `.metadata_never_index` marker stops
# it. Unregistering does not stick, because macOS re-registers any bundle it
# can still see; and `.metadata_never_index` is honoured at a volume root,
# not in a subdirectory - tried, and Spotlight indexed the bundles anyway.
# The only thing that actually works is for the bundles not to be there, so
# the install removes them.
if [ "${1:-}" = "--install" ]; then
    echo
    echo "==> installing to /Applications (needs your password)"
    osascript -e 'tell application "MSL" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application "MSL Files" to quit' >/dev/null 2>&1 || true
    sleep 2
    sudo rm -rf /Applications/MSL.app "/Applications/MSL Files.app"
    sudo cp -R "$APP" /Applications/MSL.app
    sudo cp -R "$FILES_APP" "/Applications/MSL Files.app"
    [ -x "$LSREGISTER" ] && { "$LSREGISTER" -f /Applications/MSL.app; "$LSREGISTER" -f "/Applications/MSL Files.app"; }
    rm -rf "$APP" "$FILES_APP"
    echo "    installed, and the build copies removed so nothing shows twice"
    echo
    echo "open MSL once to let it reinstall its command-line tools, then:"
    echo "    launchctl kickstart -k gui/\$(id -u)/com.msl.mslhd"
    exit 0
fi


echo
echo "built $APP"
echo "built $FILES_APP"
echo "run it with:  open '$APP'"
echo
echo
echo "note: these are build products with the same name and identifier as the"
echo "      installed apps, so while they sit here Launchpad shows MSL twice."
echo "      Install with:  Scripts/build-app.sh --install"
