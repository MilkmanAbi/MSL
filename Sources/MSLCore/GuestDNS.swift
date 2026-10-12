import Foundation

/// Which DNS resolver an instance uses.
///
/// Part of the privacy options, and the honest framing matters: this changes
/// who answers the guest's name lookups. Traffic still leaves through the
/// Mac's own network, so it hides lookups from the local network and the
/// people running it, not from the Mac.
///
/// Setting it has to survive a reboot, which is where the work is: three
/// different things want to own `/etc/resolv.conf` depending on the distro,
/// and two of them rewrite it on every boot.
public enum GuestDNS {
    public struct Choice: Equatable, Sendable, Codable {
        public let name: String
        /// Empty means "leave the distro alone".
        public let servers: [String]

        public init(name: String, servers: [String]) {
            self.name = name
            self.servers = servers
        }

        public static let automatic = Choice(name: "Automatic", servers: [])
        public static let cloudflare = Choice(name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"])
        public static let google = Choice(name: "Google", servers: ["8.8.8.8", "8.8.4.4"])
        public static let quad9 = Choice(name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"])

        public static let offered: [Choice] = [.automatic, .cloudflare, .google, .quad9]
    }

    /// Marks every file MSL writes, so reverting removes exactly what MSL
    /// added and nothing a user put there by hand.
    public static let marker = "# Written by MSL. Remove this file to go back to the distro's own DNS."

    /// The same idea for a config file MSL only *appends* to, where deleting
    /// the file would be terrible advice. Reverting matches on this text, so
    /// applying and reverting leaves udhcpc.conf as it found it instead of
    /// stacking up a comment on every cycle.
    public static let udhcpcMarker = "# Added by MSL so its DNS choice survives a lease renewal."

    /// Single-quoted for `sh`. The marker contains an apostrophe
    /// ("distro's"), which ended the quoted string and made the whole script
    /// a syntax error the first time this ran for real.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A plain IPv4 address, checked before it is ever put in a script.
    public static func isValidServer(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), part.count <= 3, !part.isEmpty else { return false }
            return value >= 0 && value <= 255
        }
    }

    /// Applies `choice` in a way that survives a reboot on every distro MSL
    /// ships.
    ///
    /// Three owners of `/etc/resolv.conf` to satisfy:
    /// - **systemd-resolved**, where the file is a symlink into `/run` and
    ///   editing it is pointless: the drop-in is the supported way.
    /// - **udhcpc** (Alpine's DHCP client), which rewrites the file on every
    ///   lease unless told not to.
    /// - plain **`/etc/resolv.conf`**, where writing it is the whole job.
    public static func applyScript(_ choice: Choice) -> String {
        // "Automatic" is the gateway, not whatever the image shipped with.
        guard !choice.servers.isEmpty else { return revertScript() + "\n" + automaticScript }
        let nameservers = choice.servers.map { "nameserver \($0)" }.joined(separator: "\n")
        let resolvedServers = choice.servers.joined(separator: " ")
        return """
        set -u
        # systemd-resolved owns resolv.conf when it is running; a drop-in is
        # the only edit that survives it.
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
            mkdir -p /etc/systemd/resolved.conf.d
            printf '%s\\n[Resolve]\\nDNS=%s\\n' \(quoted(marker)) '\(resolvedServers)' > /etc/systemd/resolved.conf.d/msl-dns.conf
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
            echo "MSL-DNS resolved"
        fi
        # Alpine's udhcpc rewrites resolv.conf on every lease.
        if [ -d /etc/udhcpc ] || command -v udhcpc >/dev/null 2>&1; then
            mkdir -p /etc/udhcpc
            if ! grep -qs '^RESOLV_CONF=' /etc/udhcpc/udhcpc.conf 2>/dev/null; then
                printf '%s\\nRESOLV_CONF="no"\\n' \(quoted(udhcpcMarker)) >> /etc/udhcpc/udhcpc.conf
            fi
        fi
        # And the file itself, unless something else owns it. Whatever was
        # there first is kept, so reverting can put it back exactly.
        if [ ! -L /etc/resolv.conf ]; then
            if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.msl-backup ] && ! head -1 /etc/resolv.conf | grep -qs 'Written by MSL'; then
                cp /etc/resolv.conf /etc/resolv.conf.msl-backup
            fi
            printf '%s\\n%s\\n' \(quoted(marker)) '\(nameservers)' > /etc/resolv.conf
            echo "MSL-DNS resolv"
        fi
        echo "MSL-DNS-OK"
        """
    }

    /// Takes MSL's changes back out, leaving anything else alone.
    public static func revertScript() -> String {
        """
        set -u
        rm -f /etc/systemd/resolved.conf.d/msl-dns.conf
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
        fi
        # Only if MSL wrote it: a resolv.conf without the marker is the
        # user's, or the distro's, and not ours to delete.
        if [ -f /etc/resolv.conf ] && head -1 /etc/resolv.conf | grep -qs 'Written by MSL'; then
            if [ -f /etc/resolv.conf.msl-backup ]; then
                mv /etc/resolv.conf.msl-backup /etc/resolv.conf
            else
                rm -f /etc/resolv.conf
                # Let whatever manages the network write its own again.
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl restart systemd-networkd >/dev/null 2>&1 || true
                elif command -v rc-service >/dev/null 2>&1; then
                    rc-service networking restart >/dev/null 2>&1 || true
                fi
            fi
        fi
        # Whatever happened above, the guest must not be left with no
        # resolver at all: that breaks every name lookup until the next DHCP
        # lease, which may be hours. The default gateway is MSL's own
        # resolver, and is what the distro would have been handed anyway.
        if [ ! -s /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
            gateway=$(ip route 2>/dev/null | awk '/^default/ { print $3; exit }')
            [ -n "$gateway" ] && printf 'nameserver %s\\n' "$gateway" > /etc/resolv.conf
        fi
        if [ -f /etc/udhcpc/udhcpc.conf ]; then
            sed -i -e '/RESOLV_CONF="no"/d' -e '/Added by MSL so its DNS choice/d' -e '/Written by MSL/d' /etc/udhcpc/udhcpc.conf 2>/dev/null || true
        fi
        echo "MSL-DNS-OK"
        """
    }

    /// Heads the resolv.conf that "Automatic" writes. Distinct from `marker`:
    /// that one means someone *chose* a resolver and must never be touched;
    /// this one is MSL's own default and is rewritten freely.
    public static let automaticMarker = "# MSL automatic DNS: your Mac's network, via the MSL gateway. Choose another in MSL's Privacy card."

    /// Points an "Automatic" guest at the NAT gateway's DNS proxy.
    ///
    /// Every image shipped with `nameserver 1.1.1.1` baked in. That works on
    /// the network the image was tested on and dies on any network that
    /// blocks outside resolvers - school, hotel and office wifi, captive
    /// portals - which is exactly "DNS breaks the moment I change wifi". The
    /// gateway (vmnet's NAT, 192.168.64.1 on every Mac so far) answers DNS
    /// by forwarding to whatever resolver the Mac is using *right now*, so a
    /// guest pointed at it follows the Mac across every network change.
    ///
    /// Run by mslhd after every start, on wake and on every Mac network
    /// change, so it is idempotent and quiet. It rewrites resolv.conf only
    /// when it is empty, is MSL's own automatic file, or is the image's
    /// untouched `1.1.1.1` default; a resolver someone chose (MSL's marker)
    /// or wrote by hand is left alone. The gateway comes from
    /// `/proc/net/route` rather than `ip route`, whose output is coloured on
    /// some distros and has no portable way to turn that off.
    /// Makes the guest try IPv4 before IPv6.
    ///
    /// **The Mac's shared network advertises an IPv6 router that does not
    /// route.** The guest accepts the advertisement, installs a default v6
    /// route, and from then on every lookup that returns a AAAA record -
    /// which `archive.ubuntu.com` and most large sites do - is tried over
    /// IPv6 first and has to time out before IPv4 is attempted.
    ///
    /// Measured in a stock Ubuntu instance: `ping6` to the address DNS had
    /// just returned lost 100% of packets, while the IPv4 address for the
    /// same host answered immediately. `apt-get update` sat there long
    /// enough to look like a hung machine.
    ///
    /// It presents as "the network is slow", which is the worst kind of
    /// bug: nothing is broken enough to investigate, so people work around
    /// it instead. The way round it is usually a snap, and a snap carries
    /// its own frozen runtime - which is how a 2019 LuaJIT ends up being
    /// the reason a game will not start.
    ///
    /// Preferring IPv4 in `getaddrinfo` rather than tearing out the route:
    /// nothing is disabled, anything genuinely v6-only still works, and a
    /// network that gains real IPv6 later needs no undoing. The line is the
    /// one glibc ships commented out for exactly this situation.
    static let preferIPv4Script = """
    set -u
    # glibc: higher precedence wins, and this entry covers v4-mapped
    # addresses. It is in the shipped gai.conf already, commented out.
    if [ -w /etc/gai.conf ] || [ ! -e /etc/gai.conf ]; then
        if ! grep -qs '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
            printf '%s\\nprecedence ::ffff:0:0/96  100\\n' \(quoted(ipv4Marker)) >> /etc/gai.conf
            echo "MSL-V4-APPLIED"
        fi
    fi
    # apt has its own resolver path and ignores gai.conf, so it is told
    # separately. Harmless on a distro that does not use apt.
    if [ -d /etc/apt/apt.conf.d ]; then
        if [ ! -f /etc/apt/apt.conf.d/99msl-ipv4 ]; then
            echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99msl-ipv4
        fi
    fi
    echo "MSL-V4-OK"
    """

    public static let ipv4Marker =
        "# Added by MSL: the Mac's shared network advertises IPv6 it cannot route."

    public static let automaticScript = """
    set -u
    # systemd-resolved owns the file where it runs; it takes the gateway from
    # DHCP already, so a stale cache is the only thing to clear.
    if [ -L /etc/resolv.conf ]; then
        command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1
        echo "MSL-DNS-OK"; exit 0
    fi
    if [ -f /etc/resolv.conf ] && head -1 /etc/resolv.conf | grep -qs 'Written by MSL'; then
        echo "MSL-DNS-OK"; exit 0
    fi
    hex=$(awk '$2 == "00000000" && $3 != "00000000" { print $3; exit }' /proc/net/route 2>/dev/null)
    [ -n "$hex" ] || { echo "MSL-DNS-NOGATEWAY"; exit 0; }
    set -- $(echo "$hex" | sed 's/\\(..\\)\\(..\\)\\(..\\)\\(..\\)/\\4 \\3 \\2 \\1/')
    gateway=$(printf '%d.%d.%d.%d' "0x$1" "0x$2" "0x$3" "0x$4")
    servers=$(awk '/^nameserver/ { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null)
    if [ ! -s /etc/resolv.conf ] || [ "$servers" = "1.1.1.1 " ] || [ "$servers" = "" ] \\
        || head -1 /etc/resolv.conf | grep -qs 'MSL automatic DNS'; then
        if [ "$servers" != "$gateway " ]; then
            printf '%s\\nnameserver %s\\n' \(quoted(automaticMarker)) "$gateway" > /etc/resolv.conf
            echo "MSL-DNS-GATEWAY $gateway"
        fi
    fi
    # A caching resolver would keep answering from the old network.
    command -v nscd >/dev/null 2>&1 && nscd -i hosts >/dev/null 2>&1
    echo "MSL-DNS-OK"
    """

    /// Reads what the guest is using now, for showing the current state.
    ///
    /// Three sources, because "which DNS server is this guest using" has
    /// three different answers depending on the distro, and the obvious one
    /// is the misleading one. On Debian and Ubuntu `/etc/resolv.conf` says
    /// `nameserver 127.0.0.53` no matter what is configured: that is
    /// systemd-resolved's own stub listener, not a resolver anyone chose.
    /// Reporting it would mean the panel confidently showing a wrong answer
    /// straight after a change it just made.
    public static let readScript = """
    set -u
    # What resolved is really forwarding to, which is the true answer where
    # it runs at all.
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null | tr ' ' '\\n' | grep -E '^[0-9]+\\.[0-9.]+$' | sed 's/^/MSL-DNS-UPSTREAM /' || true
    fi
    # What MSL asked for, as a fallback for a resolved that will not answer.
    if [ -f /etc/systemd/resolved.conf.d/msl-dns.conf ]; then
        sed -n 's/^DNS=//p' /etc/systemd/resolved.conf.d/msl-dns.conf | tr ' ' '\\n' | grep -E '^[0-9]+\\.[0-9.]+$' | sed 's/^/MSL-DNS-CONFIGURED /' || true
    fi
    grep -s '^nameserver' /etc/resolv.conf | awk '{print "MSL-DNS-RESOLVCONF " $2}'
    """

    /// A resolver that only forwards to something else on the same machine.
    /// 127.0.0.53 is systemd-resolved's stub; 127.0.0.1 is usually dnsmasq.
    public static func isLocalStub(_ server: String) -> Bool {
        server.hasPrefix("127.")
    }

    /// Where an answer came from, so the UI can be honest about how sure it
    /// is rather than presenting all three the same way.
    public enum Source: String, Sendable, Equatable {
        /// systemd-resolved, asked directly. The real upstream.
        case resolved
        /// MSL's own drop-in: what was asked for, not confirmed.
        case configured
        /// Plain `/etc/resolv.conf`, which on these distros *is* the answer.
        case resolvConf
        /// Only a local stub answered, and nothing said what it forwards to.
        case stubOnly
        case unknown
    }

    public struct Reading: Equatable, Sendable {
        public let servers: [String]
        public let source: Source

        public init(servers: [String], source: Source) {
            self.servers = servers
            self.source = source
        }
    }

    /// Picks the most truthful of the three, in that order.
    public static func parse(_ output: String) -> Reading {
        func values(_ tag: String) -> [String] {
            output.split(whereSeparator: \.isNewline).compactMap { line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix(tag + " ") else { return nil }
                let server = String(text.dropFirst(tag.count + 1))
                return isValidServer(server) ? server : nil
            }
        }

        let upstream = values("MSL-DNS-UPSTREAM").filter { !isLocalStub($0) }
        if !upstream.isEmpty { return Reading(servers: unique(upstream), source: .resolved) }

        let configured = values("MSL-DNS-CONFIGURED")
        if !configured.isEmpty { return Reading(servers: unique(configured), source: .configured) }

        let resolvConf = values("MSL-DNS-RESOLVCONF")
        let real = resolvConf.filter { !isLocalStub($0) }
        if !real.isEmpty { return Reading(servers: unique(real), source: .resolvConf) }
        if !resolvConf.isEmpty { return Reading(servers: unique(resolvConf), source: .stubOnly) }
        return Reading(servers: [], source: .unknown)
    }

    /// The servers the guest is actually resolving with.
    public static func parseActive(_ output: String) -> [String] {
        parse(output).servers
    }

    private static func unique(_ servers: [String]) -> [String] {
        var seen = Set<String>()
        return servers.filter { seen.insert($0).inserted }
    }

    public static func succeeded(_ output: String) -> Bool {
        output.contains("MSL-DNS-OK")
    }

    // MARK: - Running it

    /// Asks the guest what it resolves with.
    ///
    /// Shared by `msl dns` and the app's privacy card on purpose: two
    /// readers of the same state that disagree is worse than either of them
    /// being a little rough.
    public static func read(instance: String, distro: GuestDistro) throws -> Reading {
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: readScript, user: "")
        return parse(output)
    }

    /// Applies a choice. `false` means the guest ran the script and it did
    /// not finish, which is different from the call throwing (no instance,
    /// no connection).
    @discardableResult
    public static func apply(_ choice: Choice, instance: String, distro: GuestDistro) throws -> Bool {
        // One function for every DNS change, from the app and the CLI
        // alike. `revert` is not gated: returning to the default is the
        // safe direction.
        guard MSLAPGate.allows("network.dns", instance: instance) else {
            throw MSLAPRefusal(MSLAPGate.reason("network.dns", instance: instance)
                               ?? "Not allowed by the MSL Admin Portal")
        }
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: applyScript(choice), user: "")
        return succeeded(output)
    }
}
