// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

/// What has to be true of a guest before its SSH port may face the
/// internet.
///
/// **MSL's images ship with `PasswordAuthentication yes`.** On a LAN that is
/// a convenience; on a public address it is an invitation - an exposed port
/// 22 sees automated password guessing within minutes, and an instance's
/// account password is whatever somebody typed into a setup prompt. Checked
/// on a stock Ubuntu image: `sshd -T` reported `passwordauthentication yes`.
///
/// So exposure hardens first and publishes second, and it is not optional.
/// Nothing here can lock anybody out: `msl <instance>` reaches the guest
/// over vsock, which has no relationship to sshd at all, so a lost key
/// means a lost *remote* login and never a lost machine.
public enum PublicHardening {

    /// **`00-`, not `99-`.** sshd takes the *first* value it reads for most
    /// keywords, so a file sorting after a distro's own drop-in loses to it
    /// - and several images ship one. On a cloud-init image a `99-` file
    /// saying `PasswordAuthentication no` is read after
    /// `50-cloud-init.conf` saying yes, and the yes wins.
    ///
    /// The `sshd -T` check below is what caught this: it reports what sshd
    /// believes rather than what was written, so the wrong name failed
    /// loudly instead of publishing a guest that still took passwords.
    public static let configFileName = "00-msl-public.conf"
    public static let configPath = "/etc/ssh/sshd_config.d/\(configFileName)"

    /// The name an earlier MSL used, removed on revoke as well.
    ///
    /// Found by testing an upgrade rather than a fresh install: the guest
    /// had both files, and revoking took only the new one. The leftover
    /// says the same thing, so nothing breaks - but it keeps password
    /// logins off after the user asked for the instance to be unpublished,
    /// which is MSL quietly still enforcing a policy it was told to drop.
    static let legacyConfigPaths = ["/etc/ssh/sshd_config.d/99-msl-public.conf"]

    /// Marks the lines in `authorized_keys` that MSL put there, so they can
    /// be taken out again exactly. Left visible on purpose: somebody
    /// reading the file should be able to see where a key came from.
    public static let keyMarker = "[msl-public]"

    /// The root command that makes a guest safe to expose.
    ///
    /// Written as a drop-in rather than edited into `sshd_config`: an edit
    /// has to be undone exactly, and a file can simply be deleted.
    public static func hardenCommand(convenienceKey: String?, user: String) -> String {
        let installKey = convenienceKey.map { key in
            """
            # The one key MSL generated for connecting from this Mac.
            # Stale ones go first - it is regenerated whenever the Mac's
            # temporary directory is cleared, and two would be confusing.
            #
            # The pattern is `msl-public-`, not the current comment, so it
            # also catches the format an older MSL used. That matters more
            # than tidiness: those older keys had their private half in
            # ~/Library, which every guest can read through /mnt/mac, so one
            # left authorized here is a key any instance could use to log
            # in to this one over the internet. Found on a real upgrade.
            # The `[msl-public]` marker on keys the user authorized does not
            # match this, so their own machines are untouched.
            grep -v 'msl-public-' "$ak" > "$ak.msl" 2>/dev/null || true
            mv -f "$ak.msl" "$ak" 2>/dev/null || true
            printf '%s\\n' '\(key)' >> "$ak"
            """
        } ?? "# No convenience key: this instance is reached with keys you authorized."

        return """
        set -e
        command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ] || { echo MSL_NO_SSHD; exit 0; }
        mkdir -p /etc/ssh/sshd_config.d
        # An older MSL's file would otherwise sit alongside this one, both
        # in force and only one of them removable on revoke.
        rm -f \(legacyConfigPaths.map { "'\($0)'" }.joined(separator: " "))
        cat > '\(configPath)' <<'MSL_PUBLIC_EOF'
        # Written by MSL when this instance is published beyond the Mac, and
        # removed when it is unpublished. Named 00- deliberately: sshd takes
        # the first value it reads, so this has to be read before any
        # drop-in the distro ships.
        #
        # Password guessing against a public port 22 starts within minutes,
        # and an instance's password is whatever was typed at a setup
        # prompt. Keys only.
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin prohibit-password
        # OpenSSH's own default. It was 3, which looked like sensible
        # tightening and is actively harmful: MaxAuthTries counts *every*
        # key the client offers, and an ssh-agent with a few identities
        # loaded - the normal state of a Windows or work laptop - burns
        # through three before it reaches the key you were sent. The server
        # hangs up and reports `Permission denied (publickey)` about a key
        # it never looked at.
        #
        # It buys almost nothing either: the limit is per connection, and
        # anything brute-forcing simply reconnects.
        MaxAuthTries 6
        # A published port collects connections that open and never
        # authenticate. These keep them from accumulating.
        LoginGraceTime 20
        MaxStartups 10:30:60
        # Agent forwarding stays off: it lets whatever you log in to use
        # your keys for as long as you are connected, which is a real way
        # to lose them and is almost never wanted here.
        AllowAgentForwarding no
        #
        # TCP forwarding deliberately stays ON. Turning it off looks like
        # more security and takes away one of the main reasons to run a
        # small server: `ssh -L 8080:localhost:8080 you@your-instance` to
        # reach something running inside it. The people who can log in are
        # the people whose keys you added, and they can already run
        # anything in there - denying them a port forward secures nothing
        # and costs the use case.
        #
        # It is also not academic: it was on briefly, and it stopped a
        # published instance being usable as a jump host at all.
        MSL_PUBLIC_EOF

        # The Include has to be read *before* the distro's own settings for
        # the same reason the file is called 00-. Debian and Ubuntu ship it
        # at the top already; some minimal images have none at all, and
        # without one the drop-in above is read by nobody.
        if ! grep -qs 'sshd_config.d' /etc/ssh/sshd_config; then
            printf 'Include /etc/ssh/sshd_config.d/*.conf\\n' > /etc/ssh/sshd_config.msl
            cat /etc/ssh/sshd_config >> /etc/ssh/sshd_config.msl
            mv /etc/ssh/sshd_config.msl /etc/ssh/sshd_config
        fi

        home=$(getent passwd '\(user)' 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || home=/home/\(user)
        mkdir -p "$home/.ssh"
        ak="$home/.ssh/authorized_keys"
        touch "$ak"
        \(installKey)
        chmod 700 "$home/.ssh"; chmod 600 "$ak"
        chown -R '\(user)' "$home/.ssh" 2>/dev/null || true

        (systemctl reload ssh || systemctl reload sshd || rc-service sshd reload \\
            || systemctl restart ssh || rc-service sshd restart) >/dev/null 2>&1 || true

        # Report what sshd actually believes, not what was written. A
        # drop-in that is read too late, or not at all, fails silently and
        # this is the only thing that would catch it.
        (sshd -T 2>/dev/null || /usr/sbin/sshd -T 2>/dev/null) \\
            | grep -iE '^(passwordauthentication|kbdinteractiveauthentication)' \\
            || echo 'passwordauthentication unknown'
        """
    }

    /// Undoes it. Keys the user authorized stay: they are that instance's
    /// roster of people, managed with `msl public authorize`, and dropping
    /// them because the tunnel closed would throw away real work. The key
    /// MSL generated for itself does go.
    public static func revokeCommand(user: String) -> String {
        """
        rm -f '\(configPath)' \(legacyConfigPaths.map { "'\($0)'" }.joined(separator: " "))
        home=$(getent passwd '\(user)' 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || home=/home/\(user)
        ak="$home/.ssh/authorized_keys"
        if [ -f "$ak" ]; then
            grep -v 'msl-public-' "$ak" > "$ak.msl" 2>/dev/null || true
            mv -f "$ak.msl" "$ak" 2>/dev/null || true
            chown '\(user)' "$ak" 2>/dev/null || true
            chmod 600 "$ak" 2>/dev/null || true
        fi
        (systemctl reload ssh || systemctl reload sshd || rc-service sshd reload) >/dev/null 2>&1 || true
        echo MSL_PUBLIC_REVOKED
        """
    }

    /// Adds a key belonging to a machine somebody will connect *from*.
    ///
    /// This is the mechanism that matters for real use. The other laptop
    /// already has a keypair; MSL authorizes its public half, and no
    /// private key ever moves between machines. It is also the right shape
    /// for a team - one key per person, each removable on its own.
    public static func authorizeCommand(publicKey: String, label: String, user: String) -> String {
        let line = "\(publicKey) \(keyMarker) \(label)"
        return """
        home=$(getent passwd '\(user)' 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || home=/home/\(user)
        mkdir -p "$home/.ssh"
        ak="$home/.ssh/authorized_keys"
        touch "$ak"
        # Keyed on the key itself, not the label: authorizing the same
        # machine twice should not add a second line.
        if grep -qF '\(publicKey)' "$ak"; then
            echo MSL_KEY_ALREADY_THERE
        else
            printf '%s\\n' '\(line)' >> "$ak"
            echo MSL_KEY_ADDED
        fi
        chmod 700 "$home/.ssh"; chmod 600 "$ak"
        chown -R '\(user)' "$home/.ssh" 2>/dev/null || true
        """
    }

    public static func deauthorizeCommand(matching needle: String, user: String) -> String {
        """
        home=$(getent passwd '\(user)' 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || home=/home/\(user)
        ak="$home/.ssh/authorized_keys"
        [ -f "$ak" ] || { echo MSL_NO_KEYS; exit 0; }
        before=$(wc -l < "$ak")
        grep -vF '\(needle)' "$ak" > "$ak.msl" 2>/dev/null || true
        mv -f "$ak.msl" "$ak" 2>/dev/null || true
        chown '\(user)' "$ak" 2>/dev/null || true; chmod 600 "$ak" 2>/dev/null || true
        after=$(wc -l < "$ak")
        [ "$before" != "$after" ] && echo MSL_KEY_REMOVED || echo MSL_KEY_NOT_FOUND
        """
    }

    /// Lists the keys MSL put there, as `fingerprint<tab>label`.
    ///
    /// The label is cut with `sed`, not `${line#*...}`. In shell, `[...]`
    /// inside a parameter expansion is a *character class*, so stripping up
    /// to `[msl-public]` actually strips up to the first character in the
    /// set `msl-public` - which is the `s` of `ssh-ed25519`. The listing
    /// came out as `sh-ed25519 AAAA... [msl-public] work-laptop` and looked
    /// like a mangled key rather than a quoting bug.
    public static func listKeysCommand(user: String) -> String {
        """
        home=$(getent passwd '\(user)' 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || home=/home/\(user)
        ak="$home/.ssh/authorized_keys"
        [ -f "$ak" ] || exit 0
        grep -F '\(keyMarker)' "$ak" 2>/dev/null | while IFS= read -r line; do
            label=$(printf '%s' "$line" | sed -e 's/.*\(sedEscapedMarker)[[:space:]]*//')
            [ -n "$label" ] || label='(unnamed)'
            fingerprint=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
            printf '%s\t%s\n' "${fingerprint:-unknown}" "$label"
        done
        """
    }

    /// The marker with its brackets escaped for a `sed` pattern.
    static var sedEscapedMarker: String {
        keyMarker.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Whether `sshd -T` output says passwords are off.
    ///
    /// Checked rather than assumed, because the ordering trap above means
    /// writing the file is not the same as sshd obeying it.
    public static func passwordsAreOff(_ sshdOutput: String) -> Bool {
        sshdOutput.lowercased().contains("passwordauthentication no")
    }

    /// A public key as `ssh-keygen` would accept it, or nil.
    ///
    /// Validated before it is sent anywhere near `authorized_keys`: a line
    /// that is not a key, or that smuggles a newline, would otherwise be
    /// appended to the file that decides who may log in.
    public static func sanitizedPublicKey(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"), !text.contains("\r"), !text.contains("'"),
              text.count < 4096 else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2 else { return nil }
        let known = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                     "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com",
                     "sk-ecdsa-sha2-nistp256@openssh.com"]
        guard known.contains(fields[0]) else { return nil }
        // The base64 body, and nothing else: a key's own trailing comment
        // is dropped so MSL's marker is the only comment on the line.
        guard fields[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }),
              fields[1].count > 20 else { return nil }
        return "\(fields[0]) \(fields[1])"
    }
}
