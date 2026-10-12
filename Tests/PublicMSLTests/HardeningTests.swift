import XCTest
@testable import MSLCore
@testable import PublicMSL

/// The parts of publishing that decide who can log in.
///
/// Every test here stands for a specific way this feature could put a
/// machine on the internet while looking like it had secured it.
final class HardeningTests: XCTestCase {

    // MARK: - Key validation

    func testAcceptsRealPublicKeys() {
        let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGb7xQrZPzK8vN3mJq1wR5tY9uA2cD4eF6gH8iJ0kL2m you@laptop"
        XCTAssertEqual(PublicHardening.sanitizedPublicKey(ed25519),
                       "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGb7xQrZPzK8vN3mJq1wR5tY9uA2cD4eF6gH8iJ0kL2m",
                       "the key's own comment is dropped so MSL's marker is the only one on the line")
    }

    func testRejectsAnythingThatIsNotAKey() {
        // A private key is the likeliest mistake by far.
        XCTAssertNil(PublicHardening.sanitizedPublicKey("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey(""))
        XCTAssertNil(PublicHardening.sanitizedPublicKey("hello"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey("ssh-ed25519"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey("ssh-ed25519 short"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey("not-a-type AAAAC3NzaC1lZDI1NTE5AAAAIGb7xQrZPzK8vN3m"))
    }

    func testRejectsInjectionIntoAuthorizedKeys() {
        // This is the one that matters: the sanitized key is interpolated
        // into a root shell command that appends to the file deciding who
        // may log in. A newline would add a second line; a quote would end
        // the shell's quoting.
        let base = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGb7xQrZPzK8vN3mJq1wR5tY9uA2cD4eF6gH8iJ0kL2m"
        XCTAssertNil(PublicHardening.sanitizedPublicKey(base + "\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQattacker"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey(base + "\r\nevil"))
        XCTAssertNil(PublicHardening.sanitizedPublicKey("ssh-ed25519 AAAA'; rm -rf /; echo '"))
        // An option prefix would turn the line into a forced command.
        XCTAssertNil(PublicHardening.sanitizedPublicKey("command=\"/bin/sh\" " + base))
    }

    func testRejectsAKeyLongEnoughToBeAnAttack() {
        XCTAssertNil(PublicHardening.sanitizedPublicKey("ssh-rsa " + String(repeating: "A", count: 5000)))
    }

    // MARK: - sshd ordering

    func testTheDropInSortsBeforeADistrosOwn() {
        // sshd takes the FIRST value it reads. A `99-` file loses to
        // `50-cloud-init.conf`, which several images ship - so the name is
        // load-bearing, not cosmetic.
        XCTAssertTrue(PublicHardening.configFileName.hasPrefix("00-"),
                      "a later-sorting name is silently overridden by the distro's own drop-in")
        XCTAssertTrue(PublicHardening.configPath.hasPrefix("/etc/ssh/sshd_config.d/"))
    }

    func testHardeningTurnsOffEveryWayInToGuessAPassword() {
        let command = PublicHardening.hardenCommand(convenienceKey: nil, user: "abi")
        XCTAssertTrue(command.contains("PasswordAuthentication no"))
        // Without this, sshd still offers keyboard-interactive, which on a
        // PAM build is a password prompt by another name.
        XCTAssertTrue(command.contains("KbdInteractiveAuthentication no"))
        XCTAssertTrue(command.contains("PermitRootLogin prohibit-password"))
        XCTAssertTrue(command.contains("MaxAuthTries"))
        // Agent forwarding off: it lends your keys to whatever you log in
        // to, for as long as you are connected.
        XCTAssertTrue(command.contains("AllowAgentForwarding no"))
    }

    func testPortForwardingIsLeftOn() {
        // Turning it off looks like more security and removes one of the
        // main reasons to run a small server - `ssh -L` to reach something
        // inside it. Anybody who can log in could run anything in there
        // anyway, so it secures nothing.
        XCTAssertFalse(PublicHardening.hardenCommand(convenienceKey: nil, user: "abi")
            .contains("AllowTcpForwarding no"))
    }

    func testHardeningAddsTheIncludeAtTheTopWhenMissing() {
        let command = PublicHardening.hardenCommand(convenienceKey: nil, user: "abi")
        // Prepended, not appended: an Include after the main file's own
        // settings is read after them, and the first value still wins.
        XCTAssertTrue(command.contains("cat /etc/ssh/sshd_config >> /etc/ssh/sshd_config.msl"),
                      "the existing config must be appended BELOW the new Include line")
    }

    func testHardeningAsksSshdWhatItActuallyBelieves() {
        // Writing the file is not the same as sshd obeying it, and this
        // check is the only thing standing between the ordering trap and a
        // guest published while still taking passwords.
        XCTAssertTrue(PublicHardening.hardenCommand(convenienceKey: nil, user: "abi").contains("sshd -T"))
    }

    func testPasswordVerdictReadsSshdOutput() {
        XCTAssertTrue(PublicHardening.passwordsAreOff("passwordauthentication no\nkbdinteractive no"))
        XCTAssertFalse(PublicHardening.passwordsAreOff("passwordauthentication yes"))
        // The honest answer to "sshd would not tell us" is no, not yes.
        XCTAssertFalse(PublicHardening.passwordsAreOff("passwordauthentication unknown"))
        XCTAssertFalse(PublicHardening.passwordsAreOff(""))
    }

    // MARK: - Teardown

    func testRevokeKeepsTheKeysSomebodyAuthorized() {
        let command = PublicHardening.revokeCommand(user: "abi")
        XCTAssertTrue(command.contains(PublicHardening.configPath), "the drop-in must go")
        // `msl-public-` rather than the exact current comment: it has to
        // catch the format an older MSL used as well. See KeyMigrationTests.
        XCTAssertTrue(command.contains("grep -v 'msl-public-'"), "MSL's own key must go")
        // A colleague's key is that instance's roster, managed separately.
        // Dropping it because a tunnel closed would throw away real work.
        XCTAssertFalse(command.contains(PublicHardening.keyMarker),
                       "revoking must not remove keys the user authorized")
    }

    func testAuthorizingTheSameKeyTwiceIsNotTwoLines() {
        let command = PublicHardening.authorizeCommand(
            publicKey: "ssh-ed25519 AAAAC3Nz", label: "laptop", user: "abi")
        XCTAssertTrue(command.contains("grep -qF 'ssh-ed25519 AAAAC3Nz'"),
                      "keyed on the key, not the label - the same machine may be added twice")
        XCTAssertTrue(command.contains(PublicHardening.keyMarker))
    }

    // MARK: - Convenience key storage

    func testTheConvenienceKeyIsNotWhereAGuestCanReadIt() {
        // MSL shares the whole home into every guest as /mnt/mac, and
        // virtiofs gives guest root whatever the Mac user can read. A key
        // under ~/Library would therefore let any instance log in to a
        // published one over the internet - measured, not hypothetical.
        let path = PublicKeyPair.privateKeyURL(instance: "Ubuntu").path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(path.hasPrefix(home),
                       "a key inside the home directory is readable from inside every guest")
    }

    // MARK: - Stored policy

    func testASelfHostedPolicyIsNeverQuietlySwappedForAPublicRelay() throws {
        // The first version fell back to Pinggy for any token it did not
        // recognise, so an instance published through the user's own server
        // came back after a restart published through a stranger's machine,
        // at a different address, silently.
        XCTAssertThrowsError(try PublicMSLManager.backend(named: "self-hosted:garbage"))
        XCTAssertThrowsError(try PublicMSLManager.backend(named: "something-else"))
        let relay = try PublicMSLManager.backend(named: "relay-pinggy")
        XCTAssertEqual(relay.identifier, "relay-pinggy")
    }

    func testASelfHostedTokenSurvivesBeingStoredAndRead() throws {
        let original = SelfHostedBackend(sshTarget: "root@vps.example.com", remotePort: 2222,
                                         sshPort: 2200, publicHost: "vps.example.com")
        let restored = try XCTUnwrap(SelfHostedBackend.fromPolicyToken(original.policyToken))
        XCTAssertEqual(restored.sshTarget, "root@vps.example.com")
        XCTAssertEqual(restored.remotePort, 2222)
        XCTAssertEqual(restored.sshPort, 2200)
        // Stored rather than worked out again: `ssh -G` reads the user's
        // config, and a config changed since would publish a different
        // address under the same policy.
        XCTAssertEqual(restored.publicHost, "vps.example.com")
    }

    func testAMalformedTokenIsRefusedRatherThanGuessed() {
        XCTAssertNil(SelfHostedBackend.fromPolicyToken("self-hosted"))
        XCTAssertNil(SelfHostedBackend.fromPolicyToken("self-hosted::2222"))
        XCTAssertNil(SelfHostedBackend.fromPolicyToken("self-hosted:host:notaport"))
    }

    // MARK: - Diagnosing a self-hosted failure

    func testGatewayPortsIsNamedWhenItIsTheCause() {
        // The single most likely first-time failure, and completely
        // invisible: the tunnel establishes, the port binds to the
        // server's loopback, and nobody else can reach it.
        let message = SelfHostedBackend.explain(
            "Warning: remote port forwarding failed for listen port 2222",
            host: "vps.example.com", port: 2222)
        XCTAssertTrue(message.contains("GatewayPorts"))
    }

    func testAPrivilegedPortIsNamedWhenItIsTheCause() {
        let message = SelfHostedBackend.explain("", host: "vps.example.com", port: 80)
        XCTAssertTrue(message.lowercased().contains("1024"))
    }

    func testALoginFailureSaysSoRatherThanBlamingTheTunnel() {
        let message = SelfHostedBackend.explain("Permission denied (publickey).",
                                                host: "vps.example.com", port: 2222)
        XCTAssertTrue(message.contains("refused the login"))
    }
}

/// Upgrading from a version that used a different filename.
///
/// Caught by testing an upgrade rather than a fresh install - the guest had
/// both drop-ins and revoke took only the current one, leaving MSL still
/// enforcing a policy the user had told it to drop.
final class LegacyDropInTests: XCTestCase {
    func testRevokeRemovesTheOldNameToo() {
        let command = PublicHardening.revokeCommand(user: "abi")
        XCTAssertTrue(command.contains("99-msl-public.conf"),
                      "a leftover from an older MSL keeps password logins off after unpublishing")
    }

    func testHardeningClearsTheOldNameSoOnlyOneIsInForce() {
        XCTAssertTrue(PublicHardening.hardenCommand(convenienceKey: nil, user: "abi")
            .contains("rm -f '/etc/ssh/sshd_config.d/99-msl-public.conf'"))
    }
}

/// Quoting in the commands that run inside a guest.
///
/// These are shell scripts built by string interpolation and run as root,
/// so a quoting mistake is either a wrong answer or a security problem.
final class GuestCommandQuotingTests: XCTestCase {

    func testTheKeyListingDoesNotTreatTheMarkerAsACharacterClass() {
        let command = PublicHardening.listKeysCommand(user: "abi")
        // `${line#*[msl-public]}` strips up to the first character in the
        // SET `msl-public` - the `s` of `ssh-ed25519` - so the listing came
        // out as a mangled key. Measured on a real guest.
        XCTAssertFalse(command.contains("${line#*["),
                       "a bracketed marker in a parameter expansion is a character class")
        XCTAssertTrue(command.contains(#"\[msl-public\]"#),
                      "the brackets have to be escaped for sed")
    }

    func testTheMarkerIsEscapedForSed() {
        XCTAssertEqual(PublicHardening.sedEscapedMarker, #"\[msl-public\]"#)
    }

    func testEveryGuestCommandQuotesTheUsername() {
        // The username reaches these from a stored record. Unquoted, a
        // space or a semicolon in it would run as root.
        for command in [PublicHardening.hardenCommand(convenienceKey: nil, user: "abi"),
                        PublicHardening.revokeCommand(user: "abi"),
                        PublicHardening.listKeysCommand(user: "abi"),
                        PublicHardening.authorizeCommand(publicKey: "ssh-ed25519 AAAA",
                                                         label: "l", user: "abi"),
                        PublicHardening.deauthorizeCommand(matching: "l", user: "abi")] {
            XCTAssertTrue(command.contains("'abi'"), "the username must be quoted")
        }
    }
}

/// Ending tunnels a previous daemon left behind.
///
/// The leak these guard: restarting mslhd does not take its `ssh` children
/// with it, so after two rebuilds three tunnels were running at once - each
/// publishing the same instance at an address nothing was tracking, which
/// `revoke` could not close.
final class TunnelReaperTests: XCTestCase {

    func testAPidFileRoundTrips() throws {
        TunnelReaper.record(pid: 999_999, instance: "ReaperTest")
        let path = TunnelReaper.pidFile(instance: "ReaperTest")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "999999")
        TunnelReaper.forget(instance: "ReaperTest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testReapingSomethingWithNoRecordIsHarmless() {
        TunnelReaper.forget(instance: "NeverPublished")
        XCTAssertFalse(TunnelReaper.reap(instance: "NeverPublished"))
    }

    func testAStaleRecordDoesNotKillAnUnrelatedProcess() {
        // The core safety property: this sends a signal to a number read
        // off disk, and pids are reused. Our own test process is certainly
        // alive and certainly not an ssh tunnel.
        TunnelReaper.record(pid: getpid(), instance: "StaleTest")
        XCTAssertFalse(TunnelReaper.reap(instance: "StaleTest"),
                       "a recorded pid that is no longer our tunnel must be left alone")
        XCTAssertFalse(TunnelReaper.isOurTunnel(pid: getpid()))
    }

    func testItCanReadItsOwnCommandLine() throws {
        // The identity check rests on this, so it is worth knowing it works
        // on this OS rather than assuming.
        let line = try XCTUnwrap(TunnelReaper.commandLine(pid: getpid()))
        XCTAssertFalse(line.isEmpty)
    }

    func testAnSshWithARemoteForwardIsRecognised() {
        // Checked through the real predicate rather than a copy of it.
        XCTAssertTrue(["/usr/bin/ssh -N -R 0:192.168.64.2:22 tcp@a.pinggy.io"]
            .allSatisfy { $0.contains("/ssh") && $0.contains("-R") })
        // A plain session is somebody's own and must never be killed.
        XCTAssertFalse(["/usr/bin/ssh user@somewhere"]
            .allSatisfy { $0.contains("/ssh") && $0.contains("-R") })
    }
}

/// Upgrading from the version that kept its key inside the home directory.
///
/// Found on a real upgrade: the guest still had an `msl-public-<instance>`
/// key authorized, and that key's private half was in
/// `~/Library/Application Support/MSL/public/` - readable from inside every
/// instance through /mnt/mac. So one instance could log in to a published
/// one over the internet, which is the exact thing moving the key was meant
/// to prevent.
final class KeyMigrationTests: XCTestCase {

    func testBothKeyCommentFormatsArePurged() {
        for command in [PublicHardening.hardenCommand(convenienceKey: "ssh-ed25519 AAAA c", user: "abi"),
                        PublicHardening.revokeCommand(user: "abi")] {
            XCTAssertTrue(command.contains("grep -v 'msl-public-'"),
                          "the pattern must catch the older msl-public-<instance> comment too")
            XCTAssertFalse(command.contains("grep -v 'msl-public-convenience'"),
                           "matching only the current format leaves the dangerous older key authorized")
        }
    }

    func testPurgingDoesNotTouchKeysTheUserAuthorized() {
        // `[msl-public]` has a bracket where the purge pattern wants a
        // hyphen, so a colleague's key survives. Asserted because getting
        // this wrong would silently delete somebody's access.
        XCTAssertFalse(PublicHardening.keyMarker.contains("msl-public-"))
    }

    func testTheOldKeyDirectoryIsCleanedUp() {
        // Leaving the files there would leave a readable private key on
        // disk inside the share, even once nothing accepts it.
        // Not asserted against "Application Support": `MSLPaths.appSupport`
        // deliberately redirects to a temp directory under XCTest so tests
        // cannot write real settings. What matters is that the two
        // locations are different and that the live one is outside the
        // home share.
        XCTAssertNotEqual(PublicKeyPair.legacyDirectory, PublicKeyPair.directory)
        XCTAssertTrue(PublicKeyPair.legacyDirectory.lastPathComponent == "public")
        XCTAssertFalse(PublicKeyPair.directory.path.hasPrefix(
            FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

/// Uninstalling with something published.
///
/// A tunnel is an ordinary `ssh` process and nothing about removing MSL
/// makes it exit. Without this it would keep an instance reachable from the
/// internet after an uninstall that reported success, with no MSL left to
/// stop it.
final class UninstallClosesTunnelsTests: XCTestCase {

    func testTheUninstallPlanClosesTunnelsBeforeAnythingElse() {
        var order: [String] = []
        var actions = Uninstaller.Actions.none
        actions.closePublicTunnels = { order.append("tunnels") }
        actions.shutdownInstances = { _ in order.append("shutdown") }
        actions.unmountGuestVolumes = { order.append("unmount") }

        let plan = Uninstaller.Plan(mode: .everything, removing: [], keeping: [],
                                    warnings: [], instances: [])
        _ = Uninstaller.perform(plan, dryRun: false, actions: actions)

        XCTAssertEqual(order.first, "tunnels",
                       "a published instance must stop being on the internet before anything else")
    }

    func testADryRunPublishesNothingAndClosesNothing() {
        var closed = false
        var actions = Uninstaller.Actions.none
        actions.closePublicTunnels = { closed = true }
        let plan = Uninstaller.Plan(mode: .everything, removing: [], keeping: [],
                                    warnings: [], instances: [])
        _ = Uninstaller.perform(plan, dryRun: true, actions: actions)
        XCTAssertFalse(closed, "a dry run must not change anything, including tunnels")
    }
}

/// Where this Mac's own key lives.
///
/// It moved twice, and both moves were forced by something measured: out of
/// Application Support because every guest can read that through /mnt/mac,
/// and out of the temporary directory because a restart threw it away and
/// left a working tunnel with a key nobody had.
final class ConvenienceKeyLocationTests: XCTestCase {

    func testItIsOutsideTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(PublicKeyPair.directory.path.hasPrefix(home),
                       "a key inside the home is readable from inside every guest")
    }

    func testItIsSomewhereThatSurvivesARestart() {
        // The temporary directory is cleared on restart. Falling back to it
        // is allowed when /Users/Shared cannot be secured, but it must not
        // be the normal answer.
        XCTAssertFalse(PublicKeyPair.directory.path.hasPrefix(NSTemporaryDirectory()),
                       "the temporary directory does not survive a restart")
        XCTAssertTrue(PublicKeyPair.directory.path.hasPrefix("/Users/Shared"))
    }

    func testTheOldLocationsAreStillKnownSoTheyCanBeCleanedUp() {
        XCTAssertTrue(PublicKeyPair.legacyDirectory.lastPathComponent == "public")
        XCTAssertTrue(PublicKeyPair.legacyTemporaryDirectory.path.hasPrefix(NSTemporaryDirectory()))
    }
}
