#!/bin/sh
# Per-distro package names for `provision-msl.sh`. Sourced, not executed.
#
# Split into three tiers on purpose - the first is the difference between a
# working MSL guest and a brick, the other two are convenience. When
# bandwidth is short in SG, install REQUIRED everywhere first and come back
# for the rest.
#
# Package *names* differ per distro far more than package *contents* do;
# that is the only reason this file is a case statement rather than a list.

# --- Tier 1: REQUIRED. MSL does not work without these. ------------------
#   build tools : the three daemons are compiled inside the guest (no
#                 cross-compiler is set up), so a compiler is not optional
#                 unless you are copying in prebuilt binaries.
#   e2fsprogs   : `resize2fs` - the host can grow the disk image, but only
#                 this makes the filesystem use the new space. Without it
#                 MSL enlarges the disk and the guest never sees the room.
#   kmod        : `modprobe vmw_vsock_virtio_transport`. Debian/Ubuntu
#                 Docker bases ship no kernel package at all.
#   bash        : shellinit execs /bin/bash for real bash semantics (job
#                 control, [[ ]], arrays). Alpine ships busybox ash only.
#   sudo        : the account MSL creates on first start joins the admin
#                 group and uses sudo with its own password. MSL installs
#                 sudo then if it has to, but that needs the network at that
#                 exact moment - baked in, it just works offline.
#   kernel UAPI : all three daemons #include <linux/vm_sockets.h>. On glibc
#                 distros libc6-dev/glibc-devel drags it in; on Alpine
#                 musl-dev does NOT, and the build fails with "fatal error:
#                 linux/vm_sockets.h: No such file or directory". Confirmed
#                 by actually running this script in an arm64 container -
#                 `linux-headers` is the package, and it is required, not
#                 nice-to-have.
#
# --- Tier 2: TOOLING. The point of the rebuild. --------------------------
#   git, wget, curl, zsh (installed, NOT the login shell - see below), gcc,
#   and an SSH server. The server is installed but NOT configured here: the
#   host does that per-instance (SSHSetup), because the key it installs is
#   generated on the Mac and there is no sensible key to bake into a shared
#   image. Package names differ more than usual - `openssh` on Alpine/Arch,
#   `openssh-server` on Debian/Fedora.
#
# --- Tier 3: GUI. Needed only to run Linux apps through mslgd. -----------
#   libx11 + xterm is the minimum that proves the tunnel end to end.

msl_packages_for() {
    case "$1" in
    alpine)
        MSL_PKG_REQUIRED="gcc musl-dev linux-headers make e2fsprogs e2fsprogs-extra kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano openssh"
        MSL_PKG_GUI="libx11 libxext xterm xauth"
        ;;
    debian|ubuntu|kali|nix)
        # `nix` here is the Nix package manager on a Debian base, not NixOS.
        MSL_PKG_REQUIRED="build-essential e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano ca-certificates openssh-server"
        MSL_PKG_GUI="libx11-6 libxext6 xterm xauth"
        ;;
    arch)
        MSL_PKG_REQUIRED="base-devel linux-api-headers e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano openssh"
        MSL_PKG_GUI="libx11 libxext xterm xorg-xauth"
        ;;
    fedora)
        # Fedora 44 has no `wget` package: wget2 replaced it, and
        # wget2-wget provides the /usr/bin/wget command.
        MSL_PKG_REQUIRED="gcc make glibc-devel kernel-headers e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget2-wget curl zsh nano openssh-server"
        MSL_PKG_GUI="libX11 libXext xterm xorg-x11-xauth"
        ;;
    rocky|almalinux|alma|centos|ol|oracle)
        # os-release IDs: rocky, almalinux, centos (Stream), ol (Oracle).
        # All four checked against their 10.x repositories on 2026-09-14.
        MSL_PKG_REQUIRED="gcc make glibc-devel kernel-headers e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano openssh-server"
        MSL_PKG_GUI="libX11 libXext xterm xorg-x11-xauth"
        ;;
    opensuse*)
        # sudo-policy-wheel-auth-self: openSUSE's stock sudoers has
        # `Defaults targetpw` - sudo asks for the *target's* (root's)
        # password - which defeats an admin account that authenticates with
        # its own. This is SUSE's own package for the other policy: members
        # of wheel use their own password. It also creates the wheel group,
        # which Leap 16 doesn't have by default.
        MSL_PKG_REQUIRED="gcc make glibc-devel linux-glibc-devel e2fsprogs kmod bash sudo sudo-policy-wheel-auth-self"
        MSL_PKG_TOOLING="git wget curl zsh nano openssh"
        MSL_PKG_GUI="libX11-6 libXext6 xterm xauth"
        ;;
    void)
        MSL_PKG_REQUIRED="gcc make e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano openssh"
        MSL_PKG_GUI="libX11 libXext xterm xauth"
        ;;
    *)
        # Unknown distro: guess the most common spelling and let the
        # installer fail loudly rather than silently skipping the required
        # tier. Add a real case above once it is confirmed.
        MSL_PKG_REQUIRED="gcc make e2fsprogs kmod bash sudo"
        MSL_PKG_TOOLING="git wget curl zsh nano"
        MSL_PKG_GUI="xterm"
        return 1
        ;;
    esac
    return 0
}

# `zsh` is deliberately in TOOLING and deliberately never passed to `chsh`.
# It is there for macOS muscle memory; the login shell stays the distro
# default. "Install zsh" and "switch to zsh" are one command apart and only
# one of them is wanted - see the first-boot wizard, which offers the switch
# as an explicit, per-user choice instead of baking it into the image.
