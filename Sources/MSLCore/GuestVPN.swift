import Foundation

/// The hide.me VPN client, inside one instance.
///
/// What MSL does and does not do here is the important part. MSL installs
/// the official client and reports honestly on what it finds; it never
/// handles an account, a password or an access token, and it does not wrap
/// the client's own commands in a friendlier-looking button. Connecting is
/// the user typing `hide.me token` and `hide.me connect` in their own
/// instance, with their own credentials, and MSL being able to say whether
/// it worked.
///
/// The tunnel is the guest's alone: it is a WireGuard interface inside that
/// Linux, so the Mac's traffic is untouched, and so is every other instance.
/// That is worth saying out loud, because a VPN switch in a Mac app looks
/// like it covers the Mac.
public enum GuestVPN {
    /// Pinned, with the checksum of the exact file. An unpinned "latest"
    /// download into someone's machine, verified by nothing, is not a
    /// feature worth having: this way the bytes are either what MSL was
    /// built against or the install stops.
    public static let version = "0.9.14"
    public static let sha256 = "cddf5682621ec87c9bfc4591febfb27a6cccb1f846807640b2824543d0db539a"
    public static var downloadURL: String {
        "https://github.com/eventure/hide.client.linux/releases/download/v\(version)/hide.me-linux-arm64-\(version).tar.gz"
    }

    /// Where the client's own installer puts things, which MSL matches so
    /// that a hide.me install done by hand looks the same to this code.
    public static let installDirectory = "/opt/hide.me"
    public static let binary = "/opt/hide.me/hide.me"
    public static let tokenFile = "/opt/hide.me/accessToken.txt"

    public struct Status: Equatable, Sendable {
        /// The client is installed in the guest.
        public var installed: Bool
        /// The kernel has WireGuard. Without it the client cannot connect,
        /// and finding that out *after* installing is a poor experience.
        public var wireGuard: Bool
        /// An access token is present, which means someone has logged in.
        public var hasToken: Bool
        /// A WireGuard interface exists right now.
        public var connected: Bool

        public init(installed: Bool = false, wireGuard: Bool = false,
                    hasToken: Bool = false, connected: Bool = false) {
            self.installed = installed
            self.wireGuard = wireGuard
            self.hasToken = hasToken
            self.connected = connected
        }

        /// What to tell someone to do next, in their own words rather than
        /// MSL's. `nil` when there is nothing to do.
        public func nextStep(server: String = "free-nl.hideservers.net") -> String? {
            if !installed { return "Install the hide.me client to use it here." }
            if !wireGuard { return "This instance's kernel has no WireGuard support, so the client cannot connect." }
            if !hasToken { return "Log in from inside the instance: sudo hide.me token \(server)" }
            if !connected { return "Connect from inside the instance: sudo hide.me connect \(server)" }
            return nil
        }
    }

    /// Reads the guest. Runs as root because the module check does.
    public static let statusScript = """
    set -u
    # Presence only. The client prints no version anywhere, and running an
    # unknown binary as root just to look at its usage text is not something
    # a status check should do.
    [ -x \(binary) ] && echo "MSL-VPN-INSTALLED"
    # Loadable counts as present: the module is only inserted on demand.
    if [ -d /sys/module/wireguard ] || modprobe -n wireguard >/dev/null 2>&1 || modinfo wireguard >/dev/null 2>&1; then
        echo "MSL-VPN-WIREGUARD"
    fi
    [ -s \(tokenFile) ] && echo "MSL-VPN-TOKEN"
    if ip -o link show type wireguard 2>/dev/null | grep -q .; then echo "MSL-VPN-CONNECTED"; fi
    echo "MSL-VPN-OK"
    """

    public static func parseStatus(_ output: String) -> Status {
        var status = Status()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch text {
            case "MSL-VPN-INSTALLED": status.installed = true
            case "MSL-VPN-WIREGUARD": status.wireGuard = true
            case "MSL-VPN-TOKEN": status.hasToken = true
            case "MSL-VPN-CONNECTED": status.connected = true
            default: break
            }
        }
        return status
    }

    /// Downloads, checks, installs. Refuses to continue on a checksum
    /// mismatch, and leaves nothing behind when it does.
    public static let installScript = """
    set -u
    tmp=$(mktemp -d /tmp/msl-hideme.XXXXXX) || exit 1
    cleanup() { rm -rf "$tmp"; }
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "MSL-VPN-NO-DOWNLOADER"; cleanup; exit 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp/hide.me.tar.gz" '\(downloadURL)' || { echo "MSL-VPN-DOWNLOAD-FAILED"; cleanup; exit 0; }
    else
        wget -q -O "$tmp/hide.me.tar.gz" '\(downloadURL)' || { echo "MSL-VPN-DOWNLOAD-FAILED"; cleanup; exit 0; }
    fi
    # Every distro MSL ships has one of these; busybox has neither, so a
    # missing checksum tool stops the install rather than skipping the check.
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum "$tmp/hide.me.tar.gz" | cut -d' ' -f1)
    elif command -v openssl >/dev/null 2>&1; then
        sum=$(openssl dgst -sha256 "$tmp/hide.me.tar.gz" | sed 's/.*= *//')
    else
        echo "MSL-VPN-NO-CHECKSUM-TOOL"; cleanup; exit 0
    fi
    if [ "$sum" != '\(sha256)' ]; then
        echo "MSL-VPN-CHECKSUM-MISMATCH $sum"; cleanup; exit 0
    fi
    mkdir -p \(installDirectory)
    tar -xzf "$tmp/hide.me.tar.gz" -C \(installDirectory) || { echo "MSL-VPN-EXTRACT-FAILED"; cleanup; exit 0; }
    chmod +x \(binary) 2>/dev/null || true
    # On the PATH under its own name, so the instructions MSL prints are the
    # ones the client's own documentation gives.
    ln -sf \(binary) /usr/local/bin/hide.me 2>/dev/null || true
    cleanup
    [ -x \(binary) ] && echo "MSL-VPN-INSTALLED"
    echo "MSL-VPN-OK"
    """

    /// Takes the client back out. Only the files MSL put there.
    public static let removeScript = """
    set -u
    rm -rf \(installDirectory)
    rm -f /usr/local/bin/hide.me
    echo "MSL-VPN-OK"
    """

    public enum InstallResult: Equatable, Sendable {
        case installed
        case noDownloader
        case downloadFailed
        case noChecksumTool
        case checksumMismatch(String)
        case extractFailed
        case unknown(String)

        /// What a person should read, not what the script printed.
        public var message: String {
            switch self {
            case .installed: return "The hide.me client is installed."
            case .noDownloader: return "That instance has no curl or wget, so there is nothing to download with."
            case .downloadFailed: return "The download didn't finish. Check that the instance can reach the internet."
            case .noChecksumTool: return "That instance has no way to check the download's checksum, so MSL didn't install it."
            case .checksumMismatch(let found): return "The download didn't match the expected checksum (got \(found)). Nothing was installed."
            case .extractFailed: return "The download arrived but couldn't be unpacked."
            case .unknown(let text): return text.isEmpty ? "The install didn't finish." : text
            }
        }
    }

    public static func parseInstall(_ output: String) -> InstallResult {
        if output.contains("MSL-VPN-INSTALLED") { return .installed }
        if output.contains("MSL-VPN-NO-DOWNLOADER") { return .noDownloader }
        if output.contains("MSL-VPN-DOWNLOAD-FAILED") { return .downloadFailed }
        if output.contains("MSL-VPN-NO-CHECKSUM-TOOL") { return .noChecksumTool }
        if let range = output.range(of: "MSL-VPN-CHECKSUM-MISMATCH ") {
            let rest = output[range.upperBound...].prefix(while: { !$0.isNewline })
            return .checksumMismatch(String(rest))
        }
        if output.contains("MSL-VPN-EXTRACT-FAILED") { return .extractFailed }
        return .unknown(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Running it

    public static func status(instance: String, distro: GuestDistro) throws -> Status {
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: statusScript, user: "")
        return parseStatus(output)
    }

    /// An administrator's policy can forbid the VPN. Refused here, at the
    /// one function both the app and the CLI call - `status` and `remove`
    /// stay allowed, because reading state tells nobody anything and
    /// removing reduces exposure.
    public static func install(instance: String, distro: GuestDistro) throws -> InstallResult {
        guard MSLAPGate.allows("network.vpn", instance: instance) else {
            throw MSLAPRefusal(MSLAPGate.reason("network.vpn", instance: instance)
                               ?? "Not allowed by the MSL Admin Portal")
        }
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: installScript, user: "")
        return parseInstall(output)
    }

    public static func remove(instance: String, distro: GuestDistro) throws {
        _ = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: removeScript, user: "")
    }
}
