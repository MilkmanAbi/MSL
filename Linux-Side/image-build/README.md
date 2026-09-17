# image-build: making MSL's disk images

Everything that turns official distro container images into MSL disk
images, and checks them on a real boot. Runs on the Mac; needs only OrbStack
(or another Docker engine) and, for packaging, `xz`.

Written 2026-09-14, when all twelve images were rebuilt in Singapore.

```
build-kernel.sh      the shared kernel, initramfs and trimmed module tree
build-rootfs.sh      one distro's image (configure -> export -> assemble)
build-all.sh         several distros in a row, one log each, a summary
distros.sh           which base container image each distro is built from
rootfs-configure.sh  stage 1, inside the distro's container
rootfs-assemble.sh   stage 3, in Alpine: modules, fixes, mke2fs
smoke-test.sh        boots an image through the real daemon and checks it
smoke-account.sh     the Linux-account test matrix, through the real prompt
feature-test.sh      hibernate, snapshots, SSH, Sandbox gates, WebDAV, maintenance
backlog-test.sh      the READMEs' remaining checks: maintenance boots, dynamic
                     memory, accounts, SSH after reboot, cut-off uploads, ...
account-name-taken.exp  the first-start prompt offered a name that exists
package-images.sh    xz-compresses images and writes manifest.json + SHA256SUMS
kernel-inner.sh      the container half of build-kernel.sh
```

## The whole run

```sh
B=~/MSL-ImageBuild
image-build/build-kernel.sh $B/kernel
image-build/build-all.sh    $B/kernel $B/images            # all distros, ~1-2 min each
for d in $(. image-build/distros.sh; echo $MSL_DISTROS); do
    image-build/smoke-test.sh    $d $B/images $B/kernel
    image-build/smoke-account.sh $d $B/images
done
image-build/smoke-test.sh debian $B/images $B/kernel   # leaves the image installed
image-build/feature-test.sh debian                     # `msl debian` registers it again
image-build/backlog-test.sh $B/images $B/kernel        # an hour or so; one instance at a time
image-build/package-images.sh $B/kernel $B/images ../MSL/MSL-Images https://<where it is served>
```

`package-images.sh` writes a flat folder: `msl-<distro>-<release>-arm64.img.xz`
for each distro (release tags live in `distros.sh`, written out on purpose),
`msl-kernel-<version>-arm64.Image.xz`, `msl-initramfs-<version>-arm64.cpio.gz`,
`manifest.json` and `SHA256SUMS`. No build dates in names - a link stays valid
across rebuilds of one release; the date is the manifest's `version`.

```sh
(cd ../MSL/MSL-Images && shasum -a 256 -c SHA256SUMS)
```

`smoke-test.sh` and `smoke-account.sh` need MSL.app installed (they use the
real `msl` and `mslhd`), and install images into
`~/Library/Application Support/MSL` - that's the point: the same place and
the same daemon a user gets.

## How an image is built

1. **configure** - in the distro's own arm64 container: install its init
   system and base, then run `../provision/provision-msl.sh --no-firstboot`
   exactly as it would run in a booted guest (packages, the five daemons
   compiled from source, units and presets, fstab, the `msl` account). Then
   lock root, stop sshd starting at boot, and strip caches, docs and
   translations.
2. **export** - `docker export` of that container.
3. **assemble** - in Alpine: remove `/.dockerenv`, write the files Docker
   bind-mounts (`resolv.conf`, `hosts`, `hostname`), add the shared kernel's
   modules, and `mke2fs -d` the tree into a sparse 4 GiB ext4 image labelled
   `msl-root`.

No VM boots during a build. A container proves files landed; only
`smoke-test.sh` proves a guest works.

## The kernel

Alpine's `linux-lts` (6.18 on Alpine 3.24): lts rather than virt because
virt has no vgem and no USB/IP host driver. `build-kernel.sh` unwraps the
EFI zboot `vmlinuz` into the raw `Image` Virtualization boots, builds an
initramfs with only `base ext4 nvme virtio` (7.6 MB, down from Alpine's
default 161 MB), and trims the module tree to what a VM can use - physical
hardware, wireless, bluetooth and sound go; filesystems, netfilter, bridges,
dm-crypt, vgem and USB/IP stay. Anything left with unresolved symbols is
pruned, and a list of required modules must still resolve or the build
fails. Modules are shipped decompressed: not every distro's `kmod` reads
gzip.

## Lessons that are now code

Each of these failed a real build or boot before it was fixed, and the fix
carries a comment where it lives.

- **Stage on the container's filesystem, never a Mac-backed bind mount.**
  `mke2fs -d` couldn't list xattrs on Debian's `/usr/bin/awk` symlink through
  OrbStack's mount of APFS.
- **First boot re-applies systemd presets.** Every image has an empty
  `/etc/machine-id`, so systemd treats its first start as a first boot and
  applies unit presets: Ubuntu's `enable *` switched sshd back on, and
  `disable *` (Fedora, the Enterprise Linux family) would switch MSL's
  daemons off. `00-msl.preset` settles both.
- **The guest has no clock.** Virtualization gives this boot path no usable
  RTC, so a cold boot started seven weeks in the past and every HTTPS request
  failed certificate validation. The host sets the guest clock whenever it
  comes up (`VMManager.syncClockAfterStart`).
- **Root is locked, not empty.** An empty root password lets any user `su`
  to root where PAM allows `nullok`.
- **`msl` gets `*`, not `passwd -l`'s `!`.** Alpine's OpenSSH is built
  without PAM and reads a leading `!` as a locked account, refusing even key
  logins - `msl ssh` failed on Alpine alone. `*` matches no password and
  isn't "locked".
- **openSUSE:** its sudoers asks for the *target's* password (`Defaults
  targetpw`); `sudo-policy-wheel-auth-self` restores "your own password".
  Leap 16 also ships no `/sbin/init` link.
- **Arch:** `menci/archlinuxarm` - the official image has no arm64, and
  `lopsided/archlinux` has no `/etc/os-release`. Always `pacman -Syu`.
- **Fedora 44** has no `wget` package (`wget2-wget`). **UBI 10** (Red Hat's
  free image) lacks `e2fsprogs`, so RHEL itself isn't offered.
- **Alpine's 6.18 kernel has no legacy iptables** - nftables only, so
  iptables in a guest is the `-nft` flavour.
- **As `init=`, a script gets no useful PATH.** `msl-maintenance` found
  `e2fsck` but not `sync` in a maintenance boot, so it now sets its own PATH
  and can flush through busybox or SysRq.
- **`/etc/os-release` can be a symlink** (Arch: `-> /usr/lib/os-release`).
  Resolved inside the staged tree; followed as-is it read the *build
  container's* file and `arch.info` said "Alpine Linux". Release tags in file
  names come from `distros.sh`, not from os-release, for the same reason.

Host-side bugs the test runs flushed out (fixed in `MSL/`, not here):

- **A stopped VM must be released.** A stopped `VZVirtualMachine` that is
  still referenced keeps its XPC process and its lock on the disk, so the
  next start fails with "The storage device attachment is invalid". Every
  stop path now sets `virtualMachine = nil`.
- **The Finder mount could wake a hibernated instance.** Mounting takes
  seconds; a stop in that window left the bridge behind, webdavfs kept
  polling it, and each poll restarted the VM and threw its saved state away.
  `webdavGeneration` in `VMManager` closes it. `feature-test.sh` checks the
  saved state ten seconds after hibernating, not at once, for this reason.
- **A stopped WebDAV server kept listening.** `close()` doesn't wake a
  thread blocked in `accept()` on Darwin, so the socket stayed open; with a
  mount NetFS made despite reporting error 19, that bridge booted an
  unregistered Arch VM after the instance was removed. `stop()` shuts the
  socket down first (`WebDAVServerStopTests`). After any test run with every
  instance stopped, `mount | grep -c webdav`, mslhd's TCP listeners and
  Virtualization processes should all be 0.
- **Removing an instance while MSL.app was open could bring it back.** The
  app's automatic SSH setup opened its guest session seconds after it saw
  the instance start, and a session registers and boots whatever it names -
  so it resurrected an instance `msl remove` had just deleted. It re-checks
  status first now. Tests that remove instances can still see the app act on
  them; look at `last-used` and `ssh/` mtimes before suspecting the daemon.
- **`msl remove` left `ssh msl-<name>` behind** - the record and the
  `~/.ssh/config` block. The daemon's remove cleans both now.
- **The idle suspend froze SSH sessions.** SSH bypasses mslhd, so the pause
  three seconds after the last `msl` command caught live sessions mid-command
  and made new connections time out - which first looked like "SSH breaks
  after a reboot". Instances with SSH set up aren't light-paused, and the idle
  hibernate skips while trafficd shows a connection to port 22.
- **`instances.json` was written non-atomically**, so a read during a write
  saw no instances. The listing in a test run's summary line went empty once;
  a proven-to-fail test guards it now.
- **Re-applying a closed Sandbox gate at boot crashed mslhd** - it ran off
  the VM's queue. Now dispatched onto `vmQueue`.
- **A command 3 s after the previous one wedged the VM.** The idle suspend
  fires 3 s after the last session ends, and a new session wasn't counted
  until its connection existed - so it could be paused mid-connect, and the
  connect timeout abandoned the VM. It looked like "reopening the Network
  gate wedges vsock" in `feature-test.sh`, which happens to sleep 3 s there.
  Sessions are counted before the VM is touched now.
- **The Display gate always read closed** unless a Linux GUI app was
  running (`SANDBOX SET 0000` answered `0010`): it reported whether the X11
  server was up, not the gate.
- **`msl ssh` broke all of `ssh`** when the key path had a space
  (`Application Support`): `IdentityFile` is quoted now, and older blocks are
  repaired in place.
