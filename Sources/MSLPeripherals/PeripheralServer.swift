import Foundation
import MSLCore

/// Where `mslhd` connects to get camera frames and microphone samples for a
/// guest, and through which the guest's "a Linux app is using this" reaches
/// the person.
///
/// One connection per stream per instance, opened by `mslhd`'s
/// `PeripheralInputRelay` with a one-line hello ("camera Milk"). The app
/// decides what flows: nothing, until the person has said yes.
final class PeripheralServer {
    /// A Linux app started (`application` non-nil) or stopped using a
    /// device. Always delivered on the main queue.
    var onUsageChanged: ((PeripheralSharing.Device, String, String?) -> Void)?

    private final class Client {
        let fd: Int32
        let device: PeripheralSharing.Device
        let instance: String
        let queue: DispatchQueue
        /// Buffers accepted but not yet written. Frames are dropped past a
        /// small backlog: a camera that is late is worse than one that skips.
        var backlog = 0
        var alive = true

        init(fd: Int32, device: PeripheralSharing.Device, instance: String) {
            self.fd = fd
            self.device = device
            self.instance = instance
            queue = DispatchQueue(label: "msl.mslps.client.\(device.rawValue).\(instance)")
        }
    }

    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listenFD: Int32 = -1

    func start() {
        let path = PeripheralSharingStore.socketPath
        MSLPaths.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        unlink(path) // a stale socket from a crashed run refuses every bind
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600) // this user's processes only
        listenFD = fd
        Thread { [weak self] in self?.acceptLoop(fd) }.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(PeripheralSharingStore.socketPath)
        lock.lock()
        for client in clients.values { client.alive = false; Darwin.shutdown(client.fd, SHUT_RDWR) }
        lock.unlock()
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [weak self] in self?.serve(fd) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        guard let line = Self.readLine(fd),
              let hello = PeripheralWire.parseHelperHello(line),
              let device = Self.device(forStream: hello.stream)
        else { close(fd); return }

        let client = Client(fd: fd, device: device, instance: hello.instance)
        let key = ObjectIdentifier(client)
        lock.lock(); clients[key] = client; lock.unlock()

        var parser = PeripheralWire.ControlParser()
        var buffer = [UInt8](repeating: 0, count: 512)
        var usedBy: String?
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            for control in parser.feed(Array(buffer.prefix(n))) {
                switch control {
                case .inUse(let application): usedBy = application.isEmpty ? "A Linux app" : application
                case .released: usedBy = nil
                }
                let app = usedBy
                DispatchQueue.main.async { self.onUsageChanged?(device, hello.instance, app) }
            }
        }

        lock.lock(); client.alive = false; clients[key] = nil; lock.unlock()
        close(fd)
        // A relay that went away took its app with it.
        if usedBy != nil {
            DispatchQueue.main.async { self.onUsageChanged?(device, hello.instance, nil) }
        }
    }

    /// Sends one camera frame (already YUYV 1280x720) to every instance in
    /// `instances`.
    func sendFrame(_ yuyv: [UInt8], to instances: Set<String>) {
        guard yuyv.count == PeripheralWire.cameraFrameBytes else { return }
        let bytes = PeripheralWire.frameHeader(payloadBytes: yuyv.count) + yuyv
        send(bytes, device: .camera, to: instances, maxBacklog: 1)
    }

    /// Sends microphone samples (48 kHz stereo s16le) to every instance in
    /// `instances`. More backlog than the camera: a gap in audio is heard,
    /// a skipped frame mostly is not.
    func sendSamples(_ pcm: [UInt8], to instances: Set<String>) {
        send(pcm, device: .microphone, to: instances, maxBacklog: 8)
    }

    private func send(_ bytes: [UInt8], device: PeripheralSharing.Device, to instances: Set<String>, maxBacklog: Int) {
        guard !instances.isEmpty else { return }
        lock.lock()
        let targets = clients.values.filter { $0.device == device && instances.contains($0.instance) && $0.alive }
        lock.unlock()
        for client in targets {
            lock.lock()
            let full = client.backlog >= maxBacklog
            if !full { client.backlog += 1 }
            lock.unlock()
            if full { continue }
            client.queue.async { [weak self] in
                _ = Self.writeAll(client.fd, bytes)
                self?.lock.lock(); client.backlog -= 1; self?.lock.unlock()
            }
        }
    }

    // MARK: plumbing

    private static func device(forStream stream: String) -> PeripheralSharing.Device? {
        switch stream {
        case "camera": return .camera
        case "audio-in": return .microphone
        default: return nil
        }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 256 {
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
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
