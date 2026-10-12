import Foundation

/// Opt-in wire-level tracing for `X11Connection`, replacing the one-off
/// `DEBUG*` print statements that used to get hand-added/removed (and the
/// binary rebuilt) every time a request sequence needed inspecting. Off by
/// default (zero cost on the hot request-dispatch path beyond one env
/// lookup, cached once); set `MSL_X11_TRACE=1` in `mslhd`'s environment to
/// enable.
enum X11Trace {
    static let enabled: Bool = ProcessInfo.processInfo.environment["MSL_X11_TRACE"] == "1"

    /// Mouse and focus lines only (clicks, motion, crossing, key-window
    /// changes), via `MSL_X11_MOUSE_TRACE=1`. The full trace logs every
    /// request and slows a busy GTK app enough to batch a whole drag into
    /// one burst, which hides exactly the input-timing bugs this is for.
    static let mouseEnabled: Bool = enabled || ProcessInfo.processInfo.environment["MSL_X11_MOUSE_TRACE"] == "1"

    /// Opcodes to trace, from `MSL_X11_TRACE_OPCODES=72,62`. Empty means
    /// all of them.
    ///
    /// A full capture logs every request synchronously to stderr on the
    /// dispatch path, which is both unusable on a live GTK app (thousands
    /// of lines a second) and enough to change timing - a busy app batches
    /// a whole drag into one burst and looks broken. Narrowing to the two
    /// or three opcodes a bug is about gives back a trace that can be read
    /// and that does not move the thing being measured.
    static let tracedOpcodes: Set<UInt8> = {
        guard let raw = ProcessInfo.processInfo.environment["MSL_X11_TRACE_OPCODES"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let words = raw.split(whereSeparator: { $0 == "," || $0 == " " })
        let parsed = Set(words.compactMap { UInt8($0) })
        // An opcode is a single byte, so `72` parses and `999` does not -
        // and a filter that silently falls back to "trace everything" is
        // how someone spends an afternoon reading a log they thought was
        // narrowed. Say so once, on stderr, where the trace itself goes.
        if parsed.count != words.count {
            FileHandle.standardError.write(
                "[x11] MSL_X11_TRACE_OPCODES: ignored \(words.count - parsed.count) value(s) that are not 0-255\n"
                    .data(using: .utf8)!)
        }
        return parsed
    }()

    private static func emit(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
    }

    /// Every dispatched request - opcode, the header's overloaded second
    /// byte (detail/depth/format depending on opcode), and body length.
    static func request(opcode: UInt8, detail: UInt8, bodyCount: Int) {
        guard tracedOpcodes.isEmpty || tracedOpcodes.contains(opcode) else { return }
        // `ms` is system uptime, so request gaps line up with the mouse lines'
        // AppKit timestamps when chasing slow responses.
        emit("[x11] req opcode=\(opcode) detail=\(detail) bodyBytes=\(bodyCount) ms=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
    }

    private static var smallUploadCount = 0
    private static let smallUploadLock = NSLock()

    /// Writes a small `PutImage`'s raw bytes to `/tmp/msl-putimage/` so they
    /// can be decoded offline. The first 400 only - a pointer sweep produces
    /// one per position, and this is for looking at a handful, not logging.
    static func dumpSmallUpload(_ bytes: [UInt8], drawableID: UInt32, width: Int, height: Int,
                                depth: UInt8, rowBytes: Int, littleEndian: Bool) {
        smallUploadLock.lock()
        smallUploadCount += 1
        let n = smallUploadCount
        smallUploadLock.unlock()
        guard n <= 400 else { return }
        let dir = "/tmp/msl-putimage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = String(format: "%@/%04d-d%u-%dx%d-depth%u-row%d-%@.bin",
                          dir, n, drawableID, width, height, depth, rowBytes, littleEndian ? "le" : "be")
        FileManager.default.createFile(atPath: name, contents: Data(bytes))
    }

    /// What `handleCreateWindow`'s main-queue barrier actually costs, split
    /// into the two halves that call for completely different fixes.
    ///
    /// `wait` is how long the `.sync` sat before its block started running -
    /// the drawing the app had already queued on the main queue ahead of it,
    /// plus whatever the main thread was inside. `work` is the block itself.
    /// `bitmap` is the backing-store allocation, which was moved OFF the
    /// barrier and is timed here to show it stayed off.
    ///
    /// Why it matters: if `wait` dominates, no amount of trimming the block
    /// helps and the barrier has to go entirely (queue drawing against the
    /// record, replay when the view lands). If `work` dominates, the block
    /// is still doing too much. Measured against an Xt app, which makes one
    /// X window per widget - xcalc issues 69 `CreateWindow`s to Mousepad's 4.
    static func createWindowBarrier(windowID: UInt32, waitMS: Double, workMS: Double, bitmapMS: Double) {
        emit(String(format: "[x11] createBarrier wid=%u wait=%.3fms work=%.3fms bitmap=%.3fms",
                    windowID, waitMS, workMS, bitmapMS))
    }

    /// `CreateWindow`'s initial event mask, and any later
    /// `ChangeWindowAttributes` that changes it - the exact state
    /// `handleMapWindow`'s `Expose`-on-map decision reads.
    static func eventMask(windowID: UInt32, mask: UInt32, source: String) {
        emit("[x11] eventMask wid=\(windowID) mask=0x\(String(mask, radix: 16)) via=\(source)")
    }

    /// Whether `MapWindow` actually sent the initial `Expose` a newly
    /// visible window needs to start painting, and why not when it didn't.
    static func mapExpose(windowID: UInt32, sent: Bool, eventMask: UInt32) {
        emit("[x11] map wid=\(windowID) exposeSent=\(sent) eventMask=0x\(String(eventMask, radix: 16))")
    }

    /// A `PutImage` upload - target, geometry, depth (which now controls
    /// whether alpha is respected - see `X11Connection.handlePutImage`),
    /// and if it was dropped, why.
    static func putImage(drawableID: UInt32, width: Int, height: Int, depth: UInt8, outcome: String) {
        emit("[x11] putImage drawable=\(drawableID) \(width)x\(height) depth=\(depth) outcome=\(outcome)")
    }

    /// A window's geometry at `CreateWindow` time and every subsequent
    /// `ConfigureWindow`/resize, and any `WM_NORMAL_HINTS` applied to it -
    /// temporary, targeted tracing for `gui-bugs.md` issue #9 (default
    /// window size systematically too short / `pack_end` widgets never
    /// drawn). Answers directly: does GTK ever resize the top-level window
    /// to its real natural size before mapping, and does a min/max hint
    /// clamp that resize to something smaller than what was asked for?
    static func geometry(_ event: String, windowID: UInt32, x: Int, y: Int, width: Int, height: Int) {
        emit("[x11] geom \(event) wid=\(windowID) x=\(x) y=\(y) w=\(width) h=\(height)")
    }

    static func normalHints(windowID: UInt32, flags: UInt32, minW: UInt32, minH: UInt32, maxW: UInt32, maxH: UInt32) {
        emit("[x11] normalHints wid=\(windowID) flags=0x\(String(flags, radix: 16)) min=\(minW)x\(minH) max=\(maxW)x\(maxH)")
    }

    /// A RENDER `Composite` request - resolved src/mask/dst pictures and
    /// whether the source image actually cropped/drew, so a "nothing
    /// appeared" symptom can be told apart from "the request never made
    /// it this far" without re-deriving it by hand each time.
    static func composite(op: UInt8, srcPictureID: UInt32, srcHasSolid: Bool, srcDrawableID: UInt32?, maskPictureID: UInt32, dstPictureID: UInt32, dstDrawableID: UInt32?, outcome: String) {
        emit("[x11] composite op=\(op) src=\(srcPictureID)(solid=\(srcHasSolid) drawable=\(srcDrawableID.map(String.init) ?? "nil")) mask=\(maskPictureID) dst=\(dstPictureID)(drawable=\(dstDrawableID.map(String.init) ?? "nil")) outcome=\(outcome)")
    }

    // MARK: - Events

    /// One line per event actually written to a client - the only answer
    /// to "what did the client receive?", as opposed to what it asked for.
    ///
    /// **Why this exists as a helper rather than an inline check.** The
    /// inline version it replaces required `bytes.count == 32`, and every
    /// XI2 event is 72 or 84 bytes - so the subsystem where this server
    /// has had the most bugs (button masks, modifier state, crossing
    /// events) was the one subsystem the event trace could not see. Both
    /// XI2 defects found in the 2026-09-22 audit would have been one line
    /// of log each.
    ///
    /// The two layouts genuinely differ and cannot share a decode: byte 4
    /// is the event window for a core event and the *length* for a
    /// GenericEvent. What they do share is that `root`, `event` and
    /// `child` sit at 20, 24 and 28 in both XI2 shapes
    /// (`xXIDeviceEvent` and `xXIEnterEvent`), which is why one XI2 branch
    /// covers device, crossing and focus events alike.
    static func event(_ bytes: [UInt8], littleEndian: Bool) {
        guard enabled, bytes.count >= 32 else { return }
        let code = bytes[0] & 0x7F          // the high bit means SendEvent-delivered
        let synthetic = bytes[0] & 0x80 != 0 ? " sendEvent" : ""
        guard code >= 2, code <= 35 else { return }

        func u16(_ i: Int) -> UInt16 {
            littleEndian ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                         : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
        }
        func u32(_ i: Int) -> UInt32 {
            littleEndian ? UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                         : UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }

        if code == 35, bytes.count >= 32 {
            // GenericEvent. `buttons_len` is at a different offset in the
            // two XI2 shapes and the LENGTH cannot tell them apart, so the
            // evtype does: a device event (key/button/motion) puts it at
            // 48, after the four FP1616 coordinates; a crossing or focus
            // event puts `same_screen` and `focus` there first and the
            // mask length at 50. Reading the device offset as 64 printed
            // `buttonsLen=0` for every motion event while the code was
            // plainly writing 1 - caught by running this against a real
            // drag rather than by reading it.
            let evtype = u16(8)
            let buttonsLen: UInt16
            switch evtype {
            case XIEventType.keyPress, XIEventType.keyRelease, XIEventType.buttonPress,
                 XIEventType.buttonRelease, XIEventType.motion:
                buttonsLen = bytes.count >= 50 ? u16(48) : 0
            case XIEventType.enter, XIEventType.leave, XIEventType.focusIn, XIEventType.focusOut:
                buttonsLen = bytes.count >= 52 ? u16(50) : 0
            default:
                buttonsLen = 0 // raw events carry no button mask in this shape
            }
            emit("[x11] >>XI2 evtype=\(evtype) dev=\(u16(10)) root=\(u32(20)) event=\(u32(24)) "
                 + "child=\(u32(28)) buttonsLen=\(buttonsLen) bytes=\(bytes.count)\(synthetic)")
        } else if bytes.count == 32 {
            emit("[x11] >>EVT code=\(code) detail=\(bytes[1]) window=\(u32(4))\(synthetic)")
        }
    }
}
