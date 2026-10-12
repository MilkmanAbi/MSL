import Foundation
import AppKit

/// Server-wide state shared by every connected client: windows, graphics
/// contexts, and the atom name<->id table. Resource IDs are scoped to a
/// `[clientIndex * 0x00200000, +0x001FFFFF]` range per connection (see
/// `X11Connection.resourceIdBase`), so two simultaneously-connected
/// clients' windows/GCs never collide in these flat, server-wide
/// dictionaries even though storage itself isn't partitioned per client -
/// the simplest correct approach for a skeleton expecting only a handful
/// of concurrent clients.
final class X11State {
    private let lock = NSLock()

    /// Copy and paste with the Mac, and through the Mac with other Linux
    /// apps. One per host process, like the rest of this state.
    let clipboard = X11Clipboard()

    init() {
        clipboard.attach(to: self)
    }

    private var nextClientIndexValue: UInt32 = 1

    /// Moves this server's client-index range so it cannot overlap another
    /// process's.
    ///
    /// A client index becomes the top 11 bits of every resource ID that
    /// client owns (`X11Connection.resourceIdBase`). That was unique by
    /// construction while one process served every app - it is not any
    /// more. Each per-app host (`X11AppHost`) is its own server with its own
    /// counter, so without this every host would hand out the SAME window
    /// IDs starting from the same base, and two different apps' windows
    /// would be indistinguishable by ID. Caught immediately: the snapshot
    /// harness names its files `<windowID>.png`, so four running apps
    /// collided onto each other's snapshots and seven Layer-0 tests failed
    /// comparing one program's window against another's reference.
    ///
    /// `stride` client indices per host - enough connections for any real
    /// app (Krita, the heaviest tested, opens five) and enough hosts to run
    /// far more apps at once than a screen can hold.
    static let clientIndexStride: UInt32 = 32

    /// The largest client index that still fits a resource ID.
    ///
    /// Every ID a connection mints carries its client index in the top 11
    /// bits (`id >> 21` recovers it, which is how `X11State` routes an ID
    /// back to the connection that owns it), so 2047 is the last index
    /// that survives the shift. Swift masks an over-wide shift instead of
    /// trapping, so exceeding this wraps silently onto another client's
    /// ID space - see `X11AppRouter.maxHostSlot`.
    static let maxClientIndex: UInt32 = 2047
    func seedClientIndex(hostSlot: UInt32) {
        lock.lock(); defer { lock.unlock() }
        nextClientIndexValue = hostSlot * Self.clientIndexStride + 1
    }

    func nextClientIndex() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let value = nextClientIndexValue
        nextClientIndexValue += 1
        return value
    }

    /// Confirmed live (2026-09-02, "multi-window support" pass): with no
    /// real window manager, two DIFFERENT client apps (or two instances
    /// of the same one - reproduced with two `galculator` processes)
    /// each requesting `CreateWindow` at X11 `(0,0)` - the conventional
    /// "no preference, let the WM decide" placeholder virtually every
    /// toolkit uses when it isn't deliberately positioning itself - both
    /// land at the EXACT same on-screen spot (confirmed via `System
    /// Events`: both windows reported position `(0,39)`, perfectly
    /// overlapping, the second entirely hidden behind the first even
    /// though both were rendering correctly server-side the whole time -
    /// this was never a rendering bug). `X11Connection.handleCreateWindow`
    /// calls this once per NEW top-level window landing at `(0,0)`, to
    /// apply a classic cascading-window-manager offset instead - real WMs
    /// (`mwm`, `twm`, and effectively every desktop environment's
    /// default placement policy) have done exactly this since the 1990s
    /// for precisely this reason.
    private var cascadeCount: Int = 0
    func nextCascadeOffset() -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        let step = cascadeCount % 12 // wrap before drifting off-screen on a small display
        cascadeCount += 1
        return CGPoint(x: Double(step) * 28, y: Double(step) * 28)
    }

    // MARK: - Connection registry

    /// Every other piece of shared state here (windows, GCs, atoms) is
    /// happily anonymous - a request only ever needs to read/mutate
    /// state, never reach back into WHICH connection owns it. Selections
    /// break that: `ConvertSelection` from one client has to deliver a
    /// `SelectionRequest` EVENT to a DIFFERENT client (whichever window
    /// currently owns that selection) - the first time anything here
    /// needs cross-connection event delivery, not just "reply to
    /// whoever's asking right now". `weak` so a connection that
    /// disconnects without explicitly unregistering (a crash, a dropped
    /// socket) doesn't keep it alive forever - `connection(forClientIndex:)`
    /// callers already treat a nil result as "nothing to deliver to",
    /// the same as a client that closed normally.
    private var connectionsByClientIndex: [UInt32: WeakX11Connection] = [:]

    func registerConnection(_ connection: X11Connection, clientIndex: UInt32) {
        lock.lock()
        connectionsByClientIndex[clientIndex] = WeakX11Connection(connection)
        let count = connectionsByClientIndex.count
        lock.unlock()
        // Outside the lock: starting the poll touches AppKit.
        clipboard.connectionCountChanged(to: count)
        // And keep this host out of App Nap while a Linux app is attached -
        // a napped host stops servicing the socket and the guest app freezes
        // with nothing on the Mac side to explain it. See `X11HostActivity`.
        X11HostActivity.connectionCountChanged(to: count)
    }

    func unregisterConnection(clientIndex: UInt32) {
        lock.lock()
        connectionsByClientIndex.removeValue(forKey: clientIndex)
        let count = connectionsByClientIndex.count
        lock.unlock()
        clipboard.connectionCountChanged(to: count)
        X11HostActivity.connectionCountChanged(to: count)
    }

    func connection(forClientIndex clientIndex: UInt32) -> X11Connection? {
        lock.lock(); defer { lock.unlock() }
        return connectionsByClientIndex[clientIndex]?.value
    }

    /// Every live connection. Snapshotted under the lock and handed back as
    /// an array, so a caller can deliver to all of them without holding the
    /// lock while it writes to sockets - a write can block, and blocking
    /// here would stall every other client.
    func allConnections() -> [X11Connection] {
        lock.lock(); defer { lock.unlock() }
        return connectionsByClientIndex.values.compactMap { $0.value }
    }

    /// A window ID's high 11 bits are exactly the owning connection's
    /// `clientIndex` (see `X11Connection.resourceIdBase`'s doc comment) -
    /// recovering it needs no extra per-window bookkeeping.
    func connection(forWindow windowID: UInt32) -> X11Connection? {
        connection(forClientIndex: windowID >> 21)
    }

    // MARK: - Windows

    final class WindowRecord {
        let id: UInt32
        /// The visual it was created with; 0 means the default visual.
        var visual: UInt32 = 0
        var nsWindow: NSWindow?
        /// AppKit took key away from this window for a popup, but no
        /// `FocusOut` was sent (see `X11Connection.windowDidResignKey`), so
        /// in X11 terms it still has focus and must not get another `FocusIn`.
        var focusOutSuppressed = false
        /// An override-redirect popup whose client grabbed the keyboard to
        /// it: only such a popup is made key (`X11Connection.keyboardGrabbed`).
        var wantsKeyboard = false
        var view: X11CanvasView?
        var parent: UInt32
        /// `true` when this window's parent is the root (a real, own
        /// `NSWindow`) - `false` for a child of another window this
        /// server created, which instead gets embedded as a plain
        /// `NSView` subview of its parent's own view (see `X11Connection.
        /// handleCreateWindow`'s doc comment on why this distinction is
        /// necessary at all, not just an optimization). Changes only in
        /// `X11Connection.handleReparentWindow`, when Tk moves its
        /// toplevel into a wrapper window it created on the root.
        var isTopLevel: Bool
        /// From `CreateWindow`'s `CWOverrideRedirect` value-mask bit -
        /// `true` means this window asked to bypass normal window-
        /// manager placement/decoration entirely (popup menus, tooltips,
        /// combo-box dropdowns - anything that needs to appear exactly
        /// where the client put it, borderless, without stealing key-
        /// window status the way a real application window should). See
        /// `X11Connection.handleCreateWindow`'s doc comment for why an
        /// EARLIER version of this server silently dropped this bit
        /// entirely, giving every top-level window (menus included) the
        /// same full titled/closable/resizable chrome a real app window
        /// gets - confirmed live this is what made GTK's own menu-bar
        /// popups (`gui-bugs.md` issue #5) never actually appear.
        var overrideRedirect: Bool = false
        /// `CreateWindow`'s class was `InputOnly` (2): a window with no
        /// pixels, which exists to catch input or hold properties and must
        /// never be shown. See `X11Connection.handleCreateWindow`.
        var inputOnly: Bool = false
        /// Border width as set by CreateWindow/ConfigureWindow. Not drawn
        /// (there are no X borders here), but reported back: a client that
        /// sets 3 and reads 0 lays itself out wrong.
        var borderWidth: UInt16 = 0
        var frame: CGRect
        var mapped = false
        /// Bitmask from `ChangeWindowAttributes`'/`CreateWindow`'s
        /// `event-mask` value - which events this window's owner actually
        /// asked for (`SelectInput`, in spec terms). Checked before
        /// forwarding a real mouse event so clients that never asked for
        /// pointer events don't get spammed with ones they'll ignore or
        /// choke on.
        var eventMask: UInt32 = 0
        /// Event masks of clients OTHER than the creator, by client index.
        /// X11 masks are per client: a pager watching another app's
        /// window, or a selection owner watching the requestor's window
        /// for INCR, selects without disturbing the creator's own mask.
        /// Selecting from a second client used to OVERWRITE `eventMask`.
        var otherClientMasks: [UInt32: UInt32] = [:]
        /// 0x00RRGGBB from `CreateWindow`'s `background-pixel` value, if
        /// the client set one - used by `ClearArea` to know what to
        /// refill with (real X servers can also fill from a background
        /// *pixmap*; only a solid color is supported here).
        var backgroundPixel: UInt32 = 0x00FF_FFFF
        /// `background-pixmap = None` (value 0).
        ///
        /// The protocol says a window with no background must have its
        /// contents **left alone** by `ClearArea` and by expose
        /// processing. This server painted `backgroundPixel` - white by
        /// default - unconditionally instead, so every `XClearArea` from
        /// such a client painted white over correct content and relied on
        /// an Expose to put it back: the "renders right for a second,
        /// then blanks" shape.
        ///
        /// Confirmed live rather than assumed (2026-09-23): 7 of 45
        /// windows in a GIMP + Mousepad session set it, all of them
        /// through `ChangeWindowAttributes` after creation, none at
        /// creation - which is why both attribute loops have to handle it.
        var backgroundNone = false
        /// `background-pixmap = ParentRelative` (value 1) - inherit the
        /// parent's pixels. Treated as "leave alone" rather than as an
        /// opaque fill, which is the closer of the two available answers.
        var backgroundParentRelative = false
        /// `bit-gravity`, default `Forget` (0).
        ///
        /// Forget means the contents become **undefined** when the window
        /// is resized and the server must expose the whole thing. This
        /// server instead preserved the old pixels at top-left forever, in
        /// a bitmap it never discards - which is the architectural reason
        /// stale content reappears here where a real X server would show
        /// background, and why clients told their contents are `Forget`
        /// never repaint it.
        var bitGravity: UInt8 = 0

        var properties: [UInt32: (type: UInt32, format: UInt8, data: [UInt8])] = [:]
        /// What `_NET_WM_STATE` reports for this window. The server's own
        /// view: set when it acts on a window-manager request.
        var isMinimised = false
        var isMaximised = false
        var isFullScreen = false
        /// The frame to go back to when this window is un-maximised.
        ///
        /// Saved by the server rather than left to `NSWindow.zoom(nil)`,
        /// which restores the frame IT saved and decides which way to go by
        /// comparing the current frame against the one AppKit would pick.
        /// Neither holds for a window whose size the client drives: a GTK
        /// app re-lays-out and resizes itself after being maximised, the
        /// frame stops matching AppKit's standard frame, and the next click
        /// on the maximise button zooms again instead of restoring - the
        /// window never returned to its original size (reported 2026-09-28).
        var frameBeforeMaximise: CGRect?
        /// Whether this window has been told the pointer is inside it -
        /// i.e. an Enter has been delivered with no matching Leave yet.
        ///
        /// Real X11 strictly alternates Enter/Leave per window; AppKit does
        /// not make that guarantee for us. `NSTrackingArea` re-fires
        /// `mouseEntered` whenever the areas are rebuilt (every
        /// `updateTrackingAreas`, so every geometry change) with the cursor
        /// already inside, and `synthesizeCrossingIfPointerAlreadyInside`
        /// can add one more at map time. Observed live 2026-09-06 against
        /// `gtk4-demo`: THREE consecutive `entered=true` on one window at
        /// identical coordinates with no Leave between them, all three
        /// forwarded and all three logged by GDK as `enter notify`.
        var pointerInside = false
        /// Decoded `_NET_WM_ICON` (see `X11WindowIcon`), kept on the record
        /// because a client routinely sets the property BEFORE mapping -
        /// the Dock integration then needs it again at map time.
        var iconImage: NSImage?
        /// `WM_CLASS`'s class string - the app's stable name, unlike the
        /// title, which follows the open document.
        var appName: String?
        /// The OUTER `NSWindow` frame this server itself last asked for
        /// via `setFrame` (`handleConfigureWindow`, responding to the
        /// client's own resize/move request), or `nil` if the last
        /// geometry change did not come from us.
        ///
        /// `windowDidMove`/`windowDidResize` use it to tell a server-
        /// initiated change's own delegate callback (an echo, nothing to
        /// report) from a genuine external one (a real user drag, or an
        /// Accessibility-driven move) that MUST be recorded.
        ///
        /// This replaced a pair of pending-callback COUNTERS. Counting is
        /// fragile: `setFrame` does not reliably fire one callback per
        /// increment (a no-op dimension fires none, and AppKit may merge
        /// or reorder them), so a count could be left standing and then
        /// swallow the next real change. That is not hypothetical - it
        /// was the "menus and dialogs go haywire" bug, see
        /// `X11Connection.windowDidMove`. Comparing against the frame we
        /// actually asked for is self-correcting: a stale value simply
        /// fails to match whatever comes next.
        ///
        /// Matched with a small tolerance rather than exactly, which is
        /// the other thing the counters were protecting against: AppKit
        /// can settle a point or two off the requested frame (screen-edge
        /// clamping, minimum sizes, point/pixel rounding through
        /// `cocoaScreenFrame(fromX11:)`), and reporting that back as a
        /// real change told the client a DIFFERENT size than it just
        /// asked for - which a layout-sensitive client answers with
        /// another resize. Confirmed live to compound into monotonic size
        /// drift (a window grew 331x343 -> 333x380 across two round
        /// trips), so near-misses stay suppressed while a genuine move of
        /// hundreds of points does not.
        var programmaticOuterFrame: CGRect?

        /// Whether `frame` is (near enough) the geometry this server just
        /// asked AppKit for - see `programmaticOuterFrame`. The tolerance
        /// absorbs AppKit settling a point or two off; a real external
        /// move is orders of magnitude larger.
        func matchesProgrammaticFrame(_ frame: CGRect, tolerance: CGFloat = 2) -> Bool {
            guard let target = programmaticOuterFrame else { return false }
            return abs(frame.origin.x - target.origin.x) <= tolerance
                && abs(frame.origin.y - target.origin.y) <= tolerance
                && abs(frame.width - target.width) <= tolerance
                && abs(frame.height - target.height) <= tolerance
        }

        /// Bitmask of `1 << XIEventType.*` values this window asked for
        /// via `XISelectEvents` (`X11Connection.handleXISelectEvents`) -
        /// the XI2 analogue of `eventMask` above. Unioned across every
        /// per-device `EVENTMASK` entry any single `XISelectEvents` call
        /// sent (this server doesn't distinguish devices - see
        /// `X11Connection.handleXInputRequest`'s doc comment for why one
        /// shared mask per window is enough for a two-master-device,
        /// no-real-hardware setup like this one).
        var xiEventMask: UInt32 = 0

        /// From `SHAPE`'s `ShapeRectangles`/`ShapeMask`/`ShapeCombine`
        /// (`X11Connection.handleShapeRequest`) - the window's own
        /// BOUNDING shape (window-relative rectangles the window is
        /// actually visible/paintable within), or `nil` for the default
        /// "the whole rectangular frame" shape a window starts with.
        /// Applied: the window's view is masked to it, and clicks outside
        /// it fall through to what is beneath (`X11CanvasView.shapeRects`).
        var boundingShapeRects: [CGRect]?
        /// SHAPE's INPUT region - where the pointer hits this window - or
        /// `nil` for "same as the bounding shape".
        var inputShapeRects: [CGRect]?

        init(id: UInt32, parent: UInt32, isTopLevel: Bool, frame: CGRect) {
            self.id = id
            self.parent = parent
            self.isTopLevel = isTopLevel
            self.frame = frame
        }
    }

    private var windows: [UInt32: WindowRecord] = [:]

    /// Sibling stacking order, bottom-to-top, per parent.
    ///
    /// Explicit, because the alternative was `windows.values.filter`, and
    /// `Dictionary` iteration order is unspecified **and seeded per
    /// process** - so sibling Z-order was randomised at every launch of
    /// the same application. `QueryTree` is defined to return this list in
    /// bottom-to-top stacking order and toolkits read it as such, so the
    /// nondeterminism reached clients directly as well as reaching the
    /// screen through `MapSubwindows`.
    private var childOrder: [UInt32: [UInt32]] = [:]

    func makeWindow(id: UInt32, parent: UInt32, isTopLevel: Bool, frame: CGRect) -> WindowRecord {
        let record = WindowRecord(id: id, parent: parent, isTopLevel: isTopLevel, frame: frame)
        lock.lock()
        windows[id] = record
        // A new window goes on top of its siblings, which is what the
        // protocol says and what `addSubview` did by accident.
        var order = childOrder[parent] ?? []
        order.removeAll { $0 == id }
        order.append(id)
        childOrder[parent] = order
        lock.unlock()
        return record
    }

    /// Moves `id` within its siblings. `sibling == nil` means "relative to
    /// all of them".
    ///
    /// Implements `ConfigureWindow`'s stack-mode, which used to be parsed
    /// only to keep the value list aligned and then dropped on the floor -
    /// making `XRaiseWindow` and `XLowerWindow` complete no-ops. Qt and
    /// GTK3 both raise child windows to bring a panel, sidebar or overlay
    /// to the front.
    func restack(_ id: UInt32, parent: UInt32, mode: StackMode, sibling: UInt32?) {
        lock.lock(); defer { lock.unlock() }
        var order = childOrder[parent] ?? []
        guard let current = order.firstIndex(of: id) else { return }
        order.remove(at: current)

        func place(above: Bool, of index: Int) {
            order.insert(id, at: above ? min(index + 1, order.count) : index)
        }

        switch mode {
        case .above:
            if let sibling, let index = order.firstIndex(of: sibling) { place(above: true, of: index) }
            else { order.append(id) } // top of the stack
        case .below:
            if let sibling, let index = order.firstIndex(of: sibling) { place(above: false, of: index) }
            else { order.insert(id, at: 0) } // bottom
        case .topIf:
            // Only if obscured by the sibling (or by anything, with none
            // given). Without real region tracking, "is there anything
            // above it" is the honest approximation.
            if let sibling, let index = order.firstIndex(of: sibling) { place(above: true, of: index) }
            else if current < order.count { order.append(id) }
            else { order.insert(id, at: current) }
        case .bottomIf:
            if let sibling, let index = order.firstIndex(of: sibling) { place(above: false, of: index) }
            else if current > 0 { order.insert(id, at: 0) }
            else { order.insert(id, at: current) }
        case .opposite:
            if current == order.count { order.insert(id, at: 0) } else { order.append(id) }
        }
        childOrder[parent] = order
    }

    /// `ConfigureWindow`'s stack-mode values, from the protocol.
    enum StackMode: UInt8 {
        case above = 0, below = 1, topIf = 2, bottomIf = 3, opposite = 4
    }

    func window(_ id: UInt32) -> WindowRecord? {
        lock.lock(); defer { lock.unlock() }
        return windows[id]
    }

    /// Direct children only (`MapSubwindows`/layout don't recurse into
    /// grandchildren - matches the real protocol's own semantics).
    func children(ofParent parent: UInt32) -> [WindowRecord] {
        lock.lock(); defer { lock.unlock() }
        // In stacking order, bottom first - not dictionary order. See
        // `childOrder`. The filter is a safety net for a record removed
        // without its order entry being cleaned up, not the source of
        // truth.
        return (childOrder[parent] ?? []).compactMap { windows[$0] }.filter { $0.parent == parent }
    }

    /// Whether any override-redirect window is currently mapped - i.e.
    /// whether a menu/popup is open right now. See
    /// `X11Connection.windowDidResignKey`'s use: a real X11 menu is
    /// override-redirect precisely SO THAT it never takes the input
    /// focus, so a key-window change caused by one must not be reported
    /// to the client as a focus change.
    /// Any mapped top-level window, for a faked key when AppKit reports no
    /// key window (a headless test, or focus sitting outside this host).
    /// Deterministic order, not `values.first` - see doc 14 Part D.
    func mappedTopLevelWindowID() -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        return windows.values
            .filter { $0.mapped && $0.isTopLevel }
            .map(\.id)
            .min()
    }

    var hasMappedOverrideRedirectWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return windows.values.contains { $0.overrideRedirect && $0.mapped }
    }

    /// The server-global X11 input focus (X11 has exactly ONE, which is
    /// why this lives on the shared `X11State` and not per-connection).
    /// `0` is `None`; a real window id otherwise. Previously not modelled
    /// at all - `SetInputFocus` was a no-op and `GetInputFocus` answered
    /// a hardcoded root window, which is what made Qt tear its own menus
    /// back down (see `X11Connection.handleGetInputFocus`).
    private var focusWindow: UInt32 = 0

    func setFocusWindow(_ id: UInt32) {
        lock.lock(); focusWindow = id; lock.unlock()
    }

    func currentFocusWindow() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return focusWindow
    }

    /// Every window a given client created, top-levels first so a caller
    /// tearing them down does not visit an already-removed child twice.
    ///
    /// A window ID's high 11 bits ARE the owning client's index - see
    /// `resourceIdBase` in `X11Connection` and `connection(forWindow:)`
    /// above - so ownership needs no extra bookkeeping to recover.
    /// Frees every non-window resource a disconnected client allocated.
    ///
    /// A real X server frees **all** of a client's resources when it goes
    /// away. mslgd freed only its windows, so every pixmap, GC, RENDER
    /// picture, glyph set, font, cursor and colormap it ever made stayed in
    /// this table for the life of the host process - and a host process
    /// outlives the app's windows by design (it is reused when the app is
    /// launched again), so the same app opened and closed repeatedly grew
    /// the server without bound. Glyph sets are the worst of them: a
    /// text-heavy app's cached glyph bitmaps are real pixel buffers.
    ///
    /// Safe to key on the client index because a resource ID's high 11 bits
    /// **are** the owning connection's index - the same fact
    /// `windowIDs(ownedByClientIndex:)` and `X11Connection.isOwnID` rely on.
    /// Windows are not touched here: they are torn down separately, because
    /// each one has an AppKit half that must be closed on the main thread.
    func releaseResources(ownedByClientIndex clientIndex: UInt32) {
        lock.lock(); defer { lock.unlock() }
        let owned = { (id: UInt32) in id >> 21 == clientIndex }
        pixmaps = pixmaps.filter { !owned($0.key) }
        gcs = gcs.filter { !owned($0.key) }
        pictures = pictures.filter { !owned($0.key) }
        glyphSets = glyphSets.filter { !owned($0.key) }
        symbolFonts = symbolFonts.filter { !owned($0) }
        // A flat key is kind<<32 | id, so the id is its low 32 bits.
        flatResources = flatResources.filter { !owned(UInt32(truncatingIfNeeded: $0)) }
    }

    func windowIDs(ownedByClientIndex clientIndex: UInt32) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return windows.values
            .filter { $0.id >> 21 == clientIndex }
            .sorted { ($0.isTopLevel ? 0 : 1) < ($1.isTopLevel ? 0 : 1) }
            .map(\.id)
    }

    @discardableResult
    func removeWindow(_ id: UInt32) -> WindowRecord? {
        lock.lock(); defer { lock.unlock() }
        let record = windows.removeValue(forKey: id)
        if let record { childOrder[record.parent]?.removeAll { $0 == id } }
        // "If the owner window is destroyed, the owner of the selection
        // automatically reverts to None" - otherwise a paste after the
        // owning app quit asks a dead window and waits forever.
        for (selection, owner) in selectionOwners where owner == id {
            selectionOwners.removeValue(forKey: selection)
            selectionTimes.removeValue(forKey: selection)
        }
        childOrder.removeValue(forKey: id) // its own children are gone with it
        return record
    }

    /// Moves `id` into `newParent`'s child list, on top, **and** updates
    /// the record's own `parent`.
    ///
    /// Both, because they are one fact. Leaving the record's field to the
    /// caller meant `children(ofParent:)` - which filters on it - could
    /// disagree with the order list in the window between the two writes,
    /// and a caller that forgot the second half produced a child that was
    /// in the new parent's order and invisible to its lookup.
    func reparent(_ id: UInt32, from oldParent: UInt32, to newParent: UInt32) {
        lock.lock(); defer { lock.unlock() }
        childOrder[oldParent]?.removeAll { $0 == id }
        var order = childOrder[newParent] ?? []
        order.removeAll { $0 == id }
        order.append(id)
        childOrder[newParent] = order
        windows[id]?.parent = newParent
    }

    func closeAllWindows() {
        lock.lock()
        let all = Array(windows.values)
        windows.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            for record in all { record.nsWindow?.close() }
        }
    }

    // MARK: - Pixmaps

    private var pixmaps: [UInt32: X11Pixmap] = [:]

    func makePixmap(id: UInt32, width: Int, height: Int, depth: UInt8 = 24) -> X11Pixmap {
        let pixmap = X11Pixmap(width: width, height: height, depth: depth)
        lock.lock()
        pixmaps[id] = pixmap
        lock.unlock()
        return pixmap
    }

    func pixmap(_ id: UInt32) -> X11Pixmap? {
        lock.lock(); defer { lock.unlock() }
        return pixmaps[id]
    }

    func removePixmap(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        pixmaps.removeValue(forKey: id)
    }

    /// The shared `X11Drawable` for either a window or a pixmap ID - most
    /// drawing requests accept either kind of `DRAWABLE` interchangeably
    /// per the protocol (see `X11Drawable`'s doc comment), so callers that
    /// don't care which one they got just want this.
    func drawable(_ id: UInt32) -> X11Drawable? {
        window(id)?.view ?? pixmap(id)
    }

    // MARK: - Graphics contexts

    final class GCRecord {
        let id: UInt32
        /// 0x00RRGGBB, matching the CARD32 pixel values `ChangeGC`
        /// carries - real X visuals can be palette-indexed, but this
        /// server only ever advertises one 24-bit TrueColor visual (see
        /// `X11ConnectionSetup`), so a GC's foreground/background pixel
        /// value IS already a packed RGB triple, no colormap lookup
        /// needed.
        var foreground: UInt32 = 0x0000_0000
        var background: UInt32 = 0x00FF_FFFF
        /// From `SetClipRectangles` (core opcode 59) - `nil` means "no
        /// clip, draw normally" (the common case; most GCs never get
        /// this set). See `X11Connection.handleCopyArea`'s doc comment
        /// for why NOT honoring this specifically for `CopyArea` was a
        /// real, confirmed bug: GDK's own offscreen-double-buffer flush
        /// uses `CopyArea` with a clipped GC to limit the copy to just
        /// the damaged sub-rectangles within its bounding box, not the
        /// whole box - ignoring the clip let stale offscreen-buffer
        /// pixels in the UN-damaged gaps overwrite correctly-rendered
        /// window content there, producing exactly the ghosting/overlap
        /// glitches seen after a resize.
        /// The clip rectangles **as the client sent them**, before the
        /// clip origin is applied.
        ///
        /// Stored unshifted so that a later `XSetClipOrigin` can move
        /// them. `SetClipRectangles` used to bake the origin in at set
        /// time, which is correct exactly once: a client that sets the
        /// rectangles once and then shifts them per-widget with
        /// `ChangeGC(clip-x-origin, clip-y-origin)` - an ordinary thing
        /// for a toolkit reusing one GC across widgets - got every
        /// subsequent draw clipped at the first widget's position.
        var clipRectanglesRaw: [CGRect]?
        /// `GCClipXOrigin`/`GCClipYOrigin`. Persists across a clip-mask
        /// reset, as in the protocol.
        var clipOrigin: CGPoint = .zero
        /// Where the clip actually lands: the rectangles, moved by the
        /// origin. Every drawing path reads this.
        var clipRectangles: [CGRect]? {
            get {
                guard let raw = clipRectanglesRaw else { return nil }
                guard clipOrigin != .zero else { return raw }
                return raw.map { $0.offsetBy(dx: clipOrigin.x, dy: clipOrigin.y) }
            }
            set { clipRectanglesRaw = newValue; clipOrigin = .zero }
        }
        /// `GCFont` - which font core text through this GC indexes into.
        var font: UInt32 = 0
        /// `GCFunction`. `GXcopy` (3) is the default and the only one this
        /// server drew for a long time; `GXxor` (6) is how Xt, Motif, Tk
        /// and xterm draw rubber bands, selection outlines and text
        /// carets - draw once to show, draw again to erase. Drawn as copy,
        /// the second draw paints the mark a second time instead of
        /// erasing it, which leaves artifacts by construction.
        var function: UInt8 = 3
        /// `GCFillStyle`: FillSolid 0, FillTiled 1, FillStippled 2,
        /// FillOpaqueStippled 3, with the pixmaps and origin they use.
        /// Dropped entirely until xhell's toolkit suite: every fill was
        /// solid, so Xaw's grey (stippled) insensitive widgets, Tk's
        /// stippled canvas items and Motif's tiled backgrounds came out as
        /// flat blocks of the foreground colour.
        var fillStyle: UInt8 = 0
        var tile: UInt32 = 0
        var stipple: UInt32 = 0
        var tsOrigin: CGPoint = .zero
        /// `GCGraphicsExposures`, default True: whether CopyArea/CopyPlane
        /// owe the client a NoExpose.
        var graphicsExposures = true
        init(id: UInt32) { self.id = id }
    }

    private var gcs: [UInt32: GCRecord] = [:]

    /// Scroll-valuator positions per slave pointer (valuator 2 = horizontal,
    /// 3 = vertical), shared by every client, as device state is on a real
    /// server. Absolute and ever-growing: clients take differences.
    private var scrollPositions: [UInt16: (h: Double, v: Double)] = [:]

    func scrollPosition(device: UInt16) -> (h: Double, v: Double) {
        lock.lock(); defer { lock.unlock() }
        return scrollPositions[device] ?? (0, 0)
    }

    @discardableResult
    func advanceScroll(device: UInt16, dx: Double, dy: Double) -> (h: Double, v: Double) {
        lock.lock(); defer { lock.unlock() }
        let current = scrollPositions[device] ?? (0, 0)
        let next = (h: current.h + dx, v: current.v + dy)
        scrollPositions[device] = next
        return next
    }

    /// Font ids opened with an Adobe Symbol XLFD name. Nothing else about
    /// fonts is tracked (every font shares `X11FakeFont`'s metrics); this
    /// only picks the byte-to-character mapping, see `X11CoreText`.
    private var symbolFonts: Set<UInt32> = []

    func setFont(_ id: UInt32, isSymbol: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isSymbol { symbolFonts.insert(id) } else { symbolFonts.remove(id) }
    }

    func isSymbolFont(_ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return symbolFonts.contains(id)
    }

    /// Ids for the resource kinds this server keeps no real object for -
    /// fonts, cursors, colormaps. Tracked only so `Close/Free*` of an id the
    /// client never created is the BadFont/BadCursor/BadColor a real server
    /// sends, instead of a silent no-op (found by the xhell suite). Keyed by
    /// a kind tag so the three namespaces do not collide.
    private var flatResources: Set<UInt64> = []

    private func flatKey(_ kind: UInt8, _ id: UInt32) -> UInt64 { UInt64(kind) << 32 | UInt64(id) }

    func addFlatResource(_ kind: UInt8, _ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        flatResources.insert(flatKey(kind, id))
    }

    /// Removes the id; returns whether it existed (false -> the caller sends
    /// the matching Bad* error).
    @discardableResult
    func removeFlatResource(_ kind: UInt8, _ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flatResources.remove(flatKey(kind, id)) != nil
    }

    func hasFlatResource(_ kind: UInt8, _ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flatResources.contains(flatKey(kind, id))
    }

    func makeGC(id: UInt32) -> GCRecord {
        let record = GCRecord(id: id)
        lock.lock()
        gcs[id] = record
        lock.unlock()
        return record
    }

    func gc(_ id: UInt32) -> GCRecord? {
        lock.lock(); defer { lock.unlock() }
        return gcs[id]
    }

    func removeGC(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        gcs.removeValue(forKey: id)
    }

    // MARK: - RENDER pictures

    /// A RENDER `Picture` is a thin wrapper around something already
    /// drawable-shaped (a window/pixmap `X11Drawable`, via `CreatePicture`)
    /// OR, distinctly, a constant color with no backing pixels at all
    /// (`CreateSolidFill`) OR a linear gradient (`CreateLinearGradient` -
    /// see `X11Connection.handleRenderCreateLinearGradient`'s doc comment)
    /// - real X servers store all of these under the same `PICTURE` XID
    /// namespace, and `RenderComposite`'s `src`/`mask` arguments accept
    /// any of them interchangeably, so this mirrors that rather than
    /// giving each its own resource type.
    final class PictureRecord {
        let id: UInt32
        var drawableID: UInt32?
        var solidColor: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)?
        var linearGradient: (p1: CGPoint, p2: CGPoint, stops: [CGFloat], colors: [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)])?
        /// `CreateRadialGradient` (RENDER minor 35).
        ///
        /// Unimplemented, the picture was never created at all - so the
        /// later `Composite` found no source picture and returned early,
        /// **drawing nothing** and leaving whatever was underneath. Adwaita
        /// and several Qt styles use radial gradients, so that read as
        /// stale content rather than as a missing gradient.
        var radialGradient: (c1: CGPoint, r1: CGFloat, c2: CGPoint, r2: CGFloat,
                             stops: [CGFloat], colors: [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)])?
        /// Set via `SetPictureClipRectangles` (RENDER opcode 6) - the
        /// RENDER-extension equivalent of a core GC's `clipRectangles`
        /// (`X11Connection.handleSetClipRectangles`), applied when THIS
        /// picture is a `Composite`/`FillRectangles`/`Trapezoids`/
        /// `CompositeGlyphs8` request's DESTINATION (clip applies to
        /// where you're drawing TO, never the source/mask). `nil` means
        /// unclipped - same "empty list resets to unclipped" convention
        /// as the core GC version.
        /// The clip rectangles as the client sent them, before the clip
        /// origin - same reasoning as `GCRecord.clipRectanglesRaw`.
        var clipRectanglesRaw: [CGRect]?
        /// `CPClipXOrigin`/`CPClipYOrigin`, which were read and discarded.
        var clipOrigin: CGPoint = .zero
        var clipRectangles: [CGRect]? {
            get {
                guard let raw = clipRectanglesRaw else { return nil }
                guard clipOrigin != .zero else { return raw }
                return raw.map { $0.offsetBy(dx: clipOrigin.x, dy: clipOrigin.y) }
            }
            set { clipRectanglesRaw = newValue; clipOrigin = .zero }
        }
        /// `CPComponentAlpha`.
        ///
        /// This is how cairo and Pango ask for **subpixel (LCD)
        /// antialiased text**: the mask carries per-channel coverage
        /// rather than a single alpha, so each of R, G and B is masked by
        /// its own value. Treated as ordinary alpha - which is what
        /// dropping the bit meant - that text renders with the wrong
        /// weight and colour fringing, and `07-MSLGD-BUGS.md` already
        /// logs unexplained "text-antialiasing drift".
        var componentAlpha = false
        /// Set via `ChangePicture` (RENDER opcode 5, `CPRepeat` value bit
        /// `0x1`) - confirmed live this is how cairo's xlib-render backend
        /// actually sets repeat mode on a small reusable mask/pattern
        /// picture (e.g. a single rounded-corner alpha-coverage stamp), NOT
        /// via `CreatePicture`'s own value-mask (real toolkits create the
        /// Picture first with defaults, then `ChangePicture` it - see
        /// `X11Connection.handleRenderChangePicture`'s doc comment for the
        /// live trace that found this). `true` (RepeatNormal - the only
        /// mode real clients were ever observed setting) means an
        /// image-sourced `Composite`/`Trapezoids` should tile the source
        /// image (wrap `srcX`/`srcY` modulo its pixel dimensions) instead
        /// of treating an out-of-bounds sample as "nothing to draw."
        var repeatNormal = false
        /// `SetPictureTransform` (RENDER 28): maps destination-relative
        /// points to source points, `nil` for identity. cairo sets it to
        /// scale or rotate an image (Audacity's welcome banner, GTK's
        /// spinner icon); ignoring it drew those unscaled from the wrong
        /// origin. See `renderPictureTransform`.
        var transform: CGAffineTransform?
        /// `SetPictureFilter` (RENDER 30). RENDER's default is nearest;
        /// cairo asks for "good"/"bilinear" when it scales.
        var filterNearest = true
        init(id: UInt32) { self.id = id }
    }

    private var pictures: [UInt32: PictureRecord] = [:]

    func makePicture(id: UInt32) -> PictureRecord {
        let record = PictureRecord(id: id)
        lock.lock(); pictures[id] = record; lock.unlock()
        return record
    }

    func picture(_ id: UInt32) -> PictureRecord? {
        lock.lock(); defer { lock.unlock() }
        return pictures[id]
    }

    func removePicture(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        pictures.removeValue(forKey: id)
    }

    // MARK: - RENDER glyph sets

    /// One glyph, exactly as `AddGlyphs` uploaded it - `xOff`/`yOff` (the
    /// advance to the NEXT glyph's origin) and `x`/`y` (this glyph's own
    /// origin offset from the pen position, i.e. its left/top bearing)
    /// are what `handleRenderCompositeGlyphs8` walks a glyph run with;
    /// `imageData` is the raw per-pixel coverage/color bytes, `width`/
    /// `height` sized exactly like a `PutImage` upload would be for the
    /// glyphset's own `format`.
    struct GlyphRecord {
        let width: Int
        let height: Int
        let x: Int
        let y: Int
        let xOff: Int
        let yOff: Int
        let imageData: [UInt8]
    }

    /// A `GLYPHSET` - `CreateGlyphSet`'s `format` (an A8 coverage mask for
    /// ordinary anti-aliased text, ARGB32 for color glyphs/emoji - see
    /// `X11Connection`'s `renderFormatA8`/`renderFormatARGB32`) fixes
    /// every glyph `AddGlyphs` later uploads into this set to the same
    /// per-pixel byte width, needed to parse each upload's raw image
    /// bytes correctly.
    final class GlyphSetRecord {
        let id: UInt32
        let format: UInt32
        var glyphs: [UInt32: GlyphRecord] = [:]
        init(id: UInt32, format: UInt32) {
            self.id = id
            self.format = format
        }
    }

    private var glyphSets: [UInt32: GlyphSetRecord] = [:]

    /// Registers a second id for a glyph set that already exists
    /// (`ReferenceGlyphSet`). Both ids name the **same** record, so glyphs
    /// added through one are visible through the other - which is the whole
    /// point, and why this stores the record rather than a copy of it.
    func addGlyphSetAlias(_ id: UInt32, of existing: GlyphSetRecord) {
        lock.lock(); glyphSets[id] = existing; lock.unlock()
    }

    func makeGlyphSet(id: UInt32, format: UInt32) -> GlyphSetRecord {
        let record = GlyphSetRecord(id: id, format: format)
        lock.lock(); glyphSets[id] = record; lock.unlock()
        return record
    }

    func glyphSet(_ id: UInt32) -> GlyphSetRecord? {
        lock.lock(); defer { lock.unlock() }
        return glyphSets[id]
    }

    func removeGlyphSet(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        glyphSets.removeValue(forKey: id)
    }

    // MARK: - Atoms

    /// X11's predefined atoms (core protocol Appendix B / `Xatom.h`),
    /// index 0 == atom 1. These are COMPILE-TIME CONSTANTS in Xlib
    /// (`XA_WM_NAME` is literally `39`), so a client never interns them -
    /// it just puts the number straight on the wire.
    ///
    /// This table used to be omitted deliberately, on the reasoning that
    /// minting fresh IDs above the predefined range was equivalent. It is
    /// not, and the cost was silent: any server-side code that looked up
    /// a well-known property by `internAtom("...")` got a fresh atom in
    /// the 1000s and then compared it against the 39/40/67 a real client
    /// actually sent, so the comparison could never match.
    ///
    /// Confirmed live 2026-09-06: `applyWMNormalHints` - added as "the
    /// missing piece" for window sizing policy - had NEVER ONCE RUN. Its
    /// trace line appears zero times in a 34 MB trace of GTK3, GTK4 and Qt
    /// apps all setting `WM_NORMAL_HINTS` (atom 40) normally, because it
    /// was gated on `internAtom("WM_NORMAL_HINTS")` == some value >= 1000.
    /// Same for window titles (`WM_NAME`, 39). The giveaway was already in
    /// the trace, unread: `getProperty ... property=23 name=?` - a client
    /// asking for `RESOURCE_MANAGER` by its real predefined number, which
    /// this server could not even name.
    static let predefinedAtomNames = [
        "PRIMARY", "SECONDARY", "ARC", "ATOM", "BITMAP", "CARDINAL", "COLORMAP",
        "CURSOR", "CUT_BUFFER0", "CUT_BUFFER1", "CUT_BUFFER2", "CUT_BUFFER3",
        "CUT_BUFFER4", "CUT_BUFFER5", "CUT_BUFFER6", "CUT_BUFFER7", "DRAWABLE",
        "FONT", "INTEGER", "PIXMAP", "POINT", "RECTANGLE", "RESOURCE_MANAGER",
        "RGB_COLOR_MAP", "RGB_BEST_MAP", "RGB_BLUE_MAP", "RGB_DEFAULT_MAP",
        "RGB_GRAY_MAP", "RGB_GREEN_MAP", "RGB_RED_MAP", "STRING", "VISUALID",
        "WINDOW", "WM_COMMAND", "WM_HINTS", "WM_CLIENT_MACHINE", "WM_ICON_NAME",
        "WM_ICON_SIZE", "WM_NAME", "WM_NORMAL_HINTS", "WM_SIZE_HINTS",
        "WM_ZOOM_HINTS", "MIN_SPACE", "NORM_SPACE", "MAX_SPACE", "END_SPACE",
        "SUPERSCRIPT_X", "SUPERSCRIPT_Y", "SUBSCRIPT_X", "SUBSCRIPT_Y",
        "UNDERLINE_POSITION", "UNDERLINE_THICKNESS", "STRIKEOUT_ASCENT",
        "STRIKEOUT_DESCENT", "ITALIC_ANGLE", "X_HEIGHT", "QUAD_WIDTH", "WEIGHT",
        "POINT_SIZE", "RESOLUTION", "COPYRIGHT", "NOTICE", "FONT_NAME",
        "FAMILY_NAME", "FULL_NAME", "CAP_HEIGHT", "WM_CLASS", "WM_TRANSIENT_FOR",
    ]

    private var atomsByName: [String: UInt32] = {
        var out: [String: UInt32] = [:]
        for (index, name) in X11State.predefinedAtomNames.enumerated() { out[name] = UInt32(index + 1) }
        return out
    }()
    private var namesByAtom: [UInt32: String] = {
        var out: [UInt32: String] = [:]
        for (index, name) in X11State.predefinedAtomNames.enumerated() { out[UInt32(index + 1)] = name }
        return out
    }()
    /// Dynamically interned atoms start well clear of the predefined
    /// range seeded above.
    private var nextAtomValue: UInt32 = 1000

    /// Interns `name`, creating a new atom only if `onlyIfExists` is
    /// false and none exists yet - matches `InternAtom`'s own
    /// `only-if-exists` argument.
    func internAtom(_ name: String, onlyIfExists: Bool) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        if let existing = atomsByName[name] { return existing }
        guard !onlyIfExists else { return 0 } // 0 = None
        let value = nextAtomValue
        nextAtomValue += 1
        atomsByName[name] = value
        namesByAtom[value] = name
        return value
    }

    func atomName(_ atom: UInt32) -> String? {
        lock.lock(); defer { lock.unlock() }
        return namesByAtom[atom]
    }

    // MARK: - Selections

    /// `PRIMARY`/`CLIPBOARD` ownership (`SetSelectionOwner`/
    /// `GetSelectionOwner`) - real X11 copy/paste, including `xterm`'s
    /// own mouse-drag-to-select-then-middle-click-to-paste, runs entirely
    /// through this: no clipboard DATA is ever stored here, just which
    /// WINDOW currently claims a given selection atom - `ConvertSelection`
    /// asks that window (via a `SelectionRequest` event, cross-connection
    /// delivery - see `connection(forWindow:)`) to actually produce the
    /// data, on demand, every time.
    private var selectionOwners: [UInt32: UInt32] = [:] // selection atom -> owner window

    /// Takes a selection, recording **when**.
    ///
    /// The time is not bookkeeping - ICCCM defines `TIMESTAMP` as "the
    /// timestamp used to acquire the selection", and a client that caches
    /// selection contents keyed by it cannot tell whether the selection
    /// changed between two reads if the answer moves every time it asks.
    /// Nothing stored it at all before 2026-09-22, so `TIMESTAMP` was
    /// answered with `now` and the function's own doc comment was a lie.
    ///
    /// Returns false when the claim is refused: the protocol says to
    /// ignore a `SetSelectionOwner` whose time is earlier than the
    /// selection's current last-change time, which is what stops a
    /// late-arriving stale claim from beating a newer one.
    @discardableResult
    func setSelectionOwner(_ selection: UInt32, owner: UInt32, time: UInt32 = 0) -> Bool {
        claimSelection(selection, owner: owner, time: time) != nil
    }

    /// Sets the owner; returns the PREVIOUS owner (0 for none), or nil when
    /// the claim was older than the current one and was ignored.
    func claimSelection(_ selection: UInt32, owner: UInt32, time: UInt32 = 0) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        let previous = selectionOwners[selection] ?? 0
        // CurrentTime (0) means "now" and always wins, as it does in xorg.
        if time != 0, let previousTime = selectionTimes[selection], time < previousTime { return nil }
        if owner == 0 {
            selectionOwners.removeValue(forKey: selection)
            selectionTimes.removeValue(forKey: selection)
        } else {
            selectionOwners[selection] = owner
            selectionTimes[selection] = time
        }
        return previous
    }

    /// When the current owner took it, for `TIMESTAMP`.
    func selectionTime(_ selection: UInt32) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return selectionTimes[selection] ?? 0
    }

    private var selectionTimes: [UInt32: UInt32] = [:]

    /// Every selection this window currently owns. Asked **before**
    /// `removeWindow`, which drops them silently - XFIXES watchers need to
    /// be told which ones went away.
    func selectionsOwned(by window: UInt32) -> [(selection: UInt32, time: UInt32)] {
        lock.lock(); defer { lock.unlock() }
        return selectionOwners.compactMap { selection, owner in
            owner == window ? (selection, selectionTimes[selection] ?? 0) : nil
        }
    }

    func selectionOwner(_ selection: UInt32) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return selectionOwners[selection] ?? 0
    }
}

/// `NSMapTable`/`Unmanaged` would also work here, but a plain wrapper
/// struct capturing a `weak` reference is simpler and just as safe for
/// this one narrow use (see `X11State.connectionsByClientIndex`).
private struct WeakX11Connection {
    weak var value: X11Connection?
    init(_ value: X11Connection) { self.value = value }
}
