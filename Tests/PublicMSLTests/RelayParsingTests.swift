import XCTest
@testable import PublicMSL

/// Finding the address in what a relay prints.
///
/// Every string here is real output captured from a live tunnel on
/// 2026-10-04, banner and warnings included - because the thing that breaks
/// this is a relay changing its wording, and a test written from
/// imagination would not have caught the two traps below.
final class RelayParsingTests: XCTestCase {

    /// Exactly what Pinggy printed, down to the post-quantum warning.
    private let realTranscript = """
    Pseudo-terminal will not be allocated because stdin is not a terminal.
    Warning: Permanently added '[a.pinggy.io]:443' (RSA) to the list of known hosts.
    ** WARNING: connection is not using a post-quantum key exchange algorithm.
    ** This session may be vulnerable to "store now, decrypt later" attacks.
    ** The server may need to be upgraded. See https://openssh.com/pq.html
    Allocated port 2 for remote forward to localhost:53917
    You are not authenticated.
    Your tunnel will expire in 60 minutes. Upgrade to Pinggy Pro to get unrestricted tunnels. https://dashboard.pinggy.io
    tcp://kokdn-218-212-52-212.run.pinggy-free.link:33075
    """

    func testFindsTheAddressInRealOutput() {
        let found = RelayBackend.parseEndpoint(realTranscript)
        XCTAssertEqual(found?.host, "kokdn-218-212-52-212.run.pinggy-free.link")
        XCTAssertEqual(found?.port, 33075)
    }

    func testIgnoresTheRelaysOwnFrontDoor() {
        // `[a.pinggy.io]:443` is in the banner before the real address, and
        // taking the first match would hand somebody the relay's own port.
        let found = RelayBackend.parseEndpoint(realTranscript)
        XCTAssertNotEqual(found?.host, "a.pinggy.io")
        XCTAssertNotEqual(found?.port, 443)
    }

    func testIgnoresTheUpgradeLink() {
        // "https://dashboard.pinggy.io" is a hostname on a line of its own
        // sort, and an over-eager pattern matches it.
        XCTAssertNotEqual(RelayBackend.parseEndpoint(realTranscript)?.host, "dashboard.pinggy.io")
    }

    func testAcceptsAnAddressWithoutTheScheme() {
        // serveo and friends print a bare host:port.
        let found = RelayBackend.parseEndpoint("Forwarding TCP connections from example.serveo.net:41234\n")
        XCTAssertEqual(found?.host, "example.serveo.net")
        XCTAssertEqual(found?.port, 41234)
    }

    func testNothingUsefulMeansNil() {
        XCTAssertNil(RelayBackend.parseEndpoint(""))
        XCTAssertNil(RelayBackend.parseEndpoint("Permission denied (publickey).\n"))
        // A banner alone must not look like an answer.
        XCTAssertNil(RelayBackend.parseEndpoint(
            "Warning: Permanently added '[a.pinggy.io]:443' (RSA) to the list of known hosts.\n"))
    }

    func testTheEndpointKnowsHowToBeTyped() {
        let endpoint = PublicEndpoint(host: "h.example.net", port: 2222, user: "abi",
                                      identityFile: "/Users/a/Application Support/MSL/public/k",
                                      expires: nil, backend: "relay-pinggy")
        // The path has a space in it, every time, on every Mac.
        // IdentitiesOnly so an agent's other keys do not use up the
        // server's attempts before this one - see IdentitiesOnlyTests.
        XCTAssertEqual(endpoint.sshCommand,
                       "ssh -i \"/Users/a/Application Support/MSL/public/k\" "
                       + "-o IdentitiesOnly=yes -p 2222 abi@h.example.net")
    }

    func testExpiryIsReportedRatherThanHidden() {
        let past = PublicEndpoint(host: "h", port: 1, user: "u", identityFile: "k",
                                  expires: Date().addingTimeInterval(-60), backend: "b")
        XCTAssertTrue(past.isExpired)
        let none = PublicEndpoint(host: "h", port: 1, user: "u", identityFile: "k",
                                  expires: nil, backend: "b")
        XCTAssertFalse(none.isExpired, "a backend with no expiry never expires")
    }
}
