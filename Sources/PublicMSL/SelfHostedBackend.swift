// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Publishes an instance through a server you control.
///
/// This is the backend a **mini server** actually wants. A free relay hands
/// out a random hostname and ends the session after an hour; that is fine
/// for showing somebody something and useless for a machine meant to be
/// reachable while you are asleep. Here the address is yours, it does not
/// move, and nothing expires.
///
/// ## What it needs, and what it deliberately does not
///
/// A host you can already `ssh` to. That is the whole requirement - MSL
/// runs `ssh -R` as you, so your own `~/.ssh/config`, your agent and your
/// keys all apply exactly as they do when you type `ssh` yourself. There is
/// no MSL account, no credential for MSL to store, and nothing new to
/// install on either machine.
///
/// The one thing the server has to be told is `GatewayPorts`, and only if
/// the address should answer from anywhere rather than from the server
/// itself. Without it sshd binds the forwarded port to loopback and the
/// tunnel works perfectly while being reachable by nobody - which looks
/// exactly like a firewall problem and is not. `verify` below is what turns
/// that into a sentence instead of a mystery.
public struct SelfHostedBackend: PublicBackend {
    public let identifier = "self-hosted"
    public var displayName: String { "Your own server (\(sshTarget))" }
    public var requirement: String? { nil }

    /// `user@host` or a `~/.ssh/config` alias - whatever you would type.
    public let sshTarget: String
    /// The port on *that* server which will answer. Fixed, because the
    /// point of this backend is an address that does not change.
    public let remotePort: UInt16
    /// The port SSH itself listens on there, when it is not 22.
    public let sshPort: UInt16
    /// The hostname to hand out, when the server is reached by one name and
    /// published under another.
    public let publicHost: String

    public init(sshTarget: String, remotePort: UInt16, sshPort: UInt16 = 22, publicHost: String? = nil) {
        self.sshTarget = sshTarget
        self.remotePort = remotePort
        self.sshPort = sshPort
        self.publicHost = publicHost ?? Self.resolveHostname(sshTarget)
    }

    /// The hostname somebody else can actually reach.
    ///
    /// `sshTarget` may be a `~/.ssh/config` alias - `myvps` standing for
    /// `root@198.51.100.4` - and handing an alias to a colleague gives them
    /// a name that resolves on nobody's machine but this one. `ssh -G` is
    /// ssh's own answer to "what does this expand to", so it agrees with
    /// whatever the tunnel actually connects to.
    static func resolveHostname(_ target: String) -> String {
        let fallback = target.split(separator: "@").last.map(String.init) ?? target
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", target]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("hostname ") {
            let value = line.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return fallback
    }

    /// `self-hosted:user@host:2222` - how the policy file stores it, so a
    /// published instance can be re-opened after a restart with no further
    /// questions.
    /// `self-hosted:<target>:<remote>:<sshPort>:<publicHost>`
    ///
    /// The resolved hostname is stored rather than worked out again on
    /// restore: `ssh -G` reads the user's config, and a config that has
    /// changed since would quietly publish a different address under the
    /// same policy.
    public var policyToken: String {
        "self-hosted:\(sshTarget):\(remotePort):\(sshPort):\(publicHost)"
    }

    public static func fromPolicyToken(_ token: String) -> SelfHostedBackend? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "self-hosted",
              let remote = UInt16(parts[2]), !parts[1].isEmpty else { return nil }
        let ssh = parts.count >= 4 ? UInt16(parts[3]) ?? 22 : 22
        let host = parts.count >= 5 && !parts[4].isEmpty ? parts[4] : nil
        return SelfHostedBackend(sshTarget: parts[1], remotePort: remote, sshPort: ssh, publicHost: host)
    }

    public func expose(guestHost: String, guestPort: UInt16, user: String,
                       identityFile: String,
                       log: @escaping @Sendable (String) -> Void) throws -> PublicTunnel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            // `-N` is right here, unlike the relay: the address is already
            // known, so there is nothing to listen for and no reason to ask
            // the server for a shell.
            "-N",
            // Bind on every interface of the server, not just its loopback.
            // sshd still has the final say - see `GatewayPorts` above - and
            // `verify` reports it when it says no.
            "-R", "0.0.0.0:\(remotePort):\(guestHost):\(guestPort)",
            // Fail rather than carry on with no forward. Without this a
            // port already in use is a tunnel that looks established and
            // routes nothing.
            "-o", "ExitOnForwardFailure=yes",
            // Unattended: never stop to ask a human something.
            "-o", "BatchMode=yes",
            // Notice a dead server in a minute and a half rather than
            // holding a socket open until TCP gives up.
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // The server's host key matters here, unlike the relay's: this
            // is a machine you own and expect to stay the same. A changed
            // key should stop the tunnel, which is what the default does.
            "-o", "ConnectTimeout=20",
            "-p", String(sshPort),
            sshTarget,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input

        do { try process.run() } catch {
            throw PublicExposureError.relayRefused(error.localizedDescription)
        }

        // `ssh -N` says nothing when it works, so success cannot be read
        // off its output. Wait for the forwarded port to answer instead -
        // the only thing that actually proves the tunnel carries traffic.
        let endpoint = PublicEndpoint(host: publicHost, port: remotePort, user: user,
                                      identityFile: identityFile, expires: nil,
                                      backend: identifier)
        log("opening \(sshTarget):\(remotePort) -> \(guestHost):\(guestPort); "
            + "waiting for \(publicHost):\(remotePort) to answer")
        let reader = TunnelOutput(output)
        guard Self.waitForAnswer(host: publicHost, port: remotePort, within: 25,
                                 process: process, reader: reader) else {
            // **Terminate first.** The failure this diagnoses - a server
            // refusing to bind the forwarded port - is one where ssh stays
            // alive and silent, so reading its output before killing it
            // waits forever. That is the whole bug: the diagnostic hung on
            // precisely the case it was written for.
            process.terminate()
            reader.pump()
            throw PublicExposureError.serverRefused(
                Self.explain(reader.transcript, host: publicHost, port: remotePort))
        }
        log("\(publicHost):\(remotePort) answers")
        // Something must keep the pipe empty for the tunnel's whole life.
        reader.startDiscarding()
        return PublicTunnel(endpoint: endpoint, process: process, keepAlive: [input, reader] as [Any])
    }

    /// Whether something on the far side speaks when connected to.
    ///
    /// A plain TCP connect is not enough: sshd bound to the server's
    /// loopback still accepts from the server, and a load balancer or a
    /// parked-domain page will accept from anywhere. Reading the greeting
    /// and checking it begins `SSH-` is what distinguishes "the tunnel
    /// carries traffic" from "something answered".
    static func waitForAnswer(host: String, port: UInt16, within: TimeInterval,
                              process: Process? = nil, reader: TunnelOutput? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            // Kept drained while waiting. What is being waited on is a port,
            // not output - but the output is the only thing that can say
            // *why* when the port never answers, and a pipe nobody reads
            // holds nothing.
            reader?.pump()
            if banner(host: host, port: port)?.hasPrefix("SSH-") == true { return true }
            // An agent that has already exited is never going to start
            // answering, and `ExitOnForwardFailure` makes that the usual
            // way a refused bind shows up. Waiting out the full timeout
            // would just delay the explanation.
            if let process, !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return false
    }

    static func banner(host: String, port: UInt16, timeout: TimeInterval = 5) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else { return nil }
        defer { freeaddrinfo(info) }
        let fd = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// Turns a failure into the sentence that names the actual cause.
    ///
    /// These three account for very nearly every first attempt, and none of
    /// them is guessable from "the tunnel did not come up".
    static func explain(_ transcript: String, host: String, port: UInt16) -> String {
        let text = transcript.lowercased()
        if text.contains("remote port forwarding failed") {
            return """
            \(host) refused to listen on port \(port). Either something is already using it, \
            or sshd there has GatewayPorts off - with it off the port binds to the server's \
            own loopback and answers nobody else. Set `GatewayPorts yes` in its sshd_config, \
            or pick a port nothing is using.
            """
        }
        if text.contains("permission denied") || text.contains("publickey") {
            return "\(host) refused the login. MSL connects as you do - check `ssh \(host)` works first."
        }
        if text.contains("could not resolve") || text.contains("name or service not known") {
            return "\(host) does not resolve from this Mac."
        }
        if port < 1024 {
            return """
            Nothing answered on \(host):\(port). Ports below 1024 need root on the server, \
            and sshd will not bind one for a forward from an ordinary account - try a port \
            above 1024.
            """
        }
        return """
        The tunnel opened but nothing answered on \(host):\(port). Most often that is \
        GatewayPorts being off in the server's sshd_config, or a firewall in front of it. \
        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
        """
    }
}
