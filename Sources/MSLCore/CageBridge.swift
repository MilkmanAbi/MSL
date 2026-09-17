import Foundation
#if canImport(Virtualization)
import Virtualization
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Phase 3 of `cage-planning.md`: the host side of the cage/Wayland frame
/// stream. Structurally cloned from `DisplayBridge` (same "guest dials out,
/// host listens" direction, same delegate-must-return-fast shape - see
/// that file's own doc comments for why blocking here hangs the whole
/// process, not just this connection).
///
/// Two consumption modes, both live on the same wire connection:
/// - **File sink** (`onFrame == nil`, the original Phase 3 step 2/3
///   shape): no decode, no `NSWindow`, no `CGImage` - writes each frame's
///   raw pixels to disk (`/tmp/cageframe_<n>.raw` bounded, or
///   `cageframe_latest.raw` unbounded) so a wrong frame can be diffed as
///   bytes. Debug-only, used by `msl cage-bridge-test`/`cage-input-test`.
/// - **In-process callback** (`onFrame` set, Phase 4): skips the
///   filesystem entirely and hands each frame straight to whoever's
///   listening - `CageCanvasView` (`Sources/MSLCore/CageCanvasView.swift`)
///   uses this for a real live view. Polling a file was right for proving
///   the pipe existed; a live `NSView` needs frames pushed, not polled.
///
/// Wire format, sent once per frame by the guest's `cagebridge`
/// (`Guest/init/wayland-tests/cagebridge.c`), all fields native-endian
/// (guest and host are both arm64, so no byte-swap needed - would need
/// revisiting if either side ever isn't): a 24-byte header -
/// `magic: UInt32` ("CAGF"), `width: UInt32`, `height: UInt32`,
/// `stride: UInt32`, `format: UInt32` (a `wl_shm_format` enum value,
/// passed through opaquely), `flags: UInt32` (the screencopy protocol's
/// own `flags` bitfield - bit 0 is `y_invert`, "contents are y-inverted" -
/// passed through opaquely too; a consumer that cares, like
/// `CageCanvasView`, decides what to do with it, not this class) -
/// followed immediately by exactly `stride * height` bytes of raw pixel
/// data. Repeated once per frame, no delimiter needed since the header
/// itself carries the next payload's exact length.
public final class CageBridge: NSObject {
    /// `flags` is the screencopy `flags` bitfield (bit 0 = `y_invert`) -
    /// see this class's own doc comment. `pixels` is exactly
    /// `stride * height` bytes.
    public typealias FrameHandler = (_ width: UInt32, _ height: UInt32, _ stride: UInt32, _ format: UInt32, _ flags: UInt32, _ pixels: [UInt8]) -> Void

    private let socketDevice: VZVirtioSocketDevice
    private let port: UInt32
    private let outputDir: String
    /// 0 means unlimited (real streaming mode, matching `cagebridge.c`'s
    /// own `num_frames == 0` convention) - see `receive`'s doc comment
    /// for why the sink shape differs between the two modes. Ignored
    /// entirely when `onFrame` is set (that path never touches disk).
    private let maxFrames: Int
    /// When set, `receive` calls this for every frame instead of writing
    /// to disk - see this class's own doc comment.
    private let onFrame: FrameHandler?
    private var listener: VZVirtioSocketListener?

    private static let magic: UInt32 = 0x4341_4746 // matches cagebridge.c's CAGF_MAGIC exactly (native-endian, not a byte-order statement)

    public init(socketDevice: VZVirtioSocketDevice, port: UInt32, outputDir: String = "/tmp", maxFrames: Int = 10, onFrame: FrameHandler? = nil) {
        self.socketDevice = socketDevice
        self.port = port
        self.outputDir = outputDir
        self.maxFrames = maxFrames
        self.onFrame = onFrame
        super.init()
    }

    public func start() {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: port)
        self.listener = listener
    }

    /// See `DisplayBridge.stop()`'s doc comment - same "no unset API,
    /// dropping the retained listener is the best available substitute"
    /// reasoning applies here verbatim.
    public func stop() {
        listener = nil
    }
}

extension CageBridge: VZVirtioSocketListenerDelegate {
    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let dir = outputDir
        let cap = maxFrames
        let handler = onFrame
        Thread {
            Self.receive(connection: connection, outputDir: dir, maxFrames: cap, onFrame: handler)
        }.start()
        return true
    }

    /// `connection` is captured (and thereby kept alive) for this entire
    /// function's duration - same rule as `DisplayBridge.relay`'s own
    /// doc comment: never close `.fileDescriptor` directly, the
    /// connection object owns closing its own fd on deallocation.
    ///
    /// Three distinct sink shapes: `onFrame` set (Phase 4's live view -
    /// no file I/O at all, loops until the connection closes regardless
    /// of `maxFrames`), or (when `onFrame` is nil) the two FILE sink
    /// shapes depending on `maxFrames`, kept for the debug commands.
    /// Bounded (`maxFrames > 0`, one file per frame index) would do the
    /// wrong thing under real continuous streaming: it would either fill
    /// the disk with one file per frame within seconds at ~50fps, or
    /// (worse) hit its frame cap and `return` - closing the connection -
    /// which SIGPIPE-kills the guest's `cagebridge` on its very next
    /// write, the same class of opaque failure Phase 3 step 2 already
    /// hit once (see cage-planning.md). Unbounded file mode instead
    /// overwrites a single `cageframe_latest.raw`, atomically (write-to-
    /// temp then `rename` - `rename` is atomic on the same filesystem,
    /// so a concurrent reader never sees a torn/partial frame) and loops
    /// forever until the connection itself closes.
    private static func receive(connection: VZVirtioSocketConnection, outputDir: String, maxFrames: Int, onFrame: FrameHandler?) {
        let fd = connection.fileDescriptor
        var frameIndex = 0
        while onFrame != nil || maxFrames == 0 || frameIndex < maxFrames {
            guard let header = readHeader(fd) else { break }
            guard header.magic == magic, header.width > 0, header.height > 0, header.stride >= header.width * 4 else {
                FileHandle.standardError.write("CageBridge: bad frame header, dropping connection\n".data(using: .utf8)!)
                break
            }
            let payloadSize = Int(header.stride) * Int(header.height)
            guard let pixels = readExact(fd, count: payloadSize) else { break }

            if let onFrame {
                onFrame(header.width, header.height, header.stride, header.format, header.flags, pixels)
            } else {
                let meta = "width=\(header.width) height=\(header.height) stride=\(header.stride) format=\(header.format) flags=\(header.flags)\n"
                if maxFrames == 0 {
                    let base = outputDir + "/cageframe_latest"
                    let tmpPath = base + ".raw.tmp"
                    FileManager.default.createFile(atPath: tmpPath, contents: Data(pixels))
                    _ = rename(tmpPath, base + ".raw")
                    try? meta.write(toFile: base + ".raw.meta", atomically: true, encoding: .utf8)
                } else {
                    let path = outputDir + "/cageframe_\(frameIndex).raw"
                    try? meta.write(toFile: path + ".meta", atomically: true, encoding: .utf8)
                    FileManager.default.createFile(atPath: path, contents: Data(pixels))
                }
            }

            frameIndex += 1
        }
        withExtendedLifetime(connection) {}
    }

    private struct FrameHeader {
        var magic: UInt32
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var format: UInt32
        var flags: UInt32
    }

    private static func readHeader(_ fd: Int32) -> FrameHeader? {
        guard let bytes = readExact(fd, count: 24) else { return nil }
        return bytes.withUnsafeBytes { raw -> FrameHeader in
            let u = raw.bindMemory(to: UInt32.self)
            return FrameHeader(magic: u[0], width: u[1], height: u[2], stride: u[3], format: u[4], flags: u[5])
        }
    }

    private static func readExact(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var received = 0
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            while received < count {
                let n = read(fd, ptr.baseAddress!.advanced(by: received), count - received)
                if n <= 0 { return false }
                received += n
            }
            return true
        }
        return ok ? buf : nil
    }
}
