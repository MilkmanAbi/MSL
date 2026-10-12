import XCTest
@testable import MSLCore

/// `GPUBridge.pump` carries the GL stream between the guest's vsock
/// connection and the renderer process. Both properties below were real
/// bugs before they were tests: the relay must move bytes both ways, and
/// it must **return** when either side goes away.
final class GPUBridgeTests: XCTestCase {
    /// Two connected socket pairs: `client` <-> a, b <-> `server`, with
    /// `pump(a, b)` in the middle - the same shape as guest <-> renderer.
    private func makePair() -> (client: Int32, a: Int32, b: Int32, server: Int32) {
        var one: [Int32] = [0, 0], two: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &one), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &two), 0)
        return (one[0], one[1], two[0], two[1])
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, bytes.count)
    }

    private func receive(_ fd: Int32, _ count: Int) -> String {
        var out = [UInt8]()
        let deadline = Date().addingTimeInterval(5)
        while out.count < count, Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: count - out.count)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { out += buffer.prefix(n) } else if n == 0 { break } else { usleep(5_000) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testItRelaysBothWays() {
        let (client, a, b, server) = makePair()
        let done = expectation(description: "pump returned")
        Thread { GPUBridge.pump(a, b); done.fulfill() }.start()

        send(client, "to the renderer")
        XCTAssertEqual(receive(server, 15), "to the renderer")
        send(server, "and back again!")
        XCTAssertEqual(receive(client, 15), "and back again!")

        close(client) // the GL app exits
        wait(for: [done], timeout: 5)
        for fd in [a, b, server] { close(fd) }
    }

    /// The leak this test exists for: when the guest's side closed, the
    /// pump kept polling the renderer - which has no reason to hang up on
    /// its own - so it never returned and the renderer process was never
    /// reaped. One orphan per GL app launch.
    func testItReturnsWhenEitherSideCloses() {
        for closeServerInstead in [false, true] {
            let (client, a, b, server) = makePair()
            let done = expectation(description: "pump returned")
            Thread { GPUBridge.pump(a, b); done.fulfill() }.start()
            close(closeServerInstead ? server : client)
            wait(for: [done], timeout: 5)
            for fd in [a, b, closeServerInstead ? client : server] { close(fd) }
        }
    }

    /// In-flight bytes are not dropped on the way out: whatever the client
    /// sent before closing still reaches the renderer.
    func testItFlushesWhatWasAlreadySentBeforeClosing() {
        let (client, a, b, server) = makePair()
        let done = expectation(description: "pump returned")
        Thread { GPUBridge.pump(a, b); done.fulfill() }.start()
        send(client, "last words")
        close(client)
        XCTAssertEqual(receive(server, 10), "last words")
        wait(for: [done], timeout: 5)
        for fd in [a, b, server] { close(fd) }
    }

    /// The renderer is looked up, never assumed - a machine without it
    /// keeps rendering on the guest's CPU instead of failing.
    func testRendererLookupIsHonestAboutBeingAbsent() {
        let found = GPUBridge.locateRenderer()
        if let found {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found))
            XCTAssertTrue(GPUBridge.rendererSearchPaths.contains(found))
        }
        XCTAssertFalse(GPUBridge.rendererSearchPaths.isEmpty)
    }
}

/// The GPU path must be wired into real app launches, not just test scripts,
/// and both of its guards must hold - these are what make it seamless when
/// on and inert (never broken) when off.
final class GPULaunchIntegrationTests: XCTestCase {
    private func launch(gpu: Bool) -> String {
        var settings = MSLExperimentalSettings()
        settings.gpuAcceleration = gpu
        return GuestIntegration.launchCommand("chromium", instance: "test-no-overrides", settings: settings)
    }

    func testFlagOffNeverTouchesTheGPUPath() {
        let script = launch(gpu: false)
        XCTAssertFalse(script.contains("virpipe"), "GPU off must not select virpipe")
        XCTAssertFalse(script.contains("/tmp/.virgl_test"), "GPU off must not start the tunnel")
    }

    func testFlagOnEmitsTheGuardedGPUPathWhenARendererExists() {
        // The host gate: the lines appear only when a renderer is installed,
        // so guest and host never disagree.
        guard GPUBridge.locateRenderer() != nil else {
            XCTAssertFalse(launch(gpu: true).contains("virpipe"),
                           "with no renderer installed, even flag-on must stay on the CPU")
            return
        }
        let script = launch(gpu: true)
        XCTAssertTrue(script.contains("GALLIUM_DRIVER=virpipe"), "selects the GPU driver")
        XCTAssertTrue(script.contains("5011"), "tunnels to the GPU vsock port")
        // The guest gate: it must refuse to start a tunnel with an x11tunnel
        // that predates --socket-path, or it would hijack a display.
        XCTAssertTrue(script.contains("grep -q -- --socket-path"),
                      "must verify the tunnel understands --socket-path first")
        // GTK4 stays on cairo on purpose.
        XCTAssertTrue(script.contains("GSK_RENDERER=cairo"))
    }
}
