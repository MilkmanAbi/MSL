// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// A port on this Mac that reaches a port inside a guest.
///
/// What this is for: a development server, a database, a notebook running
/// in Linux, opened from a Mac browser at `localhost:<port>` instead of
/// hunting down the guest's current address. The guest's address moves -
/// it is a DHCP lease - so hard-coding it in a bookmark does not work,
/// which is most of the point.
public struct PortForward: Codable, Equatable, Sendable {
    public var instance: String
    /// On this Mac. Bound to 127.0.0.1 only - see `PortForwarder
    /// .Reachability` for why that is not configurable.
    public var hostPort: UInt16
    public var guestPort: UInt16
    /// How the bytes get in. Recorded because the two have genuinely
    /// different reach and the difference is invisible otherwise.
    public var route: Route
    public var added: Date

    public enum Route: String, Codable, Sendable {
        /// Straight from mslhd to the guest's address on the Mac's NAT.
        ///
        /// Reaches only what the guest has bound on `0.0.0.0`. That is not
        /// a quirk, it is most dev servers' *other* setting: Flask, Vite,
        /// Rails and `manage.py runserver` all bind `127.0.0.1` by default,
        /// and nothing outside the guest can reach a loopback socket.
        case direct
        /// Through the guest's own sshd, which does the loopback connect
        /// from inside (`ssh -L`).
        ///
        /// Reaches everything, including loopback-bound servers, and needs
        /// `msl ssh` to have been set up. **This is the route the
        /// sign-in-browser work concluded was necessary** - see
        /// `msl_signin_browser`, which recorded that a Mac-side forward
        /// cannot reach a guest's 127.0.0.1 listener and that the fix is a
        /// guest-side forwarder. sshd already is one, which is why no image
        /// rebuild and no new guest daemon are involved.
        case viaSSH
    }

    public init(instance: String, hostPort: UInt16, guestPort: UInt16,
                route: Route, added: Date = Date()) {
        self.instance = instance
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.route = route
        self.added = added
    }

    /// `8080:3000` - how the CLI takes it and prints it.
    public var pair: String { "\(hostPort):\(guestPort)" }

    public var description: String {
        "localhost:\(hostPort) -> \(instance):\(guestPort)"
            + (route == .viaSSH ? " (through SSH)" : "")
    }

    /// Parses `8080:3000`, or `3000` meaning the same port both sides.
    public static func parsePair(_ text: String) -> (host: UInt16, guest: UInt16)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        func port(_ value: Substring) -> UInt16? {
            // Explicitly not 0: `bind` reads it as "any free port", so a
            // forward asked for on port 0 would land somewhere nobody
            // could predict and the printed address would be wrong.
            guard let number = UInt16(value), number > 0 else { return nil }
            return number
        }
        switch parts.count {
        case 1: return port(parts[0]).map { ($0, $0) }
        case 2:
            guard let host = port(parts[0]), let guest = port(parts[1]) else { return nil }
            return (host, guest)
        default: return nil
        }
    }

    /// Ports the Mac will not let an unprivileged process bind.
    ///
    /// Said up front rather than reported as a bind failure, because
    /// `errno 13` on port 80 sends people to look at firewalls.
    public static func privilegedPortNote(_ port: UInt16) -> String? {
        port < 1024
            ? "port \(port) is reserved on macOS and MSL cannot bind it without root - "
            + "use something above 1024 (\(port == 80 ? "8080" : "\(UInt16(port) + 8000)"), say)"
            : nil
    }
}

/// The forwards a Mac has, across daemon restarts.
///
/// Persisted for the same reason the sandbox policy is: a forward somebody
/// set up should still be there after a reboot, and rediscovering it from
/// live sockets is impossible once the daemon has been replaced.
public enum PortForwardStore {
    public static var file: URL {
        MSLPaths.appSupport.appendingPathComponent("forwards.json")
    }

    /// The decoder and the encoder have to agree about dates.
    ///
    /// They did not, briefly: `save` set `.iso8601` and `load` used the
    /// default, which expects a number - so every forward written was
    /// unreadable and the file silently decoded as "no forwards at all".
    /// Caught by the round-trip test, which is the only kind that would
    /// have: each half works perfectly on its own.
    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    public static func load(from url: URL = file) -> [PortForward] {
        guard let data = try? Data(contentsOf: url),
              let forwards = try? coder().1.decode([PortForward].self, from: data)
        else { return [] }
        return forwards
    }

    @discardableResult
    public static func save(_ forwards: [PortForward], to url: URL = file) -> Bool {
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        guard let data = try? coder().0.encode(forwards) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func forInstance(_ instance: String, from url: URL = file) -> [PortForward] {
        load(from: url).filter { $0.instance == instance }.sorted { $0.hostPort < $1.hostPort }
    }

    /// Why a forward cannot be added. Nil when it can.
    ///
    /// `existing` must NOT include `forward` itself. **This was a real bug:**
    /// restoring a forward passes the stored list, which already holds that
    /// forward - so the clash check found the forward clashing with its own
    /// record and refused it. Every restore and every
    /// `instanceStarted` failed with "already goes to", which is why
    /// forwards never came back after a stop even though they were still
    /// listed. `withoutSelf(of:in:)` is the filter callers use.
    public static func blocker(for forward: PortForward, existing: [PortForward]) -> String? {
        if let note = PortForward.privilegedPortNote(forward.hostPort) { return note }
        // One listener per host port, whichever instance asked. Letting two
        // instances claim 8080 would mean whichever registered first wins
        // and the second silently does nothing.
        if let clash = existing.first(where: { $0.hostPort == forward.hostPort }) {
            return clash.instance == forward.instance
                ? "localhost:\(forward.hostPort) already goes to \(clash.instance):\(clash.guestPort)"
                : "localhost:\(forward.hostPort) is already forwarded to \(clash.instance) - "
                  + "pick another port on this Mac"
        }
        return nil
    }

    /// Everything recorded EXCEPT `forward`'s own entry, for a clash check
    /// that must not find the forward being restored.
    public static func withoutSelf(of forward: PortForward,
                                   in existing: [PortForward]) -> [PortForward] {
        existing.filter { !($0.hostPort == forward.hostPort && $0.instance == forward.instance) }
    }

    @discardableResult
    public static func add(_ forward: PortForward, to url: URL = file) -> Bool {
        var all = load(from: url)
        guard blocker(for: forward, existing: withoutSelf(of: forward, in: all)) == nil else { return false }
        // Replacing its own record rather than appending a second one.
        all = withoutSelf(of: forward, in: all)
        all.append(forward)
        return save(all, to: url)
    }

    /// Removes one forward by its host port. Returns what was removed.
    @discardableResult
    public static func remove(hostPort: UInt16, instance: String?,
                              from url: URL = file) -> PortForward? {
        var all = load(from: url)
        guard let index = all.firstIndex(where: {
            $0.hostPort == hostPort && (instance == nil || $0.instance == instance)
        }) else { return nil }
        let removed = all.remove(at: index)
        save(all, to: url)
        return removed
    }

    /// Drops every forward belonging to an instance - when it is removed,
    /// and when it is renamed to something else.
    public static func forget(instance: String, from url: URL = file) {
        let all = load(from: url)
        let kept = all.filter { $0.instance != instance }
        guard kept.count != all.count else { return }
        save(kept, to: url)
    }
}
