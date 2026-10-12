// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

/// Runs the port forwards a Mac has asked for, and brings them back after a
/// daemon restart.
///
/// Lives beside `PublicMSLManager` and is shaped like it for the same
/// reasons: the daemon injects what it knows (where a guest is, whether it
/// is running) so the whole path can be exercised without a virtual
/// machine, and the state is persisted so a restart is not a silent loss.
///
/// **The difference from publishing is the direction and the audience.**
/// PublicMSL makes an instance reachable from the internet, with hardened
/// sshd and key-only auth, because strangers can reach it. A forward is for
/// the person sitting at this Mac - loopback only, no authentication of its
/// own, and refused the moment the instance is sandboxed.
public final class ForwardManager: @unchecked Sendable {
    public static let shared = ForwardManager()

    public struct Host: Sendable {
        /// The guest's current address, or nil if it is not running.
        public var guestAddress: @Sendable (String) -> String?
        /// Whether a guest is running at all.
        public var isRunning: @Sendable (String) -> Bool
        /// Brings an instance up, for restoring forwards at startup.
        public var start: @Sendable (String) -> Bool

        public init(guestAddress: @escaping @Sendable (String) -> String?,
                    isRunning: @escaping @Sendable (String) -> Bool,
                    start: @escaping @Sendable (String) -> Bool) {
            self.guestAddress = guestAddress
            self.isRunning = isRunning
            self.start = start
        }
    }

    private let lock = NSLock()
    private var host: Host?
    /// By host port, which is the unique thing about a forward.
    private var active: [UInt16: Running] = [:]

    private struct Running {
        let forward: PortForward
        /// Either a socket relay in this process, or an `ssh -L` child.
        let relay: PortForwarder?
        let process: Process?
    }

    public func configure(host: Host) {
        lock.lock(); self.host = host; lock.unlock()
    }

    public enum ForwardError: Error, CustomStringConvertible {
        case refused(String)
        case notRunning(String)
        case noAddress(String)
        case sandboxed(String)
        case cannotListen(String)
        case sshNotSetUp(String)

        public var description: String {
            switch self {
            case .refused(let why): return why
            case .notRunning(let instance):
                return "\(instance) isn't running - start it first (`msl \(instance) true`)"
            case .noAddress(let instance):
                return "couldn't find \(instance)'s address on the network"
            case .sandboxed(let instance):
                // A forward is a hole in the box by definition, so it is
                // refused rather than quietly made useless. Same rule as
                // `HostOpenService`, which declines every request from a
                // sandboxed instance.
                // Points at the app, because that is where the gates are.
                // The first draft said `msl config`, which shows CPU and
                // memory and cannot touch the sandbox - a refusal naming a
                // command that does not help is worse than one naming none.
                return "\(instance) is sandboxed - a forwarded port would be a way out of the box. "
                     + "Open its network gate in MSL (the instance's Sandbox switch) first."
            case .cannotListen(let why): return why
            case .sshNotSetUp(let instance):
                return "the SSH route needs `msl ssh \(instance)` set up first - it forwards through "
                     + "the guest's own sshd, which is what reaches a server bound to 127.0.0.1"
            }
        }
    }

    // MARK: - Adding

    /// Starts a forward and remembers it.
    ///
    /// `persist` is false when restoring, because the entry is already
    /// there and rewriting it would move its `added` date.
    public func add(_ forward: PortForward, persist: Bool = true,
                    log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        // MSLAP first, before anything is opened or written.
        guard MSLAPGate.allows("network.portForward", instance: forward.instance) else {
            throw ForwardError.refused(
                MSLAPGate.reason("network.portForward", instance: forward.instance)
                ?? "Not allowed by the MSL Admin Portal")
        }
        // **A closed sandbox gate refuses a forward outright.** Letting it
        // through would be a hole in exactly the box the gate exists to
        // draw, and letting it through-but-broken would be worse: a forward
        // that looks established and routes nothing.
        guard SandboxPolicyStore.load(instance: forward.instance).isOpen else {
            throw ForwardError.sandboxed(forward.instance)
        }
        guard let host else { throw ForwardError.notRunning(forward.instance) }
        guard host.isRunning(forward.instance) else {
            throw ForwardError.notRunning(forward.instance)
        }
        guard let address = host.guestAddress(forward.instance) else {
            throw ForwardError.noAddress(forward.instance)
        }
        // The forward's OWN record is excluded. On a restore it is already
        // in the file, and comparing against it made every forward clash
        // with itself - so `restoreAll` and `instanceStarted` both failed
        // with "already goes to" and forwards never came back after a
        // stop, while still being listed as waiting for one.
        //
        // A LIVE clash is the real thing to refuse, and that is `active`,
        // not the file: two records can name the same port across a
        // restart without anything actually listening.
        if let why = PortForwardStore.blocker(
            for: forward, existing: PortForwardStore.withoutSelf(of: forward, in: PortForwardStore.load())) {
            throw ForwardError.cannotListen(why)
        }
        lock.lock()
        let liveClash = active[forward.hostPort].map { $0.forward != forward }
        lock.unlock()
        if liveClash == true {
            throw ForwardError.cannotListen("localhost:\(forward.hostPort) is already in use by another forward")
        }

        let running: Running
        switch forward.route {
        case .direct:
            // Resolved per connection: a guest's DHCP address moves across
            // a reboot of the instance, and a forward that outlived one
            // would point at nothing - or at whichever instance took the
            // lease.
            let instance = forward.instance
            let relay = PortForwarder(
                listenPort: forward.hostPort, targetHost: address,
                targetPort: forward.guestPort,
                reachability: .thisMacOnly,
                resolveHost: { [weak self] in self?.lock.withLock { self?.host }?.guestAddress(instance) },
                log: log)
            do { try relay.start() } catch {
                throw ForwardError.cannotListen("couldn't listen on localhost:\(forward.hostPort) - \(error)")
            }
            running = Running(forward: forward, relay: relay, process: nil)
            // Said once, at the point somebody can act on it. A direct
            // forward reaches only what the guest bound on 0.0.0.0, and
            // most dev servers bind 127.0.0.1 - so the common case fails
            // with a connection reset and no explanation unless this is
            // printed here.
            if !PortForwarder.canReach(host: address, port: forward.guestPort, timeout: 2) {
                log("nothing is listening on \(address):\(forward.guestPort) yet. If your server "
                    + "binds 127.0.0.1 (Flask, Vite, Rails and manage.py all do by default), this "
                    + "route cannot reach it - either start it with --host 0.0.0.0, or use "
                    + "`msl forward \(forward.instance) \(forward.pair) --ssh`, which forwards "
                    + "through the guest's own sshd and reaches loopback.")
            }

        case .viaSSH:
            guard let record = SSHSetup.RecordStore.load(instance: forward.instance) else {
                throw ForwardError.sshNotSetUp(forward.instance)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-N",
                // Both ends explicit. The left 127.0.0.1 keeps the listener
                // on this Mac only; the right one is resolved INSIDE the
                // guest, which is the whole reason this route exists.
                "-L", "127.0.0.1:\(forward.hostPort):127.0.0.1:\(forward.guestPort)",
                // Fail rather than carry on with no forward: a port already
                // taken would otherwise be a tunnel that looks up and
                // routes nothing.
                "-o", "ExitOnForwardFailure=yes",
                // Unattended. Never stop to ask a human anything - mslhd
                // has no terminal to ask from.
                "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=20",
                // **Every option spelled out, not left to `~/.ssh/config`.**
                // The first attempt passed `user@host` and failed with
                // "Host key verification failed": the block SSHSetup writes
                // matches on the ALIAS (`msl-Ubuntu`), so connecting by
                // address skips it, and `BatchMode=yes` then has no way to
                // accept an unknown key. Using the alias would fix that one
                // case and leave this depending on a file the person is
                // free to edit or delete, which a daemon should not do - so
                // the three options that matter are repeated here. They
                // mirror `SSHSetup.configBlock`; see its comment for why a
                // guest's host key is deliberately not pinned (it changes
                // with every rebuild, and pinning it would teach people to
                // ignore the mismatch warning).
                "-i", SSHSetup.privateKeyPath,
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "\(record.user)@\(record.host)",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch {
                throw ForwardError.cannotListen("couldn't start ssh - \(error)")
            }
            running = Running(forward: forward, relay: nil, process: process)
            log("forwarding through \(record.user)@\(record.host) with ssh -L")
            // **Waited for, not assumed.** `ssh -N` is silent when it
            // works AND when it is still negotiating, so reporting success
            // the moment `run()` returns reports a tunnel that is not up
            // yet - the first curl against it is refused and the forward
            // looks broken. `ExitOnForwardFailure` means a real failure
            // exits, so a short poll separates the two.
            var waited = 0
            while waited < 50, process.isRunning,
                  !PortForwarder.canReach(host: "127.0.0.1", port: forward.hostPort, timeout: 1) {
                usleep(200_000)
                waited += 1
            }
            if !process.isRunning {
                throw ForwardError.cannotListen(
                    "ssh exited before the forward came up - check `msl ssh \(forward.instance)` works")
            }
        }

        lock.lock()
        active[forward.hostPort].map { stopRunning($0) }
        active[forward.hostPort] = running
        lock.unlock()

        if persist { PortForwardStore.add(forward) }
        log("localhost:\(forward.hostPort) now reaches \(forward.instance):\(forward.guestPort)")
    }

    // MARK: - Removing

    /// **Never refused by a policy.** Closing a forward reduces what this
    /// Mac exposes, and MSLAP's rule throughout is that the safe direction
    /// is always allowed - otherwise denying `network.portForward` after
    /// somebody opened one would trap it open.
    @discardableResult
    public func remove(hostPort: UInt16, instance: String? = nil) -> PortForward? {
        lock.lock()
        if let running = active[hostPort], instance == nil || running.forward.instance == instance {
            stopRunning(running)
            active.removeValue(forKey: hostPort)
        }
        lock.unlock()
        return PortForwardStore.remove(hostPort: hostPort, instance: instance)
    }

    /// Every forward belonging to an instance - when it stops, is renamed
    /// or is removed. Stops the listeners without forgetting the entries
    /// when `persist` is false, which is what a plain stop wants: the
    /// forward comes back with the instance.
    public func stopAll(instance: String, forget: Bool) {
        lock.lock()
        for (port, running) in active where running.forward.instance == instance {
            stopRunning(running)
            active.removeValue(forKey: port)
        }
        lock.unlock()
        if forget { PortForwardStore.forget(instance: instance) }
    }

    private func stopRunning(_ running: Running) {
        running.relay?.stop()
        if let process = running.process, process.isRunning { process.terminate() }
    }

    /// Which forwards are actually up, as opposed to merely recorded.
    ///
    /// The distinction matters: a recorded forward whose listener died is
    /// exactly the "looks fine and is not" state that
    /// `restorePublishedInstances` exists to avoid, so the CLI shows both.
    public func liveHostPorts() -> Set<UInt16> {
        lock.lock(); defer { lock.unlock() }
        return Set(active.filter { _, running in
            running.process.map(\.isRunning) ?? true
        }.keys)
    }

    // MARK: - Restoring

    /// Brings back every forward recorded for this Mac. Called once at
    /// daemon start, for the same reason published instances are restored:
    /// the file survives a reboot and nothing would read it otherwise, so a
    /// forward somebody relies on would come back dead with no sign of it.
    ///
    /// An instance that is not running is left alone rather than started.
    /// Booting a VM because a port was once forwarded would be a surprising
    /// amount of work for a line in a JSON file - the forward comes up when
    /// the instance does, through `instanceStarted`.
    public func restoreAll(log: @escaping @Sendable (String) -> Void = { _ in }) {
        for forward in PortForwardStore.load() {
            guard host?.isRunning(forward.instance) == true else { continue }
            do {
                try add(forward, persist: false, log: log)
            } catch {
                log("couldn't restore \(forward.description): \(error)")
            }
        }
    }

    /// Starts any forward waiting on this instance. Called when one comes
    /// up, so a forward set up before a reboot works again without anybody
    /// asking twice.
    public func instanceStarted(_ instance: String,
                                log: @escaping @Sendable (String) -> Void = { _ in }) {
        let live = liveHostPorts()
        for forward in PortForwardStore.forInstance(instance) where !live.contains(forward.hostPort) {
            do {
                try add(forward, persist: false, log: log)
            } catch {
                log("couldn't start \(forward.description): \(error)")
            }
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
