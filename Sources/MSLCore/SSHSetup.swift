import Foundation

/// One-command SSH into an MSL instance.
///
/// The goal is that the graphical app hands you something you can paste, or
/// a button that opens a terminal already connected - not a page of
/// instructions. Getting there needs four things to be true, and this type
/// establishes each and reports honestly when it cannot:
///
/// 1. a host keypair exists (generated once, never reused from your
///    personal key - MSL should not need your identity),
/// 2. the guest has that public key in `authorized_keys`,
/// 3. the guest is running `sshd`,
/// 4. **the Mac can actually reach the guest's address.**
///
/// Point 4 is the one that is not safe to assume. `VZNATNetworkDeviceAttachment`
/// is shared/NAT networking and the host normally does get a route to the
/// guest subnet, but "normally" is not "verified", and a Connect button that
/// hands over an address nothing can reach is worse than no button. So the
/// setup **probes the address before claiming success**, and says plainly
/// when the probe fails rather than printing a command that will hang.
public enum SSHSetup {

    /// What MSL knows about an instance's SSH access, kept between runs.
    ///
    /// Persisted so the card can show the connection details the moment it
    /// opens instead of making the user wait for a guest round trip. But it
    /// is explicitly **last known**, not current: a guest's DHCP address can
    /// move while it is off, and showing a cached address as "Ready" is the
    /// same class of lie as reporting open sandbox gates over a sealed
    /// policy. `Result.verifiedThisSession` is what separates the two.
    public struct Record: Codable, Equatable, Sendable {
        public var host: String
        public var user: String
        public var alias: String
        public var fingerprint: String?
        public var lastConfigured: Date

        public init(host: String, user: String, alias: String,
                    fingerprint: String? = nil, lastConfigured: Date = Date()) {
            self.host = host
            self.user = user
            self.alias = alias
            self.fingerprint = fingerprint
            self.lastConfigured = lastConfigured
        }
    }

    public enum RecordStore {
        public static func file(for instance: String) -> URL {
            MSLPaths.appSupport
                .appendingPathComponent("ssh", isDirectory: true)
                .appendingPathComponent("\(instance).json")
        }

        public static func load(instance: String) -> Record? {
            guard let data = try? Data(contentsOf: file(for: instance)) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }

        @discardableResult
        public static func save(_ record: Record, instance: String) -> Bool {
            let url = file(for: instance)
            guard MSLPaths.ensureDirectory(url.deletingLastPathComponent()) else { return false }
            guard let data = try? JSONEncoder().encode(record) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }

        public static func forget(instance: String) {
            try? FileManager.default.removeItem(at: file(for: instance))
        }
    }

    public struct Result: Equatable, Sendable {
        public let host: String        // the guest's address
        public let user: String
        public let alias: String       // the ~/.ssh/config alias, e.g. msl-default
        public let reachable: Bool
        /// The guest's own host key fingerprint.
        ///
        /// MSL turns `StrictHostKeyChecking` off (a rebuilt guest gets a new
        /// host key, and a mismatch warning after every rebuild teaches
        /// people to ignore mismatch warnings) - which makes showing this
        /// the only way left to check what you actually connected to.
        public let fingerprint: String?
        /// False when these details came from the stored record and nothing
        /// has confirmed them since. The UI must not present a cached
        /// address as a live one.
        public let verifiedThisSession: Bool

        public init(host: String, user: String, alias: String, reachable: Bool,
                    fingerprint: String? = nil, verifiedThisSession: Bool = true) {
            self.host = host
            self.user = user
            self.alias = alias
            self.reachable = reachable
            self.fingerprint = fingerprint
            self.verifiedThisSession = verifiedThisSession
        }

        /// Everything an admin needs in one pasteable block - the case where
        /// the person connecting is not the person who set it up.
        public var shareableSummary: String {
            var lines = [
                "MSL instance access",
                "  Connect:     ssh \(alias)",
                "  Address:     \(user)@\(host)",
                "  Key:         \(SSHSetup.privateKeyPath)",
            ]
            if let fingerprint { lines.append("  Host key:    \(fingerprint)") }
            lines.append("  Config:      \(SSHSetup.configPath) (entry '\(alias)')")
            return lines.joined(separator: "\n")
        }
        /// What to actually type. Uses the alias, which survives the guest's
        /// address changing between boots (MSL rewrites the config entry).
        public var command: String { "ssh \(alias)" }
        /// The long form, for when someone wants to see what the alias means
        /// or paste it into something that has no access to the config.
        /// The key lives under "Application Support", so the path is quoted -
        /// unquoted, the pasted command split at the space.
        public var explicitCommand: String { "ssh -i \(DesktopEntry.shellQuote(SSHSetup.privateKeyPath)) \(user)@\(host)" }
    }

    /// The last known details, if MSL has ever set this instance up.
    /// Marked unverified: nothing has confirmed the address is still right.
    public static func cachedResult(instance: String) -> Result? {
        guard let record = RecordStore.load(instance: instance) else { return nil }
        return Result(host: record.host, user: record.user, alias: record.alias,
                      reachable: false, fingerprint: record.fingerprint,
                      verifiedThisSession: false)
    }

    public enum SetupError: Error, CustomStringConvertible {
        case keyGenerationFailed(String)
        case guestCommandFailed(String)
        case noGuestAddress
        case sshdMissing

        public var description: String {
            switch self {
            case .keyGenerationFailed(let detail): return "couldn't create MSL's SSH key: \(detail)"
            case .guestCommandFailed(let detail): return "the guest refused a setup step: \(detail)"
            case .noGuestAddress: return "the guest has no network address yet"
            case .sshdMissing: return "this image has no SSH server installed"
            }
        }
    }

    // MARK: - Host key

    /// MSL's own key, not the user's.
    ///
    /// Deliberately separate from `~/.ssh/id_*`: a local VM manager has no
    /// business installing your personal public key into guest images, and a
    /// key MSL owns can be regenerated or revoked without touching anything
    /// else you use.
    public static var privateKeyPath: String {
        MSLPaths.appSupport.appendingPathComponent("ssh/msl_ed25519").path
    }
    public static var publicKeyPath: String { privateKeyPath + ".pub" }

    /// Creates the keypair if it is not there. Returns the public key text.
    public static func ensureHostKey() throws -> String {
        let fileManager = FileManager.default
        if let existing = try? String(contentsOfFile: publicKeyPath, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fileManager.fileExists(atPath: privateKeyPath) {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let directory = (privateKeyPath as NSString).deletingLastPathComponent
        guard MSLPaths.ensureDirectory(URL(fileURLWithPath: directory)) else {
            throw SetupError.keyGenerationFailed("couldn't create \(directory)")
        }
        // A half-written pair from an interrupted run would make ssh-keygen
        // refuse rather than overwrite.
        try? fileManager.removeItem(atPath: privateKeyPath)
        try? fileManager.removeItem(atPath: publicKeyPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-N", "", "-C", "msl@\(Host.current().localizedName ?? "mac")",
                             "-f", privateKeyPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            throw SetupError.keyGenerationFailed("\(error)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SetupError.keyGenerationFailed(output.isEmpty ? "ssh-keygen exited \(process.terminationStatus)" : output)
        }
        // ssh-keygen already writes 0600, but an image of this file is about
        // to be trusted by a server - be explicit rather than assume.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath)

        guard let publicKey = try? String(contentsOfFile: publicKeyPath, encoding: .utf8) else {
            throw SetupError.keyGenerationFailed("key written but unreadable")
        }
        return publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Guest address

    /// Pulls `MSL_SSH_FP <fingerprint>` out of the setup script's output.
    /// The guest's output as clean lines.
    ///
    /// Two things made the parsers below read garbage on real guests (found
    /// on the 2026-09-14 images): the output arrives through a pty, so lines
    /// end in CRLF - and in Swift "\r\n" is a *single* Character, so
    /// splitting on "\n" never split anything and the fingerprint swallowed
    /// the rest of the output. And iproute2 on Debian, Ubuntu and Kali
    /// colours its output on a terminal, so the address field read
    /// "\u{1B}[35m192.168.64.64\u{1B}[0m" and the parser settled for the
    /// loopback address. Busybox's `ip` (Alpine) does neither.
    static func lines(of output: String) -> [String] {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func parseFingerprint(_ output: String) -> String? {
        for line in lines(of: output) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("MSL_SSH_FP ") else { continue }
            let value = String(trimmed.dropFirst("MSL_SSH_FP ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Pulls the first non-loopback IPv4 address out of `ip -4 -o addr`.
    ///
    /// Parsed rather than pattern-matched loosely because the guest may have
    /// several interfaces (the virtio NIC, docker/podman bridges someone
    /// installed, a VPN) and picking the wrong one produces an address that
    /// looks right and connects to nothing.
    public static func parseGuestAddress(_ output: String) -> String? {
        // Format: "2: enp0s1    inet 192.168.64.7/24 brd ... scope global enp0s1"
        var fallback: String?
        for line in lines(of: output) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let inetIndex = fields.firstIndex(of: "inet"), inetIndex + 1 < fields.count else { continue }
            let address = String(fields[inetIndex + 1].split(separator: "/").first ?? "")
            guard !address.isEmpty, !address.hasPrefix("127.") else { continue }
            let interface = fields.count > 1 ? fields[1] : ""
            // Prefer the VM's own NIC. `en*` is what systemd-networkd names
            // it (confirmed live as enp0s1) and `eth0` is what a busybox
            // guest keeps; anything else is someone's bridge.
            if interface.hasPrefix("en") || interface.hasPrefix("eth") { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    /// Whether the Mac can open a TCP connection to the guest's SSH port.
    ///
    /// The whole feature turns on this and it cannot be assumed - so it is
    /// measured, with a short timeout, before anything claims to work.
    public static func canReach(host: String, port: UInt16 = 22, timeout: TimeInterval = 3) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else { return false }
        defer { freeaddrinfo(info) }

        let fd = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking connect + poll, NOT a blocking connect with
        // SO_SNDTIMEO. That option does not bound `connect()` at all - it
        // governs `send()` - so a blocking connect to an unreachable address
        // runs to the system's own TCP timeout, which is around 75 seconds.
        // Measured, not reasoned about: the test for an unreachable host took
        // exactly that long before this was rewritten, and this call sits
        // behind a button in the UI.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        if connect(fd, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 {
            return true   // connected immediately, which happens on loopback
        }
        guard errno == EINPROGRESS else { return false }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, timeout * 1000))
        guard poll(&pollFD, 1, milliseconds) > 0 else { return false }   // 0 == timed out

        // Writable does not mean connected: a refused connection also wakes
        // poll, and the actual result is in SO_ERROR.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    // MARK: - ~/.ssh/config

    public static func alias(for instance: String) -> String { "msl-\(instance)" }

    /// The block MSL writes into `~/.ssh/config`, fenced by markers so it
    /// can be rewritten without touching anything the user put there.
    public static func configBlock(instance: String, host: String, user: String) -> String {
        """
        \(beginMarker(instance))
        Host \(alias(for: instance))
            HostName \(host)
            User \(user)
            IdentityFile "\(privateKeyPath)"
            IdentitiesOnly yes
            # A guest is rebuilt far more often than a real server, and its
            # host key changes with it. Pinning it would mean a scary
            # mismatch warning after every rebuild, so MSL keeps these out of
            # the known_hosts file entirely rather than teaching people to
            # ignore that warning.
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
            LogLevel ERROR
        \(endMarker(instance))
        """
    }

    static func beginMarker(_ instance: String) -> String { "# >>> MSL \(instance) >>>" }
    static func endMarker(_ instance: String) -> String { "# <<< MSL \(instance) <<<" }

    /// Replaces this instance's block in an existing config, or appends it.
    ///
    /// Pure and idempotent: applying it twice gives the same file, and a
    /// changed guest address rewrites in place rather than accumulating
    /// stale `Host` entries that shadow each other (ssh takes the *first*
    /// match, so a stale duplicate above the fresh one would silently win).
    public static func mergeConfig(existing: String, instance: String, host: String, user: String) -> String {
        let existing = repairingEarlierBlocks(existing)
        let block = configBlock(instance: instance, host: host, user: user)
        let begin = beginMarker(instance)
        let end = endMarker(instance)

        guard let beginRange = existing.range(of: begin),
              let endRange = existing.range(of: end),
              beginRange.lowerBound < endRange.lowerBound else {
            let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
            return existing + separator + block + "\n"
        }
        return existing.replacingCharacters(in: beginRange.lowerBound..<endRange.upperBound, with: block)
    }

    /// Whether a saved record is still for the user SSH should land as. No
    /// expectation means any record will do.
    public static func recordMatches(_ record: Record, expectedUser: String?) -> Bool {
        guard let expectedUser else { return true }
        return record.user == expectedUser
    }

    /// This instance's block taken out of `config`, and nothing else touched.
    ///
    /// Pure, and a no-op when the block isn't there. The blank line
    /// `mergeConfig` put in front of the block goes with it, so repeated
    /// set-up-then-remove cycles don't grow a pile of empty lines.
    public static func removingBlock(from config: String, instance: String) -> String {
        guard let beginRange = config.range(of: beginMarker(instance)),
              let endRange = config.range(of: endMarker(instance)),
              beginRange.lowerBound < endRange.lowerBound else { return config }
        var start = beginRange.lowerBound
        var end = endRange.upperBound
        if end < config.endIndex, config[end] == "\n" { end = config.index(after: end) }
        if start > config.startIndex {
            let before = config.index(before: start)
            if config[before] == "\n", before > config.startIndex,
               config[config.index(before: before)] == "\n" {
                start = before
            }
        }
        return config.replacingCharacters(in: start..<end, with: "")
    }

    /// Everything MSL set up for `instance` on the Mac side: the cached
    /// record and the `~/.ssh/config` block. Called when an instance is
    /// removed - otherwise `ssh msl-<name>` survived its instance, pointing at
    /// an address some other guest may hold by now (found 2026-09-14).
    /// The config is rewritten only when the block is actually in it.
    public static func forget(instance: String) {
        RecordStore.forget(instance: instance)
        guard let existing = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        let trimmed = removingBlock(from: existing, instance: instance)
        guard trimmed != existing else { return }
        try? trimmed.write(toFile: configPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }

    /// Mends the blocks earlier versions of MSL wrote, for every instance,
    /// wherever they are in the file - only inside MSL's own markers.
    ///
    /// Two faults, both of which broke more than MSL's entries (found
    /// 2026-09-14): `IdentityFile` was unquoted, and the key lives under
    /// `~/Library/Application Support`, so ssh read "Support/MSL/..." as an
    /// extra argument and refused to load `~/.ssh/config` at all - every
    /// `ssh` on the Mac failed, not just MSL's. And a guest whose `ip`
    /// coloured its output left terminal escape codes in `HostName`.
    static func repairingEarlierBlocks(_ config: String) -> String {
        var lines = config.components(separatedBy: "\n")
        var insideMSLBlock = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# >>> MSL ") { insideMSLBlock = true; continue }
            if trimmed.hasPrefix("# <<< MSL ") { insideMSLBlock = false; continue }
            guard insideMSLBlock else { continue }
            var line = lines[index].replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            if trimmed.hasPrefix("IdentityFile "), !trimmed.dropFirst("IdentityFile ".count).hasPrefix("\"") {
                let indent = line.prefix(while: { $0 == " " })
                let path = trimmed.dropFirst("IdentityFile ".count)
                line = "\(indent)IdentityFile \"\(path)\""
            }
            lines[index] = line
        }
        return lines.joined(separator: "\n")
    }

    public static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    /// Writes the merged config. Best-effort on permissions, because an
    /// unreadable `~/.ssh/config` is a problem the user has to see rather
    /// than one MSL should silently paper over.
    public static func writeConfig(instance: String, host: String, user: String) throws {
        let directory = (configPath as NSString).deletingLastPathComponent
        guard MSLPaths.ensureDirectory(URL(fileURLWithPath: directory)) else {
            throw SetupError.guestCommandFailed("couldn't create \(directory)")
        }
        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let merged = mergeConfig(existing: existing, instance: instance, host: host, user: user)
        try merged.write(toFile: configPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }

    // MARK: - Guest side

    /// The one shell command that makes the guest ready.
    ///
    /// Written as a single idempotent script rather than several round trips
    /// because every one of those crosses a pty and a vsock, and a
    /// half-applied setup is the worst outcome. Re-running it is safe.
    ///
    /// It does **not** install the SSH server - that is the provisioner's
    /// job (`Linux-Side/provision/provision-msl.sh`). If sshd is absent this
    /// says so, which is a fixable, explainable state; silently `apk add`ing
    /// from a guest with no network would just hang.
    public static func guestSetupScript(publicKey: String, user: String) -> String {
        let quotedKey = DesktopEntry.shellQuote(publicKey)
        let quotedUser = DesktopEntry.shellQuote(user)
        return """
        set -e
        command -v sshd >/dev/null 2>&1 || command -v /usr/sbin/sshd >/dev/null 2>&1 || { echo MSL_NO_SSHD; exit 0; }
        home=$(getent passwd \(quotedUser) | cut -d: -f6)
        [ -n "$home" ] || home=/root
        mkdir -p "$home/.ssh"
        chmod 700 "$home/.ssh"
        touch "$home/.ssh/authorized_keys"
        # Idempotent: re-running setup must not stack duplicate keys.
        grep -qxF \(quotedKey) "$home/.ssh/authorized_keys" || echo \(quotedKey) >> "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        chown -R \(quotedUser) "$home/.ssh" 2>/dev/null || true
        # Host keys before the first start: MSL's images ship without any
        # (every copy of an image sharing one host key would be worse than
        # none), and sshd refuses to start without them - Debian's
        # ssh.service failed at boot on exactly that until sshd stopped being
        # enabled in the image. `-A` only creates keys that are missing.
        ssh-keygen -A >/dev/null 2>&1 || true
        # Start it now, and at boot on whichever init this image uses.
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add sshd default >/dev/null 2>&1 || true
            rc-service sshd start >/dev/null 2>&1 || /usr/sbin/sshd 2>/dev/null || true
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now sshd >/dev/null 2>&1 || systemctl enable --now ssh >/dev/null 2>&1 || true
        else
            /usr/sbin/sshd 2>/dev/null || true
        fi
        # Host keys are generated on first start by most images, but not all.
        ssh-keygen -A >/dev/null 2>&1 || true
        # The guest's own fingerprint. MSL disables StrictHostKeyChecking (a
        # rebuilt guest gets a new key every time), so showing this is the
        # only verification left to anyone who cares to check.
        for k in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
            [ -f "$k" ] || continue
            printf 'MSL_SSH_FP '
            ssh-keygen -lf "$k" 2>/dev/null | awk '{print $2}'
            break
        done
        echo MSL_SSH_READY
        ip -4 -o addr show 2>/dev/null || ip -4 addr show 2>/dev/null || true
        """
    }

    // MARK: - The whole flow

    /// Sets an instance up end to end and reports what actually happened.
    ///
    /// Blocks (it drives a guest shell), so callers on the main actor must
    /// hop off first. Returns a `Result` whose `reachable` is measured, not
    /// assumed - see this type's doc comment.
    public static func configure(instance: String, distro: GuestDistro,
                                 user: String = "msl") throws -> Result {
        let publicKey = try ensureHostKey()

        let (exitCode, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro,
            command: guestSetupScript(publicKey: publicKey, user: user))

        if output.contains("MSL_NO_SSHD") { throw SetupError.sshdMissing }
        guard exitCode == 0, output.contains("MSL_SSH_READY") else {
            throw SetupError.guestCommandFailed(output.isEmpty ? "exit \(exitCode)" : output)
        }
        guard let host = parseGuestAddress(output) else { throw SetupError.noGuestAddress }

        try writeConfig(instance: instance, host: host, user: user)

        let fingerprint = parseFingerprint(output)
        RecordStore.save(Record(host: host, user: user, alias: alias(for: instance),
                                fingerprint: fingerprint),
                         instance: instance)
        ActivityLog.shared.record(.control, instance: instance, "SSH access configured",
                                  detail: "\(user)@\(host)")

        return Result(host: host, user: user, alias: alias(for: instance),
                      reachable: canReach(host: host), fingerprint: fingerprint)
    }

    /// The cheap check the automatic path runs before doing anything: if a
    /// record exists and its address still answers, the instance is already
    /// set up and a full guest round trip would be pure cost.
    ///
    /// Returns the confirmed result, or nil meaning "go and configure".
    /// `expectedUser` is who SSH should land as now. A record for anyone else
    /// is stale: MSL.app sets SSH up automatically when an instance first
    /// starts, which can be before the user has created their account - and
    /// the record it wrote, for `msl`, was then trusted forever, so `ssh
    /// msl-<name>` never landed as the account the user made (2026-09-14).
    public static func verifyExisting(instance: String, expectedUser: String? = nil) -> Result? {
        guard let record = RecordStore.load(instance: instance),
              recordMatches(record, expectedUser: expectedUser) else { return nil }
        guard canReach(host: record.host) else { return nil }
        return Result(host: record.host, user: record.user, alias: record.alias,
                      reachable: true, fingerprint: record.fingerprint)
    }
}
