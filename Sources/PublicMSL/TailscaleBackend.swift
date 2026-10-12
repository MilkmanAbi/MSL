// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Darwin
import Foundation

/// Publishes an instance across a Tailscale network.
///
/// ## Why this is the nicest of the three
///
/// The address never changes, nothing expires, there is no relay in the
/// middle and no domain to own. The trade is that it only reaches machines
/// **on your tailnet** - your own laptop, your phone, a colleague you have
/// invited - so it is not the one for handing an address to a stranger.
/// For "my own machines, always", it is better than both the others.
///
/// ## How it works, and why there is a forwarder
///
/// Tailscale gives the *Mac* a stable name. The guest is on the Mac's own
/// virtual network (192.168.64.x), which nothing else on the tailnet can
/// reach - so something has to join the two.
///
/// `tailscale serve --tcp` looks like the answer and is not: it forwards
/// only to `localhost`, so it cannot point at the guest. Advertising the
/// VM subnet as a route works but needs approval in the admin console and
/// `--accept-routes` on every client, which is a lot to ask for one SSH
/// port.
///
/// So MSL listens on a port of its own and forwards it to the guest. Any
/// machine on the tailnet connects to `<this-mac>.<tailnet>.ts.net:<port>`
/// and lands in the instance. Nothing is installed in the guest, nothing is
/// configured in Tailscale, and the forwarder is plain sockets.
public struct TailscaleBackend: PublicBackend {
    public let identifier = "tailscale"
    public var displayName: String { "Tailscale (your own machines)" }
    public var requirement: String? {
        TailscaleCLI.find() == nil ? "Tailscale, from tailscale.com/download" : nil
    }

    /// The port MSL listens on. Fixed, because the point of this backend is
    /// an address that does not move.
    public let port: UInt16

    public init(port: UInt16 = 2222) {
        self.port = port
    }

    public var policyToken: String { "tailscale:\(port)" }

    public static func fromPolicyToken(_ token: String) -> TailscaleBackend? {
        let parts = token.split(separator: ":").map(String.init)
        guard parts.first == "tailscale" else { return nil }
        return TailscaleBackend(port: parts.count > 1 ? UInt16(parts[1]) ?? 2222 : 2222)
    }

    public func expose(guestHost: String, guestPort: UInt16, user: String,
                       identityFile: String,
                       log: @escaping @Sendable (String) -> Void) throws -> PublicTunnel {
        guard let cli = TailscaleCLI.find() else {
            throw PublicExposureError.backendUnavailable(
                "Publishing over Tailscale",
                requirement: "the Tailscale app, from tailscale.com/download")
        }
        guard let name = TailscaleCLI.machineName(cli: cli, log: log) else {
            throw PublicExposureError.backendUnavailable(
                "Publishing over Tailscale",
                requirement: "Tailscale to be signed in - open it, connect, and try again")
        }
        log("using \(cli); this Mac is \(name) on your tailnet")

        let forwarder = PortForwarder(listenPort: port, targetHost: guestHost,
                                      targetPort: guestPort, log: log)
        do {
            try forwarder.start()
        } catch {
            throw PublicExposureError.relayRefused(
                "couldn't listen on port \(port): \(error). Something else may be using it - "
                + "publish again with a different port.")
        }
        log("listening on \(name):\(port)")
        return PublicTunnel(
            endpoint: PublicEndpoint(host: name, port: port, user: user,
                                     identityFile: identityFile, expires: nil,
                                     backend: identifier),
            process: nil,
            keepAlive: forwarder,
            onEnd: { forwarder.stop() })
    }
}

/// Finding and asking the Tailscale command line tool.
public enum TailscaleCLI {
    /// Where it lives, in the order worth trying.
    ///
    /// The App Store build keeps it inside the bundle rather than on PATH,
    /// which is why looking it up with `which` alone finds nothing on a
    /// perfectly working install.
    /// **The real command line tool first.**
    /// `/Applications/Tailscale.app/Contents/MacOS/Tailscale` is the GUI
    /// application's own executable; it answers `status --json` when run
    /// from a terminal, which makes it look like the right thing to use.
    /// The symlink the app installs is the actual CLI, so that is tried
    /// first and the bundle is the fallback for an install that has not
    /// made one.
    static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// What MSL can tell the user about their tailnet.
    ///
    /// Deliberately more than "is it installed": the useful question is
    /// *which of my machines could reach this*, and Tailscale already knows
    /// the answer. Showing it turns an abstract setting into a list of
    /// computers somebody recognises.
    public struct Status: Sendable {
        public enum State: String, Sendable {
            /// No Tailscale on this Mac at all.
            case missing
            /// Installed, but not signed in - a different problem with a
            /// different fix, so it gets its own answer.
            case signedOut
            case running
        }

        public var state: State
        /// This Mac's name on the tailnet.
        public var selfName: String
        /// The other machines on it, nearest thing to "who can reach this".
        public var peers: [Peer]

        public struct Peer: Sendable, Equatable {
            public var name: String
            public var system: String
            public var online: Bool
        }
    }

    /// Reads the whole picture in one call.
    public static func status() -> Status {
        guard let cli = find() else {
            return Status(state: .missing, selfName: "", peers: [])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return Status(state: .missing, selfName: "", peers: [])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Status(state: .missing, selfName: "", peers: [])
        }
        let name = trimmed((json["Self"] as? [String: Any])?["DNSName"] as? String ?? "")
        guard (json["BackendState"] as? String) == "Running", !name.isEmpty else {
            return Status(state: .signedOut, selfName: name, peers: [])
        }
        var peers: [Status.Peer] = []
        for (_, value) in (json["Peer"] as? [String: Any]) ?? [:] {
            guard let peer = value as? [String: Any] else { continue }
            let peerName = trimmed(peer["DNSName"] as? String ?? "")
            guard !peerName.isEmpty else { continue }
            peers.append(.init(name: peerName,
                               system: peer["OS"] as? String ?? "",
                               online: peer["Online"] as? Bool ?? false))
        }
        // Online first, then by name: the machine somebody is about to try
        // from is almost certainly one that is on right now.
        peers.sort { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        return Status(state: .running, selfName: name, peers: peers)
    }

    /// Tailscale reports names with a trailing dot, which is correct DNS
    /// and looks like a typo in a command somebody has to read.
    static func trimmed(_ value: String) -> String {
        value.hasSuffix(".") ? String(value.dropLast()) : value
    }

    public static func find() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This Mac's name on the tailnet, or nil when Tailscale is not signed
    /// in - which is a different problem from it not being installed, and
    /// gets a different sentence.
    public static func machineName(cli: String, log: (String) -> Void = { _ in }) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log("couldn't run \(cli): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Logged rather than swallowed: "Tailscale is not signed in" is the
        // same answer for a dozen different reasons, and without this the
        // only way to tell them apart is to guess.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("\(cli) status --json gave \(data.count) bytes that were not JSON "
                + "(exit \(process.terminationStatus))")
            return nil
        }
        guard let backendState = json["BackendState"] as? String else {
            log("no BackendState in the status")
            return nil
        }
        guard backendState == "Running" else {
            log("Tailscale is \(backendState), not Running")
            return nil
        }
        guard let this = json["Self"] as? [String: Any],
              let dnsName = this["DNSName"] as? String, !dnsName.isEmpty else {
            log("Tailscale is running but reports no name for this Mac")
            return nil
        }
        // Tailscale reports it with a trailing dot, which is correct DNS
        // and looks like a typo in a command somebody has to read.
        return trimmed(dnsName)
    }
}
