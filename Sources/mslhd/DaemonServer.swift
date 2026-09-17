import Foundation
import MSLCore
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
        case sharedDiskConflict(instance: String, other: String, distro: String)

        var description: String {
            switch self {
            case .atRunningCap(let running, let limit):
                return "\(limit) instances are already running (\(running.joined(separator: ", "))) - MSL runs at most \(limit) at once; suspend or shut one down first"
            case .sharedDiskConflict(let instance, let other, let distro):
                return "'\(other)' is already running and shares \(distro)'s disk with '\(instance)' - running both at once would corrupt it; stop '\(other)' first"
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

        // A distro's disk image is per-*distro*, not per-instance (see
        // `InstanceRegistry`'s doc comment): `msl work --distro debian` and
        // `msl personal --distro debian` are two instances backed by one
        // `rootfs-debian.img`. Sequentially that is fine; concurrently it
        // is two writers on one raw disk file, which is exactly as bad as
        // it sounds. Nothing enforced this before - the caveat was
        // documented and left to the caller, and a GUI that lists instances
        // as start buttons is precisely the caller who would trip over it.
        if let distro = registry.distro(for: instance) {
            for other in occupied where registry.distro(for: other) == distro {
                throw CapError.sharedDiskConflict(
                    instance: instance, other: other, distro: distro.rawValue)
            }
        }

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
    private func ensureRunningWithinCap(_ manager: VMManager, instance: String) async throws {
        try reserveRunSlot(for: instance)
        defer { releaseRunSlot(for: instance) }
        let wasRunning = manager.currentState() == .running
        try await manager.ensureRunning()
        // Only after a start that actually brought the guest up, and never
        // in the caller's way: extending the filesystem into space added
        // while the VM was stopped needs a running guest, and sampling how
        // full it is needs a mounted one. Detached so a slow `resize2fs` on
        // a large disk can't hold up the session the user asked for.
        if !wasRunning {
            // The clock first, and awaited: it's two quick round trips, and
            // whatever the user asked the guest to do next - a `curl`, a
            // `git pull`, a package install - needs the right time already.
            await manager.syncClockAfterStart()
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
            recordActivity(started)
            registry.recordLastUsed(started)
        }

        if let summary = request.monitorSummary {
            ActivityLog.shared.record(request.monitorCategory,
                                      instance: request.monitorInstance, summary)
        }

        do {
            switch request {
            case .session(let instance, _, _, let distro):
                try await handleSession(instance: instance, distro: distro, clientFD: clientFD)
            case .suspend(let instance):
                try await manager(for: instance).suspendLight()
                respond(clientFD, ok: true, "suspended \(instance)")
            case .resume(let instance):
                try await ensureRunningWithinCap(manager(for: instance), instance: instance)
                respond(clientFD, ok: true, "resumed \(instance)")
            case .hibernate(let instance):
                try await manager(for: instance).hibernate()
                respond(clientFD, ok: true, "hibernated \(instance)")
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
                let names = registry.list()
                let described = names.map { name in "\(name) (\(registry.distro(for: name)?.rawValue ?? "?"))" }
                respond(clientFD, ok: true, described.isEmpty ? "(none)" : described.joined(separator: ", "))
            case .createInstance(let instance, let distro):
                guard InstanceRegistry.isValidName(instance) else {
                    respond(clientFD, ok: false, "'\(instance)' isn't a usable instance name - letters, digits, - and _ only")
                    break
                }
                guard registry.distro(for: instance) == nil else {
                    respond(clientFD, ok: false, "instance '\(instance)' already exists")
                    break
                }
                _ = try registry.ensureRegistered(instance, distro: distro)
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
            case .removeDistro(let distro):
                try await handleRemoveDistro(distro, clientFD: clientFD)
            case .sessionEnded(let instance):
                // Fire-and-forget - the client doesn't wait for a response.
                sessionEnded(instance)
            case .shutdown(let instance):
                try await manager(for: instance).stopAfterGuestShutdown()
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

    private func respond(_ clientFD: Int32, ok: Bool, _ message: String) {
        let data = DaemonProtocol.encodeTextResponse(ok: ok, message: message)
        _ = data.withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
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
    /// `installed` is whether the distro's backing disk image exists yet -
    /// an instance can be registered without ever having been booted, and
    /// the UI must not offer "start" for one whose image was never
    /// downloaded.
    private func instanceDetailsBody() -> String {
        let usage = runSlotUsage()
        var lines = ["#\t\(usage.used)\t\(usage.cap)"]
        for (name, distro) in registry.entries().sorted(by: { $0.key < $1.key }) {
            let state = peekManager(for: name)?.currentState() ?? .stopped
            let imagePath = makeConfiguration(name, distro).diskImagePath ?? ""
            let installed = (!imagePath.isEmpty && FileManager.default.fileExists(atPath: imagePath)) ? "1" : "0"
            // Field 5 is the host path of the guest's filesystem mount, or
            // empty when the instance isn't running (the mount only exists
            // while it is). Appended rather than inserted so older clients,
            // which read exactly four fields, keep working.
            let mount = peekManager(for: name)?.sandboxMountPath ?? ""
            lines.append("\(name)\t\(distro.rawValue)\t\(state.rawValue)\t\(installed)\t\(mount)")
        }
        return lines.joined(separator: "\n")
    }

    /// Removing the last instance of a distro deletes the disk as well
    /// (unless asked to keep it): instances share the disk, so while others
    /// remain it has to stay, but once none do it is 64 GB nothing can reach.
    private func handleRemove(instance: String, keepDisk: Bool, clientFD: Int32) async throws {
        guard let distro = registry.distro(for: instance) else {
            respond(clientFD, ok: false, "no such instance '\(instance)'")
            return
        }
        guard startingOrUnderMaintenance([instance]).isEmpty else {
            respond(clientFD, ok: false, "\(instance) is starting or under maintenance - try again when that finishes")
            return
        }
        try await removeInstanceState(instance)
        let othersRemain = registry.entries().contains { $0.value == distro }
        // A custom image's files are the user's own and are never deleted.
        guard !keepDisk, !othersRemain, !distro.isCustom, DistroInstallation.isInstalled(distro) else {
            respond(clientFD, ok: true, "removed \(instance)")
            return
        }
        let freed = DistroInstallation.deleteFiles(for: distro)
        respond(clientFD, ok: true,
                "removed \(instance), the last \(distro.rawValue) instance, and deleted its disk, freeing \(DiskStorage.format(freed))")
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
        let freed = DistroInstallation.deleteFiles(for: distro)
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
