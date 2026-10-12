// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Publishes an instance through a public SSH relay.
///
/// The relay speaks SSH itself, so the agent is `ssh -R` and the Mac
/// already has everything needed - nothing is installed, no account is
/// made, and the guest is untouched. Verified end to end on 2026-10-04: a
/// stock `ssh` client reached a guest's sshd through
/// `*.run.pinggy-free.link` and logged in as the instance's own account.
///
/// ## What the free tier is and is not
///
/// A free relay gives a **random hostname and a session that expires**, an
/// hour at the time of writing. That is exactly right for "let me show you
/// this" and useless for a machine meant to be reachable while you are
/// asleep - which is what the self-hosted backend is for. The expiry is
/// reported rather than hidden, so nothing silently stops working.
public struct RelayBackend: PublicBackend {
    public let identifier: String
    public let displayName: String
    public var requirement: String? { nil }

    /// Where the relay listens, and what to ask it for.
    let relayHost: String
    let relayPort: UInt16
    /// Pinggy selects the mode by username: `tcp@` for a raw TCP port,
    /// which is what SSH needs. An HTTP tunnel would terminate TLS and
    /// speak HTTP at a client expecting an SSH banner.
    let relayUser: String
    /// How long a free session lasts, when the relay imposes one.
    let sessionLimit: TimeInterval?

    public static let pinggy = RelayBackend(
        identifier: "relay-pinggy", displayName: "Public relay (no account)",
        relayHost: "a.pinggy.io", relayPort: 443, relayUser: "tcp",
        sessionLimit: 60 * 60)

    public static let serveo = RelayBackend(
        identifier: "relay-serveo", displayName: "Public relay (serveo.net)",
        relayHost: "serveo.net", relayPort: 22, relayUser: "",
        sessionLimit: nil)

    public static let all: [RelayBackend] = [.pinggy, .serveo]

    public func expose(guestHost: String, guestPort: UInt16, user: String,
                       identityFile: String,
                       log: @escaping @Sendable (String) -> Void) throws -> PublicTunnel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            // **The user's ~/.ssh stays out of this.** Without `-F
            // /dev/null` ssh reads their config and offers their private
            // keys to a third-party relay - measured, five of them:
            // `Trying private key: /Users/.../id_ed25519`. A config with
            // `ForwardAgent yes` in it would forward their agent there too.
            // It also means "it works" could depend on something peculiar
            // to one Mac.
            "-F", "/dev/null",
            "-o", "IdentityAgent=none",
            "-o", "IdentitiesOnly=yes",
            // The relay's host key changes and is not ours to pin; the
            // tunnel carries SSH inside it, and *that* session is where the
            // host key that matters gets checked. Writing the relay into
            // known_hosts would also mean a scary mismatch every time the
            // relay rotated, which teaches people to ignore the warning.
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            // **Not `BatchMode=yes`.** It looks exactly right for an
            // unattended tunnel and it breaks this one: the relay accepts
            // an *unauthenticated* session, and BatchMode refuses to make
            // one - `Permission denied (publickey,password)`, before the
            // tunnel is ever allocated. Measured both ways against a live
            // relay.
            //
            // `ssh -v` settles what the relay actually wants:
            //
            //   Authentications that can continue: publickey,password
            //   Next authentication method: password
            //   Authenticated to a.pinggy.io using "password".
            //
            // An *empty* password, which it accepts from anyone. So ask for
            // that method only, once, and supply the empty answer through
            // `SSH_ASKPASS` below. `BatchMode=yes` refuses to do it at all
            // (`Permission denied (publickey,password)`), and so do
            // `NumberOfPasswordPrompts=0` and
            // `PreferredAuthentications=none` - all three measured under
            // the daemon's own conditions, no terminal and a pipe for
            // stdin.
            "-o", "PreferredAuthentications=password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ExitOnForwardFailure=yes",
            // A relay that stops answering should fail fast and be
            // re-established, not sit there looking connected.
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // **No `-N`.** It is the obvious flag for a forward-only
            // session, and it is wrong here: the relay announces the
            // address it allocated over the session channel, and `-N` is
            // precisely the flag that declines to open one. With it the
            // tunnel comes up and then sits there having never said where
            // it is - which is how it failed the first time this ran.
            "-p", String(relayPort),
            // Port 0: let the relay choose. Asking for a fixed one fails
            // whenever somebody else already has it.
            "-R", "0:\(guestHost):\(guestPort)",
        ]
        arguments.append(relayUser.isEmpty ? relayHost : "\(relayUser)@\(relayHost)")
        process.arguments = arguments
        // `/usr/bin/true` prints nothing, which *is* the empty password the
        // relay wants, and `REQUIRE=force` makes ssh use it instead of
        // looking for a terminal. Without this ssh hunts for an askpass
        // helper that is not installed and the result depends on whether
        // DISPLAY happens to be set - which, in mslhd, it is.
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = "/usr/bin/true"
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // **A stdin that never reaches EOF.** Without `-N`, ssh opens a
        // session - which is how the relay tells us the address - and that
        // session ends the moment stdin closes. Inherited stdin in a daemon
        // is already closed, and `/dev/null` reaches EOF at once, so either
        // way ssh printed its banner and exited before the relay had
        // allocated anything. A pipe nobody writes to simply stays open.
        let input = Pipe()
        process.standardInput = input
        do { try process.run() } catch {
            throw PublicExposureError.relayRefused(error.localizedDescription)
        }

        // Bounded for real now - see `TunnelOutput`, where the reason the
        // obvious loop around `availableData` is not bounded is written
        // down.
        let reader = TunnelOutput(output)
        let found = reader.read(until: Date().addingTimeInterval(40), process: process,
                                onLine: log) { Self.parseEndpoint($0) }
        guard let endpoint = found else {
            // Terminated *before* the last read, not after: in the quiet
            // failures ssh stays alive, and collecting its output first
            // would wait forever.
            process.terminate()
            let transcript = reader.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.lowercased().contains("permission denied") {
                throw PublicExposureError.relayRefused(
                    "the relay refused the connection: \(transcript.suffix(200))")
            }
            throw PublicExposureError.noEndpointReported(
                transcript.isEmpty ? "it said nothing at all" : String(transcript.suffix(300)))
        }
        // From here nobody is waiting on this pipe, so something has to
        // keep emptying it or ssh will block writing into a full one.
        reader.startDiscarding()
        let expires = sessionLimit.map { Date().addingTimeInterval($0) }
        return PublicTunnel(
            endpoint: PublicEndpoint(
                host: endpoint.host, port: endpoint.port, user: user,
                identityFile: identityFile, expires: expires, backend: identifier),
            process: process,
            // Both held for the tunnel's life: releasing the input pipe
            // closes ssh's stdin and ends the session the relay talks
            // over, and releasing the reader stops the drain.
            keepAlive: [input, reader] as [Any])
    }

    /// Finds `host:port` in whatever the relay printed.
    ///
    /// Relays announce it differently and change their banners, so this
    /// looks for the shape rather than for one relay's exact wording:
    /// an optional `tcp://`, a hostname, a colon, a port.
    static func parseEndpoint(_ text: String) -> (host: String, port: UInt16)? {
        let pattern = #"(?:tcp://)?([a-z0-9][a-z0-9.\-]*\.[a-z]{2,})(?::(\d{2,5}))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // The last match, not the first: a banner often mentions the
        // relay's own address before it allocates yours.
        var found: (String, UInt16)?
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let hostRange = Range(match.range(at: 1), in: text),
                  let portRange = Range(match.range(at: 2), in: text),
                  let port = UInt16(text[portRange]) else { return }
            let host = String(text[hostRange])
            // Not the relay's own front door, which appears in the banner
            // and in the upgrade link.
            guard !host.hasSuffix("pinggy.io"), !host.contains("dashboard"),
                  port != 443, port != 22 else { return }
            found = (host, port)
        }
        guard let found else { return nil }
        return (found.0, found.1)
    }
}
