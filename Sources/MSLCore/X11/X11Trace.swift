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

    private static func emit(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
    }

    /// Every dispatched request - opcode, the header's overloaded second
    /// byte (detail/depth/format depending on opcode), and body length.
    static func request(opcode: UInt8, detail: UInt8, bodyCount: Int) {
        // `ms` is system uptime, so request gaps line up with the mouse lines'
        // AppKit timestamps when chasing slow responses.
        emit("[x11] req opcode=\(opcode) detail=\(detail) bodyBytes=\(bodyCount) ms=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
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
}
