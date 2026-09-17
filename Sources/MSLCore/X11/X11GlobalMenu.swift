import AppKit
#if canImport(Darwin)
import Darwin
#endif

/// One entry of a Linux app's menu, as the guest's menu bridge sends it -
/// a `com.canonical.dbusmenu` item flattened to JSON (`GuestIntegration`).
struct X11GlobalMenuItem: Equatable {
    enum Toggle: Equatable { case none, checkmark, radio }

    let id: Int
    let label: String
    let enabled: Bool
    let visible: Bool
    let isSeparator: Bool
    let toggle: Toggle
    let isOn: Bool
    let hasSubmenu: Bool
    let children: [X11GlobalMenuItem]

    init?(json: Any?) {
        guard let object = json as? [String: Any], let id = (object["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        label = Self.plainLabel(object["label"] as? String ?? "")
        enabled = (object["enabled"] as? Bool) ?? true
        visible = (object["visible"] as? Bool) ?? true
        isSeparator = (object["type"] as? String) == "separator"
        switch object["toggle"] as? String {
        case "checkmark": toggle = .checkmark
        case "radio": toggle = .radio
        default: toggle = .none
        }
        isOn = ((object["state"] as? NSNumber)?.intValue ?? -1) == 1
        children = (object["children"] as? [Any] ?? []).compactMap { X11GlobalMenuItem(json: $0) }
        hasSubmenu = (object["submenu"] as? Bool) == true || !children.isEmpty
    }

    /// dbusmenu marks the access key with `_` and escapes a literal one as
    /// `__`. Mac menus have no access keys, so the markers go.
    static func plainLabel(_ raw: String) -> String {
        var result = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            if character == "_" {
                if let next = iterator.next() {
                    if next == "_" { result.append("_") } else { result.append(next) }
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    func find(_ wanted: Int) -> X11GlobalMenuItem? {
        if id == wanted { return self }
        for child in children {
            if let found = child.find(wanted) { return found }
        }
        return nil
    }

    /// What the menu bar's top row is built from; the rest is filled in
    /// each time a menu opens.
    var topLevelSignature: [String] {
        children.filter { $0.visible && !$0.isSeparator }.map { "\($0.id):\($0.label)" }
    }
}

/// The host end of one guest menu bridge connection: newline-delimited JSON
/// both ways. Reads on the thread that calls `run`; writes on a queue of
/// its own, so a click never waits on the guest.
final class X11GlobalMenuConnection {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "msl.globalmenu.write")
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func run() {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                DispatchQueue.main.async { X11GlobalMenu.shared.receive(message, from: self) }
            }
            // A single line this long is not a menu; stop reading it.
            if buffer.count > 16 << 20 { break }
        }
        DispatchQueue.main.async { X11GlobalMenu.shared.connectionClosed(self) }
        writeQueue.async { [self] in
            closed = true
            close(fd)
        }
    }

    func send(_ message: [String: Any]) {
        writeQueue.async { [self] in
            guard !closed, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(UInt8(ascii: "\n"))
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, base + sent, raw.count - sent)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return }
                    sent += n
                }
            }
        }
    }
}

/// A submenu that knows which Linux menu item it stands for.
final class X11GlobalMenuNode: NSMenu {
    var itemID = 0
    var windowID: UInt32 = 0
}

private final class X11GlobalMenuItemRef: NSObject {
    let windowID: UInt32
    let itemID: Int
    init(windowID: UInt32, itemID: Int) {
        self.windowID = windowID
        self.itemID = itemID
    }
}

/// Puts the key Linux window's menus in the Mac menu bar, between the app
/// menu and Window (both from `X11DockIntegration`).
///
/// Only the top row is built up front. Each submenu is filled from the
/// latest tree as it opens (`menuNeedsUpdate`), and the bridge is told it
/// is opening, because Qt and GTK apps commonly populate a menu - recent
/// files, open windows - only when it is about to show. When the refreshed
/// tree comes back while the menu is still open, the open menu is refilled
/// in place.
///
/// Main thread only.
final class X11GlobalMenu: NSObject, NSMenuDelegate {
    static let shared = X11GlobalMenu()

    private struct Entry {
        let connection: X11GlobalMenuConnection
        var root: X11GlobalMenuItem
    }

    private var entries: [UInt32: Entry] = [:]
    private var shownWindow: UInt32?
    private var installedItems: [NSMenuItem] = []
    private var installedSignature: [String] = []
    private var openNodes: [X11GlobalMenuNode] = []
    private var needsReinstall = false
    private var observing = false

    func receive(_ message: [String: Any], from connection: X11GlobalMenuConnection) {
        startObservingKeyWindows()
        guard let kind = message["t"] as? String,
              let windowID = (message["window"] as? NSNumber)?.uint32Value else { return }
        switch kind {
        case "menu":
            guard let root = X11GlobalMenuItem(json: message["menu"]) else { return }
            entries[windowID] = Entry(connection: connection, root: root)
            if shownWindow == nil || shownWindow == windowID || keyWindowID == windowID {
                show(windowID)
            }
        case "remove":
            entries[windowID] = nil
            if shownWindow == windowID { show(entries.keys.first) }
        default:
            break
        }
    }

    func connectionClosed(_ connection: X11GlobalMenuConnection) {
        entries = entries.filter { $0.value.connection !== connection }
        if let shown = shownWindow, entries[shown] == nil { show(entries.keys.first) }
    }

    private var keyWindowID: UInt32? {
        (NSApplication.shared.keyWindow?.contentView as? X11CanvasView)?.windowID
    }

    private func startObservingKeyWindows() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// A window with no menus of its own - a dialog, a popup - keeps the
    /// menus that were showing, the way a Mac app's menu bar stays put.
    @objc private func keyWindowChanged(_ notification: Notification) {
        if let id = keyWindowID, entries[id] != nil, id != shownWindow {
            show(id)
        } else if needsReinstall {
            show(shownWindow)
        }
    }

    private func show(_ windowID: UInt32?) {
        shownWindow = windowID
        let signature = windowID.flatMap { entries[$0] }?.root.topLevelSignature ?? []
        if !openNodes.isEmpty {
            // Never rebuild the top row under an open menu; refill what is
            // open and catch the row up once it closes.
            for node in openNodes where node.windowID == windowID { populate(node) }
            if signature != installedSignature || installedItems.first.map({ ($0.submenu as? X11GlobalMenuNode)?.windowID != windowID }) == true {
                needsReinstall = true
            }
            return
        }
        install()
    }

    private func install() {
        guard let mainMenu = NSApplication.shared.mainMenu else {
            needsReinstall = true
            return
        }
        needsReinstall = false
        for item in installedItems where mainMenu.index(of: item) >= 0 {
            mainMenu.removeItem(item)
        }
        installedItems = []
        installedSignature = []
        guard let windowID = shownWindow, let entry = entries[windowID] else { return }

        var index = min(1, mainMenu.numberOfItems)
        if let windowsMenu = NSApplication.shared.windowsMenu,
           let windowItem = mainMenu.items.firstIndex(where: { $0.submenu === windowsMenu }) {
            index = windowItem
        }
        for top in entry.root.children where top.visible && !top.isSeparator {
            let item = NSMenuItem(title: top.label, action: nil, keyEquivalent: "")
            let node = X11GlobalMenuNode(title: top.label)
            node.itemID = top.id
            node.windowID = windowID
            node.delegate = self
            node.autoenablesItems = false
            item.submenu = node
            mainMenu.insertItem(item, at: index)
            index += 1
            installedItems.append(item)
        }
        installedSignature = entry.root.topLevelSignature
    }

    private func populate(_ node: X11GlobalMenuNode) {
        node.removeAllItems()
        guard let item = entries[node.windowID]?.root.find(node.itemID) else { return }
        for child in item.children where child.visible {
            if child.isSeparator {
                node.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: child.label, action: nil, keyEquivalent: "")
            menuItem.isEnabled = child.enabled
            if child.toggle != .none { menuItem.state = child.isOn ? .on : .off }
            if child.hasSubmenu {
                let sub = X11GlobalMenuNode(title: child.label)
                sub.itemID = child.id
                sub.windowID = node.windowID
                sub.delegate = self
                sub.autoenablesItems = false
                menuItem.submenu = sub
            } else {
                menuItem.action = #selector(activate(_:))
                menuItem.target = self
                menuItem.representedObject = X11GlobalMenuItemRef(windowID: node.windowID, itemID: child.id)
            }
            node.addItem(menuItem)
        }
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? X11GlobalMenuItemRef else { return }
        entries[ref.windowID]?.connection.send(["t": "activate", "window": ref.windowID, "id": ref.itemID])
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let node = menu as? X11GlobalMenuNode else { return }
        populate(node)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let node = menu as? X11GlobalMenuNode else { return }
        openNodes.append(node)
        entries[node.windowID]?.connection.send(["t": "opening", "window": node.windowID, "id": node.itemID])
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let node = menu as? X11GlobalMenuNode else { return }
        openNodes.removeAll { $0 === node }
        entries[node.windowID]?.connection.send(["t": "closed", "window": node.windowID, "id": node.itemID])
        if openNodes.isEmpty, needsReinstall {
            // After AppKit has finished closing the menu, not inside it.
            DispatchQueue.main.async { [self] in
                if openNodes.isEmpty, needsReinstall { install() }
            }
        }
    }
}
