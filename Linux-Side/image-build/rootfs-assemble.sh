#!/bin/sh
# Stage 3 of build-rootfs.sh: runs in alpine with /work/rootfs.tar (the
# exported container), /kernel (build-kernel.sh output) and /out mounted.
set -eu

log() { echo "rootfs-assemble[$DISTRO]: $*"; }

# GNU tar, not busybox: docker export records file capabilities (ping,
# newuidmap, ...) as PAX xattrs, and busybox tar drops them silently.
apk add --no-cache tar e2fsprogs kmod >/dev/null

# Staged on the container's own filesystem, never under /work or /out.
# Those are bind mounts backed by the Mac's APFS volume, and through them
# Linux cannot list extended attributes on a symlink - mke2fs -d failed on
# Debian's /usr/bin/awk -> /etc/alternatives/awk with "No such file or
# directory while listing attributes" - nor be trusted to keep ownership,
# device nodes and setuid bits exactly as the tarball recorded them.
S=/stage
rm -rf "$S"
mkdir -p "$S"
tar --xattrs --xattrs-include='*' --numeric-owner -xpf /work/rootfs.tar -C "$S"
rm -f /work/rootfs.tar

# Docker creates /.dockerenv in every container; left in place, systemd in a
# real VM detects "virtualization docker" and fails systemd-logind in a loop.
rm -f "$S/.dockerenv"

# Docker bind-mounts resolv.conf, hosts and hostname into running
# containers, so whatever the configure stage wrote there never reached the
# exported filesystem. Written here, on plain files, they stick.
# A static resolver: systemd-networkd does DHCP but only systemd-resolved
# writes DHCP nameservers into resolv.conf, and it isn't installed.
rm -f "$S/etc/resolv.conf"
echo 'nameserver 1.1.1.1' > "$S/etc/resolv.conf"
echo "$DISTRO" > "$S/etc/hostname"
cat > "$S/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
127.0.1.1   $DISTRO
EOF

grep -q 'LABEL=msl-root' "$S/etc/fstab" || { echo "rootfs-assemble: /etc/fstab has no LABEL=msl-root root entry" >&2; exit 1; }
# Every copy of a published image would share these, so an image with SSH
# host keys in it is refused. Guests generate their own on first use
# (SSHSetup's `ssh-keygen -A`, or systemd's sshd-keygen).
if ls "$S"/etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    echo "rootfs-assemble: SSH host keys are baked into the image - rootfs-configure should have removed them" >&2
    exit 1
fi
[ -s "$S/etc/machine-id" ] && { echo "rootfs-assemble: /etc/machine-id isn't empty - every instance would share it" >&2; exit 1; }

# The shared kernel's modules. On merged-/usr distros /lib is a symlink to
# usr/lib, and extracting lib/modules through it with tar would replace the
# symlink - so resolve it first.
KVER=$(cat /kernel/kernel-release)
if [ -L "$S/lib" ]; then MODROOT="$S/usr/lib/modules"; else MODROOT="$S/lib/modules"; fi
mkdir -p "$MODROOT" /tmp/modules
rm -rf "${MODROOT:?}/$KVER"
tar -xf /kernel/modules.tar -C /tmp/modules
mv "/tmp/modules/lib/modules/$KVER" "$MODROOT/$KVER"
rm -rf /tmp/modules
depmod -b "$S" "$KVER" 2>/dev/null || depmod -b "$S/usr" "$KVER"

used_kib=$(du -sk "$S" | cut -f1)
log "root filesystem content: $((used_kib / 1024)) MiB"

# Sparse file; mke2fs -d populates it straight from the staging directory,
# in userspace, with no loop mount. Label msl-root is what /etc/fstab names.
truncate -s "$IMAGE_SIZE" "/out/$DISTRO.img"
mke2fs -q -t ext4 -L msl-root -F -d "$S" "/out/$DISTRO.img"
e2fsck -fn "/out/$DISTRO.img" >/dev/null

allocated_kib=$(du -k "/out/$DISTRO.img" | cut -f1)
{
    echo "distro:        $DISTRO"
    # /etc/os-release is a symlink on some distros (Arch: -> /usr/lib/os-release).
    # Resolved inside the staged tree - followed as-is it points into *this*
    # Alpine container, and arch.info reported "Alpine Linux v3.24".
    osr="$S/etc/os-release"
    if [ -L "$osr" ]; then
        target=$(readlink "$osr")
        case "$target" in /*) osr="$S$target" ;; *) osr="$S/etc/$target" ;; esac
    fi
    echo "os-release:    $(. "$osr" && echo "${PRETTY_NAME:-$ID $VERSION_ID}")"
    echo "kernel:        $KVER"
    echo "content:       $((used_kib / 1024)) MiB"
    echo "image size:    $IMAGE_SIZE nominal, $((allocated_kib / 1024)) MiB allocated"
    echo "built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "/out/$DISTRO.info"
rm -rf "$S"
log "image written"
