#!/bin/sh
# Boots one built image through the real MSL daemon and checks it from the
# inside - the first test that proves anything about runtime behaviour,
# because a container build proves only that files landed.
#
#   image-build/smoke-test.sh DISTRO IMAGES_DIR KERNEL_DIR
#
# Installs KERNEL_DIR's kernel/initramfs and DISTRO's image into
# ~/Library/Application Support/MSL exactly where `msl install` would (the
# image as an APFS clone, so it costs no space), registers an instance named
# after the distro, runs the checks as root over shellinit, then shuts the
# instance down and unregisters it. The installed image is left in place;
# re-running this re-installs a pristine copy first.
#
# Needs the MSL daemon running (MSL.app installs it). Prints SMOKE-PASS or
# SMOKE-FAIL as its last line and exits accordingly.
set -u

[ $# -eq 3 ] || { echo "usage: $0 DISTRO IMAGES_DIR KERNEL_DIR" >&2; exit 2; }
DISTRO=$1; IMAGES=$2; KERNEL=$3
APP_SUPPORT="$HOME/Library/Application Support/MSL"
MSL="$APP_SUPPORT/bin/msl"
[ -x "$MSL" ] || { echo "smoke-test: $MSL missing - launch MSL.app once" >&2; exit 1; }
[ -r "$IMAGES/$DISTRO.img" ] || { echo "smoke-test: no $IMAGES/$DISTRO.img" >&2; exit 1; }

# GuestDistro.diskImageFilename: Alpine keeps the original unsuffixed name.
case "$DISTRO" in alpine) disk=rootfs.img ;; *) disk="rootfs-$DISTRO.img" ;; esac

log() { echo "smoke-test[$DISTRO]: $*"; }

"$MSL" --shutdown "$DISTRO" >/dev/null 2>&1 || true
"$MSL" remove "$DISTRO" >/dev/null 2>&1 || true
cmp -s "$KERNEL/Image" "$APP_SUPPORT/disk-Image" || cp "$KERNEL/Image" "$APP_SUPPORT/disk-Image"
cmp -s "$KERNEL/initramfs" "$APP_SUPPORT/disk-initramfs-virt" || { cp "$KERNEL/initramfs" "$APP_SUPPORT/disk-initramfs-virt"; chmod 644 "$APP_SUPPORT/disk-initramfs-virt"; }
rm -f "$APP_SUPPORT/$disk"
cp -c "$IMAGES/$DISTRO.img" "$APP_SUPPORT/$disk"
log "installed $disk"

# Runs in the guest as root. POSIX sh - Alpine's is busybox ash.
checks=$(cat <<EOF
fail=0
ok()  { echo "  ok    \$1"; }
bad() { echo "  FAIL  \$1"; fail=1; }
t()   { d=\$1; shift; if "\$@" >/dev/null 2>&1; then ok "\$d"; else bad "\$d"; fi; }
running() { for p in \$(ls /proc | grep '^[0-9]'); do [ "\$(cat /proc/\$p/comm 2>/dev/null)" = "\$1" ] && return 0; done; return 1; }
. /etc/os-release
echo "  os      \$PRETTY_NAME"
echo "  kernel  \$(uname -r)"
t "root filesystem on /dev/nvme0n1" grep -q '^/dev/nvme0n1 / ' /proc/mounts
t "root mounted read-write" sh -c "awk '\\\$2 == \"/\" { print \\\$4 }' /proc/mounts | grep -q '^rw'"
if command -v systemctl >/dev/null 2>&1; then
    state=\$(systemctl is-system-running 2>/dev/null)
    [ "\$state" = running ] && ok "systemd: running" || { bad "systemd: \$state"; systemctl --failed --no-legend 2>/dev/null | sed 's/^/          /'; }
else
    t "OpenRC: default runlevel reached" sh -c 'rc-status default >/dev/null'
fi
for d in shellinit fileopsd trafficd memd; do t "\$d running" running \$d; done
t "vsock transport loaded" grep -q '^vmw_vsock_virtio_transport ' /proc/modules
t "pressure stall info (psi=1)" test -r /proc/pressure/memory
t "modules match the kernel" test -d /lib/modules/\$(uname -r)
t "modprobe works (overlay)" modprobe overlay
t "network: ping 1.1.1.1" ping -c 1 -W 5 1.1.1.1
t "DNS and HTTPS: curl example.com" curl -fsS -m 20 -o /dev/null https://example.com
t "Mac home mounted at /mnt/mac" grep -q ' /mnt/mac ' /proc/mounts
for c in sudo visudo resize2fs e2fsck cc make git curl wget zsh nano bash; do t "\$c installed" command -v \$c; done
t "compiler builds and runs a program" sh -c 'printf "int main(void){return 0;}\\n" > /tmp/msl-cc.c && cc /tmp/msl-cc.c -o /tmp/msl-cc && /tmp/msl-cc'
t "zsh is nobody's login shell" sh -c '! grep -q "/zsh\\\$" /etc/passwd'
t "msl-maintenance installed" test -x /usr/sbin/msl-maintenance
t "root password locked" sh -c 'grep "^root:" /etc/shadow | cut -d: -f2 | grep -q "^[!*]"'
t "msl account exists, password locked" sh -c 'grep "^msl:" /etc/shadow | cut -d: -f2 | grep -q "^[!*]"'
t "sudoers reads /etc/sudoers.d" sh -c 'grep -Eq "^[@#]includedir[[:space:]]+/etc/sudoers.d" /etc/sudoers /usr/etc/sudoers 2>/dev/null'
t "sshd not started at boot" sh -c '! running sshd'
t "machine-id generated on first boot" test -s /etc/machine-id
t "hostname is $DISTRO" sh -c '[ "\$(cat /proc/sys/kernel/hostname)" = "$DISTRO" ]'
echo "  disk    \$(df -h / | awk 'NR==2 { print \$3 " used of " \$2 }')"
[ \$fail = 0 ] && echo GUEST-CHECKS-PASS || echo GUEST-CHECKS-FAIL
EOF
)

log "booting and checking"
started=$(date +%s)
# msl's stdin has to stay open: an immediate EOF on it tears the session
# down before the command's output arrives. A FIFO held open by a background
# sleep does that without making this wait for the sleep - `(sleep N) | msl`
# would, because a pipeline waits for every member.
fifo=$(mktemp -u "${TMPDIR:-/tmp}/msl-smoke.XXXXXX")
mkfifo "$fifo"
sleep 600 > "$fifo" &
holder=$!
out=$("$MSL" "$DISTRO" "$checks" < "$fifo" 2>&1)
kill "$holder" 2>/dev/null
rm -f "$fifo"
echo "$out"
log "check run took $(( $(date +%s) - started ))s (including boot)"

# Checked from the Mac, because only the Mac can see it: a one-shot command
# that starts something in the background must still end. shellinit used to
# hand the session's own vsock to everything the shell ran, so a background
# process kept the session open forever - the first Linux app after every
# boot never launched (2026-09-14). The guest side of that looks perfectly
# healthy; the hang is only visible here.
fifo=$(mktemp -u "${TMPDIR:-/tmp}/msl-smoke.XXXXXX")
mkfifo "$fifo"
sleep 120 > "$fifo" &
holder=$!
bg_out=$(mktemp)
bg_started=$(date +%s)
( "$MSL" "$DISTRO" 'sleep 60 >/dev/null 2>&1 </dev/null & echo BACKGROUND-STARTED' < "$fifo" > "$bg_out" 2>&1 ) &
bg=$!
bg_ok=0
for _ in $(seq 1 20); do
    kill -0 "$bg" 2>/dev/null || { bg_ok=1; break; }
    sleep 1
done
kill "$bg" 2>/dev/null
kill "$holder" 2>/dev/null
rm -f "$fifo"
if [ "$bg_ok" = 1 ] && grep -q BACKGROUND-STARTED "$bg_out"; then
    echo "  ok    a command that starts a background process still returns ($(( $(date +%s) - bg_started ))s)"
else
    echo "  FAIL  a command that starts a background process never returned - its session's connection leaked into the process"
    bg_ok=0
fi
rm -f "$bg_out"

"$MSL" --shutdown "$DISTRO" >/dev/null 2>&1 || true
"$MSL" remove "$DISTRO" >/dev/null 2>&1 || true

case "$out" in
*GUEST-CHECKS-PASS*) [ "$bg_ok" = 1 ] && { echo SMOKE-PASS; exit 0; } ;;
esac
echo SMOKE-FAIL
exit 1
