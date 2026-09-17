#!/bin/sh
# Stage 1 of build-rootfs.sh: runs as root INSIDE the distro's own container,
# with Actual-Project/ mounted read-only at /proj.
#
# Installs the init system and the handful of things a booted machine needs
# that a container image leaves out, then hands over to provision-msl.sh -
# the same script, same flags, that would provision an already-booted guest.
# Everything distro-specific about *MSL* lives there and in packages.sh; this
# file only knows how to turn a container into something that can boot.
set -eu

log() { echo "rootfs-configure[$DISTRO]: $*"; }

case "$DISTRO" in
debian|ubuntu|kali|nix)
    log "apt: init system and base"
    apt-get update
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv udev dbus kmod iproute2 iputils-ping procps \
        ca-certificates less
    ;;
fedora|rocky|alma|centos|oracle)
    # systemd-networkd is a separate package here, and without it nothing
    # configures the NIC: every one of these booted with enp0s1 DOWN. Fedora
    # has it in its own repositories; the Enterprise Linux family only in
    # EPEL, which is also what most people add to these distros first.
    case "$DISTRO" in
    rocky|alma|centos)
        log "enabling EPEL"
        dnf install -y epel-release ;;
    oracle)
        log "enabling EPEL"
        dnf install -y oracle-epel-release-el10 ;;
    esac
    log "dnf: init system and base"
    dnf install -y --setopt=install_weak_deps=False \
        systemd systemd-udev systemd-networkd dbus-broker kmod iproute iputils procps-ng \
        ca-certificates less shadow-utils util-linux hostname findutils
    ;;
opensuse)
    log "zypper: init system and base"
    zypper --non-interactive refresh
    # Leap 16 has no systemd-sysvinit/-sysvcompat package; /sbin/init is
    # created below, for every systemd distro that lacks one.
    zypper --non-interactive install --no-recommends \
        systemd systemd-networkd udev dbus-1 kmod iproute2 iputils procps \
        ca-certificates less shadow util-linux findutils
    ;;
arch)
    log "pacman: full upgrade, init system and base"
    # -Syu, never -Sy: Arch does not support partial upgrades (see
    # provision-msl.sh's pm_refresh).
    pacman -Syu --noconfirm --needed systemd kmod dbus iproute2 iputils procps-ng less
    ;;
alpine)
    log "apk: OpenRC and base"
    apk add --no-cache alpine-base openrc busybox-openrc busybox-mdev-openrc \
        kmod e2fsprogs iproute2 ca-certificates less
    ;;
*)
    echo "rootfs-configure: no base recipe for '$DISTRO'" >&2
    exit 1 ;;
esac

# Container images mask units that make no sense in a container but that a
# real boot needs. AlmaLinux's masks systemd-remount-fs (so root stayed
# read-only), systemd-logind (so `poweroff` failed: "Could not activate
# remote peer 'org.freedesktop.login1'"), getty.target, console-getty,
# dev-hugepages.mount and sys-fs-fuse-connections.mount. A mask is a
# symlink to /dev/null in /etc; removing it restores the distro's own unit.
if [ -d /etc/systemd/system ]; then
    find /etc/systemd/system -type l | while read -r unit; do
        [ "$(readlink "$unit")" = /dev/null ] || continue
        log "unmasking $(basename "$unit") (masked by the container image)"
        rm -f "$unit"
    done
fi

# The initramfs hands over to /sbin/init. Most systemd distros ship it as a
# symlink (systemd-sysv, systemd-sysvinit); a container image may not have
# it at all - openSUSE Leap 16's doesn't - and without it the boot ends at
# "No working init found".
if [ "$DISTRO" != alpine ] && [ ! -e /sbin/init ]; then
    for systemd in /usr/lib/systemd/systemd /lib/systemd/systemd; do
        [ -x "$systemd" ] || continue
        log "no /sbin/init - linking it to $systemd"
        ln -s "$systemd" /sbin/init
        break
    done
    [ -e /sbin/init ] || { echo "rootfs-configure: no /sbin/init and no systemd binary" >&2; exit 1; }
fi

if [ "$DISTRO" = nix ]; then
    log "installing Nix (daemon mode)"
    apt-get install -y --no-install-recommends curl xz-utils
    # Downloaded to a file with -f, never `curl | sh`: a failed fetch piped
    # into sh is an empty script, which "succeeds" and leaves Nix silently
    # not installed (found the hard way in bootstrap-distro).
    curl -fsSL -o /tmp/nix-install.sh https://nixos.org/nix/install
    sh /tmp/nix-install.sh --daemon --yes
    rm -f /tmp/nix-install.sh
    # The installer skips systemd wiring when there is no running systemd to
    # detect. The unit has to live in a search path, then be enabled by a
    # .wants/ symlink pointing at that copy (a symlink straight into /nix is
    # invisible to systemd).
    cp /nix/var/nix/profiles/default/lib/systemd/system/nix-daemon.socket /etc/systemd/system/
    cp /nix/var/nix/profiles/default/lib/systemd/system/nix-daemon.service /etc/systemd/system/
    mkdir -p /etc/systemd/system/sockets.target.wants
    ln -sf /etc/systemd/system/nix-daemon.socket /etc/systemd/system/sockets.target.wants/nix-daemon.socket
fi

if [ "$DISTRO" = alpine ]; then
    # A container's Alpine has no runlevels populated - a real install's
    # setup-alpine would. These are the services a minimal VM boot needs;
    # `local` runs the MSL daemons (provision-msl.sh adds it).
    for s in devfs dmesg mdev hwdrivers; do rc-update add "$s" sysinit; done
    # swclock, not hwclock: the VM has no RTC, so hwclock fails at boot and
    # again at shutdown ("can't open /dev/misc/rtc"). swclock provides the
    # same "clock" dependency from a saved timestamp, and the host sets the
    # real time as soon as the guest is up. machine-id: OpenRC doesn't make
    # one by itself, and an empty /etc/machine-id is what every copy of the
    # image starts with.
    for s in modules sysctl hostname bootmisc syslog swclock machine-id; do rc-update add "$s" boot; done
    for s in mount-ro killprocs savecache; do rc-update add "$s" shutdown; done
    # A console login on hvc0, for debugging only (msl never logs in here).
    # The stock tty1-6 gettys are removed: there are no virtual terminals.
    sed -i '/^tty[0-9]::respawn:/d' /etc/inittab
    grep -q '^hvc0' /etc/inittab || echo 'hvc0::respawn:/sbin/getty -L 0 hvc0 vt100' >> /etc/inittab
fi

log "provisioning MSL"
# --no-firstboot: the host now creates the user's real account on first
# start (LinuxUserSetup - username, password, admin group). The in-guest
# wizard configured the built-in `msl` account instead, and would only ever
# fire under `msl <instance> -u root`, asking about the wrong account.
sh /proj/Linux-Side/provision/provision-msl.sh --no-firstboot

# Root's password is locked, not empty. msl reaches root through shellinit
# over vsock and never authenticates, so nothing MSL does needs one - and an
# *empty* root password (what `passwd -d` gave earlier images) lets any
# local user `su` straight to root on distros whose PAM allows nullok,
# which undoes the point of an admin account whose sudo asks for a
# password. Locked, the hvc0 console can't log in as root either; debug
# with `msl <instance> -u root` instead.
passwd -l root >/dev/null 2>&1 || usermod -p '!' root

# sshd is installed but not started at boot. The image deliberately carries
# no host keys (see the end of this script), and sshd refuses to start
# without them - Debian's ssh.service failed on every boot until this.
# SSHSetup generates the keys and enables sshd when the user sets SSH up.
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable ssh.service sshd.service ssh.socket sshd.socket >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/multi-user.target.wants/ssh.service \
          /etc/systemd/system/multi-user.target.wants/sshd.service \
          /etc/systemd/system/sshd.service
fi
[ "$DISTRO" = alpine ] && rc-update del sshd default >/dev/null 2>&1 || true

log "shrinking"
case "$DISTRO" in
debian|ubuntu|kali|nix)
    apt-get clean
    rm -rf /var/lib/apt/lists/* ;;
fedora|rocky|alma|centos|oracle)
    dnf clean all
    rm -rf /var/cache/dnf /var/cache/libdnf5 /var/lib/dnf/repos ;;
opensuse)
    zypper --non-interactive clean --all ;;
arch)
    pacman -Scc --noconfirm >/dev/null 2>&1 || true
    rm -rf /var/cache/pacman/pkg/* ;;
alpine)
    rm -rf /var/cache/apk/* ;;
esac
if [ "$DISTRO" = nix ]; then
    /nix/var/nix/profiles/default/bin/nix-collect-garbage >/dev/null 2>&1 || true
fi
# Documentation and translations are the largest thing in most of these
# images that nothing depends on. Manual pages stay - `man` is something
# people reach for inside a terminal - and so do copyright notices.
find /usr/share/doc -mindepth 1 -maxdepth 1 -type d -exec sh -c '
    for d; do find "$d" -mindepth 1 ! -name "copyright*" ! -name "LICENSE*" -delete 2>/dev/null || true; done' sh {} + 2>/dev/null || true
rm -rf /usr/share/info/* /usr/share/gtk-doc/* /usr/share/help/* 2>/dev/null || true
if [ -d /usr/share/locale ]; then
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'C*' -exec rm -rf {} + 2>/dev/null || true
fi
rm -rf /var/log/* /var/tmp/* /tmp/* /root/.cache /var/cache/man 2>/dev/null || true
# Per-machine identity must be generated on each instance's first boot, not
# shared by every copy of the image:
#  - an empty machine-id tells systemd to generate one;
#  - SSH host keys are made by SSHSetup (`ssh-keygen -A`) when SSH is set up.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id /etc/ssh/ssh_host_*
log "configured"
