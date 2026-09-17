#!/bin/sh
# The Linux-account half of the SG test matrix (READMES/03-SG-LINUX-ACCOUNTS.md),
# through the real `msl` first-start prompt.
#
#   image-build/smoke-account.sh DISTRO IMAGES_DIR
#
# Installs a pristine copy of DISTRO's image (so the account is created on a
# fresh disk), forgets any remembered default user for the distro, creates
# `msltest` through the prompt, and checks: the account is the login, it is
# in the admin group, sudo works *with* its password, refuses without one,
# rejects a wrong one, the password hash isn't DES, and sudoers is valid.
# Afterwards the instance is shut down and unregistered, the remembered user
# is forgotten again, and a pristine image is reinstalled - so no test
# account is left behind for real use.
set -u

[ $# -eq 2 ] || { echo "usage: $0 DISTRO IMAGES_DIR" >&2; exit 2; }
DISTRO=$1; IMAGES=$2
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
APP_SUPPORT="$HOME/Library/Application Support/MSL"
MSL="$APP_SUPPORT/bin/msl"
REGISTRY="$APP_SUPPORT/default-users.json"
case "$DISTRO" in alpine) disk=rootfs.img ;; *) disk="rootfs-$DISTRO.img" ;; esac

forget_user() {
    [ -f "$REGISTRY" ] || return 0
    /usr/bin/python3 - "$REGISTRY" "$DISTRO" <<'PY'
import json, sys
path, distro = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data.pop(distro, None)
with open(path, "w") as f:
    json.dump(data, f)
PY
}

reset_instance() {
    "$MSL" --shutdown "$DISTRO" >/dev/null 2>&1 || true
    "$MSL" remove "$DISTRO" >/dev/null 2>&1 || true
    forget_user
    rm -f "$APP_SUPPORT/$disk"
    cp -c "$IMAGES/$DISTRO.img" "$APP_SUPPORT/$disk"
}

reset_instance
out=$(/usr/bin/expect -f "$HERE/smoke-account.exp" "$MSL" "$DISTRO" msltest 'Correct-Horse-9 $pace' 2>&1)
echo "$out" | tr -d '\r' | grep -E '^(WHOAMI|GROUPS|HASH|SUDOERS_D)=|OK-|BAD-|ACCOUNT-' | sed 's/^/  /'
reset_instance

fail=0
# Only lines the guest *printed*: the terminal also echoes the typed command,
# which contains every marker name, so an unanchored grep matched its own
# question. Escape sequences some distros put before output (Arch's sudo
# marks sessions with OSC 3008) are stripped first - with perl, not sed:
# macOS's sed doesn't understand \x1b, so the old sed line stripped nothing,
# and Arch passed only when its closing OSC happened to land on another line.
printed=$(echo "$out" | tr -d '\r' | perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-9;?]*[A-Za-z]//g')
for marker in OK-SUDO-WITH-PASSWORD OK-SUDO-NEEDS-PASSWORD OK-WRONG-PASSWORD-REJECTED OK-VISUDO ACCOUNT-CHECKS-DONE; do
    echo "$printed" | grep -q "^$marker\$" || { echo "  missing: $marker"; fail=1; }
done
echo "$printed" | grep -q '^BAD-' && fail=1
out=$printed
echo "$out" | tr -d '\r' | grep -q '^WHOAMI=msltest$' || { echo "  the login isn't msltest"; fail=1; }
echo "$out" | tr -d '\r' | grep -Eq '^GROUPS=.*\b(sudo|wheel)\b' || { echo "  msltest isn't in sudo or wheel"; fail=1; }
echo "$out" | tr -d '\r' | grep -Eq '^HASH=\$' || { echo "  the password hash isn't a modern crypt format (DES truncates at 8 characters)"; fail=1; }

if [ "$fail" = 0 ]; then echo ACCOUNT-PASS; exit 0; else echo ACCOUNT-FAIL; exit 1; fi
