# Guest init / shell listener

`shellinit.c` is the guest-side counterpart to `mslhd`/`msl` on the host.
It's a minimal AF_VSOCK server that accepts one connection at a time,
allocates a real pty per connection (so job control, isatty checks,
colors etc. all behave normally - this is the same pattern sshd uses
internally), and execs a shell into it.

This is *not* a full init system by itself. To turn this into an actual
bootable guest:

1. Build a minimal Alpine arm64 rootfs - see `Sources/bootstrap-guest` at
   the repo root for the no-Docker bootstrap program that does this by
   driving Alpine's netboot installer environment over its serial console.
2. Build `shellinit` against that rootfs's libc (see Makefile - Alpine
   is musl, drop `-lutil`). Since there's no cross-compiler set up, the
   simplest path is building it *inside* the guest: attach this directory
   as a read-only virtiofs share, `apk add gcc musl-dev`, then
   `gcc -O2 -o /usr/local/bin/shellinit /mnt/host-init/shellinit.c`.
3. Wire `shellinit` up as an OpenRC local service so it starts on boot:
   ```sh
   cat > /etc/local.d/shellinit.start << 'EOF'
   #!/bin/sh
   exec /usr/local/bin/shellinit
   EOF
   chmod +x /etc/local.d/shellinit.start
   rc-update add local default
   ```
   This keeps a normal OpenRC boot (console/getty still available for
   debugging) rather than replacing init entirely. Once the shell path is
   solid, swapping the kernel cmdline to `init=/usr/local/bin/shellinit`
   to skip OpenRC entirely is a later leanness/boot-speed optimization, not
   required for the MVP.
4. Mount the virtiofs shares configured on the host side (see
   `VMConfiguration.sharedFolders`) - typically via
   `mount -t virtiofs <tag> <mountpoint>` in whatever startup script
   runs before `shellinit` takes over.
