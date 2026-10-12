// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Reaching a Linux instance from outside the Mac it runs on.
///
/// MSL's ordinary SSH lands on `192.168.64.x`, which exists only on this
/// machine. That is right for almost everything and useless for the thing
/// people keep wanting a Linux VM for: a small always-on server you can
/// reach from a laptop somewhere else.
///
/// ## Why this needs nothing in the guest
///
/// The tunnel runs **on the Mac**, not inside Linux. The relays worth using
/// take an `ssh -R` as their agent, and the Mac already has `ssh` and can
/// already reach the guest's port 22 - so exposing an instance adds no
/// binary to the guest, no package, and no image rebuild. The guest never
/// learns it is reachable.
///
/// That also rules two things out, for a reason worth writing down.
/// Cloudflare Tunnel and Tailscale both need software **on the machine
/// doing the connecting**, which defeats the point: the person being handed
/// an address should be able to type `ssh` and have it work. Only a real
/// TCP endpoint does that.
public struct PublicEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// Who to log in as - the instance's own account.
    public let user: String
    /// The private key this endpoint accepts, which is never the one local
    /// SSH uses. See `PublicKeyPair`.
    public let identityFile: String
    /// When the relay said it would drop this, if it said so at all. A
    /// self-hosted backend has no expiry and leaves it nil.
    public let expires: Date?
    public let backend: String

    public init(host: String, port: UInt16, user: String, identityFile: String,
                expires: Date? = nil, backend: String) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.expires = expires
        self.backend = backend
    }

    /// What somebody actually types. Quoted, because the key path contains
    /// "Application Support".
    public var sshCommand: String {
        // IdentitiesOnly, always - see PublicAccessModel.command for why a
        // missing one looks exactly like a wrong key.
        "ssh -i \"\(identityFile)\" -o IdentitiesOnly=yes -p \(port) \(user)@\(host)"
    }

    public var isExpired: Bool {
        guard let expires else { return false }
        return Date() >= expires
    }
}

/// Somewhere an instance's port 22 can be published.
///
/// Deliberately small: every backend has to do exactly one thing, which is
/// turn "this address and port on the Mac" into "this address and port on
/// the internet", and say when it has.
public protocol PublicBackend: Sendable {
    /// Stable name, stored in the instance's settings and shown in the UI.
    var identifier: String { get }
    var displayName: String { get }
    /// What somebody has to have before this can work at all, or nil when
    /// it needs nothing. Shown instead of an error.
    var requirement: String? { get }

    /// Opens the tunnel. Returns once an endpoint is known, and the handle
    /// keeps it alive until it is cancelled.
    func expose(guestHost: String, guestPort: UInt16, user: String,
                identityFile: String, log: @escaping @Sendable (String) -> Void) throws -> PublicTunnel
}

/// A tunnel that is up. Cancelling it closes the endpoint.
public final class PublicTunnel: @unchecked Sendable {
    public let endpoint: PublicEndpoint
    /// nil when the tunnel is not a child process at all - the Tailscale
    /// backend is a listener this process owns, with nothing to signal.
    private let process: Process?
    private let onEnd: @Sendable () -> Void
    private var cancelled = false
    private let lock = NSLock()

    /// `keepAlive` is held for the tunnel's lifetime and never used: it is
    /// the write end of the agent's stdin, and releasing it would close
    /// that stdin and end the session the relay talks over.
    private let keepAlive: Any?

    public init(endpoint: PublicEndpoint, process: Process?,
                keepAlive: Any? = nil, onEnd: @escaping @Sendable () -> Void = {}) {
        self.endpoint = endpoint
        self.process = process
        self.keepAlive = keepAlive
        self.onEnd = onEnd
    }

    /// Whether it is still carrying traffic.
    ///
    /// With no child process there is nothing to die: the forwarder lives
    /// as long as this handle does, so it is up until it is cancelled.
    public var isRunning: Bool {
        guard let process else {
            lock.lock(); defer { lock.unlock() }
            return !cancelled
        }
        return process.isRunning
    }

    /// The agent's pid, so it can be ended by a later daemon. nil once it
    /// has exited.
    public var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            // SIGTERM, then make sure. An ssh wedged mid-handshake would
            // otherwise keep the relay believing the tunnel is live, and the
            // next attempt would be handed a different address while the old
            // one still pointed here.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        onEnd()
    }
}

public enum PublicExposureError: Error, CustomStringConvertible {
    case noSSHServer
    case instanceNotRunning(String)
    case relayRefused(String)
    /// A server the user owns said no. Worded separately from the relay
    /// case: "the relay refused the tunnel" is confusing about a machine
    /// they administer themselves.
    case serverRefused(String)
    case noEndpointReported(String)
    case backendUnavailable(String, requirement: String)
    /// A stored policy that cannot be honoured exactly. Separate from
    /// `backendUnavailable` because the right response is different: this
    /// one is not retried and not substituted, it is reported.
    case policyUnreadable(String)
    /// The guest still accepts passwords. Never published anyway.
    case hardeningFailed(String)

    public var description: String {
        switch self {
        case .noSSHServer:
            return "this instance has no SSH server, so there is nothing to publish"
        case .instanceNotRunning(let name):
            return "\(name) is not running"
        case .relayRefused(let detail):
            return "the relay refused the tunnel: \(detail)"
        case .serverRefused(let detail):
            return detail
        case .noEndpointReported(let detail):
            return "the relay never said where the tunnel is. \(detail)"
        case .backendUnavailable(let name, let requirement):
            return "\(name) needs \(requirement)"
        case .policyUnreadable(let detail):
            return detail
        case .hardeningFailed(let detail):
            return detail
        }
    }
}
