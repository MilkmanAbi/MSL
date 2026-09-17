import Foundation
import MSLCore
#if canImport(Virtualization)
import Virtualization
#endif

/*
 * extract-guest-modules
 *
 * One-off tool that pulls just the kernel modules MSL actually needs (vsock
 * + its virtio transport, and ext4 + its dependencies) out of Alpine's
 * modloop-virt archive, with no Docker/OrbStack and no macOS-side squashfs
 * tooling.
 *
 * Why this exists: the netboot initramfs bundles enough modules to get
 * storage/network/virtiofs working (virtio_blk, virtio_net, virtiofs, loop,
 * squashfs) but NOT vsock or ext4 - those live in modloop-virt, a squashfs
 * image normally fetched at boot via a `modloop=` kernel param. Rather than
 * depend on that (network fetch every real boot, or a local HTTP server
 * bridging the NAT gateway), this extracts the handful of .ko files MSL
 * needs ONCE, so mslhd can just insmod them directly from a small always-on
 * virtiofs share - no modloop involved in the real guest's boot path at all.
 *
 * How: boots the netboot kernel+initramfs headless (same live environment
 * bootstrap-guest uses), which already has loop.ko + squashfs.ko +
 * virtiofs.ko bundled directly - enough to mount modloop-virt itself
 * without needing modloop's own contents first. Shares this program's
 * Application Support directory into the guest via virtiofs (read-write),
 * loop-mounts modloop-virt from it, and copies matching files back into
 * a `modules/` subdirectory the guest can write to directly - no serial
 * transfer, no network, just virtiofs.
 *
 * Not part of mslhd's runtime path - run it once:
 *
 *     swift build -c release --product extract-guest-modules
 *     codesign --force --sign - \
 *       --entitlements Resources/MSLApp/MSLApp.entitlements \
 *       .build/release/extract-guest-modules
 *     .build/release/extract-guest-modules
 */

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let positionalArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let netbootTarball = positionalArgs.first.map { URL(fileURLWithPath: $0) }
    ?? packageRoot.appendingPathComponent("../../IMAGES/alpine-netboot-3.24.1-aarch64.tar.gz")

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MSL", isDirectory: true)
let modloopURL = appSupport.appendingPathComponent("modloop-virt")
let modulesOutputDir = appSupport.appendingPathComponent("modules", isDirectory: true)

let alpineRepo = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main"

try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: modulesOutputDir, withIntermediateDirectories: true)

let (kernelURL, initrdURL) = try GuestImageTools.ensureKernelAndInitrd(netbootTarball: netbootTarball, appSupport: appSupport)

if !FileManager.default.fileExists(atPath: modloopURL.path) {
    log("extracting boot/modloop-virt ...")
    try GuestImageTools.extractMember(from: netbootTarball, member: "boot/modloop-virt", to: modloopURL)
}

// MARK: - Boot and drive the extraction

let session = SerialConsoleSession()
let config = try LiveBootConfig.headlessConfiguration(
    kernelURL: kernelURL,
    initrdURL: initrdURL,
    // Turns out `alpine_repo=` isn't just for apk later - the whole netboot
    // live root itself is fetched from it at boot (this genuinely is a
    // network boot, not just a locally-bundled live image). Omitting it
    // (tried both with and without ip=dhcp) fails headless in different
    // ways ("Mounting boot media failed" / "/sbin/init not found in new
    // root", both dropping to an emergency shell with no login prompt).
    // Match bootstrap-guest's proven-working cmdline exactly, even though
    // this tool itself doesn't need apk for anything.
    commandLine: "console=hvc0 ip=dhcp alpine_repo=\(alpineRepo) quiet",
    cpuCount: 1,
    memorySize: 512 * 1024 * 1024,
    serialAttachment: session.attachment,
    directoryShares: [(tag: "host_share", path: appSupport, readOnly: false)]
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

// loop, squashfs, fuse, and virtiofs are already resident in the running
// kernel by the time we get a shell (confirmed via /proc/modules) - the
// initramfs's early-boot phase loads them to get storage/network/virtiofs
// working before switch_root, and module state persists across that switch
// even though the .ko FILES themselves don't (the post-switch live root is
// a fresh tmpfs with no /usr/lib/modules at all - confirmed empirically,
// insmod-by-path fails with ENOENT). No insmod needed - straight to mounting.
let modloopMountDir = "/mnt/modloop"
let steps: [(command: String, marker: String)] = [
    ("mkdir -p /mnt/host && mount -t virtiofs host_share /mnt/host", "MSL_STEP_1_DONE"),
    ("mkdir -p \(modloopMountDir) && mount -t squashfs -o loop,ro /mnt/host/modloop-virt \(modloopMountDir)", "MSL_STEP_2_DONE"),
    ("mkdir -p /mnt/host/modules", "MSL_STEP_3_DONE"),
    ("""
     find \(modloopMountDir) -type f \\( -iname '*vsock*' -o -iname 'ext4*' -o -iname 'jbd2*' \\
       -o -iname 'mbcache*' -o -iname 'crc16*' \\) -exec cp -v {} /mnt/host/modules/ \\;
     """, "MSL_STEP_4_DONE"),
    ("ls -la /mnt/host/modules | cat", "MSL_STEP_5_DONE"),
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

log("--- modules extracted, shutting down guest")
session.sendLine("echo MSL_EXTRACT_DONE")
session.sendLine("poweroff -f")

do {
    try session.waitFor("MSL_EXTRACT_DONE", timeout: 30)
} catch {
    log("didn't see the final marker, but continuing to wait for shutdown")
}

let shutdownDeadline = Date().addingTimeInterval(30)
while vm.state != .stopped, Date() < shutdownDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
}

if vm.state == .stopped {
    log("guest stopped cleanly - modules at \(modulesOutputDir.path)")
} else {
    log("guest didn't report stopped within 30s (state: \(vm.state)) - check the transcript")
}
