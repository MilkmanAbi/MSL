import AppKit

/// Phase 4 of `cage-planning.md`: the real, live view of a cage session -
/// receives frames pushed by `CageBridge`'s in-process `onFrame` callback
/// (not the file-polling `/tmp/cageframe_latest.raw` path Phase 3's debug
/// commands use) and forwards real mouse/keyboard input to
/// `CageInputBridge`. Structurally similar to `X11CanvasView` (same
/// flipped-view + counter-flip-on-draw dance, same `NSView` input-
/// override shape) but simpler: there's exactly one frame source per
/// view (cage's whole composited output, not per-window drawing
/// commands), so there's no persistent `CGContext` to draw INTO - each
/// received frame becomes a fresh `CGImage` and `draw(_:)` just blits
/// whichever one is current.
///
/// **The "one window per surface vs. one kiosk window" question
/// `cage-planning.md` originally flagged as open is closed by the
/// capture mechanism already chosen, not by a design preference**:
/// `zwlr_screencopy_manager_v1.capture_output` is OUTPUT-scoped, not
/// per-surface - wlroots offers no way to capture one Wayland surface's
/// texture in isolation via screencopy. This view mirrors cage's entire
/// composited 1280x720 canvas, matching cage's own kiosk model (wraps
/// exactly one app fullscreen). Per-surface windows would need a
/// completely different capture mechanism (a nested compositor
/// presenting each client surface separately), not an option on top of
/// today's pipeline.
public final class CageCanvasView: NSView {
    private let lock = NSLock()
    private var pendingImage: CGImage?
    private var redrawScheduled = false
    private var latestImage: CGImage?

    /// Set by whoever creates this view (see `VMManager`/`DaemonServer`'s
    /// cage-view wiring) - `nil` until the guest's `cageinput` has
    /// actually connected, same as `CageInputBridge.sendKey`'s own
    /// "no connection yet" `false` return, just checked here instead so
    /// a keypress before the guest is ready is silently dropped rather
    /// than queued.
    public weak var inputBridge: CageInputBridge?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init(width: Int, height: Int) {
        super.init(frame: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)))
    }

    required init?(coder: NSCoder) { fatalError("CageCanvasView does not support NSCoding") }

    /// Matches `CageBridge.FrameHandler`'s signature - called directly
    /// from `CageBridge`'s background receive `Thread`, NOT the main
    /// thread. Building the `CGImage` here (off the main thread) is
    /// cheap - it just wraps the byte buffer in a data provider, no
    /// actual rendering happens until `draw(_:)` blits it - so the ONLY
    /// main-thread work per frame is a coalesced `needsDisplay = true`.
    /// At ~50-60fps with 3.6MB frames, one `DispatchQueue.main.async`
    /// PER FRAME (each capturing its own pixel buffer) would queue up
    /// faster than the main thread could drain it; this instead keeps a
    /// single "pending" slot and skips scheduling a new redraw if one is
    /// already in flight - later frames simply overwrite the pending one
    /// until the main thread catches up. Dropping frames this way is
    /// correct for a live view (only the LATEST state matters), unlike
    /// the debug file sink's own "every frame" contract.
    public func updateFrame(width: UInt32, height: UInt32, stride: UInt32, format: UInt32, flags: UInt32, pixels: [UInt8]) {
        // Only XRGB8888 (wl_shm format 1) is handled - the only format
        // this project's own guest clients (`01_static_frame.c`,
        // `02_input_roundtrip.c`) and cage's own headless pixman
        // renderer have ever been observed producing (confirmed via
        // `/tmp/cageframe_*.raw.meta` across every Phase 3 test run).
        // Silently dropping anything else, same "don't guess" policy
        // `X11Keyboard`'s keysym translation already uses.
        guard format == 1 else { return }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return }
        // `noneSkipFirst` + `byteOrder32Little` is the standard CG idiom
        // for memory laid out B,G,R,X per pixel (confirmed against a
        // known pixel in Phase 3 step 2's own verification: a red pixel
        // read back as bytes B=0x33,G=0x33,R=0xFF,X=0x00 - exactly
        // wl_shm's XRGB8888 in native little-endian storage).
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(
            width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(stride), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return }

        var shouldDispatch = false
        lock.lock()
        pendingImage = image
        if !redrawScheduled {
            redrawScheduled = true
            shouldDispatch = true
        }
        lock.unlock()

        if shouldDispatch {
            DispatchQueue.main.async { [weak self] in self?.applyPendingFrame() }
        }
    }

    private func applyPendingFrame() {
        lock.lock()
        let image = pendingImage
        redrawScheduled = false
        lock.unlock()
        guard let image else { return }
        latestImage = image
        let size = NSSize(width: image.width, height: image.height)
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    /// Cage's headless output never reported `y_invert` in any run this
    /// project has observed (logged once per `cagebridge` session -
    /// checked BEFORE writing this drawing code, not assumed - see
    /// `cage-planning.md`'s Phase 4 notes), so `flags` isn't consulted
    /// here yet. Frames are top-down in memory, matching exactly what
    /// `X11CanvasView`'s own `makeFlippedBitmapContext` produces - the
    /// SAME counter-flip-on-draw treatment below (translate + negative
    /// scale before `cgContext.draw`) is that file's already-confirmed-
    /// correct fix for a flipped view + a top-down image, reused
    /// verbatim rather than re-derived.
    public override func draw(_ dirtyRect: NSRect) {
        guard let image = latestImage, let cgContext = NSGraphicsContext.current?.cgContext else { return }
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: CGFloat(image.height))
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        cgContext.restoreGState()
    }

    // MARK: - Input

    /// Same reasoning as `X11CanvasView.acceptsFirstMouse` - without
    /// this, a click on a not-yet-key window is consumed just for
    /// activation and never reaches this view as a real `mouseDown`.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }

    private func sendMotion(_ event: NSEvent) {
        guard let bridge = inputBridge else { return }
        let extentW = UInt32(latestImage?.width ?? 1280)
        let extentH = UInt32(latestImage?.height ?? 720)
        // Normalized fraction of THIS VIEW's bounds, not the raw AppKit
        // point - correct regardless of window size or Retina backing
        // scale, since it's re-scaled against the frame's own extents
        // (the guest's `motion_absolute` wants coordinates in the
        // CAPTURED output's pixel space, 1280x720, not screen points).
        let point = convert(event.locationInWindow, from: nil)
        let fx = max(0, min(1, point.x / max(bounds.width, 1)))
        let fy = max(0, min(1, point.y / max(bounds.height, 1)))
        bridge.sendPointerMotion(x: UInt32(fx * CGFloat(extentW)), y: UInt32(fy * CGFloat(extentH)), xExtent: extentW, yExtent: extentH)
    }

    // Linux evdev button codes (`linux/input-event-codes.h`) -
    // BTN_LEFT/BTN_RIGHT/BTN_MIDDLE.
    private static let btnLeft: UInt32 = 0x110
    private static let btnRight: UInt32 = 0x111
    private static let btnMiddle: UInt32 = 0x112

    /// Same fix, same reasoning, as `X11CanvasView.ensureActivated()`'s
    /// own doc comment (reused verbatim, not re-derived): `mslhd` runs
    /// with `.accessory` activation policy, which does NOT reliably
    /// reclaim frontmost-APPLICATION status purely from its window being
    /// clicked - confirmed live for THIS view too (a synthetic click via
    /// macOS's own Accessibility API landed and even moved first-
    /// responder, but a following `keystroke` still went to whatever was
    /// ACTUALLY frontmost, not this window, because activation never
    /// happened). Guarded the same way X11CanvasView's version is, to
    /// avoid disrupting AppKit's own mouseDown->mouseUp tracking for a
    /// click that arrives while already active/key.
    private func ensureActivated() {
        guard !NSApplication.shared.isActive || window?.isKeyWindow != true else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public override func mouseDown(with event: NSEvent) {
        ensureActivated()
        window?.makeFirstResponder(self)
        sendMotion(event)
        inputBridge?.sendPointerButton(button: Self.btnLeft, pressed: true)
    }
    public override func mouseUp(with event: NSEvent) {
        inputBridge?.sendPointerButton(button: Self.btnLeft, pressed: false)
    }
    public override func rightMouseDown(with event: NSEvent) {
        ensureActivated()
        window?.makeFirstResponder(self)
        sendMotion(event)
        inputBridge?.sendPointerButton(button: Self.btnRight, pressed: true)
    }
    public override func rightMouseUp(with event: NSEvent) {
        inputBridge?.sendPointerButton(button: Self.btnRight, pressed: false)
    }
    public override func otherMouseDown(with event: NSEvent) {
        ensureActivated()
        window?.makeFirstResponder(self)
        sendMotion(event)
        inputBridge?.sendPointerButton(button: Self.btnMiddle, pressed: true)
    }
    public override func otherMouseUp(with event: NSEvent) {
        inputBridge?.sendPointerButton(button: Self.btnMiddle, pressed: false)
    }
    public override func mouseDragged(with event: NSEvent) { sendMotion(event) }
    public override func mouseMoved(with event: NSEvent) { sendMotion(event) }

    public override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, let keycode = CageKeyMapping.evdevKeycode(forMacKeyCode: event.keyCode) else { return }
        inputBridge?.sendKey(keycode: keycode, pressed: true)
    }
    public override func keyUp(with event: NSEvent) {
        guard let keycode = CageKeyMapping.evdevKeycode(forMacKeyCode: event.keyCode) else { return }
        inputBridge?.sendKey(keycode: keycode, pressed: false)
    }
}
