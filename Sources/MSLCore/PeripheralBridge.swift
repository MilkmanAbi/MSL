import AVFoundation
import Foundation
import Virtualization

/// mslps, the Mac half: peripherals for Linux applications, on the Mac's own
/// hardware.
///
/// Today that is sound. A Linux application plays through the guest's audio
/// server, which writes samples into a FIFO; `mslpsd` carries them over
/// vsock; this plays them. The guest has no sound card at all, which is the
/// point: no ALSA configuration per distro, and no hardware emulation for
/// MSL to own. See `READMES/09-MSLPS.md`.
///
/// The microphone and the camera are the same shape with the arrows
/// reversed, and both are gated per instance - a guest must never be able to
/// switch on a camera by itself. Sound coming *out* needs no permission and
/// is on by default.
public final class PeripheralBridge: NSObject {
    /// One port for the subsystem, one connection per stream. Separate
    /// connections rather than a multiplexed one: a stalled camera must not
    /// be able to stutter audio.
    public static let vsockPort: UInt32 = 5010

    /// Fixed for v1: 48 kHz, stereo, signed 16-bit little endian, in 10 ms
    /// frames. Both audio servers resample for us and every Mac output
    /// handles 48 kHz, so there is nothing to negotiate.
    public static let sampleRate: Double = 48_000
    public static let channels: AVAudioChannelCount = 2
    public static let frameBytes = 1920

    public enum Stream: String {
        case audioOut = "audio-out"
        case audioIn = "audio-in"
        case camera = "camera"
    }

    private let socketDevice: VZVirtioSocketDevice
    private let instance: String
    private let queue = DispatchQueue(label: "msl.mslps.bridge")
    private var listener: VZVirtioSocketListener?
    private let output = GuestAudioOutput()

    public init(socketDevice: VZVirtioSocketDevice, instance: String) {
        self.socketDevice = socketDevice
        self.instance = instance
        super.init()
    }

    public func start() {
        // Sound from Linux apps rides this bridge, so a policy denying
        // `peripherals.audio` means never opening the listener at all -
        // there is nothing for the guest to connect to.
        guard MSLAPGate.allows("peripherals.audio", instance: instance) else {
            log("audio bridge withheld by the MSL Admin Portal")
            return
        }
        output.onLog = { [weak self] message in self?.log(message) }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.vsockPort)
        self.listener = listener
    }

    public func stop() {
        listener = nil
        output.stop()
    }

    /// The guest's hello: 16 bytes, fixed width, so this never has to parse
    /// a length before it knows what it is reading.
    static func stream(fromHello bytes: [UInt8]) -> Stream? {
        guard bytes.count == 16 else { return nil }
        let text = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard text.hasPrefix("MSLPS1 ") else { return nil }
        return Stream(rawValue: String(text.dropFirst("MSLPS1 ".count)))
    }

    private func handle(connection: VZVirtioSocketConnection) {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return }
        Thread { [weak self] in
            defer { close(fd) }
            guard let self else { return }
            var hello = [UInt8](repeating: 0, count: 16)
            guard Self.readFully(fd: fd, into: &hello), let stream = Self.stream(fromHello: hello) else {
                self.log("a connection said something that was not an mslps hello")
                return
            }
            switch stream {
            case .audioOut:
                self.output.start()
                self.pumpAudioOut(fd: fd)
            case .audioIn, .camera:
                // Frames come from MSL Peripherals, which holds the Mac's
                // camera and microphone; this relays them and passes the
                // guest's "an app is using this" the other way.
                PeripheralInputRelay(stream: stream, instance: self.instance, guestFD: fd,
                                     log: { [weak self] in self?.log($0) }).run()
            }
        }.start()
    }

    /// Goes to the daemon's own log.
    ///
    /// Not `ActivityLog`: that records only while someone has the Traffic
    /// Monitor open, which is right for a live view and wrong for something
    /// you need after the fact to answer "did any sound actually arrive".
    private func log(_ message: String) {
        FileHandle.standardError.write("mslps[\(instance)]: \(message)\n".data(using: .utf8)!)
    }

    private func pumpAudioOut(fd: Int32) {
        log("sound connected")
        ActivityLog.shared.record(.lifecycle, instance: instance, "mslps: sound connected")
        var frame = [UInt8](repeating: 0, count: Self.frameBytes)
        var totalBytes = 0
        var peak: Float = 0
        while true {
            let read = frame.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            guard read > 0 else { break }
            let bytes = Array(frame.prefix(read))
            totalBytes += read
            // The peak is what makes this verifiable without ears: a stream
            // that connects and carries nothing but zeroes looks identical
            // to a working one in every other way.
            peak = max(peak, GuestAudioOutput.peak(ofS16LE: bytes))
            output.enqueue(bytes: bytes)
        }
        output.silence()
        let seconds = Double(totalBytes) / (Self.sampleRate * Double(Self.channels) * 2)
        let summary = String(format: "sound ended - %.1fs played, peak %.2f", seconds, peak)
        log(summary)
        ActivityLog.shared.record(.lifecycle, instance: instance, "mslps: " + summary)
    }

    static func readFully(fd: Int32, into bytes: inout [UInt8]) -> Bool {
        var got = 0
        return bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while got < buffer.count {
                let n = Darwin.read(fd, base + got, buffer.count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
    }
}

extension PeripheralBridge: VZVirtioSocketListenerDelegate {
    public func listener(_ listener: VZVirtioSocketListener,
                         shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                         from socketDevice: VZVirtioSocketDevice) -> Bool {
        handle(connection: connection)
        return true
    }
}

/// Plays the guest's samples on the Mac.
///
/// The two sides have different clocks and neither is master, so this is
/// built around that rather than pretending otherwise: CoreAudio pulls
/// whenever it wants samples, and takes whatever is buffered. An underrun
/// plays silence, an overrun drops the oldest audio. Both are inaudible when
/// rare and are exactly what drift produces.
final class GuestAudioOutput {
    /// Where to report engine trouble, set by the bridge that owns this.
    var onLog: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var started = false

    /// About 60 ms of stereo at 48 kHz. Enough to ride out a scheduling
    /// hiccup on either side, short enough that nobody notices the delay.
    private let capacity = Int(PeripheralBridge.sampleRate * 0.06) * Int(PeripheralBridge.channels)

    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: PeripheralBridge.sampleRate,
                                   channels: PeripheralBridge.channels)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let wanted = Int(frameCount) * Int(PeripheralBridge.channels)
            let samples = self?.take(wanted) ?? []
            // Interleaved in, deinterleaved out: the standard format is
            // non-interleaved, one buffer per channel.
            for (channel, audioBuffer) in buffers.enumerated() {
                guard let destination = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    let index = frame * Int(PeripheralBridge.channels) + channel
                    destination[frame] = index < samples.count ? samples[index] : 0
                }
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            onLog?("audio engine running at \(Int(PeripheralBridge.sampleRate)) Hz")
        } catch {
            lock.lock(); started = false; lock.unlock()
            // Worth saying out loud: samples arriving and sound playing are
            // different things, and this is the difference.
            onLog?("audio engine would not start: \(error)")
        }
    }

    func stop() {
        lock.lock()
        started = false
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
    }

    /// Drops what is buffered without tearing the engine down: the guest
    /// went quiet, and the next application to play should not hear the tail
    /// of the last one.
    func silence() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Signed 16-bit little endian, interleaved, straight off the wire.
    func enqueue(bytes: [UInt8]) {
        let samples = GuestAudioOutput.floats(fromS16LE: bytes)
        guard !samples.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: samples)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
    }

    /// How much audio is waiting, for the test that proves latency cannot
    /// grow without limit.
    var bufferedSamplesForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    private func take(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let available = min(count, buffer.count)
        let taken = Array(buffer[0..<available])
        buffer.removeFirst(available)
        return taken
    }

    /// Loudest sample in a frame, 0 to 1. Used to say in the log whether
    /// sound actually arrived: a stream carrying silence connects, reads and
    /// disconnects exactly like one carrying music.
    static func peak(ofS16LE bytes: [UInt8]) -> Float {
        floats(fromS16LE: bytes).reduce(0) { max($0, abs($1)) }
    }

    /// The one conversion in the whole path. Kept separate so it can be
    /// tested without an audio device.
    static func floats(fromS16LE bytes: [UInt8]) -> [Float] {
        let sampleCount = bytes.count / 2
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1])
            let raw = Int16(bitPattern: low | (high << 8))
            samples[index] = Float(raw) / 32768.0
        }
        return samples
    }
}
