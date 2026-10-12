import Foundation
import XCTest
@testable import MSLCore

/// A connection handed to an app host counts as delivered only when the
/// host says so. Before, `send` returned true as soon as the bytes were in
/// the socket buffer, so a host that exited between connect and accept
/// swallowed the client's display connection (xhell's DOWN results).
final class X11HandoffAckTests: XCTestCase {
    private func socketPath() -> String {
        NSTemporaryDirectory() + "msl-ack-\(UUID().uuidString.prefix(8)).sock"
    }

    private func dummyFD() -> Int32 {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        close(fds[1])
        return fds[0]
    }

    func testAnAcknowledgedHandoffIsDelivered() {
        let path = socketPath()
        guard let listener = X11FDChannel.listen(atSocketPath: path) else { return XCTFail("listen") }
        defer { close(listener); unlink(path) }
        Thread {
            if let h = X11FDChannel.accept(on: listener) {
                close(h.fd)
                X11FDChannel.acknowledge(h.control)
            }
        }.start()
        let fd = dummyFD()
        defer { close(fd) }
        XCTAssertTrue(X11FDChannel.send(fd: fd, payload: [1, 2, 3], toSocketPath: path))
    }

    /// A host on its way out declines: the router must see a failure, which
    /// is what makes it start a fresh host instead of losing the client.
    func testADeclinedHandoffIsNotDelivered() {
        let path = socketPath()
        guard let listener = X11FDChannel.listen(atSocketPath: path) else { return XCTFail("listen") }
        defer { close(listener); unlink(path) }
        Thread {
            if let h = X11FDChannel.accept(on: listener) {
                close(h.fd)
                close(h.control)   // no ack
            }
        }.start()
        let fd = dummyFD()
        defer { close(fd) }
        XCTAssertFalse(X11FDChannel.send(fd: fd, payload: [], toSocketPath: path))
    }

    func testNoHostAtAllIsNotDelivered() {
        let fd = dummyFD()
        defer { close(fd) }
        XCTAssertFalse(X11FDChannel.send(fd: fd, payload: [], toSocketPath: socketPath()))
    }
}
