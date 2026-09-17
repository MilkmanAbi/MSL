import AppKit
import Foundation
import MSLCore
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
#if canImport(Darwin)
import Darwin
#endif

/// Keeps every running MSL guest safe across host power events: sleep, wake,
/// shutdown, restart, a critically low battery, and this process being sent
/// SIGTERM/SIGINT.
///
/// ## What actually protects a guest filesystem
///
/// Pausing. A paused VM cannot write to its disk image at all, and pausing
/// is near-instant with no I/O. Everything else here is either about
/// *resuming* later (saving state to disk) or about losing less recent work
/// (flushing the guest's page cache) - neither protects the filesystem, and
/// neither is allowed to delay the pause.
///
/// That is why a power event is handled in two distinct phases rather than
/// as one `hibernate()` per instance. `hibernate()` pauses *and* saves for
/// one instance at a time, so with four instances running, the fourth could
/// still be unpaused - still writing - while the first spends seconds
/// writing gigabytes of RAM to disk. Here every instance is paused first,
/// under a short deadline, and only then does the remaining budget go on
/// saves. Whatever a deadline cuts off, the guests are already frozen.
///
/// Losing the save phase costs only "resume exactly where I left off": the
/// instance cold-boots next time, which `ensureRunning()` already handles as
/// routine. An ext4 that stops mid-transaction replays its journal on the
/// next mount, exactly as it would after a real machine lost power.
///
/// ## Why both signals and IOKit
///
/// Logout tears down a user's processes with signals and never sends the
/// IOKit power notifications; sleep and shutdown go through IOKit and may
/// send no signal at all. Which one arrives, and in what order, is not
/// something to bet a filesystem on, so both paths run the same serialized
/// handler and the second one to arrive finds nothing left to do.
// `<IOKit/IOMessage.h>`'s constants are built by a C macro
// (`iokit_common_msg`, itself bit-packing `err_system`/`err_sub`) that
// Swift's Clang importer refuses to import - confirmed at build time, not a
// guess. Redefined here from the SDK header's own hex literals OR'd into
// `iokit_common_msg`'s fixed `0xE0000000` prefix, and re-read out of
// `IOMessage.h` rather than trusted from memory.
private let msgCanSystemSleep: UInt32 = 0xE000_0270     // iokit_common_msg(0x270)
private let msgCanSystemPowerOff: UInt32 = 0xE000_0240  // iokit_common_msg(0x240)
private let msgSystemWillSleep: UInt32 = 0xE000_0280    // iokit_common_msg(0x280)
private let msgSystemWillPowerOff: UInt32 = 0xE000_0250 // iokit_common_msg(0x250)
private let msgSystemWillRestart: UInt32 = 0xE000_0310  // iokit_common_msg(0x310)
private let msgSystemHasPoweredOn: UInt32 = 0xE000_0300 // iokit_common_msg(0x300)

final class SystemResilienceMonitor {

    /// What a power event asks of every running instance.
    enum Response {
        /// Freeze, and leave the process resident. For sleep: this process
        /// survives, so there is nothing to persist and every reason to be
        /// quick.
        case pauseOnly
        /// Freeze, then save to disk and stop. For anything this process
        /// will not survive - shutdown, restart, logout, a dying battery.
        case pauseAndSave

        var label: String {
            switch self {
            case .pauseOnly: return "suspending"
            case .pauseAndSave: return "hibernating"
            }
        }
    }

    private let managersSnapshot: () -> [VMManager]
    /// Called once, at the start of any power response, before anything is
    /// touched. Lets the daemon stand down its own idle auto-suspend so it
    /// cannot pause a manager this monitor is in the middle of saving.
    var powerTransitionBegan: (() -> Void)?
    /// Called after the host wakes, so the daemon can drop bookkeeping that
    /// did not survive sleep.
    private let hostDidWake: () -> Void

    private var notifyPort: IONotificationPortRef?
    private var powerConnection: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var powerSourceSource: CFRunLoopSource?

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    /// Serializes power responses so two events - a SIGTERM arriving during
    /// a shutdown notification, say - can never run two pause/save passes
    /// over the same managers at once.
    private let actionLock = NSLock()
    private var actionInFlight = false

    /// Instances the last sleep response froze while they were running -
    /// the ones wake has to bring back. Guarded by `actionLock`.
    private var pausedForSleep: [VMManager] = []

    /// Set by the first termination signal, so a second one cannot start a
    /// second teardown on top of the first. launchd is entitled to send more
    /// than one, and does when a job outlives its first SIGTERM.
    private var terminating = false

    /// Set when a termination signal arrives while a response is already
    /// running. The *running response* then exits the process when it
    /// finishes, rather than the signal handler doing it - which is the
    /// whole fix, and the reason is in `handleTerminationSignal`.
    private var exitWhenResponseFinishes = false

    /// Set once the battery has triggered a hibernate, so a supply hovering
    /// at the threshold doesn't fire repeatedly. Cleared when the machine is
    /// plugged back in.
    private var lowBatteryLatched = false

    /// How long the per-app GUI hosts get to finish closing before the
    /// guest is frozen.
    ///
    /// Those hosts are separate processes. macOS asks each of them to quit
    /// independently of this one, and each responds by sending the Linux
    /// app a `WM_DELETE_WINDOW` and waiting - which is what gives an app
    /// with unsaved work the chance to put its own dialog up. Pausing the
    /// guest while that dialog is open freezes the X11 client drawing it,
    /// so the user is asked a question they physically cannot answer.
    ///
    /// Hence a grace period, and hence a bounded one: the user's rule is
    /// that a save prompt which drags must not hold up the shutdown. This
    /// is also the only thing protecting that work - hibernating does *not*
    /// save it, because these host processes die with the session and the
    /// app's X11 connection dies with them, so it cold-starts on restore
    /// no matter how cleanly the guest was snapshotted.
    ///
    /// Eight seconds, not more: overrunning what macOS allows produces the
    /// "MSL prevented shutdown" dialog, which is the outcome being avoided.
    private let guiHostDeadline: TimeInterval = 8

    /// How long every instance gets to *freeze*. Short on purpose: pausing
    /// does no I/O, so anything slower than this is a VM that is not going
    /// to respond in time either way, and the remaining budget is better
    /// spent on the instances that did.
    private let pauseDeadline: TimeInterval = 4

    /// How long the save phase gets, in total, across every instance
    /// (they run in parallel, so this is the slowest one, not the sum).
    /// Saving is proportional to guest RAM. Kept under launchd's
    /// `ExitTimeOut` so a logout cannot SIGKILL this process mid-write.
    private let saveDeadline: TimeInterval = 15

    /// How long the guest gets to flush its page cache before being frozen.
    /// Tight, and never allowed to delay the pause beyond it - running a
    /// command inside a guest is a way for a power handler to hang.
    /// Measured, not guessed: a `sync` on a healthy guest is tens of
    /// milliseconds, while a guest with no shell listener burns this whole
    /// budget failing to connect - which is exactly what the first test of
    /// this code did, adding 3 seconds to every lid close for nothing.
    private let quiesceDeadline: TimeInterval = 2

    /// Battery percentage at or below which a hibernate is triggered while
    /// on battery power. High enough to act before macOS begins its own
    /// emergency shutdown rather than racing it.
    private let lowBatteryThreshold = 10

    init(managersSnapshot: @escaping () -> [VMManager], hostDidWake: @escaping () -> Void = {}) {
        self.managersSnapshot = managersSnapshot
        self.hostDidWake = hostDidWake
    }

    /// Must be called from the thread that pumps the main run loop
    /// afterwards - the signal sources, the IOKit notification port and the
    /// power-source source all need it running to ever fire.
    func start() {
        installSignalHandlers()
        registerForPowerNotifications()
        registerForPowerSourceNotifications()
        registerForWorkspaceNotifications()
    }

    // MARK: - Logging out and switching users

    /// IOKit's power notifications cover sleep, shutdown and restart, but a
    /// plain **log out** is none of those - the machine stays on, so no
    /// power change happens and nothing in `registerForPowerNotifications`
    /// ever fires. Until now that case was caught only by `SIGTERM` arriving
    /// from launchd, which comes late in the teardown and gives the least
    /// warning of any path here. AppKit posts a notification at the *start*
    /// of the sequence instead, which is a much better place to act.
    private func registerForWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.log("the user is logging out or powering off")
            self?.respond(.pauseAndSave, reason: "logout")
        }

        // Fast user switching. Another account is taking the screen; this
        // session keeps running in the background and so do its guests.
        //
        // Deliberately NOT paused: switching users is not "stop what you are
        // doing", and someone who switches away mid-build and back expects
        // to find it still building - no other virtualisation tool suspends
        // on a user switch either. But the *other* user can shut the machine
        // down, so this is a free moment to flush the guests' page caches
        // while nobody is waiting on them. Cheap insurance, no behaviour
        // change.
        center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log("another user took the session - flushing guests, leaving them running")
            let running = self.managersSnapshot().filter { $0.currentState() == .running }
            guard !running.isEmpty else { return }
            self.runBounded(deadline: self.quiesceDeadline, over: running) { await $0.quiesceGuest() }
        }

        center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Nothing to repair: this session never stopped, its guests
            // never paused, and no vsock connection was broken. Logged only
            // so the sequence is legible when reading the daemon log after
            // something goes wrong.
            self?.log("session became active again")
        }
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        // Default disposition is "terminate immediately", which has to be
        // suppressed before the DispatchSource can run a handler instead.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.handleTerminationSignal(name: "SIGTERM") }
        term.resume()
        sigtermSource = term

        let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        int.setEventHandler { [weak self] in self?.handleTerminationSignal(name: "SIGINT") }
        int.resume()
        sigintSource = int
    }

    /// SIGTERM/SIGINT: freeze and save every guest, then exit - unless a
    /// power response is *already* running, in which case this must return
    /// without exiting and let that one finish.
    ///
    /// That second case is not theoretical, and it is the "sudden shutdown
    /// from the Apple menu" case specifically. It was reproduced rather than
    /// reasoned about (`power-probes/` at the repo root reproduces it, and
    /// verifies this fix), and the result is asymmetric in a way nothing
    /// here would suggest:
    ///
    /// - **Logout** enters `respond` from `NSWorkspace.willPowerOffNotification`,
    ///   whose observer is registered with `queue: .main` - so it runs
    ///   inside a *main-queue callout*. These signal sources are
    ///   `DispatchSource`s on `.main` too, and a serial queue is not
    ///   re-entrant, so a SIGTERM arriving mid-response is queued behind the
    ///   response and delivered only once it returns. Safe by accident.
    ///
    /// - **Shut Down / Restart from the Apple menu, and lid close**, enter
    ///   `respond` from the IOKit notification, which arrives on a
    ///   `CFRunLoopSource` - *not* a main-queue callout. Nothing defers the
    ///   main queue then, so the moment `waitForGUIHostsToExit` pumps the
    ///   run loop, this handler runs nested inside the still-unfinished
    ///   response. The old code logged "another power response is already
    ///   running" and then called `exit(0)` anyway, killing the process
    ///   during the GUI grace - before a single guest had been frozen, let
    ///   alone saved.
    ///
    /// Returning is the only correct move, and waiting here is the wrong
    /// one: the in-flight response is *below this frame on this same
    /// thread*, so it cannot make progress until this returns. Pumping the
    /// run loop to wait for it deadlocks until the timeout and then exits
    /// having accomplished nothing - measured, not assumed.
    private func handleTerminationSignal(name: String) {
        actionLock.lock()
        if terminating {
            actionLock.unlock()
            log("received \(name) while already shutting down - ignoring")
            return
        }
        terminating = true
        let inFlight = actionInFlight
        // Read and written under one acquisition, together with
        // `actionInFlight`: the response's own cleanup clears that flag and
        // reads this one under the same lock, so whichever side gets there
        // first, exactly one of them exits.
        if inFlight { exitWhenResponseFinishes = true }
        actionLock.unlock()

        log("received \(name)")

        if inFlight {
            log("\(name): a power response is already running - letting it finish "
                + "and exiting when it does, rather than killing it mid-flight")
            return
        }
        // No "have we already saved?" shortcut here on purpose. Asking
        // that of *history* is wrong: a `.pauseAndSave` can complete while
        // the daemon keeps running (`msl power-test shutdown`, a low-battery
        // hibernate) and an instance can be started again afterwards, so a
        // remembered "already saved" would skip a guest that is running
        // right now. `respond` asks the equivalent question of present
        // state instead - it returns immediately on "no running instances" -
        // and that answer cannot go stale.
        respond(.pauseAndSave, reason: name)
        exit(0)
    }

    // MARK: - System power

    private func registerForPowerNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifyPortRef: IONotificationPortRef?
        var notifierRef: io_object_t = 0
        let connection = IORegisterForSystemPower(refcon, &notifyPortRef, powerEventCallback, &notifierRef)
        guard connection != 0, let notifyPortRef else {
            log("IORegisterForSystemPower failed - sleep/shutdown hardening is degraded to signal handling only")
            return
        }
        powerConnection = connection
        notifierObject = notifierRef
        notifyPort = notifyPortRef
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
                           .commonModes)
    }

    /// Called on the main run loop, so full Swift work is safe here - unlike
    /// inside a raw signal handler.
    fileprivate func handlePowerMessage(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)

        switch messageType {
        case msgCanSystemSleep, msgCanSystemPowerOff:
            // These are *requests for consent* to an idle sleep or power
            // off. Having registered with IORegisterForSystemPower, a reply
            // is mandatory: leaving one unanswered stalls every idle sleep
            // for the full ~30-second timeout before macOS gives up on us.
            // MSL never has grounds to veto - a guest that needs more time
            // is handled by the will-sleep phase below, which is allowed to
            // take it - so consent is immediate and unconditional.
            IOAllowPowerChange(powerConnection, token)

        case msgSystemWillSleep:
            // The point of no return: once this returns (or the ~30s limit
            // expires) the hardware sleeps. This process survives sleep, so
            // there is nothing to persist - just freeze the guests fast.
            log("system going to sleep")
            respond(.pauseOnly, reason: "sleep")
            IOAllowPowerChange(powerConnection, token)

        case msgSystemWillPowerOff, msgSystemWillRestart:
            log("system shutting down or restarting")
            respond(.pauseAndSave, reason: "shutdown")
            IOAllowPowerChange(powerConnection, token)

        case msgSystemHasPoweredOn:
            handleWake()

        default:
            break
        }
    }

    /// After a wake, the *guests* are fine - they were frozen - but a lot of
    /// state around them is not, and none of it announces itself. Each of
    /// these surfaces later as an unrelated-looking error.
    private func handleWake() {
        log("host woke from sleep")

        // Every vsock connection died with the sleep; the daemon's session
        // counts and per-instance connection tables are now fiction.
        hostDidWake()
        for manager in managersSnapshot() {
            manager.handleHostDidWake()
        }

        // Resume what sleep froze. Nothing else ever did: an instance stayed
        // paused until some new shell session started it, while every open
        // Linux GUI app kept writing X11 events into a guest that wasn't
        // reading - the app hung and had to be force-quit after a lid close.
        // Only instances that were running when sleep came are resumed; one
        // the user had suspended stays suspended. Skipped if a power response
        // is still running, so a resume can never race a pause or a save.
        actionLock.lock()
        let inFlight = actionInFlight
        let toResume = inFlight ? [] : pausedForSleep
        if !inFlight { pausedForSleep = [] }
        actionLock.unlock()

        // A paused guest's clock stopped when the host slept, so it is
        // corrected after the resume - deliberately fire-and-forget rather
        // than something the wake path waits on.
        Task {
            var resumed = 0
            for manager in toResume where manager.currentState() == .paused {
                do {
                    try await manager.ensureRunning()
                    resumed += 1
                } catch {
                    log("wake: couldn't resume an instance - \(error)")
                }
            }
            if !toResume.isEmpty { log("wake: resumed \(resumed) instance(s) that sleep froze") }
            for manager in managersSnapshot() where manager.currentState() == .running {
                await manager.resyncGuestClock()
            }
        }
    }

    /// Runs the wake path by hand, for `msl power-test wake`.
    func simulateWake() { handleWake() }

    /// What the battery watcher currently sees, using the same parsing the
    /// real handler does.
    ///
    /// The low-battery path cannot be triggered on demand - a machine can't
    /// be made to run flat - so the part that would silently be wrong is the
    /// IOKit key handling: pick a key that doesn't exist and this either
    /// never fires or fires constantly, and either way nothing says so. This
    /// reads it out so it can be checked against `pmset -g batt`.
    func batteryDescription() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return "no power-source information available"
        }
        var lines: [String] = []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            let type = description[kIOPSTypeKey as String] as? String ?? "unknown"
            guard type == kIOPSInternalBatteryType else {
                lines.append("\(type): ignored - not an internal battery")
                continue
            }
            let isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            let onACPower = (description[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue
            let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? -1
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int ?? -1
            let percentage = maximum > 0 ? current * 100 / maximum : -1
            let wouldAct = !onACPower && !isCharging && percentage >= 0 && percentage <= lowBatteryThreshold
            let power = onACPower ? "on AC" : "on battery"
            let charging = isCharging ? ", charging" : ""
            let verdict = wouldAct ? "HIBERNATE NOW" : "do nothing"
            lines.append("battery \(percentage)% (\(current)/\(maximum)), \(power)\(charging), "
                + "threshold \(lowBatteryThreshold)%, latched \(lowBatteryLatched) -> would \(verdict)")
        }
        return lines.isEmpty ? "no batteries found" : lines.joined(separator: "\n")
    }

    // MARK: - Battery

    private func registerForPowerSourceNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, refcon)?.takeRetainedValue() else {
            log("couldn't watch the battery - low-power hibernation is unavailable")
            return
        }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Fires on every percentage change *and* every charging-state change,
    /// so it has to be cheap and idempotent.
    fileprivate func handlePowerSourceChange() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }

            let isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            let onACPower = (description[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue
            let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let percentage = maximum > 0 ? current * 100 / maximum : 100

            if onACPower || isCharging {
                // Plugged back in: re-arm, but nothing is un-hibernated -
                // that is a one-way action by design (see below).
                if lowBatteryLatched {
                    lowBatteryLatched = false
                    log("back on power - low-battery hibernation re-armed")
                }
                continue
            }

            guard percentage <= lowBatteryThreshold, !lowBatteryLatched else { continue }
            // Latched *before* acting: the pass below takes seconds, during
            // which more notifications will arrive.
            lowBatteryLatched = true
            log("battery at \(percentage)% and not charging - hibernating every instance now")
            // Deliberately one-way: plugging back in will not bring these
            // back, because a half-saved guest resumed mid-save is worse
            // than one that cold-boots. They resume on next use.
            respond(.pauseAndSave, reason: "low battery")
        }
    }

    // MARK: - The response itself

    /// Runs one power response, or returns immediately if another is already
    /// running. Exposed to `main.swift` so the same code paths can be driven
    /// by hand for testing - a host power event cannot be simulated any
    /// other way.
    func respond(_ response: Response, reason: String) {
        actionLock.lock()
        if actionInFlight {
            actionLock.unlock()
            log("\(reason): another power response is already running - not starting a second")
            return
        }
        actionInFlight = true
        actionLock.unlock()

        // Before anything else, so no other subsystem starts its own
        // pause/suspend against these managers while this runs.
        powerTransitionBegan?()
        defer {
            actionLock.lock()
            actionInFlight = false
            let shouldExit = exitWhenResponseFinishes
            actionLock.unlock()
            // Exiting from inside a `defer` reads like a mistake, so: it is
            // deliberate, and this is the only correct place for it. A
            // termination signal arrived while this response was running and
            // returned *without* exiting, precisely so this frame could
            // finish freezing and saving the guests - see
            // `handleTerminationSignal`. This is where the process actually
            // goes away.
            //
            // Inside the `defer` rather than after the last `log` because it
            // has to cover the two early returns below as well - "no running
            // instances", and the `.pauseOnly` return that skips the save
            // phase. Appending it to the end instead would leave the process
            // alive after those, waiting for launchd's SIGKILL.
            if shouldExit {
                log("\(reason): finished - exiting for the termination signal "
                    + "that arrived while it was running")
                exit(0)
            }
        }

        let live = managersSnapshot().filter { $0.currentState() != .stopped }
        guard !live.isEmpty else {
            log("\(reason): no running instances")
            return
        }
        log("\(reason): \(response.label) \(live.count) instance(s)")

        // Phase 0 - ask the guests to flush, and at the same time let any
        // GUI app hosts finish closing.
        //
        // Concurrently, because these two waits protect different things and
        // stacking them would roughly double the worst-case response: the
        // flush is what limits how much recent work is lost, and neither
        // freezes anything, so nothing here is ordered against the other.
        // Only the *pause* below has to wait for the hosts.
        let running = live.filter { $0.currentState() == .running }
        let quiesced = DispatchGroup()
        for manager in running {
            quiesced.enter()
            Task {
                await manager.quiesceGuest()
                quiesced.leave()
            }
        }
        if response == .pauseAndSave {
            waitForGUIHostsToExit()
        }
        if !running.isEmpty {
            _ = quiesced.wait(timeout: .now() + quiesceDeadline)
        }

        // Phase 1 - freeze everything. This is the part that matters, and it
        // happens for every instance before any of the slow work starts.
        let paused = runBounded(deadline: pauseDeadline, over: live) { manager in
            _ = await manager.pauseForHostPowerEvent()
        }
        log("\(reason): froze \(paused ? "every instance" : "as many instances as the deadline allowed")")

        // Only a sleep hands instances back to wake. A save stops them, and
        // they start again on next use.
        actionLock.lock()
        pausedForSleep = response == .pauseOnly ? running : []
        actionLock.unlock()

        // Phase 2 - persist, if this process is not going to survive.
        guard response == .pauseAndSave else { return }
        let saved = runBounded(deadline: saveDeadline, over: live) { manager in
            _ = await manager.saveStateForHostPowerEvent()
        }
        log("\(reason): \(saved ? "saved every instance" : "ran out of time saving - those instances will cold-boot next start, which is safe")")
    }

    /// Blocks until every per-app GUI host process has exited, or until
    /// `guiHostDeadline` passes - whichever comes first.
    ///
    /// Liveness is checked by process signature rather than by tracking
    /// child pids: the hosts are spawned by `X11AppRouter` with
    /// `posix_spawn` and their pids are not retained anywhere, and they are
    /// not necessarily children of this process to begin with. `pgrep`
    /// crosses that boundary without any new bookkeeping.
    ///
    /// Failing to observe them is deliberately treated as "none left". A
    /// broken check must not be able to stall a shutdown - the cost of
    /// returning early is a GUI app that loses unsaved work, the cost of
    /// hanging is the forced-quit dialog that endangers every instance.
    ///
    /// **This pump is the only re-entrancy window in the whole power path**,
    /// and anything added here should keep it that way. Every other wait in
    /// a response (`quiesced.wait`, both `runBounded` calls) blocks the main
    /// thread outright, so nothing can be delivered during them. This one
    /// runs the run loop, so a `SIGTERM` handler can execute *nested inside
    /// an unfinished response* - but only when the response was entered from
    /// the IOKit `CFRunLoopSource` (Apple-menu shutdown, restart, lid
    /// close), because a response entered from a main-queue callout
    /// (logout's `willPowerOffNotification`) is protected by the main
    /// queue's own non-re-entrancy. That asymmetry is measured, not derived,
    /// and `handleTerminationSignal` is written around it.
    private func waitForGUIHostsToExit() {
        guard liveGUIHostCount() > 0 else { return }
        log("waiting up to \(Int(guiHostDeadline))s for GUI apps to close (they may be asking about unsaved work)")
        let deadline = Date().addingTimeInterval(guiHostDeadline)
        while Date() < deadline {
            // Pump the run loop rather than sleeping on it.
            //
            // Power notifications arrive on the main thread (the IOKit
            // source is on `CFRunLoopGetMain`, the workspace observers use
            // `queue: .main`), and `mslhd` runs a real Cocoa event loop
            // there - it is the thread that draws X11 windows and delivers
            // clicks to them. Sleeping it for the whole grace would freeze
            // the save dialog this is waiting for, so the wait would
            // guarantee its own timeout. Running the loop keeps that
            // drawing and those clicks alive while still returning here
            // every quarter second to re-check.
            //
            // `run(mode:before:)` returns as soon as it handles an input
            // source, and immediately if there are none at all, so the
            // remainder of each tick is slept off explicitly. Without that
            // floor this becomes a spin loop that forks a `pgrep` as fast
            // as the CPU allows, for ten seconds, during a shutdown.
            let tickEnds = Date().addingTimeInterval(0.25)
            RunLoop.current.run(mode: .default, before: tickEnds)
            let remaining = tickEnds.timeIntervalSinceNow
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            if liveGUIHostCount() == 0 {
                log("every GUI app closed on its own")
                return
            }
        }
        log("GUI apps still open after \(Int(guiHostDeadline))s - freezing now rather than holding up the shutdown")
    }

    /// The number of running per-app hosts, or 0 if that cannot be
    /// determined. `--msl-app-host` is the flag `X11AppRouter.spawn` starts
    /// them with, and nothing else on the system carries it.
    private func liveGUIHostCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "--", "--msl-app-host"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// Runs `operation` over every manager in parallel and waits up to
    /// `deadline` for all of them. Returns whether they all finished.
    ///
    /// In parallel, so the deadline bounds the slowest instance rather than
    /// the sum of all of them - the difference between four instances taking
    /// one budget and taking four.
    ///
    /// Blocking the calling thread is correct here and cannot deadlock:
    /// every `VZVirtualMachine` is built with
    /// `VZVirtualMachine(configuration:queue:)` against that instance's own
    /// private `vmQueue`, so its completion handlers never need the main
    /// thread this is called from. Were it built with the queue-less
    /// initializer, completions would land on the main queue and this wait
    /// would deadlock until the deadline every single time - checked in
    /// `VMManager.buildVirtualMachine` rather than assumed.
    @discardableResult
    private func runBounded(
        deadline: TimeInterval,
        over managers: [VMManager],
        _ operation: @escaping (VMManager) async -> Void
    ) -> Bool {
        let group = DispatchGroup()
        for manager in managers {
            group.enter()
            Task {
                await operation(manager)
                group.leave()
            }
        }
        return group.wait(timeout: .now() + deadline) == .success
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("mslhd[power]: \(message)\n".data(using: .utf8)!)
    }
}

private func powerEventCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<SystemResilienceMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .handlePowerMessage(messageType, argument: messageArgument)
}

private func powerSourceCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<SystemResilienceMonitor>.fromOpaque(context).takeUnretainedValue()
        .handlePowerSourceChange()
}
