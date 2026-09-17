import Foundation

/// Creating a distro's everyday Linux account, the way WSL does the first
/// time a distro starts: a UNIX username, a password, and membership of the
/// distro's admin group - so `sudo` works, and asks for that password.
///
/// It asks for the password on purpose. An account that can become root
/// without one breaks what everyone expects of a Linux machine - scripts
/// that probe `sudo -n`, the first `sudo` that is supposed to stop and ask,
/// muscle memory from every other distro. Root without a password stays
/// available the WSL way, from the host: `msl <instance> -u root`.
///
/// Shared by the `msl` CLI's first-run prompt and the app's setup sheet, so
/// both create exactly the same account.
public enum LinuxUserSetup {
    // MARK: - Where the answer is remembered

    public static var registryURL: URL {
        MSLPaths.appSupport.appendingPathComponent("default-users.json")
    }

    public static func registry() -> DefaultUserRegistry { DefaultUserRegistry(path: registryURL) }

    /// Keyed by distro, not instance: instances of a distro share one disk,
    /// and so one `/etc/passwd`.
    public static func defaultUser(for distro: GuestDistro) -> String? {
        registry().defaultUser(for: distro)
    }

    // MARK: - Rules

    /// System accounts and groups a distro already has, or that `useradd`
    /// would collide with when it makes the user's own group. `msl` is the
    /// image's built-in unprivileged account.
    public static let reservedNames: Set<String> = [
        "root", "msl", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
        "uucp", "proxy", "www-data", "backup", "list", "irc", "nobody", "sshd", "messagebus",
        "sudo", "wheel", "adm", "operator", "halt", "shutdown", "ftp", "dbus", "polkitd",
        "systemd-network", "systemd-resolve", "systemd-timesync", "_apt",
    ]

    public enum UsernameProblem: Equatable {
        case empty
        case tooLong
        case badFirstCharacter
        case badCharacter(Character)
        case reserved

        public var message: String {
            switch self {
            case .empty: return "Choose a username."
            case .tooLong: return "Usernames can be at most 32 characters."
            case .badFirstCharacter: return "Usernames start with a lowercase letter or an underscore."
            case .badCharacter(let c): return "“\(c)” can't be in a username — use lowercase letters, digits, “_” or “-”."
            case .reserved: return "That name is already used by the system. Pick another."
            }
        }
    }

    /// The rules `useradd` and busybox `adduser` both accept - lowercase,
    /// starting with a letter or underscore - which also keeps the name
    /// safe to use bare in a path.
    public static func problem(with username: String) -> UsernameProblem? {
        guard let first = username.first else { return .empty }
        guard username.count <= 32 else { return .tooLong }
        guard (first.isLowercase && first.isASCII) || first == "_" else { return .badFirstCharacter }
        if let bad = username.first(where: { !(($0.isLowercase || $0.isNumber) && $0.isASCII) && $0 != "_" && $0 != "-" }) {
            return .badCharacter(bad)
        }
        return reservedNames.contains(username) ? .reserved : nil
    }

    public static func passwordProblem(_ password: String, confirmation: String) -> String? {
        if password.isEmpty { return "The password can't be empty." }
        if password.contains(where: \.isNewline) { return "The password can't contain line breaks." }
        if password != confirmation { return "The passwords don't match." }
        return nil
    }

    // MARK: - The guest side

    /// Exit codes the script uses to say which step went wrong.
    enum ExitCode {
        static let userExists: Int32 = 3
        static let noSudo: Int32 = 4
        static let accountFailed: Int32 = 10
        static let passwordFailed: Int32 = 11
        static let groupFailed: Int32 = 12
        static let sudoersFailed: Int32 = 13
    }

    /// Runs as root in the guest. POSIX sh, because Alpine's is busybox ash.
    ///
    /// - The account: `useradd` where it exists, busybox `adduser` on Alpine.
    /// - The password: `chpasswd`, fed by `printf` - a shell builtin, so the
    ///   password never appears in a process list.
    /// - The admin group: `sudo` on Debian and Ubuntu, `wheel` everywhere
    ///   else. Joining it is the conventional way to be an administrator, so
    ///   anything that checks group membership sees it.
    /// - Letting that group use sudo, with a password: Debian and Fedora
    ///   already do; Alpine and Arch ship the line commented out. A drop-in
    ///   says it everywhere, and `visudo` checks it before it goes live -
    ///   a broken sudoers file locks sudo for everyone.
    public static func script(username: String, password: String) -> String {
        let user = DesktopEntry.shellQuote(username)
        let credentials = DesktopEntry.shellQuote("\(username):\(password)")
        return #"""
        set -u
        user=\#(user)
        credentials=\#(credentials)

        if id "$user" >/dev/null 2>&1; then
            echo "a user called $user already exists" >&2
            exit 3
        fi

        if command -v useradd >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$user"
        else
            adduser -D -s /bin/bash -h "/home/$user" "$user"
        fi || { echo "couldn't create the account" >&2; exit 10; }

        if ! printf '%s\n' "$credentials" | chpasswd; then
            echo "couldn't set the password" >&2
            userdel -r "$user" 2>/dev/null || deluser --remove-home "$user" 2>/dev/null || true
            exit 11
        fi

        if ! command -v sudo >/dev/null 2>&1; then
            { apk add --no-cache sudo \
              || { apt-get update -qq && apt-get install -y -qq sudo; } \
              || pacman -Sy --noconfirm sudo \
              || dnf install -y -q sudo; } >/dev/null 2>&1 || true
        fi

        if grep -q '^sudo:' /etc/group; then
            group=sudo
        else
            group=wheel
            grep -q '^wheel:' /etc/group || groupadd wheel 2>/dev/null || addgroup wheel 2>/dev/null || true
        fi
        if command -v usermod >/dev/null 2>&1; then
            usermod -aG "$group" "$user"
        else
            addgroup "$user" "$group"
        fi || { echo "couldn't add $user to the $group group" >&2; exit 12; }

        rm -f "/etc/sudoers.d/$user"
        mkdir -p /etc/sudoers.d
        pending=/etc/sudoers.d/.msl-admins.pending
        printf '%%%s ALL=(ALL:ALL) ALL\n' "$group" > "$pending"
        chmod 0440 "$pending"
        if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$pending" >/dev/null 2>&1; then
            rm -f "$pending"
            echo "sudo's configuration couldn't be updated safely" >&2
            exit 13
        fi
        mv "$pending" /etc/sudoers.d/10-msl-admins

        command -v sudo >/dev/null 2>&1 || exit 4
        echo "created $user, in the $group group"
        """#
    }

    public enum Outcome: Equatable {
        /// The account exists and is the distro's default now. `warning` is
        /// set when it was made but couldn't be given sudo.
        case created(warning: String?)
        case alreadyExists
        case failed(String)
    }

    /// Public for the `msl` CLI, which runs the script over its own session
    /// path rather than `ShellClient`.
    public static func outcome(exitCode: Int32, output: String, username: String) -> Outcome {
        switch exitCode {
        case 0:
            return .created(warning: nil)
        case ExitCode.userExists:
            return .alreadyExists
        case ExitCode.noSudo:
            return .created(warning: "sudo isn't installed in this Linux, so \(username) can't use it yet. Install it as root (msl <instance> -u root), with the distro's package manager.")
        case ExitCode.groupFailed, ExitCode.sudoersFailed:
            return .created(warning: "\(username) was created, but couldn't be given sudo: \(lastLine(output) ?? "unknown error"). Root is still available with msl <instance> -u root.")
        default:
            return .failed(lastLine(output) ?? "the setup exited with status \(exitCode)")
        }
    }

    private static func lastLine(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Creates the account from the host - starting the instance if it has
    /// to - and, once it exists, remembers it as the distro's default user.
    /// Blocks; call it off the main thread.
    public static func run(instance: String, distro: GuestDistro, username: String, password: String) -> Outcome {
        do {
            let (code, output) = try ShellClient().runOneShotCommand(
                instance: instance, distro: distro, command: script(username: username, password: password))
            let result = outcome(exitCode: code, output: output, username: username)
            if case .created = result {
                try? registry().setDefaultUser(username, for: distro)
            }
            return result
        } catch {
            return .failed("\(error)")
        }
    }
}
