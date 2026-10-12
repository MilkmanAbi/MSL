import Foundation

/// Which Linux user MSL runs something as.
///
/// Every shell MSL opens already asks this question (`msl`'s `resolveUser`),
/// but the things MSL runs *for* you did not: launching a Linux app, scanning
/// an instance for apps, fetching an icon. They all took the shell protocol's
/// default, and an empty user there means **root**. So every GUI app MSL
/// started ran as root, wrote its configuration into root's home, and
/// sometimes refused to run at all (2026-09-21: Nautilus says so out loud).
///
/// The rule is the one a person would expect: work MSL does on the user's
/// behalf runs as the user's own account. Root stays deliberate, asked for by
/// name with `msl <instance> -u root`, and the things that genuinely need it
/// (creating the account, installing an SSH key, maintenance) keep asking for
/// it explicitly.
public enum GuestUser {
    /// The account for work done on the user's behalf in `instance`, or nil
    /// when it has no account yet and the caller has to deal with that.
    /// Keyed by instance: each one has its own disk and so its own
    /// `/etc/passwd` (`InstanceDisk`).
    public static func forUserFacingWork(in instance: String,
                                        lookup: (String) -> String? = { LinuxUserSetup.defaultUser(forInstance: $0) }) -> String? {
        lookup(instance)
    }

    /// What to pass to `ShellClient` for user-facing work: the account when
    /// there is one, and root otherwise.
    ///
    /// Falling back to root is deliberate, and only reachable before the
    /// first-run account exists: an instance with no account can still be
    /// scanned and started, exactly as it could before. Callers that can ask
    /// for an account first should do that instead - see
    /// `AppModel.needsUserSetup`.
    public static func shellUser(forInstance instance: String,
                                lookup: (String) -> String? = { LinuxUserSetup.defaultUser(forInstance: $0) }) -> String {
        forUserFacingWork(in: instance, lookup: lookup) ?? ""
    }

    // MARK: - Finding the account when nothing recorded one

    /// The `/etc/passwd` line format, reduced to what matters here.
    struct Account: Equatable {
        let name: String
        let uid: Int
        let home: String
        let shell: String
    }

    /// Shells that mean "this account cannot log in": a system account, not
    /// a person.
    static let nonLoginShells: Set<String> = [
        "/usr/sbin/nologin", "/sbin/nologin", "/usr/bin/nologin",
        "/bin/false", "/usr/bin/false", "",
    ]

    /// Picks the human account out of `/etc/passwd`.
    ///
    /// MSL used to rely entirely on having *recorded* an account when it
    /// created one. Anything else - an account made with `adduser` in a
    /// terminal, a registry that lost its entry, an instance adopted from
    /// elsewhere - left MSL running every app as root, which is exactly what
    /// v2 set out to stop. The passwd file is the authority; the registry is
    /// only a cache of it.
    ///
    /// Lowest uid at or above 1000 wins: that is the first account created
    /// on every distro MSL ships, and it is the one a person thinks of as
    /// theirs. 65534 is `nobody`. Accounts that cannot log in are skipped,
    /// as is `root` itself.
    public static func pick(fromPasswd text: String) -> String? {
        var candidates: [Account] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let uid = Int(fields[2]) else { continue }
            let account = Account(name: fields[0], uid: uid, home: fields[5], shell: fields[6])
            guard account.uid != 0, account.uid != 65534, account.name != "nobody",
                  !nonLoginShells.contains(account.shell),
                  account.home.hasPrefix("/home/") || account.home == "/root" || !account.home.isEmpty
            else { continue }
            candidates.append(account)
        }
        // Real user range first; 500 covers the older Red Hat convention,
        // and is only consulted when nothing modern is there.
        for floor in [1000, 500] {
            if let best = candidates.filter({ $0.uid >= floor }).min(by: { $0.uid < $1.uid }) {
                return best.name
            }
        }
        return nil
    }

    /// Reads the guest's accounts. Runs as root, because this is what
    /// decides who everything else runs as.
    static func discover(instance: String, distro: GuestDistro) -> String? {
        let script = """
        cat /etc/passwd 2>/dev/null
        command -v getent >/dev/null 2>&1 && getent passwd 2>/dev/null
        """
        guard let output = try? ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: script, user: "").1 else { return nil }
        return pick(fromPasswd: output)
    }

    /// The account MSL acts as in `instance`, asking the guest when nothing
    /// has been recorded yet, and remembering the answer.
    ///
    /// Recorded per instance - each has its own disk and so its own
    /// `/etc/passwd`. See `DefaultUserRegistry`.
    public static func resolve(instance: String, distro: GuestDistro) -> String? {
        if let known = LinuxUserSetup.defaultUser(forInstance: instance) { return known }
        guard let found = discover(instance: instance, distro: distro) else { return nil }
        try? LinuxUserSetup.registry().setDefaultUser(found, forInstance: instance)
        return found
    }

    /// What to pass to `ShellClient`, with the guest consulted when needed.
    /// Empty (root) only when the guest really has no human account yet.
    public static func shellUser(instance: String, distro: GuestDistro) -> String {
        resolve(instance: instance, distro: distro) ?? ""
    }

    /// Whether a command will run as root, for logs and error messages.
    public static func isRoot(_ user: String) -> Bool {
        user.isEmpty || user == "root"
    }
}
