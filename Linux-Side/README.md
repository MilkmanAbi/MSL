# MSL: the Linux side

Everything that runs *inside* an MSL guest, plus everything needed to turn a
stock distro image into one, collected so a rebuild can happen without
hunting through the host project. Nothing here is macOS code.

**Prepared 2026-09-09 for the Singapore rebuild; used for it 2026-09-14.**
Images are now built by **`image-build/`** - see `image-build/README.md`
for the pipeline, the kernel, the smoke tests and everything the rebuild
taught. The rest of this file describes the pieces it assembles.

```
image-build/   builds the kernel and every distro's image, boots and tests them, packages them
daemons/       the programs a guest runs for MSL to work (sources are symlinks into ../MSL)
provision/     the provisioner image-build runs inside each distro: packages, daemons, init
binaries/      old prebuilt daemons - stale, unused by image-build
tests/         the GUI test pyramid (X11, GTK, Qt, cairo, Wayland) + reference PNGs
protocols/     Wayland protocol XML used by the cage experiments
bootstrap/     the old Swift image tools (bootstrap-distro is retired; see image-build)
package-for-sg.sh   makes a self-contained tarball of this folder
```

## Which copy is authoritative

`daemons/*.c` and `bootstrap/*.swift` are **symlinks** into
`../MSL/` (this folder lives next to the repo, in `Actual-Project/`). The repository is the source of truth and always
was; the difference is that this folder can no longer disagree with it.

That matters because it already did. `daemons/fileopsd.c` was a plain copy
and had silently fallen four fixes behind the repo — an image built from it
would have baked in bugs that were fixed days earlier. Symlinks make that
failure impossible rather than merely unlikely.

The cost is that a symlink is useless once the folder travels. Use
**`./package-for-sg.sh`** to produce a tarball: it passes `tar -h`, so the
archive contains real file contents. Verified by extracting one and
confirming the packaged `fileopsd.c` contains the current `lstat` fix.

## The three daemons

Plain C, no dependencies beyond libc, all speaking `AF_VSOCK` to the host.
Ports are fixed by `VMConfiguration` on the host side; changing one here
means changing it there.

| Program | Port | Direction | What it does |
|---|---|---|---|
| `trafficd` | 5006 | guest listens | Reports the guest's own sockets and interface counters from `/proc`, for the app's Traffic Monitor. Sockets, not packets - it can say *that* the guest is talking to 1.1.1.1:443 and which process owns it, never what was said. |
| `shellinit` | 5000 | guest listens | One pty-backed shell per connection. **Every** `msl` command, the app's terminal, and all app scanning go through this. Nothing else works without it. |
| `fileopsd` | 5001 | guest listens | File operations behind the Finder share / WebDAV bridge. |
| `x11tunnel` | 5002 / 5003 | guest dials out | Relays X11 from guest clients to the host. `5002` is XQuartz, `5003` is mslgd. Needs `--announce`, which is what gives each Linux app its own Dock tile. |

`shellinit` and `fileopsd` start at boot. `x11tunnel` deliberately does
**not** — the host starts it on demand, per display, tracked by pidfile
(`/tmp/x11tunnel-<display>-<port>.pid`). GUI support stays opt-in.

### Building them

Inside the guest, against the guest's own libc — musl on Alpine, glibc
everywhere else. There is no cross-compiler set up and that is deliberate.

```sh
make -C daemons            # or: make -C daemons install PREFIX=/usr/local
```

`forkpty` lives in libutil on glibc and in libc on musl; the Makefile probes
for it, so there is no per-distro variant to remember.

**All three now compile clean on aarch64 musl** — verified 2026-09-09 in an
`alpine:latest` arm64 container, which is also the first time this session's
`fileopsd.c` changes were compiled by a real compiler rather than
syntax-checked against a stub header.

### The prebuilt binaries are stale — do not use them

`binaries/` exists for a guest with no compiler. Both files in it now
predate the source:

| File | Built | Status |
|---|---|---|
| `shellinit` | 2026-09-03 | probably fine — `shellinit.c` unchanged since 2026-08-31 |
| `fileopsd` | 2026-09-03 | **STALE** — misses the `lstat`, tab/newline and truncation fixes (2026-09-09) |
| `x11tunnel.STALE-pre-announce` | 2026-09-03 | **STALE** — predates `--announce`; using it puts every Linux app back on one shared Dock tile |

Build from source. The whole point of the rebuild is to stop shipping the
old behaviour.

## Provisioning a guest

```sh
provision/provision-msl.sh [--skip-gui] [--skip-tooling] [--no-firstboot] [--dry-run]
```

Run as root inside a booted guest — serial console, or `msl <instance> --`
if `shellinit` already works. Idempotent: re-running it to add a tier you
skipped is a supported flow.

It detects distro from `/etc/os-release`, init system from what is actually
on disk (`/run/systemd/system` or `rc-update`, never from the distro name —
guessing from the name is how you write unit files nothing reads), and
package manager from what exists. Then:

1. installs packages (three tiers, below)
2. builds and installs the three daemons
3. writes the `/etc/fstab` root entry and the `mac_home` virtiofs mount
4. wires `shellinit` + `fileopsd` into systemd or OpenRC
5. creates the unprivileged `msl` user
6. installs the first-boot wizard
7. verifies, and exits non-zero if anything required is missing

### Packages (`provision/packages.sh`)

Three tiers, because when bandwidth is short the first one is the
difference between a working guest and a brick, and the others are not.

- **REQUIRED** — compiler + `make`, **kernel UAPI headers**, `e2fsprogs`,
  `kmod`, `bash`.
- **TOOLING** — `git`, `wget`, `curl`, `zsh`, `nano`. The point of the
  rebuild.
- **GUI** — `libx11`, `libxext`, `xterm`, `xauth`. Only needed to run Linux
  apps through mslgd.

Two of those are easy to get wrong:

- **Kernel UAPI headers are required, not optional.** All three daemons
  `#include <linux/vm_sockets.h>`. On glibc distros `libc6-dev` /
  `glibc-devel` drags it in, but Alpine's `musl-dev` does **not**, and the
  build dies with `fatal error: linux/vm_sockets.h: No such file or
  directory`. Found by actually running the provisioner in a container, not
  by reading. The package is `linux-headers` (Alpine), `kernel-headers`
  (Fedora), `linux-api-headers` (Arch), `linux-glibc-devel` (openSUSE).
- **`e2fsprogs` is required for growable disks.** The host can enlarge the
  image, but only `resize2fs` inside the guest makes the filesystem use the
  new space. The root filesystem is the raw block device with no partition
  table, so there is no partition to extend first.

**`zsh` is installed and is deliberately NOT the login shell.** It is there
for macOS muscle memory; the login shell stays the distro default. That
means installing the package and *not* running `chsh`. "Install zsh" and
"switch to zsh" are one command apart and only one of them is wanted — so
the switch is offered to the user by the first-boot wizard instead of being
baked into every image. The provisioner's verify step warns if any account
in `/etc/passwd` has ended up with a zsh login shell.

## First-boot user setup

`provision/firstboot/` installs two files:

- `/usr/local/bin/msl-firstboot` — the wizard: hostname, a password for the
  `msl` account, an optional zsh switch for that account, and timezone.
- `/etc/profile.d/00-msl-firstboot.sh` — the trigger.

Interactive `shellinit` sessions get a **login shell** (`execl(shell,
"-bash", NULL)`), which sources `/etc/profile` and therefore
`/etc/profile.d/*`. That is what makes a first *use* — not a first boot —
the trigger point, which is what you want: there is an actual terminal
attached at that moment.

It configures the **existing** `msl` account rather than creating another
one. Renaming or replacing the account you may be running inside is a bad
time, and the image already ships `msl` because `msl <instance> -u msl`
depends on it.

**The guards are the feature.** This hook sits in the path every `msl`
command traverses; if it wedges, MSL is bricked and the symptom looks like a
vsock bug. So, in order:

1. Sentinel (`/var/lib/msl/setup-done`) checked first — the steady state is
   one `[ -e ]` test.
2. `[ -t 0 ] && [ -t 1 ]` — one-shot commands (`msl -- ls`, the app's
   `.desktop` scan) never enter it.
3. `MSL_SKIP_SETUP=1` escape hatch, settable from the host.
4. Root only. A non-root first session leaves the sentinel alone so root
   still gets the wizard.
5. **No `exit`, ever** — the file is *sourced*, so an `exit` would kill the
   login shell. The wizard runs in a subshell and its failure is discarded.
6. The wizard writes the sentinel **however it ends** — completed, failed,
   or Ctrl-C'd (`trap ... INT TERM HUP` as well as `EXIT`). A wizard that
   re-prompts forever because someone interrupted it is worse than one that
   never ran. Every prompt takes EOF as "use the default" rather than
   looping.

Re-arm it with `rm /var/lib/msl/setup-done`, or just run `msl-firstboot`.

## Where this duplicates the bootstrap tools

`bootstrap/` builds an image **from nothing**, on the Mac, via Docker —
`bootstrap-guest` (Alpine, drives Alpine's netboot installer over the serial
console), `bootstrap-distro` (Debian/Ubuntu/Arch/Fedora/Nix from container
base images), `provision-disk-image` (Alpine's OpenRC wiring, loop-mounting
`rootfs.img`), `build-shellinit` (compiles the daemons inside a guest).
Those remain authoritative for that job.

`provision/` does the other job: taking an image you already have and making
MSL work on it. They overlap in four places, and those lines are identical
in both **including their comments**, because each comment records a failure
diagnosed live and expensive to rediscover:

| Overlap | Why the comment matters |
|---|---|
| systemd unit files | symlinked into `multi-user.target.wants` rather than `systemctl enable`d — enable needs a live D-Bus connection to a running systemd, which does not exist during offline provisioning |
| OpenRC `local.d` scripts | `00-remount-root` (root silently stayed read-only every boot), `00b-fix-dev-perms` (mdev recreates `/dev/null` as `crw-rw----`, breaking `>/dev/null` for non-root), `network-up` (udhcpc does not bring the interface up itself and hung the whole boot) |
| `/etc/fstab` root entry | Docker bases ship no fstab, and `systemd-remount-fs` only remounts root rw if fstab has an entry to read options from |
| `mac_home` virtiofs mount | `/mnt/mac` is what `GuestPathMapper.macHomeMountPoint` assumes on the host — changing it here means changing that |

**If you change one, change the other.**

## Verification status

Be precise about this, because a clean run proves less than it looks like.

**Actually run, 2026-09-09**, in arm64 containers against the real package
managers and the real compilers:

| What | Result |
|---|---|
| Alpine (musl, busybox, apk) | full run clean — all three daemons compiled and installed |
| Debian (glibc, apt) | full run clean |
| Fedora (glibc, dnf) | full run clean — confirms the `kernel-headers` package name |
| Arch Linux ARM (pacman) | full run clean, after fixing a real bug — see below. Needs `docker run --privileged`: pacman's Landlock download sandbox fails without it, which `bootstrap-distro` already knew and does. Exercised the **systemd** branch. |
| systemd wiring branch | units symlinked into `multi-user.target.wants`, networkd `20-wired.network` written, resolv.conf correctly left alone when already populated |
| OpenRC wiring branch | all six `local.d` scripts installed executable, `rc-update add local default` applied |
| First-boot guards | 6/6 — `provision/firstboot/test-guards.sh` |
| First-boot **trigger** | 6/6 through the real mechanism: a genuine login shell on a pty runs the wizard, the shell still executes its command, the sentinel is written, the second login is silent, and a no-tty session skips it |
| `package-for-sg.sh` | tarball self-contained, carries the current `fileopsd.c` |
| Idempotency | provisioned twice: no duplicate fstab entries, `local` in the default runlevel once, `/etc/shells` unchanged |
| Every script | `sh -n`, `bash -n`, and `shellcheck -S error` clean |

Two things that run found, which reading would not have:

- **Alpine's `musl-dev` has no kernel UAPI headers.** All three daemons
  `#include <linux/vm_sockets.h>` and the build died outright with `fatal
  error: linux/vm_sockets.h: No such file or directory`. `linux-headers` is
  now in Alpine's required tier. This would have been the first thing to go
  wrong in SG.
- **`pacman -Sy` then install is broken on Arch.** Arch does not support
  partial upgrades: installing against a base image older than the repos
  produces file conflicts instead of an install (`libstdc++:
  /usr/lib/libstdc++.so.6 exists in filesystem (owned by gcc-libs)`). The
  refresh is now `pacman -Syu`.
- **Symlinks do not survive travel.** Bind-mounting this folder into a
  container dangled every one of them and the run failed before it started.
  That is what `package-for-sg.sh` exists for.

This was also the first time this session's `fileopsd.c` fixes were put
through a real compiler rather than syntax-checked against a stub header.

One harness note, so the next person does not lose an hour to it: driving
the wizard through `script` with nothing feeding the pty **hangs**, because
the wizard is sitting at a prompt waiting for a human. That is correct
behaviour, not a bug — pipe newlines in when testing.

**Not verified, and cannot be until an image boots:**

- That the daemons actually *serve* anything. A container has no vsock, so
  `shellinit` and `fileopsd` were compiled and installed but never
  connected to.
- That systemd or OpenRC actually *starts* them at boot. The wiring is on
  disk and correct; nothing here booted.
- That `shellinit`'s own `execl(shell, "-bash", NULL)` produces a shell
  that sources `/etc/profile`. The trigger is proven for a real login
  shell; that shellinit *creates* one is read from its source, not
  observed.
- The wizard's answers actually taking effect — hostname, `passwd`, `chsh`
  and the timezone symlink all ran against a container, not a booted guest.
- Anything involving the Mac: the Finder share, `resize2fs` against a
  host-grown disk, Dock tiles, `msl --`.

A container is a filesystem with a package manager, not a VM. It proves
these scripts do what they say to a root filesystem — which is where most
of the mistakes tend to be — and nothing whatever about runtime behaviour.

## Pending tests — what to run in SG, and what to include

Three genuinely different categories. Collapsing them loses the point.
`../READMES/02-IMAGE-REBUILD-SG.md` holds the build plan itself
(compression, sizing, order of operations); this is the test side.

### 1. Written, passing, host-side only

These pass today and will keep passing whatever the images do — which is
exactly their limit.

| Suite | State | What it does *not* cover |
|---|---|---|
| `swift test` (113 tests) | green | Nothing that touches a guest. Pure logic only. |
| `GuestPathMappingTests` (16) | green | That the mapped path opens the right directory in a real shell. |
| `FileOpsProtocolTests` (12) | green | That `fileopsd` actually emits the bytes being parsed. |
| `WebDAVPutStrategyTests` (11) | green | `handlePut`'s orchestration — the STAT dispatch, the rename, the cleanup call. |
| mslgd test pyramid (19/19) | green as of 2026-09-06 | Needs a booting guest with the toolkits to run at all. **Re-run the whole pyramid on each rebuilt image** — `Scripts/x11-test.sh`, and the cairo/GTK/Qt layers via `X11_TEST_DIR`. Use `test_all_apps.sh` (simultaneous 4-app) rather than one app at a time; that is how the galculator clip bug was found. |

### 2. Written but inert — has never executed against a guest

Code exists for all of these. None has run. **This is the list the rebuild
exists to close.**

> **Status after the 2026-09-14 rebuild** - tested on real boots through the
> installed app and daemon (`image-build/feature-test.sh`, 22/22 on all twelve
> distros, and `image-build/backlog-test.sh`):
>
> - **Verified:** dangling symlinks listed (`lstat`); names with a tab or
>   newline listed correctly (LIST2, below); a directory deeper than PATH_MAX
>   lists without harm; `handlePut` temp+rename - a 6 MiB copy lands intact,
>   `+x` survives an overwrite, and a 64 MiB copy cut off by a hard stop leaves
>   no file under its final name; orphan `.msl-put-*.tmp` cleanup; `trafficd`
>   serving and process attribution; SSH one-command connect (the Mac *does*
>   reach the guest's NAT address - no vsock `ProxyCommand` needed); SSH after
>   a reboot (it broke only because the idle suspend paused the guest under the
>   session - fixed, see `SSHActivity`); Sandbox gates live, across a cold boot
>   and across hibernate.
> - **Not run:** the MSL Files context menu and live guest path mapping (both
>   need clicking through the app); a real Apple-menu Shut Down with a live
>   guest; `x11tunnel --announce` (Linux GUI work is paused).
>
> In section 3 below, everything is now written and verified - LIST2, CHMOD,
> the orphan sweep (lazy, per directory, rather than at startup), NVMe,
> `resize2fs` end to end, daemons starting at boot on every distro, zsh present
> but not the login shell - except the first-boot wizard, which was dropped:
> account setup happens from the Mac.

| Thing | Where | How to test it once an image boots |
|---|---|---|
| `lstat` instead of `stat` when listing | `fileopsd.c` `handle_list` | Make a dangling symlink in the guest; it must appear in the Finder share. Before the fix it vanished silently. |
| Skip tab/newline names | `fileopsd.c` `handle_list` | `touch $'a\tb'`; the rest of the directory must still list correctly. |
| Reject truncated paths | `fileopsd.c` `handle_list` | Deep nesting past 4096 bytes; must skip, not stat the wrong path. |
| `handlePut` temp+rename | `WebDAVServer.swift` | Copy a >4 MiB file into a guest folder in Finder. Then kill the VM mid-copy: **no** partial file should be left. Then repeat over an *existing* file and confirm its mode survives. |
| Orphan `.msl-put-*.tmp` | same | After a killed multi-MiB copy, look for one. It is expected to be left behind on a timeout — that is the documented gap the sweep closes. |
| MSL Files context menu | `FilesModel.swift` | "Open in Terminal", "Copy as Path", "Open Folder in MSL" — the last hop (guest shell opening at the right directory) has never been observed. |
| Guest path mapping, live | `GuestPathMapping.swift` | Unit-tested exhaustively; never exercised against a real mount. |
| Power hardening on a real guest | `SystemResilienceMonitor` | `msl power-test shutdown` proved the logic; a genuine Apple-menu Shut Down with a live guest has not been re-run since. |
| `x11tunnel --announce` | `x11tunnel.c` | Open two Linux apps; each must get its **own** Dock tile, icon and name. This is the whole reason the prebuilt binary is quarantined. |
| `trafficd` serving | `trafficd.c` | Open the app's Traffic Monitor → "Guest connections". It should list real sockets; `curl example.com` in the guest should appear. Compiles clean and its `/proc` parsers pass 30 fixture assertions, but it has never answered over a real vsock. |
| Process attribution | `trafficd.c` | Tick "Show processes". Names should appear against sockets. Walks every fd of every process, so watch that it stays quick on a busy guest. |
| SSH one-command connect | `SSHSetup.swift` | Overview → "Set up". **Then check the thing that decides the design:** whether the Mac can reach the guest's address at all. `canReach` probes and reports honestly, so a failure is visible - but if it fails on rebuilt images, SSH needs to move to vsock with a `ProxyCommand`. |
| SSH after a reboot | `SSHSetup.swift` | The guest's DHCP address can change. `ssh msl-<instance>` should keep working after "Set up again" rewrites the config block in place. |
| Sandbox gates, live | `SandboxPolicy` | Cut Network on a running guest: `ping` should fail inside it while `msl --` keeps working (vsock is not the NIC). Then hibernate and resume - the cut must still be there. |

### 3. Not yet written — needs the rebuild first

| Thing | Note |
|---|---|
| `LIST2 = 0x09` opcode | Length-prefixed binary listing entries. The real fix for names containing tabs/newlines; skipping them is damage control. Design in 02-IMAGE-REBUILD-SG.md. |
| `CHMOD = 0x08` opcode | Lets `handlePut` use temp+rename for **overwrites** too. Today they write in place, on purpose, because `rename` would drop the file's mode and `fileopsd` cannot restore it. |
| Orphan-temp sweep | One-shot `.msl-put-*.tmp` cleanup at `fileopsd` startup. |
| NVMe migration | `/dev/vda` → `/dev/nvme0n1`. **Do it in the same pass** — it needs `root=` and `/etc/fstab` changed inside the image, which the rebuild is already doing. `provision-msl.sh`'s fstab line is marked with this. |
| `resize2fs` end to end | Grow a disk from the Mac, confirm the guest sees the space. Never tested against a rebuilt image. |
| Boot-time daemon start, per distro | The known gap: five of six images boot to a login prompt with no `shellinit`, so the host cannot talk to them at all. |
| zsh present, not the login shell | The provisioner's verify step checks it; confirm on a booted image. |
| First-boot wizard, live | Boot a fresh image, confirm the wizard fires exactly once, and that `msl -- echo hi` (non-interactive) never triggers it. |

### Per-distro state

Alpine's image has a corrupt ext4 (`Attempted to kill init! exitcode=1`) —
it filled to 100% and truncated a library mid-install. The other five boot
to a login prompt but carry no MSL daemons. All six are being **replaced,
not repaired**.

New distros for SG need a real aarch64 port. Candidates already noted:
openSUSE Tumbleweed, Void, Rocky/Alma, Gentoo (heavy), genuine NixOS via
`nixos-generators`. `packages.sh` already has entries for openSUSE, Void and
Rocky/Alma; an unknown distro falls back to common names and returns
non-zero so the provisioner warns rather than silently skipping the required
tier.

## Base images

`image-build/distros.sh` is what the build reads; `GuestDistro.dockerImage`
in the repo mirrors it. Every one was checked on 2026-09-14 to publish a
linux/arm64 manifest and to carry every package in the required tier.

| Distro | Base image | Note |
|---|---|---|
| Alpine | `alpine:3.24` | built from the container like the rest now, with OpenRC added |
| Debian | `debian:13-slim` | |
| Ubuntu | `ubuntu:26.04` | |
| Kali | `kalilinux/kali-rolling:latest` | |
| Arch | `menci/archlinuxarm:latest` | **Arch Linux ARM**, a separate project: `archlinux` has no arm64 manifest, and `lopsided/archlinux` ships no `/etc/os-release` |
| Fedora | `fedora:44` | no `wget` package - `wget2-wget` |
| Rocky | `rockylinux/rockylinux:10` | |
| AlmaLinux | `almalinux:10` | |
| CentOS Stream | `quay.io/centos/centos:stream10` | |
| Oracle Linux | `oraclelinux:10` | os-release ID `ol` |
| openSUSE | `opensuse/leap:16.0` | needs `sudo-policy-wheel-auth-self`; no `/sbin/init` in the container |
| Nix | `debian:13-slim` | the Nix *package manager* on Debian, not genuine NixOS |

Not offered: Red Hat's UBI 10 (no `e2fsprogs` in its repositories, and RHEL
proper needs a subscription), Void (no arm64 container image), genuine NixOS
(needs `nixos-generators`, not a container export).

**Arch installs must be `pacman -Syu`, never `-Sy`.** Arch does not support
partial upgrades: refreshing the database and then installing against a base
image older than the repos produces file conflicts instead of an install
(`libstdc++: /usr/lib/libstdc++.so.6 exists in filesystem (owned by
gcc-libs)`). Found by running it; `provision-msl.sh` does the full upgrade.

## Order of operations in SG

1. Fresh base image per distro.
2. `./package-for-sg.sh` on the Mac; carry the tarball in (or mount the
   folder — `/mnt/mac` reaches it once the guest is up).
3. Boot the image, run `provision/provision-msl.sh` as root.
4. Reboot, then verify from the Mac: `msl <instance> -- echo hello` must
   answer. Nothing else is worth testing until it does.
5. Walk category 2 above. That is the list this rebuild exists to close.
6. Clean caches, zero free space, shut down cleanly, compress
   (`zstd -19 --long=27`), update the manifest — details in
   02-IMAGE-REBUILD-SG.md.

## `daemons/msl-maintenance.sh` (2026-09-11)

The guest half of the app's Maintenance card - a POSIX `sh` script, not a
daemon: nothing runs until the host calls it. `provision-msl.sh` installs it
at `/usr/sbin/msl-maintenance`, a fixed path the host depends on. Its tests
run anywhere with a POSIX shell: `dash daemons/tests/msl-maintenance_test.sh`.
The SG test checklist is in `02-IMAGE-REBUILD-SG.md`, "Maintenance tools".
