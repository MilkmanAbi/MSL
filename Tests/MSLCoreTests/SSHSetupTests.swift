import XCTest
@testable import MSLCore

/// The parts of one-command SSH that can be wrong without looking wrong.
///
/// Address picking and config merging both fail *quietly*: the wrong
/// interface yields an address that connects to nothing, and a duplicated
/// `Host` block silently shadows the fresh one because ssh takes the first
/// match it finds.
final class SSHSetupTests: XCTestCase {

    // MARK: - Picking the guest's address

    /// Real `ip -4 -o addr show` output from a systemd guest.
    private let typical = """
    1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever
    2: enp0s1    inet 192.168.64.7/24 metric 100 brd 192.168.64.255 scope global dynamic enp0s1\\       valid_lft 2591sec preferred_lft 2591sec
    """

    func testPicksTheGuestNicNotLoopback() {
        XCTAssertEqual(SSHSetup.parseGuestAddress(typical), "192.168.64.7")
    }

    func testPrefersTheVMNicOverSomeoneElsesBridge() {
        // A guest with Docker installed has a docker0 address that is
        // perfectly valid and completely useless to connect to.
        let withDocker = """
        1: lo    inet 127.0.0.1/8 scope host lo
        2: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
        3: enp0s1    inet 192.168.64.7/24 brd 192.168.64.255 scope global dynamic enp0s1
        """
        XCTAssertEqual(SSHSetup.parseGuestAddress(withDocker), "192.168.64.7")
    }

    func testBusyboxStyleEthNameIsAlsoPreferred() {
        let alpine = """
        1: lo    inet 127.0.0.1/8 scope host lo
        2: eth0    inet 192.168.64.9/24 brd 192.168.64.255 scope global eth0
        """
        XCTAssertEqual(SSHSetup.parseGuestAddress(alpine), "192.168.64.9")
    }

    func testFallsBackToAnyNonLoopbackAddress() {
        // Better an unusual interface name than nothing at all.
        let odd = """
        1: lo    inet 127.0.0.1/8 scope host lo
        2: wlan9    inet 10.0.0.4/24 scope global wlan9
        """
        XCTAssertEqual(SSHSetup.parseGuestAddress(odd), "10.0.0.4")
    }

    func testNoAddressWhenOnlyLoopbackExists() {
        // A guest whose DHCP has not come up yet. Must be nil, not "127.0.0.1".
        XCTAssertNil(SSHSetup.parseGuestAddress("1: lo    inet 127.0.0.1/8 scope host lo"))
        XCTAssertNil(SSHSetup.parseGuestAddress(""))
        XCTAssertNil(SSHSetup.parseGuestAddress("command not found"))
    }

    // MARK: - ~/.ssh/config

    func testAppendsToAnEmptyConfig() {
        let merged = SSHSetup.mergeConfig(existing: "", instance: "default",
                                          host: "192.168.64.7", user: "msl")
        XCTAssertTrue(merged.contains("Host msl-default"))
        XCTAssertTrue(merged.contains("HostName 192.168.64.7"))
        XCTAssertTrue(merged.contains("User msl"))
    }

    func testLeavesTheUsersOwnEntriesAlone() {
        let existing = """
        Host work
            HostName work.example.com
            User someone
        """
        let merged = SSHSetup.mergeConfig(existing: existing, instance: "default",
                                          host: "192.168.64.7", user: "msl")
        XCTAssertTrue(merged.contains("Host work"), "the user's own config must survive")
        XCTAssertTrue(merged.contains("HostName work.example.com"))
        XCTAssertTrue(merged.contains("Host msl-default"))
    }

    /// The one that matters. ssh uses the FIRST matching Host block, so an
    /// appended second block for the same alias would be silently ignored
    /// and the user would connect to the old address forever.
    func testRewritingReplacesInPlaceRatherThanAppending() {
        let first = SSHSetup.mergeConfig(existing: "", instance: "default",
                                         host: "192.168.64.7", user: "msl")
        let second = SSHSetup.mergeConfig(existing: first, instance: "default",
                                          host: "192.168.64.99", user: "msl")

        let occurrences = second.components(separatedBy: "Host msl-default").count - 1
        XCTAssertEqual(occurrences, 1, "a second block would shadow the first")
        XCTAssertTrue(second.contains("HostName 192.168.64.99"))
        XCTAssertFalse(second.contains("192.168.64.7"), "the stale address must be gone")
    }

    func testMergingIsIdempotent() {
        let once = SSHSetup.mergeConfig(existing: "", instance: "default",
                                        host: "192.168.64.7", user: "msl")
        let twice = SSHSetup.mergeConfig(existing: once, instance: "default",
                                         host: "192.168.64.7", user: "msl")
        XCTAssertEqual(once, twice)
    }

    func testTwoInstancesGetSeparateBlocks() {
        var config = SSHSetup.mergeConfig(existing: "", instance: "default",
                                          host: "192.168.64.7", user: "msl")
        config = SSHSetup.mergeConfig(existing: config, instance: "work",
                                      host: "192.168.64.8", user: "msl")
        XCTAssertTrue(config.contains("Host msl-default"))
        XCTAssertTrue(config.contains("Host msl-work"))
        // And updating one must not disturb the other.
        config = SSHSetup.mergeConfig(existing: config, instance: "default",
                                      host: "192.168.64.77", user: "msl")
        XCTAssertTrue(config.contains("HostName 192.168.64.77"))
        XCTAssertTrue(config.contains("HostName 192.168.64.8"))
    }

    func testHostKeyCheckingIsOffWithAStatedReason() {
        // A rebuilt guest gets a new host key, and a mismatch warning after
        // every rebuild teaches people to ignore mismatch warnings.
        let block = SSHSetup.configBlock(instance: "default", host: "10.0.0.1", user: "msl")
        XCTAssertTrue(block.contains("StrictHostKeyChecking no"))
        XCTAssertTrue(block.contains("UserKnownHostsFile /dev/null"))
        XCTAssertTrue(block.contains("IdentitiesOnly yes"),
                      "otherwise ssh offers every key in the agent before MSL's own")
    }

    // MARK: - The guest script

    func testTheGuestScriptIsIdempotent() {
        let script = SSHSetup.guestSetupScript(publicKey: "ssh-ed25519 AAAA test", user: "msl")
        XCTAssertTrue(script.contains("grep -qxF"),
                      "re-running setup must not stack duplicate authorized_keys lines")
    }

    func testTheGuestScriptReportsAMissingServerRatherThanInstallingOne() {
        // Installing needs a package manager and a network, and a guest with
        // its Network gate cut would just hang.
        let script = SSHSetup.guestSetupScript(publicKey: "k", user: "msl")
        XCTAssertTrue(script.contains("MSL_NO_SSHD"))
        XCTAssertFalse(script.contains("apk add"))
        XCTAssertFalse(script.contains("apt-get"))
    }

    func testTheGuestScriptHandlesBothInitSystems() {
        let script = SSHSetup.guestSetupScript(publicKey: "k", user: "msl")
        XCTAssertTrue(script.contains("rc-update"), "OpenRC (Alpine)")
        XCTAssertTrue(script.contains("systemctl"), "systemd (everything else)")
    }

    /// A public key is text crossing a pty and a guest shell, so it gets
    /// quoted. Asserting "the dangerous substring is absent" would be wrong -
    /// it IS present, inertly, inside single quotes. So this asks a real
    /// shell what the quoted form actually expands to.
    func testQuotedValuesSurviveARealShellUnchanged() throws {
        for hostile in ["key'; rm -rf /; echo '", "plain-key", "with space", #"back\slash"#, "$(whoami)", "`id`"] {
            let quoted = DesktopEntry.shellQuote(hostile)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(out, hostile, "shell quoting changed the value for \(hostile)")
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testTheScriptEmbedsTheKeyInQuotedFormNotRaw() {
        let script = SSHSetup.guestSetupScript(publicKey: "key'; rm -rf /", user: "msl")
        // The escaped-quote sequence is the proof the value was quoted at all.
        XCTAssertTrue(script.contains(#"'\''"#), "the embedded key was not shell-quoted")
    }

    func testAliasIsPerInstance() {
        XCTAssertEqual(SSHSetup.alias(for: "default"), "msl-default")
        XCTAssertNotEqual(SSHSetup.alias(for: "default"), SSHSetup.alias(for: "work"))
    }

    /// Both halves matter: the answer, and how long it takes to get it.
    ///
    /// A blocking `connect()` ignores `SO_SNDTIMEO` and runs to the system
    /// TCP timeout - about 75 seconds, which is what this test measured
    /// before `canReach` was rewritten to poll a non-blocking socket. That
    /// call sits behind a button, so the timeout is the feature.
    func testUnreachableHostIsReportedQuickly() {
        // 203.0.113.0/24 is TEST-NET-3: reserved for documentation and not
        // routable, so this cannot accidentally succeed.
        let started = Date()
        XCTAssertFalse(SSHSetup.canReach(host: "203.0.113.1", port: 22, timeout: 1))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "canReach must honour its timeout, not the system's")
    }

    func testAClosedPortOnAReachableHostIsRefusedNotHung() {
        // Loopback with (almost certainly) nothing listening: poll wakes the
        // socket as writable, and only SO_ERROR distinguishes refused from
        // connected.
        let started = Date()
        XCTAssertFalse(SSHSetup.canReach(host: "127.0.0.1", port: 9, timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

/// When MSL sets an instance up without being asked.
///
/// This trigger hangs off a poll loop that rebuilds the instance list every
/// few seconds, and every false fire is a guest shell round trip that
/// installs a key and starts a service. The guards are the feature, and they
/// are the only part of the automatic path testable without a guest.
final class SSHAutoSetupTests: XCTestCase {

    private func shouldFire(previous: VMManager.InstanceState?,
                            current: VMManager.InstanceState,
                            enabled: Bool = true,
                            inFlight: Bool = false,
                            hasRecord: Bool = false) -> Bool {
        SSHAutoSetup.shouldConfigure(previous: previous, current: current,
                                     enabled: enabled, inFlight: inFlight,
                                     hasRecord: hasRecord)
    }

    func testFiresOnAColdStart() {
        XCTAssertTrue(shouldFire(previous: .stopped, current: .running))
        XCTAssertTrue(shouldFire(previous: .transitioning, current: .running))
    }

    /// A resume keeps the guest's address and its authorized_keys, so there
    /// is nothing to redo - and this is the transition that happens most.
    func testDoesNotFireOnAResume() {
        XCTAssertFalse(shouldFire(previous: .paused, current: .running))
    }

    func testDoesNotFireWhenNothingChanged() {
        XCTAssertFalse(shouldFire(previous: .running, current: .running))
    }

    func testDoesNotFireForAnInstanceThatIsNotRunning() {
        for state in [VMManager.InstanceState.stopped, .paused, .transitioning] {
            XCTAssertFalse(shouldFire(previous: .stopped, current: state), "\(state)")
        }
    }

    /// The subtle one. On app launch (or after a daemon restart) there is no
    /// previous state for anything, so every running instance looks like it
    /// just transitioned. Without this, opening the app would reconfigure
    /// every running instance every time.
    func testFirstSightOfARunningInstanceOnlyFiresIfItWasNeverConfigured() {
        XCTAssertTrue(shouldFire(previous: nil, current: .running, hasRecord: false),
                      "a never-configured instance is worth one attempt")
        XCTAssertFalse(shouldFire(previous: nil, current: .running, hasRecord: true),
                       "one MSL already knows must not be redone on every app launch")
    }

    func testRespectsTheSetting() {
        XCTAssertFalse(shouldFire(previous: .stopped, current: .running, enabled: false))
    }

    func testNeverOverlapsWithARunningAttempt() {
        XCTAssertFalse(shouldFire(previous: .stopped, current: .running, inFlight: true))
    }

    // MARK: - The stored record

    func testRecordRoundTripsThroughItsStoredForm() throws {
        let record = SSHSetup.Record(host: "192.168.64.7", user: "msl", alias: "msl-default",
                                     fingerprint: "SHA256:abc123")
        let decoded = try JSONDecoder().decode(SSHSetup.Record.self,
                                               from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testRecordsArePerInstance() {
        XCTAssertNotEqual(SSHSetup.RecordStore.file(for: "default"),
                          SSHSetup.RecordStore.file(for: "work"))
    }

    func testAnUnknownInstanceHasNoRecordRatherThanAnEmptyOne() {
        XCTAssertNil(SSHSetup.RecordStore.load(instance: "never-seen-\(UUID().uuidString)"))
        XCTAssertNil(SSHSetup.cachedResult(instance: "never-seen-\(UUID().uuidString)"))
    }

    func testAFreshRecordIsNotStale() {
        let fresh = SSHSetup.Record(host: "10.0.0.1", user: "msl", alias: "msl-x")
        XCTAssertFalse(SSHAutoSetup.recordIsStale(fresh))
        let old = SSHSetup.Record(host: "10.0.0.1", user: "msl", alias: "msl-x",
                                  lastConfigured: Date(timeIntervalSinceNow: -60 * 60 * 24))
        XCTAssertTrue(SSHAutoSetup.recordIsStale(old))
    }

    /// A cached record must never present itself as confirmed. The guest's
    /// address can move while it is switched off, and a confidently wrong
    /// address is worse than an obviously stale one.
    func testCachedDetailsAreMarkedUnverified() throws {
        let instance = "cache-test-\(UUID().uuidString)"
        defer { SSHSetup.RecordStore.forget(instance: instance) }
        SSHSetup.RecordStore.save(SSHSetup.Record(host: "192.168.64.7", user: "msl",
                                                  alias: "msl-\(instance)"),
                                  instance: instance)
        let cached = try XCTUnwrap(SSHSetup.cachedResult(instance: instance))
        XCTAssertFalse(cached.verifiedThisSession)
        XCTAssertFalse(cached.reachable, "an unprobed record must not claim reachability")
        XCTAssertEqual(cached.host, "192.168.64.7")
    }

    // MARK: - Fingerprint

    func testParsesTheGuestFingerprint() {
        let output = """
        MSL_SSH_FP SHA256:2xK9Lm0pQrStUvWxYz1234567890abcdefGHIJKL
        MSL_SSH_READY
        2: enp0s1    inet 192.168.64.7/24 scope global enp0s1
        """
        XCTAssertEqual(SSHSetup.parseFingerprint(output),
                       "SHA256:2xK9Lm0pQrStUvWxYz1234567890abcdefGHIJKL")
        // And the address still parses out of the same blob.
        XCTAssertEqual(SSHSetup.parseGuestAddress(output), "192.168.64.7")
    }

    /// Real output from a Debian 13 guest (2026-09-14): CRLF line endings
    /// from the pty, and iproute2 colouring every address. Before the fix,
    /// the fingerprint swallowed everything after it and the host came out
    /// as a colour-coded 127.0.0.1.
    func testParsesRealPtyOutputWithCRLFAndColour() {
        let output = "MSL_SSH_FP SHA256:YB/IsWbMsA1GFnnvRk7EePSGSiiUN5S7AOI5WVBRlaU\r\nMSL_SSH_READY\r\n"
            + "1: lo    inet \u{1B}[35m127.0.0.1\u{1B}[0m/8 scope host lo\\       valid_lft forever preferred_lft forever\r\n"
            + "2: \u{1B}[36menp0s1    \u{1B}[0minet \u{1B}[35m192.168.64.64\u{1B}[0m/24 metric 1024 brd \u{1B}[35m192.168.64.255 \u{1B}[0mscope global dynamic enp0s1\\       valid_lft 3598sec preferred_lft 3598sec\r\n"
        XCTAssertEqual(SSHSetup.parseFingerprint(output), "SHA256:YB/IsWbMsA1GFnnvRk7EePSGSiiUN5S7AOI5WVBRlaU")
        XCTAssertEqual(SSHSetup.parseGuestAddress(output), "192.168.64.64")
    }

    /// Alpine's busybox `ip` doesn't colour, but the lines still end in CRLF.
    func testParsesBusyboxOutputWithCRLF() {
        let output = "MSL_SSH_FP SHA256:ivkQHnWAnj5vF0ktAVFPTfVkpQ57tuu7CuwPgPFi6Ns\r\nMSL_SSH_READY\r\n"
            + "2: eth0    inet 192.168.64.66/24 scope global eth0\\       valid_lft forever preferred_lft forever\r\n"
        XCTAssertEqual(SSHSetup.parseFingerprint(output), "SHA256:ivkQHnWAnj5vF0ktAVFPTfVkpQ57tuu7CuwPgPFi6Ns")
        XCTAssertEqual(SSHSetup.parseGuestAddress(output), "192.168.64.66")
    }

    /// Blocks written before 2026-09-14 had an unquoted IdentityFile under
    /// "Application Support" - which made ssh reject the whole config - and
    /// could carry colour codes in HostName. Any later write repairs every
    /// MSL block, and leaves the user's own entries exactly as they were.
    func testRewritingTheConfigRepairsEarlierBlocks() {
        let key = "/Users/someone/Library/Application Support/MSL/ssh/msl_ed25519"
        let existing = """
        Host work
            IdentityFile /Users/someone/.ssh/id work
        # >>> MSL arch >>>
        Host msl-arch
            HostName \u{1B}[1;35m127.0.0.1\u{1B}[0m
            IdentityFile \(key)
        # <<< MSL arch <<<
        """
        let merged = SSHSetup.mergeConfig(existing: existing, instance: "debian", host: "192.168.64.7", user: "abi")
        XCTAssertTrue(merged.contains("    IdentityFile \"\(key)\""), "the old block's key path must be quoted")
        XCTAssertFalse(merged.contains("\u{1B}"), "no escape codes may survive")
        XCTAssertTrue(merged.contains("    HostName 127.0.0.1"))
        XCTAssertTrue(merged.contains("    IdentityFile /Users/someone/.ssh/id work"),
                      "entries outside MSL's markers are the user's and stay untouched")
        XCTAssertTrue(merged.contains("IdentityFile \"\(SSHSetup.privateKeyPath)\""), "the new block is quoted too")
    }

    func testAMissingFingerprintIsNilNotEmpty() {
        XCTAssertNil(SSHSetup.parseFingerprint("MSL_SSH_READY"))
        XCTAssertNil(SSHSetup.parseFingerprint("MSL_SSH_FP "))
    }

    // MARK: - The admin's copy-everything block

    func testShareableSummaryCarriesWhatSomeoneElseNeeds() {
        let result = SSHSetup.Result(host: "192.168.64.7", user: "msl", alias: "msl-default",
                                     reachable: true, fingerprint: "SHA256:abc")
        let summary = result.shareableSummary
        XCTAssertTrue(summary.contains("ssh msl-default"))
        XCTAssertTrue(summary.contains("msl@192.168.64.7"))
        XCTAssertTrue(summary.contains("SHA256:abc"), "the fingerprint is the only check left")
        XCTAssertTrue(summary.contains(SSHSetup.privateKeyPath))
    }
}
