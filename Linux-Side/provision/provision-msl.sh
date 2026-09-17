#!/bin/sh
# Brings a stock Linux guest up to MSL spec, from inside the guest.
#
#   ./provision-msl.sh [--skip-gui] [--skip-tooling] [--no-firstboot] [--dry-run]
#
# Run it as root in a booted guest (serial console, or `msl <instance> --`
# once shellinit is already running). It is idempotent - running it twice
# is a supported way to add a tier you skipped the first time.
#
# WHAT THIS IS NOT
# ----------------
# This does not build an image from nothing. That is the Docker-based path
# in ../bootstrap/ (`bootstrap-guest` for Alpine, `bootstrap-distro` for
# everything else, `provision-disk-image` for Alpine's OpenRC wiring), run
# on the Mac, and those remain authoritative for it. This script is for the
# other job: taking a distro image you downloaded, or one you already have,
# and making MSL work on it.
#
# The two overlap in four places - the systemd unit files, the OpenRC
# local.d scripts, the /etc/fstab root entry, and the mac_home mount. Those
# lines are identical in both, comments included, because each comment
# records a failure that was diagnosed live and is expensive to rediscover.
# If you change one, change the other. The overlap is listed in
# ../README.md under "Where this duplicates the bootstrap tools".
#
# Used for real: image-build/rootfs-configure.sh runs it (--no-firstboot)
# inside every distro's arm64 container when MSL's published images are
# built, and MSL ships it in Custom Images/_MSL Guest Kit for people making
# their own images. It has not been run inside an already-booted guest -
# the path this header originally described - so expect that one to need
# a fix the first time.

set -eu

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DAEMON_SRC="${MSL_DAEMON_SRC:-$SELF_DIR/../daemons}"
PREFIX="${PREFIX:-/usr/local}"

DO_GUI=1
DO_TOOLING=1
DO_FIRSTBOOT=1
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
    --skip-gui)      DO_GUI=0 ;;
    --skip-tooling)  DO_TOOLING=0 ;;
    --no-firstboot)  DO_FIRSTBOOT=0 ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "provision-msl: unknown option $arg" >&2; exit 2 ;;
    esac
done

log()  { echo "provision-msl: $*"; }
warn() { echo "provision-msl: WARNING: $*" >&2; }
run()  { if [ "$DRY_RUN" = 1 ]; then echo "  would run: $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || { echo "provision-msl: must run as root" >&2; exit 1; }

# ---------------------------------------------------------------- detect

# /etc/os-release's ID is the only identifier every distro here agrees on.
DISTRO=unknown
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
fi
# Nix images are a Debian base with the Nix package manager on top, so they
# identify as debian and should be treated as debian - which the package
# table already does.
case "$DISTRO" in
    linuxmint|pop|raspbian) DISTRO=ubuntu ;;
    archarm) DISTRO=arch ;;
esac

# Init system by what is actually on disk, not by distro name - an Alpine
# image with systemd or a Debian image without it are both possible, and
# guessing from the name is how you write unit files nothing will ever read.
if [ -d /run/systemd/system ] || [ -x /usr/lib/systemd/systemd ] || [ -x /lib/systemd/systemd ]; then
    INIT=systemd
elif command -v rc-update >/dev/null 2>&1; then
    INIT=openrc
else
    INIT=unknown
fi

# Package manager, again by what exists.
if   command -v apk    >/dev/null 2>&1; then PM=apk
elif command -v apt-get>/dev/null 2>&1; then PM=apt
elif command -v pacman >/dev/null 2>&1; then PM=pacman
elif command -v dnf    >/dev/null 2>&1; then PM=dnf
elif command -v zypper >/dev/null 2>&1; then PM=zypper
elif command -v xbps-install >/dev/null 2>&1; then PM=xbps
else PM=unknown
fi

log "distro=$DISTRO init=$INIT pm=$PM prefix=$PREFIX"
[ "$INIT" = unknown ] && warn "no init system recognised - the daemons will be installed but nothing will start them at boot"
[ "$PM" = unknown ] && { echo "provision-msl: no supported package manager found" >&2; exit 1; }

# ---------------------------------------------------------------- packages

pm_refresh() {
    case "$PM" in
    apk)    run apk update ;;
    apt)    DEBIAN_FRONTEND=noninteractive run apt-get update ;;
    # -Syu, not -Sy: Arch does not support partial upgrades. Refreshing the
    # database and then installing against a base image whose packages are
    # older than the repos produces file conflicts rather than an install
    # ("libstdc++: /usr/lib/libstdc++.so.6 exists in filesystem (owned by
    # gcc-libs)") - confirmed by doing exactly that in an arm64 container.
    # The full upgrade is the supported path and costs a download the
    # rebuild is making anyway.
    pacman) run pacman -Syu --noconfirm ;;
    dnf)    : ;;   # dnf refreshes per-transaction
    zypper) run zypper --non-interactive refresh ;;
    xbps)   run xbps-install -S ;;
    esac
}

pm_install() {
    [ -n "$1" ] || return 0
    # Unquoted on purpose - these are space-separated package lists.
    # shellcheck disable=SC2086
    case "$PM" in
    apk)    run apk add --no-cache $1 ;;
    apt)    DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends $1 ;;
    pacman) run pacman -S --noconfirm --needed $1 ;;
    dnf)    run dnf install -y $1 ;;
    zypper) run zypper --non-interactive install -y $1 ;;
    xbps)   run xbps-install -y $1 ;;
    esac
}

# shellcheck disable=SC1091
. "$SELF_DIR/packages.sh"
if ! msl_packages_for "$DISTRO"; then
    warn "no package list for '$DISTRO' - guessing common names; if the required tier fails, add a case to packages.sh"
fi

log "refreshing package index"
pm_refresh

log "installing required packages: $MSL_PKG_REQUIRED"
pm_install "$MSL_PKG_REQUIRED"

if [ "$DO_TOOLING" = 1 ]; then
    log "installing tooling: $MSL_PKG_TOOLING"
    # Best-effort: a missing convenience package must not abort a run whose
    # required tier already succeeded. `set -e` would otherwise leave the
    # guest half-provisioned over a package name typo.
    pm_install "$MSL_PKG_TOOLING" || warn "some tooling packages failed - check names in packages.sh for $DISTRO"
fi

if [ "$DO_GUI" = 1 ]; then
    log "installing GUI client packages: $MSL_PKG_GUI"
    pm_install "$MSL_PKG_GUI" || warn "some GUI packages failed - GUI apps may not run, but MSL itself will work"
fi

# ---------------------------------------------------------------- daemons

# Built inside the guest against the guest's own libc - musl on Alpine,
# glibc everywhere else - which is why there is no cross-compiler set up
# and no prebuilt binary shipped as the primary path. `forkpty` lives in
# libutil on glibc and in libc itself on musl; the Makefile probes for it.
log "building the three guest daemons from $DAEMON_SRC"
if [ ! -r "$DAEMON_SRC/shellinit.c" ]; then
    echo "provision-msl: no daemon sources at $DAEMON_SRC (set MSL_DAEMON_SRC)" >&2
    exit 1
fi
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
# Copy out of the source tree: it may be a read-only virtiofs mount from
# the Mac, and `make` writes its objects next to the sources.
cp "$DAEMON_SRC"/*.c "$DAEMON_SRC"/Makefile "$BUILD_DIR/" 2>/dev/null || \
    cp "$DAEMON_SRC"/*.c "$BUILD_DIR/"
if [ -r "$BUILD_DIR/Makefile" ]; then
    run make -C "$BUILD_DIR" all
    run make -C "$BUILD_DIR" install PREFIX="$PREFIX"
else
    warn "no Makefile alongside the sources - compiling by hand"
    LIBUTIL=""
    echo 'int main(void){return 0;}' > "$BUILD_DIR/.probe.c"
    cc "$BUILD_DIR/.probe.c" -lutil -o "$BUILD_DIR/.probe" 2>/dev/null && LIBUTIL="-lutil"
    run mkdir -p "$PREFIX/bin"
    # shellcheck disable=SC2086
    run cc -O2 -Wall -o "$PREFIX/bin/shellinit" "$BUILD_DIR/shellinit.c" $LIBUTIL
    run cc -O2 -Wall -o "$PREFIX/bin/fileopsd"  "$BUILD_DIR/fileopsd.c"
    run cc -O2 -Wall -o "$PREFIX/bin/x11tunnel" "$BUILD_DIR/x11tunnel.c"
    run cc -O2 -Wall -o "$PREFIX/bin/trafficd"  "$BUILD_DIR/trafficd.c"
    run cc -O2 -Wall -o "$PREFIX/bin/memd"      "$BUILD_DIR/memd.c"
fi
log "daemons installed in $PREFIX/bin"

# The maintenance script is shell, not C, so the *.c copy above never sees
# it. It goes to /usr/sbin rather than $PREFIX/bin on purpose: the host names
# this exact path twice - as the command for the Maintenance card's
# utilities, and as `init=` for a maintenance boot - so it can't move with
# PREFIX.
if [ -r "$DAEMON_SRC/msl-maintenance.sh" ]; then
    run cp "$DAEMON_SRC/msl-maintenance.sh" /usr/sbin/msl-maintenance
    run chmod 0755 /usr/sbin/msl-maintenance
    log "maintenance tools installed at /usr/sbin/msl-maintenance"
else
    warn "no msl-maintenance.sh beside the daemons - the Maintenance card's disk and utility tools won't work in this image"
fi

# ---------------------------------------------------------------- mounts

# Docker base images ship no /etc/fstab at all - confirmed live that this
# leaves root mounted read-only despite the kernel cmdline's `rw`:
# `systemd-remount-fs.service` only remounts root read-write if /etc/fstab
# has an entry for it to read mount options from (Alpine's OpenRC remounts
# unconditionally instead, which is why the same kernel/initramfs combo did
# not hit this for Alpine). Without this, shellinit's service cannot write
# its own log, let alone anything a real shell session needs to do.
#
# By LABEL, not device name. The disk was /dev/vda under virtio-blk and is
# /dev/nvme0n1 since the NVMe migration (2026-09-14); a label survives any
# future change of controller too. The image build formats the root
# filesystem with `mke2fs -L msl-root` - an image provisioned some other way
# needs `e2label <root device> msl-root` for this line to match.
if [ ! -s /etc/fstab ] || ! grep -qE '^[^#]*[[:space:]]/[[:space:]]' /etc/fstab 2>/dev/null; then
    log "adding a root entry to /etc/fstab"
    run sh -c "echo 'LABEL=msl-root / ext4 defaults 0 1' >> /etc/fstab"
fi

# The Mac home share. `mac_home` is the virtiofs tag the host attaches; the
# guest mount point is what GuestPathMapper on the host assumes, so changing
# it here means changing GuestPathMapper.macHomeMountPoint too.
run mkdir -p /mnt/mac
grep -q '^mac_home' /etc/fstab 2>/dev/null || run sh -c "echo 'mac_home /mnt/mac virtiofs defaults 0 0' >> /etc/fstab"
run ln -sfn /mnt/mac /root/mac

# ---------------------------------------------------------------- init

install_systemd() {
    log "wiring the daemons as systemd units"
    run mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/network
    for unit in shellinit fileopsd trafficd memd; do
        run cp "$SELF_DIR/init/$unit.service" "/etc/systemd/system/$unit.service"
        # Symlinked straight into multi-user.target.wants rather than
        # `systemctl enable`d: enable needs a live D-Bus connection to a
        # running systemd, which does not exist during offline provisioning
        # (and may not exist here either, if this runs in a chroot).
        run ln -sf "/etc/systemd/system/$unit.service" \
                   "/etc/systemd/system/multi-user.target.wants/$unit.service"
    done
    # Presets, because symlinks alone don't survive a first boot. Every copy
    # of an MSL image starts with an empty /etc/machine-id, and on that
    # first boot systemd re-applies unit presets to everything. Fedora and
    # the Enterprise Linux family preset `disable *`, which would switch
    # MSL's own daemons off before they ever ran; Ubuntu presets `enable *`,
    # which switched sshd on (found live - ssh.service came back enabled on
    # a rebuilt Ubuntu image despite being disabled in it). A preset in /etc
    # outranks the distro's, and 00- sorts first.
    run mkdir -p /etc/systemd/system-preset
    run sh -c 'cat > /etc/systemd/system-preset/00-msl.preset' <<'EOF'
# MSL: applied on first boot (see provision-msl.sh). MSL's guest daemons and
# networking on; sshd off until the user sets SSH up from the Mac, which
# enables it explicitly.
enable shellinit.service
enable fileopsd.service
enable trafficd.service
enable memd.service
enable systemd-networkd.service
enable nix-daemon.socket
disable ssh.service
disable sshd.service
disable ssh.socket
disable sshd.socket
EOF
    # systemd-networkd ships with systemd, just not enabled. `Name=en*`
    # matches whatever the virtio-net device gets predictable-named to
    # (confirmed live: enp0s1) without hardcoding it.
    run cp "$SELF_DIR/init/20-wired.network" /etc/systemd/network/20-wired.network
    for candidate in /usr/lib/systemd/system/systemd-networkd.service \
                     /lib/systemd/system/systemd-networkd.service; do
        [ -e "$candidate" ] || continue
        run ln -sf "$candidate" /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
        break
    done
    # systemd-networkd does DHCP but leaves /etc/resolv.conf alone - that is
    # systemd-resolved's job specifically, and it is not installed here.
    # Confirmed live: without this, resolv.conf stays empty and every DNS
    # lookup fails ("Could not resolve host") despite a working IP and route.
    # A static public resolver is simpler and more robust than wiring up
    # resolved's stub machinery for one NAT-isolated VM with one interface.
    [ -s /etc/resolv.conf ] || run sh -c "echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
}

install_openrc() {
    log "wiring shellinit + fileopsd into OpenRC's local service"
    run mkdir -p /etc/local.d
    for f in "$SELF_DIR"/init/local.d/*.start; do
        [ -e "$f" ] || continue
        run cp "$f" "/etc/local.d/$(basename "$f")"
        run chmod +x "/etc/local.d/$(basename "$f")"
    done
    # Idempotent: `rc-update add` on an already-added service warns, which
    # is harmless, but checking first keeps the log clean.
    if command -v rc-update >/dev/null 2>&1; then
        rc-update show default 2>/dev/null | grep -q local || run rc-update add local default
    fi
    [ -s /etc/resolv.conf ] || run sh -c "echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
}

case "$INIT" in
systemd) install_systemd ;;
openrc)  install_openrc ;;
*)       warn "skipping boot wiring (init=$INIT) - start the daemons by hand: $PREFIX/bin/shellinit & $PREFIX/bin/fileopsd &" ;;
esac

# x11tunnel is deliberately NOT started at boot. The host starts it on
# demand, per display, and tracks it by pidfile
# (/tmp/x11tunnel-<display>-<port>.pid). GUI support stays opt-in.

# ---------------------------------------------------------------- users

# A default unprivileged user, matching WSL's "you get a real non-root
# user, not just root" expectation - `msl <instance> -u msl` (see
# shellinit.c's privilege drop). Passwordless like root's own account: msl
# never authenticates through either of them, it connects straight to
# shellinit over vsock, so the only thing a password affects is the console
# getty, which exists for our own debugging.
#
# The first-boot wizard sets this account up rather than creating another
# one - renaming or replacing the account whose shell you are currently
# running inside is a bad time.
if ! id msl >/dev/null 2>&1; then
    log "creating the default unprivileged user 'msl'"
    if command -v useradd >/dev/null 2>&1; then
        run useradd -m -s /bin/bash msl
    else
        run adduser -D -s /bin/bash -h /home/msl msl   # busybox (Alpine)
    fi
    # No usable password rather than an empty one: an empty password would
    # let any local user `su msl` without one. shellinit's privilege drop
    # needs no password.
    #
    # `*`, not `passwd -l`'s `!`. OpenSSH built without PAM (Alpine's) reads
    # a leading `!` as a locked account and refuses even key logins, so
    # `msl ssh` failed on Alpine alone (2026-09-14). `*` matches no password
    # either, and isn't "locked". sed because busybox has no usermod.
    run sed -i 's/^msl:[^:]*:/msl:*:/' /etc/shadow
fi

# ---------------------------------------------------------------- firstboot

if [ "$DO_FIRSTBOOT" = 1 ]; then
    log "installing the first-boot setup wizard"
    run mkdir -p /var/lib/msl "$PREFIX/bin" /etc/profile.d
    run cp "$SELF_DIR/firstboot/msl-firstboot.sh" "$PREFIX/bin/msl-firstboot"
    run chmod +x "$PREFIX/bin/msl-firstboot"
    # 00- prefix: it should greet before anything else in profile.d prints.
    run cp "$SELF_DIR/firstboot/profile-hook.sh" /etc/profile.d/00-msl-firstboot.sh
    run chmod 0644 /etc/profile.d/00-msl-firstboot.sh
    # Removing the sentinel is how you re-arm the wizard for testing.
    run rm -f /var/lib/msl/setup-done
fi

# ---------------------------------------------------------------- verify

if [ "$DRY_RUN" = 1 ]; then
    log "dry run - nothing was changed, so there is nothing to verify"
    exit 0
fi

log "verifying"
FAIL=0
for b in shellinit fileopsd x11tunnel trafficd memd; do
    if [ -x "$PREFIX/bin/$b" ]; then echo "  ok      $PREFIX/bin/$b"
    else echo "  MISSING $PREFIX/bin/$b"; FAIL=1; fi
done
check() {  # check <description> <failure hint>; the test itself is $3...
    _desc="$1"; _hint="$2"; shift 2
    if "$@" >/dev/null 2>&1; then echo "  ok      $_desc"
    else echo "  MISSING $_desc${_hint:+ ($_hint)}"; FAIL=1; fi
}
check resize2fs "growable disks will not work" command -v resize2fs
check modprobe  "the vsock module cannot be loaded" command -v modprobe
check /bin/bash "shellinit execs it"                test -x /bin/bash
check sudo      "the account MSL creates can't use sudo" command -v sudo
check visudo    "MSL can't check its sudoers drop-in"    command -v visudo
# openSUSE Leap 16 keeps its sudoers in /usr/etc (with /etc/sudoers as an
# optional override), and that file is what includes /etc/sudoers.d.
check "sudoers reads /etc/sudoers.d" "MSL's admin-group rule would be ignored" \
                sh -c "grep -Eqs '^[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers /usr/etc/sudoers"
check /usr/sbin/msl-maintenance "the Maintenance card's tools won't work" \
                                                    test -x /usr/sbin/msl-maintenance
check e2fsck    "a maintenance boot can't check the disk"  command -v e2fsck
case "$INIT" in
systemd) check "shellinit.service enabled" "" \
               test -L /etc/systemd/system/multi-user.target.wants/shellinit.service
         # Fedora, openSUSE and the Enterprise Linux family package networkd
         # separately; without it the guest boots with its NIC down.
         check "systemd-networkd installed" "the guest will have no network" \
               sh -c 'test -x /usr/lib/systemd/systemd-networkd || test -x /lib/systemd/systemd-networkd' ;;
openrc)  check "/etc/local.d/shellinit.start" "" \
               test -x /etc/local.d/shellinit.start ;;
esac
# zsh must be present and must NOT be anyone's login shell.
if command -v zsh >/dev/null 2>&1; then
    if grep -q ':/[^:]*/zsh$' /etc/passwd 2>/dev/null; then
        echo "  WARN    zsh is someone's login shell - the image should ship with the distro default"
    else
        echo "  ok      zsh installed, not the login shell"
    fi
fi

if [ "$FAIL" = 0 ]; then
    log "done. Reboot, then check from the Mac: msl <instance> -- echo hello"
else
    log "done WITH GAPS (see MISSING above)"
    exit 1
fi
