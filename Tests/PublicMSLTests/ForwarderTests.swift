import XCTest
import Darwin
@testable import PublicMSL

/// The port forwarder, which is the only moving part of the Tailscale
/// backend and the one thing in it that can be tested without a tailnet.
final class PortForwarderTests: XCTestCase {

    /// A throwaway TCP server that echoes what it is sent, standing in for
    /// the guest's sshd.
    private func startEchoServer() -> (port: UInt16, stop: () -> Void) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                      // let the kernel pick
        address.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listener, 4)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                        guard count > 0 else { break }
                        _ = buffer.withUnsafeBytes { write(client, $0.baseAddress, count) }
                    }
                    close(client)
                }.start()
            }
        }.start()
        return (port, { close(listener) })
    }

    private func freePort() -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) }
        }
        close(probe)
        return UInt16(bigEndian: bound.sin_port)
    }

    private func send(_ text: String, toPort port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        var window = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    func testItCarriesTrafficBothWays() throws {
        let target = startEchoServer()
        defer { target.stop() }
        let forwarder = PortForwarder(listenPort: freePort(), targetHost: "127.0.0.1",
                                      targetPort: target.port)
        try forwarder.start()
        defer { forwarder.stop() }
        XCTAssertEqual(send("SSH-2.0-probe", toPort: forwarder.listenPort), "SSH-2.0-probe")
    }

    func testItHandlesSeveralConnections() throws {
        // sshd is not a one-shot service, and the first version of the
        // accept loop would have stopped after a single odd connection.
        let target = startEchoServer()
        defer { target.stop() }
        let forwarder = PortForwarder(listenPort: freePort(), targetHost: "127.0.0.1",
                                      targetPort: target.port)
        try forwarder.start()
        defer { forwarder.stop() }
        for index in 0..<5 {
            XCTAssertEqual(send("probe-\(index)", toPort: forwarder.listenPort), "probe-\(index)")
        }
    }

    func testAPortAlreadyInUseSaysSo() throws {
        let target = startEchoServer()
        defer { target.stop() }
        let port = freePort()
        let first = PortForwarder(listenPort: port, targetHost: "127.0.0.1", targetPort: target.port)
        try first.start()
        defer { first.stop() }

        let second = PortForwarder(listenPort: port, targetHost: "127.0.0.1", targetPort: target.port)
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertTrue("\(error)".contains("already in use"),
                          "the usual failure deserves the usual words")
        }
    }

    func testStoppingReleasesThePort() throws {
        let target = startEchoServer()
        defer { target.stop() }
        let port = freePort()
        let first = PortForwarder(listenPort: port, targetHost: "127.0.0.1", targetPort: target.port)
        try first.start()
        first.stop()
        // Without SO_REUSEADDR and a real close, republishing on the same
        // port would fail for minutes afterwards.
        let second = PortForwarder(listenPort: port, targetHost: "127.0.0.1", targetPort: target.port)
        XCTAssertNoThrow(try second.start())
        second.stop()
    }

    func testAnUnreachableGuestDoesNotWedgeTheListener() throws {
        // The guest can be paused or gone. Those connections must fail and
        // the forwarder must carry on serving the next one.
        let forwarder = PortForwarder(listenPort: freePort(), targetHost: "127.0.0.1",
                                      targetPort: 1)   // nothing listens on port 1
        try forwarder.start()
        defer { forwarder.stop() }
        XCTAssertNil(send("hello", toPort: forwarder.listenPort))

        let target = startEchoServer()
        defer { target.stop() }
        let working = PortForwarder(listenPort: freePort(), targetHost: "127.0.0.1",
                                    targetPort: target.port)
        try working.start()
        defer { working.stop() }
        XCTAssertEqual(send("still-here", toPort: working.listenPort), "still-here")
    }
}

/// Reading Tailscale's state.
final class TailscaleCLITests: XCTestCase {

    func testItLooksInsideTheAppBundleToo() {
        // The App Store build keeps the tool inside the bundle rather than
        // on PATH, so `which tailscale` finds nothing on a working install.
        XCTAssertTrue(TailscaleCLI.candidates.contains {
            $0.contains("Tailscale.app/Contents/MacOS")
        })
        XCTAssertTrue(TailscaleCLI.candidates.contains("/usr/local/bin/tailscale"))
    }

    func testAMissingInstallStatesWhatIsNeeded() {
        // Nothing here may throw when Tailscale is absent: the backend
        // reports a requirement instead, which the app shows as a sentence
        // rather than as a failure.
        if TailscaleCLI.find() == nil {
            let requirement = TailscaleBackend().requirement
            XCTAssertNotNil(requirement, "with Tailscale missing, say so rather than failing")
            XCTAssertTrue(requirement?.contains("tailscale.com") == true,
                          "and say where to get it")
        } else {
            XCTAssertNil(TailscaleBackend().requirement,
                         "with Tailscale installed there is nothing to ask for")
        }
    }

    func testThePolicyTokenRoundTrips() throws {
        let backend = TailscaleBackend(port: 2345)
        let restored = try XCTUnwrap(TailscaleBackend.fromPolicyToken(backend.policyToken))
        XCTAssertEqual(restored.port, 2345)
        XCTAssertNil(TailscaleBackend.fromPolicyToken("self-hosted:x:1"))
    }
}
