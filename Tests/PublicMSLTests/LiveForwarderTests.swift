import Darwin
import XCTest
@testable import PublicMSL

/// Forwards to a running guest and checks a real sshd answers through it.
///
/// Opt-in: set `MSL_TEST_GUEST` to the guest's IP. Skipped otherwise,
/// because a test suite must not depend on a virtual machine being up. The
/// unit tests beside it prove the forwarder with a local echo server; this
/// one proves it against the thing it actually has to carry.
final class LiveForwarderTests: XCTestCase {
    func testForwardsRealSSH() throws {
        let guestIP = ProcessInfo.processInfo.environment["MSL_TEST_GUEST"] ?? ""
        try XCTSkipIf(guestIP.isEmpty, "set MSL_TEST_GUEST to run this")
        let forwarder = PortForwarder(listenPort: 47222, targetHost: guestIP, targetPort: 22)
        try forwarder.start()
        defer { forwarder.stop() }
        let banner = SelfHostedBackend.banner(host: "127.0.0.1", port: 47222, timeout: 8)
        XCTAssertNotNil(banner, "nothing answered through the forwarder")
        XCTAssertTrue(banner?.hasPrefix("SSH-") == true, "got: \(banner ?? "nothing")")
        print("FORWARDER-PROOF: \(banner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }
}
