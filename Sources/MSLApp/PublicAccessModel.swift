import AppKit
import Foundation
import MSLCore
import PublicMSL

/// What the app knows about an instance being reachable from outside the
/// Mac.
///
/// Kept beside `AppModel`'s SSH state and shaped the same way, because the
/// card shows the same three honest answers: not set up, working on it, or
/// here is the address. The fourth - published but the tunnel is down right
/// now - is the one this feature cannot do without: a free relay rotates
/// its address roughly hourly, and during that handover the instance *is*
/// published and *is* briefly unreachable. Showing "not published" then
/// would be a lie, and showing the old address a worse one.
@MainActor
final class PublicAccessModel: ObservableObject {

    enum State: Equatable {
        /// Not published, and nothing stored saying it should be.
        case off
        /// Publishing or re-establishing.
        case working(String)
        /// Live, with the address somebody can use.
        case live(Endpoint)
        /// Meant to be published; the tunnel is not up at this moment.
        case pending(reason: String)
        case failed(String)
    }

    struct Endpoint: Equatable {
        var host: String
        var port: UInt16
        var user: String
        var identityFile: String
        /// **An instant, not a countdown.** Held as seconds-remaining it
        /// was frozen at whatever the daemon last said, so a card left open
        /// went on claiming "about 58 more minutes" indefinitely - and
        /// claimed it about an address that had already been replaced.
        var expires: Date?
        var backend: String

        /// **`IdentitiesOnly=yes` is not optional here.**
        ///
        /// Without it, ssh offers every key its agent is holding before the
        /// one named by `-i`. A published instance allows a limited number
        /// of attempts per connection, so on any machine with a populated
        /// agent - a work laptop, a Windows box with Pageant-style setup -
        /// the server hangs up before reaching the right key and reports
        /// `Permission denied (publickey)` about a key it never tried.
        /// Measured: the key was correct and worked from the Mac.
        var command: String {
            // Quoted, because the path can have a space in it.
            "ssh -i \"\(identityFile)\" -o IdentitiesOnly=yes -p \(port) \(user)@\(host)"
        }

        /// The same command for somebody who is not sitting at this Mac.
        ///
        /// The local one names a file at `/Users/Shared/MSL/keys/...`,
        /// which exists on exactly one computer in the world. Sent to a
        /// colleague it reads as an instruction they cannot follow, and the
        /// obvious guess - that they need that exact path - is wrong. So
        /// the shareable form says `path/to/key` and leaves them to put the
        /// key where they like.
        var remoteCommand: String {
            "ssh -i path/to/key -o IdentitiesOnly=yes -p \(port) \(user)@\(host)"
        }

        var address: String { "\(user)@\(host):\(port)" }

        /// Whether a private key is actually on disk for this.
        ///
        /// It lives in the Mac's temporary directory - deliberately, so no
        /// guest can read it - and that directory is cleared on restart. So
        /// the command above can be exactly right and the key gone, and the
        /// card has to say so rather than offer a Copy button for something
        /// that will fail.
        var keyExists: Bool { FileManager.default.fileExists(atPath: identityFile) }

        var expiryNote: String? {
            guard let expires else { return nil }
            let remaining = expires.timeIntervalSinceNow
            guard remaining > 0 else {
                return "This address has run out. MSL is opening a new one."
            }
            let minutes = max(1, Int(remaining / 60))
            return "This address lasts about \(minutes) more minute\(minutes == 1 ? "" : "s"). "
                + "MSL opens a new one automatically, at a new address."
        }

        /// The same endpoint in `PublicMSL`'s own shape, so the shared
        /// instruction text does not need a second copy of this type.
        var asPublicEndpoint: PublicEndpoint {
            PublicEndpoint(host: host, port: port, user: user, identityFile: identityFile,
                           expires: expires, backend: backend)
        }

        /// One block somebody can paste to a colleague.
        ///
        /// Uses `remoteCommand`: this is the text that gets sent, and the
        /// local path in it would be a path on nobody else's machine.
        var shareableSummary: String {
            var lines = ["Host: \(host)", "Port: \(port)", "User: \(user)", "", remoteCommand]
            if expires != nil {
                lines.append("")
                lines.append("Note: this address is temporary and will change.")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct AuthorizedKey: Identifiable, Equatable {
        var fingerprint: String
        var label: String
        var id: String { fingerprint + label }
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var keys: [String: [AuthorizedKey]] = [:]
    @Published var busy: Set<String> = []

    func state(for instance: String) -> State { states[instance] ?? .off }
    func authorizedKeys(for instance: String) -> [AuthorizedKey] { keys[instance] ?? [] }

    /// Asks the daemon where an instance stands. Cheap: no guest round trip.
    func refresh(_ instance: String) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .utility) {
                DaemonClient.send(.publicStatus(instance: instance), timeout: 10)
            }.value
            guard let self else { return }
            self.states[instance] = Self.parse(reply)
        }
    }

    static func parse(_ reply: String?) -> State {
        guard let reply, reply.hasPrefix("OK ") else { return .off }
        let body = String(reply.dropFirst(3))
        if body.hasPrefix("PENDING") {
            return .pending(reason: "The instance is starting, or the address is being renewed.")
        }
        let fields = body.components(separatedBy: "\t")
        guard fields.count >= 6, let port = UInt16(fields[1]) else { return .off }
        return .live(Endpoint(host: fields[0], port: port, user: fields[2],
                              identityFile: fields[3],
                              expires: Int(fields[4]).map { Date().addingTimeInterval(TimeInterval($0)) },
                              backend: fields[5]))
    }

    /// Shows a setup problem on the card without pretending to publish.
    func reportSetupNeeded(_ instance: String, _ message: String) {
        states[instance] = .failed(message)
    }

    func publish(_ instance: String, backend: String = "relay-pinggy") {
        busy.insert(instance)
        states[instance] = .working("Turning off password logins, then opening the tunnel…")
        Task { [weak self] in
            let reply = await Task.detached(priority: .userInitiated) {
                // Generous: hardening is a guest round trip and the relay is
                // a network one. A timeout here would look like a failure
                // while the tunnel actually came up.
                DaemonClient.send(.publicExpose(instance: instance, backend: backend), timeout: 180)
            }.value
            guard let self else { return }
            self.busy.remove(instance)
            if let reply, reply.hasPrefix("OK ") {
                self.states[instance] = Self.parse(reply)
            } else {
                self.states[instance] = .failed(Self.readable(reply))
            }
        }
    }

    func unpublish(_ instance: String) {
        busy.insert(instance)
        states[instance] = .working("Closing the tunnel and putting the SSH server back…")
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicRevoke(instance: instance), timeout: 120)
            }.value
            guard let self else { return }
            self.busy.remove(instance)
            self.states[instance] = .off
        }
    }

    func loadKeys(_ instance: String) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .utility) {
                DaemonClient.send(.publicKeys(instance: instance), timeout: 30)
            }.value
            guard let self else { return }
            guard let reply, reply.hasPrefix("OK ") else { self.keys[instance] = []; return }
            self.keys[instance] = String(reply.dropFirst(3))
                .split(separator: "\n")
                .compactMap { line in
                    let fields = line.components(separatedBy: "\t")
                    guard fields.count >= 2 else { return nil }
                    return AuthorizedKey(fingerprint: fields[0], label: fields[1])
                }
        }
    }

    /// Adds a key somebody pasted. Returns a message to show either way.
    func authorize(_ instance: String, key: String, label: String,
                   completion: @escaping (Bool, String) -> Void) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Caught here rather than sent anywhere: pasting a private key into
        // a box labelled "public key" is the likeliest mistake, and the
        // right response is to say so, not to fail opaquely.
        if trimmed.contains("PRIVATE KEY") {
            completion(false, "That is a private key - keep it where it is. "
                       + "Paste the matching .pub file instead.")
            return
        }
        guard PublicHardeningShim.looksLikeAPublicKey(trimmed) else {
            completion(false, "That does not look like an SSH public key. It should start "
                       + "with ssh-ed25519 or ssh-rsa.")
            return
        }
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let fields = trimmed.split(separator: " ").map(String.init)
            name = fields.count >= 3 ? fields[2...].joined(separator: " ") : "a computer"
        }
        busy.insert(instance)
        Task { [weak self] in
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicAuthorize(instance: instance, key: trimmed, label: name),
                                  timeout: 60)
            }.value
            guard let self else { return }
            self.busy.remove(instance)
            self.loadKeys(instance)
            if let reply, reply.hasPrefix("OK ") {
                completion(true, String(reply.dropFirst(3)))
            } else {
                completion(false, Self.readable(reply))
            }
        }
    }

    func deauthorize(_ instance: String, fingerprintOrLabel: String) {
        busy.insert(instance)
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicDeauthorize(instance: instance, match: fingerprintOrLabel),
                                  timeout: 60)
            }.value
            guard let self else { return }
            self.busy.remove(instance)
            self.loadKeys(instance)
        }
    }

    // MARK: - Emailing the address out

    struct NotifyPerson: Identifiable, Equatable {
        var email: String
        var label: String
        var hasKey: Bool
        var id: String { email }
    }

    struct NotifySetup: Equatable {
        var configured: Bool
        var from: String
        var perDay: Int
    }

    @Published private(set) var notifySetup = NotifySetup(configured: false, from: "", perDay: 3)
    @Published private(set) var notifyPeople: [String: [NotifyPerson]] = [:]

    func people(for instance: String) -> [NotifyPerson] { notifyPeople[instance] ?? [] }

    func loadNotify(_ instance: String) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .utility) {
                DaemonClient.send(.publicNotifyList(instance: instance), timeout: 15)
            }.value
            guard let self, let reply, reply.hasPrefix("OK ") else { return }
            var setup = NotifySetup(configured: false, from: "", perDay: 3)
            var people: [NotifyPerson] = []
            for line in String(reply.dropFirst(3)).split(separator: "\n") {
                let fields = line.components(separatedBy: "\t")
                if fields.first == "CONFIGURED" {
                    setup = NotifySetup(configured: fields.count > 1 && fields[1] == "true",
                                        from: fields.count > 2 ? fields[2] : "",
                                        perDay: fields.count > 3 ? Int(fields[3]) ?? 3 : 3)
                } else if fields.count >= 3 {
                    people.append(NotifyPerson(email: fields[0], label: fields[1],
                                               hasKey: fields[2] == "true"))
                }
            }
            self.notifySetup = setup
            self.notifyPeople[instance] = people
        }
    }

    func saveNotifySetup(apiKey: String, from: String, replyTo: String,
                         instance: String, completion: @escaping (Bool, String) -> Void) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicNotifySetup(apiKey: apiKey, replyTo: replyTo, from: from),
                                  timeout: 30)
            }.value
            guard let self else { return }
            let ok = reply?.hasPrefix("OK ") == true
            self.loadNotify(instance)
            completion(ok, ok ? String(reply!.dropFirst(3)) : Self.readable(reply))
        }
    }

    func sendTestEmail(to address: String, completion: @escaping (Bool, String) -> Void) {
        Task {
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicNotifyTest(to: address), timeout: 90)
            }.value
            let ok = reply?.hasPrefix("OK ") == true
            completion(ok, ok ? "Sent. Check \(address)." : Self.readable(reply))
        }
    }

    func addPerson(_ instance: String, email: String, label: String,
                   completion: @escaping (Bool, String) -> Void) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicNotifyAdd(instance: instance, email: email,
                                                   label: label.isEmpty ? email : label),
                                  timeout: 90)
            }.value
            guard let self else { return }
            self.loadNotify(instance)
            let ok = reply?.hasPrefix("OK ") == true
            completion(ok, ok ? String(reply!.dropFirst(3)) : Self.readable(reply))
        }
    }

    func removePerson(_ instance: String, email: String) {
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicNotifyRemove(instance: instance, email: email), timeout: 30)
            }.value
            self?.loadNotify(instance)
        }
    }

    // MARK: - How people reach it

    /// The three ways, in the order they suit people.
    enum Route: String, CaseIterable, Identifiable {
        case relay, tailscale, ownServer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .relay:     return "Public relay — anyone, no setup"
            case .tailscale: return "Tailscale — your own machines"
            case .ownServer: return "Your own server — a fixed address"
            }
        }

        var explanation: String {
            switch self {
            case .relay:
                return "Works for anybody you send the address to, with nothing to install. "
                     + "The address changes about once an hour."
            case .tailscale:
                return "Reaches machines on your tailnet only, but the address never changes and "
                     + "nothing expires. Needs Tailscale on this Mac and on theirs."
            case .ownServer:
                return "Publishes through a machine you can already ssh to. Fixed address, no "
                     + "expiry, nobody else in the path."
            }
        }
    }

    /// Remembered per instance, because which route suits it is a property
    /// of the machine, not of the app.
    func route(for instance: String) -> Route {
        let stored = UserDefaults.standard.string(forKey: "MSLPublicRoute.\(instance)") ?? ""
        return Route(rawValue: stored) ?? .relay
    }

    func setRoute(_ route: Route, for instance: String) {
        UserDefaults.standard.set(route.rawValue, forKey: "MSLPublicRoute.\(instance)")
        objectWillChange.send()
    }

    func serverTarget(for instance: String) -> String {
        UserDefaults.standard.string(forKey: "MSLPublicServer.\(instance)") ?? ""
    }

    func setServerTarget(_ value: String, for instance: String) {
        UserDefaults.standard.set(value, forKey: "MSLPublicServer.\(instance)")
        objectWillChange.send()
    }

    /// The token the daemon needs for the chosen route.
    func backendToken(for instance: String) -> String {
        switch route(for: instance) {
        case .relay:
            return "relay-pinggy"
        case .tailscale:
            return "tailscale:\(tailscalePort(for: instance))"
        case .ownServer:
            // `user@host:port` - the port is what people connect to there,
            // and is deliberately not guessed.
            let parts = serverTarget(for: instance).split(separator: ":").map(String.init)
            guard parts.count >= 2, let port = UInt16(parts[1]) else { return "" }
            return "self-hosted:\(parts[0]):\(port):22:"
        }
    }

    // MARK: - A key to send by hand

    /// Makes somebody a key and returns everything they need, ready to
    /// paste into a message.
    ///
    /// The counterpart to emailing: emailing needs a domain, and most
    /// people will just send it in a chat.
    func makeShareableKey(_ instance: String, label: String,
                          completion: @escaping (Bool, String) -> Void) {
        Task { [weak self] in
            let reply = await Task.detached(priority: .userInitiated) {
                DaemonClient.send(.publicMakeKey(instance: instance, label: label), timeout: 90)
            }.value
            guard let self else { return }
            guard let reply, reply.hasPrefix("OK ") else {
                completion(false, Self.readable(reply))
                return
            }
            let privateKey = String(reply.dropFirst(3))
            guard case .live(let endpoint) = self.state(for: instance) else {
                completion(false, "Key made, but \(instance) isn't published yet.")
                return
            }
            let file = "msl-\(instance.lowercased())-key"
            let block = """
            Save this as ~/Downloads/\(file), then run:

              chmod 600 ~/Downloads/\(file)
              ssh -i ~/Downloads/\(file) -o IdentitiesOnly=yes -p \(endpoint.port) \(endpoint.user)@\(endpoint.host)

            \(privateKey.trimmingCharacters(in: .whitespacesAndNewlines))
            """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(block, forType: .string)
            completion(true, "Copied. Paste it to \(label) — it has the key and the command.")
        }
    }

    // MARK: - Tailscale

    struct TailnetMachine: Identifiable, Equatable {
        var name: String
        var system: String
        var online: Bool
        var id: String { name }

        /// `abi-surface.tail9f4cc7.ts.net` reads as noise; the first label
        /// is the name somebody actually gave the machine.
        var shortName: String { String(name.split(separator: ".").first ?? "") }
    }

    struct TailnetStatus: Equatable {
        var state: String      // missing | signedOut | running
        var selfName: String
        var machines: [TailnetMachine]

        static let unknown = TailnetStatus(state: "missing", selfName: "", machines: [])
        var isReady: Bool { state == "running" }
        var selfShortName: String { String(selfName.split(separator: ".").first ?? "") }
    }

    @Published private(set) var tailnet = TailnetStatus.unknown

    /// Port MSL listens on for the Tailscale route. Remembered per
    /// instance, so two published instances do not collide on one port.
    func tailscalePort(for instance: String) -> Int {
        let stored = UserDefaults.standard.integer(forKey: "MSLTailscalePort.\(instance)")
        return stored == 0 ? 2222 : stored
    }

    func setTailscalePort(_ port: Int, for instance: String) {
        UserDefaults.standard.set(port, forKey: "MSLTailscalePort.\(instance)")
        objectWillChange.send()
    }

    func refreshTailnet() {
        Task { [weak self] in
            let reply = await Task.detached(priority: .utility) {
                DaemonClient.send(.publicTailscaleStatus, timeout: 20)
            }.value
            guard let self, let reply, reply.hasPrefix("OK ") else { return }
            let lines = String(reply.dropFirst(3)).split(separator: "\n").map(String.init)
            guard let head = lines.first?.components(separatedBy: "\t") else { return }
            var machines: [TailnetMachine] = []
            for line in lines.dropFirst() {
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 3 else { continue }
                machines.append(TailnetMachine(name: fields[0], system: fields[1],
                                               online: fields[2] == "true"))
            }
            self.tailnet = TailnetStatus(state: head.first ?? "missing",
                                         selfName: head.count > 1 ? head[1] : "",
                                         machines: machines)
        }
    }

    static func readable(_ reply: String?) -> String {
        guard let reply else { return "MSL's background service didn't answer." }
        return reply.replacingOccurrences(of: "ERROR ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The one piece of `PublicMSL` the app needs, without the app depending on
/// the whole module.
///
/// A deliberately loose check: the daemon validates properly before the key
/// goes near `authorized_keys`, and duplicating that here would mean two
/// places to keep in step. This exists only so an obvious paste mistake is
/// caught before a round trip.
enum PublicHardeningShim {
    static func looksLikeAPublicKey(_ text: String) -> Bool {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2, fields[1].count > 20 else { return false }
        return fields[0].hasPrefix("ssh-") || fields[0].hasPrefix("ecdsa-")
            || fields[0].hasPrefix("sk-")
    }
}
