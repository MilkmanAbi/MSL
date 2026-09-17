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

    init(width: Int, height: Int) {
        pixelWidth = max(1, width)
        pixelHeight = max(1, height)
        bitmapContext = makeFlippedBitmapContext(width: pixelWidth, height: pixelHeight)
        super.init(frame: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Starts solid white, like a freshly-mapped X window's usual
        // background - a blank/transparent canvas looked broken live (an
        // app that never explicitly clears its window before drawing
        // showed the desktop wallpaper through it instead).
        bitmapContext.setFillColor(x11Color(red: 1, green: 1, blue: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }

    required init?(coder: NSCoder) { fatalError("X11CanvasView does not support NSCoding") }

    func resize(width: Int, height: Int) {
        guard width > 0, height > 0, width != pixelWidth || height != pixelHeight else { return }
        let newContext = makeFlippedBitmapContext(width: width, height: height)
        newContext.setFillColor(x11Color(red: 1, green: 1, blue: 1))
        newContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let image = bitmapContext.makeImage() {
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
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
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
        cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        cgContext.restoreGState()
    }

    func notifyChanged() {
        setNeedsDisplayFromAnyThread()
        X11Snapshot.dump(windowID: windowID, context: bitmapContext)
    }

    func setNeedsDisplayFromAnyThread() {
        if Thread.isMainThread {
            needsDisplay = true
        } else {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
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
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
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

    /// Scroll wheel. X11 has no scroll event: the core protocol expresses
    /// a wheel notch as a press+release pair on button 4 (up), 5 (down),
    /// 6 (left) or 7 (right), and that is still how GTK and Qt read
    /// scrolling under XInput2 as well (`XI_ButtonPress` with `detail` 4-7)
    /// whenever the server advertises no smooth-scroll valuator classes -
    /// which this server deliberately does not, see
    /// `handleXIQueryDevice`'s doc comment on the GDK
    /// `_gdk_x11_device_xi2_add_scroll_valuator` assertion that advertising
    /// them triggered.
    ///
    /// This view had NO `scrollWheel` override at all, so scrolling was
    /// entirely non-functional in every app - no document scrolling, no
    /// list scrolling, no canvas zoom.
    ///
    /// A trackpad reports many small `hasPreciseScrollingDeltas` events
    /// rather than discrete notches, so deltas are accumulated here and
    /// only emitted once a notch's worth has built up; a real wheel
    /// (non-precise) already reports whole notches and passes straight
    /// through.
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        let notch: CGFloat = 10 // points of precise scrolling per emitted button click
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        // Cap the per-event burst: a fast flick can otherwise synthesize
        // hundreds of button pairs in one go and swamp the client.
        let maxClicks: CGFloat = 8
        if event.hasPreciseScrollingDeltas {
            scrollAccumX += dx
            scrollAccumY += dy
            // Clamp BEFORE draining the accumulator, so a burst that hits
            // the cap leaves its excess in the accumulator for the next
            // event instead of silently losing that scroll distance.
            dx = min(max((scrollAccumX / notch).rounded(.towardZero), -maxClicks), maxClicks)
            dy = min(max((scrollAccumY / notch).rounded(.towardZero), -maxClicks), maxClicks)
            scrollAccumX -= dx * notch
            scrollAccumY -= dy * notch
        } else {
            dx = min(max(dx, -maxClicks), maxClicks)
            dy = min(max(dy, -maxClicks), maxClicks)
        }
        func emit(_ button: UInt8, times: Int) {
            for _ in 0..<times {
                eventSink?.mouseButton(event, in: self, pressed: true, button: button)
                eventSink?.mouseButton(event, in: self, pressed: false, button: button)
            }
        }
        // AppKit's positive `scrollingDeltaY` means the content moves down,
        // i.e. the user scrolled UP - X11 button 4.
        if dy > 0 { emit(4, times: Int(dy)) } else if dy < 0 { emit(5, times: Int(-dy)) }
        if dx > 0 { emit(6, times: Int(dx)) } else if dx < 0 { emit(7, times: Int(-dx)) }
    }

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

    override func keyDown(with event: NSEvent) { eventSink?.keyEvent(event, in: self, pressed: true) }
    override func keyUp(with event: NSEvent) { eventSink?.keyEvent(event, in: self, pressed: false) }

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
    func mouseMoved(_ event: NSEvent, in view: X11CanvasView)
    func mouseCrossing(_ event: NSEvent, in view: X11CanvasView, entered: Bool)
    func keyEvent(_ event: NSEvent, in view: X11CanvasView, pressed: Bool)
    func modifierFlagsChanged(_ event: NSEvent, in view: X11CanvasView)
}
