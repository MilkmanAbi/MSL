# MSL-Images

The Linux disk images MSL installs, ready to publish: one shared kernel and
initramfs, twelve distros, a manifest `msl install` reads, and checksums.

Built and tested 2026-09-14. Every image boots over NVMe in about five seconds
and passes MSL's full test suite on a real boot through the app and daemon -
see `Actual-Project/Linux-Side/image-build/README.md`.

## Files

```
manifest.json                            what `msl install` fetches, with sizes and sha256
SHA256SUMS                               every image file, for `shasum -a 256 -c SHA256SUMS`
msl-kernel-6.18.50-lts-arm64.Image.xz    the kernel every distro boots
msl-initramfs-6.18.50-lts-arm64.cpio.gz  its initramfs
msl-<distro>-<release>-arm64.img.xz      one per distro, below
```

Names say what a file is, which release and which architecture, and never a
build date - a link stays the same across rebuilds of one release. The build
date is each entry's `version` in `manifest.json`. `msl install` saves every
file under its own fixed name on the Mac, so the published names are for
people and servers only.

## Distros

| Distro | File | Built from |
|---|---|---|
| Alpine 3.24 | `msl-alpine-3.24-arm64.img.xz` | `alpine:3.24` |
| Debian 13 "trixie" | `msl-debian-13-arm64.img.xz` | `debian:13-slim` |
| Ubuntu 26.04 LTS | `msl-ubuntu-26.04-arm64.img.xz` | `ubuntu:26.04` |
| Kali Rolling | `msl-kali-rolling-arm64.img.xz` | `kalilinux/kali-rolling` |
| Arch Linux ARM | `msl-arch-rolling-arm64.img.xz` | `menci/archlinuxarm` |
| Fedora 44 | `msl-fedora-44-arm64.img.xz` | `fedora:44` |
| Rocky Linux 10.2 | `msl-rocky-10.2-arm64.img.xz` | `rockylinux/rockylinux:10` |
| AlmaLinux 10.2 | `msl-alma-10.2-arm64.img.xz` | `almalinux:10` |
| CentOS Stream 10 | `msl-centos-stream10-arm64.img.xz` | `quay.io/centos/centos:stream10` |
| Oracle Linux 10.2 | `msl-oracle-10.2-arm64.img.xz` | `oraclelinux:10` |
| openSUSE Leap 16.0 | `msl-opensuse-leap16.0-arm64.img.xz` | `opensuse/leap:16.0` |
| Nix on Debian 13 | `msl-nix-debian13-arm64.img.xz` | `debian:13-slim` + Nix |

- **Arch** is Arch Linux ARM - Arch itself has no arm64 port.
- **Nix** is the Nix package manager on Debian, not NixOS.
- **Red Hat Enterprise Linux** isn't offered: Red Hat's free UBI image lacks
  e2fsprogs, and full RHEL needs a subscription. Rocky, Alma, CentOS Stream
  and Oracle Linux cover that family.

## What's in every image

- MSL's guest daemons, started at boot: `shellinit` (the `msl` shell),
  `fileopsd` (Finder), `trafficd` (network monitor), `memd` (dynamic memory),
  and the maintenance script at `/usr/sbin/msl-maintenance`.
- git, curl, wget, gcc, make, nano, zsh (installed, not the default shell),
  sudo, an SSH server (off until you set SSH up from the Mac), e2fsprogs.
- Root on `LABEL=msl-root`, so the same image boots however its disk is
  attached.
- **No usable passwords.** Root is locked and the built-in `msl` account has
  none. The first time you start an instance, MSL asks you to create your own
  account, which gets sudo with its own password.
- No SSH host keys and an empty machine id, so every install is its own
  machine.

## Installing

MSL does this for you:

```sh
msl install debian                       # from MSL's published catalog
msl install debian --manifest <url>      # from anywhere else
```

It downloads the image, checks its sha256, unpacks it (sparse - a 4 GiB image
takes about 600 MiB on disk), and grows the disk to 16 GiB the first time the
instance starts. The shared kernel and initramfs are fetched once, for the
first distro.

By hand:

```sh
shasum -a 256 -c SHA256SUMS
xz -dk msl-debian-13-arm64.img.xz
```

## Where they're published

SourceForge's file release system, project `msl-files`:

```
https://sourceforge.net/projects/msl-files/files/
├── manifest.json                    the current catalog - what MSL fetches by default
└── msl-images-2026.09.14/           this release: every file above, and its own manifest.json
```

MSL's built-in catalog URL is
`https://downloads.sourceforge.net/project/msl-files/manifest.json`, and every
`url` inside it is `https://downloads.sourceforge.net/project/msl-files/msl-images-<date>/<file>`.
`downloads.sourceforge.net` redirects to a mirror; `curl -fL` (which `msl
install` uses) follows it.

A new release is a new dated folder plus a new root `manifest.json`, so the
catalog URL never changes and older copies of MSL keep finding current images:

```sh
cd Actual-Project/Linux-Side
image-build/package-images.sh ~/MSL-ImageBuild/kernel ~/MSL-ImageBuild/images \
    ../MSL/MSL-Images https://downloads.sourceforge.net/project/msl-files/msl-images-<date>
# then upload the folder's files to /home/frs/project/msl-files/msl-images-<date>/
# over SFTP (frs.sourceforge.net), and manifest.json to the project root as well
```

## Rebuilding

Everything that makes these lives in `Actual-Project/Linux-Side/image-build/`:
`build-kernel.sh`, `build-all.sh`, the test scripts, and `package-images.sh`.
Its README is the full runbook.
