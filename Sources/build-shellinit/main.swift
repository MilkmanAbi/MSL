import Foundation
import MSLCore
#if canImport(Virtualization)
import Virtualization
#endif

/*
 * build-shellinit
 *
 * One-off tool that cross-builds Guest/init's guest binaries (shellinit.c,
 * fileopsd.c, x11tunnel.c) against musl inside a real Alpine aarch64
 * environment (no cross-compiler set up on the host), and caches the
 * resulting binaries so `provision-disk-image`/`bootstrap-distro` can
 * install them onto every distro's disk instead of recompiling every time.
 * Name predates fileopsd.c/x11tunnel.c existing - kept as-is rather than
 * renamed, see README.
 *
 * Not part of mslhd's runtime path - run it once (or after editing
 * shellinit.c/fileopsd.c):
 *
 *     swift build -c release --product build-shellinit
 *     codesign --force --sign - \
 *       --entitlements Resources/MSLApp/MSLApp.entitlements \
 *       .build/release/build-shellinit
 *     .build/release/build-shellinit
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
let guestInitDir = packageRoot.appendingPathComponent("Guest/init")
let binOutputDir = appSupport.appendingPathComponent("bin", isDirectory: true)

let alpineRepo = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main"

try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: binOutputDir, withIntermediateDirectories: true)
guard FileManager.default.fileExists(atPath: guestInitDir.appendingPathComponent("shellinit.c").path),
      FileManager.default.fileExists(atPath: guestInitDir.appendingPathComponent("fileopsd.c").path),
      FileManager.default.fileExists(atPath: guestInitDir.appendingPathComponent("x11tunnel.c").path) else {
    log("Guest/init/shellinit.c, fileopsd.c, or x11tunnel.c not found under \(guestInitDir.path) - run from the package root")
    exit(1)
}

let (kernelURL, initrdURL) = try GuestImageTools.ensureKernelAndInitrd(netbootTarball: netbootTarball, appSupport: appSupport)

let session = SerialConsoleSession()
let config = try LiveBootConfig.headlessConfiguration(
    kernelURL: kernelURL,
    initrdURL: initrdURL,
    commandLine: "console=hvc0 ip=dhcp alpine_repo=\(alpineRepo) quiet",
    cpuCount: 2,
    memorySize: 1024 * 1024 * 1024,
    serialAttachment: session.attachment,
    directoryShares: [
        (tag: "guest_src", path: guestInitDir, readOnly: true),
        (tag: "guest_bin", path: binOutputDir, readOnly: false),
    ]
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

// musl (Alpine's libc) has forkpty in libc directly - no -lutil needed,
// unlike glibc. See Guest/init/Makefile and README.
let steps: [(command: String, marker: String)] = [
    ("apk update", "MSL_STEP_1_DONE"),
    ("apk add gcc musl-dev linux-headers", "MSL_STEP_2_DONE"), // linux-headers has linux/vm_sockets.h
    ("mkdir -p /mnt/src && mount -t virtiofs guest_src /mnt/src", "MSL_STEP_3_DONE"),
    ("mkdir -p /mnt/bin && mount -t virtiofs guest_bin /mnt/bin", "MSL_STEP_4_DONE"),
    // -static: shellinit gets installed onto every distro's disk (Alpine,
    // Debian, Ubuntu, ...), not just booted from the musl environment it's
    // compiled in. A dynamically-linked build bakes in musl's interpreter
    // path (/lib/ld-musl-aarch64.so.1), which doesn't exist on a
    // glibc-based rootfs - confirmed live that installing that binary onto
    // a Debian/Ubuntu disk makes it fail to exec at all, so its systemd
    // service crash-loops instead of ever binding vsock. musl makes fully
    // static binaries easy and small; there's no reason a tiny,
    // syscall-heavy program like this should dynamically link at all.
    ("gcc -O2 -Wall -Wextra -static -o /mnt/bin/shellinit /mnt/src/shellinit.c", "MSL_STEP_5_DONE"),
    ("gcc -O2 -Wall -Wextra -static -o /mnt/bin/fileopsd /mnt/src/fileopsd.c", "MSL_STEP_5B_DONE"),
    // Ultra-experimental (see the archived msl-vgpu.md design) - same
    // static-musl reasoning as shellinit/fileopsd above.
    ("gcc -O2 -Wall -Wextra -static -o /mnt/bin/x11tunnel /mnt/src/x11tunnel.c", "MSL_STEP_5C_DONE"),
    ("chmod +x /mnt/bin/shellinit /mnt/bin/fileopsd /mnt/bin/x11tunnel", "MSL_STEP_6_DONE"),
    ("ls -la /mnt/bin | cat", "MSL_STEP_7_DONE"),
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

log("--- shellinit built, shutting down guest")
session.sendLine("echo MSL_BUILD_DONE")
session.sendLine("poweroff -f")

do {
    try session.waitFor("MSL_BUILD_DONE", timeout: 30)
} catch {
    log("didn't see the final marker, but continuing to wait for shutdown")
}

let shutdownDeadline = Date().addingTimeInterval(30)
while vm.state != .stopped, Date() < shutdownDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
}

if vm.state == .stopped {
    // The .app bundle context on the host needs the binaries marked
    // executable too, not just inside the guest - virtiofs preserves the
    // mode bit, but set it explicitly in case that ever changes.
    for name in ["shellinit", "fileopsd", "x11tunnel"] {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binOutputDir.appendingPathComponent(name).path
        )
    }
    log("guest stopped cleanly - shellinit/fileopsd/x11tunnel at \(binOutputDir.path)")
} else {
    log("guest didn't report stopped within 30s (state: \(vm.state)) - check the transcript")
}
