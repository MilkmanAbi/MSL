import XCTest
@testable import MSLCore
#if canImport(Darwin)
import Darwin
#endif

/// A stopped `WebDAVServer` must stop listening.
///
/// The bug: `stop()` only `close()`d the listen socket. On Darwin that doesn't
/// wake a thread blocked in `accept()`, and the blocked call keeps the socket
/// listening - so a "stopped" bridge went on accepting connections, and the
/// requests it served started VMs. It booted an unregistered Arch VM long
/// after that instance was removed (2026-09-14).
///
/// No guest is involved: the client is told it may never wake one, so the
/// only thing under test is the socket's lifetime.
final class WebDAVServerStopTests: XCTestCase {
    private func makeServer() -> WebDAVServer {
        let configuration = VMConfiguration(name: "webdav-stop-test-\(UUID().uuidString.prefix(8))",
                                            kernelPath: "/nonexistent/Image",
                                            initrdPath: "/nonexistent/initramfs")
        let client = FileOpsClient(manager: VMManager(configuration: configuration), mayWake: { false })
        return WebDAVServer(fileOpsClient: client, guestRoot: "/", bindAddress: "127.0.0.1",
                            instanceName: configuration.name)
    }

    /// Connects to 127.0.0.1:`port`; returns the socket, or -1 if refused.
    private func connectLoopback(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    func testStoppedServerRefusesNewConnections() throws {
        let server = makeServer()
        let port = try server.start()

        let before = connectLoopback(port)
        XCTAssertGreaterThanOrEqual(before, 0, "a started server should accept")
        if before >= 0 { close(before) }

        // Let the accept thread get back into accept() - the state the bug
        // needed - before stopping.
        Thread.sleep(forTimeInterval: 0.2)
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)

        let after = connectLoopback(port)
        if after >= 0 { close(after) }
        XCTAssertEqual(after, -1, "a stopped server must not still be listening")
    }

    func testRequestAfterStopIsNotServed() throws {
        let server = makeServer()
        let port = try server.start()
        Thread.sleep(forTimeInterval: 0.2)
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)

        let fd = connectLoopback(port)
        guard fd >= 0 else { return }   // refused outright: the good outcome
        defer { close(fd) }
        let request = "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64)
        let got = read(fd, &buffer, buffer.count)
        XCTAssertLessThanOrEqual(got, 0, "a stopped server answered a request")
    }
}
