import Foundation

/*
 * bootstrap-distro - retired 2026-09-14.
 *
 * This tool built non-Alpine disk images from Docker base images. It was
 * replaced by the shell pipeline in `Linux-Side/image-build/`, which builds
 * every distro (Alpine included) the same way and provisions it with the
 * same `provision-msl.sh` a booted guest would run:
 *
 *     Linux-Side/image-build/build-kernel.sh  OUT/kernel
 *     Linux-Side/image-build/build-rootfs.sh  <distro> OUT/kernel OUT/images
 *
 * The ten boot failures this tool's comments recorded (static shellinit,
 * /.dockerenv, the missing fstab, kmod, gzip'd modules, pacman's Landlock
 * sandbox, DNS, Nix's systemd wiring, `curl | sh`, the read-only loop mount)
 * are written up in READMES/05-README.md under "What it actually took to get
 * Debian/Ubuntu/Arch booting", and each fix lives on in the new pipeline's
 * comments where it applies.
 */

FileHandle.standardError.write("""
bootstrap-distro has been retired. Build images with Linux-Side/image-build/:
  build-kernel.sh OUT/kernel
  build-rootfs.sh <distro> OUT/kernel OUT/images

""".data(using: .utf8)!)
exit(1)
