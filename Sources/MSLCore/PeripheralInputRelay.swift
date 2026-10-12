import Foundation

/// One camera or microphone stream for one guest, inside `mslhd`.
///
/// `mslhd` owns the guest's vsock but may not open the camera or the
/// microphone: macOS grants those to an app with a bundle, never to a
/// daemon. The MSL Peripherals app holds them. So this sits in the middle:
///
///   guest  --"cheese is using the camera"-->  here  -->  MSL Peripherals
///   guest  <--------- frames / samples -----  here  <--  MSL Peripherals
///
/// It carries bytes and holds no policy. Whether anything real flows is
/// decided in the app, by the person. If a Linux app asks while the app is
/// not running, this opens it - which is what puts the question in front
/// of them. Until they answer, the guest keeps showing its placeholder and
/// feeding silence, so nothing in Linux waits on the Mac.
final class PeripheralInputRelay {
    private let stream: PeripheralBridge.Stream
    private let instance: String
    private let guestFD: Int32
    private let log: (String) -> Void

    private let lock = NSLock()
    private var helperFD: Int32 = -1
    /// The last "an app is using this", replayed to a helper that connects
    /// later - otherwise opening the helper would lose the very request
    /// that caused it to be opened.
    private var request: PeripheralWire.Control?
    private var finished = false
    private var lastLaunch = Date.distantPast
    /// Launches since the helper last actually connected.
    private var launchesWithoutConnecting = 0

    init(stream: PeripheralBridge.Stream, instance: String, guestFD: Int32, log: @escaping (String) -> Void) {
        self.stream = stream
        self.instance = instance
        self.guestFD = guestFD
        self.log = log
    }

    /// Runs until the guest disconnects.
    func run() {
        Self.noSigpipe(guestFD)
        log("\(stream.rawValue) connected")
        Thread { [self] in helperLoop() }.start()

        var parser = PeripheralWire.ControlParser()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(guestFD, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            for control in parser.feed(Array(buffer.prefix(n))) {
                handle(control)
            }
        }

        lock.lock()
        finished = true
        let fd = helperFD
        lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) } // wakes the helper loop
        log("\(stream.rawValue) disconnected")
    }

    private func handle(_ control: PeripheralWire.Control) {
        switch control {
        case .inUse(let application):
            log("\(stream.rawValue) wanted by \(application.isEmpty ? "a Linux app" : application)")
        case .released:
            log("\(stream.rawValue) released")
        }
        lock.lock()
        request = (control == .released) ? nil : control
        let fd = helperFD
        lock.unlock()
        if fd >= 0 {
            _ = Self.writeAll(fd, PeripheralWire.encode(control))
        } else if control != .released {
            launchHelperIfDue()
        }
    }

    // MARK: the helper side

    private func helperLoop() {
        while true {
            lock.lock(); let done = finished; lock.unlock()
            if done { return }

            let fd = Self.connectUnix(PeripheralSharingStore.socketPath)
            guard fd >= 0 else {
                lock.lock(); let wanted = request != nil; lock.unlock()
                if wanted { launchHelperIfDue() }
                // Quickly while a Linux app is waiting: the helper is being
                // opened for it, and every second here is a second before
                // the person is even asked.
                Thread.sleep(forTimeInterval: wanted ? 0.25 : 2)
                continue
            }
            Self.noSigpipe(fd)
            guard Self.writeAll(fd, PeripheralWire.helperHello(stream: stream.rawValue, instance: instance)) else {
                close(fd); continue
            }
            lock.lock()
            helperFD = fd
            launchesWithoutConnecting = 0
            let pending = request
            lock.unlock()
            if let pending { _ = Self.writeAll(fd, PeripheralWire.encode(pending)) }

            switch stream {
            case .camera: pumpFrames(from: fd)
            default: pumpSamples(from: fd)
            }

            lock.lock()
            helperFD = -1
            lock.unlock()
            close(fd)
        }
    }

    /// Whole frames only. A helper that goes away mid-frame must not leave
    /// half a picture in the guest's stream, which would misalign every
    /// frame after it - so a frame is read completely before any of it is
    /// passed on.
    private func pumpFrames(from fd: Int32) {
        var header = [UInt8](repeating: 0, count: PeripheralWire.frameHeaderBytes)
        var payload = [UInt8](repeating: 0, count: PeripheralWire.cameraFrameBytes)
        var frames = 0
        while PeripheralBridge.readFully(fd: fd, into: &header) {
            guard PeripheralWire.payloadLength(ofFrameHeader: header) == PeripheralWire.cameraFrameBytes else {
                log("camera: the helper sent something that is not a frame; reconnecting")
                break
            }
            guard PeripheralBridge.readFully(fd: fd, into: &payload) else { break }
            guard Self.writeAll(guestFD, header), Self.writeAll(guestFD, payload) else { break }
            frames += 1
            if frames == 1 { log("camera: first frame delivered") }
        }
        if frames > 0 { log("camera: \(frames) frames delivered") }
    }

    private func pumpSamples(from fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: PeripheralBridge.frameBytes)
        var chunks = 0
        while PeripheralBridge.readFully(fd: fd, into: &chunk) {
            guard Self.writeAll(guestFD, chunk) else { break }
            chunks += 1
            if chunks == 1 { log("microphone: first samples delivered") }
        }
        if chunks > 0 { log(String(format: "microphone: %.1fs delivered", Double(chunks) / 100)) }
    }

    /// Opens MSL Peripherals so the person is asked. At most every 15
    /// seconds: a Linux app retrying must not be able to keep pulling a
    /// window in front of whatever they are doing.
    ///
    /// And not at all, for five minutes, once three launches in a row have
    /// never connected. A helper that crashes on start used to be reopened
    /// every 15 seconds for as long as the Linux app kept the device open,
    /// each launch taking focus away from macOS's own "quit unexpectedly"
    /// dialog - which is what made that dialog impossible to dismiss.
    private func launchHelperIfDue() {
        lock.lock()
        let spacing: TimeInterval = launchesWithoutConnecting >= 3 ? 300 : 15
        let due = Date().timeIntervalSince(lastLaunch) > spacing
        if due { lastLaunch = Date(); launchesWithoutConnecting += 1 }
        let failing = launchesWithoutConnecting
        lock.unlock()
        guard due else { return }
        if failing > 3 {
            log("MSL Peripherals has not answered after \(failing - 1) launches; trying again, then waiting 5 minutes")
        } else {
            log("opening MSL Peripherals to ask about the \(stream == .camera ? "camera" : "microphone")")
        }
        Self.openHelper()
    }

    static func openHelper() {
        let byBundle = Process()
        byBundle.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // --on-request: opened for a Linux app's request, so the app shows
        // only the request, not its whole settings window.
        byBundle.arguments = ["-b", "com.msl.peripherals", "--args", "--on-request"]
        if (try? byBundle.run()) != nil {
            byBundle.waitUntilExit()
            if byBundle.terminationStatus == 0 { return }
        }
        // Not registered with Launch Services yet: find it inside MSL.app.
        let candidates = ["/Applications/MSL.app", NSHomeDirectory() + "/Applications/MSL.app"]
            .map { $0 + "/Contents/Library/MSL Peripherals.app" }
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let byPath = Process()
            byPath.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            byPath.arguments = [path, "--args", "--on-request"]
            try? byPath.run()
        }
    }

    // MARK: plumbing

    static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return -1 }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd); return -1 }
        return fd
    }

    /// A write to a peer that has gone must be an error, not a signal that
    /// takes `mslhd` - and every VM in it - down.
    static func noSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return true }
            var left = buffer.count
            while left > 0 {
                let n = Darwin.write(fd, base, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                base += n
                left -= n
            }
            return true
        }
    }
}
