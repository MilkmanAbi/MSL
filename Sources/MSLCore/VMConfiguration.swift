// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
import Virtualization

/// User-facing / persisted configuration for a single guest VM instance.
public struct VMConfiguration: Codable, Equatable {
    /// Instance name - identifies this VM's snapshot files and is how `msl`
    /// picks which one to connect to (`msl <name>`). Also used as the guest
    /// hostname (in principle - the live-netboot init script ignores
    /// `hostname=`, confirmed on a real boot; unverified whether a disk-
    /// booted guest's own `/etc/hostname` respects it).
    public var name: String

    /// How the guest boots - see `BootMode`'s doc comment for the tradeoffs.
    public var bootMode: BootMode

    /// Path to the guest root disk image (raw format - VZ wants raw, not
    /// qcow2). Required for `.persistentDisk`, unused for `.liveNetboot`.
    public var diskImagePath: String?

    /// Path to the linux kernel image used by VZLinuxBootLoader - the raw
    /// ARM64 Image, NOT Alpine's zboot-wrapped vmlinuz-virt (see
    /// GuestImageTools.extractZbootImage). For `.persistentDisk`, this must
    /// be the kernel extracted *from that disk's own* /boot (matching
    /// `/lib/modules` version) - not the netboot tarball's, which will be a
    /// different kernel build entirely. See README's "Guest boot strategy".
    public var kernelPath: String

    /// Path to the initial ramdisk - same "must match the disk" caveat as
    /// `kernelPath` applies for `.persistentDisk`.
    public var initrdPath: String

    /// vCPU count. Default kept low on purpose - see design notes on leanness.
    public var cpuCount: Int

    /// Memory in bytes. Default kept low on purpose.
    public var memorySize: UInt64

    /// Host directories shared into the guest via virtiofs.
    public var sharedFolders: [SharedFolder]

    /// Whether to attach the Rosetta directory share for x86-64 binary
    /// support in-guest.
    public var rosettaEnabled: Bool

    /// vsock port the guest's shell listener (`shellinit`) accepts
    /// connections on.
    public var shellVsockPort: UInt32

    /// vsock port the guest's file-ops listener (`fileopsd`) accepts
    /// connections on - the MSL Sandbox's Finder-into-Linux direction, one
    /// connection per request/response (see `Guest/init/fileopsd.c`'s wire
    /// format doc comment).
    public var fileOpsVsockPort: UInt32

    /// vsock port `mslhd` listens on (host-side) for the guest's X11
    /// tunnel (`x11tunnel`, see `Guest/init/x11tunnel.c`) to connect out
    /// to - the *opposite* direction from `shellVsockPort`/
    /// `fileOpsVsockPort`, where the guest listens and the host connects.
    /// The guest side dials out fresh per local X client (an X app
    /// connecting to `DISPLAY=:0`), so it's naturally the guest that
    /// initiates - see the archived `msl-vgpu.md` design's Phase 1. `5001`
    /// is what that doc suggests, written without knowing this codebase
    /// already owns 5001 for `fileOpsVsockPort` - `5002` avoids the
    /// collision.
    public var displayVsockPort: UInt32

    /// vsock port `mslhd` listens on (host-side) for `X11Server`
    /// (`mslgd` - see the archived `msl-vgpu.md` design's Phase 2) - a
    /// second, independent guest `x11tunnel` connects here instead of
    /// `displayVsockPort` to bypass XQuartz entirely and get windows
    /// rendered by this project's own from-scratch X11 implementation.
    /// Deliberately a different port from `displayVsockPort` rather than
    /// replacing it - Phase 1 (XQuartz-backed) and Phase 2 (native) can
    /// run side by side during development, same reasoning as
    /// `displayVsockPort` itself avoiding a collision with
    /// `fileOpsVsockPort`.
    public var mslgdVsockPort: UInt32

    /// vsock port `mslhd` listens on (host-side) for the guest's cage
    /// bridge (`Guest/init/wayland-tests/cagebridge.c` - see
    /// `cage-planning.md`'s Phase 3) to connect out to - same "guest
    /// dials out, host listens" direction as `displayVsockPort`/
    /// `mslgdVsockPort`, for the same reason (the guest side is the one
    /// that knows when its Wayland/cage session actually has a frame to
    /// send). Separate port so cage's frame stream can run alongside
    /// either X11 path without colliding - `5000`-`5003` are already
    /// owned by `shellVsockPort`/`fileOpsVsockPort`/`displayVsockPort`/
    /// `mslgdVsockPort`.
    /// Where `trafficd` listens - the guest's own view of its network, for
    /// the Traffic Monitor. Guest listens, host connects, same direction as
    /// `shellVsockPort`/`fileOpsVsockPort`.
    public var trafficVsockPort: UInt32 = 5006

    /// vsock port `memd` accepts on - the guest half of dynamic memory
    /// allocation. Only consulted when the instance's `ResourcePolicy` is in
    /// dynamic mode; a manual-mode instance never connects.
    public var memoryVsockPort: UInt32 = 5007

    public var cageVsockPort: UInt32

    /// vsock port `mslhd` listens on (host-side) for the guest's cage
    /// INPUT bridge (`Guest/init/wayland-tests/cageinput.c` - Phase 3
    /// step 3 of `cage-planning.md`) to connect out to. Deliberately a
    /// SEPARATE port/connection from `cageVsockPort`'s frame stream, not
    /// the same connection used bidirectionally - see `CageInputBridge`'s
    /// doc comment for why (a 3.6MB frame under sustained streaming can
    /// block the frame-stream connection's write path for long enough to
    /// starve input if they shared one connection).
    public var cageInputVsockPort: UInt32

    /// Alpine repo URL. For `.liveNetboot`, this is the live boot's own
    /// `alpine_repo=` kernel param - the netboot environment fetches its
    /// *own root content* from here, not just apk packages later. Unused
    /// for `.persistentDisk` (the disk already has its own root).
    public var alpineRepo: String

    /// Host directory containing the vsock/ext4 kernel modules extracted by
    /// `extract-guest-modules`. Only used by `.liveNetboot`'s cold-boot
    /// script - `.persistentDisk` boots a real installed system whose own
    /// `/lib/modules` (installed via the `linux-virt` apk package) already
    /// has everything needed, loadable the normal way (`modprobe`, driven
    /// by OpenRC), confirmed by inspecting a real bootstrapped disk image.
    public var modulesPath: String?

    /// Host directory containing the precompiled `shellinit` binary (see
    /// `build-shellinit`). For `.liveNetboot`, shared into the guest
    /// read-only and exec'd directly by the cold-boot script. For
    /// `.persistentDisk`, unused at runtime - `shellinit` needs to already
    /// be installed onto the disk itself (`/usr/local/bin/shellinit`,
    /// wired into OpenRC's `local` service) as a one-time step, the same
    /// way `Guest/init/README.md` always described - see README.
    public var shellinitBinPath: String?

    public enum BootMode: String, Codable, Equatable {
        /// Ephemeral: fetches a fresh Alpine live root over the network on
        /// every cold boot (no persistence across boots), and needs
        /// `VMManager.performColdBootSetup`'s scripted virtiofs-share +
        /// `insmod` + exec dance to get vsock working at all, because the
        /// live root has no `/lib/modules` post-`switch_root` (see
        /// README's "Guest bootstrap findings"). This is what got the
        /// project's first working end-to-end shell, and is still the
        /// fallback for a fresh instance with no disk image yet.
        case liveNetboot
        /// Persistent: boots a real installed Alpine system from
        /// `diskImagePath` (produced by `bootstrap-guest`), using the
        /// kernel/initramfs extracted *from that same disk's* `/boot` (see
        /// README's "Guest boot strategy" for why kernel/module version
        /// matching mattered here). No cold-boot scripting needed at all -
        /// `shellinit` starts as a normal OpenRC `local` service, the same
        /// way any other Alpine service would.
        case persistentDisk
    }

    public init(
        name: String,
        bootMode: BootMode = .liveNetboot,
        diskImagePath: String? = nil,
        kernelPath: String,
        initrdPath: String,
        cpuCount: Int = VMConfiguration.defaultCPUCount(),
        memorySize: UInt64 = VMConfiguration.defaultMemorySize(),
        sharedFolders: [SharedFolder] = [],
        rosettaEnabled: Bool = false,
        shellVsockPort: UInt32 = 5000,
        fileOpsVsockPort: UInt32 = 5001,
        displayVsockPort: UInt32 = 5002,
        mslgdVsockPort: UInt32 = 5003,
        cageVsockPort: UInt32 = 5004,
        cageInputVsockPort: UInt32 = 5005,
        trafficVsockPort: UInt32 = 5006,
        memoryVsockPort: UInt32 = 5007,
        alpineRepo: String = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main",
        modulesPath: String? = nil,
        shellinitBinPath: String? = nil,
        kernelCommandLineOverride: String? = nil,
        diskStorageKey: String? = nil
    ) {
        self.kernelCommandLineOverride = kernelCommandLineOverride
        self.diskStorageKey = diskStorageKey
        self.name = name
        self.bootMode = bootMode
        self.diskImagePath = diskImagePath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.sharedFolders = sharedFolders
        self.rosettaEnabled = rosettaEnabled
        self.shellVsockPort = shellVsockPort
        self.fileOpsVsockPort = fileOpsVsockPort
        self.displayVsockPort = displayVsockPort
        self.mslgdVsockPort = mslgdVsockPort
        self.trafficVsockPort = trafficVsockPort
        self.memoryVsockPort = memoryVsockPort
        self.cageVsockPort = cageVsockPort
        self.cageInputVsockPort = cageInputVsockPort
        self.alpineRepo = alpineRepo
        self.modulesPath = modulesPath
        self.shellinitBinPath = shellinitBinPath
    }

    /// Kernel command line. `.liveNetboot` needs `ip=dhcp alpine_repo=...`
    /// to fetch its live root at all (confirmed on a real boot: omitting
    /// either, even with the other set, drops to an emergency shell with
    /// no login prompt - see README). `.persistentDisk` needs
    /// `rootfstype=ext4` - confirmed on a real boot that omitting it drops
    /// to the initramfs emergency shell with "mount: mounting /dev/vda on
    /// /sysroot failed: No such file or directory" even though `/dev/vda`
    /// exists and is a valid ext4 filesystem (verified with `blkid`): the
    /// init script's root-mount call doesn't pass `-t`, and without a type
    /// hint the kernel has no name to `request_module` against, so `ext4.
    /// ko` (present in `/lib/modules` but not preloaded by mkinitfs) never
    /// gets loaded before the mount attempt. Passing `rootfstype=ext4`
    /// gives the init script (and the kernel's module autoload) the type
    /// name it needs. `quiet` is dropped in both cases since a human might
    /// be watching mslhd's own log for boot progress.
    // MARK: - Default sizing

    /// vCPUs for a new instance: half the host's logical cores, clamped to
    /// a sensible range.
    ///
    /// The previous fixed default of 2 ignored the machine entirely, which
    /// on anything modern left most of it unused - and this project's
    /// headline feature is running real GUI applications, which are not
    /// single-threaded. vCPUs are time-shared rather than reserved, so
    /// several instances each holding this many is normal.
    ///
    /// Overridable with `MSL_VM_CPUS`.
    public static func defaultCPUCount() -> Int {
        let requested = ProcessInfo.processInfo.environment["MSL_VM_CPUS"].flatMap(Int.init)
        return cpuCount(
            forHostCores: ProcessInfo.processInfo.processorCount,
            frameworkMaximum: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            frameworkMinimum: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            requested: requested)
    }

    /// Pure policy, so it can be checked for hosts other than this one.
    static func cpuCount(
        forHostCores cores: Int, frameworkMaximum: Int, frameworkMinimum: Int,
        requested: Int? = nil
    ) -> Int {
        let target = requested.map { max($0, 1) } ?? max(2, cores / 2)
        // The framework's own bounds are the ones actually enforced;
        // `cores` only keeps the default sensible on small machines.
        let ceiling = min(8, max(frameworkMinimum, min(frameworkMaximum, max(cores, frameworkMinimum))))
        return min(max(target, frameworkMinimum), max(ceiling, frameworkMinimum))
    }

    /// RAM for a new instance, sized from the host.
    ///
    /// Two rules, whichever is smaller. A share of the host (a sixth), and
    /// a headroom rule: `maxConcurrentRunning` instances together must not
    /// claim more than three quarters of the machine, since that many can
    /// be up at once. The headroom rule is what makes this safe on a small
    /// host - a flat 2 GB floor would have let four instances claim all
    /// 8 GB of an 8 GB Mac, which is worse than the 1 GB default it
    /// replaced.
    ///
    /// The old 1 GB default is below what a desktop Linux application
    /// actually wants; GIMP or Krita on 1 GB spends its time swapping.
    ///
    /// The ceiling is a hibernation constraint as much as a host one:
    /// saving a guest writes its entire RAM to disk, and
    /// `SystemResilienceMonitor` bounds that before a shutdown proceeds
    /// regardless.
    ///
    /// Overridable with `MSL_VM_MEMORY_MB`.
    public static func defaultMemorySize() -> UInt64 {
        let requested = ProcessInfo.processInfo.environment["MSL_VM_MEMORY_MB"]
            .flatMap(UInt64.init).map { $0 * 1024 * 1024 }
        return memorySize(
            forHostMemory: ProcessInfo.processInfo.physicalMemory,
            frameworkMaximum: VZVirtualMachineConfiguration.maximumAllowedMemorySize,
            frameworkMinimum: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            concurrentInstances: UInt64(InstanceRegistry.maxConcurrentRunning),
            requested: requested)
    }

    /// Pure policy, so it can be checked for hosts other than this one.
    static func memorySize(
        forHostMemory host: UInt64, frameworkMaximum: UInt64, frameworkMinimum: UInt64,
        concurrentInstances: UInt64, requested: UInt64? = nil
    ) -> UInt64 {
        let share = host / 6
        let headroom = concurrentInstances > 0 ? (host / 4 * 3) / concurrentInstances : share
        var target = requested ?? min(share, headroom)

        // An absolute floor of 1 GB - the old default - so a very small
        // host still gets something bootable rather than being pushed
        // under it by the headroom rule.
        target = max(target, 1024 * 1024 * 1024)
        target = min(target, 8 * 1024 * 1024 * 1024)
        target = min(max(target, frameworkMinimum), frameworkMaximum)
        // Virtualization requires a whole number of megabytes and rejects
        // the configuration outright otherwise.
        return (target / (1024 * 1024)) * (1024 * 1024)
    }

    /// `.persistentDisk`: root is the NVMe namespace (`VMManager` attaches
    /// the disk to an NVMe controller - see `buildVirtualMachine`), and
    /// `rootfstype=ext4` is still required (see the note above).
    ///
    /// `psi=1`: the kernel is built with pressure-stall information but
    /// `CONFIG_PSI_DEFAULT_DISABLED=y`. Dynamic memory's controller reads
    /// `/proc/pressure/memory` when it exists and is merely slower to
    /// notice a struggling guest without it (`memd`, `BalloonController`).
    public var kernelCommandLine: String {
        switch bootMode {
        case .liveNetboot:
            return "console=hvc0 ip=dhcp alpine_repo=\(alpineRepo)"
        case .persistentDisk:
            return kernelCommandLineOverride ?? "console=hvc0 root=/dev/nvme0n1 rootfstype=ext4 rw psi=1"
        }
    }

    /// A custom image's own command line (`image.json`), replacing the
    /// persistent-disk default above.
    public var kernelCommandLineOverride: String?

    /// The disk's name for `DiskStorage`. Nil means the disk file's own
    /// name, which is right for published distros; a custom image's disk is
    /// usually also called `rootfs.img` and must not share Alpine's policy
    /// (see `GuestBootFiles.storageKey`).
    public var diskStorageKey: String?

    /// A MAC address for the network device, deterministic from the
    /// instance name. `VZNetworkDeviceConfiguration.MACAddress` defaults to
    /// a random address if left unset - confirmed on a real run that this
    /// breaks save/restore entirely: `VMManager` builds a fresh
    /// `VZVirtioNetworkDeviceConfiguration` every time it constructs a VM
    /// (cold boot, and again before every restore), so an unset MAC gets a
    /// *different* random value each time, and `restoreMachineStateFrom`
    /// rejects the mismatch against the saved state with `VZErrorDomain
    /// Code=12 "invalid argument"`. Deriving it from the name (rather than
    /// generating once and persisting it) means every `VMConfiguration`
    /// built for this instance - across daemon restarts too - ends up with
    /// the exact same address with no extra state to keep in sync.
    public var macAddressString: String {
        // FNV-1a, not Swift's Hasher - Hasher is deliberately randomized
        // per process (hash-flooding protection), which would defeat the
        // entire point here: this must be identical across daemon restarts.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var bytes = (0..<6).map { UInt8((hash >> (8 * $0)) & 0xFF) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02 // unicast + locally-administered bits
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// A single host directory exposed into the guest via virtiofs.
public struct SharedFolder: Codable, Equatable {
    /// virtiofs mount tag, referenced from /etc/fstab or a mount command
    /// inside the guest.
    public var tag: String

    /// Host path. Expected to come from a security-scoped bookmark in the
    /// app; the CLI/daemon just need the resolved path at connect time.
    public var hostPath: String

    public var readOnly: Bool

    public init(tag: String, hostPath: String, readOnly: Bool = false) {
        self.tag = tag
        self.hostPath = hostPath
        self.readOnly = readOnly
    }
}
