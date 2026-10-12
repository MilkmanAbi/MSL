import Foundation
import Virtualization

/// The Mac's GPU, for Linux OpenGL apps.
///
/// The guest's own Mesa already knows how to do this: its `virpipe` driver
/// forwards Gallium commands over a socket instead of to a graphics card.
/// This is the other end - it carries that socket over vsock and hands it
/// to `virgl_test_server`, which replays the commands on the Mac's GPU
/// through Metal. Nothing here emulates hardware, and the guest needs no
/// driver of its own. See `Guest/virtual-gpu/README.md`.
///
/// ```
/// Linux app → Mesa (GALLIUM_DRIVER=virpipe) → /tmp/.virgl_test
///   → x11tunnel → vsock 5011 → [Mac] GPUBridge → virgl_test_server → Metal
/// ```
///
/// **One renderer process per connection, spawned - never forked.** macOS
/// forbids using system frameworks in a forked child that has not `exec`d,
/// and a forked renderer fails every Metal shader compile: ANGLE says so
/// outright, while Apple's GL only reports `buildPipelineState failed` and
/// then draws nothing at all. That is why the renderer runs with
/// `--no-fork` and why this spawns a fresh process per client rather than
/// letting one server accept several.
public final class GPUBridge: NSObject {
    /// One port for the subsystem, one connection per GL client - the same
    /// shape as `PeripheralBridge` (5010).
    public static let vsockPort: UInt32 = 5011

    /// Where the renderer might be. Not built by this package (it is
    /// virglrenderer, built separately - `Guest/virtual-gpu/build.sh`), so
    /// it is looked up rather than assumed. Absent means GL apps keep
    /// rendering on the guest's CPU, which is the pre-existing behaviour
    /// and a perfectly good fallback.
    public static var rendererSearchPaths: [String] {
        [
            MSLPaths.binDirectory.appendingPathComponent("virgl_test_server").path,
            "/opt/homebrew/opt/virglrenderer/bin/virgl_test_server",
            "/usr/local/opt/virglrenderer/bin/virgl_test_server",
        ]
    }

    public static func locateRenderer() -> String? {
        rendererSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let socketDevice: VZVirtioSocketDevice
    private let instance: String
    private var listener: VZVirtioSocketListener?
    /// Renderers started for live connections, so `stop()` can end them.
    private var renderers: [Process] = []
    private let lock = NSLock()

    public init(socketDevice: VZVirtioSocketDevice, instance: String) {
        self.socketDevice = socketDevice
        self.instance = instance
        super.init()
    }

    public func start() {
        guard let renderer = Self.locateRenderer() else {
            log("no virgl_test_server found - Linux GL apps will render on the guest's CPU")
            return
        }
        log("GPU acceleration available (\(renderer))")
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
        self.listener = listener
    }

    public func stop() {
        listener = nil
        lock.lock()
        let running = renderers
        renderers.removeAll()
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[mslgpu \(instance)] \(message)\n".data(using: .utf8)!)
    }

    /// Starts a renderer on its own socket and returns a connected fd.
    ///
    /// The renderer creates the socket itself, so this waits for it to
    /// appear rather than guessing a delay - a fixed sleep is either a
    /// stall or a race, and on a cold start it is both.
    private func startRenderer(path: String) -> (Process, Int32)? {
        let socketPath = NSTemporaryDirectory()
            .appending("msl-gpu-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock")
        try? FileManager.default.removeItem(atPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // OpenGL only for now. `--venus` would also set
        // VIRGL_RENDERER_RENDER_SERVER, which delegates to a separate
        // `virgl_render_server` process this build does not ship - with it
        // on, GL and Vulkan both hang. See Guest/virtual-gpu/README.md.
        process.arguments = ["--socket-path", socketPath, "--no-fork"]
        process.standardOutput = FileHandle.nullDevice
        // Kept, not discarded: when a GL app dies with "lost connection to
        // rendering server", the renderer's own last words (a failed shader
        // compile, an unsupported format, Metal refusing a pipeline) are the
        // only account of why. Appended per instance, trimmed at 4 MB.
        process.standardError = Self.rendererLog(instance: instance)
        do { try process.run() } catch {
            log("could not start the renderer: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath),
               let fd = Self.connect(toUnixSocket: socketPath) {
                // The renderer has it open; the name is no longer needed.
                try? FileManager.default.removeItem(atPath: socketPath)
                return (process, fd)
            }
            guard process.isRunning else { break }
            usleep(20_000)
        }
        log("the renderer did not come up")
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: socketPath)
        return nil
    }

    static func rendererLog(instance: String) -> FileHandle {
        let url = MSLPaths.logsDirectory.appendingPathComponent("virgl-\(instance).log")
        _ = MSLPaths.ensureDirectory(MSLPaths.logsDirectory)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 4 << 20 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    static func connect(toUnixSocket path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= limit else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: limit + 1) { buffer in
                _ = strncpy(buffer, path, limit)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    private func handle(connection: VZVirtioSocketConnection) {
        guard let renderer = Self.locateRenderer() else { return }
        let guestFD = dup(connection.fileDescriptor)
        guard guestFD >= 0 else { return }
        Thread { [weak self] in
            guard let self else { close(guestFD); return }
            guard let (process, rendererFD) = self.startRenderer(path: renderer) else {
                close(guestFD)
                return
            }
            self.lock.lock(); self.renderers.append(process); self.lock.unlock()
            Self.pump(guestFD, rendererFD)
            close(guestFD)
            close(rendererFD)
            // The renderer ended first: that is the guest's "lost
            // connection to rendering server". Say how, so it can be traced.
            if !process.isRunning {
                self.log("the renderer exited (status \(process.terminationStatus), "
                    + "\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")) while an app was using it - see virgl-\(self.instance).log")
            }
            // The client is gone, and this renderer served only it.
            if process.isRunning {
                process.terminate()
                // SIGTERM, then make sure. A renderer wedged inside a GL
                // call would otherwise outlive every app that used it.
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            self.lock.lock(); self.renderers.removeAll { $0 == process }; self.lock.unlock()
        }.start()
    }

    /// One direction of the relay: a fixed buffer consumed by offset.
    ///
    /// Offsets rather than trimming the front of an array: a GL frame is
    /// megabytes, and `removeFirst` on every partial write is an O(n)
    /// memmove of the remainder each time. That alone held the relay to
    /// ~330 MB/s, which on a 4 MB frame is most of the frame time.
    private struct Direction {
        let source: Int32
        let destination: Int32
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int
        var head = 0
        var tail = 0
        var sourceClosed = false

        var pending: Int { tail - head }
        var space: Int { capacity - tail }

        /// Slides what is left to the front so the tail can grow again.
        mutating func compact() {
            guard head > 0 else { return }
            if pending > 0 { memmove(buffer, buffer + head, pending) }
            tail = pending
            head = 0
        }
    }

    /// Copies bytes both ways until either side closes.
    ///
    /// One `poll` over both fds rather than a thread per direction: a
    /// blocking copy would sit in `write` and stop reading, which is the
    /// deadlock `x11tunnel`'s relay documents on the guest side.
    static func pump(_ a: Int32, _ b: Int32, bufferSize: Int = 4 << 20) {
        for fd in [a, b] {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            // Ask for room to keep a frame in flight. Best effort: the
            // kernel may clamp it, and the relay is correct either way.
            var size = Int32(bufferSize)
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let toB = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        let toA = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { toB.deallocate(); toA.deallocate() }
        var directions = [
            Direction(source: a, destination: b, buffer: toB, capacity: bufferSize),
            Direction(source: b, destination: a, buffer: toA, capacity: bufferSize),
        ]

        while true {
            // Done when a source has closed and everything it sent is gone.
            let finished = directions.contains { $0.sourceClosed && $0.pending == 0 }
            if finished { break }

            var fds = [pollfd(fd: a, events: 0, revents: 0), pollfd(fd: b, events: 0, revents: 0)]
            for direction in directions {
                let readIndex = direction.source == a ? 0 : 1
                let writeIndex = direction.destination == a ? 0 : 1
                if !direction.sourceClosed, direction.space > 0 { fds[readIndex].events |= Int16(POLLIN) }
                if direction.pending > 0 { fds[writeIndex].events |= Int16(POLLOUT) }
            }
            guard fds.contains(where: { $0.events != 0 }) else { break }
            // No timeout. A GL app that sits idle - a CAD tool with nothing
            // to redraw, an app behind a first-run dialog - sends nothing for
            // minutes, and a timeout here used to end the relay after 60 s of
            // quiet: the app's next draw hit a closed socket and Mesa aborted
            // with "lost connection to rendering server" (KiCad's 3D viewer,
            // 2026-09-28). Either side closing still ends it, via POLLHUP.
            let ready = poll(&fds, 2, -1)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }

            var broken = false
            for index in directions.indices {
                let readIndex = directions[index].source == a ? 0 : 1
                let writeIndex = directions[index].destination == a ? 0 : 1

                if fds[writeIndex].revents & Int16(POLLOUT) != 0, directions[index].pending > 0 {
                    let written = write(directions[index].destination,
                                        directions[index].buffer + directions[index].head,
                                        directions[index].pending)
                    if written > 0 {
                        directions[index].head += written
                        if directions[index].pending == 0 {
                            directions[index].head = 0
                            directions[index].tail = 0
                        }
                    } else if written < 0, errno != EAGAIN, errno != EINTR {
                        broken = true
                    }
                }

                if fds[readIndex].revents & Int16(POLLIN) != 0 {
                    directions[index].compact()
                    if directions[index].space > 0 {
                        let count = read(directions[index].source,
                                         directions[index].buffer + directions[index].tail,
                                         directions[index].space)
                        if count > 0 {
                            directions[index].tail += count
                        } else if count == 0 {
                            directions[index].sourceClosed = true
                        } else if errno != EAGAIN, errno != EINTR {
                            broken = true
                        }
                    }
                }

                if fds[readIndex].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    directions[index].sourceClosed = true
                }
            }
            if broken { break }
        }
    }
}

extension GPUBridge: VZVirtioSocketListenerDelegate {
    public func listener(_ listener: VZVirtioSocketListener,
                         shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                         from socketDevice: VZVirtioSocketDevice) -> Bool {
        handle(connection: connection)
        return true
    }
}
