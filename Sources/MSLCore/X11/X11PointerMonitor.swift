import AppKit

/// Pointer motion anywhere on the Mac screen, for clients that select
/// `XI_RawMotion` on the root window (xeyes follows the pointer this way;
/// with XI2 present it has no timer fallback, so without these events its
/// pupils never move).
///
/// AppKit only delivers `mouseMoved` to a view while the pointer is over
/// it, so this uses NSEvent monitors: a global one for motion over other
/// apps and the desktop, and a local one for motion over this process's own
/// windows (global monitors never see their own app's events). Mouse-event
/// global monitors need no Accessibility permission (only key events do).
///
/// Motion is coalesced to `minimumInterval` with a trailing flush, so a
/// 120 Hz trackpad doesn't flood a client that redraws on every event,
/// and the last position of a stroke is still always delivered.
///
/// Main thread only. Monitors are installed while at least one subscriber
/// is alive and removed after the last one goes.
final class X11PointerMonitor {
    static let shared = X11PointerMonitor()

    /// Delivery cadence: 60 Hz.
    static let minimumInterval: TimeInterval = 1.0 / 60

    private struct Subscriber {
        weak var owner: AnyObject?
        let handler: (_ dx: Double, _ dy: Double) -> Void
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var throttle = X11MotionThrottle(minimumInterval: X11PointerMonitor.minimumInterval)
    private var flushScheduled = false

    func subscribe(_ owner: AnyObject, handler: @escaping (_ dx: Double, _ dy: Double) -> Void) {
        subscribers[ObjectIdentifier(owner)] = Subscriber(owner: owner, handler: handler)
        installIfNeeded()
    }

    func unsubscribe(_ owner: AnyObject) {
        subscribers.removeValue(forKey: ObjectIdentifier(owner))
        removeIfUnused()
    }

    private func installIfNeeded() {
        guard globalMonitor == nil, !subscribers.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    private func removeIfUnused() {
        subscribers = subscribers.filter { $0.value.owner != nil }
        guard subscribers.isEmpty else { return }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func record(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if throttle.add(dx: Double(event.deltaX), dy: Double(event.deltaY), now: now) {
            flush(now: now)
        } else if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + throttle.remaining(now: now)) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flush(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func flush(now: TimeInterval) {
        guard let delta = throttle.take(now: now) else { return }
        for subscriber in subscribers.values where subscriber.owner != nil {
            subscriber.handler(delta.dx, delta.dy)
        }
        removeIfUnused()
    }
}

/// The coalescing arithmetic behind `X11PointerMonitor`, kept free of
/// AppKit so it can be tested directly.
struct X11MotionThrottle {
    let minimumInterval: TimeInterval
    private(set) var pendingDX = 0.0
    private(set) var pendingDY = 0.0
    private(set) var hasPending = false
    private var lastSent: TimeInterval = -.infinity

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Accumulates one motion; true when it may be sent right away.
    mutating func add(dx: Double, dy: Double, now: TimeInterval) -> Bool {
        pendingDX += dx
        pendingDY += dy
        hasPending = true
        return now - lastSent >= minimumInterval
    }

    /// Seconds until the next send is allowed.
    func remaining(now: TimeInterval) -> TimeInterval {
        max(0, minimumInterval - (now - lastSent))
    }

    /// The accumulated motion, if any, and resets it.
    mutating func take(now: TimeInterval) -> (dx: Double, dy: Double)? {
        guard hasPending else { return nil }
        defer { pendingDX = 0; pendingDY = 0; hasPending = false; lastSent = now }
        return (pendingDX, pendingDY)
    }
}
