// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// The wire protocol between `msl` (client) and `mslhd` (daemon) over the
/// control UNIX domain socket. Line-based text, not binary framing - this
/// project is in a fast feature-growth phase (suspend/hibernate/snapshot/
/// multi-instance all landed at once) and a human-readable, trivially
/// extensible protocol is worth more right now than the last bit of
/// leanness. Revisit if this ever needs to be fast/binary (it's a control
/// channel, not the shell data path - that part is `ShellProtocol`'s own
/// binary framing over the handed-off vsock fd, once this control channel's
/// job - authenticating the session and handing off the fd - is done).
public enum DaemonProtocol {

    /// Default location for the daemon's listening UNIX domain socket.
    public static func defaultSocketPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/MSL/mslhd.sock"
    }

    public static func defaultInstanceRegistryPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/MSL/instances.json"
    }

    /// One control request, always a single newline-terminated line.
    public enum ControlRequest {
        /// `distro` only matters the first time `instance` is created -
        /// see `InstanceRegistry.ensureRegistered`. Defaults to `.alpine`
        /// when omitted from the wire line, so old 3-token `SESSION`
        /// lines (and older `msl` clients) keep working unchanged.
        case session(instance: String, rows: UInt16, cols: UInt16, distro: GuestDistro = .alpine)
        case suspend(instance: String)
        case resume(instance: String)
        case hibernate(instance: String)
        case snapshotSave(instance: String, name: String)
        case snapshotRestore(instance: String, name: String)
        case snapshotList(instance: String)
        case status(instance: String)
        case instanceList
        /// Removes one instance. When it was the last instance of its distro
        /// the disk they shared is deleted too, unless `keepDisk` - nothing
        /// uses it any more, and leaving it stranded a 63 GB image nobody
        /// could see (2026-09-16).
        case remove(instance: String, keepDisk: Bool = false)
        /// Deletes a whole distro installation: every instance of `distro`,
        /// then the disk image they share. Refused while any of them is
        /// starting or under maintenance.
        case removeDistro(distro: GuestDistro)
        /// Sent by `msl` right after a shell session's relay loop ends
        /// (interactive or one-shot, clean exit or dropped connection),
        /// over a fresh short-lived connection - fire-and-forget, no
        /// response expected. Lets the daemon know a session for `instance`
        /// is no longer active, so it can auto-suspend once the last one
        /// closes rather than only on the idle timer - see `DaemonServer`'s
        /// `activeSessions` tracking. A client that crashes before sending
        /// this just means the auto-suspend doesn't fire promptly for that
        /// instance - a safe failure mode (nothing is lost, it just stays
        /// warm longer than ideal), not one worth adding real robustness
        /// against yet.
        case sessionEnded(instance: String)
        /// Sent by `msl --shutdown` after it has already asked the guest to
        /// `poweroff` over the shell channel and given it a moment to
        /// flush - see `VMManager.stopAfterGuestShutdown()`. Distinct from
        /// `hibernate`: no save-to-disk, and any stale implicit hibernate
        /// snapshot is cleared rather than left to be wrongly restored from
        /// next time.
        case shutdown(instance: String)
        /// Ultra-experimental (see the archived `msl-vgpu.md` design):
        /// starts the host side of the GUI tunnel for `instance` - see
        /// `VMManager.startDisplayBridge()`/`DisplayBridge`'s doc comments.
        /// Sent by `msl gui <instance>`. Never sent implicitly - GUI
        /// support stays fully opt-in.
        case startGui(instance: String)
        /// Ultra-experimental (see the archived `msl-vgpu.md` design's
        /// Phase 2): starts the native X11 server (`X11Server`/"mslgd")
        /// for `instance` - see `VMManager.startX11Server()`'s doc
        /// comment. Sent by `msl gui-native <instance>`; independent of
        /// `startGui` (Phase 1's XQuartz-tunnel path) - both can run at
        /// once.
        case startNativeGui(instance: String)
        /// `cage-planning.md` Phase 3: starts the host side of the cage/
        /// Wayland frame stream (`CageBridge`) for `instance` - see
        /// `VMManager.startCageBridge()`'s doc comment. Sent by
        /// `msl cage-bridge-test <instance>`; independent of `startGui`/
        /// `startNativeGui` - all three can run at once, on separate
        /// ports.
        /// `maxFrames`: 0 = unlimited/continuous (real streaming mode -
        /// see `CageBridge.receive`'s doc comment for why the sink shape
        /// differs), a positive count = bounded debug-dump mode (one
        /// file per frame index, `msl cage-bridge-test`'s own default).
        case startCageBridge(instance: String, maxFrames: Int)
        /// `cage-planning.md` Phase 3 step 3: starts the host side of
        /// host->guest input injection (`CageInputBridge`) for
        /// `instance` - see `VMManager.startCageInputBridge()`'s doc
        /// comment. Sent by `msl cage-input-test <instance>`;
        /// independent of `startCageBridge` (separate port/connection).
        case startCageInputBridge(instance: String)
        /// Injects one synthetic key event into `instance`'s currently-
        /// connected guest `cageinput` session - see
        /// `VMManager.sendCageKey()`'s doc comment for the `keycode`
        /// convention (evdev, not Xkb). Debug-only, sent by `msl
        /// cage-input-test`.
        case sendCageKey(instance: String, keycode: UInt32, pressed: Bool)
        /// `cage-planning.md` Phase 4: starts a real, on-screen live
        /// view of `instance`'s cage session - see
        /// `VMManager.startCageView()`'s doc comment. Sent by `msl
        /// cage-view <instance>`.
        case startCageView(instance: String)
        /// Registers `instance` (with `distro`) **without** starting it -
        /// the explicit counterpart to the implicit registration every
        /// other verb does as a side effect of `DaemonServer.manager
        /// (for:)`. MSLApp needs a real "create this instance" action that
        /// is distinguishable from a typo, and read-only verbs must stop
        /// conjuring instances into existence (that is how `--`, `start`
        /// and `--shutdown` ended up in `instances.json`).
        case createInstance(instance: String, distro: GuestDistro)
        /// Every registered instance with its distro and current state, in
        /// one round trip, plus how many count against the concurrent-VM
        /// cap and what that cap is. MSLApp polls this a few times a
        /// minute; doing it as `INSTANCES` plus one `STATUS` per instance
        /// was N+1 connections per refresh, and - worse - each `STATUS`
        /// registered any name it was handed.
        ///
        /// Response body is one instance per line:
        /// `<name>\t<distro>\t<state>\t<installed 0|1>`, preceded by a
        /// header line `#\t<runningCount>\t<cap>`.
        case instanceDetails
        /// Runs one of the host-power responses by hand, exactly as the real
        /// IOKit notification would. Debug-only, and the only way any of
        /// this is testable: a machine cannot be made to sleep, shut down or
        /// run its battery flat on demand, so without this the sleep and
        /// shutdown paths would ship having never once been executed.
        /// `event` is one of `sleep`, `shutdown`, `lowbattery`, `wake`.
        case powerTest(event: String)

        /// Reads the sandbox gates for `instance`. The answer comes from
        /// the VM's own devices where it can (a network attachment can drop
        /// on its own, see `VMManager.observedSandboxPolicy()`), so this is
        /// a real query and not an echo of the last SET.
        case sandboxGet(instance: String)

        /// Closes or opens the gates for `instance`. `token` is
        /// `SandboxPolicy.wireToken` - four flags in one word, so the whole
        /// policy moves atomically rather than as four commands that could
        /// half-apply.
        case sandboxSet(instance: String, token: String)

        /// Asks the guest what its own network is doing (`trafficd`). The
        /// reply is the raw SOCKETS payload, base64'd, because this control
        /// channel is line-based text and the payload deliberately is not.
        case trafficSnapshot(instance: String, attributeProcesses: Bool)

        /// What dynamic memory is doing for `instance` right now - the
        /// current balloon target, what the guest says it is using, and why
        /// the last adjustment happened. Read-only, and never starts a VM:
        /// a stopped instance simply has no live figures to report.
        case memoryStatus(instance: String)

        /// Filesystem check and repair, the maintenance boot, the guest
        /// utilities, and check-at-start. `command` is a closed set of words
        /// validated at parse time - never a command to execute.
        case maintenance(instance: String, command: MaintenanceCommand)

        /// The instance this request would *start*, if any - as opposed to
        /// merely asking about one or shutting one down. Drives the
        /// daemon's idle bookkeeping: something that brings a VM up must
        /// count as activity, or the idle timer hibernates it moments
        /// later, while a status poll must not (it would keep every
        /// instance alive for as long as a UI is watching).
        public var startsInstance: String? {
            switch self {
            case .session(let instance, _, _, _),
                 .resume(let instance),
                 .startGui(let instance),
                 .startNativeGui(let instance),
                 .startCageBridge(let instance, _),
                 .startCageInputBridge(let instance),
                 .startCageView(let instance),
                 .snapshotRestore(let instance, _):
                return instance
            case .suspend, .hibernate, .shutdown, .status, .instanceList,
                 .instanceDetails, .remove, .removeDistro, .sessionEnded, .snapshotSave,
                 .snapshotList, .sendCageKey, .createInstance, .powerTest,
                 // Reading or changing the gates must never boot a VM.
                 // Closing them on a stopped instance is the normal way to
                 // sandbox something *before* it runs; the policy is
                 // persisted and re-applied on its next start.
                 .sandboxGet, .sandboxSet,
                 // Watching a guest must never start one.
                 .trafficSnapshot, .memoryStatus,
                 // Maintenance works on a stopped instance, and the one boot
                 // it does is its own - never an ordinary start.
                 .maintenance:
                return nil
            }
        }

        /// A one-line description for the traffic monitor, or `nil` for
        /// requests not worth showing.
        ///
        /// The exclusions are all **polls**: `MSLApp` asks for
        /// `INSTANCE_DETAILS` every few seconds and the sandbox tab asks
        /// for its gates on a timer. Logging those would bury every real
        /// event under the UI watching itself - the monitor would mostly
        /// show that the monitor is open.
        public var monitorSummary: String? {
            switch self {
            case .instanceDetails, .instanceList, .status, .sandboxGet, .sessionEnded,
                 // The monitor polls this every second while open.
                 .trafficSnapshot,
                 // The Resources card polls this while it is on screen.
                 .memoryStatus:
                return nil
            case .maintenance(_, let command):
                // The card polls its status; the actions are worth logging.
                return command == .status ? nil : "Maintenance: \(command.rawValue)"
            case .session(let instance, _, _, _):        return "Shell session opened (\(instance))"
            case .suspend:                                return "Suspend"
            case .resume:                                 return "Resume"
            case .hibernate:                              return "Hibernate"
            case .shutdown:                               return "Shut down"
            case .snapshotSave(_, let name):              return "Snapshot saved: \(name)"
            case .snapshotRestore(_, let name):           return "Snapshot restored: \(name)"
            case .snapshotList:                           return "Snapshot list"
            case .remove:                                 return "Instance removed"
            case .removeDistro(let distro):               return "Installation deleted (\(distro.rawValue))"
            case .startGui:                               return "XQuartz tunnel started"
            case .startNativeGui:                         return "mslgd started"
            case .startCageBridge:                        return "Cage frame bridge started"
            case .startCageInputBridge:                   return "Cage input bridge started"
            case .sendCageKey:                            return "Cage key injected"
            case .startCageView:                          return "Cage view started"
            case .createInstance(_, let distro):          return "Instance created (\(distro.rawValue))"
            case .powerTest(let event):                   return "Power test: \(event)"
            case .sandboxSet(_, let token):               return "Sandbox gates set to \(token)"
            }
        }

        /// Which instance the monitor should file this under, if any.
        public var monitorInstance: String? {
            switch self {
            case .session(let instance, _, _, _),
                 .suspend(let instance), .resume(let instance), .hibernate(let instance),
                 .shutdown(let instance), .status(let instance), .remove(let instance, _),
                 .sessionEnded(let instance), .startGui(let instance),
                 .startNativeGui(let instance), .startCageView(let instance),
                 .startCageBridge(let instance, _), .startCageInputBridge(let instance),
                 .sendCageKey(let instance, _, _), .snapshotSave(let instance, _),
                 .snapshotRestore(let instance, _), .snapshotList(let instance),
                 .createInstance(let instance, _), .sandboxGet(let instance),
                 .sandboxSet(let instance, _), .trafficSnapshot(let instance, _),
                 .memoryStatus(let instance), .maintenance(let instance, _):
                return instance
            case .instanceList, .instanceDetails, .powerTest, .removeDistro:
                return nil
            }
        }

        /// Which lane of the monitor this belongs in.
        public var monitorCategory: ActivityEvent.Category {
            switch self {
            case .startGui, .startNativeGui, .startCageBridge, .startCageInputBridge,
                 .startCageView, .sendCageKey:
                return .display
            case .suspend, .resume, .hibernate, .shutdown, .snapshotSave,
                 .snapshotRestore, .powerTest:
                return .lifecycle
            case .sandboxGet, .sandboxSet:
                return .sandbox
            case .maintenance:
                return .lifecycle
            case .trafficSnapshot, .memoryStatus:
                return .control
            default:
                return .control
            }
        }

        public func encode() -> Data {
            let line: String
            switch self {
            case .session(let instance, let rows, let cols, let distro):
                line = "SESSION \(instance) \(rows) \(cols) \(distro.rawValue)"
            case .suspend(let instance): line = "SUSPEND \(instance)"
            case .resume(let instance): line = "RESUME \(instance)"
            case .hibernate(let instance): line = "HIBERNATE \(instance)"
            case .snapshotSave(let instance, let name): line = "SNAPSHOT SAVE \(instance) \(name)"
            case .snapshotRestore(let instance, let name): line = "SNAPSHOT RESTORE \(instance) \(name)"
            case .snapshotList(let instance): line = "SNAPSHOT LIST \(instance)"
            case .status(let instance): line = "STATUS \(instance)"
            case .instanceList: line = "INSTANCES"
            case .remove(let instance, let keepDisk): line = keepDisk ? "REMOVE \(instance) KEEP_DISK" : "REMOVE \(instance)"
            case .removeDistro(let distro): line = "REMOVE_DISTRO \(distro.rawValue)"
            case .sessionEnded(let instance): line = "SESSION_ENDED \(instance)"
            case .startGui(let instance): line = "START_GUI \(instance)"
            case .startNativeGui(let instance): line = "START_NATIVE_GUI \(instance)"
            case .startCageBridge(let instance, let maxFrames): line = "START_CAGE_BRIDGE \(instance) \(maxFrames)"
            case .startCageInputBridge(let instance): line = "START_CAGE_INPUT_BRIDGE \(instance)"
            case .sendCageKey(let instance, let keycode, let pressed): line = "SEND_CAGE_KEY \(instance) \(keycode) \(pressed ? 1 : 0)"
            case .startCageView(let instance): line = "START_CAGE_VIEW \(instance)"
            case .shutdown(let instance): line = "SHUTDOWN \(instance)"
            case .createInstance(let instance, let distro): line = "CREATE \(instance) \(distro.rawValue)"
            case .instanceDetails: line = "INSTANCE_DETAILS"
            case .powerTest(let event): line = "POWER_TEST \(event)"
            case .sandboxGet(let instance): line = "SANDBOX GET \(instance)"
            case .sandboxSet(let instance, let token): line = "SANDBOX SET \(instance) \(token)"
            case .trafficSnapshot(let instance, let procs): line = "TRAFFIC \(instance) \(procs ? 1 : 0)"
            case .memoryStatus(let instance): line = "MEMORY \(instance)"
            case .maintenance(let instance, let command): line = "MAINTENANCE \(instance) \(command.rawValue)"
            }
            return (line + "\n").data(using: .utf8)!
        }

        public static func parse(_ line: String) -> ControlRequest? {
            let tokens = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            guard let command = tokens.first else { return nil }
            let rest = Array(tokens.dropFirst())
            switch command.uppercased() {
            case "SESSION":
                guard rest.count >= 3, let rows = UInt16(rest[1]), let cols = UInt16(rest[2]) else { return nil }
                let distro = rest.count > 3 ? (GuestDistro(rawValue: rest[3]) ?? .alpine) : .alpine
                return .session(instance: rest[0], rows: rows, cols: cols, distro: distro)
            case "SUSPEND":
                guard rest.count == 1 else { return nil }
                return .suspend(instance: rest[0])
            case "RESUME":
                guard rest.count == 1 else { return nil }
                return .resume(instance: rest[0])
            case "HIBERNATE":
                guard rest.count == 1 else { return nil }
                return .hibernate(instance: rest[0])
            case "SNAPSHOT":
                guard rest.count >= 2 else { return nil }
                switch rest[0].uppercased() {
                case "SAVE" where rest.count == 3: return .snapshotSave(instance: rest[1], name: rest[2])
                case "RESTORE" where rest.count == 3: return .snapshotRestore(instance: rest[1], name: rest[2])
                case "LIST" where rest.count == 2: return .snapshotList(instance: rest[1])
                default: return nil
                }
            case "STATUS":
                guard rest.count == 1 else { return nil }
                return .status(instance: rest[0])
            case "INSTANCES":
                return .instanceList
            case "INSTANCE_DETAILS":
                return .instanceDetails
            case "POWER_TEST":
                guard rest.count == 1 else { return nil }
                return .powerTest(event: rest[0])
            case "TRAFFIC":
                guard rest.count == 2 else { return nil }
                return .trafficSnapshot(instance: rest[0], attributeProcesses: rest[1] == "1")
            case "MAINTENANCE":
                // Unknown words fail here, at the edge, so nothing downstream
                // ever sees a command it doesn't know.
                guard rest.count == 2, let command = MaintenanceCommand(rawValue: rest[1]) else { return nil }
                return .maintenance(instance: rest[0], command: command)
            case "MEMORY":
                guard rest.count == 1 else { return nil }
                return .memoryStatus(instance: rest[0])
            case "SANDBOX":
                guard rest.count >= 2 else { return nil }
                switch rest[0].uppercased() {
                case "GET" where rest.count == 2: return .sandboxGet(instance: rest[1])
                case "SET" where rest.count == 3: return .sandboxSet(instance: rest[1], token: rest[2])
                default: return nil
                }
            case "CREATE":
                guard rest.count == 2, let distro = GuestDistro(rawValue: rest[1]) else { return nil }
                return .createInstance(instance: rest[0], distro: distro)
            case "REMOVE":
                switch rest.count {
                case 1: return .remove(instance: rest[0])
                case 2 where rest[1] == "KEEP_DISK": return .remove(instance: rest[0], keepDisk: true)
                default: return nil
                }
            case "REMOVE_DISTRO":
                guard rest.count == 1, let distro = GuestDistro(rawValue: rest[0]) else { return nil }
                return .removeDistro(distro: distro)
            case "SESSION_ENDED":
                guard rest.count == 1 else { return nil }
                return .sessionEnded(instance: rest[0])
            case "SHUTDOWN":
                guard rest.count == 1 else { return nil }
                return .shutdown(instance: rest[0])
            case "START_GUI":
                guard rest.count == 1 else { return nil }
                return .startGui(instance: rest[0])
            case "START_NATIVE_GUI":
                guard rest.count == 1 else { return nil }
                return .startNativeGui(instance: rest[0])
            case "START_CAGE_BRIDGE":
                guard rest.count == 2, let maxFrames = Int(rest[1]) else { return nil }
                return .startCageBridge(instance: rest[0], maxFrames: maxFrames)
            case "START_CAGE_INPUT_BRIDGE":
                guard rest.count == 1 else { return nil }
                return .startCageInputBridge(instance: rest[0])
            case "SEND_CAGE_KEY":
                guard rest.count == 3, let keycode = UInt32(rest[1]), let pressedFlag = Int(rest[2]) else { return nil }
                return .sendCageKey(instance: rest[0], keycode: keycode, pressed: pressedFlag != 0)
            case "START_CAGE_VIEW":
                guard rest.count == 1 else { return nil }
                return .startCageView(instance: rest[0])
            default:
                return nil
            }
        }
    }

    /// Reads a single newline-terminated line from a raw fd (byte-at-a-time
    /// - control requests are short and this isn't a hot path). Returns nil
    /// on EOF/error before any newline.
    public static func readLine(fd: Int32, maxLength: Int = 4096) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < maxLength {
            let n = read(fd, &byte, 1)
            guard n == 1 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Daemon -> client for SESSION requests specifically: a single status
    /// byte sent before the fd handoff (OK) or instead of it, followed by a
    /// plain-text reason (error).
    public static let statusOK: UInt8 = 0x00
    public static let statusError: UInt8 = 0x01

    /// Daemon -> client for every other request: one newline-terminated
    /// text line, "OK ..." or "ERROR ...".
    public static func encodeTextResponse(ok: Bool, message: String) -> Data {
        ((ok ? "OK " : "ERROR ") + message + "\n").data(using: .utf8)!
    }
}
