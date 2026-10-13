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
        /// Reattach to a session that is already running in the guest, on
        /// the vsock port it reported when it was created. Never starts the
        /// instance: a reattach is only meaningful if the guest is up, and
        /// starting it here would resume an instance somebody just paused.
        case attachSession(instance: String, port: UInt32)
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
        /// Gives an instance another name, carrying every piece of state
        /// MSL holds about it (`InstanceStateTransfer`).
        ///
        /// In the daemon rather than the CLI because only mslhd knows what
        /// is running, owns the maintenance slot, and holds the VMManager
        /// whose files have to move - and because MSLAP's `instance.rename`
        /// has to bind `msl` and MSL.app alike.
        case renameInstance(instance: String, newName: String)
        /// Makes a second instance from this one: its disk, its accounts,
        /// its settings, under a new name.
        ///
        /// Cheap for the same reason a new instance is - `clonefile(2)` on
        /// APFS - so this is a real copy of a working setup rather than a
        /// fresh install to configure again.
        case cloneInstance(instance: String, newName: String)
        /// Writes the provenance marker inside a guest again, when it has
        /// gone missing and the person is sure the disk is the right one.
        ///
        /// **Deliberately a request somebody has to make by hand.** MSL
        /// will not rewrite a missing marker on its own, because doing so
        /// would stamp an instance's identity onto whatever disk is
        /// actually there. But a marker CAN go missing innocently - a
        /// disk-space cleanup, a `/etc` restore, somebody tidying - and
        /// without a way back an instance would stay flagged for ever.
        /// So the way back exists and costs an explicit decision.
        case rewriteIdentityMarker(instance: String)
        /// Moves an instance's disk into an encrypted container, or back
        /// out of one.
        ///
        /// In the daemon because it needs the instance provably stopped
        /// and the maintenance slot held - nothing else may open the image
        /// while gigabytes of it are being copied.
        case protectInstance(instance: String, enable: Bool)
        /// Supplies, sets or forgets an administrator-held container key.
        ///
        /// `action` is `unlock`, `lock`, or `adopt` (move the container to
        /// admin-held mode). The passphrase is the remainder of the line,
        /// because a passphrase may contain spaces - and it reaches the
        /// daemon over a unix socket owned by this user, which is the same
        /// channel every other request uses.
        ///
        /// **Never logged and never persisted.** The daemon keeps an
        /// unwrapped key in memory for the life of the process and
        /// nowhere else; writing one down would turn admin-held mode back
        /// into at-rest mode with extra steps.
        case vaultKey(instance: String, action: String, passphrase: String)

        /// Opens a port on this Mac that reaches one inside a guest.
        ///
        /// In the daemon because mslhd is the process that knows where a
        /// guest is, owns the listener's lifetime across sessions, and can
        /// bring the forward back after a restart - and because
        /// `network.portForward` has to bind the app and the CLI alike.
        case forwardAdd(instance: String, hostPort: UInt16, guestPort: UInt16, viaSSH: Bool)
        /// Closes one. **Never refused by a policy** - it reduces what this
        /// Mac exposes, and the safe direction is always allowed.
        case forwardRemove(hostPort: UInt16)
        /// What is forwarded, and which of those are actually live.
        case forwardList(instance: String)
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
        /// MSL Files asking what a parked file pick wants it to show. See
        /// `PendingFilePicks` and `READMES/24-FILE-PICKER.md`.
        case filePickDetails(token: String)
        /// MSL Files reporting what the person chose. Paths are base64 on
        /// the wire because this protocol is space-separated and a path may
        /// contain spaces; `cancelled` is distinct from an empty list, which
        /// would mean "chose nothing reachable".
        case filePickResult(token: String, encodedPaths: [String], cancelled: Bool)
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

        /// Lists a guest directory through `fileopsd`, for MSL Files to
        /// overlay the *real* Linux mode (permissions and file type) onto its
        /// WebDAV-mount listing - the mount fakes both. The app has no vsock
        /// of its own, so mslhd lists on its behalf. Read-only, never starts
        /// or wakes a VM: an instance that isn't running just has no answer.
        /// `guestPath` is base64 on the wire because a path may contain
        /// spaces, which the space-split parser would otherwise break on. The
        /// reply is the raw LIST2 bytes, base64'd (see the `FILE_LIST`
        /// handler), decoded with `FileOpsProtocol.parseList2`.
        case fileList(instance: String, guestPath: String)

        /// Sets a guest file's permission bits through `fileopsd` - what "Make
        /// Executable" in MSL Files needs, because POSIX bits set over the
        /// WebDAV mount never reach the real Linux inode. `guestPath` is
        /// base64 as in `fileList`. Registered, running instances only.
        case fileChmod(instance: String, guestPath: String, mode: UInt32)

        /// Reads a folder's git state, or initialises a repository in it.
        ///
        /// Runs inside the guest, which is the only place it can be right:
        /// the WebDAV mount fakes POSIX modes, so a Mac-side git sees every
        /// file as mode-changed, and asking it to stat a large checkout over
        /// the mount is slow enough to be unusable. `guestPath` is base64 as
        /// in `fileList`. Like the other file operations this never starts or
        /// wakes an instance - a stopped one simply has no repositories to
        /// report.
        /// `argument` carries the remote URL for `setOrigin`, base64 like
        /// the path. Empty for every other operation, and empty for
        /// `setOrigin` means "remove the origin".
        case gitQuery(instance: String, guestPath: String, operation: GitOperation,
                      argument: String = "")

        /// Tries to reach a guest on the local network **from the daemon**,
        /// so macOS raises its Local Network prompt for the process that
        /// actually needs the permission.
        ///
        /// macOS grants Local Network per binary, and it is `mslhd` that
        /// connects to an instance's address - not MSL.app. Asking from the
        /// app prompted for the app, the person allowed it, and the daemon
        /// was still refused, which is why this came back for everyone who
        /// had already allowed everything.
        case localNetworkProbe(host: String)

        /// The Mac's USB devices, as the daemon sees them. No instance and
        /// no entitlement - a plain IOKit registry read.
        case usbList

        /// Hand a Mac USB device to a running guest over USB/IP.
        ///
        /// `device` is a `locationID` in hex, or the literal `synthetic` for
        /// `SyntheticUSBDevice` - MSL's own self-test, which exercises the
        /// identical path (vsock carriage, `vhci_hcd` attach, URB framing)
        /// without touching hardware. `capture` takes the device away from
        /// macOS's own driver, which needs root.
        case usbAttach(instance: String, device: String, capture: Bool)

        /// Resolves a device the person named and says which tier it needs,
        /// without attaching anything.
        ///
        /// Separate from `usbAttach` because the answer decides whether the
        /// CLI has to ask for a password at all - a device macOS has never
        /// heard of is attached with no privileges, and most devices are
        /// not that.
        case usbPlan(device: String)

        /// Opens a one-shot socket for a root helper to serve a captured
        /// device on, and returns its path. The daemon waits for the helper
        /// in the background; the caller's job is to start it.
        case usbRelay(instance: String, device: String)

        /// Takes a device back from a guest.
        case usbDetach(instance: String, device: String)

        /// Publish an instance's SSH beyond this Mac. See `PublicMSL`.
        case publicExpose(instance: String, backend: String)
        /// Stop publishing it, and undo the hardening.
        case publicRevoke(instance: String)
        /// Where an instance is published, if it is.
        case publicStatus(instance: String)
        /// Let a machine's own public key log in. This is how somebody
        /// connects from another computer without a private key ever
        /// travelling - see `PublicHardening.authorizeCommand`.
        case publicAuthorize(instance: String, key: String, label: String)
        case publicDeauthorize(instance: String, match: String)
        case publicKeys(instance: String)

        // Emailing the address out. **Every one of these goes through the
        // daemon**, including from the app, because the API key lives in
        // the Keychain and an item written by one binary and read by
        // another prompts the user - MSL is ad-hoc signed, so `msl`,
        // `MSLApp` and `mslhd` are three different identities. One writer
        // and one reader means no prompts, ever.
        case publicNotifySetup(apiKey: String, replyTo: String, from: String)
        case publicNotifyForget
        case publicNotifyTest(to: String)
        case publicNotifyAdd(instance: String, email: String, label: String)
        case publicNotifyRemove(instance: String, email: String)
        case publicNotifyList(instance: String)
        /// Make a key for one person and hand it back, for sharing by
        /// hand. The other half of `publicAuthorize`: that one takes a key
        /// somebody already has, this one makes them one.
        case publicMakeKey(instance: String, label: String)
        /// Whether Tailscale is here, signed in, and which machines are on
        /// the tailnet. Asked by the app so the setting can show state
        /// rather than ask somebody to go and check.
        case publicTailscaleStatus

        /// The instance this request would *start*, if any - as opposed to
        /// merely asking about one or shutting one down. Drives the
        /// daemon's idle bookkeeping: something that brings a VM up must
        /// count as activity, or the idle timer hibernates it moments
        /// later, while a status poll must not (it would keep every
        /// instance alive for as long as a UI is watching).
        public var startsInstance: String? {
            switch self {
            // `.attachSession` is deliberately absent: reattaching to a
            // session must never start or keep alive an instance somebody
            // just hibernated.
            case .session(let instance, _, _, _),
                 .resume(let instance),
                 .startGui(let instance),
                 .startNativeGui(let instance),
                 .startCageBridge(let instance, _),
                 .startCageInputBridge(let instance),
                 .startCageView(let instance),
                 .snapshotRestore(let instance, _),
                 // Writing the provenance marker needs the guest up, and
                 // asking for it is a deliberate request for that - so it
                 // counts as a start, and as activity the idle timer must
                 // not undo a second later.
                 .rewriteIdentityMarker(let instance),
                 // Renaming and cloning are absent on purpose: both refuse
                 // a running instance outright, so there is no VM for them
                 // to keep awake and nothing to count as activity.
                 // Handing a device to an instance is a deliberate request
                 // for that instance to have it, so it counts as a start.
                 // mslhd pauses a guest a few seconds after its last
                 // session closes, and an attach that refused a paused
                 // instance - which is most of them, most of the time -
                 // would be useless.
                 .usbAttach(let instance, _, _),
                 .usbRelay(let instance, _),
                 // Publishing an instance is a deliberate request for it to
                 // be reachable, and there is nothing to publish while it
                 // is paused - which, a few seconds after the last session
                 // closes, is most of the time.
                 .publicExpose(let instance, _),
                 // Authorizing a key has to reach the guest's filesystem,
                 // so the guest has to be there.
                 .publicAuthorize(let instance, _, _),
                 .publicDeauthorize(let instance, _):
                return instance
            case .attachSession, .suspend, .hibernate, .shutdown, .status, .instanceList,
                 .instanceDetails, .remove, .removeDistro, .sessionEnded, .snapshotSave,
                 .snapshotList, .sendCageKey, .createInstance, .powerTest,
                 // Both refuse a running instance, so there is no VM for
                 // them to keep awake - see the note in the arm above.
                 .renameInstance, .cloneInstance,
                 // Protecting needs the instance STOPPED - the whole disk
                 // is being copied - so it never starts one either.
                 .protectInstance,
                 // Supplying a key does not start anything - it only makes
                 // a later start possible.
                 .vaultKey,
                 // Writing the marker needs the guest up, and asking for
                 // it is a deliberate request for that to happen - so
                 // unlike the forwards below, this one does start an
                 // instance.
                 //
                 // (Listed in the arm ABOVE this one; see there.)
                 // A forward REQUIRES a running guest and refuses when
                 // there is not one, so it never starts anything.
                 //
                 // It does not keep one awake either, and nothing here
                 // pretends otherwise: traffic through a forward is not
                 // counted as activity, so an idle guest still suspends
                 // underneath it. The listener is taken down when that
                 // happens (`DaemonServer.stopForwards`) so a request is
                 // refused at once rather than hanging, and brought back
                 // when the instance next starts.
                 .forwardAdd, .forwardRemove, .forwardList,
                 // Reading or changing the gates must never boot a VM.
                 // Closing them on a stopped instance is the normal way to
                 // sandbox something *before* it runs; the policy is
                 // persisted and re-applied on its next start.
                 .sandboxGet, .sandboxSet,
                 // Watching a guest must never start one.
                 .trafficSnapshot, .memoryStatus,
                 // Maintenance works on a stopped instance, and the one boot
                 // it does is its own - never an ordinary start.
                 .maintenance,
                 // File operations answer only for an already-running
                 // instance and never start one - see their handlers.
                 .fileList, .fileChmod, .gitQuery,
                 // A permission probe against an address; no instance at all.
                 .localNetworkProbe,
                 // A file pick is a conversation about an instance that is
                 // already running - the app doing the asking is inside it.
                 .filePickDetails, .filePickResult,
                 // Passthrough answers only for an already-running guest:
                 // the attach is collected by a guest-side helper, which
                 // cannot run on a VM that is not up.
                 // Listing and planning read the Mac's registry, and a
                 // detach only ever ends something already running.
                 .usbList, .usbPlan, .usbDetach,
                 // Revoking and asking must never boot a machine; the first
                 // is a teardown and the second is a question.
                 .publicRevoke, .publicStatus, .publicKeys, .publicTailscaleStatus,
                 // Email setup is Mac-side bookkeeping. Adding somebody to
                 // the list does not need the instance: their key is made
                 // when it is published, not when they are listed.
                 .publicNotifySetup, .publicNotifyForget, .publicNotifyTest,
                 .publicNotifyAdd, .publicNotifyRemove, .publicNotifyList,
                 // Making a key writes into the guest, so it needs the
                 // instance up - but it must never start one for that.
                 .publicMakeKey:
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
                 .memoryStatus,
                 // MSL Files fires these while browsing; logging every
                 // directory listing would bury every real event.
                 .fileList, .fileChmod,
                 // The permissions panel checking whether macOS lets the
                 // daemon onto the local network. Not an action on anything.
                 .localNetworkProbe,
                 // Asked once as the picker opens. What the person chose is
                 // logged by `HostOpenService`, which is the part worth
                 // seeing - this is just the handshake.
                 .filePickDetails:
                return nil
            case .gitQuery(let instance, let path, let operation, let argument):
                // Reading a repository is browsing and is not worth a line -
                // and the badge pass runs on every directory opened, so
                // logging it would bury every real event, exactly as logging
                // `fileList` would. The two that write are worth a line.
                switch operation {
                case .inspect, .badges:
                    return nil
                case .initialise:
                    return "created a git repository in \(path) on '\(instance)'"
                case .setOrigin:
                    return argument.isEmpty
                        ? "removed the git origin of \(path) on '\(instance)'"
                        : "set the git origin of \(path) on '\(instance)' to \(argument)"
                }
            case .maintenance(_, let command):
                // The card polls its status; the actions are worth logging.
                return command == .status ? nil : "Maintenance: \(command.rawValue)"
            case .filePickResult(_, let paths, let cancelled):
                return cancelled ? "File dialog cancelled" : "Chose \(paths.count) file(s) for Linux"
            case .session(let instance, _, _, _):        return "Shell session opened (\(instance))"
            case .attachSession(let instance, _):         return "Shell session reattached (\(instance))"
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
            case .renameInstance(let instance, let newName): return "\(instance) renamed to \(newName)"
            case .cloneInstance(let instance, let newName):  return "\(newName) cloned from \(instance)"
            case .rewriteIdentityMarker(let instance):
                return "\(instance): provenance marker written again by hand"
            case .protectInstance(let instance, let enable):
                return enable ? "\(instance)'s disk moved into an encrypted container"
                              : "\(instance)'s disk moved out of its container"
            case .vaultKey(let instance, let action, _):
                // The passphrase is deliberately absent from this string:
                // it is what the activity monitor records.
                return "\(instance): container key \(action)"
            case .forwardAdd(let instance, let hostPort, let guestPort, _):
                return "localhost:\(hostPort) forwarded to \(instance):\(guestPort)"
            case .forwardRemove(let hostPort):              return "localhost:\(hostPort) no longer forwarded"
            case .forwardList:                              return nil
            case .powerTest(let event):                   return "Power test: \(event)"
            case .usbList, .usbPlan:                      return nil
            case .usbAttach(let instance, let device, _):  return "USB \(device) attached to \(instance)"
            case .usbRelay(let instance, let device):      return "USB \(device) captured for \(instance)"
            case .usbDetach(let instance, let device):     return "USB \(device) detached from \(instance)"
            case .publicExpose(let instance, _):           return "\(instance) published beyond this Mac"
            case .publicRevoke(let instance):              return "\(instance) no longer published"
            case .publicStatus, .publicKeys, .publicNotifyList, .publicMakeKey,
                 .publicTailscaleStatus: return nil
            case .publicNotifySetup:                       return "email set up"
            case .publicNotifyForget:                      return "email settings removed"
            case .publicNotifyTest(let to):                return "test email sent to \(to)"
            case .publicNotifyAdd(let instance, let email, _):
                return "\(email) will be told where \(instance) is"
            case .publicNotifyRemove(_, let email):        return "\(email) removed"
            case .publicAuthorize(let instance, _, let label):
                return "\(label) can now reach \(instance)"
            case .publicDeauthorize(let instance, _):      return "key removed from \(instance)"
            case .sandboxSet(_, let token):               return "Sandbox gates set to \(token)"
            }
        }

        /// Which instance the monitor should file this under, if any.
        public var monitorInstance: String? {
            switch self {
            case .attachSession(let instance, _),
                 .session(let instance, _, _, _),
                 .suspend(let instance), .resume(let instance), .hibernate(let instance),
                 .shutdown(let instance), .status(let instance), .remove(let instance, _),
                 .sessionEnded(let instance), .startGui(let instance),
                 .startNativeGui(let instance), .startCageView(let instance),
                 .startCageBridge(let instance, _), .startCageInputBridge(let instance),
                 .sendCageKey(let instance, _, _), .snapshotSave(let instance, _),
                 .snapshotRestore(let instance, _), .snapshotList(let instance),
                 .createInstance(let instance, _), .sandboxGet(let instance),
                 .sandboxSet(let instance, _), .trafficSnapshot(let instance, _),
                 .memoryStatus(let instance), .maintenance(let instance, _),
                 // Filed under the instance that already exists - the one
                 // being renamed, or the one being copied from. The new
                 // name has no history to file anything under yet.
                 .renameInstance(let instance, _), .cloneInstance(let instance, _),
                 .forwardAdd(let instance, _, _, _), .forwardList(let instance),
                 .rewriteIdentityMarker(let instance),
                 .protectInstance(let instance, _),
                 .vaultKey(let instance, _, _):
                return instance
            case .localNetworkProbe:
                return nil
            case .fileList(let instance, _), .fileChmod(let instance, _, _),
                 .gitQuery(let instance, _, _, _),
                 .usbAttach(let instance, _, _), .usbRelay(let instance, _),
                 .usbDetach(let instance, _), .publicExpose(let instance, _),
                 .publicRevoke(let instance), .publicStatus(let instance),
                 .publicAuthorize(let instance, _, _), .publicDeauthorize(let instance, _),
                 .publicKeys(let instance), .publicNotifyAdd(let instance, _, _),
                 .publicNotifyRemove(let instance, _), .publicNotifyList(let instance):
                return instance
            case .filePickDetails, .filePickResult:
                // The token names the pick, not an instance; the instance is
                // known only to `PendingFilePicks`, and the pick itself is
                // filed by `HostOpenService` against the right one.
                return nil
            case .instanceList, .instanceDetails, .powerTest, .removeDistro,
                 .usbList, .usbPlan,
                 // A host port is unique across this Mac, so closing one
                 // names no instance - which is also why `msl unforward`
                 // takes just the port.
                 .forwardRemove,
                 // Email setup is about this Mac, not about one instance.
                 .publicNotifySetup, .publicNotifyForget, .publicNotifyTest,
                 .publicMakeKey, .publicTailscaleStatus:
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
            case .attachSession(let instance, let port): line = "ATTACH \(instance) \(port)"
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
            case .renameInstance(let instance, let newName): line = "RENAME \(instance) \(newName)"
            case .cloneInstance(let instance, let newName): line = "CLONE \(instance) \(newName)"
            case .rewriteIdentityMarker(let instance): line = "IDENTITY_REMARK \(instance)"
            case .protectInstance(let instance, let enable):
                line = "PROTECT \(instance) \(enable ? "ON" : "OFF")"
            case .vaultKey(let instance, let action, let passphrase):
                line = "VAULT_KEY \(instance) \(action) \(passphrase)"
            case .forwardAdd(let instance, let hostPort, let guestPort, let viaSSH):
                line = "FORWARD_ADD \(instance) \(hostPort) \(guestPort) \(viaSSH ? "SSH" : "DIRECT")"
            case .forwardRemove(let hostPort): line = "FORWARD_REMOVE \(hostPort)"
            case .forwardList(let instance): line = "FORWARD_LIST \(instance)"
            case .instanceDetails: line = "INSTANCE_DETAILS"
            case .filePickDetails(let token): line = "FILE_PICK_DETAILS \(token)"
            case .filePickResult(let token, let paths, let cancelled):
                line = (["FILE_PICK_RESULT", token, cancelled ? "CANCELLED" : "PICKED"] + paths)
                    .joined(separator: " ")
            case .powerTest(let event): line = "POWER_TEST \(event)"
            case .sandboxGet(let instance): line = "SANDBOX GET \(instance)"
            case .sandboxSet(let instance, let token): line = "SANDBOX SET \(instance) \(token)"
            case .trafficSnapshot(let instance, let procs): line = "TRAFFIC \(instance) \(procs ? 1 : 0)"
            case .memoryStatus(let instance): line = "MEMORY \(instance)"
            case .usbList: line = "USB_LIST"
            case .usbAttach(let instance, let device, let capture):
                line = "USB_ATTACH \(instance) \(device) \(capture ? "CAPTURE" : "SHARE")"
            case .usbPlan(let device): line = "USB_PLAN \(device)"
            case .publicExpose(let instance, let backend): line = "PUBLIC_EXPOSE \(instance) \(backend)"
            case .publicRevoke(let instance): line = "PUBLIC_REVOKE \(instance)"
            case .publicStatus(let instance): line = "PUBLIC_STATUS \(instance)"
            case .publicAuthorize(let instance, let key, let label):
                line = "PUBLIC_AUTHORIZE \(instance) \(label) \(key)"
            case .publicDeauthorize(let instance, let match):
                line = "PUBLIC_DEAUTHORIZE \(instance) \(match)"
            case .publicKeys(let instance): line = "PUBLIC_KEYS \(instance)"
            // `from` goes last: it may be `MSL <a@b.com>`, which contains a
            // space, and the wire format splits on spaces.
            case .publicNotifySetup(let apiKey, let replyTo, let from):
                line = "PUBLIC_NOTIFY_SETUP \(apiKey) \(replyTo.isEmpty ? "-" : replyTo) \(from)"
            case .publicNotifyForget: line = "PUBLIC_NOTIFY_FORGET"
            case .publicNotifyTest(let to): line = "PUBLIC_NOTIFY_TEST \(to)"
            case .publicNotifyAdd(let instance, let email, let label):
                line = "PUBLIC_NOTIFY_ADD \(instance) \(email) \(label)"
            case .publicNotifyRemove(let instance, let email):
                line = "PUBLIC_NOTIFY_REMOVE \(instance) \(email)"
            case .publicNotifyList(let instance): line = "PUBLIC_NOTIFY_LIST \(instance)"
            case .publicMakeKey(let instance, let label):
                line = "PUBLIC_MAKE_KEY \(instance) \(label)"
            case .publicTailscaleStatus: line = "PUBLIC_TAILSCALE_STATUS"
            case .usbRelay(let instance, let device): line = "USB_RELAY \(instance) \(device)"
            case .usbDetach(let instance, let device): line = "USB_DETACH \(instance) \(device)"
            case .maintenance(let instance, let command): line = "MAINTENANCE \(instance) \(command.rawValue)"
            case .fileList(let instance, let guestPath):
                line = "FILE_LIST \(instance) \(Data(guestPath.utf8).base64EncodedString())"
            case .localNetworkProbe(let host):
                line = "LOCAL_NETWORK_PROBE \(Data(host.utf8).base64EncodedString())"
            case .fileChmod(let instance, let guestPath, let mode):
                line = "FILE_CHMOD \(instance) \(Data(guestPath.utf8).base64EncodedString()) \(mode)"
            case .gitQuery(let instance, let guestPath, let operation, let argument):
                // A fourth field only when there is one, so a three-field
                // request stays exactly what it was.
                let extra = argument.isEmpty
                    ? "" : " " + Data(argument.utf8).base64EncodedString()
                line = "GIT_QUERY \(instance) \(Data(guestPath.utf8).base64EncodedString()) "
                     + operation.rawValue + extra
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
            case "ATTACH":
                guard rest.count == 2, let port = UInt32(rest[1]) else { return nil }
                return .attachSession(instance: rest[0], port: port)
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
            case "USB_LIST":
                return .usbList
            case "USB_ATTACH":
                guard rest.count == 3 else { return nil }
                return .usbAttach(instance: rest[0], device: rest[1],
                                  capture: rest[2].uppercased() == "CAPTURE")
            case "PUBLIC_EXPOSE":
                guard rest.count == 2 else { return nil }
                return .publicExpose(instance: rest[0], backend: rest[1])
            case "PUBLIC_REVOKE":
                guard rest.count == 1 else { return nil }
                return .publicRevoke(instance: rest[0])
            case "PUBLIC_AUTHORIZE":
                // The key itself contains spaces, so it is the remainder of
                // the line rather than one field.
                guard rest.count >= 3 else { return nil }
                return .publicAuthorize(instance: rest[0], key: rest.dropFirst(2).joined(separator: " "),
                                        label: rest[1])
            case "PUBLIC_DEAUTHORIZE":
                guard rest.count >= 2 else { return nil }
                return .publicDeauthorize(instance: rest[0], match: rest.dropFirst().joined(separator: " "))
            case "PUBLIC_NOTIFY_SETUP":
                guard rest.count >= 3 else { return nil }
                let replyTo = rest[1] == "-" ? "" : rest[1]
                return .publicNotifySetup(apiKey: rest[0], replyTo: replyTo,
                                          from: rest.dropFirst(2).joined(separator: " "))
            case "PUBLIC_NOTIFY_FORGET":
                return .publicNotifyForget
            case "PUBLIC_NOTIFY_TEST":
                guard rest.count == 1 else { return nil }
                return .publicNotifyTest(to: rest[0])
            case "PUBLIC_NOTIFY_ADD":
                guard rest.count >= 2 else { return nil }
                return .publicNotifyAdd(instance: rest[0], email: rest[1],
                                        label: rest.count > 2 ? rest.dropFirst(2).joined(separator: " ") : rest[1])
            case "PUBLIC_NOTIFY_REMOVE":
                guard rest.count == 2 else { return nil }
                return .publicNotifyRemove(instance: rest[0], email: rest[1])
            case "PUBLIC_TAILSCALE_STATUS":
                return .publicTailscaleStatus
            case "PUBLIC_MAKE_KEY":
                guard rest.count >= 2 else { return nil }
                return .publicMakeKey(instance: rest[0],
                                      label: rest.dropFirst().joined(separator: " "))
            case "PUBLIC_NOTIFY_LIST":
                guard rest.count == 1 else { return nil }
                return .publicNotifyList(instance: rest[0])
            case "PUBLIC_KEYS":
                guard rest.count == 1 else { return nil }
                return .publicKeys(instance: rest[0])
            case "PUBLIC_STATUS":
                guard rest.count == 1 else { return nil }
                return .publicStatus(instance: rest[0])
            case "USB_PLAN":
                guard rest.count == 1 else { return nil }
                return .usbPlan(device: rest[0])
            case "USB_RELAY":
                guard rest.count == 2 else { return nil }
                return .usbRelay(instance: rest[0], device: rest[1])
            case "USB_DETACH":
                guard rest.count == 2 else { return nil }
                return .usbDetach(instance: rest[0], device: rest[1])
            case "INSTANCE_DETAILS":
                return .instanceDetails
            case "FILE_PICK_DETAILS":
                guard rest.count == 1 else { return nil }
                return .filePickDetails(token: rest[0])
            case "FILE_PICK_RESULT":
                guard rest.count >= 2 else { return nil }
                let cancelled = rest[1] == "CANCELLED"
                return .filePickResult(token: rest[0],
                                       encodedPaths: Array(rest.dropFirst(2)),
                                       cancelled: cancelled)
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
            case "FILE_LIST":
                guard rest.count == 2, let path = DaemonProtocol.decodeBase64Path(rest[1]) else { return nil }
                return .fileList(instance: rest[0], guestPath: path)
            case "LOCAL_NETWORK_PROBE":
                guard rest.count == 1, let host = DaemonProtocol.decodeBase64Path(rest[0]) else { return nil }
                return .localNetworkProbe(host: host)
            case "GIT_QUERY":
                guard rest.count == 3 || rest.count == 4,
                      let path = DaemonProtocol.decodeBase64Path(rest[1]),
                      let operation = GitOperation(rawValue: rest[2]) else { return nil }
                let argument = rest.count == 4
                    ? (DaemonProtocol.decodeBase64Path(rest[3]) ?? "") : ""
                return .gitQuery(instance: rest[0], guestPath: path,
                                 operation: operation, argument: argument)
            case "FILE_CHMOD":
                guard rest.count == 3, let path = DaemonProtocol.decodeBase64Path(rest[1]),
                      let mode = UInt32(rest[2]) else { return nil }
                return .fileChmod(instance: rest[0], guestPath: path, mode: mode)
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
            case "VAULT_KEY":
                // The passphrase is the REST of the line, so one
                // containing spaces survives - and `lock` carries none.
                guard rest.count >= 2, InstanceRegistry.isValidName(rest[0]),
                      ["unlock", "lock", "adopt", "status"].contains(rest[1].lowercased())
                else { return nil }
                return .vaultKey(instance: rest[0], action: rest[1].lowercased(),
                                 passphrase: rest.dropFirst(2).joined(separator: " "))
            case "PROTECT":
                guard rest.count == 2, InstanceRegistry.isValidName(rest[0]),
                      ["ON", "OFF"].contains(rest[1].uppercased()) else { return nil }
                return .protectInstance(instance: rest[0], enable: rest[1].uppercased() == "ON")
            case "IDENTITY_REMARK":
                guard rest.count == 1, InstanceRegistry.isValidName(rest[0]) else { return nil }
                return .rewriteIdentityMarker(instance: rest[0])
            case "FORWARD_ADD":
                // Ports parsed here, so a request naming something that is
                // not a port fails to decode rather than reaching the
                // handler as a zero - which `bind` reads as "any free
                // port" and would land somewhere nobody could predict.
                guard rest.count == 4,
                      let hostPort = UInt16(rest[1]), hostPort > 0,
                      let guestPort = UInt16(rest[2]), guestPort > 0,
                      InstanceRegistry.isValidName(rest[0]) else { return nil }
                return .forwardAdd(instance: rest[0], hostPort: hostPort,
                                   guestPort: guestPort, viaSSH: rest[3].uppercased() == "SSH")
            case "FORWARD_REMOVE":
                guard rest.count == 1, let hostPort = UInt16(rest[0]), hostPort > 0 else { return nil }
                return .forwardRemove(hostPort: hostPort)
            case "FORWARD_LIST":
                guard rest.count == 1 else { return nil }
                return .forwardList(instance: rest[0])
            case "RENAME", "CLONE":
                // Both names checked at parse time. These become file and
                // directory components in a dozen places
                // (`InstanceStateTransfer`), and a name that cannot be one
                // must be rejected before any of them is touched - the
                // reason `isValidName` exists at all is three junk entries
                // (`--`, `start`, `--shutdown`) that CLI flags registered.
                guard rest.count == 2,
                      InstanceRegistry.isValidName(rest[0]),
                      InstanceRegistry.isValidName(rest[1]) else { return nil }
                return command.uppercased() == "RENAME"
                    ? .renameInstance(instance: rest[0], newName: rest[1])
                    : .cloneInstance(instance: rest[0], newName: rest[1])
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
        /// One of each case, with placeholder payloads, so tests can check
        /// that MSLAP's mapping covers the whole protocol.
        ///
        /// Hand-maintained because Swift cannot enumerate cases with
        /// associated values - but `MSLAPEnforcement.requirement` has no
        /// `default`, so a NEW case breaks the build there first and this
        /// list is updated in the same change.
        public static var everyCaseForAudit: [ControlRequest] {
            [
                .session(instance: "i", rows: 1, cols: 1),
                .attachSession(instance: "i", port: 1),
                .suspend(instance: "i"), .resume(instance: "i"),
                .hibernate(instance: "i"), .shutdown(instance: "i"),
                .snapshotSave(instance: "i", name: "n"),
                .snapshotRestore(instance: "i", name: "n"),
                .snapshotList(instance: "i"),
                .status(instance: "i"), .instanceList, .instanceDetails,
                .remove(instance: "i"), .removeDistro(distro: .alpine),
                .sessionEnded(instance: "i"),
                .startGui(instance: "i"), .startNativeGui(instance: "i"),
                .startCageBridge(instance: "i", maxFrames: 1),
                .startCageInputBridge(instance: "i"),
                .sendCageKey(instance: "i", keycode: 1, pressed: true),
                .startCageView(instance: "i"),
                // BOTH kinds, for the same reason as `publicExpose` below:
                // the mapping branches on whether the distro is a custom
                // image, and a published distro alone would leave
                // `distro.custom` looking unreachable to the audit.
                .createInstance(instance: "i", distro: .alpine),
                .createInstance(instance: "i", distro: .custom("slug")),
                .renameInstance(instance: "i", newName: "j"),
                .cloneInstance(instance: "i", newName: "j"),
                .forwardAdd(instance: "i", hostPort: 8080, guestPort: 3000, viaSSH: false),
                .forwardRemove(hostPort: 8080),
                .forwardList(instance: "i"),
                .rewriteIdentityMarker(instance: "i"),
                // BOTH directions: the mapping branches on `enable`, and
                // one alone would leave a capability looking unreachable
                // to the catalogue audit.
                .protectInstance(instance: "i", enable: true),
                .protectInstance(instance: "i", enable: false),
                .vaultKey(instance: "i", action: "unlock", passphrase: "p"),
                .vaultKey(instance: "i", action: "lock", passphrase: ""),
                .vaultKey(instance: "i", action: "adopt", passphrase: "p"),
                .filePickDetails(token: "t"),
                .filePickResult(token: "t", encodedPaths: [], cancelled: false),
                .powerTest(event: "e"),
                .sandboxGet(instance: "i"), .sandboxSet(instance: "i", token: "t"),
                .trafficSnapshot(instance: "i", attributeProcesses: false),
                .memoryStatus(instance: "i"),
                .fileList(instance: "i", guestPath: "/"),
                .gitQuery(instance: "i", guestPath: "/", operation: .inspect),
                .gitQuery(instance: "i", guestPath: "/", operation: .initialise),
                .gitQuery(instance: "i", guestPath: "/", operation: .badges),
                .localNetworkProbe(host: "192.168.64.2"),
                .gitQuery(instance: "i", guestPath: "/", operation: .setOrigin,
                          argument: "https://example.com/a.git"),
                .fileChmod(instance: "i", guestPath: "/", mode: 0),
                .usbList, .usbAttach(instance: "i", device: "d", capture: false),
                .usbPlan(device: "d"), .usbRelay(instance: "i", device: "d"),
                .usbDetach(instance: "i", device: "d"),
                // BOTH backends: the mapping branches on this string, so
                // one of them alone would leave a capability looking
                // unreachable and the catalogue audit would reject it.
                .publicExpose(instance: "i", backend: "relay"),
                .publicExpose(instance: "i", backend: "self-hosted"),
                .publicRevoke(instance: "i"), .publicStatus(instance: "i"),
                .publicAuthorize(instance: "i", key: "k", label: "l"),
                .publicDeauthorize(instance: "i", match: "m"),
                .publicKeys(instance: "i"),
                .publicNotifySetup(apiKey: "k", replyTo: "r", from: "f"),
                .publicNotifyForget, .publicNotifyTest(to: "t"),
                .publicNotifyAdd(instance: "i", email: "e", label: "l"),
                .publicNotifyRemove(instance: "i", email: "e"),
                .publicNotifyList(instance: "i"),
                .publicMakeKey(instance: "i", label: "l"),
                .publicTailscaleStatus,
            ]
        }

    }

    /// Decodes a base64 path token back to a UTF-8 path, rejecting anything
    /// that isn't valid base64 or valid UTF-8 - a malformed request must fail
    /// to parse, not decode to garbage.
    private static func decodeBase64Path(_ token: String) -> String? {
        guard let data = Data(base64Encoded: token),
              let path = String(data: data, encoding: .utf8) else { return nil }
        return path
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
