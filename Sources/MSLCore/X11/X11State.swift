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
        lock.lock(); defer { lock.unlock() }
        connectionsByClientIndex[clientIndex] = WeakX11Connection(connection)
    }

    func unregisterConnection(clientIndex: UInt32) {
        lock.lock(); defer { lock.unlock() }
        connectionsByClientIndex.removeValue(forKey: clientIndex)
    }

    func connection(forClientIndex clientIndex: UInt32) -> X11Connection? {
        lock.lock(); defer { lock.unlock() }
        return connectionsByClientIndex[clientIndex]?.value
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
        var nsWindow: NSWindow?
        /// AppKit took key away from this window for a popup, but no
        /// `FocusOut` was sent (see `X11Connection.windowDidResignKey`), so
        /// in X11 terms it still has focus and must not get another `FocusIn`.
        var focusOutSuppressed = false
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
        var frame: CGRect
        var mapped = false
        /// Bitmask from `ChangeWindowAttributes`'/`CreateWindow`'s
        /// `event-mask` value - which events this window's owner actually
        /// asked for (`SelectInput`, in spec terms). Checked before
        /// forwarding a real mouse event so clients that never asked for
        /// pointer events don't get spammed with ones they'll ignore or
        /// choke on.
        var eventMask: UInt32 = 0
        /// 0x00RRGGBB from `CreateWindow`'s `background-pixel` value, if
        /// the client set one - used by `ClearArea` to know what to
        /// refill with (real X servers can also fill from a background
        /// *pixmap*; only a solid color is supported here).
        var backgroundPixel: UInt32 = 0x00FF_FFFF
        var properties: [UInt32: (type: UInt32, format: UInt8, data: [UInt8])] = [:]
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
        /// Stored for protocol correctness (`ShapeGetRectangles`/
        /// `ShapeQueryExtents` echo back whatever was last set) - not yet
        /// applied to actual rendering/hit-testing, see that handler's
        /// doc comment for the concrete follow-up that would close that
        /// gap.
        var boundingShapeRects: [CGRect]?

        init(id: UInt32, parent: UInt32, isTopLevel: Bool, frame: CGRect) {
            self.id = id
            self.parent = parent
            self.isTopLevel = isTopLevel
            self.frame = frame
        }
    }

    private var windows: [UInt32: WindowRecord] = [:]

    func makeWindow(id: UInt32, parent: UInt32, isTopLevel: Bool, frame: CGRect) -> WindowRecord {
        let record = WindowRecord(id: id, parent: parent, isTopLevel: isTopLevel, frame: frame)
        lock.lock()
        windows[id] = record
        lock.unlock()
        return record
    }

    func window(_ id: UInt32) -> WindowRecord? {
        lock.lock(); defer { lock.unlock() }
        return windows[id]
    }

    /// Direct children only (`MapSubwindows`/layout don't recurse into
    /// grandchildren - matches the real protocol's own semantics).
    func children(ofParent parent: UInt32) -> [WindowRecord] {
        lock.lock(); defer { lock.unlock() }
        return windows.values.filter { $0.parent == parent }
    }

    /// Whether any override-redirect window is currently mapped - i.e.
    /// whether a menu/popup is open right now. See
    /// `X11Connection.windowDidResignKey`'s use: a real X11 menu is
    /// override-redirect precisely SO THAT it never takes the input
    /// focus, so a key-window change caused by one must not be reported
    /// to the client as a focus change.
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
        return windows.removeValue(forKey: id)
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
        var clipRectangles: [CGRect]?
        /// `GCFont` - which font core text through this GC indexes into.
        var font: UInt32 = 0
        init(id: UInt32) { self.id = id }
    }

    private var gcs: [UInt32: GCRecord] = [:]

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
        /// Set via `SetPictureClipRectangles` (RENDER opcode 6) - the
        /// RENDER-extension equivalent of a core GC's `clipRectangles`
        /// (`X11Connection.handleSetClipRectangles`), applied when THIS
        /// picture is a `Composite`/`FillRectangles`/`Trapezoids`/
        /// `CompositeGlyphs8` request's DESTINATION (clip applies to
        /// where you're drawing TO, never the source/mask). `nil` means
        /// unclipped - same "empty list resets to unclipped" convention
        /// as the core GC version.
        var clipRectangles: [CGRect]?
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

    func setSelectionOwner(_ selection: UInt32, owner: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if owner == 0 { selectionOwners.removeValue(forKey: selection) } else { selectionOwners[selection] = owner }
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
