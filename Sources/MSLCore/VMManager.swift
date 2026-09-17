// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
import AppKit
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(NetFS)
import NetFS
#endif

/// Owns the lifecycle of a single guest VM instance: cold boot (plus the
/// one-time serial-console setup that gets vsock working - see
/// `performColdBootSetup`), lightweight pause/resume ("suspension"),
/// save-to-disk-and-stop ("hibernation"), named snapshots, and handing out
/// vsock connections for shell sessions.
///
/// Concurrency model: `VZVirtualMachine`'s header is explicit that every
/// operation on the machine must happen on a single queue - either the main
/// queue (the convenience initializer) or a private queue supplied via the
/// `VZVirtualMachine(configuration:queue:)` designated initializer. This
/// class uses the latter: `vmQueue` is that queue, all mutable state is
/// only ever touched from closures dispatched onto it, and every public
/// method here hops onto `vmQueue` before touching the VM. Callers can
/// invoke these methods from any thread/Task. `@unchecked Sendable`
/// reflects that this safety is enforced manually by funneling everything
/// through `vmQueue`, not something the compiler can verify structurally.
public final class VMManager: NSObject, @unchecked Sendable {

    public let configuration: VMConfiguration

    private let vmQueue: DispatchQueue

    /// Only ever read/written from within a `vmQueue` closure.
    private var virtualMachine: VZVirtualMachine?

    /// The share that was in place before the sandbox revoked it, so
    /// reopening that gate puts back the same one rather than a guess at
    /// how it was built. Only ever read/written from within a `vmQueue`
    /// closure.
    private var savedDirectoryShare: VZDirectoryShare?

    /// The current VM's serial console session, used once at cold boot to
    /// script module loading + starting shellinit (see
    /// `performColdBootSetup`). Rebuilt every time a new `VZVirtualMachine`
    /// is constructed - it's tied 1:1 to that VM's serial port pipes.
    /// Only ever read/written from within a `vmQueue` closure.
    private var coldBootSession: SerialConsoleSession?

    /// Retains each shell session's `VZVirtioSocketConnection` for as long
    /// as its raw fd is in use on this side. The fd is owned by this object
    /// and is closed automatically when it deallocates - callers must never
    /// also manually `close()` the fd themselves (see `releaseConnection`).
    /// Only ever read/written from within a `vmQueue` closure.
    private var openConnections: [Int32: VZVirtioSocketConnection] = [:]

    /// Guards against a double-boot race: two `ensureRunning()` calls
    /// queued back-to-back on `vmQueue` (e.g. two concurrent shell sessions
    /// for the same instance) would otherwise both see `virtualMachine`
    /// either `nil` or not yet `.running`/`.paused` - `vm.start`/`vm.resume`
    /// are async and don't update `.state` before their queued closure
    /// returns, so the second call would fall through to `buildVirtualMachine
    /// ()` again and start a SECOND independent `VZVirtualMachine` against
    /// the same shared disk image/vsock ports out from under the first's
    /// still-pending start. Confirmed live as the cause of a
    /// `noDescriptorReceived` failure on BOTH sides when two `msl`
    /// invocations hit the same instance at nearly the same time. While
    /// `true`, any further `ensureRunning()` call queues its continuation
    /// here instead of re-entering the build/start/resume logic; `finish
    /// Starting` resolves all of them together once the in-flight
    /// start/resume/restore settles. Only ever touched from within a
    /// `vmQueue` closure.
    private var isStarting = false

    /// Set while a filesystem check, repair or maintenance boot owns this
    /// instance's disk. `ensureRunning` refuses while it is set: booting a
    /// guest on an image e2fsck is rewriting would corrupt it outright.
    /// Only ever read or written on `vmQueue`.
    private var maintenanceInProgress = false
    private var pendingStartContinuations: [CheckedContinuation<Void, Error>] = []

    /// The MSL Sandbox's "Linux -> Finder" bridge - `webdavLock` guards
    /// these two rather than `vmQueue` because `startFileSandbox()` runs
    /// off `vmQueue` entirely on purpose (see its doc comment), while
    /// `stopFileSandbox()` is called from within `vmQueue` closures
    /// (`hibernate`/`snapshotSave`/`snapshotRestore`) - both can touch
    /// these concurrently.
    private let webdavLock = NSLock()
    private var webdavServer: WebDAVServer?
    private var webdavMountPath: String?

    /// Bumped by every `stopFileSandbox()`, and claimed by `webdavStarting`
    /// for the length of a start. Mounting takes seconds, and a stop in that
    /// window used to find nothing to unmount: the start then recorded a
    /// bridge for a VM that was gone, macOS's webdavfs kept polling it, and
    /// each poll went through `ensureRunning()` - waking a hibernated
    /// instance moments after it was saved and throwing its saved state
    /// away. Five such mounts had piled up by the time it was found
    /// (2026-09-14).
    private var webdavGeneration: UInt64 = 0
    private var webdavStarting = false

    /// Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 1
    /// and `DisplayBridge`'s doc comment) - only ever non-nil after an
    /// explicit `startDisplayBridge()` call (`msl gui <instance>`), never
    /// started automatically alongside the shell/file-ops bridges. Only
    /// ever read/written from within a `vmQueue` closure, same rule as
    /// `openConnections`/`virtualMachine`.
    private var displayBridge: DisplayBridge?

    /// Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 2
    /// and `X11Server`'s doc comment) - the from-scratch native X11
    /// server, an alternative to `displayBridge`'s XQuartz-tunnel path.
    /// Same "only ever non-nil after an explicit start call, only ever
    /// touched from `vmQueue`" rules as `displayBridge`.
    private var x11Server: X11Server?

    /// Links, mail and folders from Linux apps, carried out on the Mac -
    /// see `HostOpenService`. Unlike the display paths above, running
    /// whenever the VM is: a request can come from any app MSL launched.
    /// Only touched from `vmQueue`.
    private var hostOpenService: HostOpenService?

    /// `cage-planning.md` Phase 3 - the host side of the cage/Wayland
    /// frame stream, an independent third listener alongside
    /// `displayBridge`/`x11Server` on its own port (`cageVsockPort`).
    /// Same "only ever non-nil after an explicit start call, only ever
    /// touched from `vmQueue`" rules.
    private var cageBridge: CageBridge?

    /// `cage-planning.md` Phase 3 step 3 - the host side of host->guest
    /// input injection, an independent listener/port from `cageBridge`
    /// (see `CageInputBridge`'s doc comment for why). Same "only ever
    /// non-nil after an explicit start call, only ever touched from
    /// `vmQueue`" rules.
    private var cageInputBridge: CageInputBridge?

    /// `cage-planning.md` Phase 4 - the real, on-screen live view of a
    /// cage session (see `CageCanvasView`'s doc comment). Distinct from
    /// `cageBridge`/`cageInputBridge` (which just move bytes) - this is
    /// the actual `NSWindow` a user looks at and clicks/types into.
    /// `nil` until `startCageView()` is called (`msl cage-view
    /// <instance>`); only ever touched from `vmQueue`, same as the
    /// other cage state, EXCEPT the window/view themselves which are
    /// only ever touched from the main thread (see `startCageView`'s
    /// own comment on why the AppKit object creation itself dispatches
    /// there rather than running on `vmQueue`).
    private var cageWindow: NSWindow?
    private var cageCanvasView: CageCanvasView?

    /// The address `WebDAVServer` binds for this instance's sandbox mount.
    /// Always the canonical loopback address - unlike Linux, macOS's `lo0`
    /// does NOT treat the rest of `127.0.0.0/8` as automatically usable;
    /// only `127.0.0.1` is actually assigned out of the box (confirmed via
    /// `ifconfig lo0` and a live `bind()` failure, `EADDRNOTAVAIL`, when a
    /// derived-per-instance `127.x.y.z` address was tried here first -
    /// every other address in that range needs an explicit, root-requiring
    /// `ifconfig lo0 alias` first). Concurrent instances therefore all
    /// mount against the same host, differentiated only by port - not a
    /// real collision, since `NetFSMountURLSync` names the resulting
    /// `/Volumes` entry after the host either way (see `startFileSandbox`'s
    /// doc comment on why there's no better name available for a WebDAV
    /// mount), and macOS already auto-suffixes a second mount of the same
    /// name (`127.0.0.1-1`, etc.) exactly like it does for two disk images
    /// that happen to share a volume label.
    private var webdavLoopbackAddress: String { "127.0.0.1" }

    /// Where this instance's guest filesystem is mounted on the host, or
    /// `nil` when it isn't - the mount only exists while the VM runs.
    ///
    /// Exposed so a client (the app's file browser) can find the mount at
    /// all: `NetFSMountURLSync` picks the path itself, and it is named
    /// after the loopback address rather than the instance, so there is no
    /// path a caller could construct for itself.
    public var sandboxMountPath: String? {
        webdavLock.lock()
        defer { webdavLock.unlock() }
        return webdavMountPath
    }

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MSL", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The implicit "resume where I left off" snapshot hibernate uses.
    private var snapshotURL: URL {
        appSupportDir.appendingPathComponent("vm-\(configuration.name).state")
    }

    private func namedSnapshotURL(_ name: String) -> URL {
        appSupportDir.appendingPathComponent("vm-\(configuration.name)-\(name).state")
    }

    private var machineIdentifierURL: URL {
        appSupportDir.appendingPathComponent("vm-\(configuration.name).machineid")
    }

    /// `VZGenericPlatformConfiguration.machineIdentifier` is explicitly
    /// documented (`VZGenericPlatformConfiguration.h`) as required to
    /// match exactly between a saved VM and whatever restores it -
    /// `config.platform` defaults to a fresh `VZGenericPlatformConfiguration`
    /// with a brand-new random identifier on every single
    /// `VZVirtualMachineConfiguration()`, which we build fresh on every
    /// cold boot and again before every restore attempt. Persisting one
    /// identifier per instance and reusing it every time is required for
    /// `restoreMachineStateFrom` to have any chance of working - this was
    /// found *after* fixing an analogous issue with the network device's
    /// MAC address (also defaults to random per-build) didn't fully
    /// resolve the "invalid argument" restore failures; this one is more
    /// fundamental, per the header, than the MAC address ever was.
    private func loadOrCreateMachineIdentifier() -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: machineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try? identifier.dataRepresentation.write(to: machineIdentifierURL)
        return identifier
    }

    public init(configuration: VMConfiguration) {
        self.configuration = configuration
        self.vmQueue = DispatchQueue(label: "com.msl.mslhd.vm.\(configuration.name)")
        // Load the sandbox here, not at first start.
        //
        // A manager exists as soon as anything asks about an instance -
        // `msl suspend` on a stopped VM builds one - and until this line
        // existed, such a manager reported `.open` for an instance whose
        // stored policy was fully sealed. The UI showed four open gates over
        // a sealed policy, and toggling one would have written that lie back
        // over the real one, silently opening the other three.
        self.sandboxPolicyStorage = SandboxPolicyStore.load(instance: configuration.name)
        super.init()
    }

    public var isRunning: Bool {
        vmQueue.sync { virtualMachine?.state == .running }
    }

    public enum InstanceState: String {
        case stopped, running, paused, transitioning
    }

    public func currentState() -> InstanceState {
        vmQueue.sync {
            switch virtualMachine?.state {
            case .none, .some(.stopped): return .stopped
            case .some(.running): return .running
            case .some(.paused): return .paused
            // An errored VM holds nothing and can never be resumed - only
            // rebuilt - so it is `stopped` for every purpose that matters.
            // Reporting it as `transitioning` (what `default` did) left a
            // failed start looking permanently mid-flight: the UI showed a
            // spinner that never resolved, and the daemon's concurrency
            // cap counted a slot that nothing was using.
            case .some(.error): return .stopped
            default: return .transitioning
            }
        }
    }

    /// Ensures a VM is up and running: unpauses if paused, resumes from the
    /// implicit snapshot if one exists, or cold-boots (running the one-time
    /// serial-console setup - see `performColdBootSetup`) otherwise. A
    /// no-op if already running. Safe to call from any thread.
    public func ensureRunning() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // First - before even the already-running fast path. During
                // a maintenance boot the VM *is* running: letting a shell
                // session through would hand it a guest with no shell daemon,
                // and the idle-suspend after that session ended would pause
                // the guest in the middle of a repair. Refused rather than
                // queued, because a repair can take minutes and a start that
                // silently waited that long would look hung.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }

                if let vm = virtualMachine, vm.state == .running {
                    continuation.resume()
                    return
                }

                // A start/resume/restore is already in flight for this
                // instance (queued behind an earlier `ensureRunning()` call
                // on this same `vmQueue`) - wait for it instead of
                // re-entering the logic below, which would otherwise race
                // it (see `isStarting`'s doc comment).
                if isStarting {
                    pendingStartContinuations.append(continuation)
                    return
                }

                if let vm = virtualMachine, vm.state == .paused {
                    isStarting = true
                    vm.resume { result in
                        switch result {
                        case .success: self.resumeAfterVMUp(continuation)
                        case .failure(let error): self.finishStarting(.failure(error), primary: continuation)
                        }
                    }
                    return
                }

                isStarting = true

                // Whatever stopped VM might still be held goes before the new
                // one is built: its XPC process keeps the disk image locked,
                // and building a second VM on that disk fails with "The storage
                // device attachment is invalid". Every stop path releases it now
                // too; this makes a missed one harmless. (Restores that "failed
                // unreliably" before 2026-09-14 were most likely this.)
                virtualMachine = nil

                let vm: VZVirtualMachine
                let session: SerialConsoleSession
                do {
                    (vm, session) = try buildVirtualMachine()
                } catch {
                    finishStarting(.failure(error), primary: continuation)
                    return
                }
                vm.delegate = self
                virtualMachine = vm
                coldBootSession = session

                if FileManager.default.fileExists(atPath: snapshotURL.path) {
                    vm.restoreMachineStateFrom(url: snapshotURL) { restoreError in
                        if let restoreError {
                            // Snapshot state can be invalidated by host
                            // sleep/wake on some macOS versions - fall back
                            // to a cold boot (with its setup script) rather
                            // than failing outright. Restore has proven
                            // unreliable in practice even outside of a
                            // sleep/wake scenario (see README's "Known
                            // Issues") - this is logged loudly rather than
                            // swallowed, since a silent fallback here once
                            // already masked that bug and looked identical
                            // to a genuine successful resume from outside.
                            FileHandle.standardError.write(
                                "VMManager[\(self.configuration.name)]: restore failed (\(restoreError)) - falling back to cold boot\n".data(using: .utf8)!
                            )
                            try? FileManager.default.removeItem(at: self.snapshotURL)
                            vm.start { result in
                                switch result {
                                case .success:
                                    self.afterColdStart(session: session, continuation: continuation)
                                case .failure(let error):
                                    self.finishStarting(.failure(error), primary: continuation)
                                }
                            }
                            return
                        }
                        // Consume the snapshot: a resume point is valid
                        // exactly once.
                        //
                        // Leaving it in place is a real filesystem hazard,
                        // not untidiness. Once the guest is running again it
                        // writes to its disk, so the disk moves past the
                        // moment this snapshot captured. If the daemon is
                        // then killed without writing a fresh one - SIGKILL,
                        // a panic, power loss - the next start finds this
                        // same stale file and replays memory from *before*
                        // those writes on top of a disk that contains them.
                        // The guest's cached ext4 metadata then disagrees
                        // with what is actually on the disk, which is how a
                        // filesystem gets corrupted without anything ever
                        // reporting an error. `stopAfterGuestShutdown` names
                        // this same hazard for the poweroff path; it applies
                        // just as much here.
                        //
                        // The cost of deleting it is that an abnormal exit
                        // means a cold boot instead of a resume - which is
                        // the safe direction, and what happens after a real
                        // machine loses power.
                        try? FileManager.default.removeItem(at: self.snapshotURL)

                        // Restored from a snapshot taken after cold-boot
                        // setup already ran once - modules are loaded and
                        // shellinit is already running in the restored
                        // guest memory image. No setup script needed.
                        vm.resume { result in
                            switch result {
                            case .success: self.resumeAfterVMUp(continuation)
                            case .failure(let error): self.finishStarting(.failure(error), primary: continuation)
                            }
                        }
                    }
                } else {
                    vm.start { result in
                        switch result {
                        case .success:
                            self.afterColdStart(session: session, continuation: continuation)
                        case .failure(let error):
                            self.finishStarting(.failure(error), primary: continuation)
                        }
                    }
                }
            }
        }
    }

    /// Must only be called from within a `vmQueue` closure. Resolves every
    /// `ensureRunning()` call currently waiting on this start/resume/restore
    /// attempt - the `primary` continuation that actually triggered it, plus
    /// anyone who queued behind it in `pendingStartContinuations` while
    /// `isStarting` was `true` - and clears `isStarting` so the next genuine
    /// transition (e.g. after a later `hibernate()`) isn't permanently
    /// blocked.
    private func finishStarting(_ result: Result<Void, Error>, primary: CheckedContinuation<Void, Error>) {
        isStarting = false
        let waiters = pendingStartContinuations
        pendingStartContinuations = []
        switch result {
        case .success:
            primary.resume()
            for waiter in waiters { waiter.resume() }
        case .failure(let error):
            primary.resume(throwing: error)
            for waiter in waiters { waiter.resume(throwing: error) }
        }
    }

    /// Must only be called from within a `vmQueue` closure, after a
    /// successful cold `vm.start()`. Dispatches on boot mode - see
    /// `VMConfiguration.BootMode`'s doc comment for why these differ so
    /// much: `.liveNetboot` needs the full scripted setup, `.persistentDisk`
    /// just needs to wait out a normal boot.
    private func afterColdStart(session: SerialConsoleSession, continuation: CheckedContinuation<Void, Error>) {
        switch configuration.bootMode {
        case .liveNetboot:
            runColdBootSetup(session: session, continuation: continuation)
        case .persistentDisk:
            // No scripting needed - shellinit starts as a normal OpenRC
            // `local` service, the same as any other Alpine service. This
            // fixed delay covers kernel decompression + ext4 mount +
            // OpenRC startup before the first vsock connect attempt -
            // not yet tuned against a real boot's actual timing (see
            // README's "Guest boot strategy" - .persistentDisk is new).
            // Spend the boot wait *watching* the console rather than
            // sleeping through it.
            //
            // A guest whose kernel panics does not stop the VM - the vCPU
            // halts, and Virtualization.framework still reports the machine
            // as running - so this used to declare success and hand back a
            // guest that nothing could ever connect to. Every later command
            // then failed with "connection reset by peer", which says
            // nothing about what actually went wrong. Observed directly on
            // an instance whose root filesystem was corrupt.
            //
            // Same worst case as the fixed delay it replaces (no panic
            // means waiting the full timeout), and faster when there is one.
            DispatchQueue.global().async { [self] in
                if (try? session.waitForAny(["Kernel panic"], timeout: 5)) != nil {
                    vmQueue.async { [self] in
                        // Tear the machine down before reporting. A panicked
                        // guest leaves the vCPU halted while the framework
                        // still reports the VM as `running`, so leaving the
                        // object in place means every *later* call takes the
                        // "already running" fast path and gets a bare
                        // "connection reset by peer" instead of the real
                        // reason - only the very first attempt would ever
                        // say what happened. Dropping it makes each attempt
                        // cold-boot and report the panic honestly.
                        func reportPanic() {
                            virtualMachine = nil
                            coldBootSession = nil
                            openConnections.removeAll()
                            finishStarting(.failure(VMManagerError.guestKernelPanic), primary: continuation)
                        }
                        if let vm = virtualMachine, vm.canStop {
                            vm.stop { _ in self.vmQueue.async { reportPanic() } }
                        } else {
                            reportPanic()
                        }
                    }
                    return
                }
                // Back onto vmQueue, like the panic branch above. This closure
                // runs on a global queue (it blocks watching the console), and
                // `resumeAfterVMUp` touches the VM's devices - Virtualization
                // asserts they're used on the VM's own queue. Called from here
                // directly, a cold boot of any instance with a closed Sandbox
                // gate crashed mslhd in `VZVirtioFileSystemDevice.share`
                // (EXC_BREAKPOINT, dispatch_assert_queue_fail - 2026-09-14).
                vmQueue.async { [self] in resumeAfterVMUp(continuation) }
            }
        }
    }

    /// Must only be called from within a `vmQueue` closure, after a
    /// successful cold `vm.start()`, and only for `.liveNetboot`.
    private func runColdBootSetup(session: SerialConsoleSession, continuation: CheckedContinuation<Void, Error>) {
        do {
            try performColdBootSetup(session: session)
            resumeAfterVMUp(continuation)
        } catch {
            finishStarting(.failure(error), primary: continuation)
        }
    }

    /// Common tail for every `ensureRunning()` success path that represents
    /// the VM actually (re)starting - as opposed to the already-`.running`
    /// early return in `ensureRunning`, which intentionally skips this (the
    /// sandbox is presumably already up in that case). Kicks off the MSL
    /// Sandbox's WebDAV bridge/mount fire-and-forget on a background queue
    /// so a slow or failing `mount_webdav` never delays whoever's actually
    /// waiting on `ensureRunning()` - typically a shell connection, which
    /// has nothing to do with Finder - see `startFileSandbox`'s doc comment
    /// for why a mount failure there is logged, not thrown.
    private func resumeAfterVMUp(_ continuation: CheckedContinuation<Void, Error>) {
        // Every path to a running VM converges here - cold boot, resume
        // from paused, and restore from a snapshot - which is exactly why
        // the sandbox is re-applied at this one point rather than at each
        // `vm.start`/`vm.resume` completion handler.
        //
        // It has to be re-applied at all because `buildVirtualMachine()`
        // unconditionally builds a fresh, fully-attached network device (it
        // has no choice - the deterministic MAC is what makes restore work
        // at all). Without this, cutting a guest's network and then
        // hibernating would silently hand it back on the next resume: the
        // switch would still read "cut" while packets flowed.
        applyStoredSandboxPolicy()

        // Same reasoning as the sandbox above, and the same hazard. The
        // balloon device is rebuilt with every `buildVirtualMachine()`, and
        // the framework initialises its target to
        // `configuration.memorySize` every time - so a guest that had been
        // squeezed to 1 GB comes back from a resume holding the full ceiling
        // while any stale controller state still believed otherwise.
        // Restarting the governor here re-seeds it from what the device
        // actually has rather than from what we last asked for.
        startBalloonGovernorIfNeeded()

        // Every start builds a new socket device, so the listener is
        // rebuilt with it rather than kept.
        startHostOpenService()

        ActivityLog.shared.record(.lifecycle, instance: configuration.name, "Virtual machine running")

        DispatchQueue.global().async { [self] in startFileSandbox() }
        finishStarting(.success(()), primary: continuation)
    }

    /// Starts the guest-file-ops-over-vsock WebDAV bridge (`WebDAVServer`)
    /// and mounts it under `/Volumes` - the "Linux -> Finder" half of the
    /// MSL Sandbox (the other half, `mac_home` via virtiofs, is set up
    /// guest-side at provisioning time instead - see README's "MSL Sandbox"
    /// section). Always called off `vmQueue` (see `resumeAfterVMUp`), so
    /// it's free to block without stalling any VM operation.
    ///
    /// The whole guest filesystem is exposed, not just `/root` - see the
    /// comment at the `WebDAVServer` construction below for why. (This
    /// paragraph used to say `/root` was hardcoded here; it isn't, and
    /// hasn't been since that changed.)
    ///
    /// Uses `NetFSMountURLSync` (`NetFS.framework`), NOT a plain
    /// `Process`-spawned `/sbin/mount_webdav` - found the hard way that the
    /// CLI tool doesn't work for this at all: it calls `realpath()` on the
    /// target path itself with no privilege elevation (confirmed via the
    /// unified log: `webdavfs_agent: realpath(...) failed`), and an
    /// unprivileged process can never create a new directory directly under
    /// `/Volumes` (root:wheel, mode 755) to satisfy that. This isn't an
    /// environment quirk - it reproduced identically from a real,
    /// GUI-launched Terminal.app session, not just this project's own
    /// tooling. `NetFSMountURLSync` is the actual API Finder's own "Connect
    /// to Server" uses, and goes through a privileged broker that creates
    /// the mountpoint itself - confirmed working end-to-end (real read/
    /// write/delete through the resulting `/Volumes/<address>` mount) once
    /// two options were both set: `kNetFSAllowLoopbackKey` (WebDAV loopback
    /// mounts are refused by default) and `kNetFSUseGuestKey` (without it,
    /// NetAuth's internal auth negotiation - which never gets to prompt,
    /// since `kNAUIOptionNoUI` is also set - fails as a generic
    /// `kNetAuthErrorInternal` rather than a clear "no credentials"
    /// error). `mountpath` is deliberately left `nil` rather than a
    /// pre-chosen `/Volumes/MSL-<name>` path - passing an explicit path
    /// hits the exact same `realpath()`-on-a-nonexistent-directory
    /// failure as the CLI, since only the "pick your own mountpoint under
    /// a location I already own" and "let NetFS choose entirely" forms
    /// were confirmed to work, not "create this exact new path for me."
    /// One consequence: the mounted volume's name in Finder is whatever
    /// `webdavLoopbackAddress` resolves to (`127.0.0.1`, and a second
    /// concurrent mount becomes `127.0.0.1-1`), not `MSL-<name>` - WebDAV has no separate "share name" concept the way
    /// SMB/AFP do, and `kNetFSDisplayNameKey` (which looked promising)
    /// turned out to be for `EnumerateShares` results, not this call, per
    /// `NetFS.h`. A cosmetic gap, not a functional one - `webdavMountPath`
    /// (read back from `mountpoints`) is still tracked correctly for
    /// `stopFileSandbox` regardless of what it's named.
    ///
    /// Failure anywhere in this chain is logged, never thrown - the shell
    /// and the raw file-ops protocol both work with zero dependency on this
    /// succeeding, so a missing Finder mount is a degraded-but-usable
    /// state, not a broken instance.
    private func startFileSandbox() {
        webdavLock.lock()
        if webdavServer != nil || webdavStarting {
            webdavLock.unlock()
            return
        }
        webdavStarting = true
        let generation = webdavGeneration
        webdavLock.unlock()

        func abandon() {
            webdavLock.lock()
            webdavStarting = false
            // Retires this attempt's client too. A bridge that failed to
            // mount is never recorded, so no stop would ever bump this for
            // it - and its client could otherwise keep waking the VM.
            webdavGeneration &+= 1
            webdavLock.unlock()
        }

        let bindAddress = webdavLoopbackAddress
        // This bridge may wake the guest only while it is the current one -
        // see `webdavGeneration`. A paused guest still wakes, which is what
        // Finder access after an idle-suspend needs.
        let client = FileOpsClient(manager: self, mayWake: { [weak self] in
            guard let self else { return false }
            self.webdavLock.lock()
            defer { self.webdavLock.unlock() }
            return self.webdavGeneration == generation
        })
        // "/" not "/root" - matches real WSL, whose \\wsl$\<Distro>\ share
        // exposes the whole distro filesystem (/bin, /etc, /home, ...),
        // not just the home directory. Nothing about the WebDAV bridge
        // itself is scoped to a subtree; this is purely which guest path
        // its "/" maps to.
        let server = WebDAVServer(fileOpsClient: client, guestRoot: "/", bindAddress: bindAddress,
                                  instanceName: configuration.name)
        let port: UInt16
        do {
            port = try server.start()
        } catch {
            FileHandle.standardError.write("VMManager[\(configuration.name)]: WebDAV server failed to start (\(error)) - Finder mount unavailable, shell/file-ops still work\n".data(using: .utf8)!)
            abandon()
            return
        }

        #if canImport(NetFS)
        guard let url = URL(string: "http://\(bindAddress):\(port)/") else {
            FileHandle.standardError.write("VMManager[\(configuration.name)]: could not build WebDAV URL for \(bindAddress):\(port)\n".data(using: .utf8)!)
            server.stop()
            abandon()
            return
        }
        let openOptions = NSMutableDictionary()
        openOptions[kNetFSAllowLoopbackKey as String] = true
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        openOptions[kNetFSUseGuestKey as String] = true
        let mountOptions = NSMutableDictionary()
        var mountpointsUnmanaged: Unmanaged<CFArray>?
        let mountResult = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &mountpointsUnmanaged)
        guard mountResult == 0, let mountedPath = (mountpointsUnmanaged?.takeRetainedValue() as? [String])?.first else {
            FileHandle.standardError.write("VMManager[\(configuration.name)]: NetFSMountURLSync failed (\(mountResult)) - Finder mount unavailable, shell/file-ops still work\n".data(using: .utf8)!)
            server.stop()
            abandon()
            // NetFS can report a failure and mount anyway; a mount left
            // pointing at the stopped server is removed rather than left for
            // Finder to hang on.
            Self.unmountIfMounted(url: url.absoluteString)
            return
        }

        webdavLock.lock()
        webdavStarting = false
        let stale = webdavGeneration != generation
        if !stale {
            webdavServer = server
            webdavMountPath = mountedPath
        }
        webdavLock.unlock()
        if stale {
            FileHandle.standardError.write("VMManager[\(configuration.name)]: the instance stopped while its Finder mount was being set up - removed the mount again\n".data(using: .utf8)!)
            Self.unmount(mountedPath)
            server.stop()
            // The stop may have been a restart: a start that came in while
            // this one held the slot returned without mounting anything.
            if isRunning { startFileSandbox() }
        }
        #else
        server.stop()
        abandon()
        #endif
    }

    /// Unmounts (if mounted) and stops the WebDAV bridge - called before
    /// the VM itself stops (`hibernate`/`snapshotSave`/`snapshotRestore`),
    /// since a mount pointed at a vsock connection to a VM that no longer
    /// exists would just hang the next Finder access instead of cleanly
    /// disappearing (the acceptance bar from the original design: "stop
    /// instance -> volume disappears cleanly"). A no-op if nothing is
    /// mounted (e.g. `startFileSandbox` never succeeded, or this is a
    /// `suspendLight()` pause rather than a real stop - see that method's
    /// doc comment for why a lightweight pause deliberately leaves the
    /// mount in place).
    private func stopFileSandbox() {
        webdavLock.lock()
        let server = webdavServer
        let mountPath = webdavMountPath
        webdavServer = nil
        webdavMountPath = nil
        webdavGeneration &+= 1
        webdavLock.unlock()

        if let mountPath { Self.unmount(mountPath) }
        server?.stop()

        // Same teardown-before-the-VM-actually-stops reasoning as the
        // WebDAV bridge above - a `DisplayBridge` pointed at a
        // `VZVirtioSocketDevice` whose owning VM no longer exists is just
        // dead weight, not actively harmful, but there's no reason to keep
        // it around. Almost always `nil` in practice - this experimental
        // GUI path is opt-in and rarely started at all.
        displayBridge?.stop()
        displayBridge = nil
        x11Server?.stop()
        x11Server = nil
        hostOpenService?.stop()
        hostOpenService = nil
    }

    /// Must be called on `vmQueue`.
    private func startHostOpenService() {
        hostOpenService?.stop()
        hostOpenService = nil
        guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        // Default `mayWake`: a request only ever comes from a running guest,
        // and `{ false }` refuses every operation outright - it did, and no
        // attachment could be read while the WebDAV mount was still coming up.
        let fileOps = FileOpsClient(manager: self)
        let service = HostOpenService(
            socketDevice: socketDevice, instance: configuration.name,
            mountPath: { [weak self] in self?.sandboxMountPath },
            readGuestFile: { path, maxBytes in try Self.readWhole(path, maxBytes: maxBytes, using: fileOps) })
        service.start()
        hostOpenService = service
    }

    /// Reads a guest file through `fileopsd`, refusing anything over
    /// `maxBytes`. Blocks the calling thread, which must not be `vmQueue`.
    private static func readWhole(_ path: String, maxBytes: Int, using client: FileOpsClient) throws -> Data {
        final class Box: @unchecked Sendable { var result: Result<Data, Error> = .success(Data()) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                var data = Data()
                let chunk: UInt32 = 1 << 20
                while true {
                    let piece = try await client.read(path, offset: UInt64(data.count), length: chunk)
                    data.append(piece)
                    if data.count > maxBytes { throw CocoaError(.fileReadTooLarge) }
                    if piece.count < Int(chunk) { break }
                }
                box.result = .success(data)
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result.get()
    }

    /// Unmounts whatever is mounted from exactly `url`, if anything is.
    private static func unmountIfMounted(url: String) {
        // getmntinfo rather than getfsstat: Swift reads `[statfs]` as an array
        // of the statfs *function*, and getmntinfo hands back the buffer.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return }
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard from == url else { continue }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            unmount(on)
        }
    }

    /// `umount`, then `umount -f` if that was refused. webdavfs refuses a
    /// plain unmount while anything has the volume busy, and the refusal
    /// used to be swallowed, leaving the mount behind.
    private static func unmount(_ path: String) {
        for arguments in [[path], ["-f", path]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/umount")
            process.arguments = arguments
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        }
    }

    /// Ultra-experimental (see the archived `msl-vgpu.md` design): starts
    /// the host side of the GUI tunnel for this instance - see
    /// `DisplayBridge`'s doc comment for the full picture. Deliberately
    /// opt-in, unlike `startFileSandbox()` - nothing calls this
    /// automatically on boot; `msl gui <instance>` is the only caller. A
    /// no-op if already started; throws `VMManagerError.notRunning` if the
    /// VM isn't up yet (nothing to bridge to).
    public func startDisplayBridge() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                guard displayBridge == nil else {
                    continuation.resume()
                    return
                }
                guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                let bridge = DisplayBridge(socketDevice: socketDevice, port: configuration.displayVsockPort)
                bridge.start()
                displayBridge = bridge
                continuation.resume()
            }
        }
    }

    /// Stops the GUI tunnel's host side, if it was ever started - a no-op
    /// otherwise. Safe to call from any thread.
    public func stopDisplayBridge() {
        vmQueue.async { [self] in
            displayBridge?.stop()
            displayBridge = nil
        }
    }

    /// Ultra-experimental (see the archived `msl-vgpu.md` design's Phase 2):
    /// starts the native X11 server (`X11Server`/"mslgd") for this
    /// instance - the from-scratch alternative to `startDisplayBridge()`'s
    /// XQuartz-tunnel path, on its own port (`mslgdVsockPort`) so both can
    /// run side by side. Same opt-in/no-op-if-already-started/
    /// `.notRunning`-if-the-VM-isn't-up contract as `startDisplayBridge()`.
    public func startX11Server() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                guard x11Server == nil else {
                    continuation.resume()
                    return
                }
                guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                let server = X11Server(socketDevice: socketDevice, port: configuration.mslgdVsockPort,
                                       instance: configuration.name)
                server.start()
                x11Server = server
                continuation.resume()
            }
        }
    }

    // MARK: - Sandbox

    /// The gates currently closed for this instance.
    ///
    /// Seeded from disk in `init` so a stopped instance reports its real
    /// policy, then kept current by `setSandboxPolicy` and
    /// `applyStoredSandboxPolicy`. Only ever read/written from within a
    /// `vmQueue` closure after construction, like every other piece of
    /// mutable state here.
    private var sandboxPolicyStorage = SandboxPolicy.open

    /// Drives the memory balloon when this instance is in dynamic mode.
    /// `nil` in manual mode, and on any image whose guest has no `memd`.
    private var balloonGovernor: BalloonGovernor?

    /// The stored policy. Cheap and lock-free because it is only a mirror -
    /// `observedSandboxPolicy()` is the one that asks the devices.
    public func sandboxPolicy() async -> SandboxPolicy {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in continuation.resume(returning: sandboxPolicyStorage) }
        }
    }

    /// What the VM's devices actually report, not what we last asked for.
    ///
    /// These two can genuinely disagree: `VZNetworkDevice`'s header is
    /// explicit that `attachment` "may change at any time while the VM is
    /// running based on the state of the host network", and a failed set
    /// nils the property and calls the delegate. A UI driven by the stored
    /// flag would cheerfully show "connected" while the guest was cut off.
    ///
    /// Returns the stored policy unchanged for a VM that isn't running -
    /// there are no devices to ask, and the policy is still what will be
    /// applied at the next start.
    public func observedSandboxPolicy() async -> SandboxPolicy {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in continuation.resume(returning: observedPolicyOnQueue()) }
        }
    }

    /// Applies a policy and persists it.
    ///
    /// Persisted deliberately: a sandbox that forgets across a restart is
    /// not a sandbox. It is re-applied by `applyStoredSandboxPolicy()`
    /// after every start and restore rather than being baked into
    /// `buildVirtualMachine()`, which keeps the saved-state format and the
    /// deterministic-MAC contract untouched.
    ///
    /// Returns what the devices report afterwards, so a caller never has to
    /// assume the change took.
    @discardableResult
    public func setSandboxPolicy(_ policy: SandboxPolicy) async -> SandboxPolicy {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in
                sandboxPolicyStorage = policy
                SandboxPolicyStore.save(policy, instance: configuration.name)
                applyPolicyToDevices(policy)
                continuation.resume(returning: observedPolicyOnQueue())
            }
        }
    }

    /// Re-applies whatever was stored, after a start or a restore.
    ///
    /// `buildVirtualMachine()` always builds a fresh, fully-attached
    /// network device (it has to - see `macAddressString`), so without this
    /// every boot would silently hand a sandboxed guest its network back.
    func applyStoredSandboxPolicy() {
        let stored = SandboxPolicyStore.load(instance: configuration.name)
        sandboxPolicyStorage = stored
        guard !stored.isOpen else { return }
        note("re-applying sandbox policy (\(stored.closedGateCount) gate(s) closed)")
        applyPolicyToDevices(stored)
    }

    /// The actual mechanism. Must be called on `vmQueue`.
    private func applyPolicyToDevices(_ policy: SandboxPolicy) {
        guard let vm = virtualMachine else { return }

        // Detaching leaves the guest's interface configured but connected
        // to nothing - an unplugged cable, not a firewall. Reattaching
        // builds a fresh NAT attachment; the guest's existing DHCP lease
        // usually survives, but a long cut can outlive it.
        if let device = vm.networkDevices.first {
            let wanted: VZNetworkDeviceAttachment? = policy.networkCut ? nil : VZNATNetworkDeviceAttachment()
            if policy.networkCut != (device.attachment == nil) {
                device.attachment = wanted
            }
        }

        // Revoking the share is abrupt by design: the guest gets I/O errors
        // on /mnt/mac rather than a clean unmount, because a clean unmount
        // would need the guest's cooperation, which is the thing a sandbox
        // cannot rely on.
        if let fsDevice = vm.directorySharingDevices.first as? VZVirtioFileSystemDevice {
            if policy.macHomeShareRevoked {
                if fsDevice.share != nil { savedDirectoryShare = fsDevice.share; fsDevice.share = nil }
            } else if fsDevice.share == nil, let restored = savedDirectoryShare {
                fsDevice.share = restored
            }
        }

        if policy.displayServerDisabled {
            x11Server?.stop()
            x11Server = nil
        }
        // Turning the display server back ON is deliberately not done here:
        // `startX11Server()` is opt-in per session and has its own
        // preconditions. Reopening the gate lets it be started again; it
        // does not start it.

        X11InputGate.shared.setFrozen(policy.inputFrozen, instance: configuration.name)
    }

    /// Must be called on `vmQueue`.
    private func observedPolicyOnQueue() -> SandboxPolicy {
        guard let vm = virtualMachine else { return sandboxPolicyStorage }
        var policy = sandboxPolicyStorage
        if let device = vm.networkDevices.first { policy.networkCut = (device.attachment == nil) }
        if let share = vm.directorySharingDevices.first as? VZVirtioFileSystemDevice {
            policy.macHomeShareRevoked = (share.share == nil)
        }
        // Not `x11Server == nil`: the server only runs while a Linux GUI app
        // does, so that reported the Display gate closed whenever none was
        // open (SET 0000 answered 0010 - found 2026-09-14). The gate is the
        // stored decision; nothing device-side can reopen it on its own.
        return policy
    }

    /// Stops the native X11 server, if it was ever started - a no-op
    /// otherwise. Safe to call from any thread.
    public func stopX11Server() {
        vmQueue.async { [self] in
            x11Server?.stop()
            x11Server = nil
        }
    }

    /// `cage-planning.md` Phase 3 - starts the host side of the cage/
    /// Wayland frame stream (`CageBridge`) for this instance, on its own
    /// port (`cageVsockPort`) so it can run alongside either X11 path.
    ///
    /// UNLIKE `startDisplayBridge()`/`startX11Server()`'s own "no-op if
    /// already started" contract, this ALWAYS stops any existing
    /// `cageBridge` first and starts a fresh one with the requested
    /// `maxFrames` - a real bug caught live: `msl cage-bridge-test
    /// default 10` (bounded) followed by `msl cage-input-test default`
    /// (wants unbounded) in the SAME `mslhd` session, with the old no-op
    /// guard, silently kept the FIRST (bounded, `maxFrames=10`) bridge
    /// running - the second call's `maxFrames: 0` request was dropped
    /// entirely, and the guest's own unbounded `cagebridge` connected to
    /// a bridge that closed it after 10 frames anyway, SIGPIPE-killing
    /// the guest. These debug commands are one-shot by nature (unlike
    /// `X11Server`, which genuinely needs to stay up serving many
    /// separate client sessions) - always restarting fresh is the
    /// correct behavior here, not an existing-bridge no-op.
    public func startCageBridge(maxFrames: Int = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                cageBridge?.stop()
                let bridge = CageBridge(socketDevice: socketDevice, port: configuration.cageVsockPort, maxFrames: maxFrames)
                bridge.start()
                cageBridge = bridge
                continuation.resume()
            }
        }
    }

    /// Stops the cage bridge, if it was ever started - a no-op otherwise.
    /// Safe to call from any thread.
    public func stopCageBridge() {
        vmQueue.async { [self] in
            cageBridge?.stop()
            cageBridge = nil
        }
    }

    /// `cage-planning.md` Phase 3 step 3 - starts the host side of
    /// host->guest input injection (`CageInputBridge`) for this
    /// instance, on its own port (`cageInputVsockPort`) - independent of
    /// `startCageBridge()`'s frame stream, see `CageInputBridge`'s doc
    /// comment for why. ALWAYS stops any existing `cageInputBridge`
    /// first and starts fresh - same reasoning as `startCageBridge()`'s
    /// own doc comment (these are one-shot debug commands, not a
    /// long-lived server meant to just no-op on a repeat call).
    public func startCageInputBridge() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                cageInputBridge?.stop()
                let bridge = CageInputBridge(socketDevice: socketDevice, port: configuration.cageInputVsockPort)
                bridge.start()
                cageInputBridge = bridge
                continuation.resume()
            }
        }
    }

    /// Stops the cage input bridge, if it was ever started - a no-op
    /// otherwise. Safe to call from any thread.
    public func stopCageInputBridge() {
        vmQueue.async { [self] in
            cageInputBridge?.stop()
            cageInputBridge = nil
        }
    }

    /// Injects a synthetic key event into whatever guest `cageinput`
    /// session is currently connected, if any - `false` if none is (the
    /// bridge was never started, or the guest binary hasn't dialed in
    /// yet). See `CageInputBridge.sendKey`'s doc comment for the
    /// `keycode` convention (evdev, not Xkb).
    @discardableResult
    public func sendCageKey(keycode: UInt32, pressed: Bool) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            vmQueue.async { [self] in
                continuation.resume(returning: cageInputBridge?.sendKey(keycode: keycode, pressed: pressed) ?? false)
            }
        }
    }

    /// `cage-planning.md` Phase 4 - starts a REAL, on-screen live view of
    /// this instance's cage session: creates `cageBridge`/
    /// `cageInputBridge` (same as `startCageBridge()`/
    /// `startCageInputBridge()`, but wired to a `CageCanvasView` via
    /// `CageBridge`'s in-process `onFrame` callback instead of the debug
    /// file sink) plus a real `NSWindow` to show it in. No-op if a view
    /// is already running for this instance (checked via `cageWindow`,
    /// NOT `cageBridge`/`cageInputBridge` - a real bug caught live: those
    /// two can already be non-nil from an EARLIER debug-only
    /// `startCageBridge()`/`startCageInputBridge()` call in the same
    /// `mslhd` process, e.g. `msl cage-input-test` run once before `msl
    /// cage-view` in the same session - guarding on them made this
    /// method silently no-op and return "OK" with no window ever
    /// created, which is worse than a guard using the wrong state; this
    /// STOPS any such stale debug-mode bridges first, since the view
    /// needs its own `onFrame`-wired `CageBridge`, not a file-sink one).
    ///
    /// AppKit object creation (the window, the view) happens on
    /// `DispatchQueue.main`, NOT `vmQueue` - same reasoning as
    /// `X11Server.start()`'s own `NSApplication.shared.activate` call:
    /// `mslhd`'s `main.swift` already runs a REAL `NSApplication.shared.
    /// run()` event loop, and AppKit objects must be created/touched on
    /// the main thread. Created SYNCHRONOUSLY (`DispatchQueue.main.sync`,
    /// safe here since `vmQueue` is a private queue, never the main
    /// queue itself - no deadlock risk) specifically so `CageBridge`'s
    /// `onFrame` closure below can capture the real `view` directly
    /// rather than racing a `cageCanvasView` property that might not be
    /// set yet when the very first frame arrives.
    public func startCageView() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                guard cageWindow == nil else {
                    continuation.resume()
                    return
                }
                guard let vm = virtualMachine, let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }

                cageBridge?.stop()
                cageBridge = nil
                cageInputBridge?.stop()
                cageInputBridge = nil

                let inputBridge = CageInputBridge(socketDevice: socketDevice, port: configuration.cageInputVsockPort)
                inputBridge.start()
                cageInputBridge = inputBridge

                let view = DispatchQueue.main.sync { () -> CageCanvasView in
                    // 1280x720 matches every headless cage session this
                    // whole project has run so far (`WLR_BACKENDS=
                    // headless`'s own fixed default output size,
                    // confirmed repeatedly in Phase 1-3's own capture
                    // output) - `CageCanvasView.updateFrame` resizes
                    // itself the instant a real frame header says
                    // otherwise, so this is just a reasonable starting
                    // size, not a hard assumption.
                    let view = CageCanvasView(width: 1280, height: 720)
                    view.inputBridge = inputBridge
                    let window = NSWindow(
                        contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
                        styleMask: [.titled, .closable, .miniaturizable],
                        backing: .buffered, defer: false
                    )
                    window.title = "cage - \(configuration.name)"
                    window.isReleasedWhenClosed = false
                    window.acceptsMouseMovedEvents = true
                    window.contentView = view
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    cageWindow = window
                    cageCanvasView = view
                    return view
                }

                let frameBridge = CageBridge(socketDevice: socketDevice, port: configuration.cageVsockPort) { [weak view] width, height, stride, format, flags, pixels in
                    view?.updateFrame(width: width, height: height, stride: stride, format: format, flags: flags, pixels: pixels)
                }
                frameBridge.start()
                cageBridge = frameBridge
                continuation.resume()
            }
        }
    }

    /// Stops the cage view, if it was ever started - a no-op otherwise.
    /// Tears down `cageBridge`/`cageInputBridge` (same objects
    /// `startCageBridge()`/`startCageInputBridge()` would have created -
    /// they're shared state, so this also stops those) and closes the
    /// window on the main thread. Safe to call from any thread.
    public func stopCageView() {
        vmQueue.async { [self] in
            cageBridge?.stop()
            cageBridge = nil
            cageInputBridge?.stop()
            cageInputBridge = nil
            DispatchQueue.main.async { [self] in
                cageWindow?.close()
                cageWindow = nil
                cageCanvasView = nil
            }
        }
    }

    /// Alpine's netboot live root has no vsock support out of the box (see
    /// README's "Guest bootstrap findings") - this logs in over the serial
    /// console, mounts the two read-only virtiofs shares `buildVirtualMachine`
    /// attaches (`msl_modules`, `msl_bin`), loads the vsock kernel modules
    /// `extract-guest-modules` pulled out of Alpine's modloop archive (in
    /// dependency order - insmod doesn't resolve dependencies itself the
    /// way modprobe does), and execs the precompiled `shellinit` binary
    /// `build-shellinit` produced. Only needed once per cold boot - a
    /// restored-from-snapshot VM already has all of this live in its
    /// restored memory image.
    private func performColdBootSetup(session: SerialConsoleSession) throws {
        // Not "<name>:~#" - a `hostname=` kernel cmdline param was tried
        // and doesn't take effect on this init script (confirmed on a real
        // boot: still "localhost:~#" regardless). The default ":~#"
        // matcher doesn't care what the actual hostname is.
        try session.loginAsRoot()

        try session.runStep(
            "mkdir -p /mnt/msl-modules && mount -t virtiofs msl_modules /mnt/msl-modules",
            marker: "MSL_CB_MODSHARE_DONE"
        )
        try session.runStep(
            "mkdir -p /mnt/msl-bin && mount -t virtiofs msl_bin /mnt/msl-bin",
            marker: "MSL_CB_BINSHARE_DONE"
        )

        // Dependency order matters - insmod doesn't resolve it like
        // modprobe would. vhost_vsock.ko (host-side vhost acceleration)
        // deliberately excluded - not applicable to a guest. vsock_loopback
        // also excluded - confirmed on a real boot it fails to load
        // ("unknown symbol in module"), and it's for local same-host
        // AF_VSOCK loopback testing, not the guest<->host virtio transport
        // shellinit actually needs.
        let vsockModuleLoadOrder = [
            "vsock", "vsock_diag",
            "vmw_vsock_virtio_transport_common", "vmw_vsock_virtio_transport",
        ]
        for (index, module) in vsockModuleLoadOrder.enumerated() {
            try session.runStep("insmod /mnt/msl-modules/\(module).ko", marker: "MSL_CB_MOD_\(index)_DONE")
        }

        // No guest-side chmod - msl_bin is a read-only share (confirmed on
        // a real boot: chmod fails with "Operation not permitted" there),
        // and build-shellinit already sets +x on the host side, which a
        // read-only virtiofs mount still correctly exposes for reading.
        try session.runStep(
            "/mnt/msl-bin/shellinit >/var/log/shellinit.log 2>&1 &",
            marker: "MSL_CB_SHELLINIT_STARTED"
        )
        Thread.sleep(forTimeInterval: 1) // let shellinit finish binding its vsock listener
    }

    /// Lightweight, in-memory pause ("suspension") - the VM process stays
    /// alive, resume is near-instant. Contrast with `hibernate()`, which
    /// saves to disk and stops the process entirely.
    public func suspendLight() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // Never pause a maintenance boot: e2fsck would stall mid-pass
                // until the maintenance timeout gave up on it.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                guard let vm = virtualMachine, vm.state == .running else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                // A paused guest cannot answer, and polling one would be a
                // vsock connect that times out every cycle for as long as it
                // stays suspended. `resumeAfterVMUp` starts it again.
                stopBalloonGovernor()
                vm.pause { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Saves current VM state to the implicit snapshot and stops it
    /// entirely ("hibernation") - contrast with `suspendLight()`, which
    /// keeps the process resident for a near-instant resume. Called by the
    /// daemon's idle timer, and available as an explicit command.
    public func hibernate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // Saving a maintenance boot would make its init - the repair
                // script - the thing the next ordinary start resumes into.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                guard let vm = virtualMachine, vm.state == .running || vm.state == .paused else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                stopFileSandbox()
                stopBalloonGovernor()

                // Same rule as `saveStateForHostPowerEvent`: saving a
                // panicked guest only guarantees the next start restores the
                // panic.
                if consoleShowsPanic {
                    note("not hibernating - this guest's kernel panicked; the next start will boot it fresh")
                    try? FileManager.default.removeItem(at: snapshotURL)
                    vm.stop { error in
                        self.virtualMachine = nil
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                    return
                }

                func saveThenStop() {
                    // saveMachineStateTo refuses to overwrite an existing
                    // file at the target URL ("File exists") - confirmed
                    // live: hibernating the same instance a second time,
                    // ever, fails outright once `snapshotURL` already
                    // exists from a prior hibernate (including one from a
                    // previous daemon run - this file persists on disk).
                    // Since hibernate's whole point is "save current state,
                    // replacing whatever was saved before," clear out the
                    // stale file first rather than let this silently break
                    // every hibernate after the first (including the
                    // idle-timer's automatic ones - see DaemonServer).
                    try? FileManager.default.removeItem(at: snapshotURL)
                    vm.saveMachineStateTo(url: snapshotURL) { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        vm.stop { error in
                            // Released as soon as it stops: a stopped VZVirtualMachine that is
                            // still referenced keeps its XPC process and its lock on the disk
                            // image, and the next start or restore then fails with "The storage
                            // device attachment is invalid" (found 2026-09-14).
                            self.virtualMachine = nil
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }

                // saveMachineStateTo requires the VM to be paused first -
                // confirmed on a real call: attempting it while .running
                // fails with VZErrorDomain Code=3 "Virtual machine state
                // "running" is invalid for saving."
                if vm.state == .running {
                    vm.pause { result in
                        switch result {
                        case .success: saveThenStop()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                } else {
                    saveThenStop()
                }
            }
        }
    }

    // MARK: - Host power events

    /// Flushes the guest's dirty page cache to the disk image.
    ///
    /// Best-effort and strictly advisory: it reduces how much recent work a
    /// sudden power loss throws away, and it is **not** what protects the
    /// filesystem. Pausing is what protects the filesystem - a paused guest
    /// cannot write, and an ext4 that stops mid-transaction replays its
    /// journal on the next mount, which is exactly what a real machine
    /// losing power does. (The corruption this project actually suffered
    /// came from the disk filling to 100% and truncating a library
    /// mid-write, not from a power event.)
    ///
    /// Never allowed to gate a pause: it runs a command inside the guest,
    /// which is a way for a power handler to hang, so callers bound it and
    /// carry on regardless of the result.
    public func quiesceGuest() async {
        guard currentState() == .running else { return }
        // `sync` alone: `fsfreeze` would be a stronger guarantee but an
        // unfreeze that never runs leaves the guest wedged with every write
        // blocked forever, which is a worse failure than the one it
        // prevents.
        _ = await runInternalCommand("sync", timeout: 5)
    }

    /// Freezes the guest immediately. Near-instant, no disk I/O, and the
    /// single most important thing to get done during a host power event -
    /// once this returns the guest cannot write to its disk at all.
    ///
    /// Unlike `suspendLight()` this never throws for an instance that is
    /// already paused or stopped: during a shutdown "it was already safe"
    /// and "we just made it safe" are the same outcome, and a thrown error
    /// there would only obscure the instances that genuinely failed.
    @discardableResult
    public func pauseForHostPowerEvent() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            vmQueue.async { [self] in
                // A maintenance boot is left alone. The host sleeping freezes
                // it with everything else and it carries on after wake;
                // pausing it here would only hand it to
                // `saveStateForHostPowerEvent` - see the guard there.
                if maintenanceInProgress {
                    note("host power event during maintenance - leaving the maintenance run alone")
                    continuation.resume(returning: true)
                    return
                }
                guard let vm = virtualMachine else {
                    continuation.resume(returning: true)
                    return
                }
                switch vm.state {
                case .paused, .stopped:
                    continuation.resume(returning: true)
                case .running where vm.canPause:
                    vm.pause { result in
                        if case .failure(let error) = result {
                            self.note("couldn't pause for a host power event: \(error)")
                        }
                        continuation.resume(returning: (try? result.get()) != nil)
                    }
                default:
                    // Mid-transition. Nothing useful to do and no time to
                    // wait for it during a power event.
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Writes an already-paused VM's state to disk and stops it, so it can
    /// be resumed after the host reboots.
    ///
    /// Deliberately separate from `pauseForHostPowerEvent()`. `hibernate()`
    /// does both together, which means that with several instances running,
    /// the last one may still be *unpaused* - and still writing - while the
    /// first is spending seconds writing gigabytes of RAM to disk. Pausing
    /// everything first and saving afterwards makes the safety property
    /// hold no matter where a deadline cuts the work off.
    ///
    /// Losing this step costs only the ability to resume where the guest
    /// left off; the next start cold-boots instead. `ensureRunning()`
    /// already treats a bad snapshot that way.
    @discardableResult
    public func saveStateForHostPowerEvent() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            vmQueue.async { [self] in
                // Never save a maintenance boot. Its init is the repair
                // script: saving it would make the next ordinary start resume
                // straight back into a repair.
                if maintenanceInProgress {
                    continuation.resume(returning: false)
                    return
                }
                guard let vm = virtualMachine, vm.state == .paused else {
                    continuation.resume(returning: false)
                    return
                }

                // Never preserve a guest that has already crashed.
                //
                // A panicked guest is still `running` as far as the
                // framework is concerned, so it gets frozen and saved like
                // any other - and then *restored* on the next start, which
                // brings the panic back. That turns one bad boot into a
                // machine that is permanently dead and cannot be recovered
                // by restarting it, which is precisely the loop this was
                // observed doing: SIGTERM saved a panicked guest, and every
                // start afterwards restored it and failed identically.
                // Discarding instead means the next start cold-boots, which
                // is the only thing that can help.
                if consoleShowsPanic {
                    note("not saving state - this guest's kernel panicked; the next start will boot it fresh")
                    try? FileManager.default.removeItem(at: snapshotURL)
                    vm.stop { _ in self.virtualMachine = nil; continuation.resume(returning: false) }
                    return
                }

                stopFileSandbox()
                // `saveMachineStateTo` refuses to overwrite an existing
                // file - see `hibernate()` for the confirmed failure.
                try? FileManager.default.removeItem(at: snapshotURL)
                vm.saveMachineStateTo(url: snapshotURL) { error in
                    if let error {
                        self.note("couldn't save state: \(error) - this instance will cold-boot next time")
                        continuation.resume(returning: false)
                        return
                    }
                    vm.stop { _ in self.virtualMachine = nil; continuation.resume(returning: true) }
                }
            }
        }
    }

    /// Puts this manager back into a coherent state after the host has woken
    /// from sleep.
    ///
    /// A `VZVirtioSocketConnection` does not survive the host sleeping: the
    /// guest was frozen mid-connection and every open session is gone.
    /// Holding on to those references means the next caller reuses a dead
    /// fd and gets an error that looks like MSL breaking rather than a
    /// session that ended. Dropping them makes the next request open a
    /// fresh connection, which is the only thing that can work.
    public func handleHostDidWake() {
        vmQueue.async { [self] in
            let stale = openConnections.count
            openConnections.removeAll()
            if stale > 0 {
                note("host woke - dropped \(stale) connection(s) that did not survive sleep")
            }
        }
    }

    /// Re-sets the guest's clock from the host's.
    ///
    /// A paused guest's clock stops while the host sleeps, so on waking it
    /// can be hours behind. Skewed time is not a cosmetic problem: it breaks
    /// TLS certificate validation, makes `make` rebuild or skip everything,
    /// and confuses `git` - all of which surface as unrelated-looking errors
    /// long after the sleep that caused them.
    public func resyncGuestClock() async {
        guard currentState() == .running else { return }
        // The same code the Maintenance card's "Sync clock" button runs - see
        // `syncGuestClock`. One implementation, so a fix to either is a fix
        // to both.
        let result = await syncGuestClock()
        if result.status == .ok {
            note("guest clock after wake: \(result.summary)")
        } else {
            note("couldn't resync the guest clock after wake")
        }
    }

    /// Sets the guest's clock from the host's whenever the guest comes up -
    /// a cold boot, a restore from hibernation, or a resume from a pause.
    ///
    /// The guest has no clock of its own to read at boot: Virtualization
    /// gives a Linux guest booted this way no RTC it can use (the kernel's
    /// EFI RTC needs EFI runtime services, and there's no PL031), so a cold
    /// boot started from whatever date systemd falls back to - seven weeks
    /// behind on the 2026-09-14 images, which failed every HTTPS request
    /// with "certificate is not yet valid". A restored or resumed guest is
    /// behind by however long it was saved or paused.
    public func syncClockAfterStart() async {
        guard currentState() == .running else { return }
        let result = await syncGuestClock()
        if result.status == .ok {
            note("guest clock at start: \(result.summary)")
        } else {
            note("couldn't set the guest clock at start")
        }
    }

    /// Stops the VM process outright, with no save-to-disk - for use after
    /// the guest has already been asked to `poweroff` over the shell
    /// channel and had a chance to actually flush its filesystem (see
    /// `msl --shutdown`, which drives that part client-side over the shell
    /// connection before calling this). Clears any *implicit* hibernate
    /// snapshot: a poweroff changes the disk's on-disk state, so an
    /// existing snapshot of the VM's in-memory state from before it would
    /// no longer match and must not be restored from on the next
    /// `ensureRunning()` - it'd otherwise silently look like a successful
    /// resume while actually replaying stale pre-shutdown memory over a
    /// post-shutdown disk. Named snapshots and the instance's registry
    /// entry are left untouched - this is "power off the machine," not
    /// `removeAllPersistedState()`'s "delete this instance." A no-op if
    /// already stopped.
    public func stopAfterGuestShutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                stopFileSandbox()
                try? FileManager.default.removeItem(at: snapshotURL)

                guard let vm = virtualMachine, vm.state != .stopped else {
                    virtualMachine = nil
                    continuation.resume()
                    return
                }
                vm.stop { error in
                    self.virtualMachine = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Saves a NAMED checkpoint (unlike `hibernate()`'s single implicit
    /// slot) - pauses, saves, and stops, same shape as `hibernate()`.
    ///
    /// This was originally written to pause-save-*resume*, on the
    /// assumption `saveMachineStateTo` could capture a checkpoint without
    /// otherwise disrupting a running VM. Confirmed wrong on a real run:
    /// the resulting file restored with `VZErrorDomain Code=12 "failed to
    /// restore with error 'invalid argument'"` - reproduced immediately
    /// even with zero activity between save and restore, so it's not a
    /// race with guest activity. Whatever `saveMachineStateTo` captures
    /// apparently isn't valid once the *same* VM object is resumed and
    /// continues running afterward - only `hibernate()`'s pause-save-stop
    /// shape (never resuming that VM object again) produced snapshots that
    /// actually restored. Until proven otherwise, treat "resume the VM you
    /// just saved" as unsupported for this API, regardless of what the
    /// completion handler firing without an error seems to promise.
    public func snapshotSave(name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // A named snapshot of a maintenance boot is a checkpoint of
                // the repair script - nothing anyone would want to go back to.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                guard let vm = virtualMachine, vm.state == .running || vm.state == .paused else {
                    continuation.resume(throwing: VMManagerError.notRunning)
                    return
                }
                stopFileSandbox()

                func saveThenStop() {
                    // Same "won't overwrite an existing file" behavior as
                    // hibernate()'s saveThenStop - see its comment. A named
                    // snapshot re-save under the same name should replace
                    // it, not fail.
                    try? FileManager.default.removeItem(at: namedSnapshotURL(name))
                    vm.saveMachineStateTo(url: namedSnapshotURL(name)) { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        vm.stop { error in
                            // Released as soon as it stops: a stopped VZVirtualMachine that is
                            // still referenced keeps its XPC process and its lock on the disk
                            // image, and the next start or restore then fails with "The storage
                            // device attachment is invalid" (found 2026-09-14).
                            self.virtualMachine = nil
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }

                if vm.state == .running {
                    vm.pause { result in
                        switch result {
                        case .success: saveThenStop()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                } else {
                    saveThenStop()
                }
            }
        }
    }

    /// Restores a NAMED checkpoint, replacing whatever is currently
    /// running (stopping it first if needed).
    public func snapshotRestore(name: String) async throws {
        let url = namedSnapshotURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VMManagerError.snapshotNotFound(name)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // Restoring builds and starts a VM on this disk - on an image
                // e2fsck may be rewriting at this very moment.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                stopFileSandbox()

                // Drop the *implicit* hibernate snapshot. The named one
                // being restored here deliberately survives - a checkpoint
                // is meant to be returned to more than once - but the
                // implicit one describes a moment that this restore has just
                // overwritten. Left in place, an abnormal exit later would
                // resume from it and replay memory from before the restore
                // on top of the restored disk.
                try? FileManager.default.removeItem(at: snapshotURL)

                func restoreIntoFreshVM() {
                    let vm: VZVirtualMachine
                    let session: SerialConsoleSession
                    do {
                        (vm, session) = try buildVirtualMachine()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    vm.delegate = self
                    virtualMachine = vm
                    coldBootSession = session
                    vm.restoreMachineStateFrom(url: url) { restoreError in
                        if let restoreError {
                            continuation.resume(throwing: restoreError)
                            return
                        }
                        vm.resume { result in
                            switch result {
                            case .success: self.resumeAfterVMUp(continuation)
                            case .failure(let error): continuation.resume(throwing: error)
                            }
                        }
                    }
                }

                if let vm = virtualMachine, vm.state != .stopped {
                    vm.stop { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        self.virtualMachine = nil
                        restoreIntoFreshVM()
                    }
                } else {
                    virtualMachine = nil
                    restoreIntoFreshVM()
                }
            }
        }
    }

    /// Lists named snapshots on disk for this instance (not the implicit
    /// hibernate slot). Pure filesystem listing - no VM state involved, so
    /// this doesn't need to go through `vmQueue`.
    public func snapshotList() -> [String] {
        let dir = appSupportDir
        let prefix = "vm-\(configuration.name)-"
        let suffix = ".state"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { file in
            guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
            return String(file.dropFirst(prefix.count).dropLast(suffix.count))
        }.sorted()
    }

    /// Tears down everything this instance has persisted on disk - stops
    /// the VM if running (a plain stop, not `hibernate()`'s pause-and-save;
    /// there's no point saving state that's about to be deleted), then
    /// removes the implicit hibernate snapshot, every named snapshot, and
    /// the machine identifier. Used by `msl remove <name>` -
    /// `InstanceRegistry.remove` drops the registry entry itself, this
    /// only cleans up what `VMManager` owns. Deliberately does NOT touch
    /// the distro's shared disk image (`GuestDistro.diskImageFilename`) -
    /// that file is shared across every instance of the same distro (see
    /// `InstanceRegistry`'s caveat on this), not owned by this one, so
    /// removing an instance never removes the underlying distro data.
    public func removeAllPersistedState() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                // Removing an instance deletes its files - including the image
                // a repair is working on.
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                stopFileSandbox()

                func cleanupFiles() {
                    try? FileManager.default.removeItem(at: snapshotURL)
                    try? FileManager.default.removeItem(at: machineIdentifierURL)
                    for name in snapshotList() {
                        try? FileManager.default.removeItem(at: namedSnapshotURL(name))
                    }
                    virtualMachine = nil
                    coldBootSession = nil
                    continuation.resume()
                }

                if let vm = virtualMachine, vm.state != .stopped {
                    vm.stop { _ in cleanupFiles() }
                } else {
                    cleanupFiles()
                }
            }
        }
    }

    /// Opens a new vsock connection to the guest's shell listener and
    /// returns its raw file descriptor. `VMManager` retains the underlying
    /// `VZVirtioSocketConnection` until `releaseConnection(fd:)` is called -
    /// the caller (DaemonServer) must hand the fd off (e.g. via SCM_RIGHTS)
    /// and then call `releaseConnection(fd:)`, NOT close the fd directly:
    /// the connection object closes its own fd on deallocation, and a
    /// manual close() racing that would risk closing an unrelated fd number
    /// that got reused in between.
    public func openShellConnection() async throws -> Int32 {
        do {
            return try await openConnection(port: configuration.shellVsockPort)
        } catch {
            // Translate the symptom into the cause when the console says
            // what it was.
            //
            // A guest whose kernel panicked is still "running" to
            // Virtualization.framework - the vCPU is simply halted - so
            // every connection attempt fails with a bare "connection reset
            // by peer" that says nothing about why. Checking the console at
            // *failure* time rather than at a fixed point during boot means
            // this does not depend on how long the guest took to panic,
            // which is exactly what made a timing-based check unreliable.
            if guestPanicked {
                note("the guest kernel panicked - reporting that instead of the connection error")
                throw VMManagerError.guestKernelPanic
            }
            throw error
        }
    }

    /// Whether the guest's console shows a kernel panic.
    public var guestPanicked: Bool {
        vmQueue.sync { consoleShowsPanic }
    }

    /// Same check, for callers already running on `vmQueue` - where the
    /// public property above would deadlock on its own `sync`.
    private var consoleShowsPanic: Bool {
        coldBootSession?.consoleContains("Kernel panic") ?? false
    }

    /// One line to stderr, matching this file's existing `VMManager[name]:`
    /// convention - mslhd's stderr is its log file.
    private func note(_ message: String) {
        FileHandle.standardError.write("VMManager[\(configuration.name)]: \(message)\n".data(using: .utf8)!)
    }

    /// Runs one command in the guest and returns its output, using this
    /// manager's own vsock connection.
    ///
    /// `ShellClient` exists for exactly this, but it reaches the guest by
    /// connecting to **mslhd's control socket** - which is fine for a
    /// separate process and wrong from inside mslhd itself, where it would
    /// mean the daemon opening a session against itself and counting it as
    /// user activity. This talks to the already-open VM directly.
    ///
    /// Not interactive: one EXEC frame out, frames back until the guest
    /// reports an exit. Nothing reads stdin, and the write side is never
    /// half-closed - see `LinuxAppLauncher` for why that distinction
    /// matters so much.
    @discardableResult
    public func runInternalCommand(_ command: String, timeout: TimeInterval = 60) async -> (exitCode: Int32, output: String) {
        guard let fd = try? await openShellConnection() else { return (-1, "") }
        defer { releaseConnection(fd: fd) }

        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        let request = ShellProtocol.encodeExec(command: command, rows: 24, cols: 80, user: "")
        var sent = 0
        request.withUnsafeBytes { buffer in
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }

        func readExactly(_ count: Int) -> [UInt8]? {
            guard count > 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            let complete = buffer.withUnsafeMutableBytes { raw -> Bool in
                let base = raw.baseAddress!
                while got < count {
                    let n = read(fd, base + got, count - got)
                    if n <= 0 { return false }
                    got += n
                }
                return true
            }
            return complete ? buffer : nil
        }

        var exitCode: Int32 = -1
        var collected: [UInt8] = []
        while let header = readExactly(5) {
            guard let type = ShellProtocol.FrameType(rawValue: header[0]) else { break }
            let length = (Int(header[1]) << 24) | (Int(header[2]) << 16) | (Int(header[3]) << 8) | Int(header[4])
            guard let payload = readExactly(length) else { break }
            switch type {
            case .data: collected.append(contentsOf: payload)
            case .exit:
                exitCode = Int32(payload.first ?? 1)
                return (exitCode, String(decoding: collected, as: UTF8.self))
            case .exec, .resize: break
            }
        }
        return (exitCode, String(decoding: collected, as: UTF8.self))
    }

    /// Extends the guest filesystem into space added to the image while it
    /// was stopped, and records how full it now is so the next boot knows
    /// whether to grow again.
    ///
    /// Called after a start rather than as part of one: `resize2fs` needs a
    /// running guest, and the usage sample is only meaningful once the
    /// filesystem is mounted.
    public func applyPendingStorageChanges() async {
        guard let imagePath = configuration.diskImagePath else { return }
        let imageName = configuration.diskStorageKey ?? (imagePath as NSString).lastPathComponent

        if DiskStorage.filesystemResizeIsPending(forImageNamed: imageName) {
            let result = await runInternalCommand(DiskStorage.filesystemResizeCommand, timeout: 300)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0 {
                DiskStorage.clearPendingFilesystemResize(forImageNamed: imageName)
                if !output.isEmpty { note("resize2fs: \(output)") }
            } else {
                // Left pending deliberately - a guest without e2fsprogs
                // should pick the extra space up the next time it boots
                // with the tool installed, not silently forget about it.
                note("couldn't extend the guest filesystem yet: \(output)")
            }
        }

        let sample = await runInternalCommand(DiskStorage.usageCommand, timeout: 30)
        if sample.exitCode == 0, let usage = DiskStorage.parseUsage(sample.output) {
            DiskStorage.recordUsage(
                DiskStorage.Usage(total: usage.total, used: usage.used, sampled: Date()),
                forImageNamed: imageName)
        }
    }

    /// Opens a new vsock connection to the guest's file-ops listener
    /// (`fileopsd`) and returns its raw file descriptor - same retained/
    /// caller-releases-it contract as `openShellConnection`. Each
    /// connection is exactly one request/response (see `Guest/init/
    /// fileopsd.c`'s doc comment) - callers open a fresh one per file
    /// operation rather than reusing a connection across requests.
    public func openFileOpsConnection() async throws -> Int32 {
        try await openConnection(port: configuration.fileOpsVsockPort)
    }

    /// Opens a connection to `trafficd`. Fails with the usual connect error
    /// on an image built before `trafficd` existed, which is how
    /// `TrafficClient` reports "this guest cannot answer" rather than
    /// pretending the guest has no connections.
    public func openTrafficConnection() async throws -> Int32 {
        try await openConnection(port: configuration.trafficVsockPort)
    }

    public func openMemoryConnection() async throws -> Int32 {
        try await openConnection(port: configuration.memoryVsockPort)
    }

    // MARK: - Memory balloon

    /// The instance's resource policy, as stored.
    public func resourcePolicy() -> ResourcePolicy {
        ResourcePolicyStore.load(instance: configuration.name)
    }

    /// Starts (or restarts) the governor if this instance is in dynamic
    /// mode. Called from `resumeAfterVMUp`, so it runs on `vmQueue`.
    private func startBalloonGovernorIfNeeded() {
        let policy = ResourcePolicyStore.load(instance: configuration.name)
        guard case .dynamic(let floorMB, let ceilingMB) = policy.resolvedMemory() else {
            balloonGovernor?.stop()
            balloonGovernor = nil
            return
        }
        balloonGovernor?.stop()
        let governor = BalloonGovernor(
            manager: self,
            bounds: BalloonBounds(floor: floorMB * 1024 * 1024, ceiling: ceilingMB * 1024 * 1024))
        balloonGovernor = governor
        governor.start()
    }

    /// Stops the governor - on pause, hibernate and stop, so a suspended
    /// instance is not polled and a stopped one leaves no timer behind.
    func stopBalloonGovernor() {
        balloonGovernor?.stop()
        balloonGovernor = nil
    }

    /// What the balloon is doing, for the UI. `nil` when not in dynamic mode.
    public func balloonState() -> BalloonGovernor.State? {
        balloonGovernor?.state
    }

    /// Reads the live target off the device, hopping to `vmQueue` to do it.
    ///
    /// Asynchronous because every access to `virtualMachine` has to happen
    /// on that queue, and the governor runs on its own.
    func balloonTargetOnQueueAsync(_ completion: @escaping (UInt64?) -> Void) {
        vmQueue.async { [self] in
            completion((virtualMachine?.memoryBalloonDevices.first
                        as? VZVirtioTraditionalMemoryBalloonDevice)?.targetVirtualMachineMemorySize)
        }
    }

    /// Writes a new target to the device.
    ///
    /// Only a *request*: the framework hands it to the guest's balloon
    /// driver, which decides what it can actually give up and when. The
    /// value here is what we asked for, not what happened - which is why the
    /// governor re-reads the device rather than assuming its own arithmetic
    /// took effect.
    func setBalloonTarget(_ target: UInt64, completion: @escaping (Bool) -> Void) {
        vmQueue.async { [self] in
            guard let device = virtualMachine?.memoryBalloonDevices.first
                    as? VZVirtioTraditionalMemoryBalloonDevice else {
                completion(false)
                return
            }
            device.targetVirtualMachineMemorySize = target
            completion(true)
        }
    }

    // MARK: - Maintenance

    /// Whether a hibernated session is waiting to be resumed.
    ///
    /// Maintenance refuses while one is. The image and the saved memory are
    /// a pair: the memory holds the kernel's idea of what is on the disk,
    /// inode caches and all, and resuming it on top of a disk e2fsck has
    /// since rewritten would be a corruption this feature introduced.
    public var hasSavedSession: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    /// Takes the disk for maintenance, or says exactly why not.
    private func beginMaintenance() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async { [self] in
                if maintenanceInProgress {
                    continuation.resume(throwing: VMManagerError.maintenanceInProgress)
                    return
                }
                // Paused is not stopped: a paused guest still has the
                // filesystem mounted, in memory, mid-flight.
                let stopped: Bool = {
                    guard let vm = virtualMachine else { return true }
                    return vm.state == .stopped || vm.state == .error
                }()
                guard stopped, !isStarting else {
                    continuation.resume(throwing: VMManagerError.mustBeStoppedForMaintenance)
                    return
                }
                guard !FileManager.default.fileExists(atPath: snapshotURL.path) else {
                    continuation.resume(throwing: VMManagerError.savedSessionBlocksMaintenance)
                    return
                }
                maintenanceInProgress = true
                continuation.resume()
            }
        }
    }

    private func endMaintenance() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            vmQueue.async { [self] in
                maintenanceInProgress = false
                continuation.resume()
            }
        }
    }

    /// Checks or repairs this instance's disk from the Mac side.
    ///
    /// The flag is set and cleared on `vmQueue`, but e2fsck itself runs off
    /// it: a real disk can take minutes, and holding the queue that long
    /// would stall every status query for this instance along with it.
    public func runFilesystemMaintenance(mode: FsckMode) async throws -> FsckRun {
        guard let imagePath = configuration.diskImagePath else { throw VMManagerError.noDiskImage }
        guard let e2fsck = E2fsck.locate() else { throw VMManagerError.e2fsckUnavailable }
        try await beginMaintenance()
        let run = await Task.detached(priority: .userInitiated) {
            FilesystemCheck.run(e2fsck: e2fsck, imagePath: imagePath, mode: mode)
        }.value
        await endMaintenance()

        note("filesystem \(mode.rawValue): \(run.verdict.title) (e2fsck exit \(run.verdict.exitCode))")
        ActivityLog.shared.record(.lifecycle, instance: configuration.name,
                                  "Filesystem \(mode.rawValue): \(run.verdict.title)")
        return run
    }

    /// Discards the pre-repair backup. Refused while maintenance holds the
    /// disk, since a repair in flight may be about to rely on it.
    public func discardRepairBackup() async throws {
        guard let imagePath = configuration.diskImagePath else { throw VMManagerError.noDiskImage }
        try await beginMaintenance()
        ImageBackup.discard(for: imagePath)
        await endMaintenance()
    }

    /// Puts the pre-repair backup back. Needs a stopped instance for the same
    /// reason a repair does.
    public func restoreRepairBackup() async throws {
        guard let imagePath = configuration.diskImagePath else { throw VMManagerError.noDiskImage }
        try await beginMaintenance()
        defer { Task { await self.endMaintenance() } }
        try ImageBackup.restore(for: imagePath)
    }

    /// The optional pre-boot check. Runs inside `buildVirtualMachine`, so on
    /// `vmQueue` and during a start - acceptable because it is opt-in and the
    /// start is already the only thing this instance is doing.
    private func checkFilesystemBeforeBootIfEnabled(imagePath: String, maintenanceBoot: Bool) throws {
        // Never before a maintenance boot. That boot is the repair path, and
        // refusing it because the disk is damaged would lock the user out of
        // the very fix they asked for.
        guard !maintenanceBoot else { return }
        guard MaintenanceSettingsStore.load(instance: configuration.name).checkFilesystemAtStart else { return }
        // Skipped when resuming a saved session - see `hasSavedSession`.
        guard !FileManager.default.fileExists(atPath: snapshotURL.path) else {
            note("check-at-start skipped: resuming a saved session, whose disk and memory must stay a pair")
            return
        }
        // An unchecked disk is not a clean one. With the check switched on,
        // being unable to run it refuses the boot rather than waving it
        // through - and says how to get unstuck.
        guard let e2fsck = E2fsck.locate() else {
            throw VMManagerError.filesystemCheckFailed(
                "check-at-start is on, but e2fsck isn't installed on this Mac. Install e2fsprogs, or turn the check off in Tools.")
        }
        let run = FilesystemCheck.run(e2fsck: e2fsck, imagePath: imagePath, mode: .check)
        guard run.verdict.allowsBoot else {
            throw VMManagerError.filesystemCheckFailed("\(run.verdict.title). \(run.verdict.detail)")
        }
        note("check-at-start: filesystem clean")
    }

    /// Boots the guest with the maintenance script as init and root
    /// read-only, and reads the result off the serial console.
    ///
    /// Nothing else runs - no shell daemon, no file bridge, no sandbox, no
    /// balloon. `resumeAfterVMUp` is never reached, so none of it is set up
    /// and none of it needs tearing down.
    ///
    /// **Unverified on a guest**: no image contains the script yet. What is
    /// tested is everything around the boot - the command line, the report
    /// parser, and the verdict table it shares with the host-side check.
    public func runMaintenanceBoot(_ action: MaintenanceBootAction,
                                   timeout: TimeInterval = 1800) async throws -> MaintenanceBootReport {
        try await beginMaintenance()
        do {
            // The same free safety net as the host-side repair: an APFS clone
            // of the disk before e2fsck is let near it. The clone is taken on
            // the Mac, so it works whether or not e2fsprogs is installed - and
            // if it can't be made, the repair doesn't happen.
            if action == .fsckRepair, let imagePath = configuration.diskImagePath {
                try ImageBackup.make(for: imagePath)
            }
            let report = try await performMaintenanceBoot(action, timeout: timeout)
            await endMaintenance()
            return report
        } catch {
            await stopMaintenanceMachine()
            await endMaintenance()
            throw error
        }
    }

    private func performMaintenanceBoot(_ action: MaintenanceBootAction,
                                        timeout: TimeInterval) async throws -> MaintenanceBootReport {
        let session: SerialConsoleSession = try await withCheckedThrowingContinuation { continuation in
            vmQueue.async { [self] in
                let built: (VZVirtualMachine, SerialConsoleSession)
                do {
                    built = try buildVirtualMachine(
                        kernelCommandLineOverride: action.kernelCommandLine(base: configuration.kernelCommandLine))
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let (vm, session) = built
                vm.delegate = self
                virtualMachine = vm
                vm.start { result in
                    switch result {
                    case .success: continuation.resume(returning: session)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }

        // Waits on its own schedule, sleeping between looks - see
        // `SerialConsoleSession.transcriptSnapshot` for why not `waitForAny`.
        let deadline = Date().addingTimeInterval(timeout)
        var transcript = session.transcriptSnapshot()
        while Date() < deadline {
            transcript = session.transcriptSnapshot()
            if MaintenanceBootReport.terminalMarkers.contains(where: transcript.contains) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Stopped regardless of how it ended. A guest whose init couldn't run
        // panics with its vCPU halted while the framework still reports it
        // running (the same trap the cold-boot panic watcher exists for), so
        // the script's own power-off can't be relied on.
        await stopMaintenanceMachine()
        let report = MaintenanceBootReport.parse(transcript: transcript, action: action)
        note("maintenance boot \(action.rawValue): \(report.outcome)")
        ActivityLog.shared.record(.lifecycle, instance: configuration.name,
                                  "Maintenance boot \(action.rawValue) finished")
        return report
    }

    /// Stops and forgets the maintenance VM so the next ordinary start builds
    /// a fresh one with the normal command line.
    private func stopMaintenanceMachine() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            vmQueue.async { [self] in
                func finish() {
                    virtualMachine = nil
                    coldBootSession = nil
                    openConnections.removeAll()
                    continuation.resume()
                }
                guard let vm = virtualMachine else { return finish() }
                if vm.state == .stopped || vm.state == .error {
                    finish()
                } else {
                    vm.stop { _ in self.vmQueue.async { finish() } }
                }
            }
        }
    }

    /// Everything the Maintenance card needs, in one query.
    ///
    /// Looks inside the disk image only when nothing is using it: a running
    /// guest's image changes underneath any reader, and a hibernated one is
    /// half of a pair that shouldn't be disturbed. The probe is read-only and
    /// only a hint, so a maintenance run starting a moment later is harmless.
    public func maintenanceStatus() async -> MaintenanceStatus {
        let inProgress: Bool = await withCheckedContinuation { continuation in
            vmQueue.async { [self] in continuation.resume(returning: maintenanceInProgress) }
        }
        let e2fsck = E2fsck.locate()
        let imagePath = configuration.diskImagePath
        let running = isRunning
        let saved = hasSavedSession
        var status = MaintenanceStatus(
            e2fsckAvailable: e2fsck != nil,
            running: running,
            inProgress: inProgress,
            hasSavedSession: saved,
            hasRepairBackup: imagePath.map(ImageBackup.exists(for:)) ?? false,
            checkAtStart: MaintenanceSettingsStore.load(instance: configuration.name).checkFilesystemAtStart,
            scriptInImage: nil)
        if !running, !saved, !inProgress, let imagePath {
            status.scriptInImage = await Task.detached(priority: .utility) {
                MaintenanceTools.imageContainsScript(imagePath: imagePath, e2fsck: e2fsck)
            }.value
        }
        return status
    }

    private func openConnection(port: UInt32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            vmQueue.async { [self] in
                attemptConnection(port: port, remainingRetries: 10, continuation: continuation)
            }
        }
    }

    /// Per-attempt bound on `VZVirtioSocketDevice.connect(toPort:)` - see
    /// `attemptConnection`'s doc comment for why this exists at all.
    private static let connectAttemptTimeout: TimeInterval = 4

    /// Must only be called from within a `vmQueue` closure. Retries the
    /// vsock connect a few times, half a second apart, before giving up.
    /// Right after any cold boot (live-netboot or persistent-disk),
    /// `ensureRunning()` returning doesn't guarantee the guest's listener
    /// has actually bound yet - `.persistentDisk`'s cold-start wait is a
    /// fixed delay with no console-marker synchronization (see
    /// `afterColdStart`), and the guest side has its own latency (virtio-
    /// vsock transport module autoload, OpenRC's `local` service /
    /// systemd actually reaching the listener's bind/listen). Confirmed on
    /// a real disk boot that a single immediate connect attempt fails with
    /// `ECONNRESET` (not the more usual `ECONNREFUSED`) when the listener
    /// isn't up yet - retrying briefly absorbs that race instead of
    /// needing a longer, and still ultimately racy, fixed delay upstream.
    /// Shared by both `openShellConnection` and `openFileOpsConnection` -
    /// parameterized on port rather than duplicated, since the race is
    /// identical for both listeners.
    ///
    /// Also guards against a distinct, harder failure mode: confirmed live
    /// (via `sample` on the XPC helper mid-hang, cross-checked against
    /// `log show` for that process) that `connect(toPort:)`'s completion
    /// handler can simply never fire at all - neither success nor failure
    /// - for the rest of that XPC helper's lifetime, once a libdispatch-
    /// level bug hits inside it (the helper's own log: "BUG in libdispatch
    /// client: read, monitored resource vanished before the source cancel
    /// handler was invoked", timed exactly at the first connect attempt).
    /// Retrying against the SAME session doesn't help once this hits -
    /// confirmed live that a second, fully independent connect attempt
    /// against the same still-running VM hangs identically. So a timeout
    /// here doesn't retry the existing connection like a normal failure
    /// does - it abandons the VM reference outright (see `settled`'s
    /// timeout branch below) so the *next* `ensureRunning()` cold-boots a
    /// fresh XPC helper instead of hanging the same way forever.
    private func attemptConnection(port: UInt32, remainingRetries: Int, continuation: CheckedContinuation<Int32, Error>) {
        guard let vm = virtualMachine,
              let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            continuation.resume(throwing: VMManagerError.notRunning)
            return
        }

        // Guards against a double-resume of `continuation` if both the
        // timeout and a (very late-arriving) real completion handler fire -
        // safe unguarded by a lock since every mutation happens inside a
        // block scheduled on `vmQueue`, a serial queue.
        var settled = false

        let timeoutWorkItem = DispatchWorkItem { [self] in
            guard !settled else { return }
            settled = true
            // Deliberately does NOT call `vm.stop()` first to clean up -
            // that's itself another async call into the same wedged
            // session, with no more guarantee of its completion handler
            // firing than the connect we just gave up on. The orphaned
            // XPC helper process is a harmless (if wasteful) leak, not a
            // correctness problem - it holds no lock on the disk image
            // beyond its own lifetime.
            self.virtualMachine = nil
            self.coldBootSession = nil
            continuation.resume(throwing: VMManagerError.shellConnectTimedOut)
        }
        vmQueue.asyncAfter(deadline: .now() + Self.connectAttemptTimeout, execute: timeoutWorkItem)

        // connect(toPort:) is NS_REFINED_FOR_SWIFT - the completion handler
        // is Result-wrapped, single argument.
        socketDevice.connect(toPort: port) { [self] result in
            vmQueue.async { [self] in
                guard !settled else { return }
                settled = true
                timeoutWorkItem.cancel()
                switch result {
                case .success(let connection):
                    let fd = connection.fileDescriptor
                    self.openConnections[fd] = connection
                    continuation.resume(returning: fd)
                case .failure(let error):
                    guard remainingRetries > 0 else {
                        continuation.resume(throwing: error)
                        return
                    }
                    vmQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                        attemptConnection(port: port, remainingRetries: remainingRetries - 1, continuation: continuation)
                    }
                }
            }
        }
    }

    /// Drops this manager's retained reference to a shell connection once
    /// its fd has been handed off and is no longer needed on this side.
    /// This is the only correct way to let the fd close - see
    /// `openShellConnection`.
    public func releaseConnection(fd: Int32) {
        vmQueue.async { [self] in
            _ = openConnections.removeValue(forKey: fd)
        }
    }

    /// Must only be called from within a `vmQueue` closure. Returns the new
    /// VM together with the serial console session wired into its serial
    /// port - callers that need to script the guest (cold boot, snapshot
    /// restore) use the session; callers that don't (a plain resume) can
    /// ignore it.
    private func buildVirtualMachine(kernelCommandLineOverride: String? = nil) throws -> (VZVirtualMachine, SerialConsoleSession) {
        let config = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = loadOrCreateMachineIdentifier()
        config.platform = platform

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: configuration.kernelPath))
        bootLoader.initialRamdiskURL = URL(fileURLWithPath: configuration.initrdPath)
        bootLoader.commandLine = kernelCommandLineOverride ?? configuration.kernelCommandLine
        config.bootLoader = bootLoader

        config.cpuCount = configuration.cpuCount
        config.memorySize = configuration.memorySize

        if let diskImagePath = configuration.diskImagePath {
            // Before anything opens the image - the attachment below and the
            // resize both come after. See `checkFilesystemBeforeBootIfEnabled`.
            try checkFilesystemBeforeBootIfEnabled(
                imagePath: diskImagePath, maintenanceBoot: kernelCommandLineOverride != nil)

            // The last possible moment the image can change size: nothing
            // has it open, and `VZDiskImageStorageDeviceAttachment` reads
            // the file's length right below - a guest's disk capacity is
            // fixed for the whole life of the attachment, so growing it
            // later in the boot would have no effect until the next one.
            let preparation = DiskStorage.prepareForBoot(
                imagePath: diskImagePath,
                imageName: configuration.diskStorageKey ?? (diskImagePath as NSString).lastPathComponent)
            if let grewTo = preparation.grewTo {
                note("disk grown to \(DiskStorage.format(grewTo)) - the guest filesystem will be extended once it's up")
            }
            if let message = preparation.note {
                note("storage: \(message)")
            }

            // `.uncached` + `.full`, stated explicitly rather than taking
            // the two-argument initializer's defaults.
            //
            // Measured, not assumed: `init(url:readOnly:)` yields
            // `caching=automatic, sync=full`. So synchronisation was already
            // the safe setting - the gap was host caching, and "automatic"
            // means Virtualization decides, which is not something to leave
            // to chance for the one file whose corruption costs a whole
            // instance.
            //
            // Caching matters here specifically because these images are
            // **sparse**. UTM hit ext4 corruption on exactly this
            // combination - a sparse image behind a virtio block device -
            // and traced it to write-order inversion under load: a sparse
            // file defers physical allocation until the write lands, so
            // with the host page cache in the middle, later writes can
            // complete ahead of earlier ones and the filesystem's own
            // ordering guarantees stop holding. Their fix was this exact
            // pair of arguments (utmapp/UTM#5869); their reported symptom,
            // "EXT4-fs error ... bad block bitmap checksum", is the same
            // family as the "Orphan file not empty" this project keeps
            // seeing after unclean stops.
            //
            // This is a deliberate trade, not a free win. Measured on this
            // machine with 1 GB files neither of which had been read
            // before: 1.23 GB/s with `F_NOCACHE` against 4.09 GB/s without,
            // so cold sequential reads cost roughly 3x. (Re-reads are a
            // different story - the guest keeps its own page cache over the
            // same blocks, so `automatic` largely buys a second copy of
            // what the guest already holds.)
            //
            // Worth it anyway: a slower boot is an inconvenience, and a
            // corrupted rootfs is the whole instance.
            //
            // And the disk sits behind an NVMe controller rather than
            // virtio-blk - UTM's second fix for the same corruption
            // (utmapp/UTM#5919), for NVMe's stricter I/O ordering. It
            // renames the guest's disk from `/dev/vda` to `/dev/nvme0n1`,
            // which `kernelCommandLine`'s `root=` and the shared initramfs
            // (built with mkinitfs's `nvme` feature by
            // Linux-Side/image-build/build-kernel.sh) move with. The images
            // themselves name root by `LABEL=msl-root`, so they boot under
            // either controller. Switched with the 2026-09-14 image rebuild.
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: diskImagePath),
                readOnly: false,
                cachingMode: .uncached,
                synchronizationMode: .full
            )
            config.storageDevices = [VZNVMExpressControllerDeviceConfiguration(attachment: diskAttachment)]
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        // A deterministic (not default-random) MAC is required for
        // save/restore to work at all - see VMConfiguration.macAddressString.
        if let mac = VZMACAddress(string: configuration.macAddressString) {
            net.macAddress = mac
        }
        config.networkDevices = [net]

        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // virtio-rng. Without it the guest seeds its CRNG from CPU jitter
        // alone, and anything calling `getrandom()` before that completes
        // blocks - which in practice is early userspace doing key
        // generation or TLS on first boot. It costs nothing, and it is in
        // Apple's own Linux VM sample for the same reason.
        //
        // Note for anyone adding devices here: device topology is part of
        // what a saved state must match, so a change like this invalidates
        // existing `.state` files. That degrades safely - `restore` failing
        // falls back to a cold boot, loudly - but it does mean one
        // hibernated session is lost the first time the set changes.
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Attached unconditionally, even in manual mode.
        //
        // The device costs nothing while its target sits at the configured
        // size, and it cannot be added to a running VM - so attaching it
        // only for dynamic instances would mean switching a running
        // instance to dynamic mode did nothing until the next cold boot,
        // with no way to say why. It also has to be present in *both* the
        // saving and restoring configurations for a snapshot to reload, and
        // the mode can be changed while an instance is hibernated.
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let session = SerialConsoleSession()
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = session.attachment
        config.serialPorts = [serialConfig]

        // The modules/shellinit-bin shares only matter for .liveNetboot's
        // cold-boot script (see performColdBootSetup) - .persistentDisk
        // boots a real installed system whose own /lib/modules already has
        // everything, and whose shellinit is already on disk as an OpenRC
        // service, not pushed in via virtiofs each boot.
        var shares: [(tag: String, path: URL, readOnly: Bool)] = []
        if configuration.bootMode == .liveNetboot {
            guard let modulesPath = configuration.modulesPath, let shellinitBinPath = configuration.shellinitBinPath else {
                throw VMManagerError.missingLiveNetbootPaths
            }
            shares.append((tag: "msl_modules", path: URL(fileURLWithPath: modulesPath), readOnly: true))
            shares.append((tag: "msl_bin", path: URL(fileURLWithPath: shellinitBinPath), readOnly: true))
        }
        shares.append(contentsOf: configuration.sharedFolders.map {
            (tag: $0.tag, path: URL(fileURLWithPath: $0.hostPath), readOnly: $0.readOnly)
        })
        config.directorySharingDevices = shares.map { share in
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            fsDevice.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share.path, readOnly: share.readOnly))
            return fsDevice
        }

        if configuration.rosettaEnabled, VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosettaShare = try VZLinuxRosettaDirectoryShare()
            let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosettaDevice.share = rosettaShare
            config.directorySharingDevices.append(rosettaDevice)
        }

        try config.validate()
        do {
            try config.validateSaveRestoreSupport()
        } catch {
            FileHandle.standardError.write("VMManager: config does NOT support save/restore: \(error)\n".data(using: .utf8)!)
        }
        return (VZVirtualMachine(configuration: config, queue: vmQueue), session)
    }
}

public enum VMManagerError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case snapshotNotFound(String)
    case missingLiveNetbootPaths
    case shellConnectTimedOut
    case guestKernelPanic
    case maintenanceInProgress
    case mustBeStoppedForMaintenance
    case savedSessionBlocksMaintenance
    case e2fsckUnavailable
    case noDiskImage
    case filesystemCheckFailed(String)

    public var description: String {
        switch self {
        case .notRunning: return "instance is not running"
        case .connectionFailed: return "failed to open shell connection"
        case .snapshotNotFound(let name): return "no snapshot named '\(name)'"
        case .missingLiveNetbootPaths: return "bootMode is .liveNetboot but modulesPath/shellinitBinPath are nil"
        case .shellConnectTimedOut: return "shell connection timed out - the VM's virtio-socket session appears wedged; retry the command (it will cold-boot a fresh VM)"
        case .guestKernelPanic: return "the guest kernel panicked while booting - its filesystem is probably damaged; check the boot log in ~/Library/Logs/MSL/mslhd.log"
        case .maintenanceInProgress: return "maintenance is running on this instance's disk - it can start once that finishes"
        case .mustBeStoppedForMaintenance: return "the instance has to be shut down first - a disk that's in use can't be checked or repaired safely"
        case .savedSessionBlocksMaintenance: return "this instance has a hibernated session - its saved memory and its disk are a pair, so resume and shut it down (or discard the session) before maintenance"
        case .e2fsckUnavailable: return "e2fsck isn't installed on this Mac - install e2fsprogs (`brew install e2fsprogs`), or use Maintenance Boot instead"
        case .noDiskImage: return "this instance has no disk image to check"
        case .filesystemCheckFailed(let reason): return "didn't start: the filesystem check at start found a problem - \(reason)"
        }
    }
}


// MARK: - VZVirtualMachineDelegate

/// Notices when a VM stops without being asked to.
///
/// Nothing was watching for this before, and both cases it covers are real:
/// a user typing `poweroff` inside the guest, and Virtualization.framework
/// dropping a VM on its own - which is a documented hazard around host
/// sleep, reported by other projects built on the same framework (Lima and
/// UTM both have open issues about VMs hanging or dying across a sleep/wake
/// cycle).
///
/// Callbacks arrive on the VM's own queue, which is this manager's
/// `vmQueue`, so they can touch its state directly.
extension VMManager: VZVirtualMachineDelegate {

    /// The guest powered itself off - `poweroff`, `shutdown -h`, or systemd
    /// reaching its final target.
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        note("the guest powered itself off")
        cleanUpAfterUnexpectedStop()
    }

    /// The framework stopped the VM because something went wrong.
    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        note("the virtual machine stopped unexpectedly: \(error)")
        cleanUpAfterUnexpectedStop()
    }

    /// Documented to fire whenever a network interface fails to start -
    /// including on ordinary boots and guest-initiated resets - so this is
    /// informational only and deliberately does not treat the VM as broken.
    public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        note("network attachment disconnected: \(error)")
    }

    /// Shared cleanup for a VM that stopped without going through
    /// `hibernate()`/`stopAfterGuestShutdown()`.
    ///
    /// Clearing the implicit snapshot is the part that matters. A guest that
    /// powers itself off has written its filesystem out and moved the disk
    /// past whatever an earlier hibernate captured; leaving that snapshot in
    /// place means the next start restores memory from before the shutdown
    /// on top of a disk from after it. `stopAfterGuestShutdown` already
    /// clears it for the host-driven case and explains why - but until now
    /// nothing covered a `poweroff` typed inside the guest, which is an
    /// entirely ordinary thing to do.
    private func cleanUpAfterUnexpectedStop() {
        stopFileSandbox()
        openConnections.removeAll()
        coldBootSession = nil
        // Released, not just left `.stopped`: a stopped VZVirtualMachine that
        // is still referenced keeps its Virtualization XPC process alive, and
        // that process keeps the disk image open. Found on 2026-09-14 - after a
        // `poweroff` inside the guest, starting the same instance again failed
        // with "The storage device attachment is invalid" until mslhd itself
        // restarted, and every such stop leaked ~400 MB. `stopAfterGuestShutdown`
        // already released it; this path never did.
        virtualMachine = nil
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            try? FileManager.default.removeItem(at: snapshotURL)
            note("discarded the saved resume point - it no longer matches this disk")
        }
    }
}
