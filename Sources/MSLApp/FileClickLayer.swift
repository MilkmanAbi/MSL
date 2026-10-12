import AppKit
import MSLCore
import SwiftUI

/// The single owner of left clicks on a file item, in every view mode.
///
/// Selection used to be a tug-of-war. Each row carried a SwiftUI single-tap,
/// a simultaneous double-tap, `.draggable` (which grabs mouse-down on macOS to
/// watch for a drag), and - in the list - `List`'s own native selection. Which
/// one won depended on timing, so a click might select, be undone by the next
/// handler, or need repeating; highlighting "switched back and forth".
///
/// This replaces all four with one AppKit view that does what Finder does:
///
/// - **Mouse-down selects**, immediately, using the modifiers and click count
///   from the real event (SwiftUI's tap gesture carries neither).
/// - **A second click opens.** No waiting out a double-click interval first.
/// - **Mouse-down on an item that's already part of a multi-selection doesn't
///   collapse it** - you might be starting a drag. It collapses on mouse-up if
///   you didn't drag, exactly like Finder.
/// - **Dragging starts here**, carrying every selected file, so a drag out to
///   Finder, Mail or another root copies the lot.
/// - **Accepts first mouse**, so a click that also takes focus away from the
///   search field still selects.
///
/// Everything that isn't a plain left mouse-down - right-click, control-click,
/// scrolling, hover, a drag already in flight - is passed straight through by
/// `hitTest`, so the SwiftUI context menu and drop targets underneath keep
/// working untouched.
struct FileClickLayer: NSViewRepresentable {
    /// The item's path - how the marquee maps this view back to a file.
    var path: String
    var isSelected: () -> Bool
    var onSelect: (NSEvent.ModifierFlags) -> Void
    var onOpen: () -> Void
    var dragItems: () -> [MSLFileItem]
    /// Off while the item is being renamed inline, so the text field gets the
    /// clicks instead.
    var enabled: Bool = true
    /// How far from the leading edge a drag picks up the *file*. Past it, a
    /// drag becomes a marquee instead - Finder's list view, where only the
    /// icon and name are the file and the rest of the row is whitespace you
    /// can rubber-band from. nil: the whole item drags the file (icon view).
    var dragHandleWidth: CGFloat? = nil

    func makeNSView(context: Context) -> FileClickView { FileClickView() }

    func updateNSView(_ view: FileClickView, context: Context) {
        view.path = path
        view.isSelected = isSelected
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.dragItems = dragItems
        view.enabled = enabled
        view.dragHandleWidth = dragHandleWidth
    }
}

final class FileClickView: NSView, NSDraggingSource {
    /// Every item view currently alive, so the marquee can ask each where it
    /// is. Weak: rows the list recycles and cells a lazy grid unloads simply
    /// drop out.
    static let live = NSHashTable<FileClickView>.weakObjects()

    var path = ""
    var isSelected: () -> Bool = { false }
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var dragItems: () -> [MSLFileItem] = { [] }
    var enabled = true
    var dragHandleWidth: CGFloat?
    /// Set when a drag from row whitespace was handed to the marquee; the rest
    /// of this mouse gesture is forwarded to it.
    private weak var marqueeHandoff: MarqueeView?

    private var downEvent: NSEvent?
    private var dragged = false
    /// Set when mouse-down landed on an item already in the selection with no
    /// modifiers: the collapse to a single selection waits for mouse-up.
    private var deferredSelect = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.live.add(self) } else { Self.live.remove(self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, let event = NSApp.currentEvent,
              event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control)   // control-click = context menu
        else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // A recycled row can still hold the hand-off of a drag that ended
        // while it was off-screen; a new press starts clean.
        marqueeHandoff = nil
        takeFocusFromTextFields()
        downEvent = event
        dragged = false
        deferredSelect = false

        if event.clickCount == 2 {
            onOpen()
            return
        }
        guard event.clickCount == 1 else { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers.isEmpty, isSelected() {
            deferredSelect = true
        } else {
            onSelect(event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let marqueeHandoff { marqueeHandoff.mouseDragged(with: event); return }
        guard !dragged, let down = downEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        dragged = true
        deferredSelect = false
        // Started on the row's whitespace, not its icon or name: rubber-band.
        if let limit = dragHandleWidth, convert(start, from: nil).x > limit,
           let marquee = MarqueeView.covering(windowPoint: start, in: window) {
            marqueeHandoff = marquee
            marquee.mouseDown(with: down)
            marquee.mouseDragged(with: event)
            return
        }
        // Dragging an unselected item drags just that item - and selects it,
        // which is what the mouse-down already did.
        let items = dragItems()
        guard !items.isEmpty else { return }
        let origin = convert(down.locationInWindow, from: nil)
        let draggingItems: [NSDraggingItem] = items.prefix(64).enumerated().map { index, item in
            let dragItem = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: item.path) as NSURL)
            let icon = FileIconCache.shared.icon(for: item)
            let offset = CGFloat(min(index, 4)) * 3
            dragItem.setDraggingFrame(NSRect(x: origin.x - 16 + offset, y: origin.y - 16 - offset,
                                             width: 32, height: 32),
                                      contents: icon)
            return dragItem
        }
        let session = beginDraggingSession(with: draggingItems, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if let marqueeHandoff {
            marqueeHandoff.mouseUp(with: event)
            self.marqueeHandoff = nil
            downEvent = nil
            return
        }
        if deferredSelect, !dragged { onSelect([]) }
        deferredSelect = false
        downEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move, .generic]
    }

    /// A click in the file area ends editing in the search or rename field,
    /// and leaves the window itself as first responder - not a table view,
    /// which would swallow the arrow keys the model uses to move the selection.
    private func takeFocusFromTextFields() {
        guard let window, !(window.firstResponder === window) else { return }
        window.makeFirstResponder(nil)
    }
}

/// Arrow-key navigation for the file area, handled from the real key event.
///
/// Installed as a background of the Files window. It only acts while its own
/// window is key, nothing is being typed into (a text field would want the
/// arrows), and no rename is in progress; otherwise the event goes on its way
/// untouched. Shift is read from the event itself, which is the one thing the
/// SwiftUI shortcut version got wrong.
struct ArrowKeyMonitor: NSViewRepresentable {
    let files: FilesModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.files = files
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.files = files }

    final class MonitorView: NSView {
        weak var files: FilesModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let files = self.files, let window = self.window,
                      event.window === window, window.isKeyWindow,
                      !(window.firstResponder is NSText),
                      files.renaming == nil, !files.isShowingDashboard,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                else { return event }
                let delta: Int
                switch event.keyCode {
                case 123, 126: delta = -1   // left, up
                case 124, 125: delta = 1    // right, down
                default: return event
                }
                MainActor.assumeIsolated {
                    files.moveSelection(by: delta, extend: event.modifierFlags.contains(.shift))
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
