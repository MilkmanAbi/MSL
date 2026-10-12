import AppKit
import SwiftUI

/// How a marquee's hits combine with what was selected before the drag -
/// Finder's rules, kept pure so they're tested on their own.
enum MarqueeRule: Equatable {
    /// No modifier: the rectangle *is* the selection.
    case replace
    /// ⇧: the rectangle adds to what was already selected.
    case add
    /// ⌘: the rectangle flips each item it covers.
    case toggle

    init(modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) { self = .toggle }
        else if modifiers.contains(.shift) { self = .add }
        else { self = .replace }
    }

    func combine(base: Set<String>, hits: Set<String>) -> Set<String> {
        switch self {
        case .replace: return hits
        case .add: return base.union(hits)
        case .toggle: return base.symmetricDifference(hits)
        }
    }
}

/// Rubber-band selection over the list and the icon grid.
///
/// A transparent AppKit layer above the scroll view that takes a mouse-down
/// only on *empty* space - anything over an item (`FileClickView`), a scroll
/// bar or a text field is passed through untouched, as are right-clicks and
/// scrolling. Items are hit-tested with their real AppKit frames converted
/// into the scroll view's document coordinates, which stay put while the view
/// scrolls; frames are remembered once seen, so rows a list recycles or cells
/// a lazy grid unloads while the rectangle still covers them stay selected.
struct MarqueeLayer: NSViewRepresentable {
    @ObservedObject var files: FilesModel

    func makeNSView(context: Context) -> MarqueeView { MarqueeView() }

    func updateNSView(_ view: MarqueeView, context: Context) {
        view.files = files
        view.tint = NSColor(files.theme.selection)
    }
}

final class MarqueeView: NSView {
    /// Live marquees, so a list row can hand a whitespace drag to the one
    /// covering it.
    static let live = NSHashTable<MarqueeView>.weakObjects()

    static func covering(windowPoint: NSPoint, in window: NSWindow?) -> MarqueeView? {
        live.allObjects.first { view in
            view.window === window && window != nil
                && view.convert(view.bounds, to: nil).contains(windowPoint)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.live.add(self) } else { Self.live.remove(self) }
    }

    weak var files: FilesModel?
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    // Drag state. `nil` start = no marquee in progress.
    private weak var scrollView: NSScrollView?
    private var startInDocument: NSPoint?
    private var lastWindowPoint = NSPoint.zero
    private var lastEvent: NSEvent?
    private var dragging = false
    private var rule = MarqueeRule.replace
    private var baseSelection: Set<String> = []
    private var knownFrames: [String: NSRect] = [:]
    private var autoscrollTimer: Timer?
    private var escapeMonitor: Any?
    /// Tracks the rest of the drag at window level once a marquee begins.
    /// A drag handed over from a list row arrives through that row's view, and
    /// once autoscroll carries the row off-screen the list recycles it - a view
    /// out of the window gets no more of the gesture, so the mouse-up never
    /// came and the marquee (and its autoscroll) ran on forever.
    private var trackingMonitor: Any?
    /// Set while asking what lies *under* this view, so our own hitTest steps
    /// aside for the probe.
    private var probing = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hit testing - empty space only

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !probing, let window, let superview,
              frame.contains(point),
              let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        let windowPoint = superview.convert(point, to: nil)
        probing = true
        let underneath = window.contentView?.hitTest(
            window.contentView?.convert(windowPoint, from: nil) ?? windowPoint)
        probing = false
        // Items, scroll bars and text fields keep their own clicks.
        var view = underneath
        while let current = view {
            if current is FileClickView || current is NSScroller || current is NSText
                || current is NSTextField { return nil }
            view = current.superview
        }
        return self
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let files, let window else { return }
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
        scrollView = scrollViewUnder(event.locationInWindow)
        guard let document = scrollView?.documentView else { return }
        startInDocument = document.convert(event.locationInWindow, from: nil)
        lastWindowPoint = event.locationInWindow
        lastEvent = event
        dragging = false
        rule = MarqueeRule(modifiers: event.modifierFlags)
        baseSelection = files.selection
        knownFrames = [:]
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }   // the tracking monitor has it now
        guard let start = startInDocument, let document = scrollView?.documentView else { return }
        lastWindowPoint = event.locationInWindow
        lastEvent = event
        if !dragging {
            let now = document.convert(event.locationInWindow, from: nil)
            guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
            beginDrag()
        }
        update()
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragging else { return endDrag() }
        if startInDocument != nil {
            // A click on empty space, no drag: Finder clears the selection
            // (a modified click leaves it alone).
            if MarqueeRule(modifiers: event.modifierFlags) == .replace { files?.selection = [] }
        }
        endDrag()
    }

    // MARK: Drag lifecycle

    private func beginDrag() {
        dragging = true
        if rule == .replace { files?.selection = [] }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
        trackingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.dragging else { return event }
            if event.type == .leftMouseUp {
                self.endDrag()
            } else {
                self.lastWindowPoint = event.locationInWindow
                self.update()
            }
            return nil   // consumed: no stray drag or mouse-up reaches a row
        }
        // Esc cancels: the selection goes back to what it was before the drag.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.files?.selection = self.baseSelection
            self.endDrag()
            return nil
        }
    }

    private func endDrag() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let trackingMonitor { NSEvent.removeMonitor(trackingMonitor) }
        trackingMonitor = nil
        startInDocument = nil
        dragging = false
        knownFrames = [:]
        needsDisplay = true
    }

    /// Recomputes the rectangle and the selection it implies.
    private func update() {
        guard dragging, let files, let rect = documentRect, let document = scrollView?.documentView else { return }
        for view in FileClickView.live.allObjects where view.window === window && !view.path.isEmpty {
            // Only items inside this scroll view (another window or view mode
            // must not leak in).
            guard view.isDescendant(of: document) else { continue }
            knownFrames[view.path] = view.convert(view.bounds, to: document)
        }
        let hits = Set(knownFrames.compactMap { $0.value.intersects(rect) ? $0.key : nil })
        let next = rule.combine(base: baseSelection, hits: hits)
        if next != files.selection { files.selection = next }
        needsDisplay = true
    }

    private var documentRect: NSRect? {
        guard let start = startInDocument, let document = scrollView?.documentView else { return nil }
        let now = document.convert(lastWindowPoint, from: nil)
        return NSRect(x: min(start.x, now.x), y: min(start.y, now.y),
                      width: abs(now.x - start.x), height: abs(now.y - start.y))
    }

    // MARK: Autoscroll

    /// Scrolls while the pointer is near or past the top/bottom edge - faster
    /// the further out it is - and keeps going while the mouse is held still,
    /// which is what makes selecting a long list by dragging practical.
    private func autoscrollTick() {
        guard dragging, let scrollView, let document = scrollView.documentView else { return }
        // Backstop: if the button is up and we somehow missed the release, stop.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return endDrag() }
        // Re-measure every tick, not only when the mouse moves or the view
        // scrolls: rows still animating in after a view switch, cells a lazy
        // grid is loading, or a listing that refreshes mid-drag all move under
        // a pointer that's being held still - and a selection computed from
        // stale frames dropped the very row the drag started on.
        defer { update() }
        let clip = scrollView.contentView
        let point = clip.convert(lastWindowPoint, from: nil)
        let visible = clip.bounds
        let edge: CGFloat = 28
        var delta: CGFloat = 0
        if point.y < visible.minY + edge {
            delta = -speed(for: visible.minY + edge - point.y)
        } else if point.y > visible.maxY - edge {
            delta = speed(for: point.y - (visible.maxY - edge))
        }
        guard delta != 0 else { return }
        let maxY = max(0, document.frame.height - visible.height)
        var origin = visible.origin
        origin.y = min(max(origin.y + delta, 0), maxY)
        guard origin.y != visible.origin.y else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func speed(for depth: CGFloat) -> CGFloat {
        min(max(depth * 0.45, 2), 48)
    }

    private func scrollViewUnder(_ windowPoint: NSPoint) -> NSScrollView? {
        guard let content = window?.contentView else { return nil }
        probing = true
        let underneath = content.hitTest(content.convert(windowPoint, from: nil))
        probing = false
        var view = underneath
        while let current = view {
            if let scroll = current as? NSScrollView { return scroll }
            view = current.superview
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard dragging, let rect = documentRect, let document = scrollView?.documentView,
              rect.width > 0 || rect.height > 0 else { return }
        // Views don't clip to their bounds by default any more (macOS 14+); a
        // rectangle dragged past the list would otherwise paint over the
        // status bar below it.
        NSBezierPath(rect: bounds).addClip()
        let local = convert(document.convert(rect, to: nil), from: nil).integral.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: local, xRadius: 2, yRadius: 2)
        tint.withAlphaComponent(0.16).setFill()
        path.fill()
        tint.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

