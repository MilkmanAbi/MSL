// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

/// What MSL remembers about an instance being published.
///
/// Stored, because an exposure is meant to **survive a restart**: a machine
/// somebody is using as a small server should come back reachable when it
/// comes back, without anybody having to be at the Mac. That is also the
/// dangerous half of the feature, so the record is explicit, per instance,
/// and the app always shows it.
public struct PublicPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var backend: String
    /// The address last handed out. Kept only to show while re-establishing
    /// - a relay hands out a different one each time, so it is history, not
    /// a promise.
    public var lastEndpoint: PublicEndpoint?

    public init(enabled: Bool, backend: String, lastEndpoint: PublicEndpoint? = nil) {
        self.enabled = enabled
        self.backend = backend
        self.lastEndpoint = lastEndpoint
    }
}

public enum PublicPolicyStore {
    static var directory: URL { MSLPaths.appSupport.appendingPathComponent("public") }

    static func file(instance: String) -> URL {
        directory.appendingPathComponent("\(instance).json")
    }

    public static func load(instance: String) -> PublicPolicy? {
        guard let data = try? Data(contentsOf: file(instance: instance)) else { return nil }
        return try? JSONDecoder().decode(PublicPolicy.self, from: data)
    }

    @discardableResult
    public static func save(_ policy: PublicPolicy, instance: String) -> Bool {
        _ = MSLPaths.ensureDirectory(directory)
        guard let data = try? JSONEncoder().encode(policy) else { return false }
        return (try? data.write(to: file(instance: instance), options: .atomic)) != nil
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: file(instance: instance))
    }

    /// Every instance that has asked to be published, for the daemon to
    /// re-establish as instances come up.
    public static func allEnabled() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter { load(instance: $0)?.enabled == true }
    }
}

/// Publishes instances, and keeps them published.
///
/// One of these per daemon. It owns the live tunnels, re-establishes them
/// when a relay drops one, and hands the current endpoint to whoever asks.
public final class PublicMSLManager: @unchecked Sendable {
    public static let shared = PublicMSLManager()

    /// What the manager needs from the rest of MSL, injected so the whole
    /// thing can be tested without a virtual machine.
    public struct Host: Sendable {
        /// The guest's address on the Mac's network, or nil when it is not
        /// running.
        public var guestAddress: @Sendable (String) -> String?
        /// The account SSH should land as.
        public var guestUser: @Sendable (String) -> String
        /// Runs a command in the guest as root, returning its output.
        public var runAsRoot: @Sendable (String, String) -> (exitCode: Int32, output: String)

        public init(guestAddress: @escaping @Sendable (String) -> String?,
                    guestUser: @escaping @Sendable (String) -> String,
                    runAsRoot: @escaping @Sendable (String, String) -> (exitCode: Int32, output: String)) {
            self.guestAddress = guestAddress
            self.guestUser = guestUser
            self.runAsRoot = runAsRoot
        }
    }

    private var storedHost: Host?
    private var host: Host? {
        get { lock.lock(); defer { lock.unlock() }; return storedHost }
    }
    private var tunnels: [String: PublicTunnel] = [:]
    private var watchers: Set<String> = []
    private let lock = NSLock()

    private init() {}

    public func configure(host: Host) {
        lock.lock(); storedHost = host; lock.unlock()
    }

    /// Resolves a stored backend token.
    ///
    /// **Throws rather than falling back.** The first version returned
    /// Pinggy for anything it did not recognise, which meant an instance
    /// published through the user's own server would come back after a
    /// restart published through a public relay instead - a different
    /// address, a stranger's machine in the path, and no indication that
    /// anything had changed. A policy that cannot be honoured exactly is
    /// not honoured at all.
    public static func backend(named identifier: String) throws -> PublicBackend {
        if identifier.hasPrefix("tailscale") {
            guard let backend = TailscaleBackend.fromPolicyToken(identifier) else {
                throw PublicExposureError.policyUnreadable(
                    "this instance is published over Tailscale, but the saved details are "
                    + "unreadable (\(identifier)). Publish it again to fix that.")
            }
            return backend
        }
        if identifier.hasPrefix("self-hosted") {
            guard let backend = SelfHostedBackend.fromPolicyToken(identifier) else {
                throw PublicExposureError.policyUnreadable(
                    "this instance is published through your own server, but the saved "
                    + "details are unreadable (\(identifier)). Publish it again to fix that.")
            }
            return backend
        }
        if let relay = RelayBackend.all.first(where: { $0.identifier == identifier }) {
            return relay
        }
        throw PublicExposureError.policyUnreadable(
            "no way to publish called \(identifier) - this MSL may be older than the setting.")
    }

    public func endpoint(instance: String) -> PublicEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return tunnels[instance]?.endpoint
    }

    public func isPublished(instance: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tunnels[instance]?.isRunning == true
    }

    // MARK: - Publishing

    /// Hardens the guest, then opens the tunnel.
    ///
    /// In that order, always. Publishing a guest that still accepts
    /// passwords would put a brute-force target on the internet, and MSL
    /// would have put it there.
    @discardableResult
    public func expose(instance: String, backend: PublicBackend,
                       persist: Bool = true,
                       log: @escaping @Sendable (String) -> Void = { _ in }) throws -> PublicEndpoint {
        guard let host = self.host else { throw PublicExposureError.instanceNotRunning(instance) }
        guard let address = host.guestAddress(instance) else {
            throw PublicExposureError.instanceNotRunning(instance)
        }
        let user = host.guestUser(instance)

        // nil is fine: the convenience key is for getting in from this
        // Mac, and an instance reached with keys somebody authorized does
        // not need one at all.
        let convenienceKey = PublicKeyPair.ensure(instance: instance)
        log("hardening \(instance)'s SSH server")
        let hardened = host.runAsRoot(instance, PublicHardening.hardenCommand(
            convenienceKey: convenienceKey, user: user))
        guard !hardened.output.contains("MSL_NO_SSHD") else { throw PublicExposureError.noSSHServer }
        guard PublicHardening.passwordsAreOff(hardened.output) else {
            // Refused rather than published anyway. An instance that still
            // takes passwords is one this feature must not put on the
            // internet, and saying so is better than a warning nobody reads.
            throw PublicExposureError.hardeningFailed(
                "couldn't turn password logins off in \(instance), so it will not be published. "
                + "sshd reported: "
                + hardened.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log("password logins are off; opening the tunnel")

        // **Every route needs this, not just Tailscale.** The relay and
        // self-hosted backends have `ssh` do their connecting, and a child
        // of mslhd is attributed to mslhd for Local Network privacy - so
        // being refused the local subnet breaks all three identically.
        // Measured: the same `ssh -R` command reached the guest from a
        // shell and was reset when mslhd ran it.
        //
        // macOS reports the refusal as EHOSTUNREACH, which reads as a
        // routing fault, so this is said plainly at publish time rather
        // than left to be discovered as a connection reset by whoever was
        // sent the address.
        if !PortForwarder.canReach(host: address, port: 22) {
            log("WARNING: macOS is blocking MSL from reaching \(address) on the local network. "
                + "Open System Settings > Privacy & Security > Local Network and turn MSL on, "
                + "then publish again - until then every connection will be refused.")
        }
        // Anything left over from a previous daemon goes first. Otherwise
        // the old tunnel keeps running beside the new one, publishing the
        // same instance at a second address that nothing is tracking.
        if TunnelReaper.reap(instance: instance) {
            log("closed a leftover tunnel for \(instance) first")
        }
        let tunnel = try backend.expose(guestHost: address, guestPort: 22, user: user,
                                        identityFile: PublicKeyPair.privateKeyURL(instance: instance).path,
                                        log: log)
        lock.lock()
        tunnels[instance]?.cancel()
        tunnels[instance] = tunnel
        lock.unlock()
        // Written down so the next daemon can end it even if this one is
        // killed without getting to run anything.
        if let pid = tunnel.processIdentifier { TunnelReaper.record(pid: pid, instance: instance) }

        if persist {
            // The *token*, not the identifier: a self-hosted backend's
            // identifier is just "self-hosted" and says nothing about
            // which server or which port.
            let token = (backend as? SelfHostedBackend)?.policyToken
                ?? (backend as? TailscaleBackend)?.policyToken
                ?? backend.identifier
            PublicPolicyStore.save(
                PublicPolicy(enabled: true, backend: token, lastEndpoint: tunnel.endpoint),
                instance: instance)
        }
        // A published instance that lets the Mac doze off is not
        // published. See `PublicWakefulness` for what this does and does
        // not promise.
        PublicWakefulness.shared.hold(for: instance)
        startWatching(instance: instance, backend: backend, log: log)
        // Last, and never in the way: an address nobody can be told about
        // is still an address that works, so a mail server having a bad day
        // must not turn a successful publish into a failed one.
        notify(instance: instance, endpoint: tunnel.endpoint, host: host, log: log)
        return tunnel.endpoint
    }

    /// Closes the tunnel and undoes the hardening.
    public func revoke(instance: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        lock.lock()
        let tunnel = tunnels.removeValue(forKey: instance)
        watchers.remove(instance)
        let host = storedHost
        lock.unlock()
        tunnel?.cancel()
        // Belt and braces: if this daemon never knew about the tunnel -
        // because a previous one opened it - cancelling our own handle
        // would leave it running.
        TunnelReaper.reap(instance: instance)
        PublicPolicyStore.forget(instance: instance)

        if let host {
            _ = host.runAsRoot(instance, PublicHardening.revokeCommand(user: host.guestUser(instance)))
        }
        PublicKeyPair.remove(instance: instance)
        PublicWakefulness.shared.release(for: instance)
        log("\(instance) is no longer published")
    }

    /// Brings back everything that was published, at daemon start.
    ///
    /// Without this, "persists across restarts" was only half true: the
    /// policy survived, but nothing acted on it until somebody opened a
    /// session - so a Mac that rebooted overnight came back with its
    /// mini server unreachable and no sign of why. `startInstance` is the
    /// daemon's own starter, passed in so this module never has to know how
    /// a VM is booted.
    public func restoreAll(startInstance: @escaping @Sendable (String) -> Bool,
                           log: @escaping @Sendable (String) -> Void = { _ in }) {
        // Before anything else: a tunnel from the daemon that just stopped
        // may still be running, and re-publishing beside it would mean two
        // addresses for one instance with only one of them known.
        TunnelReaper.reapAll(log: log)
        let published = PublicPolicyStore.allEnabled()
        guard !published.isEmpty else { return }
        log("published at last shutdown: \(published.joined(separator: ", "))")
        Thread { [weak self] in
            for instance in published {
                guard let self else { return }
                if self.host?.guestAddress(instance) == nil {
                    log("starting \(instance) because it is published")
                    guard startInstance(instance) else {
                        log("couldn't start \(instance); it stays unpublished for now")
                        continue
                    }
                }
                self.restoreIfEnabled(instance: instance, log: log)
            }
        }.start()
    }

    /// Re-opens whatever was published, for an instance that has just come
    /// up. Called by the daemon when a VM starts.
    public func restoreIfEnabled(instance: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let policy = PublicPolicyStore.load(instance: instance), policy.enabled else { return }
        guard !isPublished(instance: instance) else { return }
        let backend: PublicBackend
        do { backend = try Self.backend(named: policy.backend) } catch {
            log("not publishing \(instance) again: \(error)")
            return
        }
        Thread { [weak self] in
            do {
                let endpoint = try self?.expose(instance: instance, backend: backend, log: log)
                if let endpoint { log("\(instance) is published again at \(endpoint.host):\(endpoint.port)") }
            } catch {
                log("couldn't publish \(instance) again: \(error)")
            }
        }.start()
    }

    /// Emails the roster right now, for somebody added to an instance that
    /// is already published.
    public func notifyNow(instance: String, endpoint: PublicEndpoint,
                          log: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let host = self.host else { return }
        notify(instance: instance, endpoint: endpoint, host: host, log: log)
    }

    /// Tells whoever is on the list where the instance is now.
    ///
    /// Detached, because sending mail is a network round trip and the
    /// person who asked to publish should not wait on somebody else's
    /// inbox.
    private func notify(instance: String, endpoint: PublicEndpoint, host: Host,
                        log: @escaping @Sendable (String) -> Void) {
        guard !NotifyRoster.load(instance: instance).isEmpty else { return }
        guard let mailer = NotifySettings.mailer() else {
            log("people are waiting to be told the address, but no email account is set up "
                + "- run: msl public notify setup")
            return
        }
        let user = host.guestUser(instance)
        Thread {
            let failures = NotifyDispatch.run(
                instance: instance, endpoint: endpoint, senderName: nil,
                authorize: { key, label in
                    host.runAsRoot(instance, PublicHardening.authorizeCommand(
                        publicKey: key, label: label, user: user)).output.contains("MSL_KEY")
                },
                deauthorize: { key in
                    _ = host.runAsRoot(instance, PublicHardening.deauthorizeCommand(
                        matching: key, user: user))
                },
                send: { try mailer.send($0) },
                log: log)
            for failure in failures { log("email problem - \(failure)") }
        }.start()
    }

    /// Watches one tunnel and re-opens it when it drops.
    ///
    /// A free relay ends the session after an hour, and any relay can go
    /// away - so "published" has to mean "kept published", or the feature
    /// works until the first time nobody is looking.
    private func startWatching(instance: String, backend: PublicBackend,
                               log: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard !watchers.contains(instance) else { lock.unlock(); return }
        watchers.insert(instance)
        lock.unlock()

        Thread { [weak self] in
            var backoff: TimeInterval = 2
            while let self {
                Thread.sleep(forTimeInterval: 2)
                self.lock.lock()
                let stillWanted = self.watchers.contains(instance)
                let alive = self.tunnels[instance]?.isRunning == true
                self.lock.unlock()
                guard stillWanted else { return }
                if alive { backoff = 2; continue }
                guard PublicPolicyStore.load(instance: instance)?.enabled == true else { return }
                // The instance has to be up for there to be anything to
                // publish; a paused one is not a failure to retry hard.
                guard self.host?.guestAddress(instance) != nil else {
                    Thread.sleep(forTimeInterval: 10)
                    continue
                }
                log("the tunnel for \(instance) dropped - opening it again")
                do {
                    let endpoint = try self.expose(instance: instance, backend: backend, persist: true, log: log)
                    log("\(instance) is back at \(endpoint.host):\(endpoint.port)")
                    backoff = 2
                } catch {
                    // Backed off, because the usual reason a retry fails is
                    // the instance being down - and hammering a relay while
                    // it is would get the address refused for longer.
                    log("couldn't reopen \(instance): \(error)")
                    Thread.sleep(forTimeInterval: backoff)
                    backoff = min(backoff * 2, 120)
                }
            }
        }.start()
    }
}
