import AppKit

/// A plain `NSWindow`'s `canBecomeKey`/`canBecomeMain` both default to
/// `false` when its `styleMask` is `.borderless` (documented AppKit
/// behavior, not a bug) - exactly the style `X11Connection.
/// handleCreateWindow` gives an override-redirect top-level window (see
/// its own doc comment: real GTK/Qt popup menus, tooltips, combo-box
/// dropdowns). Left at the default, such a window can still receive a
/// `mouseDown` (AppKit delivers that to whichever window is frontmost
/// under the click regardless of key status) but never reliably becomes
/// KEY - which matters the moment a popup needs to route KEYBOARD input
/// (type-ahead in a combo box, arrow-key navigation within an open menu)
/// rather than just a single click. Overriding both to `true` here makes
/// override-redirect windows behave like real popups instead of
/// permanently-non-key windows that happen to still catch a stray click.
final class X11PopupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The `NSView` backing one X11 window - owns an off-screen `CGContext`
/// bitmap that every drawing request (`PolyFillRectangle`, `ClearArea`,
/// `CopyArea`, ...) draws into directly (via `X11Drawable`'s shared
/// helpers); `draw(_:)` just blits it. Matches the doc's suggested
/// architecture ("pixmap backing store -> CGBitmapContext, CoreGraphics
/// for PutImage/CopyArea/FillRect"). See `X11Pixmap` for this project's
/// OTHER `X11Drawable` - the off-screen kind a window never shows on its
/// own.
final class X11CanvasView: NSView, X11Drawable {
    private(set) var bitmapContext: CGContext
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int

    weak var eventSink: X11EventSink?
    /// Text-input state (see `X11CanvasView+TextInput.swift`).
    var markedText: String?
    /// Keys whose keyDown became text; their keyUp must not reach X either.
    var textRoutedKeys: Set<UInt16> = []
    /// The key event being run through the input context, and whether the
    /// input method handed it back as a plain key.
    var routingKeyEvent: NSEvent?
    var routedKeyWentRaw = false
    /// The window ID this view is drawing for - threaded through to
    /// `eventSink` calls so the connection knows which X window a mouse
    /// event actually landed on without a reverse NSView->id lookup.
    var windowID: UInt32 = 0
    /// Timestamp of the last plain mouse-move delivered for this view: AppKit
    /// hands the same move to a view both through its tracking area and as
    /// first responder (see `X11Connection.mouseMoved`).
    var lastMotionTimestamp: TimeInterval = -1

    /// The window's SHAPE bounding mask (`X11Connection.handleShapeMask`):
    /// an RGBA image the size of the view, alpha 255 inside the shape and 0
    /// outside, raw row 0 = the top row. `nil` for an ordinary rectangular
    /// window, which stays exactly as before (not even layer-backed).
    ///
    /// Applied as a layer mask, not in `draw(_:)`: shaped clients draw into a
    /// CHILD window covering the shaped top-level (xeyes' Eyes widget), and
    /// only a layer mask clips subviews too. Measured on a flipped view
    /// (geometryFlipped): the mask image's row 0 lands at the top. Main
    /// thread only.
    var shapeMask: CGImage? {
        didSet {
            guard let shapeMask else {
                layer?.mask = nil
                return
            }
            wantsLayer = true
            let maskLayer = CALayer()
            maskLayer.frame = bounds
            maskLayer.contents = shapeMask
            layer?.mask = maskLayer
        }
    }

    /// The window's SHAPE bounding region as rectangles, in this view's
    /// own X11 pixels (`X11Connection.handleShapeRectangles`). Drawn as a
    /// mask - through `shapeMask`, the path already measured the right way
    /// up - so the window, and every child in it, shows only inside the
    /// region. `nil` removes it. Main thread only.
    var shapeRects: [CGRect]? {
        didSet { refreshShapeMaskFromRects() }
    }

    /// SHAPE's input region (`nil` = same as the bounding shape).
    var inputShapeRects: [CGRect]?

    private func refreshShapeMaskFromRects() {
        guard let rects = shapeRects else {
            shapeMask = nil
            return
        }
        let bytes = X11ShapeRegion.maskRGBA(rects, width: pixelWidth, height: pixelHeight)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixelWidth * 4, space: x11DeviceRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        shapeMask = image
    }

    /// Clicks outside a window's shape belong to whatever is beneath it -
    /// for a GTK3 popover drawn over a shaped native child, that is the
    /// parent window the popover lives in. Returning nil here is exactly
    /// "not me" to AppKit, which then tries the next view down.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if shapeRects != nil || inputShapeRects != nil {
            let local = convert(point, from: superview)
            if let rects = shapeRects, !X11ShapeRegion.contains(rects, local) { return nil }
            if let rects = inputShapeRects, !X11ShapeRegion.contains(rects, local) { return nil }
        }
        return super.hitTest(point)
    }

    /// `context` lets the caller build the backing bitmap **off the main
    /// thread**, which matters more than it sounds: `handleCreateWindow`
    /// creates this inside a `DispatchQueue.main.sync` barrier, and an
    /// Xt/Motif/Tk app makes one X window per *widget* - measured
    /// 2026-09-23, xcalc issues **69** `CreateWindow` requests against
    /// Mousepad's **4**. Every allocation left on main is 69 allocations
    /// behind whatever drawing was already queued there.
    ///
    /// `background` is filled ONCE. This used to fill white here and then
    /// get filled again by the caller with the real background pixel -
    /// two full passes over the same buffer, per window, inside that same
    /// barrier.
    init(width: Int, height: Int, context: CGContext? = nil, background: UInt32? = nil) {
        pixelWidth = max(1, width)
        pixelHeight = max(1, height)
        bitmapContext = context ?? makeFlippedBitmapContext(width: pixelWidth, height: pixelHeight)
        super.init(frame: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Solid, not transparent, like a freshly-mapped X window's usual
        // background - a blank/transparent canvas looked broken live (an
        // app that never explicitly clears its window before drawing
        // showed the desktop wallpaper through it instead).
        let rgb = background ?? 0x00FF_FFFF
        bitmapContext.setFillColor(x11Color(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                                            green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                            blue: CGFloat(rgb & 0xFF) / 255))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }

    required init?(coder: NSCoder) { fatalError("X11CanvasView does not support NSCoding") }

    /// Resizes the backing bitmap.
    ///
    /// `preserveContent` is the window's **bit-gravity**, and the default
    /// in X11 is `Forget`: on a resize the contents become *undefined* and
    /// the server exposes the whole window. This server instead preserved
    /// the old pixels at top-left, in a bitmap it never discards, which is
    /// the architectural reason stale content reappears here where a real
    /// server shows background - and why a client told its contents are
    /// `Forget` does not repaint them.
    ///
    /// **The caller must expose the whole window after a resize that does
    /// not preserve.** Otherwise the window is cleared with nothing
    /// telling the client to paint it, and it simply goes blank. The
    /// reference (`miext/rootless`'s `FinishFrameResize`) damages the
    /// entire new area for exactly this reason.
    func resize(width: Int, height: Int, preserveContent: Bool = true, background: UInt32? = nil) {
        guard width > 0, height > 0, width != pixelWidth || height != pixelHeight else { return }
        let newContext = makeFlippedBitmapContext(width: width, height: height)
        if let background {
            newContext.setFillColor(x11Color(red: CGFloat((background >> 16) & 0xFF) / 255,
                                             green: CGFloat((background >> 8) & 0xFF) / 255,
                                             blue: CGFloat(background & 0xFF) / 255))
        } else {
            newContext.setFillColor(x11Color(red: 1, green: 1, blue: 1))
        }
        newContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if preserveContent, let image = bitmapContext.makeImage() {
            // See `drawImageTopLeftOriented`'s doc comment - a plain
            // `draw(image, in:)` here would flip the window's existing
            // content vertically on every resize (same root cause as the
            // `CopyArea`/`PutImage` flip bug it documents, just never
            // caught here specifically since no Layer-0-3 test resizes a
            // window with asymmetric content and checks orientation
            // afterward).
            drawImageTopLeftOriented(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight), on: newContext)
        }
        bitmapContext = newContext
        pixelWidth = width
        pixelHeight = height
        setFrameSize(NSSize(width: CGFloat(width) * displayScale, height: CGFloat(height) * displayScale))
        // A shape is in window pixels and does not grow with the window;
        // the mask image does, so it is rebuilt at the new size.
        if shapeRects != nil { refreshShapeMaskFromRects() }
        else if let mask = layer?.mask { mask.frame = bounds }
        needsDisplay = true
    }

    /// Points per X11 pixel for this view's own frame - Native Scaling
    /// (`X11DisplayScale`). Only a TOP-LEVEL window's canvas is ever
    /// scaled: its bounds stay in X11 pixels while its frame is `pixels x
    /// displayScale`, so AppKit scales both the drawing and every mouse
    /// coordinate (`convert(_:from:)` answers in bounds), and each child
    /// window - a subview laid out in those bounds - needs nothing at all.
    /// A canvas reparented into another window goes back to 1.
    var displayScale: CGFloat = 1 {
        didSet {
            guard displayScale != oldValue else { return }
            setFrameSize(NSSize(width: CGFloat(pixelWidth) * displayScale,
                                height: CGFloat(pixelHeight) * displayScale))
        }
    }

    /// Keeps the bounds in X11 pixels whatever size AppKit gives the frame
    /// - including when the window is resized by hand, which sets the
    /// content view's frame directly. At a scale of 1 this is the identity
    /// and changes nothing.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(NSSize(width: newSize.width / displayScale, height: newSize.height / displayScale))
    }

    /// `NSView.isFlipped` only affects AppKit's OWN graphics-context setup
    /// (used below in `draw(_:)`'s final blit) - `bitmapContext` is a
    /// manually-created, standalone `CGContext`, entirely unrelated to the
    /// view's own coordinate system, so this flag alone does nothing for
    /// it. Confirmed live: without also flipping `bitmapContext` itself
    /// (`makeFlippedBitmapContext`), every non-full-window draw (any real
    /// request - `xterm` draws each terminal line at a distinct Y) landed
    /// at the WRONG vertical position, silently, since a full-canvas fill
    /// (the only thing exercised before real content existed) is flip-
    /// invariant and never exposed it.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = X11Perf.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer { if X11Perf.enabled { X11Perf.frame(nanos: DispatchTime.now().uptimeNanoseconds - perfStart) } }
        guard let image = bitmapContext.makeImage(),
              let cgContext = NSGraphicsContext.current?.cgContext else { return }
        // `NSGraphicsContext.current`'s CGContext, inside a flipped
        // view's `draw(_:)`, ALREADY carries AppKit's own top-left-origin
        // flip - stacking THAT on top of `bitmapContext`'s own manual
        // flip (`makeFlippedBitmapContext`) cancels out to a net
        // NON-flip, showing the drawn content upside down (confirmed
        // live: exactly this - real terminal text, correctly rendered
        // and correctly positioned inside `bitmapContext` itself, showed
        // up inverted once actually composited on screen through this
        // exact call). Counter-flipping locally, same technique
        // `X11Drawable.drawText` already uses for glyphs, undoes AppKit's
        // ambient flip for just this blit so the two cancel back to
        // exactly the one flip `bitmapContext` itself wanted.
        cgContext.saveGState()
        // Composite only what AppKit asked for. The blit used to cover the
        // whole window however small the damage was, so the cost of a
        // partial update scaled with the window's area rather than with
        // what changed. Clipping rather than cropping the image keeps the
        // flip arithmetic below exactly as it was - this is the one place
        // in this file where getting that wrong shows every pixel upside
        // down, and it is not worth re-deriving for a saving CoreGraphics
        // already gives for free behind a clip.
        cgContext.clip(to: dirtyRect)
        // Native Scaling draws X11 pixels at a fraction of a point, which
        // is not a whole number of physical pixels; the default filter
        // shimmers on text at that ratio.
        if displayScale != 1 { cgContext.interpolationQuality = .high }
        cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        cgContext.restoreGState()
    }

    func notifyChanged(damage: CGRect? = nil) {
        X11Perf.notified()
        setNeedsDisplayFromAnyThread(damage)
        X11Snapshot.dump(windowID: windowID, context: bitmapContext)
    }

    func setNeedsDisplayFromAnyThread(_ damage: CGRect? = nil) {
        // This view is `isFlipped`, so its coordinates are top-left origin
        // - the same space X11 uses. A damage rect therefore needs no
        // conversion, only clamping to the view in case a client drew
        // partly outside it.
        let mark = { [weak self] in
            guard let self else { return }
            if let damage {
                let clamped = damage.intersection(self.bounds)
                if !clamped.isNull, !clamped.isEmpty {
                    self.setNeedsDisplay(clamped)
                    return
                }
            }
            self.needsDisplay = true
        }
        if Thread.isMainThread { mark() } else { DispatchQueue.main.async(execute: mark) }
    }

    // MARK: - Input (mouse + keyboard - see X11Keyboard for the real
    // keysym translation keyboard events rely on)

    override var acceptsFirstResponder: Bool { true }

    /// Without this, AppKit's DEFAULT behavior (`acceptsFirstMouse`
    /// returns `false`) "eats" the first click on any window that isn't
    /// already key: that click only brings the window to the front/key -
    /// it is NOT delivered to this view as a real `mouseDown` at all. For
    /// a client that reads mouse position via keyboard focus (`xterm`,
    /// which only needs KEY status, not a delivered click) this is
    /// invisible; for a client whose entire interaction model IS mouse
    /// clicks (galculator's buttons), it means every click that arrives
    /// after the window last had focus is silently swallowed for
    /// activation purposes and the client never sees a `ButtonPress` at
    /// all - indistinguishable from "clicking does nothing" to a user
    /// clicking once and expecting it to register, which is exactly what
    /// it looked like. `NSApplication.shared.activate(ignoringOtherApps:)`
    /// below is a second, complementary fix for a related but distinct
    /// gap: an `.accessory`-policy app (this one) doesn't always reliably
    /// reclaim frontmost-APPLICATION status purely from its window being
    /// clicked the way a normal-policy app's window would.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.activeInActiveApp`, not `.activeInKeyWindow`: with the latter
        // AppKit synthesises `mouseExited` the instant this window stops
        // being key and `mouseEntered` when it is key again - pointer
        // unmoved. A popup (tooltip, Firefox's tab preview) takes key when
        // mapped, so the main window got LeaveNotify, the app hid the popup
        // as "no longer hovered", key came back, EnterNotify, popup shown
        // again: ~40 map/unmap cycles a second and the whole window
        // flickering. In X11 crossing depends only on where the pointer
        // is, never on focus. Each Linux app is its own macOS process, so
        // "active app" is exactly this app's windows.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    /// See `acceptsFirstMouse`'s doc comment for why this call is here,
    /// not just relying on AppKit's normal click-to-activate: confirmed
    /// live this `.accessory`-policy app's window did not reliably
    /// become the frontmost application purely from being clicked.
    ///
    /// Guarded on `!NSApp.isActive || window?.isKeyWindow != true` -
    /// confirmed live that calling `activate`/`makeKeyAndOrderFront`
    /// UNCONDITIONALLY on every single `mouseDown`, even when the app was
    /// ALREADY active and this window already key, could disrupt AppKit's
    /// own mouseDown->mouseUp tracking for THAT SAME click (a real click,
    /// not `CGEventPost`-synthesized, showed the button's pressed/
    /// depressed visual state firing correctly - so `mouseDown` itself
    /// clearly arrived - but the app then appeared frozen, consistent
    /// with `mouseUp` never following through and the toolkit's own
    /// internal pointer grab staying stuck "waiting for a release that
    /// never came"). Only forcing activation when it's actually NEEDED
    /// avoids that disruption for the overwhelmingly common case (the
    /// user clicking a SECOND button while the window is already
    /// focused), while still fixing the original "window lost focus,
    /// first click does nothing" gap for the case that actually needs it.
    private func ensureActivated() {
        guard !NSApplication.shared.isActive || window?.isKeyWindow != true else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Diagnostic only (trace-gated): one physical click was seen reaching
        // GTK as TWO press/release pairs ~0.8s apart when it activated the
        // window. AppKit's eventNumber tells a replayed activating click (same
        // number) from two distinct clicks.
        if X11Trace.mouseEnabled {
            FileHandle.standardError.write("[x11] appkit mouseDown eventNumber=\(event.eventNumber) clickCount=\(event.clickCount) timestamp=\(event.timestamp) appActive=\(NSApplication.shared.isActive) key=\(window?.isKeyWindow ?? false) wid=\(windowID)\n".data(using: .utf8)!)
        }
        ensureActivated()
        // Unconditional (unlike `ensureActivated`'s own guarded re-
        // activation, which deliberately skips work when the window is
        // already key/active - see its doc comment on why doing THAT
        // unconditionally broke AppKit's own click tracking): a click
        // into a DIFFERENT already-key window (e.g. a second top-level
        // window, or a click landing back in this one after some other
        // view briefly held first-responder) still needs to move
        // keyboard focus to THIS view specifically. `makeFirstResponder`
        // is cheap and idempotent - no equivalent disruption risk.
        window?.makeFirstResponder(self)
        eventSink?.mouseButton(event, in: self, pressed: true, button: 1)
    }
    override func mouseUp(with event: NSEvent) {
        if X11Trace.mouseEnabled { // see mouseDown's diagnostic
            FileHandle.standardError.write("[x11] appkit mouseUp eventNumber=\(event.eventNumber) clickCount=\(event.clickCount) timestamp=\(event.timestamp) appActive=\(NSApplication.shared.isActive) key=\(window?.isKeyWindow ?? false) wid=\(windowID)\n".data(using: .utf8)!)
        }
        eventSink?.mouseButton(event, in: self, pressed: false, button: 1)
    }
    override func rightMouseDown(with event: NSEvent) {
        ensureActivated()
        window?.makeFirstResponder(self)
        eventSink?.mouseButton(event, in: self, pressed: true, button: 3)
    }
    override func rightMouseUp(with event: NSEvent) { eventSink?.mouseButton(event, in: self, pressed: false, button: 3) }

    /// AppKit's `buttonNumber` for anything that isn't left (0) or right
    /// (1), mapped to its X11 button number. X11 numbers the middle button
    /// 2 (AppKit calls it 3), and by long-standing convention 8/9 are
    /// "back"/"forward" - AppKit's next two buttons. Without these two
    /// overrides the middle button produced NOTHING at all: X11's
    /// middle-click primary-selection paste, and every app that uses
    /// middle-click for pan/close-tab, were simply dead.
    private static func x11Button(forAppKitButtonNumber n: Int) -> UInt8? {
        switch n {
        case 2: return 2 // middle
        case 3: return 8 // back
        case 4: return 9 // forward
        default: return nil
        }
    }
    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.x11Button(forAppKitButtonNumber: event.buttonNumber) else { return }
        ensureActivated()
        window?.makeFirstResponder(self)
        eventSink?.mouseButton(event, in: self, pressed: true, button: button)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.x11Button(forAppKitButtonNumber: event.buttonNumber) else { return }
        eventSink?.mouseButton(event, in: self, pressed: false, button: button)
    }

    override func mouseDragged(with event: NSEvent) {
        if X11Trace.mouseEnabled { // arrival rate and lag for fast drags
            FileHandle.standardError.write("[x11] appkit mouseDragged eventNumber=\(event.eventNumber) timestamp=\(event.timestamp) uptime=\(ProcessInfo.processInfo.systemUptime) wid=\(windowID)\n".data(using: .utf8)!)
        }
        eventSink?.mouseMoved(event, in: self)
    }
    // A drag with the RIGHT or MIDDLE button held is still pointer motion
    // and must still be reported - AppKit routes it to a separate override
    // from `mouseDragged`, so leaving these out silently froze the pointer
    // for the whole duration of any non-left drag (Krita's pan/rotate,
    // right-drag context gestures).
    override func rightMouseDragged(with event: NSEvent) { eventSink?.mouseMoved(event, in: self) }
    override func otherMouseDragged(with event: NSEvent) { eventSink?.mouseMoved(event, in: self) }
    override func mouseMoved(with event: NSEvent) { eventSink?.mouseMoved(event, in: self) }

    /// Wheel and trackpad scrolling, translated in `X11Connection.scrollWheel`
    /// into XI 2.1 smooth-scroll valuator motion plus legacy button 4-7
    /// clicks (see `X11ScrollTranslator`). This view used to do the
    /// translation itself, as button clicks only, truncating each wheel
    /// event's fractional delta - slow wheel ticks did nothing.
    override func scrollWheel(with event: NSEvent) { eventSink?.scrollWheel(event, in: self) }

    /// Trackpad pinch and rotation - XI 2.4 gestures, or Ctrl+scroll for
    /// clients that don't take them (see `X11Connection.magnify`).
    override func magnify(with event: NSEvent) { eventSink?.magnify(event, in: self) }
    override func rotate(with event: NSEvent) { eventSink?.rotate(event, in: self) }

    /// Without these two overrides, the `.mouseEnteredAndExited` tracking
    /// area set up in `updateTrackingAreas` above fires into AppKit's
    /// default (no-op) `NSResponder.mouseEntered`/`mouseExited` - this
    /// view never told `eventSink` a crossing happened at all. See
    /// `gui-bugs.md` issue #10 and `X11Connection.sendXICrossingEvent`'s
    /// doc comment: GTK's menu-item activation depends on having seen a
    /// real `XI_Enter` on the item's own window before the matching
    /// `ButtonRelease`, not on the button event alone.
    override func mouseEntered(with event: NSEvent) { eventSink?.mouseCrossing(event, in: self, entered: true) }
    override func mouseExited(with event: NSEvent) { eventSink?.mouseCrossing(event, in: self, entered: false) }

    override func keyDown(with event: NSEvent) {
        if routeAsText(event) { return }
        eventSink?.keyEvent(event, in: self, pressed: true)
    }
    override func keyUp(with event: NSEvent) {
        if textRoutedKeys.remove(event.keyCode) != nil { return }
        eventSink?.keyEvent(event, in: self, pressed: false)
    }

    /// Command-key events, which AppKit never delivers to `keyDown`/`keyUp`
    /// reliably - see `X11KeyboardRouter`.
    func forwardKey(_ event: NSEvent, pressed: Bool) { eventSink?.keyEvent(event, in: self, pressed: pressed) }
    // Without this, AppKit's default `NSResponder.flagsChanged` handling
    // never reaches `keyEvent` at all for pure modifier taps (Shift/
    // Control/Option alone, no other key) - not critical for basic typing
    // but Control needs to be down-in-time for terminal Ctrl+<key> combos
    // regardless of whether it arrived with the letter or a moment
    // earlier, so this still forwards them the same way.
    override func flagsChanged(with event: NSEvent) {
        eventSink?.modifierFlagsChanged(event, in: self)
    }
}

/// Callback surface `X11CanvasView` uses to report real AppKit input back
/// to the owning `X11Connection`, which translates it into X11 wire
/// events.
protocol X11EventSink: AnyObject {
    func mouseButton(_ event: NSEvent, in view: X11CanvasView, pressed: Bool, button: UInt8)
    func scrollWheel(_ event: NSEvent, in view: X11CanvasView)
    func magnify(_ event: NSEvent, in view: X11CanvasView)
    func rotate(_ event: NSEvent, in view: X11CanvasView)
    func mouseMoved(_ event: NSEvent, in view: X11CanvasView)
    func mouseCrossing(_ event: NSEvent, in view: X11CanvasView, entered: Bool)
    func keyEvent(_ event: NSEvent, in view: X11CanvasView, pressed: Bool)
    func modifierFlagsChanged(_ event: NSEvent, in view: X11CanvasView)
    /// Text with no key behind it (emoji picker, dictation, input methods).
    func insertText(_ text: String, in view: X11CanvasView)
}
