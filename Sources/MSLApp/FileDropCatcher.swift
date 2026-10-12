import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A drag destination covering the whole window, in AppKit.
///
/// **SwiftUI's `List` eats drags over its empty space.** A folder row has a
/// drop target and works; the blank area below the rows belongs to the table
/// view, which answers the drag itself and never passes it out to the
/// container the modifier was attached to. So no amount of putting
/// `onDrop` on an ancestor helps - the drag is already spoken for.
///
/// This sits on the window's content view, above everything SwiftUI draws,
/// and works out where a drop means to land from where it happened.
struct FileDropCatcher: NSViewRepresentable {
    let destination: () -> String?
    let folderUnderPoint: (String) -> String?
    let receive: ([URL], String) -> Void

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.apply(destination: destination, folder: folderUnderPoint, receive: receive)
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.apply(destination: destination, folder: folderUnderPoint, receive: receive)
    }

    /// A zero-size view whose only job is to find the window and hang the
    /// real destination off its content view.
    final class Anchor: NSView {
        private weak var overlay: Overlay?
        private var destination: (() -> String?)?
        private var folderUnderPoint: ((String) -> String?)?
        private var receive: (([URL], String) -> Void)?

        func apply(destination: @escaping () -> String?,
                   folder: @escaping (String) -> String?,
                   receive: @escaping ([URL], String) -> Void) {
            self.destination = destination
            self.folderUnderPoint = folder
            self.receive = receive
            overlay?.destination = destination
            overlay?.folderUnderPoint = folder
            overlay?.receive = receive
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let content = window?.contentView else { return }
            guard overlay?.superview !== content else { return matchOverlayFrame() }
            let added = Overlay(frame: .zero)
            added.destination = destination
            added.folderUnderPoint = folderUnderPoint
            added.receive = receive
            content.addSubview(added, positioned: .above, relativeTo: nil)
            overlay = added
            matchOverlayFrame()
        }

        override func layout() {
            super.layout()
            matchOverlayFrame()
        }

        /// Keeps the overlay exactly over the file area.
        ///
        /// **Not the whole window.** This anchor is the browser's background,
        /// so its frame is the listing and nothing else - and that matters,
        /// because an overlay covering everything would also sit over the
        /// sidebar and answer drops meant for Downloads or an instance,
        /// sending them to whichever folder happened to be open instead.
        private func matchOverlayFrame() {
            guard let overlay, let content = window?.contentView, superview != nil else { return }
            let frameInContent = convert(bounds, to: content)
            if overlay.frame != frameInContent { overlay.frame = frameInContent }
        }

        deinit { overlay?.removeFromSuperview() }
    }

    final class Overlay: NSView {
        var destination: (() -> String?)?
        var folderUnderPoint: ((String) -> String?)?
        var receive: (([URL], String) -> Void)?
        private var highlighted = false { didSet { needsDisplay = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes([.fileURL])
        }

        /// Invisible to clicks, findable by drags. AppKit locates a drop
        /// target by hit-testing, so returning nil unconditionally would mean
        /// never being offered one; it declines only while a mouse event is
        /// being routed, and during a drag there is none.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                 .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel:
                return nil
            default:
                return super.hitTest(point)
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard target(for: sender) != nil, !urls(from: sender).isEmpty else { return [] }
            highlighted = true
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            target(for: sender) != nil ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
        override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            highlighted = false
            let found = urls(from: sender)
            guard !found.isEmpty, let target = target(for: sender) else { return false }
            receive?(found, target)
            return true
        }

        /// The folder row under the cursor, else the folder being browsed.
        private func target(for sender: NSDraggingInfo) -> String? {
            let inWindow = sender.draggingLocation
            for row in FileClickView.live.allObjects where row.window === window {
                guard row.convert(row.bounds, to: nil).contains(inWindow) else { continue }
                if let folder = folderUnderPoint?(row.path) { return folder }
                break
            }
            return destination?()
        }

        private func urls(from sender: NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: options) as? [URL]) ?? []
        }

        override func draw(_ dirtyRect: NSRect) {
            guard highlighted else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            bounds.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3),
                                       xRadius: 8, yRadius: 8)
            outline.lineWidth = 3
            outline.stroke()
        }
    }
}
