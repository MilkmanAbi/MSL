import XCTest
@testable import MSLCore

final class GuestDNSTests: XCTestCase {
    func testOfferedChoicesAreSane() {
        XCTAssertTrue(GuestDNS.Choice.automatic.servers.isEmpty)
        XCTAssertEqual(GuestDNS.Choice.cloudflare.servers.first, "1.1.1.1")
        for choice in GuestDNS.Choice.offered.dropFirst() {
            XCTAssertTrue(choice.servers.allSatisfy(GuestDNS.isValidServer), choice.name)
            XCTAssertGreaterThanOrEqual(choice.servers.count, 2, "\(choice.name) should have a fallback")
        }
    }

    func testAddressValidation() {
        for good in ["1.1.1.1", "8.8.4.4", "192.168.0.1", "255.255.255.255"] {
            XCTAssertTrue(GuestDNS.isValidServer(good), good)
        }
        for bad in ["", "1.1.1", "1.1.1.256", "1.1.1.1.1", "one.one.one.one", "1.1.1.-1", "1.1.1.1 ; rm -rf /"] {
            XCTAssertFalse(GuestDNS.isValidServer(bad), bad)
        }
    }

    /// The three things that own resolv.conf on the distros MSL ships.
    func testApplyHandlesEveryResolverOwner() {
        let script = GuestDNS.applyScript(.cloudflare)
        XCTAssertTrue(script.contains("resolved.conf.d/msl-dns.conf"), "systemd-resolved needs a drop-in")
        XCTAssertTrue(script.contains("RESOLV_CONF=\"no\""), "Alpine's udhcpc would overwrite it")
        XCTAssertTrue(script.contains("[ ! -L /etc/resolv.conf ]"), "never write through a symlink resolved owns")
        XCTAssertTrue(script.contains("1.1.1.1"))
    }

    /// Automatic means "undo what MSL did", not "write something else".
    func testAutomaticReverts() {
        let script = GuestDNS.applyScript(.automatic)
        XCTAssertTrue(script.contains("rm -f /etc/systemd/resolved.conf.d/msl-dns.conf"))
        // It may still write the default gateway, so that undoing never
        // leaves the guest with no resolver, but never a resolver of MSL's
        // choosing: none of the offered servers may appear.
        // (1.1.1.1 does appear - as the image default it *replaces*.)
        for server in GuestDNS.Choice.offered.flatMap(\.servers) {
            XCTAssertFalse(script.contains("nameserver \(server)"), "reverting must not pick \(server)")
        }
    }

    /// A resolv.conf MSL did not write belongs to the user or the distro.
    func testRevertOnlyRemovesMSLsOwnFile() {
        XCTAssertTrue(GuestDNS.revertScript().contains("grep -qs 'Written by MSL'"))
    }

    func testReadsActiveServers() {
        let output = "MSL-DNS-RESOLVCONF 1.1.1.1\r\nMSL-DNS-RESOLVCONF 1.0.0.1\r\n"
        XCTAssertEqual(GuestDNS.parseActive(output), ["1.1.1.1", "1.0.0.1"])
        XCTAssertEqual(GuestDNS.parse(output).source, .resolvConf)
        XCTAssertTrue(GuestDNS.succeeded("MSL-DNS-OK\r\n"))
        XCTAssertFalse(GuestDNS.succeeded("something went wrong"))
    }
}

extension GuestDNSTests {
    /// Every generated script must be valid shell. The first live run failed
    /// with "unexpected end of file" because the marker text contains an
    /// apostrophe and ended its own single-quoted string.
    func testEveryScriptParsesAsShell() throws {
        for (name, script) in [("apply-cloudflare", GuestDNS.applyScript(.cloudflare)),
                               ("apply-custom", GuestDNS.applyScript(GuestDNS.Choice(name: "C", servers: ["10.0.0.1"]))),
                               ("revert", GuestDNS.revertScript()),
                               ("read", GuestDNS.readScript),
                               ("automatic", GuestDNS.automaticScript),
                               ("apply-automatic", GuestDNS.applyScript(.automatic)),
                               ("mac-links", GuestHomeLinks.script)] {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("msl-dns-\(name)-\(UUID().uuidString).sh")
            try Data(script.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", file.path]
            let errors = Pipe()
            check.standardError = errors
            try check.run()
            check.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(check.terminationStatus, 0, "\(name) is not valid shell: \(message)")
        }
    }
}

extension GuestDNSTests {
    /// Reverting must never leave the guest unable to resolve anything. The
    /// first live revert deleted resolv.conf and nothing rewrote it, so the
    /// instance had no resolver at all until its next DHCP lease.
    func testRevertRestoresAndNeverLeavesNoResolver() {
        let revert = GuestDNS.revertScript()
        XCTAssertTrue(revert.contains("resolv.conf.msl-backup"), "the original file should come back")
        XCTAssertTrue(revert.contains("! -s /etc/resolv.conf"), "an empty resolv.conf must be caught")
        XCTAssertTrue(revert.contains("awk '/^default/"), "the gateway is the last-resort resolver")
        XCTAssertTrue(GuestDNS.applyScript(.cloudflare).contains("cp /etc/resolv.conf /etc/resolv.conf.msl-backup"))
    }
}

extension GuestDNSTests {
    /// Applying and reverting has to be a round trip in udhcpc.conf too: the
    /// first version left its comment behind, so every cycle added a line.
    func testUdhcpcCommentIsRemovedOnRevert() {
        XCTAssertTrue(GuestDNS.applyScript(.quad9).contains("Added by MSL so its DNS choice"))
        let revert = GuestDNS.revertScript()
        XCTAssertTrue(revert.contains("/Added by MSL so its DNS choice/d"))
        XCTAssertTrue(revert.contains(#"/RESOLV_CONF="no"/d"#))
    }
}

extension GuestDNSTests {
    /// The reader used to report systemd-resolved's stub listener. On Debian
    /// and Ubuntu that meant `msl dns <name> cloudflare` succeeded and then
    /// the very next read said the instance resolved with 127.0.0.53.
    func testResolvedStubIsNeverTheAnswer() {
        let output = """
        MSL-DNS-UPSTREAM 1.1.1.1
        MSL-DNS-UPSTREAM 1.0.0.1
        MSL-DNS-CONFIGURED 1.1.1.1
        MSL-DNS-CONFIGURED 1.0.0.1
        MSL-DNS-RESOLVCONF 127.0.0.53
        """
        let reading = GuestDNS.parse(output)
        XCTAssertEqual(reading.servers, ["1.1.1.1", "1.0.0.1"])
        XCTAssertEqual(reading.source, .resolved)
        XCTAssertFalse(reading.servers.contains("127.0.0.53"))
    }

    /// A resolved that will not answer `resolvectl dns` still leaves MSL's
    /// own drop-in, which is a better answer than the stub.
    func testFallsBackToTheDropIn() {
        let reading = GuestDNS.parse("MSL-DNS-CONFIGURED 9.9.9.9\nMSL-DNS-RESOLVCONF 127.0.0.53\n")
        XCTAssertEqual(reading.servers, ["9.9.9.9"])
        XCTAssertEqual(reading.source, .configured)
    }

    /// And when a stub is genuinely all there is, say so rather than
    /// pretending it is a chosen resolver.
    func testStubOnlyIsLabelled() {
        let reading = GuestDNS.parse("MSL-DNS-RESOLVCONF 127.0.0.53\n")
        XCTAssertEqual(reading.source, .stubOnly)
        XCTAssertEqual(GuestDNS.parse("").source, .unknown)
    }

    /// Duplicates come back from resolvectl (once per link) and would read
    /// as "1.1.1.1, 1.1.1.1" in the panel.
    func testDuplicatesCollapse() {
        XCTAssertEqual(GuestDNS.parseActive("MSL-DNS-UPSTREAM 1.1.1.1\nMSL-DNS-UPSTREAM 1.1.1.1\n"), ["1.1.1.1"])
    }
}

extension GuestDNSTests {
    /// "Automatic" follows the Mac's network through the NAT gateway, and
    /// never overrides a resolver somebody chose.
    func testAutomaticUsesTheGatewayAndRespectsChoices() throws {
        let script = GuestDNS.automaticScript
        XCTAssertTrue(script.contains("/proc/net/route"))
        XCTAssertTrue(script.contains("grep -qs 'Written by MSL'"), "a chosen resolver must be left alone")
        XCTAssertTrue(GuestDNS.applyScript(.automatic).hasSuffix(script))

        // Run the gateway decoding for real: 0140A8C0 is 192.168.64.1.
        let decode = """
        hex=0140A8C0
        set -- $(echo "$hex" | sed 's/\\(..\\)\\(..\\)\\(..\\)\\(..\\)/\\4 \\3 \\2 \\1/')
        printf '%d.%d.%d.%d' "0x$1" "0x$2" "0x$3" "0x$4"
        """
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = ["-c", decode]
        let out = Pipe()
        run.standardOutput = out
        try run.run()
        run.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "192.168.64.1")
        XCTAssertTrue(script.contains(#"sed 's/\(..\)\(..\)\(..\)\(..\)/\4 \3 \2 \1/'"#))
    }
}
