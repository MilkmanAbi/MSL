import Foundation

/// Records every request a real client sends, byte for byte, so a session
/// can be analysed (which requests does GTK4 actually use?) and replayed
/// against mslgd by the xhell suite (`Guest/x11-torture`, `s_replay.py`).
///
/// Off unless `MSL_X11_CAPTURE_DIR` is set in mslhd's environment (it
/// reaches the per-app hosts the same way `MSL_X11_TRACE` does). One file
/// per connection, named after the host process (the app) and pid:
///
///     "XCAP1\n" + JSON header line + "\n", then per request:
///     u32 LE length + the request's bytes exactly as received
///
/// The header records the client's resource-id base and mask and its byte
/// order, which is what lets a replayer map the recorded ids onto its own.
/// Capped at 64 MB per connection: a replay of a real startup needs the
/// first few thousand requests, not an hour of video frames.
final class X11Capture {
    static let directory: String? = ProcessInfo.processInfo.environment["MSL_X11_CAPTURE_DIR"]
    private static let cap = 64 << 20
    private static var counter = 0
    private static let counterLock = NSLock()

    private let handle: FileHandle
    private var written = 0
    private var full = false

    init?(base: UInt32, mask: UInt32, littleEndian: Bool, root: UInt32) {
        guard let dir = Self.directory else { return nil }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Self.counterLock.lock(); Self.counter += 1; let n = Self.counter; Self.counterLock.unlock()
        let app = (ProcessInfo.processInfo.processName as NSString).lastPathComponent
        let path = "\(dir)/\(app)-\(getpid())-\(n).xcap"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        let header: [String: Any] = ["app": app, "base": base, "mask": mask, "root": root,
                                     "byteOrder": littleEndian ? "l" : "B",
                                     "when": ISO8601DateFormatter().string(from: Date())]
        let json = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
        handle.write(Data("XCAP1\n".utf8) + json + Data("\n".utf8))
    }

    /// Called from the connection's own thread only.
    func record(header: [UInt8], body: [UInt8]) {
        guard !full else { return }
        let total = header.count + body.count
        if written + total > Self.cap {
            full = true
            return
        }
        var len = UInt32(total).littleEndian
        var chunk = Data(bytes: &len, count: 4)
        chunk.append(contentsOf: header)
        chunk.append(contentsOf: body)
        handle.write(chunk)
        written += total + 4
    }

    deinit { try? handle.close() }
}
