import Foundation
import MSLCore

/*
 * provision-disk-image
 *
 * One-off tool that turns a freshly bootstrapped `rootfs.img`
 * (`bootstrap-guest`'s output - a real ext4 Alpine root, but with no
 * `shellinit`/`fileopsd` installed and no boot files pulled out for
 * `mslhd`'s `.persistentDisk` mode) into something `mslhd` can actually
 * boot.
 * Automates every step that was done by hand against a real running disk
 * this session - see README's "Guest boot strategy" for the two non-obvious
 * fixes this bakes in (`rootfstype=ext4` is handled on mslhd's side, but
 * the `vmw_vsock_virtio_transport` modprobe has to live *on the disk*,
 * since nothing else in a normal Alpine boot ever triggers it).
 *
 * macOS has no native ext4 driver, so this shells out to OrbStack/Docker
 * (already a project dependency for this exact reason) to loop-mount
 * `rootfs.img` read-write from a throwaway Linux container - the same
 * technique used manually via `docker run --privileged ... mount -o loop`
 * during development, just scripted instead of typed by hand each time.
 *
 * Not part of mslhd's runtime path - run it once per fresh `rootfs.img`
 * (or after re-running `build-shellinit`). Unlike the other one-off tools
 * here, this one never touches `Virtualization.framework` (all the real
 * work happens inside a Docker container), so it needs no entitlement or
 * codesign step:
 *
 *     swift build -c release --product provision-disk-image
 *     .build/release/provision-disk-image
 *
 * Requires `bootstrap-guest` (for rootfs.img) and `build-shellinit` (for
 * the precompiled shellinit binary) to have already been run, and OrbStack
 * (or another Docker Desktop-compatible engine) running.
 */

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProvisionError.commandFailed("\(executable) \(arguments.joined(separator: " "))", process.terminationStatus)
    }
}

enum ProvisionError: Error, CustomStringConvertible {
    case missingInput(String)
    case commandFailed(String, Int32)

    var description: String {
        switch self {
        case .missingInput(let what): return "missing required input: \(what)"
        case .commandFailed(let command, let status): return "command failed (exit \(status)): \(command)"
        }
    }
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MSL", isDirectory: true)

let rootfsURL = appSupport.appendingPathComponent("rootfs.img")
let shellinitBinURL = appSupport.appendingPathComponent("bin/shellinit")
let fileopsdBinURL = appSupport.appendingPathComponent("bin/fileopsd")
let diskKernelURL = appSupport.appendingPathComponent("disk-Image")
let diskInitrdURL = appSupport.appendingPathComponent("disk-initramfs-virt")

guard FileManager.default.fileExists(atPath: rootfsURL.path) else {
    throw ProvisionError.missingInput("\(rootfsURL.path) - run bootstrap-guest first")
}
guard FileManager.default.fileExists(atPath: shellinitBinURL.path),
      FileManager.default.fileExists(atPath: fileopsdBinURL.path) else {
    throw ProvisionError.missingInput("\(shellinitBinURL.path) / \(fileopsdBinURL.path) - run build-shellinit first")
}

let tmpDir = appSupport.appendingPathComponent(".provision-disk-image-tmp", isDirectory: true)
try? FileManager.default.removeItem(at: tmpDir)
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }

// Everything that needs write access to rootfs.img's ext4 filesystem
// happens inside one throwaway privileged container: install shellinit,
// wire it into OpenRC's `local` service (idempotently - `rc-update add`
// on an already-added service prints a warning but that's fine either
// way), bake in the vsock transport modprobe fix, and copy the boot files
// out to a bind-mounted host directory. `chroot`ing into /mnt/root runs
// *the target disk's own* rc-update/openrc binaries, not anything from the
// throwaway alpine:latest container - it doesn't need openrc installed
// itself.
// NOTE: the local.d scripts below are duplicated - deliberately, comments
// and all - in ../../../Linux-Side/provision/init/local.d/, used by
// provision-msl.sh to wire an existing image rather than build one. If you
// change one, change the other. See Linux-Side/README.md.
let guestScript = """
set -e
mkdir -p /mnt/root
# -t ext4 is required, not optional - confirmed live: plain `mount -o loop`
# (no explicit type) fails outright in this container image with "mount:
# mounting /dev/loop0 on /mnt/root failed: Invalid argument", even though
# the image is a genuine ext4 filesystem (confirmed via blkid). alpine:
# latest's busybox mount doesn't do the libblkid-backed type
# autodetection a full util-linux mount would - it needs telling.
mount -t ext4 -o loop /rootfs.img /mnt/root
# The disk's own /etc/fstab never had a root ("/") entry at all (confirmed
# live) - unlike Debian/Ubuntu/Arch's systemd-remount-fs.service, which at
# least LOOKS at fstab for this, this minimal Alpine install never enabled
# any of the standard "boot" runlevel services (checkfs/fsck/mount-ro
# etc.) that would normally remount root rw, so it silently stayed
# read-only through every boot - masked until now because every prior
# write we did at runtime went to the separate mac_home virtiofs mount,
# never to the root fs itself. `fileopsd` writing real guest paths (e.g.
# /root/...) surfaced it immediately ("Read-only file system", errno 30).
# Fixed the same explicit way as the mac_home mount itself: don't rely on
# assumed distro machinery, just do it - a local.d script sorting before
# every other one here (00- prefix) remounts rw unconditionally.
cat > /mnt/root/etc/local.d/00-remount-root.start <<'EOF'
#!/bin/sh
mount -o remount,rw /
EOF
chmod +x /mnt/root/etc/local.d/00-remount-root.start
# `mdev` (busybox's device manager, what this minimal Alpine install uses
# instead of udev) repopulates /dev fresh every boot from its own
# defaults, not anything persisted on disk - confirmed live that it was
# creating /dev/null (and its siblings) as `crw-rw---- root:root` instead
# of the standard `crw-rw-rw-`, silently breaking basic stdio redirection
# (`</dev/null`, `>/dev/null`) for any non-root process - which includes
# the unprivileged `msl` user this project explicitly supports (`msl
# <instance> -u msl`). A static `chmod` on the disk image's own /dev
# entries wouldn't survive mdev's next re-populate, so this has to run at
# boot too, same as the rw-remount above (00-prefixed - needs to win the
# race against anything else in local.d that might touch these devices).
cat > /mnt/root/etc/local.d/00b-fix-dev-perms.start <<'EOF'
#!/bin/sh
chmod 666 /dev/null /dev/zero /dev/full /dev/random /dev/urandom /dev/tty /dev/ptmx 2>/dev/null
EOF
chmod +x /mnt/root/etc/local.d/00b-fix-dev-perms.start
cp /host-bin/shellinit /mnt/root/usr/local/bin/shellinit
chmod +x /mnt/root/usr/local/bin/shellinit
cp /host-bin/fileopsd /mnt/root/usr/local/bin/fileopsd
chmod +x /mnt/root/usr/local/bin/fileopsd
# Ultra-experimental (see the archived msl-vgpu.md design's Phase 1) - the
# binary is installed but deliberately has NO local.d/OpenRC service of
# its own, unlike shellinit/fileopsd above: GUI support stays fully
# opt-in, started on demand by `msl gui <instance>` (which runs it as a
# background one-shot command over the existing shell channel), not at
# every boot. `libx11`/`xterm` are the minimal client-side pieces needed
# to prove the tunnel end to end - X11 core fonts are served by whatever
# X server is on the *other* end (XQuartz, host-side), not needed here.
cp /host-bin/x11tunnel /mnt/root/usr/local/bin/x11tunnel
chmod +x /mnt/root/usr/local/bin/x11tunnel
# The target disk's own /etc/resolv.conf is only ever populated at real
# boot time (network-up.start's udhcpc, below) - this chroot has no
# kernel/DHCP of its own, so `apk add` here would have no DNS without an
# explicit resolver. Same fix bootstrap-distro's populateScript already
# uses for the same reason.
echo 'nameserver 1.1.1.1' > /mnt/root/etc/resolv.conf
# libx11/xterm live in the `community` repo, not `main`. Written from
# scratch rather than patched - confirmed live that the disk's own
# /etc/apk/repositories is actually EMPTY (`cat` on it produced nothing),
# not just missing `community`: whatever `bootstrap-guest` did to install
# packages during the disk's original bootstrap apparently never relied on
# this file (probably passed `--repository` directly per invocation), so
# there was nothing in it to patch in the first place.
cat > /mnt/root/etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
EOF
# `|| true` on both, NOT bare - confirmed live that a disk with a corrupted
# apk database (e.g. after the ext4 write-back coherency issue noted below
# actually hits) fails these with "Unable to read database: No such file
# or directory" / "Failed to open apk database" - and under this whole
# script's `set -e`, an uncaught failure HERE aborts before ever reaching
# the sync/umount at the bottom. That's the worse problem: it leaves this
# throwaway container's loop-mounted ext4 view torn down uncleanly by
# `docker run --rm` (no umount, no sync) right after the shellinit/
# fileopsd/x11tunnel copies above - a textbook way to hand ext4 a torn
# write and manufacture exactly the "mounting fs with errors" corruption
# this file's own trailing comment already worries about, on a disk that
# didn't actually have it yet. libx11/xterm are best-effort convenience
# packages (most test flows already have them from an earlier successful
# provision) - never worth risking the critical binary installs over.
if ! chroot /mnt/root apk update; then
    echo "provision-disk-image: apk update failed - attempting a one-shot db repair (missing /lib/apk/db/installed is the common case for 'Unable to read database')"
    mkdir -p /mnt/root/lib/apk/db
    [ -f /mnt/root/lib/apk/db/installed ] || : > /mnt/root/lib/apk/db/installed
    chroot /mnt/root apk update || echo "provision-disk-image: apk update still failing after repair attempt (continuing - see comment above)"
fi
chroot /mnt/root apk add --no-cache libx11 xterm || echo "provision-disk-image: apk add failed (continuing - see comment above)"
cat > /mnt/root/etc/local.d/shellinit.start <<'EOF'
#!/bin/sh
modprobe vmw_vsock_virtio_transport 2>/dev/null
# No `export HOME=/root` here (there used to be one) - shellinit now sets
# HOME/USER/LOGNAME/SHELL itself per-session, based on whichever user the
# EXEC frame actually resolves to (root by default, see `msl -u`) - see
# shellinit.c. A blanket root-only value baked into this script would be
# wrong for any other user.
exec /usr/local/bin/shellinit &
EOF
chmod +x /mnt/root/etc/local.d/shellinit.start
cat > /mnt/root/etc/local.d/fileopsd.start <<'EOF'
#!/bin/sh
modprobe vmw_vsock_virtio_transport 2>/dev/null
exec /usr/local/bin/fileopsd &
EOF
chmod +x /mnt/root/etc/local.d/fileopsd.start
chroot /mnt/root /sbin/rc-update show default | grep -q local || chroot /mnt/root /sbin/rc-update add local default
# A default unprivileged user (`msl`), matching WSL's own "you get a real
# non-root user, not just root" expectation - `msl <instance> -u msl` (see
# shellinit.c's privilege-drop). Alpine's busybox `adduser` (not the
# `useradd` every other distro here uses), `-D` for a locked/no password,
# same reasoning and precedent as root's own passwordless account - this
# is never used for real interactive login auth. No sudo/wheel grant yet -
# deliberately out of scope for this pass.
chroot /mnt/root id msl >/dev/null 2>&1 || chroot /mnt/root adduser -D -s /bin/bash -h /home/msl msl
mkdir -p /mnt/root/mnt/mac
grep -q '^mac_home' /mnt/root/etc/fstab 2>/dev/null || echo 'mac_home /mnt/mac virtiofs defaults 0 0' >> /mnt/root/etc/fstab
ln -sfn /mnt/mac /mnt/root/root/mac
cat > /mnt/root/etc/local.d/network-up.start <<'EOF'
#!/bin/sh
# The persistent disk never had boot-time networking configured before -
# only the live-netboot path had DHCP, driven by the kernel's own
# `ip=dhcp` cmdline handling in that environment's init. eth0 exists but
# stays administratively down without this, confirmed live (`ip addr`
# showed `state DOWN`, no address) - `ip link set up` first is required,
# confirmed live that udhcpc does NOT bring the interface up itself and
# just retries "Network is down" forever otherwise (which, combined with
# `-b` only backgrounding *after* a successful lease, hung the entire
# boot indefinitely at "Starting local..." until this fix). Needed for
# NFS server reachability from the host (see README's "MSL Sandbox"
# section) - shellinit itself doesn't need networking at all, everything
# else here still does.
ip link set eth0 up 2>/dev/null
udhcpc -i eth0 -b 2>/dev/null
EOF
chmod +x /mnt/root/etc/local.d/network-up.start
cat > /mnt/root/etc/local.d/mount-mac-home.start <<'EOF'
#!/bin/sh
mount /mnt/mac 2>/dev/null
EOF
chmod +x /mnt/root/etc/local.d/mount-mac-home.start
cp /mnt/root/boot/vmlinuz-virt /out/vmlinuz-virt
cp /mnt/root/boot/initramfs-virt /out/initramfs-virt
# Explicit sync before AND after unmount, plus blockdev --flushbufs on the
# loop device itself - cheap insurance against a real filesystem
# corruption hit live once (root inode came back as garbage on the next
# boot - e2fsck confirmed the whole superblock/inode table was scrambled,
# not just a torn write). Root cause was never pinned down for certain -
# it correlated with a freshly-restarted OrbStack VM, which points at a
# virtiofs write-back cache coherency gap between Virtualization.
# framework's own disk I/O (bootstrap-guest, and later mslhd itself) and
# this container's loop-mounted view of the exact same host file, rather
# than anything wrong with the mount/copy steps themselves - but cheap
# enough to guard against unconditionally regardless.
sync
blockdev --flushbufs /dev/loop0 2>/dev/null || true
umount /mnt/root
sync
echo MSL_PROVISION_DONE
"""

log("provisioning rootfs.img via a throwaway privileged container (loop-mount, install shellinit+fileopsd, wire OpenRC, extract boot files) ...")
try runProcess("/usr/local/bin/docker", [
    "run", "--rm", "--privileged",
    "-v", "\(rootfsURL.path):/rootfs.img",
    "-v", "\(shellinitBinURL.deletingLastPathComponent().path):/host-bin:ro",
    "-v", "\(tmpDir.path):/out",
    "alpine:latest",
    "sh", "-c", guestScript,
])

let extractedVmlinuz = tmpDir.appendingPathComponent("vmlinuz-virt")
let extractedInitrd = tmpDir.appendingPathComponent("initramfs-virt")
guard FileManager.default.fileExists(atPath: extractedVmlinuz.path),
      FileManager.default.fileExists(atPath: extractedInitrd.path) else {
    throw ProvisionError.missingInput("container didn't produce /out/vmlinuz-virt and /out/initramfs-virt")
}

log("unwrapping the disk's own zboot-wrapped vmlinuz-virt (must match /lib/modules on the disk, not the netboot tarball's) ...")
try? FileManager.default.removeItem(at: diskKernelURL)
try GuestImageTools.extractZbootImage(from: extractedVmlinuz, to: diskKernelURL)

try? FileManager.default.removeItem(at: diskInitrdURL)
try FileManager.default.copyItem(at: extractedInitrd, to: diskInitrdURL)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskInitrdURL.path)

log("done - \(diskKernelURL.path) and \(diskInitrdURL.path) are ready for mslhd's .persistentDisk mode")
