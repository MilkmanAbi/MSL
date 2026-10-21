import Foundation
import MSLCore
import PublicMSL
#if canImport(Darwin)
import Darwin
#endif

/// Accepts connections on the local control socket, brokers VM lifecycle
/// for every registered instance (see `InstanceRegistry`, capped at
/// `InstanceRegistry.maxInstances`), and hands off a raw vsock fd per
/// shell session via SCM_RIGHTS.
final class DaemonServer {

    /// Builds a fresh `VMConfiguration` for a newly-registered instance
    /// name + distro - supplied by `main.swift`, which knows the shared
    /// kernel/initrd paths and each distro's disk image filename.
    private let makeConfiguration: (String, GuestDistro) -> VMConfiguration
    private let registry: InstanceRegistry

    private var managers: [String: VMManager] = [:]
    private let managersLock = NSLock()

    private var listenFD: Int32 = -1

    /// Set by `main.swift` so `POWER_TEST` can reach the resilience monitor.
    /// A closure rather than a stored reference, so this type keeps knowing
    /// nothing about power handling.
    var onPowerTest: ((String) -> String)?

    /// Written from `handle(clientFD:)`, which runs once per accepted
    /// connection inside its own unstructured `Task` - concurrent sessions
    /// mean concurrent Tasks, potentially on different threads. Also read
    /// from `startIdleTimer`'s `DispatchSourceTimer` handler, which fires on
    /// `.global()`, and cleared from `handleRemove`'s `async` body. A plain
    /// `[String: Date]` with no lock here crashed the whole daemon process
    /// live under two genuinely concurrent sessions (`NSInvalidArgument
    /// Exception` inside Dictionary's internal storage from the torn
    /// concurrent write) - confirmed by reproducing it, then it going away
    /// once every access went through `activityLock`. Every access to
    /// `lastActivity` MUST go through `recordActivity`/`clearActivity`/
    /// `activitySnapshot` below, never touch the dictionary directly.
    private var lastActivity: [String: Date] = [:]
    private let activityLock = NSLock()
    private let idleTimeout: TimeInterval = 5 * 60
    private var idleTimer: DispatchSourceTimer?

    private func recordActivity(_ instance: String) {
        activityLock.lock()
        lastActivity[instance] = Date()
        activityLock.unlock()
    }

    private func clearActivity(_ instance: String) {
        activityLock.lock()
        lastActivity.removeValue(forKey: instance)
        activityLock.unlock()
    }

    private func activitySnapshot() -> [String: Date] {
        activityLock.lock()
        defer { activityLock.unlock() }
        return lastActivity
    }

    /// Count of currently-open shell sessions per instance - incremented
    /// once a session's guest-side connection is actually established (see
    /// `handleSession`), decremented on `.sessionEnded` (sent by `msl`
    /// right after its relay loop ends, whether the session exited cleanly
    /// or the connection just dropped - see `ControlRequest.sessionEnded`'s
    /// doc comment). Drives the WSL-like "leave it running, suspended, once
    /// you close the last terminal" behavior: hitting zero schedules a
    /// debounced `suspendLight()`, cancelled if a new session starts in the
    /// meantime so a quick `msl -- cmd1 && msl -- cmd2` back-to-back
    /// doesn't thrash pause/resume. Also consulted by the idle timer below,
    /// so a quietly-idle but still-open interactive session never gets
    /// hard-hibernated out from under its own live connection - the idle
    /// timer previously only looked at *session-start* time, which would
    /// otherwise hibernate a genuinely-in-use session that just hadn't
    /// started anything new in 5 minutes.
    ///
    /// A client that crashes before ever sending `.sessionEnded` leaves its
    /// instance's count permanently inflated - a safe failure mode (that
    /// instance just stops auto-suspending until a manual `msl suspend`,
    /// nothing is lost or corrupted), not one worth building real crash
    /// detection for yet.
    private var activeSessions: [String: Int] = [:]
    private var pendingSuspend: [String: DispatchWorkItem] = [:]
    private let sessionsLock = NSLock()
    private let suspendDebounce: TimeInterval = 3

    private func sessionStarted(_ instance: String) {
        sessionsLock.lock()
        activeSessions[instance, default: 0] += 1
        pendingSuspend.removeValue(forKey: instance)?.cancel()
        sessionsLock.unlock()
    }

    /// Set once a host power transition (sleep, shutdown, logout, low
    /// battery) has started, and never cleared - the process does not
    /// outlive the transition in the cases that set it, and for sleep the
    /// idle-suspend it suppresses is redundant with the pause anyway.
    ///
    /// Without this, logging out races itself: `msl`'s termination handler
    /// sends `.sessionEnded`, which schedules `suspendLight()` for
    /// `suspendDebounce` seconds later on a global queue, while
    /// `SystemResilienceMonitor.respond` is pausing and saving those same
    /// managers. That monitor's `actionLock` only serializes power responses
    /// against each other - it knows nothing about this path - so the two
    /// would reach one `VMManager` at once, which is exactly the
    /// mid-save-suspend that corrupts a guest filesystem.
    private var powerTransitionActive = false

    /// Set by `main.swift`: whether a host power response is running.
    var powerResponseInFlight: () -> Bool = { false }

    /// Stops idle auto-suspend from firing for the rest of this process's
    /// life, and cancels any suspend already counting down.
    func beginPowerTransition() {
        sessionsLock.lock()
        powerTransitionActive = true
        let pending = pendingSuspend
        pendingSuspend.removeAll()
        sessionsLock.unlock()
        for (_, work) in pending { work.cancel() }
    }

    /// Takes an instance's forwards down without forgetting them, so they
    /// come back when it next starts.
    ///
    /// **A forward does not wake a paused guest, and this is what makes
    /// that bearable.** Measured: with the listener still up over a
    /// suspended instance, a request hangs for the full client timeout and
    /// the guest stays paused - ten seconds of nothing, which reads as a
    /// broken server. With the listener down it is refused at once, which
    /// reads as "not running" and is the truth. `instanceStarted` brings it
    /// back with the instance.
    ///
    /// Waking the guest on an incoming connection is what the WebDAV
    /// bridge does (`FileOpsClient`'s `mayWake`) and would be the nicer
    /// behaviour here too; it is not wired, so nothing claims it is.
    private func stopForwards(for instance: String) {
        ForwardManager.shared.stopAll(instance: instance, forget: false)
    }

    private func sessionEnded(_ instance: String) {
        sessionsLock.lock()
        let count = max(0, (activeSessions[instance] ?? 1) - 1)
        activeSessions[instance] = count
        var scheduledWork: DispatchWorkItem?
        if count == 0, !powerTransitionActive {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sessionsLock.lock()
                let stillIdle = (self.activeSessions[instance] ?? 0) == 0
                let transitioning = self.powerTransitionActive
                self.pendingSuspend.removeValue(forKey: instance)
                self.sessionsLock.unlock()
                // Re-checked here and not only at schedule time: the
                // transition usually starts *after* this was queued.
                guard stillIdle, !transitioning else { return }

                self.managersLock.lock()
                let existing = self.managers[instance]
                self.managersLock.unlock()
                guard let manager = existing, manager.currentState() == .running else { return }
                // Not an instance set up for SSH. `ssh msl-<name>` never
                // passes through this daemon, so a pause here froze live SSH
                // sessions three seconds after the last `msl` command and made
                // new connections time out (2026-09-14). A pause frees no
                // memory - the paused VM keeps all of it - so leaving these
                // running costs only an idle guest's CPU. The idle hibernate
                // still reclaims the memory, and it checks for live sessions.
                guard SSHSetup.RecordStore.load(instance: instance) == nil else { return }
                // Nor an instance holding a USB device. The attachment
                // itself survives a pause - the vsock does - but a paused
                // guest answers no URBs, so the device would go dead in the
                // guest three seconds after the attach and come back only
                // when something else resumed it. Same reasoning as the SSH
                // case above: a pause frees no memory, so leaving it running
                // costs only an idle guest's CPU, and the idle hibernate
                // (which also checks) still reclaims it.
                guard !manager.hasUSBAttachments else { return }
                // Logged because this is invisible from the outside and
                // looks exactly like an app crashing: the VM pauses, the
                // app's X11 connection stops answering, and it exits
                // cleanly with no crash report anywhere.
                MSLLog.line("idle", "\(instance): pausing - no sessions left")
                Task { try? await manager.suspendLight() }
            }
            pendingSuspend[instance] = work
            scheduledWork = work
        }
        sessionsLock.unlock()

        if let scheduledWork {
            DispatchQueue.global().asyncAfter(deadline: .now() + suspendDebounce, execute: scheduledWork)
        }
    }

    private func hasActiveSessions(_ instance: String) -> Bool {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return (activeSessions[instance] ?? 0) > 0
    }

    /// Instances whose VM is being brought up right now, reserved under
    /// `managersLock` between the cap check and `ensureRunning()` finishing.
    ///
    /// Without this the cap is a check-then-act race: every accepted
    /// connection is handled in its own `Task`, so five simultaneous
    /// `SESSION` requests would all read a running-count of zero, all pass,
    /// and all start. Same shape as the torn `lastActivity` write that once
    /// crashed this daemon outright - concurrency here is real, not
    /// theoretical.
    private var startingInstances: Set<String> = []
    /// Instances whose disk a maintenance run currently holds - see
    /// `reserveMaintenanceSlot` for why this isn't `startingInstances`.
    private var maintenanceInstances = Set<String>()

    enum CapError: Error, CustomStringConvertible {
        case atRunningCap(running: [String], limit: Int)

        var description: String {
            switch self {
            case .atRunningCap(let running, let limit):
                return "\(limit) instances are already running (\(running.joined(separator: ", "))) - MSL runs at most \(limit) at once; suspend or shut one down first"
            }
        }
    }

    /// Something an instance needs to boot isn't on this Mac.
    ///
    /// Checked *before* handing the configuration to Virtualization, which
    /// answers a missing kernel with `VZErrorDomain Code=2 "The boot loader
    /// is invalid"` wrapped around a POSIX ENOENT - four nested errors that
    /// never name the file or say what to do about it. That dump is what a
    /// shipment installed onto a Mac with no distro downloaded produced
    /// (2026-10-02).
    enum BootFilesError: Error, CustomStringConvertible {
        case missing(instance: String, reason: String)

        var description: String {
            switch self {
            case .missing(let instance, let reason):
                return "\(instance) can't start: \(reason)"
            }
        }
    }

    /// Claims a slot for `instance` against `InstanceRegistry.maxConcurrentRunning`,
    /// or throws if every slot is taken. An instance that already holds a
    /// slot (running, paused, or mid-start) reclaims its own rather than
    /// taking a second - re-entering a running instance must never be
    /// refused.
    ///
    /// A **paused** VM counts. `suspendLight()` pauses rather than stops,
    /// and a paused `VZVirtualMachine` still holds its entire guest RAM
    /// allocation on the host, so treating paused as free would let the cap
    /// be exceeded by exactly the resource it exists to bound.
    private func reserveRunSlot(for instance: String) throws {
        managersLock.lock()
        defer { managersLock.unlock() }
        guard try !holdsOrCanTakeSlot(instance, enforceCap: true) else { return }
        startingInstances.insert(instance)
    }

    /// Takes a slot for the whole of a maintenance run, or returns `false` if
    /// another maintenance run already holds this instance.
    ///
    /// A set of its own, not `startingInstances`. A start attempted during
    /// maintenance reaches `ensureRunningWithinCap`, whose deferred
    /// `releaseRunSlot` removes the instance from `startingInstances` - so if
    /// maintenance lived there, a *refused* start would quietly drop the
    /// repair's reservation and let another instance on the same disk start
    /// in the middle of it.
    ///
    /// The shared-disk rule is the point of all this. Two instances of one
    /// distro share one image file; checking or repairing it while the
    /// *other* instance has it mounted would destroy it. The cap is enforced
    /// only for a maintenance boot - a host-side check uses no guest memory.
    private func reserveMaintenanceSlot(for instance: String, enforceCap: Bool) throws -> Bool {
        managersLock.lock()
        defer { managersLock.unlock() }
        if maintenanceInstances.contains(instance) { return false }
        _ = try holdsOrCanTakeSlot(instance, enforceCap: enforceCap)
        maintenanceInstances.insert(instance)
        return true
    }

    private func releaseMaintenanceSlot(for instance: String) {
        managersLock.lock()
        maintenanceInstances.remove(instance)
        managersLock.unlock()
    }

    /// The occupied-set rules, shared by starts and maintenance. Must be
    /// called with `managersLock` held. Returns `true` when `instance` already
    /// holds a slot; otherwise throws if taking one would breach the
    /// shared-disk rule or (when asked) the cap.
    private func holdsOrCanTakeSlot(_ instance: String, enforceCap: Bool) throws -> Bool {
        var occupied: [String] = []
        for (name, manager) in managers where manager.currentState() != .stopped {
            occupied.append(name)
        }
        for name in startingInstances.union(maintenanceInstances) where !occupied.contains(name) {
            occupied.append(name)
        }
        if occupied.contains(instance) { return true }

        // Two instances of one distro used to be two writers on one raw disk
        // file, so starting the second had to be refused. They each have
        // their own disk now (`InstanceDisk`), which is the whole point of
        // that change: `msl work --distro debian` and `msl personal --distro
        // debian` are two separate machines and run together like any other
        // pair. The refusal is gone; only the memory cap below is left.

        if enforceCap, occupied.count >= InstanceRegistry.maxConcurrentRunning {
            throw CapError.atRunningCap(running: occupied.sorted(), limit: InstanceRegistry.maxConcurrentRunning)
        }
        return false
    }

    /// Drops the mid-start reservation. Safe to call whether the start
    /// succeeded (the manager's own `.running` state holds the slot from
    /// here on) or failed (nothing holds it, which is correct).
    private func releaseRunSlot(for instance: String) {
        managersLock.lock()
        startingInstances.remove(instance)
        managersLock.unlock()
    }

    /// `reserveRunSlot` + `ensureRunning` + release, as one step. Every
    /// path that can bring a VM up goes through this; none calls
    /// `ensureRunning()` directly any more.
    func ensureRunningWithinCap(_ manager: VMManager, instance: String) async throws {
        // Never start a VM in the middle of a power response - see
        // `SystemResilienceMonitor.isResponding`. The wait is bounded: a
        // response is seconds, and a stuck one must not hang every session.
        var waited = 0
        while powerResponseInFlight(), waited < 600 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        // Before the slot and before Virtualization sees anything: an
        // instance whose kernel isn't on this Mac must be told so in MSL's
        // own words, not through a four-deep VZErrorDomain dump.
        let distro = registry.distro(for: instance) ?? .alpine
        // **Skipped for a protected instance**, whose disk is inside its
        // container rather than at `disks/<name>.img`. This check reads the
        // plain path, so without this it reported "its disk is missing -
        // the instance's filesystem isn't on this Mac any more" about an
        // instance whose filesystem was right there, encrypted. Found on
        // the first live boot from a container.
        //
        // Nothing is lost by skipping it: the container's own absence is
        // reported by `openVaultIfNeeded`, which refuses the boot with a
        // message about the container instead of about a missing file.
        let isProtected: Bool = {
            guard case .valid(let identity) = InstanceIdentityStore.verdict(for: instance)
            else { return false }
            return InstanceVault.exists(serial: identity.serial)
        }()
        if !isProtected,
           let reason = distro.bootFiles(instance: instance).missingDescription(distro: distro) {
            throw BootFilesError.missing(instance: instance, reason: reason)
        }

        try reserveRunSlot(for: instance)
        defer { releaseRunSlot(for: instance) }
        let wasRunning = manager.currentState() == .running
        try await manager.ensureRunning()
        // An instance that was published stays published across a restart -
        // which is the whole point of using one as a small server, and also
        // the half of this feature that deserves care. It is deliberate and
        // per instance: nothing becomes reachable that was not already
        // asked to be, and the app always shows that it is.
        //
        // Detached, because opening a tunnel is a network round trip to a
        // relay and nobody should wait for it to get a shell.
        // Forwards come back with the instance, on the same reasoning and
        // with the same care: a forward is per instance and asked for
        // explicitly, nothing is opened that nobody asked for, and the
        // listener is loopback-only. Detached, because the SSH route is a
        // network round trip and nobody should wait for it to get a shell.
        if !PortForwardStore.forInstance(instance).isEmpty {
            configureForwarding()
            Task.detached(priority: .utility) {
                ForwardManager.shared.instanceStarted(instance) {
                    Self.publicLog("forward \(instance)", $0)
                }
            }
        }
        if PublicPolicyStore.load(instance: instance)?.enabled == true {
            configurePublicMSL()
            PublicMSLManager.shared.restoreIfEnabled(instance: instance) {
                Self.publicLog(instance, $0)
            }
        }
        // Only after a start that actually brought the guest up, and never
        // in the caller's way: extending the filesystem into space added
        // while the VM was stopped needs a running guest, and sampling how
        // full it is needs a mounted one. Detached so a slow `resize2fs` on
        // a large disk can't hold up the session the user asked for.
        // Bring this instance's `shellinit` up to date, if it is not.
        //
        // Every published image carries whatever `shellinit` it was built
        // with, and detachable sessions need a newer one - but instances
        // have their own disks, so this is a per-instance upgrade and not a
        // reason to rebuild and republish twelve images. Done on a cold
        // start only (`!wasRunning`): a resume restores the processes that
        // were already running, so there is nothing to upgrade into.
        //
        // Detached, and allowed to fail silently: a guest with no `cc`
        // simply keeps the `shellinit` it has, and the protocol is built so
        // an older one is detected and worked with rather than broken.
        // The guest-side provenance marker, on a cold start only.
        //
        // **This cannot prevent a boot, and nothing here pretends it
        // can.** The marker lives inside the guest's filesystem, so
        // reading it needs the guest up - the check therefore ENDS a boot
        // rather than refusing one. The host-side check in
        // `VMManager.ensureRunning` is the one that prevents; this one
        // catches the attack that check cannot see, a disk swapped under a
        // name whose identity is perfectly valid.
        //
        // Detached, like every other first-boot guest task, so a slow
        // round trip never holds up the session somebody asked for.
        if !wasRunning {
            Task.detached(priority: .utility) { [weak self] in
                await self?.checkGuestWitness(instance: instance, manager: manager)
            }
        }
        if !wasRunning, let install = GuestShellUpgrade.installCommand() {
            Task.detached(priority: .utility) {
                let result = await manager.runInternalCommand(install, timeout: 120)
                let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.exitCode == 0, said.contains("updated to") else {
                    if !said.isEmpty { MSLLog.line("shellinit", "\(instance): \(said)") }
                    return
                }
                // No restart: the running listener owns the vsock port, so
                // a replacement cannot bind until it is gone and every
                // connection in that window is reset. The new binary serves
                // from this instance's next start instead.
                MSLLog.line("shellinit", "\(instance): \(said) - active from the next start")
            }
        }

        // Linux apps that were open when this instance was hibernated. Only
        // after a start that actually brought the guest up, and detached:
        // nobody is waiting on a window reopening, and one app failing must
        // not hold up the session the user actually asked for.
        if !wasRunning,
           InstanceExperiments.effective(for: instance).reopenAppsAfterHibernate,
           AppSessionRestore.manifest(for: instance) != nil {
            let distro = registry.distro(for: instance) ?? .alpine
            Task.detached(priority: .utility) {
                let result = AppSessionRestore.reopen(
                    instance: instance, distro: distro,
                    launch: AppSessionRestore.launcher(instance: instance, distro: distro))
                if !result.unknown.isEmpty {
                    MSLLog.line("reopen", "\(instance): no command known for \(result.unknown.joined(separator: ", "))")
                }
            }
        }

        if !wasRunning {
            // The clock first, and awaited: it's two quick round trips, and
            // whatever the user asked the guest to do next - a `curl`, a
            // `git pull`, a package install - needs the right time already.
            await manager.syncClockAfterStart()
            // Same reason: the image's hard-coded resolver may not work on
            // the network the Mac is on now.
            await manager.refreshGuestDNS(reason: "start")
            Task { await manager.linkMacHomes() }
            Task { await manager.applyPendingStorageChanges() }
        }
    }

    /// How many instances currently hold a slot, and the cap - for
    /// `INSTANCE_DETAILS`, so the UI can show "3 / 4" without guessing.
    private func runSlotUsage() -> (used: Int, cap: Int) {
        managersLock.lock()
        defer { managersLock.unlock() }
        var occupied = Set(managers.filter { $0.value.currentState() != .stopped }.keys)
        occupied.formUnion(startingInstances)
        occupied.formUnion(maintenanceInstances)
        return (occupied.count, InstanceRegistry.maxConcurrentRunning)
    }

    /// `instance`'s manager **only if this daemon session already has
    /// one** - never registers, never builds. Read-only verbs (`STATUS`,
    /// `INSTANCE_DETAILS`) must use this: `manager(for:)` calls
    /// `registry.ensureRegistered`, so answering "what state is `--shutdown`
    /// in?" would register an instance named `--shutdown`. That is exactly
    /// how `--`, `start` and `--shutdown` ended up in `instances.json`.
    private func peekManager(for instance: String) -> VMManager? {
        managersLock.lock()
        defer { managersLock.unlock() }
        return managers[instance]
    }

    init(registry: InstanceRegistry, makeConfiguration: @escaping (String, GuestDistro) -> VMConfiguration) {
        self.registry = registry
        self.makeConfiguration = makeConfiguration
        // Before anything can boot. The daemon is the only place that knows
        // nothing is running yet, and a disk cloned out from under a live
        // guest is a clone of a half-written filesystem. Does nothing on a
        // machine that has already been migrated, and tries again next start
        // if an instance happens to be up.
        let outcome = InstanceLayoutMigration.runIfNeeded(
            instances: registry.entries(),
            isRunning: { _ in false },
            log: { FileHandle.standardError.write(("mslhd: " + $0 + "\n").data(using: .utf8)!) })
        for failure in outcome.failures {
            FileHandle.standardError.write("mslhd: disk migration: \(failure)\n".data(using: .utf8)!)
        }
    }

    /// `distro` only takes effect the first time `instance` is registered -
    /// see `InstanceRegistry.ensureRegistered`. Every other caller (status,
    /// suspend, etc.) passes the default and it's silently ignored for an
    /// already-existing instance.
    /// Runs one maintenance command and returns its reply line.
    ///
    /// Always a status (for `status`) or an outcome (for everything else),
    /// never a bare error - so the app always has a sentence to show, and a
    /// refusal reads the same way as a result.
    private static func performMaintenance(_ command: MaintenanceCommand, on manager: VMManager,
                                           instance: String) async -> String {
        if command == .status {
            return await manager.maintenanceStatus().wireLine
        }
        let outcome: MaintenanceOutcome
        do {
            if let mode = command.fsckMode {
                outcome = MaintenanceOutcome(fsck: try await manager.runFilesystemMaintenance(mode: mode))
            } else if let action = command.bootAction {
                outcome = MaintenanceOutcome(report: try await manager.runMaintenanceBoot(action))
            } else if let utility = command.utility {
                outcome = MaintenanceOutcome(utility: utility, result: try await manager.runGuestUtility(utility))
            } else {
                switch command {
                case .backupDiscard:
                    try await manager.discardRepairBackup()
                    outcome = MaintenanceOutcome(tone: .good, title: "Backup discarded",
                                                 detail: "The copy of the disk from before the repair has been deleted.")
                case .backupRestore:
                    try await manager.restoreRepairBackup()
                    outcome = MaintenanceOutcome(tone: .good, title: "Disk restored",
                                                 detail: "The disk is back to exactly how it was before the repair.")
                case .checkAtStartOn, .checkAtStartOff:
                    let on = command == .checkAtStartOn
                    if on, E2fsck.locate() == nil {
                        // Refused here rather than accepted and then failing
                        // every boot with it.
                        outcome = .failure(E2fsck.installHint)
                    } else {
                        var settings = MaintenanceSettingsStore.load(instance: instance)
                        settings.checkFilesystemAtStart = on
                        MaintenanceSettingsStore.save(settings, instance: instance)
                        outcome = MaintenanceOutcome(
                            tone: .good,
                            title: on ? "Check at start is on" : "Check at start is off",
                            detail: on
                                ? "Every start now checks the disk first, and won't boot on a damaged one."
                                : "Starts no longer check the disk first.")
                    }
                default:
                    outcome = .failure("unhandled maintenance command \(command.rawValue)")
                }
            }
        } catch {
            outcome = .failure("\(error)")
        }
        return outcome.wireLine
    }

    private func manager(for instance: String, distro: GuestDistro = .alpine) throws -> VMManager {
        managersLock.lock()
        defer { managersLock.unlock() }
        if let existing = managers[instance] { return existing }
        try registry.ensureRegistered(instance, distro: distro)
        let resolvedDistro = registry.distro(for: instance) ?? distro
        let manager = VMManager(configuration: makeConfiguration(instance, resolvedDistro))
        managers[instance] = manager
        return manager
    }

    /// Removes and returns `instance`'s manager if this daemon session has
    /// one, without registering a new one if it doesn't (unlike `manager
    /// (for:)`) - `nil` just means "never touched this session," not an
    /// error. A plain synchronous method (not `async`) purely so its lock/
    /// unlock pair can live together in one place, callable from
    /// `handleRemove`'s `async` body without the Swift 6 "lock unavailable
    /// from asynchronous contexts" warning that calling `NSLock` directly
    /// inline in an `async` function triggers.
    /// `instance`'s manager if this daemon session already has one, without
    /// creating or removing it - `manager(for:)` would register a brand new
    /// instance just to answer a question, and `takeManager(for:)` would
    /// evict a running VM's manager out from under it. Same lock/unlock
    /// pairing and the same non-`async` reason as `takeManager`.
    /// Which instance holds each attached device, keyed by device token.
    private func heldUSBDevices() -> [String: String] {
        managersLock.lock()
        let snapshot = managers
        managersLock.unlock()
        var held: [String: String] = [:]
        for (name, manager) in snapshot where manager.isRunning {
            for attachment in manager.usbAttachments() { held[attachment.device] = name }
        }
        return held
    }

    private struct ResolvedUSB {
        let token: String
        let displayName: String
        let speed: UInt32
        let claim: USBDriverClaim
    }

    /// Turns what the person typed into one device.
    ///
    /// Accepts a `locationID` in hex, a `vendor:product` pair, or
    /// `synthetic`. `vendor:product` is what anybody actually knows about
    /// their hardware - a location ID is a port path nobody has memorised -
    /// but it is not unique, so two of the same adapter is an error rather
    /// than a coin flip.
    /// A refusal with something to print. `Result`'s failure has to be an
    /// `Error`, and every one of these is a sentence for the person rather
    /// than a condition to branch on.
    private struct USBRefusal: Error { let message: String }

    private func resolveUSB(_ device: String) -> Result<ResolvedUSB, USBRefusal> {
        if device.lowercased() == "synthetic" {
            return .success(ResolvedUSB(token: "synthetic",
                                        displayName: "MSL Virtual Test Device", speed: 3,
                                        claim: USBDriverClaim(onDevice: [], onInterfaces: [])))
        }
        let devices = USBDeviceEnumerator.listDevices()
        var matches: [USBDeviceInfo] = []
        if device.contains(":") {
            let parts = device.split(separator: ":")
            guard parts.count == 2,
                  let vendor = UInt16(parts[0], radix: 16),
                  let product = UInt16(parts[1], radix: 16) else {
                return .failure(USBRefusal(message: "not a vendor:product pair: \(device)"))
            }
            matches = devices.filter { $0.vendorID == vendor && $0.productID == product }
        } else if let locationID = UInt32(device, radix: 16) {
            matches = devices.filter { $0.locationID == locationID }
        } else {
            return .failure(USBRefusal(message: "not a location ID or vendor:product pair: \(device)"))
        }

        guard let found = matches.first else {
            return .failure(USBRefusal(message: devices.isEmpty
                ? "no USB devices are attached to the Mac"
                : "no USB device matches \(device) - msl usb list shows what is there"))
        }
        guard matches.count == 1 else {
            let locations = matches.map { String(format: "%08x", $0.locationID) }.joined(separator: ", ")
            return .failure(USBRefusal(
                message: "\(matches.count) devices match \(device) - name one by location ID: \(locations)"))
        }
        guard let service = USBDeviceEnumerator.findService(locationID: found.locationID) else {
            return .failure(USBRefusal(message: "\(found.description) went away while it was being looked up"))
        }
        defer { IOObjectRelease(service.service) }
        return .success(ResolvedUSB(token: String(format: "%08x", found.locationID),
                                    displayName: found.productName ?? found.description,
                                    speed: HostUSBDevice.linkSpeed(of: service.service),
                                    claim: USBDriverProbe.claim(of: service.service)))
    }

    /// One line per endpoint, parsed by the CLI and the app.
    private static func describe(_ endpoint: PublicEndpoint) -> String {
        let expiry = endpoint.expires.map { String(Int($0.timeIntervalSinceNow)) } ?? "-"
        return [endpoint.host, String(endpoint.port), endpoint.user,
                endpoint.identityFile, expiry, endpoint.backend].joined(separator: "\t")
    }

    private static func publicLog(_ instance: String, _ message: String) {
        FileHandle.standardError.write("[mslpublic \(instance)] \(message)\n".data(using: .utf8)!)
    }

    /// Hands `PublicMSLManager` the few things it needs from the daemon.
    ///
    /// Injected rather than reached for, so the whole publishing path can
    /// be exercised in tests with no virtual machine anywhere near it.
    private func configurePublicMSL() {
        PublicMSLManager.shared.configure(host: .init(
            guestAddress: { [weak self] name in
                guard let manager = self?.existingManager(for: name), manager.isRunning else { return nil }
                return SSHSetup.RecordStore.load(instance: name)?.host
                    ?? runBlockingOnDaemon { await manager.runInternalCommand("hostname -I", timeout: 15) }
                        .output.split(separator: " ").first.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
            },
            guestUser: { name in LinuxUserSetup.defaultUser(forInstance: name) ?? "msl" },
            runAsRoot: { [weak self] name, command in
                guard let manager = self?.existingManager(for: name) else { return (-1, "") }
                return runBlockingOnDaemon { await manager.runInternalCommand(command, timeout: 90, user: "root") }
            }))
    }

    /// Brings back every instance that was published when the Mac last
    /// shut down.
    ///
    /// Called once at daemon start. Without it the policy file survived a
    /// reboot and nothing read it until somebody opened a session - so a
    /// machine somebody is using as a small server came back unreachable,
    /// with the app still showing it as published. That is the worst
    /// possible shape for this feature: it looks fine and it is not.
    func restorePublishedInstances() {
        // The one-shot identity pass, before anything can be started.
        //
        // Here because MSL has no upgrade hook, and "the first time the new
        // daemon runs" is the closest honest equivalent. Idempotent, so
        // calling it every start costs a `stat` once the record exists.
        if let issued = InstanceIdentityMigration.runIfNeeded(instances: registry.list()),
           !issued.isEmpty {
            MSLLog.line("identity",
                        "issued identities to \(issued.count) existing instance(s): "
                        + issued.joined(separator: ", "))
        }
        configurePublicMSL()
        // Forwards come back here too, for the same reason: the file
        // survives a reboot and nothing else would read it, so a forward
        // somebody relies on would come back dead with no sign of it.
        configureForwarding()
        ForwardManager.shared.restoreAll { Self.publicLog("forward", $0) }
        // Even with nothing published, leftovers from the previous daemon
        // have to go - a policy the user revoked while mslhd was down would
        // otherwise still have a live tunnel behind it.
        TunnelReaper.reapAll { Self.publicLog("startup", $0) }
        // An older MSL kept its public keys inside the home directory,
        // which every guest can read through /mnt/mac.
        PublicKeyPair.removeLegacyKeys { Self.publicLog("startup", $0) }
        // And the temporary-directory ones, from the version before these
        // moved somewhere that survives a restart.
        PublicKeyPair.removeLegacyTemporaryKeys()
        PublicMSLManager.shared.restoreAll(startInstance: { [weak self] instance in
            guard let self else { return false }
            return runBlockingOnDaemon {
                do {
                    let vmManager = try await self.manager(for: instance)
                    try await self.ensureRunningWithinCap(vmManager, instance: instance)
                    return true
                } catch {
                    return false
                }
            }
        }, log: { Self.publicLog("startup", $0) })
    }

    private static func usbLog(_ instance: String, _ message: String) {
        FileHandle.standardError.write("[mslusb \(instance)] \(message)\n".data(using: .utf8)!)
    }

    private func existingManager(for instance: String) -> VMManager? {
        managersLock.lock()
        defer { managersLock.unlock() }
        return managers[instance]
    }

    private func takeManager(for instance: String) -> VMManager? {
        managersLock.lock()
        defer { managersLock.unlock() }
        return managers.removeValue(forKey: instance)
    }

    /// Every `VMManager` this daemon session currently knows about (has
    /// touched at least once since it started), regardless of state -
    /// callers filter by `currentState()` themselves. Used by
    /// `SystemResilienceMonitor` to find every instance worth hibernating/
    /// suspending on a system power event; a registered-but-never-started
    /// instance simply never appears here since no `VMManager` was ever
    /// built for it (nothing to do for one anyway - it's already `.stopped`
    /// in every sense that matters).
    /// Discards bookkeeping that did not survive a host sleep.
    ///
    /// Every vsock connection dies when the host sleeps, so every session
    /// that was open is gone - but no client is left to send
    /// `.sessionEnded`, and `activeSessions` only ever decrements on that.
    /// One sleep therefore leaves counts permanently inflated, and an
    /// instance whose count never reaches zero never auto-suspends again:
    /// it stays resident, holding a concurrency slot and its full guest RAM,
    /// for as long as the daemon lives. The counter's own doc comment calls
    /// a single crashed client "a safe failure mode"; a sleep kills them all
    /// at once, every time the lid closes, which is a different thing.
    ///
    /// Pending suspends are cancelled too - they were scheduled against a
    /// session state that no longer exists.
    func hostDidWake() {
        sessionsLock.lock()
        let inflated = activeSessions.filter { $0.value > 0 }.keys.sorted()
        activeSessions.removeAll()
        for (_, work) in pendingSuspend { work.cancel() }
        pendingSuspend.removeAll()
        sessionsLock.unlock()

        if !inflated.isEmpty {
            FileHandle.standardError.write(
                "mslhd: host woke - cleared session counts for \(inflated.joined(separator: ", ")); those sessions died with the sleep\n"
                    .data(using: .utf8)!)
        }

        // An instance that was idle-timed just before the sleep would
        // otherwise be judged on a timestamp from before it, and hibernated
        // the moment the machine wakes.
        activityLock.lock()
        for name in lastActivity.keys { lastActivity[name] = Date() }
        activityLock.unlock()
    }

    func allManagers() -> [VMManager] {
        managersLock.lock()
        defer { managersLock.unlock() }
        return Array(managers.values)
    }

    func run() throws {
        try bindAndListen()
        startIdleTimer()

        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }
            Task { [weak self] in
                await self?.handle(clientFD: clientFD)
            }
        }
    }

    private func bindAndListen() throws {
        let path = DaemonProtocol.defaultSocketPath()
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw DaemonServerError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is 104 bytes on Darwin - double check against <sys/un.h>
        // if targeting anything else.
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                path.withCString { strncpy(cptr, $0, 103) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw DaemonServerError.bindFailed(errno) }
        guard listen(listenFD, 16) == 0 else { throw DaemonServerError.listenFailed(errno) }
    }

    private func handle(clientFD: Int32) async {
        defer { close(clientFD) }

        guard let line = DaemonProtocol.readLine(fd: clientFD),
              let request = DaemonProtocol.ControlRequest.parse(line) else {
            return
        }

        // Every request that brings a VM *up* counts as activity, not just
        // `.session`.
        //
        // Only `.session` did before, and the idle timer hibernates any
        // instance whose last activity is older than `idleTimeout`. An
        // instance with no recorded activity has `.distantPast`, which is
        // older than any timeout - so an instance started through `RESUME`
        // or `START_NATIVE_GUI` (never through a shell session) was
        // hibernated by the very next 30-second tick. Nothing noticed
        // while starting a VM meant typing `msl <name>`; MSLApp's Start
        // button makes it the normal case, and four instances started this
        // way all disappeared within a minute.
        //
        // Queries are deliberately NOT activity: MSLApp polls
        // `INSTANCE_DETAILS` every few seconds, and counting that would
        // mean nothing is ever idle while the app is open.
        if let started = request.startsInstance {
            // The lock is enforced here, not in the app: this is where every
            // request that would start something meets, and `msl work` skips
            // the app entirely. Already-running instances are not re-asked -
            // see `InstanceLockPolicy`.
            let state = (try? await manager(for: started).currentState()) ?? .stopped
            let live = state == .running || state == .paused
            if InstanceLockPolicy.requiresAuthentication(instance: started,
                                                         isRunningOrPaused: live,
                                                         settings: InstanceLockStore.load()) {
                switch await BiometricAuth.authenticate(reason: InstanceLockPolicy.reason(for: started)) {
                case .authenticated:
                    break
                case .denied(let why):
                    respond(clientFD, ok: false, "\(started) is locked - \(why)")
                    return
                case .unavailable(let why):
                    // Refusing here would make the instance unstartable on a
                    // Mac that cannot authenticate, which is worse than the
                    // lock not applying. Say so plainly in the log.
                    FileHandle.standardError.write(
                        "mslhd: \(started) is locked, but this Mac can't authenticate (\(why)) - starting anyway\n"
                            .data(using: .utf8)!)
                }
            }
            recordActivity(started)
            registry.recordLastUsed(started)
        }

        if let summary = request.monitorSummary {
            ActivityLog.shared.record(request.monitorCategory,
                                      instance: request.monitorInstance, summary)
        }

        // **MSLAP, at the one chokepoint.** The app and the CLI both reach
        // MSL through here, so a refusal binds both by construction -
        // enforcing in the app would leave `msl` able to do the thing
        // anyway. Checked before the request is dispatched, and before any
        // VM is touched.
        let managed = MSLAPPolicyStore.cached()
        Self.logPolicyStateOnce(managed)
        var activePolicy: MSLAPPolicy?
        var activeIssuer: String?
        switch managed {
        case .managed(let loaded):
            activePolicy = loaded.policy
            activeIssuer = loaded.policy.issuer
        case .broken(_, let fallback):
            // A tampered policy falls back to the last one that verified,
            // never to freedom - otherwise editing the file would be the
            // easiest way to lift every restriction on the machine.
            activePolicy = fallback
            activeIssuer = fallback?.issuer
        case .unmanaged:
            break
        }
        if let refusal = MSLAPEnforcement.check(request,
                                                policy: activePolicy,
                                                issuer: activeIssuer) {
            MSLLog.line("mslap", refusal)
            respond(clientFD, ok: false, refusal)
            return
        }

        do {
            switch request {
            case .session(let instance, _, _, let distro):
                try await handleSession(instance: instance, distro: distro, clientFD: clientFD)
            case .attachSession(let instance, let port):
                try await handleAttach(instance: instance, port: port, clientFD: clientFD)
            case .suspend(let instance):
                MSLLog.line("session", "\(instance): suspending on request")
                try await manager(for: instance).suspendLight()
                stopForwards(for: instance)
                respond(clientFD, ok: true, "suspended \(instance)")
            case .resume(let instance):
                try await ensureRunningWithinCap(manager(for: instance), instance: instance)
                respond(clientFD, ok: true, "resumed \(instance)")
            case .hibernate(let instance):
                // Linux apps close first, and politely. The guest's RAM is
                // about to be written whole, so an app left running is saved
                // blind - its X server dies with the Mac side - and comes
                // back holding a singleton lock it cannot be restarted
                // around. See `AppSessionRestore`.
                if InstanceExperiments.effective(for: instance).reopenAppsAfterHibernate {
                    // Resolved through this daemon's own VM manager, never
                    // back out through `LinuxAppLauncher` - that would send a
                    // request into the daemon currently serving this one.
                    let vm = try? manager(for: instance)
                    let closed = AppSessionRestore.closeApps(
                        instance: instance,
                        resolve: { name in
                            guard let vm, let candidate = AppSessionRestore.candidateCommand(for: name)
                            else { return nil }
                            let found = runBlockingOnDaemon {
                                await vm.runInternalCommand("command -v \(candidate)", timeout: 10)
                            }
                            return found.exitCode == 0 && !found.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? candidate : nil
                        })
                    guard closed.allClosed else {
                        // The person asked for this, so the person gets to
                        // decide. An app that will not close is an app with
                        // unsaved work in it.
                        AppSessionRestore.forget(instance: instance)
                        respond(clientFD, ok: false,
                                "\(closed.stubborn.joined(separator: ", ")) wouldn't close, so \(instance) was left running - save your work and try again")
                        break
                    }
                }
                let closing = AppSessionRestore.manifest(for: instance)?.apps ?? []
                try await manager(for: instance).hibernate()
                // Said plainly, because this is the thing people are
                // surprised by: a hibernate **closes** Linux apps. It has
                // to - their X server is on the Mac and does not survive -
                // so they come back reopened, not where they were, except
                // where the app restores its own session.
                if closing.isEmpty {
                    respond(clientFD, ok: true, "hibernated \(instance)")
                } else {
                    let names = closing.map(\.name).joined(separator: ", ")
                    respond(clientFD, ok: true,
                            "hibernated \(instance) - closed \(names); they reopen on resume. Use suspend instead to keep them exactly as they are.")
                }
            case .snapshotSave(let instance, let name):
                try await manager(for: instance).snapshotSave(name: name)
                respond(clientFD, ok: true, "saved snapshot '\(name)' for \(instance)")
            case .snapshotRestore(let instance, let name):
                try await manager(for: instance).snapshotRestore(name: name)
                respond(clientFD, ok: true, "restored snapshot '\(name)' for \(instance)")
            case .snapshotList(let instance):
                let names = try manager(for: instance).snapshotList()
                respond(clientFD, ok: true, names.isEmpty ? "(none)" : names.joined(separator: ", "))
            case .status(let instance):
                // Deliberately non-registering (see `peekManager`): asking
                // about an instance must never create it. An unknown or
                // never-started name is `stopped`, which is the truth.
                let state = peekManager(for: instance)?.currentState() ?? .stopped
                respond(clientFD, ok: true, state.rawValue)
            case .instanceList:
                // **With the state, which `msl list` has always promised and
                // never gave.** Its own help line says "Every instance and
                // whether it's running"; it printed names and distros only,
                // so the single question you most want answered in a hurry -
                // what is live right now? - had no command that answered it.
                // `msl status` with no argument reports one instance, and
                // said "stopped" with two guests running (2026-10-01).
                //
                // Only non-stopped states are shown, so the usual listing
                // stays short and anything running stands out.
                let names = registry.list()
                let described = names.map { name -> String in
                    let distro = registry.distro(for: name)?.rawValue ?? "?"
                    let state = peekManager(for: name)?.currentState() ?? .stopped
                    return state == .stopped
                        ? "\(name) (\(distro))"
                        : "\(name) (\(distro), \(state.rawValue))"
                }
                respond(clientFD, ok: true, described.isEmpty ? "(none)" : described.joined(separator: ", "))
            case .createInstance(let instance, let distro):
                // `CLICommands.nameRefusal`, not `isValidName`: it covers
                // the character rules *and* refuses a name that a command
                // already owns, which an instance could never be addressed
                // by again (`msl run` can't reach an instance called `run`).
                // Here because this is the one place every caller - the CLI,
                // the app's New Instance sheet, a shipment - comes through.
                if let refusal = CLICommands.nameRefusal(instance) {
                    respond(clientFD, ok: false, refusal)
                    break
                }
                // Issued below, after the instance really exists.
                guard registry.distro(for: instance) == nil else {
                    respond(clientFD, ok: false, "instance '\(instance)' already exists")
                    break
                }
                _ = try registry.ensureRegistered(instance, distro: distro)
                // No identity call here: `ensureRegistered` above issues
                // one, which is the real chokepoint - this request is NOT
                // the only way an instance comes into being, whatever its
                // own comment says, because `msl new` registers directly.
                //
                // **A shipment is worth noting:** it also arrives here, and
                // currently reads as a fresh original. Its real lineage is
                // recorded from the manifest in a later step (README 31
                // step 7); until then MSL makes no provenance claim about
                // an imported instance rather than a false one.
                respond(clientFD, ok: true, "created \(instance) (\(distro.rawValue))")
            case .instanceDetails:
                respond(clientFD, ok: true, instanceDetailsBody())
            case .powerTest(let event):
                guard let onPowerTest else {
                    respond(clientFD, ok: false, "power testing isn't wired up in this build")
                    break
                }
                respond(clientFD, ok: true, onPowerTest(event))
            case .remove(let instance, let keepDisk):
                try await handleRemove(instance: instance, keepDisk: keepDisk, clientFD: clientFD)
            case .renameInstance(let instance, let newName):
                try await handleRenameOrClone(instance, to: newName, mode: .move, clientFD: clientFD)
            case .cloneInstance(let instance, let newName):
                try await handleRenameOrClone(instance, to: newName, mode: .copy, clientFD: clientFD)
            case .protectInstance(let instance, let enable):
                try await handleProtect(instance, enable: enable, clientFD: clientFD)
            case .vaultKey(let instance, let action, let passphrase):
                handleVaultKey(instance, action: action, passphrase: passphrase,
                               clientFD: clientFD)
            case .rewriteIdentityMarker(let instance):
                guard let token = InstanceIdentityStore.rawToken(for: instance) else {
                    respond(clientFD, ok: false,
                            "\(instance) has no recorded identity to write - there is nothing to restore")
                    break
                }
                guard let command = GuestIdentityWitness.writeCommand(token: token) else {
                    respond(clientFD, ok: false, "\(instance)'s recorded identity is not usable")
                    break
                }
                let vm = try manager(for: instance)
                try await ensureRunningWithinCap(vm, instance: instance)
                let wrote = await vm.runInternalCommand(command, timeout: 30, user: "root")
                guard wrote.exitCode == 0 else {
                    respond(clientFD, ok: false,
                            "couldn't write the marker in \(instance): \(wrote.output)")
                    break
                }
                InstanceIdentityStore.markWitnessed(instance)
                respond(clientFD, ok: true,
                        "wrote \(instance)'s provenance marker again. If this disk is NOT the one "
                        + "MSL recorded, that claim is now wrong and only you know it.")
            case .forwardAdd(let instance, let hostPort, let guestPort, let viaSSH):
                handleForwardAdd(instance, hostPort: hostPort, guestPort: guestPort,
                                 viaSSH: viaSSH, clientFD: clientFD)
            case .forwardRemove(let hostPort):
                if let removed = ForwardManager.shared.remove(hostPort: hostPort) {
                    respond(clientFD, ok: true, "closed \(removed.description)")
                } else {
                    respond(clientFD, ok: false, "nothing is forwarded from localhost:\(hostPort)")
                }
            case .forwardList(let instance):
                respond(clientFD, ok: true, forwardListBody(instance))
            case .removeDistro(let distro):
                try await handleRemoveDistro(distro, clientFD: clientFD)
            case .sessionEnded(let instance):
                // Fire-and-forget - the client doesn't wait for a response.
                sessionEnded(instance)
            case .shutdown(let instance):
                try await manager(for: instance).stopAfterGuestShutdown()
                stopForwards(for: instance)
                respond(clientFD, ok: true, "shut down \(instance)")
            case .startGui(let instance):
                let vmManager = try manager(for: instance)
                try await ensureRunningWithinCap(vmManager, instance: instance)
                try await vmManager.startDisplayBridge()
                respond(clientFD, ok: true, "GUI tunnel started for \(instance)")
            case .startNativeGui(let instance):
                let vmManager = try manager(for: instance)
                try await ensureRunningWithinCap(vmManager, instance: instance)
                try await vmManager.startX11Server()
                respond(clientFD, ok: true, "native X11 server started for \(instance)")
            case .startCageBridge(let instance, let maxFrames):
                let vmManager = try manager(for: instance)
                try await ensureRunningWithinCap(vmManager, instance: instance)
                try await vmManager.startCageBridge(maxFrames: maxFrames)
                respond(clientFD, ok: true, "cage bridge started for \(instance)")
            case .startCageInputBridge(let instance):
                let vmManager = try manager(for: instance)
                try await ensureRunningWithinCap(vmManager, instance: instance)
                try await vmManager.startCageInputBridge()
                respond(clientFD, ok: true, "cage input bridge started for \(instance)")
            case .sendCageKey(let instance, let keycode, let pressed):
                let vmManager = try manager(for: instance)
                let sent = await vmManager.sendCageKey(keycode: keycode, pressed: pressed)
                respond(clientFD, ok: sent, sent ? "key sent" : "no cageinput connection for \(instance)")
            case .trafficSnapshot(let instance, let attributeProcesses):
                // Only answers for an instance this session already knows and
                // that is actually up. A monitor must not start a VM, and it
                // must not wake a suspended one either - that would change
                // the very thing it claims to be observing.
                guard let vmManager = existingManager(for: instance), vmManager.isRunning else {
                    respond(clientFD, ok: false, "instance is not running")
                    break
                }
                do {
                    let payload = try await TrafficClient(manager: vmManager)
                        .rawSocketsPayload(attributeProcesses: attributeProcesses)
                    respond(clientFD, ok: true, Data(payload).base64EncodedString())
                } catch TrafficClient.TrafficClientError.unavailable {
                    // A distinct marker, not a generic failure: the UI shows
                    // "this image is too old" rather than an empty list that
                    // reads as "nothing is happening".
                    respond(clientFD, ok: false, Self.trafficUnavailableMarker)
                }
            case .maintenance(let instance, let command):
                // Registered instances only. `manager(for:)` would register an
                // unknown name as a brand-new instance, and a typo becoming a
                // VM is a bug this project has already had once.
                guard registry.distro(for: instance) != nil,
                      let vmManager = try? manager(for: instance) else {
                    respond(clientFD, ok: false, "no instance named \(instance)")
                    break
                }
                // Anything that touches the image holds a slot for its whole
                // run - see `reserveMaintenanceSlot`.
                var heldSlot = false
                if command.touchesDisk {
                    do {
                        guard try reserveMaintenanceSlot(for: instance, enforceCap: command.bootsVirtualMachine) else {
                            respond(clientFD, ok: true, MaintenanceOutcome.failure(
                                "Maintenance is already running on this instance's disk.").wireLine)
                            break
                        }
                        heldSlot = true
                    } catch {
                        respond(clientFD, ok: true, MaintenanceOutcome.failure("\(error)").wireLine)
                        break
                    }
                }
                let reply = await Self.performMaintenance(command, on: vmManager, instance: instance)
                if heldSlot { releaseMaintenanceSlot(for: instance) }
                respond(clientFD, ok: true, reply)
            case .filePickDetails(let token):
                // MSL Files asking what a parked pick wants it to show. The
                // claim also says "I am alive", which is what stops
                // `PendingFilePicks.wait` giving up on it - see
                // `READMES/24-FILE-PICKER.md`.
                guard let pick = PendingFilePicks.shared.claim(token: token) else {
                    respond(clientFD, ok: false, "no such file pick")
                    break
                }
                let details: [String: Any] = [
                    "instance": pick.instance,
                    "mode": pick.request.mode.rawValue,
                    "start": pick.request.startGuestPath,
                    "name": pick.request.suggestedName,
                    "multiple": pick.request.allowsMultiple,
                    "title": pick.request.title,
                ]
                let encoded = (try? JSONSerialization.data(withJSONObject: details))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                respond(clientFD, ok: true, encoded)

            case .filePickResult(let token, let encodedPaths, let cancelled):
                // Paths arrive base64'd because this protocol is
                // space-separated and a path may contain spaces.
                let paths = encodedPaths.compactMap { encoded -> String? in
                    Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
                }
                // An empty list from a non-cancel is still not a pick: it
                // means nothing chosen was reachable from the guest.
                let outcome: PendingFilePicks.Outcome =
                    cancelled || paths.isEmpty ? .cancelled : .picked(paths)
                PendingFilePicks.shared.complete(token: token, outcome: outcome)
                respond(clientFD, ok: true, "ok")

            case .fileList(let instance, let guestPath):
                // The app has no vsock; we list on its behalf so MSL Files can
                // overlay the real Linux mode its WebDAV mount fakes. Like the
                // traffic snapshot: an already-running, known instance only -
                // never start or wake one just to show permissions.
                guard let vmManager = existingManager(for: instance), vmManager.isRunning else {
                    respond(clientFD, ok: false, "instance is not running")
                    break
                }
                do {
                    let entries = try await FileOpsClient(manager: vmManager).list(guestPath)
                    let bytes = FileOpsProtocol.encodeEntriesAsList2(entries)
                    respond(clientFD, ok: true, Data(bytes).base64EncodedString())
                } catch {
                    respond(clientFD, ok: false, "\(error)")
                }
            case .localNetworkProbe(let host):
                // **The point is the attempt, not the answer.** macOS grants
                // Local Network per binary, and it is this process that
                // connects to an instance - so trying from here is what
                // raises the prompt against the right one. Asking from
                // MSL.app prompted for MSL.app, the person allowed it, and
                // the daemon was still refused.
                let reachable = PortForwarder.canReach(host: host, port: 22, timeout: 3)
                respond(clientFD, ok: true, reachable ? "reachable" : "unreachable")
            case .gitQuery(let instance, let guestPath, let operation, let argument):
                // Same rule as the other file operations: an already-running,
                // known instance only. A file browser must never boot a VM to
                // decorate a folder, and a passive status overlay that did
                // would start instances just by being scrolled past.
                guard let vmManager = existingManager(for: instance), vmManager.isRunning else {
                    respond(clientFD, ok: false, "instance is not running")
                    break
                }
                // Validated here as well as in the app: the daemon takes
                // requests from anything that can reach its socket, so a
                // check only the UI performs is not a check.
                let script: String? = {
                    switch operation {
                    case .inspect: return Git.inspectScript(path: guestPath)
                    case .badges: return Git.badgesScript(directory: guestPath)
                    case .initialise: return Git.initialiseScript(path: guestPath)
                    case .setOrigin:
                        guard argument.isEmpty || Git.isUsableRemote(argument) else { return nil }
                        return Git.setOriginScript(path: guestPath, url: argument)
                    }
                }()
                guard let script else {
                    respond(clientFD, ok: false, "that is not a usable remote URL")
                    break
                }
                // Base64 the whole script rather than quoting it: it reaches
                // the guest through an exec frame and then a shell, and the
                // path inside it is attacker-shaped data - somebody's folder
                // name - that must not be able to become a command.
                //
                // Twenty seconds. A repository with a lot of history takes a
                // moment, and a mount that has gone away takes forever.
                let result = await vmManager.runInternalCommand(
                    Git.wrapped(script), timeout: 20, user: "root")
                guard result.exitCode == 0 else {
                    respond(clientFD, ok: false, "git could not be run in this instance")
                    break
                }
                respond(clientFD, ok: true, Data(result.output.utf8).base64EncodedString())
            case .fileChmod(let instance, let guestPath, let mode):
                // "Make Executable" and any future permission edit: POSIX bits
                // set over the WebDAV mount never reach the real inode, so this
                // goes straight to fileopsd's CHMOD.
                guard let vmManager = existingManager(for: instance), vmManager.isRunning else {
                    respond(clientFD, ok: false, "instance is not running")
                    break
                }
                do {
                    let applied = try await FileOpsClient(manager: vmManager)
                        .chmodIfSupported(guestPath, mode: mode)
                    if applied {
                        respond(clientFD, ok: true, "ok")
                    } else {
                        respond(clientFD, ok: false, "this guest image is too old to change permissions")
                    }
                } catch {
                    respond(clientFD, ok: false, "\(error)")
                }
            case .usbList:
                // One row per device: location, ids, which macOS driver has
                // it (or none, meaning MSL can pass it through for free),
                // which instance is holding it, and the name. Tab-separated
                // because a product name contains spaces and the CLI does
                // the column alignment.
                let devices = USBDeviceEnumerator.listDevices()
                let held = heldUSBDevices()
                var rows: [String] = []
                for device in devices {
                    let token = String(format: "%08x", device.locationID)
                    let claim = USBDeviceEnumerator.findService(locationID: device.locationID).map {
                        defer { IOObjectRelease($0.service) }
                        return USBDriverProbe.claim(of: $0.service)
                    }
                    rows.append([
                        token,
                        String(format: "%04x:%04x", device.vendorID, device.productID),
                        claim?.summary ?? "unknown",
                        held[token] ?? "-",
                        device.productName ?? "Unknown Device",
                    ].joined(separator: "\t"))
                }
                // Synthetic always available, and listed so that the
                // self-test is discoverable rather than folklore.
                rows.append(["synthetic", "1209:4d53", "none - native",
                             held["synthetic"] ?? "-", "MSL Virtual Test Device"].joined(separator: "\t"))
                respond(clientFD, ok: true, rows.joined(separator: "\n"))

            case .usbPlan(let device):
                switch resolveUSB(device) {
                case .failure(let refusal):
                    respond(clientFD, ok: false, refusal.message)
                case .success(let resolved):
                    // NATIVE or CAPTURE, then the fields the CLI needs to
                    // explain itself and to start a helper.
                    let tier = resolved.claim.isFree ? "NATIVE" : "CAPTURE"
                    let holder = heldUSBDevices()[resolved.token]
                    respond(clientFD, ok: true, [
                        tier, resolved.token, String(resolved.speed),
                        resolved.claim.summary, holder ?? "-", resolved.displayName,
                    ].joined(separator: "\t"))
                }

            case .usbRelay(let instance, let device):
                let vmManager: VMManager
                do {
                    vmManager = try await manager(for: instance)
                    try await ensureRunningWithinCap(vmManager, instance: instance)
                } catch {
                    respond(clientFD, ok: false, "couldn't start \(instance): \(error.localizedDescription)")
                    break
                }
                switch resolveUSB(device) {
                case .failure(let refusal):
                    respond(clientFD, ok: false, refusal.message)
                case .success(let resolved):
                    let attachment = USBAttachment(device: resolved.token,
                                                   displayName: resolved.displayName, captured: true)
                    guard let path = vmManager.prepareUSBRelay(attachment: attachment,
                                                               speed: resolved.speed) else {
                        respond(clientFD, ok: false, "could not open a socket for the root helper")
                        break
                    }
                    respond(clientFD, ok: true, path)
                }

            case .publicExpose(let instance, let backendName):
                // Starts the instance if it is merely paused - there is
                // nothing to publish otherwise, and paused is its normal
                // state a few seconds after the last session closed.
                let vmManager: VMManager
                do {
                    vmManager = try await manager(for: instance)
                    try await ensureRunningWithinCap(vmManager, instance: instance)
                } catch {
                    respond(clientFD, ok: false, "couldn't start \(instance): \(error.localizedDescription)")
                    break
                }
                _ = vmManager
                configurePublicMSL()
                do {
                    let backend = try PublicMSLManager.backend(named: backendName)
                    let endpoint = try PublicMSLManager.shared.expose(
                        instance: instance, backend: backend) { Self.publicLog(instance, $0) }
                    respond(clientFD, ok: true, Self.describe(endpoint))
                } catch {
                    respond(clientFD, ok: false, "\(error)")
                }

            case .publicTailscaleStatus:
                let status = TailscaleCLI.status()
                var lines = ["\(status.state.rawValue)\t\(status.selfName)"]
                for peer in status.peers {
                    lines.append("\(peer.name)\t\(peer.system)\t\(peer.online)")
                }
                respond(clientFD, ok: true, lines.joined(separator: "\n"))

            case .publicMakeKey(let instance, let label):
                // Makes somebody a key and hands it back to be sent by
                // hand. The counterpart to pasting in a key they already
                // have - which is the better way round, but needs them to
                // send you one first, and sometimes you just want to put
                // everything in a message now.
                guard let vm = existingManager(for: instance), vm.isRunning else {
                    respond(clientFD, ok: false, "\(instance) needs to be running")
                    break
                }
                guard let pair = RecipientKey.generate(forEmail: label, instance: instance) else {
                    respond(clientFD, ok: false, "couldn't generate a key")
                    break
                }
                let keyUser = LinuxUserSetup.defaultUser(forInstance: instance) ?? "msl"
                // **Replace this machine's previous key, do not stack one.**
                // The private half goes to the clipboard and is never
                // stored, so the moment it is overwritten the old key is
                // unrecoverable - pressing the button twice used to leave
                // the guest holding keys nobody had, indistinguishable in
                // the roster from real people.
                _ = await vm.runInternalCommand(
                    PublicHardening.deauthorizeCommand(
                        matching: "\(PublicHardening.keyMarker) \(label)", user: keyUser),
                    timeout: 30, user: "root")
                let safeLabel = label.replacingOccurrences(of: "'", with: "")
                let added = await vm.runInternalCommand(
                    PublicHardening.authorizeCommand(publicKey: pair.publicKey,
                                                     label: safeLabel, user: keyUser),
                    timeout: 45, user: "root")
                guard added.output.contains("MSL_KEY") else {
                    respond(clientFD, ok: false, "couldn't add the key to \(instance)")
                    break
                }
                // The private half goes back over the local socket and is
                // never written to disk here: it belongs to whoever is
                // about to be sent it, and a copy on this Mac would only be
                // another thing to look after.
                respond(clientFD, ok: true, pair.privateKey)

            case .publicNotifySetup(let apiKey, let replyTo, let from):
                guard MailMessage.looksLikeAnAddress(from) else {
                    respond(clientFD, ok: false,
                            "the From address doesn't look like an email address. It has to be on a "
                            + "domain you verified in Resend, like msl@your-company.com")
                    break
                }
                guard ResendCredentials.save(apiKey) else {
                    respond(clientFD, ok: false, "couldn't save the API key to the Keychain")
                    break
                }
                let settings = NotifySettings(
                    fromAddress: from,
                    replyTo: replyTo.isEmpty ? nil : replyTo,
                    rotationEmailsPerDay: NotifySettings.load()?.rotationEmailsPerDay ?? 3)
                guard settings.save() else {
                    respond(clientFD, ok: false, "couldn't save the email settings")
                    break
                }
                respond(clientFD, ok: true, "sending as \(from)")

            case .publicNotifyForget:
                ResendCredentials.remove()
                NotifySettings.forget()
                respond(clientFD, ok: true, "email settings removed")

            case .publicNotifyTest(let to):
                guard let mailer = NotifySettings.mailer() else {
                    respond(clientFD, ok: false, "\(MailError.notConfigured)")
                    break
                }
                var message = NotifyMessages.test(to: to)
                message.from = mailer.from
                do {
                    try mailer.send(message)
                    respond(clientFD, ok: true, "sent to \(to)")
                } catch {
                    respond(clientFD, ok: false, "\(error)")
                }

            case .publicNotifyAdd(let instance, let email, let label):
                guard MailMessage.looksLikeAnAddress(email) else {
                    respond(clientFD, ok: false, "\(email) doesn't look like an email address")
                    break
                }
                var roster = NotifyRoster.load(instance: instance)
                guard !roster.contains(where: { $0.email.lowercased() == email.lowercased() }) else {
                    respond(clientFD, ok: true, "\(email) is already on the list for \(instance)")
                    break
                }
                roster.append(NotifyRecipient(email: email, label: label))
                NotifyRoster.save(roster, instance: instance)
                // Already published? Then they should hear now rather than
                // at the next rotation - being added to a live machine and
                // waiting an hour for the email would feel broken.
                if let endpoint = PublicMSLManager.shared.endpoint(instance: instance) {
                    configurePublicMSL()
                    PublicMSLManager.shared.notifyNow(instance: instance, endpoint: endpoint) {
                        Self.publicLog(instance, $0)
                    }
                    respond(clientFD, ok: true, "\(email) added - sending them the details now")
                } else {
                    respond(clientFD, ok: true,
                            "\(email) added. They'll be emailed when you publish \(instance).")
                }

            case .publicNotifyRemove(let instance, let email):
                var roster = NotifyRoster.load(instance: instance)
                let before = roster.count
                roster.removeAll { $0.email.lowercased() == email.lowercased() }
                guard roster.count < before else {
                    respond(clientFD, ok: false, "\(email) isn't on the list for \(instance)")
                    break
                }
                NotifyRoster.save(roster, instance: instance)
                // Their key stays in the guest on purpose: taking somebody
                // off the mailing list is not the same as throwing them out,
                // and `msl public deauthorize` is the command that means
                // that. Said plainly so nobody assumes otherwise.
                respond(clientFD, ok: true,
                        "\(email) will no longer be emailed. Their key still works - "
                        + "remove it with: msl public deauthorize \(instance) \(email)")

            case .publicNotifyList(let instance):
                let settings = NotifySettings.load()
                let configured = ResendCredentials.isConfigured && settings != nil
                var lines = ["CONFIGURED\t\(configured)\t\(settings?.fromAddress ?? "")\t"
                             + "\(settings?.rotationEmailsPerDay ?? 3)"]
                for person in NotifyRoster.load(instance: instance) {
                    lines.append("\(person.email)\t\(person.label)\t\(person.keyDelivered)\t"
                                 + "\(person.lastAddressSent ?? "")")
                }
                respond(clientFD, ok: true, lines.joined(separator: "\n"))

            case .publicAuthorize(let instance, let key, let label):
                // Validated on the Mac before a byte of it goes near the
                // file that decides who may log in. A line that is not a
                // key, or that smuggles a newline, would otherwise be
                // appended to `authorized_keys`.
                guard let clean = PublicHardening.sanitizedPublicKey(key) else {
                    respond(clientFD, ok: false,
                            "that does not look like an SSH public key. It should start with "
                            + "ssh-ed25519 or ssh-rsa - the contents of a .pub file, not a private key.")
                    break
                }
                guard let vm = try? await manager(for: instance), vm.isRunning else {
                    respond(clientFD, ok: false, "\(instance) needs to be running to add a key")
                    break
                }
                let user = LinuxUserSetup.defaultUser(forInstance: instance) ?? "msl"
                let safeLabel = label.replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                let added = await vm.runInternalCommand(
                    PublicHardening.authorizeCommand(publicKey: clean, label: safeLabel, user: user),
                    timeout: 45, user: "root")
                if added.output.contains("MSL_KEY_ALREADY_THERE") {
                    respond(clientFD, ok: true, "that key could already reach \(instance)")
                } else if added.output.contains("MSL_KEY_ADDED") {
                    respond(clientFD, ok: true, "\(safeLabel) can now reach \(instance)")
                } else {
                    respond(clientFD, ok: false, "couldn't add the key: \(added.output)")
                }

            case .publicDeauthorize(let instance, let match):
                guard let vm = try? await manager(for: instance), vm.isRunning else {
                    respond(clientFD, ok: false, "\(instance) needs to be running to remove a key")
                    break
                }
                let user = LinuxUserSetup.defaultUser(forInstance: instance) ?? "msl"
                let safe = match.replacingOccurrences(of: "'", with: "")
                let removed = await vm.runInternalCommand(
                    PublicHardening.deauthorizeCommand(matching: safe, user: user),
                    timeout: 45, user: "root")
                if removed.output.contains("MSL_KEY_REMOVED") {
                    respond(clientFD, ok: true, "removed")
                } else {
                    respond(clientFD, ok: false, "no key on \(instance) matched \(safe)")
                }

            case .publicKeys(let instance):
                guard let vm = existingManager(for: instance), vm.isRunning else {
                    respond(clientFD, ok: false, "\(instance) is not running")
                    break
                }
                let user = LinuxUserSetup.defaultUser(forInstance: instance) ?? "msl"
                let listed = await vm.runInternalCommand(
                    PublicHardening.listKeysCommand(user: user), timeout: 30, user: "root")
                respond(clientFD, ok: true, listed.output.trimmingCharacters(in: .whitespacesAndNewlines))

            case .publicRevoke(let instance):
                configurePublicMSL()
                PublicMSLManager.shared.revoke(instance: instance) { Self.publicLog(instance, $0) }
                respond(clientFD, ok: true, "\(instance) is no longer published")

            case .publicStatus(let instance):
                configurePublicMSL()
                if let endpoint = PublicMSLManager.shared.endpoint(instance: instance) {
                    respond(clientFD, ok: true, Self.describe(endpoint))
                } else if let policy = PublicPolicyStore.load(instance: instance), policy.enabled {
                    // Wanted, but not up: the instance is down, or the
                    // tunnel is being re-established. Saying so beats
                    // saying "not published" about something that will be.
                    respond(clientFD, ok: true, "PENDING \(policy.backend)")
                } else {
                    respond(clientFD, ok: false, "\(instance) is not published")
                }

            case .usbDetach(let instance, let device):
                guard let vmManager = existingManager(for: instance) else {
                    respond(clientFD, ok: false, "\(instance) is not running")
                    break
                }
                if let gone = vmManager.detachUSB(device: device) {
                    respond(clientFD, ok: true, "\(gone.displayName) detached from \(instance)")
                } else {
                    respond(clientFD, ok: false, "\(instance) is not holding \(device)")
                }
            case .usbAttach(let instance, let device, let capture):
                // Deliberately `existingManager`: passthrough is collected
                // by a helper running inside the guest, so an instance that
                // is not up cannot complete one. Booting a VM because
                // somebody plugged in a USB stick would also be a surprise.
                // Starts the instance if it is merely paused, which is its
                // normal state a few seconds after the last session closed.
                let vmManager: VMManager
                do {
                    vmManager = try await manager(for: instance)
                    try await ensureRunningWithinCap(vmManager, instance: instance)
                } catch {
                    respond(clientFD, ok: false, "couldn't start \(instance): \(error.localizedDescription)")
                    break
                }
                let backend: USBIPDeviceBackend
                if device.lowercased() == "synthetic" {
                    // MSL's own self-test: the identical path - vsock
                    // carriage, `vhci_hcd` attach, URB framing - with a
                    // device that is answered from a table instead of from
                    // hardware. It is the only part of passthrough that can
                    // be verified without plugging anything in.
                    backend = SyntheticUSBDevice { Self.usbLog(instance, $0) }
                } else {
                    // Checked before the device is even looked up: it is
                    // true of every device, and saying so first means the
                    // answer does not depend on having guessed a real
                    // location ID.
                    if capture, geteuid() != 0 {
                        respond(clientFD, ok: false,
                                "taking a device from macOS needs root, and mslhd runs as you. "
                                + "Without capture, only a device macOS has no driver for can be "
                                + "attached - and it ships drivers for FTDI, CH34x, CP210x, "
                                + "Prolific and CDC-ACM, so most adapters need capture. "
                                + "Until the root helper exists: sudo msl-usbd serve <locationID> --tcp <port> --capture")
                        break
                    }
                    guard let locationID = UInt32(device, radix: 16) else {
                        respond(clientFD, ok: false, "not a locationID: \(device)")
                        break
                    }
                    guard let found = USBDeviceEnumerator.findService(locationID: locationID) else {
                        respond(clientFD, ok: false, "no USB device at location \(device)")
                        break
                    }
                    defer { IOObjectRelease(found.service) }
                    do {
                        backend = try HostUSBDevice(service: found.service, info: found.info,
                                                    capture: capture) { Self.usbLog(instance, $0) }
                    } catch {
                        respond(clientFD, ok: false,
                                "could not open \(found.info.description): \(error.localizedDescription)"
                                + (capture ? "" : " - macOS may already have a driver for it (try capture)"))
                        break
                    }
                }
                let outcome = await vmManager.attachUSB(backend)
                respond(clientFD, ok: outcome.ok, outcome.message)
            case .memoryStatus(let instance):
                // Like the traffic snapshot: answers only for an instance
                // that is already up, and never starts or wakes one. A
                // stopped instance has no balloon to report on, and the card
                // says so rather than showing stale figures.
                guard let vmManager = existingManager(for: instance), vmManager.isRunning,
                      let state = vmManager.balloonState() else {
                    respond(clientFD, ok: false, "no dynamic memory for this instance")
                    break
                }
                // One shared encoder with the client - see
                // `BalloonGovernor.State.wireLine`, which is tested against
                // its own decoder rather than each side guessing.
                respond(clientFD, ok: true, state.wireLine)
            case .sandboxGet(let instance):
                // Deliberately does NOT go through `manager(for:)`'s
                // start-if-needed path - see `startsInstance`. A stopped
                // instance answers from the persisted policy, which is the
                // truthful answer: those are the gates its next boot gets.
                let policy = await sandboxPolicy(for: instance)
                respond(clientFD, ok: true, policy.wireToken)
            case .sandboxSet(let instance, let token):
                guard let requested = SandboxPolicy.fromWireToken(token) else {
                    respond(clientFD, ok: false, "malformed sandbox policy token")
                    break
                }
                let applied = await setSandboxPolicy(requested, for: instance)
                // Answer with what the devices report, not with what was
                // asked for. They can differ - a network attachment can
                // drop on its own - and a UI that echoes the request would
                // show a lie in exactly the case worth knowing about.
                respond(clientFD, ok: true, applied.wireToken)
            case .startCageView(let instance):
                let vmManager = try manager(for: instance)
                try await ensureRunningWithinCap(vmManager, instance: instance)
                try await vmManager.startCageView()
                respond(clientFD, ok: true, "cage view started for \(instance)")
            }
        } catch {
            respond(clientFD, ok: false, "\(error)")
        }
    }

    /// The gates for `instance`, from its running VM if there is one and
    /// from the persisted policy if there is not.
    private func sandboxPolicy(for instance: String) async -> SandboxPolicy {
        guard let vmManager = existingManager(for: instance) else {
            return SandboxPolicyStore.load(instance: instance)
        }
        return await vmManager.observedSandboxPolicy()
    }

    /// Applies and persists. A stopped instance persists only - which is
    /// the point of persisting: the gates are waiting for its next start.
    private func setSandboxPolicy(_ policy: SandboxPolicy, for instance: String) async -> SandboxPolicy {
        guard let vmManager = existingManager(for: instance) else {
            SandboxPolicyStore.save(policy, instance: instance)
            X11InputGate.shared.setFrozen(policy.inputFrozen, instance: instance)
            return policy
        }
        return await vmManager.setSandboxPolicy(policy)
    }

    /// Told apart from any other failure by `MSLApp`, so it can explain that
    /// the image predates `trafficd` instead of showing an empty list.
    static let trafficUnavailableMarker = DaemonServerMarkers.trafficUnavailable

    /// Says what MSLAP is doing, once, the first time a request arrives.
    ///
    /// A tampered or unreadable policy would otherwise be visible only to
    /// whoever runs `msl admin status`. The administrator who needs to
    /// know is usually not sitting at the machine, so it goes in the log
    /// where they will actually find it.
    nonisolated(unsafe) private static var loggedPolicyState = false
    private static func logPolicyStateOnce(_ state: MSLAPPolicyStore.Result) {
        guard !loggedPolicyState else { return }
        loggedPolicyState = true
        switch state {
        case .unmanaged:
            MSLLog.line("mslap", "no policy installed - nothing restricted")
        case .managed(let loaded):
            // Counted across every SCOPE, not just the app-wide view: a
            // policy whose rules all name instances would otherwise log
            // "0 denied" while denying plenty, which is exactly the line
            // an administrator would read to confirm it had taken effect.
            let rules = Set(loaded.policy.scopes.flatMap { $0.deny }).count
            let scopes = loaded.policy.scopes.count
            MSLLog.line("mslap", "policy in force from \(loaded.url.path) "
                        + "(\(loaded.strength.title), \(rules) denial"
                        + (rules == 1 ? "" : "s") + " across \(scopes) scope"
                        + (scopes == 1 ? "" : "s")
                        + (loaded.signedBy.map { ", signed by \($0)" } ?? ", unsigned") + ")")
        case .broken(let failure, let fallback):
            MSLLog.line("mslap", "POLICY NOT IN FORCE: \(failure)")
            if fallback != nil {
                MSLLog.line("mslap", "still enforcing the last policy that verified")
            } else {
                MSLLog.line("mslap", "and no previously verified policy to fall back to")
            }
        }
        if !MSLAPKeyStore.storeIsProtected() {
            // Loud, because every signature check silently fails when this
            // is true.
            MSLLog.line("mslap", "WARNING: \(MSLAPKeyStore.directory.path) is not protected - "
                        + "pinned keys are being ignored and signed policies will not verify")
            // **And on a Mac that is actually enrolled, this is fatal.**
            // Every signature check fails closed, so the administrator's
            // rules have stopped applying while MSL carries on looking
            // normal - which is the worst way for a managed Mac to fail.
            // A warning in a log nobody reads is not enough for that.
            //
            // Only when a policy is installed where the person cannot have
            // written it. An unmanaged Mac with odd permissions on a shared
            // folder is untidy, not dangerous, and keeps the warning.
            if FileManager.default.fileExists(atPath: MSLAPPolicyStore.systemURL.path) {
                MSLLog.line("mslap", "FATAL: this Mac is enrolled and the key store is writable "
                            + "by other accounts - signed policies cannot verify")
                CrashScreen.stop(.keyStoreUnprotected,
                                 detail: "\(MSLAPKeyStore.directory.path) is group- or "
                                       + "world-writable while \(MSLAPPolicyStore.systemURL.path) "
                                       + "is enrolled")
            }
        }
    }

    private func respond(_ clientFD: Int32, ok: Bool, _ message: String) {
        let data = DaemonProtocol.encodeTextResponse(ok: ok, message: message)
        _ = data.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
    }

    /// Reattach to a session already running in the guest, on the vsock
    /// port it reported when it was created (`ShellProtocol.FrameType
    /// .session`).
    ///
    /// Deliberately **does not start the instance**. A reattach only means
    /// anything if the guest is up, and starting it here would resume an
    /// instance somebody had just hibernated - the opposite of what they
    /// asked for. The client waits for the instance to come back by some
    /// other route and reattaches then.
    ///
    /// Not counted as a session start either: the session is already
    /// counted from when it was created, and counting the reattach as well
    /// would hold the instance against the idle timer twice.
    private func handleAttach(instance: String, port: UInt32, clientFD: Int32) async throws {
        guard let vmManager = peekManager(for: instance),
              vmManager.currentState() == .running else {
            var status = DaemonProtocol.statusError
            _ = withUnsafePointer(to: &status) { write(clientFD, $0, 1) }
            let reason = "\(instance) isn't running"
            _ = reason.withCString { write(clientFD, $0, strlen($0)) }
            return
        }
        let connectFD: Int32
        do {
            connectFD = try await vmManager.openShellConnection(port: port)
        } catch {
            var status = DaemonProtocol.statusError
            _ = withUnsafePointer(to: &status) { write(clientFD, $0, 1) }
            let reason = "\(error)"
            _ = reason.withCString { write(clientFD, $0, strlen($0)) }
            return
        }
        var status = DaemonProtocol.statusOK
        _ = withUnsafePointer(to: &status) { write(clientFD, $0, 1) }
        try? FileDescriptorPassing.send(fileDescriptor: connectFD, over: clientFD)
        // Same lifetime rule as `handleSession`, and for the same reason:
        // Virtualization.framework ties this connection's real lifetime to
        // "any close tears it down", so releasing before the client has
        // taken the fd kills it under them. Waiting for their EOF is the
        // synchronisation point; the timeout stops a crashed client leaking
        // the slot forever.
        var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 5000)
        vmManager.releaseConnection(fd: connectFD)
    }

    private func handleSession(instance: String, distro: GuestDistro, clientFD: Int32) async throws {
        let vmManager = try manager(for: instance, distro: distro)

        // Counted before the VM is touched, not once the connection exists.
        // Counted after, a session arriving just as the previous one's idle
        // suspend fired passed `ensureRunning` on a running VM, was paused
        // under it, and its vsock connect never completed - the 4 s timeout
        // then abandoned the whole VM. Reproduced every time at exactly 3 s
        // after a session ended (2026-09-14). The suspend re-checks this
        // count under `sessionsLock` before pausing.
        sessionStarted(instance)

        let connectFD: Int32
        do {
            // Through the cap like every other start path. This one is the
            // one that matters most: `msl <name>` from a terminal is how
            // instances actually get started, so a cap that covered only
            // the GUI's buttons would be decorative.
            try await ensureRunningWithinCap(vmManager, instance: instance)
            connectFD = try await vmManager.openShellConnection()
        } catch {
            // No session reached the client, so no `.sessionEnded` will come.
            sessionEnded(instance)
            var status = DaemonProtocol.statusError
            _ = withUnsafePointer(to: &status) { write(clientFD, $0, 1) }
            let reason = "\(error)"
            _ = reason.withCString { write(clientFD, $0, strlen($0)) }
            return
        }

        // Already counted above; `sessionEnded` (sent once the client's relay
        // loop finishes) balances that `+1`.
        var status = DaemonProtocol.statusOK
        _ = withUnsafePointer(to: &status) { write(clientFD, $0, 1) }

        do {
            try FileDescriptorPassing.send(fileDescriptor: connectFD, over: clientFD)
        } catch {
            // best effort - client just sees a closed connection and bails
        }

        // Do NOT release right after the SCM_RIGHTS send returns. Ordinary
        // POSIX fd-passing semantics would make that safe - a successful
        // sendmsg() already means the kernel holds its own independent
        // reference to the passed fd, so the sender closing its copy right
        // after shouldn't affect a receiver that hasn't called recvmsg()
        // yet. But `VZVirtioSocketConnection` doesn't behave like an
        // ordinary fd here: confirmed live that releasing immediately can
        // tear down the underlying vsock connection out from under a
        // concurrent second session before its client ever gets to use the
        // fd it just received (surfaced as `noDescriptorReceived`/a silent
        // "connection closed unexpectedly" on the client, reliably
        // reproducible with two near-simultaneous sessions against the same
        // instance, gone once release was delayed) - Virtualization.
        // framework apparently ties this resource's real lifetime to
        // "any close tears it down," not to standard fd-table refcounting.
        // The client closes `clientFD` immediately after a successful
        // receive (see `runShellSession`'s "control channel's job is done"
        // comment) - waiting for that EOF is the correct synchronization
        // point, not an arbitrary delay. Bounded by a generous timeout so a
        // client that crashes before ever closing its end can't leak this
        // instance's connection slot forever.
        var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 5000)

        // VMManager owns connectFD's underlying VZVirtioSocketConnection and
        // closes it when its reference is dropped - never close(connectFD)
        // directly here, that would race the connection object's own close
        // and risk closing an unrelated fd number reused in the meantime.
        vmManager.releaseConnection(fd: connectFD)
    }

    /// Unregisters `instance` and cleans up everything `VMManager` owns for
    /// it (stops the VM if running, deletes its snapshot/machineid files -
    /// see `VMManager.removeAllPersistedState`). Never touches the
    /// underlying distro disk image, which is shared across every instance
    /// of that distro, not owned by this one. Works whether or not this
    /// daemon session has ever touched `instance` before - a registered-
    /// but-never-started instance still gets a throwaway `VMManager` built
    /// just long enough to clear its on-disk state.
    /// One line per registered instance, `name\tdistro\tstate\tinstalled`,
    /// behind a `#\t<used>\t<cap>` header. Tab-separated rather than JSON
    /// only because every other response on this socket is a plain line and
    /// `respond` already handles multi-line bodies.
    ///
    /// `installed` is whether this instance can actually start: it either
    /// already has its own disk, or its distro has a downloaded base to
    /// clone one from on first boot (`InstanceDisk`). Both count - an
    /// instance that has never been booted has no disk of its own yet and
    /// must still offer "start", while an instance whose distro's base was
    /// deleted keeps working on the disk it already has.
    private func instanceDetailsBody() -> String {
        let usage = runSlotUsage()
        var lines = ["#\t\(usage.used)\t\(usage.cap)"]
        for (name, distro) in registry.entries().sorted(by: { $0.key < $1.key }) {
            let state = peekManager(for: name)?.currentState() ?? .stopped
            let imagePath = makeConfiguration(name, distro).diskImagePath ?? ""
            let hasOwnDisk = !imagePath.isEmpty && FileManager.default.fileExists(atPath: imagePath)
            let canBeCloned = distro.isCustom
                ? FileManager.default.fileExists(atPath: distro.baseImageURL().path)
                : distro.baseIsInstalled()
            let installed = (hasOwnDisk || canBeCloned) ? "1" : "0"
            // Field 5 is the host path of the guest's filesystem mount, or
            // empty when the instance isn't running (the mount only exists
            // while it is). Appended rather than inserted so older clients,
            // which read exactly four fields, keep working.
            let mount = peekManager(for: name)?.sandboxMountPath ?? ""
            lines.append("\(name)\t\(distro.rawValue)\t\(state.rawValue)\t\(installed)\t\(mount)")
        }
        return lines.joined(separator: "\n")
    }

    /// Removing an instance deletes **its own** disk, and leaves the distro's
    /// downloaded base alone so the next instance of it costs no download.
    ///
    /// That is the whole shape of it since instances stopped sharing one
    /// image (`InstanceDisk`). It used to be the other way round: the disk
    /// belonged to the distro, so it could only be deleted once the last
    /// instance went, and until then removing instances freed nothing.
    /// `--keep-disk` still keeps the disk, for someone who wants to
    /// re-register the same instance later.

    /// Reads the guest's provenance marker and acts on what it says.
    ///
    /// Shut down with `stopAfterGuestShutdown`, **never a hard stop**: the
    /// disk may be somebody's real work, and the point is that it is not
    /// the disk MSL recorded - not that it deserves damaging. A hard stop
    /// risks the filesystem, which would turn a provenance finding into
    /// data loss.
    private func checkGuestWitness(instance: String, manager: VMManager) async {
        let hostToken = InstanceIdentityStore.rawToken(for: instance)
        guard hostToken != nil else { return }

        let read = await manager.runInternalCommand(
            GuestIdentityWitness.readCommand, timeout: 20, user: "root")
        guard read.exitCode == 0 else { return }

        let finding = GuestIdentityWitness.compare(
            hostToken: hostToken,
            guestContents: read.output,
            everWritten: InstanceIdentityStore.hasBeenWitnessed(instance))

        switch GuestIdentityWitness.action(for: finding, instance: instance,
                                           managed: MSLAPGate.policy != nil) {
        case .nothing:
            break

        case .write:
            guard let token = hostToken,
                  let command = GuestIdentityWitness.writeCommand(token: token) else { return }
            let wrote = await manager.runInternalCommand(command, timeout: 20, user: "root")
            if wrote.exitCode == 0 {
                InstanceIdentityStore.markWitnessed(instance)
            } else {
                // A read-only root, or a distro doing something unusual.
                // Logged and left: a marker that could not be written must
                // never stop an instance working.
                MSLLog.line("identity",
                            "\(instance): could not write the provenance marker - \(wrote.output)")
            }

        case .report(let detail):
            MSLLog.line("identity", detail)
            ActivityLog.shared.record(.lifecycle, instance: instance,
                                      "Provenance marker problem", detail: detail)

        case .stop(let detail):
            MSLLog.line("identity", detail)
            ActivityLog.shared.record(.lifecycle, instance: instance,
                                      "Stopped: the disk is not the one recorded", detail: detail)
            try? await manager.stopAfterGuestShutdown()
        }
    }

    /// Moves an instance's disk into an encrypted container, or back out.
    ///
    /// **Takes the maintenance slot.** Gigabytes are about to be copied
    /// and the image must not be opened by anything else while that
    /// happens - which is exactly what that slot is for.
    private func handleProtect(_ instance: String, enable: Bool,
                               clientFD: Int32) async throws {
        guard registry.distro(for: instance) != nil else {
            respond(clientFD, ok: false, "no such instance '\(instance)'")
            return
        }
        guard case .valid(let identity) = InstanceIdentityStore.verdict(for: instance) else {
            respond(clientFD, ok: false,
                    "\(instance) has no verified identity, and the container's key is derived "
                    + "from it - `msl identity \(instance)` says why.")
            return
        }
        let manager = existingManager(for: instance)
        guard manager.map({ $0.currentState() == .stopped }) ?? true else {
            respond(clientFD, ok: false,
                    "\(instance) is running - stop it first. Its whole disk is about to be copied.")
            return
        }
        guard !VMManager.hasSavedState(instance: instance) else {
            // Saved memory lives beside the disk and would be left behind
            // on the wrong side of the boundary.
            respond(clientFD, ok: false,
                    "\(instance) has hibernated memory, which would be left outside the container. "
                    + "Start it once to use that up, then try again.")
            return
        }
        guard (try? reserveMaintenanceSlot(for: instance, enforceCap: false)) == true else {
            respond(clientFD, ok: false,
                    "\(instance) is starting or under maintenance - try again when that finishes")
            return
        }
        defer { releaseMaintenanceSlot(for: instance) }

        let plainPath = InstanceDisk.url(instance: instance).path
        do {
            if enable {
                guard !InstanceVault.exists(serial: identity.serial) else {
                    respond(clientFD, ok: true, "\(instance) is already in a container")
                    return
                }
                try InstanceVault.moveIn(instance: instance, identity: identity,
                                          diskPath: plainPath) { update in
                    MSLLog.line("vault", "\(instance): \(update.description)")
                }
                respond(clientFD, ok: true,
                        "\(instance)'s disk is now inside an encrypted container. A copy of the "
                        + "file is useless without this Mac - and what is inside it is still "
                        + "readable by anyone who can open a shell in the instance.")
            } else {
                try InstanceVault.moveOut(instance: instance, identity: identity,
                                           diskPath: plainPath) { update in
                    MSLLog.line("vault", "\(instance): \(update.description)")
                }
                respond(clientFD, ok: true,
                        "\(instance)'s disk is back out of its container, as a plain file.")
            }
        } catch {
            respond(clientFD, ok: false, "\(error)")
        }
    }

    /// Supplies, sets or forgets an administrator-held container key.
    ///
    /// **Nothing here logs the passphrase**, and the unwrapped key lives
    /// only in `InstanceVault`'s in-memory table - writing one down would
    /// turn admin-held mode back into at-rest mode with extra steps, which
    /// is the entire difference between the two rungs.
    private func handleVaultKey(_ instance: String, action: String, passphrase: String,
                                clientFD: Int32) {
        guard registry.distro(for: instance) != nil else {
            respond(clientFD, ok: false, "no such instance '\(instance)'")
            return
        }
        guard case .valid(let identity) = InstanceIdentityStore.verdict(for: instance) else {
            respond(clientFD, ok: false,
                    "\(instance) has no verified identity, so MSL cannot tell which container "
                    + "is its - `msl identity \(instance)` says why.")
            return
        }
        guard InstanceVault.exists(serial: identity.serial) else {
            respond(clientFD, ok: false,
                    "\(instance)'s disk is not in a container - `msl protect \(instance)` puts it "
                    + "in one first.")
            return
        }
        switch action {
        case "status":
            // **Answered by the daemon, not the CLI.** The unwrapped key
            // lives in THIS process's memory and nowhere else, so a CLI
            // that checked its own table reported "LOCKED" for a container
            // the daemon had open - which is how this was found.
            let mode = InstanceVault.keyMode(serial: identity.serial)
            respond(clientFD, ok: true,
                    "\(mode.rawValue)\t\(InstanceVault.isUnlocked(serial: identity.serial) ? 1 : 0)")

        case "lock":
            InstanceVault.lock(serial: identity.serial)
            // Closed as well as forgotten: leaving it attached would mean
            // the decrypted contents stayed reachable after somebody
            // deliberately locked it, which is the opposite of what they
            // asked for.
            try? InstanceVault.detach(identity)
            respond(clientFD, ok: true,
                    "\(instance)'s key is forgotten and its container is closed. It needs the "
                    + "passphrase again before it can start.")

        case "unlock":
            guard InstanceVault.keyMode(serial: identity.serial) == .adminHeld else {
                respond(clientFD, ok: true,
                        "\(instance)'s container uses this Mac's own key - there is nothing to "
                        + "unlock.")
                return
            }
            guard InstanceVault.unlock(serial: identity.serial, adminPassphrase: passphrase) else {
                respond(clientFD, ok: false, "that passphrase does not open \(instance)'s container")
                return
            }
            respond(clientFD, ok: true,
                    "\(instance) is unlocked until mslhd next restarts - a reboot will ask again, "
                    + "because the key is never written down.")

        case "adopt":
            guard !passphrase.isEmpty else {
                respond(clientFD, ok: false, "an empty passphrase protects nothing")
                return
            }
            do {
                try InstanceVault.useAdminHeldKey(for: identity, adminPassphrase: passphrase)
                respond(clientFD, ok: true,
                        "\(instance)'s container now needs that passphrase. Nothing on this Mac "
                        + "can open it without someone typing it - including MSL after a reboot. "
                        + "There is no recovery if it is lost.")
            } catch {
                respond(clientFD, ok: false, "\(error)")
            }

        default:
            respond(clientFD, ok: false, "unknown key action '\(action)'")
        }
    }

    // MARK: - Port forwarding

    private func handleForwardAdd(_ instance: String, hostPort: UInt16, guestPort: UInt16,
                                  viaSSH: Bool, clientFD: Int32) {
        guard registry.distro(for: instance) != nil else {
            respond(clientFD, ok: false, "no such instance '\(instance)'")
            return
        }
        var notes: [String] = []
        let forward = PortForward(instance: instance, hostPort: hostPort,
                                  guestPort: guestPort, route: viaSSH ? .viaSSH : .direct)
        do {
            // The log closure collects rather than prints, so the one thing
            // worth knowing - that nothing is listening on the guest side
            // yet - reaches the person who typed the command instead of
            // only mslhd's log.
            try ForwardManager.shared.add(forward) { notes.append($0) }
        } catch {
            respond(clientFD, ok: false, "\(error)")
            return
        }
        respond(clientFD, ok: true, ([forward.description] + notes).joined(separator: "\n"))
    }

    /// One forward per line: `<hostPort>\t<guestPort>\t<route>\t<live 0|1>`.
    ///
    /// `live` is separate from being recorded on purpose. A forward whose
    /// listener died is the "looks fine and is not" state, and a list that
    /// could not tell the two apart would be the thing that hides it.
    private func forwardListBody(_ instance: String) -> String {
        let live = ForwardManager.shared.liveHostPorts()
        return PortForwardStore.forInstance(instance).map { forward in
            "\(forward.hostPort)\t\(forward.guestPort)\t\(forward.route.rawValue)"
                + "\t\(live.contains(forward.hostPort) ? 1 : 0)"
        }.joined(separator: "\n")
    }

    /// Hands `ForwardManager` what it needs, the same way
    /// `configurePublicMSL` does - injected so the path is testable with no
    /// VM anywhere near it.
    private func configureForwarding() {
        ForwardManager.shared.configure(host: .init(
            guestAddress: { [weak self] name in
                guard let manager = self?.existingManager(for: name), manager.isRunning else { return nil }
                return SSHSetup.RecordStore.load(instance: name)?.host
                    ?? runBlockingOnDaemon { await manager.runInternalCommand("hostname -I", timeout: 15) }
                        .output.split(separator: " ").first.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
            },
            isRunning: { [weak self] name in
                self?.existingManager(for: name)?.isRunning ?? false
            },
            start: { [weak self] name in
                guard let self else { return false }
                return runBlockingOnDaemon {
                    do {
                        let vmManager = try await self.manager(for: name)
                        try await self.ensureRunningWithinCap(vmManager, instance: name)
                        return true
                    } catch { return false }
                }
            }))
    }

    /// Renaming and cloning, which are one operation with one flag.
    ///
    /// **Written as one function on purpose.** They share every
    /// precondition that matters - not running, not busy, a usable and
    /// unused name, and above all not escaping an MSLAP scope - and the
    /// bug waiting in two implementations is that a check gets added to one
    /// of them. `InstanceRename` holds the preconditions and
    /// `InstanceStateTransfer` the inventory of state, so this function is
    /// just the part only the daemon can do: knowing what is running,
    /// owning the maintenance slot, and holding the `VMManager` whose files
    /// move.
    private func handleRenameOrClone(_ old: String, to new: String,
                                     mode: InstanceStateTransfer.Mode,
                                     clientFD: Int32) async throws {
        let verb = mode == .move ? "rename" : "clone"
        let manager = existingManager(for: old)
        let situation = InstanceRename.Situation(
            exists: registry.distro(for: old) != nil,
            targetExists: registry.distro(for: new) != nil
                // A name with no registry entry but a disk still on disk is
                // taken: `msl remove --keep-disk` leaves exactly that, and
                // reusing the name would quietly adopt somebody else's
                // filesystem.
                || InstanceDisk.exists(instance: new),
            isRunning: manager.map { $0.currentState() != .stopped } ?? false,
            isBusy: !startingOrUnderMaintenance([old]).isEmpty,
            hasSavedState: manager?.hasSavedState() ?? VMManager.hasSavedState(instance: old),
            snapshots: manager?.snapshotList() ?? VMManager.snapshotNames(instance: old),
            instanceCount: registry.list().count,
            policy: MSLAPGate.policy)

        let blocker = mode == .move
            ? InstanceRename.renameBlocker(from: old, to: new, situation: situation)
            : InstanceRename.cloneBlocker(from: old, to: new, situation: situation)
        if let blocker {
            respond(clientFD, ok: false, "\(blocker)")
            return
        }
        guard let distro = registry.distro(for: old) else {
            respond(clientFD, ok: false, "no such instance '\(old)'")
            return
        }

        // The maintenance slot, for the same reason a repair takes it: the
        // files are about to move, and nothing else may open them while
        // they do. Taken for the SOURCE, which is the name anything else
        // would ask about.
        // `enforceCap: false` - no guest memory is involved, this is all
        // host-side file movement.
        guard (try? reserveMaintenanceSlot(for: old, enforceCap: false)) == true else {
            respond(clientFD, ok: false, "\(old) is starting or under maintenance - try again when that finishes")
            return
        }
        defer { releaseMaintenanceSlot(for: old) }

        // The instance's own disk has to exist before anything is moved.
        // An instance registered but never started has none yet, and a
        // clone of nothing is not a copy of a working setup - it is a
        // confusing empty instance with somebody else's settings.
        do {
            try InstanceDisk.ensure(instance: old, distro: distro)
        } catch {
            respond(clientFD, ok: false, "\(old) has no disk yet (\(error)) - start it once first")
            return
        }

        // Dropped BEFORE the move, not after: a `VMManager` holds paths
        // built from the old name, and one left in the table would go on
        // writing to files that are not there any more.
        if mode == .move { _ = takeManager(for: old) }

        let touched: [String]
        do {
            touched = try InstanceStateTransfer.apply(mode, from: old, to: new)
        } catch {
            respond(clientFD, ok: false, "couldn't \(verb) \(old): \(error)")
            return
        }

        // **Both names, both modes.** `InstanceStateTransfer` clears the
        // record file, but the `~/.ssh/config` BLOCK is a separate thing
        // that `SSHSetup.forget` owns - and a block naming the old alias
        // and the old address would otherwise sit there being wrong. For a
        // clone the new name has no block yet, so clearing it is a no-op
        // that costs nothing and guards against a reused name.
        SSHSetup.forget(instance: new)
        if mode == .move { SSHSetup.forget(instance: old) }

        // Identity. A rename re-signs the one that moved with the
        // inventory; a clone is ISSUED one deriving from its parent, which
        // keeps the lineage (so a policy about that lineage still catches
        // it) and gains a generation (so the depth says how far from the
        // original it is).
        //
        // Best-effort, deliberately: an instance with no identity reads as
        // `unidentified`, which the acceptance rules answer for. A failure
        // here must never be able to break renaming or cloning.
        if mode == .move {
            InstanceIdentityStore.reSign(for: new)
        } else {
            InstanceIdentityStore.issueCopy(of: old, to: new)
        }

        if mode == .move {
            // The app list and the generated `.app` bundles are DISCARDED
            // rather than moved. A bundle's launch command embeds the
            // instance name, so a moved one would launch an instance that
            // no longer exists - and per `msl_sessions_register_and_boot`,
            // doing so would REGISTER the old name again as a fresh,
            // empty instance. Rescanning is cheap; a resurrected ghost
            // instance is not.
            LinuxAppCatalog.forget(instance: old)
            clearActivity(old)
            // `last-used` is a pointer, not state: a stale value sends
            // plain `msl` to an instance that is gone.
            if registry.lastUsed() == old { registry.recordLastUsed(new) }
        }

        let what = touched.isEmpty ? "its registration" : touched.joined(separator: ", ")
        respond(clientFD, ok: true, mode == .move
            ? "renamed \(old) to \(new) (\(what))"
            : "cloned \(old) to \(new) (\(what))")
    }

    private func handleRemove(instance: String, keepDisk: Bool, clientFD: Int32) async throws {
        guard registry.distro(for: instance) != nil else {
            respond(clientFD, ok: false, "no such instance '\(instance)'")
            return
        }
        guard startingOrUnderMaintenance([instance]).isEmpty else {
            respond(clientFD, ok: false, "\(instance) is starting or under maintenance - try again when that finishes")
            return
        }
        try await removeInstanceState(instance)
        guard !keepDisk else {
            respond(clientFD, ok: true, "removed \(instance), keeping its disk")
            return
        }
        // This instance's own disk, and the account that lived on it.
        let freed = DiskStorage.allocatedSize(of: InstanceDisk.url(instance: instance).path)
        InstanceDisk.remove(instance: instance)
        try? LinuxUserSetup.registry().forgetDefaultUser(forInstance: instance)
        guard freed > 0 else {
            respond(clientFD, ok: true, "removed \(instance)")
            return
        }
        respond(clientFD, ok: true,
                "removed \(instance) and deleted its disk, freeing \(DiskStorage.format(freed))")
    }

    /// Synchronous so the lock is never held across an `await`.
    private func startingOrUnderMaintenance(_ instances: [String]) -> [String] {
        managersLock.lock()
        defer { managersLock.unlock() }
        return instances.filter { maintenanceInstances.contains($0) || startingInstances.contains($0) }
    }

    /// Everything removing one instance does - shared by `REMOVE` and
    /// `REMOVE_DISTRO`, so the two can never drift apart.
    private func removeInstanceState(_ instance: String) async throws {
        // Forwards go with the instance. A listener left pointing at a
        // deleted instance would accept connections and reset every one.
        ForwardManager.shared.stopAll(instance: instance, forget: true)
        let manager = takeManager(for: instance) ?? VMManager(configuration: makeConfiguration(instance, registry.distro(for: instance) ?? .alpine))
        try await manager.removeAllPersistedState()
        try registry.remove(instance)
        clearActivity(instance)
        // The SSH record and `~/.ssh/config` block go with the instance.
        // Here rather than in MSLApp so `msl remove` gets it too.
        SSHSetup.forget(instance: instance)
        // Its CPU and memory choices too - a new instance given the same name
        // used to inherit them silently.
        ResourcePolicyStore.forget(instance: instance)
        // And its scanned applications. A new instance reusing the name
        // inherited the old one's app list: an Alpine instance was deleted
        // and a Debian one created in its place, and MSL went on offering
        // the Alpine apps - including Flatpaks that were not installed any
        // more, which failed with "not installed" when clicked (2026-09-22).
        LinuxAppCatalog.forget(instance: instance)
        // The badge its owner picked (`InstanceAppearance`) and any
        // per-instance experimental overrides a shipment left behind
        // (`InstanceExperiments`). Same rule as the app list above: a new
        // instance reusing a deleted one's name inherited both.
        InstanceAppearanceStore.forget(instance: instance)
        InstanceExperiments.forget(instance: instance)
        // And the list of apps to reopen, or a new instance reusing the
        // name would come up launching somebody else's.
        AppSessionRestore.forget(instance: instance)
        // Everything above is a store somebody remembered to add after it
        // caused a bug. This covers the rest by inventory, so the next one
        // does not need remembering - and it closes five that were already
        // leaking: the instance lock, the camera and microphone
        // permissions, the per-app graphics modes, the sandbox gates and
        // the custom launch commands. See `InstanceStateTransfer.forget`
        // for why the launch commands are the serious one.
        InstanceStateTransfer.forget(instance: instance)
    }

    /// Deletes a whole distro installation: every instance of it, then the
    /// disk they share. The only way to actually free a distro's disk -
    /// removing instances one at a time never touches it.
    ///
    /// Refused while any of its instances is starting or under maintenance: a
    /// repair or a boot owns the image, and deleting it underneath either is
    /// exactly the kind of damage the maintenance slot exists to prevent.
    private func handleRemoveDistro(_ distro: GuestDistro, clientFD: Int32) async throws {
        let instances = registry.entries().filter { $0.value == distro }.map(\.key).sorted()
        let busy = startingOrUnderMaintenance(instances)
        guard busy.isEmpty else {
            respond(clientFD, ok: false, "\(busy.joined(separator: ", ")) is starting or under maintenance - try again when that finishes")
            return
        }
        for instance in instances {
            try await removeInstanceState(instance)
        }
        // The instances were just unregistered, so their disks have to be
        // named explicitly - `deleteFiles` has nothing left to look them up
        // with.
        let freed = DistroInstallation.deleteFiles(for: distro, instanceDisks: instances)
        if let slug = distro.customSlug {
            respond(clientFD, ok: true,
                    "removed \(instances.count) \(distro.rawValue) instance(s) - its files in Custom Images/\(slug) are untouched")
            return
        }
        respond(clientFD, ok: true,
                "removed \(instances.count) \(distro.rawValue) instance(s) and deleted the \(distro.rawValue) disk, freeing \(DiskStorage.format(freed))")
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.managersLock.lock()
            let snapshot = self.managers
            self.managersLock.unlock()
            let activity = self.activitySnapshot()
            for (name, manager) in snapshot {
                // An instance that is already down is not idle, it is
                // *finished*. Without this the timer kept picking the same
                // hibernated instances up every 30 seconds - the log read
                // "idle too long - asking its apps to close" followed by
                // "hibernating" over and over for the same names - and each
                // pass asked the Mac's Linux apps to close again. Paused is
                // deliberately not excluded: MSL suspends an idle guest
                // within seconds of the last session closing, so a paused
                // instance is the normal thing to hibernate, and skipping it
                // would disable the idle timer altogether.
                if manager.currentState() == .stopped { continue }
                let last = activity[name] ?? .distantPast
                if Date().timeIntervalSince(last) > self.idleTimeout {
                    // An open `msl` session is not idle either. This checked
                    // only the time since the last daemon request, and a
                    // session sends none while it runs - so every Linux app
                    // started with `msl gui-native` (and every long shell)
                    // had its VM hibernated underneath it five minutes in:
                    // "shell connection closed unexpectedly", window gone
                    // (2026-09-14, gtk3-widget-factory, twice).
                    if self.hasActiveSessions(name) {
                        self.recordActivity(name)
                        continue
                    }
                    // A guest holding a USB device is not idle. Hibernating
                    // it releases the device back to macOS, so the person
                    // who plugged something in and walked away would find it
                    // gone - and `vhci_hcd` would be holding a dead port.
                    if manager.hasUSBAttachments {
                        self.recordActivity(name)
                        continue
                    }
                    Task { [weak self] in
                        // Someone connected over SSH is not idle, however long
                        // it's been since the last `msl` command - see
                        // `SSHActivity`. Counted as activity so the check
                        // comes round again a full timeout later, not every
                        // 30 seconds. If trafficd can't answer, hibernate as
                        // before rather than keep a guest up on a guess.
                        if manager.isRunning,
                           let sockets = try? await TrafficClient(manager: manager).sockets(attributeProcesses: false),
                           SSHActivity.hasLiveSessions(sockets) {
                            self?.recordActivity(name)
                            return
                        }
                        // A published instance stays up. Somebody
                        // reaching it from the internet arrives over the
                        // network, which is not a session and does not
                        // count as activity, so the idle timer would
                        // hibernate the very machine the tunnel points at -
                        // and the tunnel would keep looking healthy while
                        // every connection to it hung. Checked against the
                        // policy rather than the live tunnel, so a moment
                        // of re-establishing it does not open the window.
                        if PublicPolicyStore.load(instance: name)?.enabled == true {
                            self?.recordActivity(name)
                            return
                        }
                        // An automatic hibernate must never cost somebody
                        // unsaved work. If a Linux app will not close, the
                        // timer simply does not fire - the instance stays up
                        // and the check comes round again later.
                        if InstanceExperiments.effective(for: name).reopenAppsAfterHibernate {
                            MSLLog.line("idle", "\(name): idle too long - asking its apps "
                                        + "to close before hibernating")
                            let closed = AppSessionRestore.closeApps(
                                instance: name,
                                resolve: { appName in
                                    guard let candidate = AppSessionRestore.candidateCommand(for: appName)
                                    else { return nil }
                                    let found = runBlockingOnDaemon {
                                        await manager.runInternalCommand("command -v \(candidate)", timeout: 10)
                                    }
                                    return found.exitCode == 0 && !found.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? candidate : nil
                                })
                            guard closed.allClosed else {
                                AppSessionRestore.forget(instance: name)
                                self?.recordActivity(name)
                                return
                            }
                        }
                        MSLLog.line("idle", "\(name): hibernating")
                        try? await manager.hibernate()
                    }
                }
            }
        }
        timer.resume()
        idleTimer = timer
    }
}

enum DaemonServerError: Error {
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Runs an async call from a synchronous closure.
///
/// Needed because `AppSessionRestore.closeApps` is synchronous - it is a
/// poll loop - but resolving an app's command is an async guest round trip.
/// Kept to short, bounded calls for that reason.
func runBlockingOnDaemon<T>(_ work: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached { result = await work(); semaphore.signal() }
    semaphore.wait()
    return result!
}
