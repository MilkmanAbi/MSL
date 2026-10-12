import Foundation

/// Repairs a Linux home directory that MSL itself made root-owned.
///
/// Until 2026-09-21 every GUI app MSL launched ran as **root** (see
/// `GuestUser`). Those apps wrote their settings and caches into the
/// account's home anyway, because `$HOME` came from the environment rather
/// than from who was running: `~/.config`, `~/.cache`, `~/.local`, recent
/// files, whole project directories. The account then could not edit its own
/// files, and apps failed in ways that look nothing like a permissions
/// problem ("could not save settings", silently empty recent lists).
///
/// Fixing the launcher stops it happening again. It does not undo what has
/// already happened, which is what this is for.
///
/// Everything here runs as root in the guest, because only root can give
/// files away. The scripts are built as strings and parsed back so they can
/// be tested without a running instance.
public enum HomeOwnership {
    public struct Report: Equatable, Sendable {
        /// Files in the account's home not owned by the account.
        public let wrongCount: Int
        /// A few of them, for showing the user what will change.
        public let samples: [String]
        /// The home directory that was looked at.
        public let home: String

        public var needsRepair: Bool { wrongCount > 0 }
    }

    /// Single-quoted for `sh`, so a home directory with a space or a quote in
    /// it cannot end the argument early.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Counts what is wrong, changes nothing.
    ///
    /// `-xdev` on purpose: the Mac's home folder is mounted inside the guest
    /// at `/mnt/mac`, and a bind or symlink into it must never be walked, let
    /// alone chowned. Counting stops at the filesystem boundary.
    public static func scanScript(user: String) -> String {
        let u = quoted(user)
        return """
        set -u
        # Alpine (busybox + musl) has no `getent`, so read the passwd file
        # itself and keep getent only as the fallback for directory-backed
        # accounts (LDAP, SSSD), where /etc/passwd has no entry.
        home=$(awk -F: -v u=\(u) '$1 == u { print $6 }' /etc/passwd 2>/dev/null)
        [ -n "$home" ] || home=$(getent passwd \(u) 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then echo "MSL-HOME-MISSING"; exit 0; fi
        echo "MSL-HOME $home"
        count=$(find "$home" -xdev ! -user \(u) 2>/dev/null | wc -l)
        echo "MSL-WRONG $count"
        find "$home" -xdev ! -user \(u) 2>/dev/null | head -20 | sed 's/^/MSL-SAMPLE /'
        """
    }

    /// Gives every file in the account's home back to the account.
    ///
    /// Only inside the home directory, only files that are not already the
    /// user's, and never across a filesystem boundary. The group is the
    /// account's own primary group, which is what `useradd` made.
    public static func repairScript(user: String) -> String {
        let u = quoted(user)
        return """
        set -u
        # Alpine (busybox + musl) has no `getent`, so read the passwd file
        # itself and keep getent only as the fallback for directory-backed
        # accounts (LDAP, SSSD), where /etc/passwd has no entry.
        home=$(awk -F: -v u=\(u) '$1 == u { print $6 }' /etc/passwd 2>/dev/null)
        [ -n "$home" ] || home=$(getent passwd \(u) 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then echo "MSL-HOME-MISSING"; exit 0; fi
        group=$(id -gn \(u) 2>/dev/null || echo \(u))
        before=$(find "$home" -xdev ! -user \(u) 2>/dev/null | wc -l)
        find "$home" -xdev ! -user \(u) -exec chown "\(user):$group" {} + 2>/dev/null
        after=$(find "$home" -xdev ! -user \(u) 2>/dev/null | wc -l)
        echo "MSL-REPAIRED $((before - after))"
        echo "MSL-WRONG $after"
        """
    }

    /// Reads either script's output. Unknown lines are ignored, so a distro
    /// that prints a warning first does not break the parse.
    ///
    /// Split on `isNewline`, never on the character `"\n"`: the guest runs
    /// commands on a pty, so lines end CRLF, and **Swift treats "\r\n" as one
    /// Character**. Splitting on "\n" therefore does not split at all, the
    /// whole reply arrives as a single line, and the count is never found.
    public static func parse(_ output: String) -> Report? {
        var home = ""
        var wrong: Int?
        var samples: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "MSL-HOME-MISSING" { return nil }
            if text.hasPrefix("MSL-HOME ") { home = String(text.dropFirst("MSL-HOME ".count)) }
            if text.hasPrefix("MSL-WRONG ") { wrong = Int(text.dropFirst("MSL-WRONG ".count).trimmingCharacters(in: .whitespacesAndNewlines)) }
            if text.hasPrefix("MSL-SAMPLE ") { samples.append(String(text.dropFirst("MSL-SAMPLE ".count))) }
        }
        guard let wrong else { return nil }
        return Report(wrongCount: wrong, samples: samples, home: home)
    }

    /// How many files a repair actually handed over.
    public static func parseRepaired(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) where line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("MSL-REPAIRED ") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(text.dropFirst("MSL-REPAIRED ".count).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    // MARK: - Against a running instance

    /// Looks, changes nothing. Nil when the instance has no account yet, or
    /// the account has no home directory.
    public static func scan(instance: String, distro: GuestDistro) throws -> Report? {
        guard let user = GuestUser.forUserFacingWork(in: instance) else { return nil }
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: scanScript(user: user), user: "")
        return parse(output)
    }

    /// Hands the files back. Returns how many changed.
    public static func repair(instance: String, distro: GuestDistro) throws -> Int {
        guard let user = GuestUser.forUserFacingWork(in: instance) else { return 0 }
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: repairScript(user: user), user: "")
        return parseRepaired(output) ?? 0
    }
}
