import Foundation
import MSLCore
#if canImport(Virtualization)
import Virtualization
#endif

/*
 * bootstrap-guest
 *
 * One-off tool that builds a real Alpine arm64 ext4 root filesystem onto a
 * raw disk image, with no Docker/OrbStack and no macOS-side ext4 tooling.
 * Boots Alpine's netboot kernel+initramfs headless, drives the live
 * environment over its serial console (see MSLCore/SerialConsoleSession),
 * and uses `mke2fs -d <staging-dir>` to format+populate the target disk
 * directly from userspace - no kernel-side ext4 driver needed on the live
 * side at all (see README's "Guest bootstrap findings" for why that matters
 * - the live kernel doesn't have ext4 built in).
 *
 * Not part of mslhd's runtime path - run it once to produce rootfs.img:
 *
 *     swift build -c release --product bootstrap-guest
 *     codesign --force --sign - \
 *       --entitlements Resources/MSLApp/MSLApp.entitlements \
 *       .build/release/bootstrap-guest
 *     .build/release/bootstrap-guest
 */

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// MARK: - Configuration

let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let netbootTarball = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : packageRoot.appendingPathComponent("../../IMAGES/alpine-netboot-3.24.1-aarch64.tar.gz")

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MSL", isDirectory: true)
let diskURL = appSupport.appendingPathComponent("rootfs.img")

// Alpine repo branch matching the downloaded netboot release. If this
// doesn't resolve on first boot (check the transcript for apk errors), try
// "edge" instead of "v3.24".
let alpineRepo = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main"
let diskSizeBytes: UInt64 = 4 * 1024 * 1024 * 1024 // 4GB sparse

func createSparseDisk(at url: URL, sizeBytes: UInt64) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        log("disk image already exists at \(url.path), reusing it")
        return
    }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: sizeBytes)
    try handle.close()
}

// MARK: - Set up Application Support + extract kernel/initramfs

try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
let (kernelURL, initrdURL) = try GuestImageTools.ensureKernelAndInitrd(netbootTarball: netbootTarball, appSupport: appSupport)
try createSparseDisk(at: diskURL, sizeBytes: diskSizeBytes)

// MARK: - Boot and drive the install

let session = SerialConsoleSession()
let config = try LiveBootConfig.headlessConfiguration(
    kernelURL: kernelURL,
    initrdURL: initrdURL,
    commandLine: "console=hvc0 ip=dhcp alpine_repo=\(alpineRepo) quiet",
    cpuCount: 2,
    memorySize: 2 * 1024 * 1024 * 1024,
    serialAttachment: session.attachment,
    diskURL: diskURL
)
let vm = VZVirtualMachine(configuration: config)

log("booting Alpine netboot environment (headless, serial console piped) ...")
vm.start { result in
    switch result {
    case .success: log("VM started")
    case .failure(let error): log("VM failed to start: \(error)"); exit(1)
    }
}

log("waiting for the login prompt ...")
try session.loginAsRoot()

// mkfs.ext4 + mount + apk --root was the first approach tried here, and it
// failed silently: this live netboot kernel doesn't have ext4 built in (no
// modloop was supplied on the kernel cmdline, and modloop is where Alpine
// keeps most filesystem drivers). `mount` failed, but the script didn't
// check for that and proceeded to `apk add --root /mnt/root` anyway - which
// happily installed the entire rootfs into a plain (unmounted) ramdisk
// directory that vanished on poweroff, leaving /dev/vda an empty,
// freshly-formatted-but-otherwise-untouched ext4 filesystem. See README's
// "Guest bootstrap findings" for the full story.
//
// Fix: `mke2fs -d <dir>` formats AND populates an ext4 image directly from
// a plain staging directory, entirely in userspace via e2fsprogs - no
// kernel-side ext4 driver involved at all. Populate a staging dir with apk
// first, then format+populate the real disk from it in one step.
//
// Also installs linux-virt (kernel modules matching this exact running
// kernel) and mkinitfs onto the target, which generates a matching
// initramfs at /boot - the real MSL guest boots using THOSE (extracted from
// the finished rootfs.img), not the netboot tarball's kernel/initramfs,
// so kernel and modules are guaranteed to match. See Sources/mslhd.
let steps: [(command: String, marker: String)] = [
    ("apk update", "MSL_STEP_1_DONE"),
    ("apk add e2fsprogs e2fsprogs-extra", "MSL_STEP_2_DONE"), // -extra has debugfs, used for verification below
    ("mkdir -p /mnt/stage", "MSL_STEP_3_DONE"),
    // bash isn't part of alpine-base (Alpine deliberately ships busybox ash
    // as /bin/sh instead) - explicit here since shellinit execs /bin/bash
    // for real bash semantics (job control, [[ ]], arrays, etc.), not the
    // POSIX-only default.
    ("apk add --root /mnt/stage --initdb -U --allow-untrusted -X \(alpineRepo) alpine-base openrc linux-virt mkinitfs gcc musl-dev bash",
     "MSL_STEP_4_DONE"),
    ("echo 'nameserver 1.1.1.1' > /mnt/stage/etc/resolv.conf", "MSL_STEP_5_DONE"),
    // -F: this tool is re-run whenever the package list changes (as it
    // just was, to add bash) - createSparseDisk() above deliberately
    // reuses an existing disk image rather than recreating it, so a
    // second run hits a disk that already has an ext4 signature on it.
    // Without -F, mke2fs prompts "Proceed anyway? (y,N)" and hangs
    // forever waiting for input this scripted serial-console session can
    // never provide (confirmed live: it just sits there until runStep's
    // marker-wait times out). -F is safe here since reformatting +
    // repopulating the disk from /mnt/stage is the explicit point of this
    // step, not an accident to guard against.
    ("mke2fs -F -t ext4 -L mslroot -d /mnt/stage /dev/vda", "MSL_STEP_6_DONE"),
    // debugfs's `ls` pages its output when stdout looks like a tty, which
    // swallowed the next command into the pager's "Examine:" prompt on
    // first real run - `| cat` makes stdout a pipe instead, disabling that.
    ("debugfs -R 'ls -l /' /dev/vda | cat", "MSL_STEP_7_DONE"),
]

for (index, step) in steps.enumerated() {
    log("--- step \(index + 1)/\(steps.count): \(step.command)")
    do {
        try session.runStep(step.command, marker: step.marker)
    } catch {
        log("\(error) - aborting")
        exit(1)
    }
}

// `poweroff -f` forces an immediate halt with none of the normal shutdown
// sequence's own unmount/flush - confirmed live this let corruption
// through once: mke2fs -d's writes go through the *guest kernel's own*
// buffer cache on the way to the virtio-blk device, and `-f` can halt the
// VM before that cache is actually flushed through to the host-side file,
// even though everything looked fine to the same session's own later
// reads (still served from that same, not-yet-flushed cache). An explicit
// `sync`, waited on via the same runStep/marker mechanism as every other
// step here (not just fired and hoped for), closes that gap.
log("--- syncing before shutdown")
do {
    try session.runStep("sync", marker: "MSL_SYNC_DONE")
} catch {
    log("\(error) - aborting")
    exit(1)
}

log("--- rootfs populated, shutting down guest")
session.sendLine("echo MSL_BOOTSTRAP_DONE")
session.sendLine("poweroff -f")

do {
    try session.waitFor("MSL_BOOTSTRAP_DONE", timeout: 30)
} catch {
    log("didn't see the final marker, but continuing to wait for shutdown")
}

let shutdownDeadline = Date().addingTimeInterval(30)
while vm.state != .stopped, Date() < shutdownDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
}

if vm.state == .stopped {
    log("guest stopped cleanly - rootfs.img at \(diskURL.path) is ready")
} else {
    log("guest didn't report stopped within 30s (state: \(vm.state)) - check the transcript; rootfs.img may still be valid since the writes completed before poweroff")
}
