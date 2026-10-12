import Foundation

/// macOS scroll events -> XInput 2.1 smooth scrolling plus legacy wheel
/// clicks, the way a real Xorg with libinput reports a mouse wheel and a
/// touchpad.
///
/// XI2proto "Smooth scrolling": scroll axes are valuators with a
/// ScrollClass, and the server provides *both* the valuator motion and the
/// legacy button 4-7 events, one click per `increment` of valuator travel,
/// marking the emulated half with `XIPointerEmulated`. Toolkits pick one:
/// GTK3 turns valuator deltas into GDK_SCROLL_SMOOTH for widgets that ask
/// for smooth scrolling and the emulated clicks into discrete scrolls for
/// the rest (`gdkwindow.c`); Qt and Chromium read the valuators and ignore
/// legacy clicks once a device has a ScrollClass; core clients only ever
/// see buttons.
///
/// Two sources, like two physical devices:
/// - **wheel** (no precise deltas): one valuator unit per line, increment
///   1. macOS's wheel acceleration arrives as fractional lines, which
///   accumulate - the old code truncated each event with `Int(dy)`, so slow
///   wheel ticks under 1.0 line did nothing at all.
/// - **touchpad** (precise deltas, Magic Mouse included): valuator units are
///   X pixels of finger travel, increment `touchpadIncrement`, so Qt gets
///   pixel deltas (it uses raw deltas once the increment exceeds 15) and
///   GTK/Chromium get fractional clicks.
///
/// Direction: AppKit's `scrollingDelta` already includes the user's
/// natural-scrolling preference, positive meaning the content moves
/// down/right. X's vertical valuator grows when scrolling *down* (button 5 =
/// +1 unit, XI2proto), so both axes are negated.
struct X11ScrollTranslator {
    enum Source: Equatable { case wheel, touchpad }

    /// Valuator units per legacy click.
    static let wheelIncrement = 1.0
    /// X pixels of touchpad travel per legacy click. Chromium scrolls about
    /// 53 px per wheel click, so this keeps the two devices in proportion.
    static let touchpadIncrement = 50.0
    /// At most this many legacy clicks per axis per event; the rest carries
    /// over, so a fast flick can't flood a client with button pairs.
    static let maxClicksPerEvent = 8

    static func increment(_ source: Source) -> Double {
        source == .wheel ? wheelIncrement : touchpadIncrement
    }

    struct Step: Equatable {
        var source: Source
        /// Valuator deltas, in the source's units. Positive = right / down.
        var dx: Double
        var dy: Double
        /// Legacy buttons (4 up, 5 down, 6 left, 7 right), in send order.
        var clicks: [UInt8]
    }

    private var remainderX = 0.0
    private var remainderY = 0.0
    private var lastSource: Source?

    /// `scale` is Native Scaling's points-per-X-pixel factor (touchpad
    /// deltas are in points). `beginsGesture` is true for the first event
    /// of a new touch gesture: leftover fractions of a click from the last
    /// gesture must not leak into this one.
    mutating func translate(scrollingDeltaX: Double, scrollingDeltaY: Double, precise: Bool,
                            beginsGesture: Bool, scale: Double = 1) -> Step {
        let source: Source = precise ? .touchpad : .wheel
        if beginsGesture || source != lastSource {
            remainderX = 0
            remainderY = 0
        }
        lastSource = source
        let perUnit = precise ? 1 / max(scale, 0.01) : 1
        let dx = -scrollingDeltaX * perUnit
        let dy = -scrollingDeltaY * perUnit
        let increment = Self.increment(source)
        remainderX += dx / increment
        remainderY += dy / increment
        var clicks: [UInt8] = []
        func drain(_ remainder: inout Double, negative: UInt8, positive: UInt8) {
            // The epsilon: ten 0.3-line ticks sum to 2.9999999, and without
            // it the third click never came.
            let whole = min(Double(Self.maxClicksPerEvent), (abs(remainder) + 1e-9).rounded(.down))
            guard whole >= 1 else { return }
            let sign: Double = remainder < 0 ? -1 : 1
            clicks += Array(repeating: remainder < 0 ? negative : positive, count: Int(whole))
            remainder -= sign * whole
        }
        drain(&remainderY, negative: 4, positive: 5)
        drain(&remainderX, negative: 6, positive: 7)
        return Step(source: source, dx: dx, dy: dy, clicks: clicks)
    }
}

/// Pinch (and rotate) on a trackpad, for clients that don't select XI 2.4
/// gesture events: Ctrl + scroll, the zoom convention every Linux toolkit
/// and browser follows. Zooming in is Ctrl + scroll up.
///
/// One click per `magnificationPerClick` of accumulated magnification,
/// which is ~10% - the step browsers zoom by per Ctrl+wheel click. The
/// smooth valuator delta is proportional, so apps with continuous Ctrl-zoom
/// (image viewers, GIMP) follow the fingers.
struct X11PinchZoomFallback {
    static let magnificationPerClick = 0.1

    private var remainder = 0.0

    mutating func reset() { remainder = 0 }

    /// Vertical valuator delta (touchpad units) and clicks for one
    /// `magnify` event.
    mutating func translate(magnification: Double) -> (dy: Double, clicks: [UInt8]) {
        let units = -magnification / Self.magnificationPerClick // zoom in = scroll up = negative
        remainder += units
        let whole = min(Double(X11ScrollTranslator.maxClicksPerEvent), (abs(remainder) + 1e-9).rounded(.down))
        var clicks: [UInt8] = []
        if whole >= 1 {
            clicks = Array(repeating: remainder < 0 ? 4 : 5, count: Int(whole))
            remainder -= (remainder < 0 ? -1 : 1) * whole
        }
        return (units * X11ScrollTranslator.touchpadIncrement, clicks)
    }
}
