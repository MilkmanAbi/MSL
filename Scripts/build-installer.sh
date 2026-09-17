#!/bin/bash
# Builds MSL-<version>.pkg - the installer people download from GitHub.
#
#   Scripts/build-installer.sh [--skip-build]
#
# The package does one thing: put MSL.app in /Applications. Everything else
# MSL needs - the `msl` command, the background service, its LaunchAgent -
# the app installs for itself on first launch (`AppModel.start`), into the
# user's own home directory. So the package needs no pre/postinstall magic
# to set MSL up, and an upgrade is just a newer app bundle.
#
# It is NOT a data package: nothing here touches
# ~/Library/Application Support/MSL, which is where every disk image,
# instance and setting lives. Installing over an existing MSL keeps all of
# it - that is the whole upgrade story (`msl uninstall` is the other half).
#
# The one thing the postinstall does do is stop a running mslhd, because an
# upgrade otherwise leaves the OLD daemon serving the NEW `msl` - and an old
# daemon answers a command it doesn't know by closing the connection without
# a word, which looks like MSL is broken rather than out of date.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/MSL.app"
STAGE="$ROOT/dist/pkgroot"
SCRIPTS="$ROOT/dist/pkgscripts"
RESOURCES="$ROOT/dist/pkgresources"
IDENTIFIER="com.msl.app"

if [ "${1:-}" != "--skip-build" ]; then
    "$ROOT/Scripts/build-app.sh"
elif [ ! -d "$APP" ]; then
    echo "build-installer: no $APP - run without --skip-build" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
PKG="$ROOT/dist/MSL-$VERSION.pkg"
COMPONENT="$ROOT/dist/MSL-app.pkg"

echo "==> MSL $VERSION (macOS $MIN_OS or later, Apple silicon)"

# The app must still carry the virtualization entitlement when it comes out
# the other side: mslhd ships inside the bundle, and one without that
# entitlement starts fine and then fails every single VM start - a failure
# that looks nothing like a signing problem. Checked here, and again after
# the package is built, because this is the step that could silently drop it.
if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    echo "build-installer: $APP has no virtualization entitlement - it would install and then fail to start any VM" >&2
    exit 1
fi

echo "==> staging"
rm -rf "$STAGE" "$SCRIPTS" "$RESOURCES" "$COMPONENT" "$PKG"
mkdir -p "$STAGE" "$SCRIPTS" "$RESOURCES"
# -R (not -a): copy the bundle, resolving nothing, preserving the signature.
cp -R "$APP" "$STAGE/MSL.app"

cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/sh
# Runs as root, after MSL.app is in place.
#
# Only job: if this is an upgrade and the previous version's mslhd is still
# running, stop it. It is started again - from the new binaries - the next
# time the app or the `msl` command needs it. Without this, the old daemon
# keeps serving until the next login, and a newer `msl` talking to an older
# mslhd gets silence rather than an error.
#
# Everything else MSL needs belongs to the user, not to root, and the app
# installs it on first launch.
set -e

# The user being installed for, not root: LaunchAgents are per-user, and
# `launchctl bootout gui/0/...` would address root's session. During a
# fresh install from a setup assistant there may be no console user at all,
# which is not an error - there is then nothing running to stop.
CONSOLE_UID=$(stat -f %u /dev/console 2>/dev/null || echo 0)
if [ "$CONSOLE_UID" -gt 0 ]; then
    launchctl bootout "gui/$CONSOLE_UID/com.msl.mslhd" 2>/dev/null || true
fi

# `msl` on PATH, which only the installer can do: /usr/local/bin needs root,
# and this package is the one part of MSL that ever has it. Without this,
# someone who installs MSL and opens Terminal has no `msl` command until
# they have opened the app at least once - and "open the app first" is not
# something a terminal user should have to know.
#
# The link points into the app bundle, not at the copy the app installs
# under ~/Library/Application Support/MSL/bin: that way it always matches
# the version actually installed, and an upgrade can't leave it stale.
#
# Only if the target is really there: a link to nothing is worse than no
# link, because the shell finds `msl` and then can't run it.
if [ -x /Applications/MSL.app/Contents/MacOS/msl ]; then
    mkdir -p /usr/local/bin
    ln -sf /Applications/MSL.app/Contents/MacOS/msl /usr/local/bin/msl
else
    echo "MSL postinstall: /Applications/MSL.app is missing - not linking msl" >&2
fi
exit 0
POSTINSTALL
chmod +x "$SCRIPTS/postinstall"

# Installer panes. Plain HTML: the installer renders these as-is, and a
# stylesheet is not worth a second file nobody will read.
cat > "$RESOURCES/welcome.html" <<HTML
<!DOCTYPE html><html><head><style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;
       line-height: 1.55; color: #1d1d1f; margin: 0; }
h2 { font-size: 17px; margin: 0 0 8px; }
p { margin: 0 0 10px; }
.muted { color: #6e6e73; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
@media (prefers-color-scheme: dark) {
  body { color: #f5f5f7; }
  .muted { color: #a1a1a6; }
}
</style></head><body>
<h2>MSL $VERSION</h2>
<p><b>Mac Subsystem for Linux.</b> Real Linux distributions on your Mac: in a
window, in Terminal, and as ordinary Mac apps.</p>
<p>This installs <b>MSL.app</b> and the <code>msl</code> command. Everything
else - your instances, disk images and settings - lives in your home folder.</p>
<p><b>Already have MSL?</b> This replaces the app and touches nothing else, so
your Linux carries on exactly as it is.</p>
<p class="muted">Apple silicon, macOS $MIN_OS or later. This is the only time
MSL asks for an administrator password.</p>
</body></html>
HTML

cat > "$RESOURCES/conclusion.html" <<'HTML'
<!DOCTYPE html><html><head><style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;
       line-height: 1.55; color: #1d1d1f; margin: 0; }
h2 { font-size: 17px; margin: 0 0 8px; }
p { margin: 0 0 10px; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
      background: rgba(0,0,0,0.06); padding: 8px 10px; border-radius: 6px; margin: 0 0 10px; }
@media (prefers-color-scheme: dark) {
  body { color: #f5f5f7; }
  pre { background: rgba(255,255,255,0.10); }
}
</style></head><body>
<h2>MSL is installed</h2>
<p>Open <b>MSL</b> from your Applications folder, and it will offer to install
a Linux distribution.</p>
<p>Or start in Terminal - the <code>msl</code> command is ready now:</p>
<pre style="background:#f4f4f4; padding:8px; border-radius:6px;">msl install debian
msl debian</pre>
<p><b>Removing MSL later:</b> run <code>msl uninstall</code>. It removes MSL
and keeps every instance and image, so you can install it again and carry on
where you left off. <code>msl uninstall --everything</code> removes the Linux
side too, and asks first.</p>
</body></html>
HTML

if [ -f "$ROOT/Assets/License.md" ]; then
    cp "$ROOT/Assets/License.md" "$RESOURCES/license.txt"
fi

# The melon, bottom-left of every pane. Scaled here from the one canonical
# copy in Assets/ rather than checked in a second time at a second size -
# the same reason make-icon.sh derives the .icns from it.
sips -Z 160 "$ROOT/Assets/App_Logo.png" --out "$RESOURCES/background.png" >/dev/null 2>&1

echo "==> component package"
# NOT relocatable. pkgbuild marks every bundle relocatable by default, which
# tells Installer: "if an app with this bundle identifier already exists
# anywhere on the disk, install over *that* one instead." On 2026-09-16 it
# found a leftover build product with MSL's identifier -
# `.build/mslhd.app` - and installed MSL there, so /Applications/MSL.app
# never existed and /usr/local/bin/msl pointed at nothing. Any user with a
# copy of MSL in Downloads would get the same. MSL goes in /Applications.
COMPONENT_PLIST="$ROOT/dist/pkgcomponents.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "$COMPONENT_PLIST" 2>/dev/null || true
pkgbuild \
    --root "$STAGE" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location /Applications \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --scripts "$SCRIPTS" \
    "$COMPONENT" >/dev/null
rm -f "$COMPONENT_PLIST"

# The distribution wraps the component with the panes, the licence and the
# two requirements. `hostArchitectures=arm64` alone is not enough of a guard:
# it governs which architecture the installer runs as, so the explicit
# Apple-silicon check below is what actually refuses an Intel Mac, with a
# sentence that says why.
cat > "$ROOT/dist/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>MSL $VERSION</title>
    <organization>com.msl</organization>
    <options customize="never" require-scripts="false" hostArchitectures="arm64" rootVolumeOnly="true"/>
    <background file="background.png" alignment="bottomleft" scaling="none"/>
    <background-darkAqua file="background.png" alignment="bottomleft" scaling="none"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
$( [ -f "$RESOURCES/license.txt" ] && echo '    <license file="license.txt" mime-type="text/plain"/>' )
    <volume-check script="volumeCheck()"/>
    <installation-check script="installCheck()"/>
    <script><![CDATA[
function installCheck() {
    if (!system.sysctl('hw.optional.arm64')) {
        my.result.title = 'Apple silicon required';
        my.result.message = 'MSL runs Linux through Apple’s Virtualization framework on arm64, which Intel Macs do not have.';
        my.result.type = 'Fatal';
        return false;
    }
    if (system.compareVersions(system.version.ProductVersion, '$MIN_OS') < 0) {
        my.result.title = 'macOS $MIN_OS or later required';
        my.result.message = 'This Mac is running macOS ' + system.version.ProductVersion + '.';
        my.result.type = 'Fatal';
        return false;
    }
    return true;
}
function volumeCheck() {
    return true;
}
]]></script>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">MSL-app.pkg</pkg-ref>
    <choices-outline>
        <line choice="default"><line choice="$IDENTIFIER"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false" title="MSL">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
</installer-gui-script>
XML

echo "==> product package"
productbuild \
    --distribution "$ROOT/dist/distribution.xml" \
    --resources "$RESOURCES" \
    --package-path "$ROOT/dist" \
    "$PKG" >/dev/null

# MSL is signed ad-hoc (no paid Developer ID), so the package is unsigned
# too and Gatekeeper will refuse a double-click with "unidentified
# developer". Right-click > Open is the documented way in, and that is what
# the release notes have to say - printed here so it is never forgotten.
rm -rf "$STAGE" "$SCRIPTS" "$RESOURCES" "$COMPONENT" "$ROOT/dist/distribution.xml"

# The built app is only an ingredient. Left in dist/, it's a second MSL.app
# with the same bundle id: Spotlight, Launchpad and the Dock's recent apps
# then show MSL twice once the package is installed (2026-09-16). KEEP_APP=1
# keeps it, for --skip-build runs.
if [ "${KEEP_APP:-0}" != "1" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$STAGE/MSL.app" 2>/dev/null || true
    rm -rf "$APP"
fi

SIZE=$(du -h "$PKG" | cut -f1)
echo
echo "built $PKG ($SIZE)"
echo
echo "test it on this Mac:   sudo installer -pkg '$PKG' -target /"
echo "then check the entitlement survived:"
echo "    codesign -d --entitlements - --xml /Applications/MSL.app | grep virtualization"
echo
echo "GitHub release notes must say: the package is unsigned, so the first"
echo "open is Control-click > Open (or System Settings > Privacy & Security)."
