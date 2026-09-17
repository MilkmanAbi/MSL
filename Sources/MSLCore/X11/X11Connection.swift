import Foundation
import AppKit
#if canImport(Darwin)
import Darwin
#endif

/// One X11 client's connection: performs the connection-setup handshake,
/// then reads/dispatches requests until the client disconnects. Runs
/// entirely on its own background `Thread` (handed the raw fd by
/// `X11Server`'s listener delegate) - `AppKit` calls within request
/// handlers are dispatched to the main thread (`NSWindow`/`NSView` are
/// main-thread-only), everything else (wire parsing, state lookups) stays
/// right here.
///
/// Only the request subset actually implemented (see the `switch` in
/// `dispatch`) gets a real reply; anything else gets a spec-compliant
/// `BadImplementation` error instead of silence - clients are required by
/// the X11 protocol to tolerate an error for *any* request (including
/// ones that don't normally reply), so this is always a safe response for
/// something unimplemented, never a way to accidentally hang a client
/// waiting forever for a reply that will never come.
final class X11Connection: NSObject {
    private let fd: Int32
    private let clientIndex: UInt32
    private let state: X11State

    private var littleEndian = true
    private var sequenceNumber: UInt16 = 0
    /// A real X11 `TIMESTAMP` (milliseconds, server-defined reference
    /// point - doesn't need to be wall-clock-accurate, just monotonic
    /// and reflective of REAL elapsed time between events) - `.systemUptime`
    /// rather than wall-clock time, so it isn't affected by NTP/clock
    /// adjustments. Confirmed live via real interactive testing: every
    /// event this server sent used a hardcoded `time=0`, and repeated
    /// clicks/keypresses on the same target became unreliable ("click,
    /// see the press, then it eventually catches up") - GTK's own
    /// double-click detection measures the DELTA between successive
    /// events' timestamps, and two genuinely-separate clicks both
    /// claiming `time=0` look identical to a delta of zero, which is
    /// exactly what a double-click's second click looks like - very
    /// plausibly confusing GTK's click-tracking state machine into
    /// treating ordinary rapid single clicks as (or waiting to
    /// disambiguate from) a double-click gesture. `UInt32` wraps after
    /// ~49 days of uptime, which is fine - X11 timestamps are DEFINED to
    /// wrap and clients are required to handle it.
    private var currentX11Timestamp: UInt32 { UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000)) }
    private var resourceIdBase: UInt32 = 0
    private var resourceIdMask: UInt32 = 0
    private var rootWindowID: UInt32 = 0
    private var colormapID: UInt32 = 0
    /// This client's `XkbPerClientFlags`. DetectableAutoRepeat is the one
    /// that changes what gets sent - see `keyEvent`.
    private var xkbClientFlags: UInt32 = 0
    /// Mac keys whose keyDown the shortcut remapper replaced, so their keyUp
    /// is swallowed rather than delivered unpaired. Main thread only.
    private var remappedMacKeys: Set<UInt16> = []
    /// Observes keyboard layout switches, so the client hears about them.
    private var keymapObserver: NSObjectProtocol?
    /// Buttons currently held down, this connection's one pointer - feeds
    /// `mouseButton`'s `state` field (see its doc comment). Not per-window:
    /// X11's pointer is a single per-connection resource.
    private var pressedButtons: Set<UInt8> = []
    /// Most recently mapped ORDINARY (not override-redirect) top-level on
    /// this connection - the fallback "window this menu spawned from" when
    /// a popup sets no `WM_TRANSIENT_FOR` and nothing holds the input
    /// focus yet. See `attachToOwnerWindow`.
    private var lastOrdinaryTopLevelID: UInt32?
    /// Which XKB events this client selected (`XkbSelectEvents`) - not
    /// per window like `WindowRecord.eventMask`, since XKB selections are
    /// made against the keyboard, not a window. GDK and Qt both select
    /// state, map and new-keyboard notifications at startup.
    private var xkbSelection = X11XkbEventSelection()
    private var visualID: UInt32 = 0x0000_0021
    /// A second, depth-32 TrueColor visual with no real behavioral
    /// difference from `visualID` at the core-protocol level (this
    /// server's drawables are all premultiplied RGBA already regardless
    /// of which visual created them - see `X11Drawable`'s doc comment).
    /// Exists purely so RENDER's `QueryPictFormats` can offer a visual
    /// that actually maps to `renderFormatARGB32` - confirmed live this
    /// isn't cosmetic: GDK/cairo check for an ARGB-capable *visual*
    /// (not just an ARGB *PictFormat* reachable only via pixmaps) before
    /// deciding RENDER is usable for real window compositing at all: with
    /// no depth-32 visual offered, GDK silently gave up on RENDER
    /// entirely - present per `QueryExtension`, but never actually used
    /// for a single `CreatePicture`/`Composite` call - and every widget's
    /// queued draw just... never got flushed. Real X servers (Xvfb
    /// confirmed via a wire-level proxy comparison) always pair a 32-bit
    /// ARGB visual with RENDER for exactly this reason.
    private var argbVisualID: UInt32 = 0x0000_0022

    /// Serializes every write to `fd` - both the request-handling loop's
    /// own replies AND event bytes sent asynchronously from AppKit's main
    /// thread (a real mouse click) can originate from different threads;
    /// without this, two concurrent `write()` calls on the same socket
    /// could interleave mid-message and desync the client irrecoverably.
    private let writeLock = NSLock()
    /// Bytes the socket would not take yet, in order, drained by
    /// `drainWriteBacklog`. Guarded by `writeLock` - see `writeFull`.
    private var writeBacklog: [UInt8] = []
    private var writeBacklogDraining = false
    /// Set once the socket is gone (write error, disconnect, backlog limit).
    private var writeClosed = false
    /// Past this the guest has stopped reading for good; the connection is
    /// dropped rather than growing without bound.
    private static let writeBacklogLimit = 64 << 20

    /// Bytes already read off `fd` by someone else, to be consumed before
    /// any further `read()`.
    ///
    /// The per-app host process (`X11AppHost`) exists because macOS gives
    /// one Dock tile per PROCESS, so each Linux app needs its own. `mslhd`
    /// accepts the vsock connection, reads far enough into the stream to
    /// learn the app's `WM_CLASS` name (`X11AppSniffer`), and only then
    /// knows which host to hand the connection to - by which point those
    /// bytes are off the socket and must be replayed here, or the client's
    /// connection setup and first requests are simply lost.
    private var pendingPrefix: [UInt8]

    /// Which VM this connection serves, for the sandbox input gate.
    /// Optional: an `mslgui` shim from an older build is started without it.
    let instance: String?

    init(fd: Int32, clientIndex: UInt32, state: X11State, prefix: [UInt8] = [], instance: String? = nil) {
        self.instance = instance
        self.fd = fd
        self.clientIndex = clientIndex
        self.state = state
        self.pendingPrefix = prefix
        super.init()
    }

    func run() {
        defer { cleanupOnDisconnect() }
        // Non-blocking, so `writeFull` can never park the main thread in a
        // full socket buffer. `MSG_DONTWAIT` is not enough: XNU's socket send
        // ignores it and only honours the socket's own non-blocking state.
        // `readFull` waits in `poll` instead.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        guard performHandshake() else { return }
        state.registerConnection(self, clientIndex: clientIndex) // see X11State's doc comment - needed for cross-connection selection events
        DispatchQueue.main.async {
            X11KeymapProvider.shared.startObserving()
            X11KeyboardRouter.installIfNeeded()
        }
        keymapObserver = NotificationCenter.default.addObserver(
            forName: X11KeymapProvider.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.keymapDidChange() }

        while true {
            guard let header = readFull(4) else { break }
            let opcode = header[0]
            let detail = header[1]
            let shortLength = littleEndian
                ? (UInt16(header[3]) << 8 | UInt16(header[2]))
                : (UInt16(header[2]) << 8 | UInt16(header[3]))
            // BIG-REQUESTS wire extension (see `handleBigReqEnable`'s doc
            // comment): a standard length of exactly 0 is otherwise never
            // valid (every request is at least its own 4-byte header, one
            // unit) - real clients repurpose it to mean "the real length
            // doesn't fit in 16 bits, read 4 more bytes for it." Handling
            // this unconditionally (not gated on whether this connection
            // ever sent `BigReqEnable`) is safe for the same reason and
            // avoids tracking an extra per-connection flag for it.
            var length = UInt32(shortLength)
            if shortLength == 0 {
                guard let extended = readFull(4) else { break }
                length = littleEndian
                    ? (UInt32(extended[3]) << 24 | UInt32(extended[2]) << 16 | UInt32(extended[1]) << 8 | UInt32(extended[0]))
                    : (UInt32(extended[0]) << 24 | UInt32(extended[1]) << 16 | UInt32(extended[2]) << 8 | UInt32(extended[3]))
            }
            guard length >= 1 else { break } // every request is at least one 4-byte unit (its own header)
            let bodyByteCount = Int(length) * 4 - 4 - (shortLength == 0 ? 4 : 0)
            var body: [UInt8] = []
            if bodyByteCount > 0 {
                guard let read = readFull(bodyByteCount) else { break }
                body = read
            }
            sequenceNumber = sequenceNumber &+ 1
            dispatch(opcode: opcode, detail: detail, body: body)
        }
    }

    private func cleanupOnDisconnect() {
        // Stop writers first: the backlog drain must never send on a
        // descriptor number that `close` has freed for reuse.
        writeLock.lock()
        writeClosed = true
        writeBacklog.removeAll()
        writeLock.unlock()
        close(fd)
        state.unregisterConnection(clientIndex: clientIndex)
        if let keymapObserver { NotificationCenter.default.removeObserver(keymapObserver) }
        DispatchQueue.main.async { X11PointerMonitor.shared.unsubscribe(self) }
        // Destroy this client's windows, exactly as a real server frees a
        // disconnected client's resources.
        //
        // This used to deliberately leave them on screen, on the reasoning
        // that "a closed app's window sticking around a moment longer is
        // harmless". It was, until the windows started backing a Dock tile
        // and Mission Control tiles: a ghost window from an app that exited
        // ten minutes ago keeps the process `.regular`, keeps a tile in the
        // Dock, keeps a row in the Dock menu, and shows up as its own
        // Mission Control tile - none of which any amount of polish
        // elsewhere can make feel native. Confirmed live: eight windows on
        // screen from four apps, four of them fixtures whose guest
        // processes had exited long before.
        //
        // Ownership is recoverable with no extra bookkeeping - a window
        // ID's high 11 bits are the owning client's index (see
        // `resourceIdBase`).
        for windowID in state.windowIDs(ownedByClientIndex: clientIndex) {
            destroyWindowRecursive(windowID)
        }
    }

    // MARK: - Connection setup

    private func performHandshake() -> Bool {
        guard let first = readFull(1) else { return false }
        switch first[0] {
        case 0x42: littleEndian = false // 'B' - MSB first
        case 0x6C: littleEndian = true  // 'l' - LSB first
        default: return false
        }
        guard let rest = readFull(11) else { return false } // unused(1)+major(2)+minor(2)+name-len(2)+data-len(2)+unused(2)
        let r = X11ByteReader(rest, littleEndian: littleEndian)
        _ = r.readU8()
        let major = r.readU16()
        _ = r.readU16()
        let nameLen = Int(r.readU16())
        let dataLen = Int(r.readU16())
        _ = r.readU16()

        let namePadded = X11Wire.pad(nameLen)
        let dataPadded = X11Wire.pad(dataLen)
        if namePadded > 0, readFull(namePadded) == nil { return false }
        if dataPadded > 0, readFull(dataPadded) == nil { return false }

        guard major == 11 else {
            sendSetupFailure(reason: "this server only speaks X11 protocol major version 11")
            return false
        }

        resourceIdBase = clientIndex << 21 // a fresh, non-overlapping 0x00200000-wide ID range per connection
        resourceIdMask = 0x001F_FFFF
        // Confirmed live (GDK: "XID collision, trouble ahead", then a
        // spurious DestroyWindow on the client's own just-created main
        // window moments later) that placing these at the BOTTOM of the
        // client's allocatable range - `resourceIdBase | 0x01/0x02` - was
        // a real bug, not just cosmetic: real clients (Xlib/GDK) allocate
        // their OWN resource IDs sequentially from `resource-id-base`
        // upward with no knowledge that specific low offsets are already
        // taken - a client's own 2nd or 3rd self-allocated resource (a
        // cursor, in the trace that caught this) can land exactly on
        // whatever offset a server reserves this way. Real X servers keep
        // the root window/default colormap in an ID space no client's
        // resource-id-base range ever reaches at all; parking these at
        // the very TOP of this range instead - not the bottom - gets the
        // same effect without restructuring the per-connection ID scheme:
        // a client would need to sequentially self-allocate over two
        // million resources before ever reaching up here.
        rootWindowID = resourceIdBase | resourceIdMask
        colormapID = resourceIdBase | (resourceIdMask - 1)

        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        let response = X11ConnectionSetup.buildSuccessResponse(.init(
            littleEndian: littleEndian,
            resourceIdBase: resourceIdBase,
            resourceIdMask: resourceIdMask,
            rootWindowID: rootWindowID,
            colormapID: colormapID,
            visualID: visualID,
            argbVisualID: argbVisualID,
            screenWidthPixels: screenW,
            screenHeightPixels: screenH
        ))
        writeFull(response)
        return true
    }

    private func sendSetupFailure(reason: String) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        let reasonBytes = Array(reason.utf8)
        let reasonPadded = X11Wire.pad(reasonBytes.count)
        w.writeU8(0) // Failed
        w.writeU8(UInt8(min(255, reasonBytes.count)))
        w.writeU16(11)
        w.writeU16(0)
        w.writeU16(UInt16(reasonPadded / 4))
        w.writeString8Padded(reason)
        writeFull(w.bytes)
    }

    private static func mainScreenSizeInPixels() -> (width: Int, height: Int) {
        var result = (width: 1920, height: 1080)
        let read = { if let frame = NSScreen.main?.frame { result = (Int(frame.width), Int(frame.height)) } }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        return result
    }

    /// X11 top-level window coordinates are screen-relative, top-left
    /// origin, Y down - `NSWindow`'s own `contentRect`/`setFrame` (unlike
    /// a *subview's* `frame`, which is superview-relative and respects
    /// the superview's `isFlipped`) always use Cocoa's native bottom-left
    /// origin, Y up, regardless of anything this app declares. Passing an
    /// X11 rect straight through - confirmed live - silently mirrors
    /// every top-level window vertically: a client asking for `y=50`
    /// (near the screen's top) lands the window near the BOTTOM instead.
    /// Must run on the main thread (`NSScreen.main`); every call site
    /// already is.
    private static func cocoaScreenFrame(fromX11 frame: CGRect) -> CGRect {
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        return CGRect(x: frame.origin.x, y: screenHeight - frame.origin.y - frame.height, width: frame.width, height: frame.height)
    }

    /// Inverse of `cocoaScreenFrame(fromX11:)` - reads a WINDOW's real,
    /// current on-screen position/size back out as the X11 top-level
    /// content frame a client would recognize. Needs the content view's
    /// OWN size, not just `window.frame`: for a `.titled` window,
    /// `window.frame` includes the title bar (added ABOVE the content
    /// view, never moving its bottom edge - confirmed empirically via
    /// `MSL_X11_TRACE` reading back `window.frame` vs `contentView.frame`
    /// right after construction), so `window.frame.height` alone would
    /// be wrong by exactly the title-bar height. Confirmed live
    /// (2026-09-02) this distinction is NOT cosmetic: a NEWLY CREATED
    /// `.titled` window whose requested X11 position would put its title
    /// bar above the real screen top gets silently pushed back on-screen
    /// by AppKit's own internal placement logic during its first
    /// `orderFront`/`makeKeyAndOrderFront` - confirmed via `MSL_X11_TRACE`
    /// that this adjustment does NOT fire `NSWindowDelegate.windowDidMove`
    /// (ruled out via a temporary trace inside it showing zero calls
    /// across an entire app startup) and does NOT go through any
    /// `ConfigureWindow` request either (the client's own requests kept
    /// x/y at the ORIGINAL value throughout, confirmed via trace) - so
    /// `record.frame.origin` silently went stale relative to the window's
    /// TRUE on-screen position, with no code path ever correcting it.
    /// This is exactly what broke `gui-bugs.md` issue #5's menu-popup
    /// positioning: GDK's own popup-placement math trusted the ORIGINAL
    /// (now-wrong) position it was told about via `ConfigureNotify`,
    /// putting the dropdown ~30-40px too high. `handleMapWindow` calls
    /// this right after ordering the window front specifically to catch
    /// and correct for exactly this class of silent AppKit adjustment,
    /// not just handle explicit client-driven moves the way
    /// `windowDidMove` already did.
    private static func x11Frame(fromCocoaWindow window: NSWindow) -> CGRect {
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let contentSize = window.contentView?.frame.size ?? window.frame.size
        let contentBottomAppKit = window.frame.origin.y // title bar (if any) extends the frame UPWARD from here, never moves it
        let contentTopAppKit = contentBottomAppKit + contentSize.height
        return CGRect(x: window.frame.origin.x, y: screenHeight - contentTopAppKit, width: contentSize.width, height: contentSize.height)
    }

    // MARK: - Request dispatch

    private func dispatch(opcode: UInt8, detail: UInt8, body: [UInt8]) {
        X11Trace.request(opcode: opcode, detail: detail, bodyCount: body.count)
        switch opcode {
        case X11Opcode.createWindow: handleCreateWindow(detail: detail, body: body)
        case X11Opcode.mapWindow: handleMapWindow(body: body)
        case X11Opcode.unmapWindow: handleUnmapWindow(body: body)
        case X11Opcode.destroyWindow: handleDestroyWindow(body: body)
        case X11Opcode.configureWindow: handleConfigureWindow(body: body)
        case X11Opcode.getGeometry: handleGetGeometry(body: body)
        case X11Opcode.createGC: handleCreateGC(body: body)
        case X11Opcode.changeGC: handleChangeGC(body: body)
        case X11Opcode.freeGC: handleFreeGC(body: body)
        // `SetClipRectangles` - genuinely unrecognized by name (this
        // server's usual `BadImplementation`-for-unrecognized-opcodes
        // policy) was confirmed live to crash a real GDK/GTK client
        // (galculator): GDK issues this ROUTINELY (ordinary damage/
        // redraw-region bookkeeping, not an edge case - fires on
        // essentially every widget redraw), and its default X-error
        // handling on receiving a `BadImplementation` for it left the app
        // broken enough to crash outright right after the first button
        // click. Actually implemented (not just silenced) below, once
        // that crash was fixed and a SEPARATE, real glitch surfaced:
        // `handleCopyArea` ignoring the clip entirely let GDK's own
        // offscreen-double-buffer flush overwrite correctly-rendered
        // content with stale offscreen-buffer pixels in gaps that were
        // never meant to be touched - see `handleSetClipRectangles`'s and
        // `handleCopyArea`'s own doc comments.
        case X11Opcode.setClipRectangles: handleSetClipRectangles(body: body)
        case X11Opcode.polyFillRectangle: handlePolyFillRectangle(body: body)
        case X11Opcode.clearArea: handleClearArea(detail: detail, body: body)
        case X11Opcode.copyArea: handleCopyArea(body: body)
        case X11Opcode.imageText8: handleImageText8(detail: detail, body: body)
        case X11Opcode.polyText8: handlePolyText8(body: body)
        case X11Opcode.queryTree: handleQueryTree(body: body)
        case X11Opcode.createPixmap: handleCreatePixmap(detail: detail, body: body)
        case X11Opcode.freePixmap: handleFreePixmap(body: body)
        case X11Opcode.putImage: handlePutImage(detail: detail, body: body)
        case X11Opcode.getImage: handleGetImage(detail: detail, body: body)
        case X11Opcode.polyPoint: handlePolyPoint(detail: detail, body: body)
        case X11Opcode.polyLine: handlePolyLine(detail: detail, body: body)
        case X11Opcode.polySegment: handlePolySegment(body: body)
        case X11Opcode.polyRectangle: handlePolyRectangle(body: body)
        case X11Opcode.polyArc: handlePolyArc(body: body)
        case X11Opcode.fillPoly: handleFillPoly(body: body)
        case X11Opcode.polyFillArc: handlePolyFillArc(body: body)
        case X11Opcode.internAtom: handleInternAtom(detail: detail, body: body)
        case X11Opcode.setSelectionOwner: handleSetSelectionOwner(body: body)
        case X11Opcode.getSelectionOwner: handleGetSelectionOwner(body: body)
        case X11Opcode.convertSelection: handleConvertSelection(body: body)
        case X11Opcode.sendEvent: handleSendEvent(body: body)
        case X11Opcode.getAtomName: handleGetAtomName(body: body)
        case X11Opcode.changeProperty: handleChangeProperty(body: body)
        case X11Opcode.getProperty: handleGetProperty(detail: detail, body: body)
        case X11Opcode.deleteProperty: handleDeleteProperty(body: body)
        case X11Opcode.queryExtension: handleQueryExtension(body: body)
        case X11Opcode.listExtensions: handleListExtensions()
        case X11Opcode.renderExtension: handleRenderRequest(minor: detail, body: body)
        case X11Opcode.bigRequestsExtension: handleBigReqEnable()
        case X11Opcode.xinputExtension: handleXInputRequest(minor: detail, body: body)
        case X11Opcode.xkbExtension: handleXkbRequest(minor: detail, body: body)
        case X11Opcode.randrExtension: handleRandRRequest(minor: detail, body: body)
        case X11Opcode.xcMiscExtension: handleXCMiscRequest(minor: detail, body: body)
        case X11Opcode.shapeExtension: handleShapeRequest(minor: detail, body: body)
        case X11Opcode.getInputFocus: handleGetInputFocus()
        case X11Opcode.queryPointer: handleQueryPointer(body: body)
        case X11Opcode.translateCoordinates: handleTranslateCoordinates(body: body)
        case X11Opcode.changeWindowAttributes: handleChangeWindowAttributes(body: body)
        case X11Opcode.getWindowAttributes: handleGetWindowAttributes(body: body)
        case X11Opcode.allocColor: handleAllocColor(body: body)
        case X11Opcode.queryColors: handleQueryColors(body: body)
        case X11Opcode.allocNamedColor: handleAllocNamedColor(body: body)
        case X11Opcode.lookupColor: handleLookupColor(body: body)
        case X11Opcode.mapSubwindows: handleMapSubwindows(body: body)
        case X11Opcode.reparentWindow: handleReparentWindow(body: body)
        case X11Opcode.createCursor, X11Opcode.createGlyphCursor, X11Opcode.freeCursor, X11Opcode.recolorCursor:
            break // no reply per spec - no real cursor shapes exist yet (see X11Server's doc comment)
        case X11Opcode.grabButton, X11Opcode.ungrabButton: break // no reply per spec; single-client grabs aren't meaningfully contested
        // Same for passive key grabs. Every GTK app sends UngrabKey at
        // startup and got BadImplementation for it.
        case X11Opcode.grabKey, X11Opcode.ungrabKey: break
        // No reply per spec for any of these five - and nothing real to
        // do for any of them, matching `handleAllocColor`/`handleQueryColors`'s
        // own "one flat, always-available colormap" reasoning (see their
        // doc comment): no per-ID colormap actually exists to create,
        // free, copy, install into, or uninstall. Confirmed live as a
        // real crash before this fix, not just theoretical - `abiword`
        // hit `CreateColormap` (opcode 78) unconditionally at startup
        // (defensive GTK boilerplate, not anything abiword-specific) and
        // got a real `BadImplementation` X error from the previous
        // shared `default:` catch-all.
        case X11Opcode.createColormap, X11Opcode.freeColormap, X11Opcode.copyColormapAndFree,
             X11Opcode.installColormap, X11Opcode.uninstallColormap: break
        case X11Opcode.listInstalledColormaps: handleListInstalledColormaps()
        case X11Opcode.grabServer, X11Opcode.ungrabServer: break // no reply per spec; nothing to actually serialize against with one server-side dispatch queue
        case X11Opcode.grabPointer, X11Opcode.grabKeyboard: handleGrabReply()
        case X11Opcode.setInputFocus: handleSetInputFocus(body: body) // no reply per spec, but real state to record
        case X11Opcode.ungrabPointer, X11Opcode.ungrabKeyboard: break // no reply per spec
        case X11Opcode.openFont: handleOpenFont(body: body) // no reply; see MARK: - Font requests
        case X11Opcode.closeFont: state.setFont(X11ByteReader(body, littleEndian: littleEndian).readU32(), isSymbol: false)
        case X11Opcode.queryFont: handleQueryFont()
        case X11Opcode.queryTextExtents: handleQueryTextExtents(detail: detail, body: body)
        case X11Opcode.getKeyboardMapping: handleGetKeyboardMapping(body: body)
        case X11Opcode.getModifierMapping: handleGetModifierMapping()
        case X11Opcode.bell, X11Opcode.noOperation: break // deliberate silent no-ops
        default: sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: 0, majorOpcode: opcode)
        }
    }

    // MARK: - Window requests

    private func handleCreateWindow(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let parent = r.readU32()
        let x = r.readI16()
        let y = r.readI16()
        let width = max(1, r.readU16())
        let height = max(1, r.readU16())
        r.skip(2) // border-width
        // `class`: 0 CopyFromParent, 1 InputOutput, 2 InputOnly. Read and
        // DISCARDED until 2026-09-06, which put invisible windows on screen:
        // an InputOnly window has no pixels at all - it exists purely to
        // catch input or to hold properties, cannot be drawn into (a real
        // server answers `BadMatch` if you try), and must never be
        // displayed. Qt keeps one, and it showed up as the stray 1x1
        // top-level that followed every Krita session around, ranked into
        // the tiling script's slots and destined to become a phantom
        // Mission Control tile and Dock-menu row.
        let windowClass = r.readU16()
        let inputOnly = windowClass == 2
        r.skip(4) // visual
        let valueMask = r.readU32()

        var eventMask: UInt32 = 0
        var backgroundPixel: UInt32 = 0x00FF_FFFF
        var overrideRedirect = false
        for bit: UInt32 in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000] {
            guard valueMask & bit != 0 else { continue }
            let value = r.readU32()
            if bit == 0x02 { backgroundPixel = value }
            if bit == 0x200 { overrideRedirect = value != 0 } // CWOverrideRedirect
            if bit == 0x800 { eventMask = value }
        }

        // Confirmed live this distinction is NOT optional: real X11
        // clients - `xterm` very much included - build a two-level window
        // tree, an outer WM-decorated "shell" whose `parent` is the root,
        // and an inner "core"/content window whose `parent` is THAT shell
        // (later mapped via `MapSubwindows`, not its own `MapWindow` -
        // see `handleMapSubwindows`). Earlier, every `CreateWindow`
        // unconditionally became its own independent top-level `NSWindow`
        // - the shell showed up (decorated, correctly sized, real
        // traffic lights) but the CHILD - where `xterm` actually draws
        // its terminal text - was a second, entirely separate, NEVER-
        // mapped `NSWindow` floating off-screen nobody ever saw: a
        // structurally blank shell window forever, no matter how correct
        // the drawing code itself was. A child instead becomes a plain
        // `NSView` subview of its parent's own view - embedded the way a
        // real client already expects, with X11's parent-relative (x,y)
        // mapping directly onto AppKit's own superview-relative `frame`
        // (respects the parent's `isFlipped` top-left origin automatically,
        // no extra math needed here).
        let parentRecord = state.window(parent)
        let isTopLevel = parentRecord == nil

        // See `X11State.nextCascadeOffset()`'s doc comment - a top-level,
        // non-popup window landing at X11 `(0,0)` (the conventional "no
        // preference" placeholder) gets a small cascading offset instead
        // of stacking exactly on top of every OTHER window that also
        // used that same placeholder. Never applied to override-redirect
        // windows (menus, tooltips) - those genuinely need to land
        // exactly where the client computed, not wherever a cascade
        // counter happens to be.
        var (cascadedX, cascadedY) = (Double(x), Double(y))
        if isTopLevel, !overrideRedirect, x == 0, y == 0 {
            let offset = state.nextCascadeOffset()
            cascadedX = offset.x
            cascadedY = offset.y
        }
        let frame = CGRect(x: cascadedX, y: cascadedY, width: Double(width), height: Double(height))
        let record = state.makeWindow(id: wid, parent: parent, isTopLevel: isTopLevel, frame: frame)
        record.eventMask = eventMask
        record.backgroundPixel = backgroundPixel
        record.overrideRedirect = overrideRedirect
        record.inputOnly = inputOnly
        X11Trace.eventMask(windowID: wid, mask: eventMask, source: "CreateWindow")
        X11Trace.geometry("create", windowID: wid, x: Int(cascadedX), y: Int(cascadedY), width: Int(width), height: Int(height))

        // `.sync`, not `.async` - confirmed live this is a real race, not
        // just a style choice: every drawing handler (`ImageText8`,
        // `PolyFillRectangle`, `PutImage`, ...) checks `record.view`
        // SYNCHRONOUSLY on this connection's own background thread,
        // with no ordering relative to whenever the main thread's async
        // block here happens to actually run. In the common, realistic
        // sequence a real client sends - CreateWindow, MapWindow, then
        // immediately drawing - that async assignment routinely hadn't
        // landed yet by the time the first draw request checked it,
        // silently dropping every one of them (`record.view == nil`, a
        // quiet early return, no error). `.sync` blocks this thread
        // briefly (once per window - not a hot path) but guarantees
        // `record.view`/`record.nsWindow` are already visible to every
        // other thread by the time this function returns.
        let eventSink = self
        DispatchQueue.main.sync {
            let view = X11CanvasView(width: Int(width), height: Int(height))
            view.windowID = wid
            view.eventSink = eventSink
            view.fillWithColor(backgroundPixel)
            record.view = view

            if isTopLevel && !inputOnly {
                // Confirmed live (2026-09-02, `gui-bugs.md` issue #5 -
                // "menus/dialogs severely broken"): `CWOverrideRedirect`
                // was read here (to stay wire-aligned with the rest of
                // the value-list) but never actually applied - EVERY
                // top-level window, including a GTK menu-bar dropdown
                // (created override-redirect specifically so it appears
                // borderless, exactly where the client positioned it,
                // without going through normal window-manager placement/
                // decoration/activation), got the SAME full titled/
                // closable/miniaturizable/resizable chrome a real
                // top-level app window gets. That's real client-visible
                // breakage on its own (a menu popup with a title bar and
                // traffic lights makes no sense), but it also explains
                // why the popup never even got as far as being SHOWN:
                // confirmed via trace log that GTK creates the popup,
                // queries the pointer once more, and destroys it again
                // without ever calling `MapWindow` - consistent with a
                // client-side sanity check (comparing the window it just
                // asked for against what it's actually going to get)
                // giving up rather than showing a visibly-wrong result.
                // A borderless `NSWindow` at `.popUpMenu` level (floats
                // above the normal window, doesn't participate in
                // Cmd-\` cycling or the Window menu) is the correct
                // AppKit shape for this.
                let window = self.makeTopLevelWindow(frame: frame, overrideRedirect: overrideRedirect)
                window.contentView = view
                record.nsWindow = window
            } else if !isTopLevel {
                // Not added as a subview yet - `CreateWindow` doesn't
                // imply mapped, same as a top-level window not showing
                // until its own `MapWindow`/`MapSubwindows` arrives.
                view.frame = frame
            }
            // An InputOnly top-level deliberately gets NO `NSWindow`. It
            // keeps its record (properties, event mask, geometry) so every
            // request naming it still works, and its `view` so nothing that
            // reaches for one has to special-case it - it simply never
            // appears on screen, which is the whole definition of the
            // class. `handleMapWindow`'s `record.nsWindow?` calls are
            // already optional, so mapping one is a no-op that still sends
            // the `MapNotify` the client expects.
        }
    }

    /// The NSWindow for a top-level: a borderless `X11PopupWindow` at
    /// `.popUpMenu` level for override-redirect (see `handleCreateWindow`),
    /// an ordinary titled window otherwise. Main thread only.
    private func makeTopLevelWindow(frame: CGRect, overrideRedirect: Bool) -> NSWindow {
        let styleMask: NSWindow.StyleMask = overrideRedirect ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
        // `X11PopupWindow` (not plain `NSWindow`) specifically for
        // the override-redirect case - see its own doc comment
        // for why a borderless window needs the `canBecomeKey`/
        // `canBecomeMain` override to behave like a real popup.
        let window: NSWindow = overrideRedirect
            ? X11PopupWindow(contentRect: Self.cocoaScreenFrame(fromX11: frame), styleMask: styleMask, backing: .buffered, defer: false)
            : NSWindow(contentRect: Self.cocoaScreenFrame(fromX11: frame), styleMask: styleMask, backing: .buffered, defer: false)
        if overrideRedirect {
            window.level = .popUpMenu
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = true
        } else {
            window.title = "X11 Window"
        }
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        // Mission Control / Exposé / Cmd-` participation - see
        // `X11DockIntegration.applyCollectionBehavior`. A menu or
        // tooltip must NOT get its own Mission Control tile.
        X11DockIntegration.applyCollectionBehavior(to: window, overrideRedirect: overrideRedirect)
        window.delegate = self // see windowDidResize(_:) below - real user-driven resizing needs this
        return window
    }

    /// `CWOverrideRedirect` changed after `CreateWindow`.
    ///
    /// Tk creates a menu's wrapper window first and only then marks it
    /// override-redirect with `ChangeWindowAttributes` (tkUnixWm.c
    /// `TkpMakeMenuWindow`). Reading the bit only at creation left every
    /// IDLE/gitk dropdown a titled, key-stealing NSWindow of its own. An
    /// NSWindow's class and style can't change in place, so the window is
    /// rebuilt around the same view, keeping visibility and child windows.
    private func applyOverrideRedirect(_ record: X11State.WindowRecord, _ overrideRedirect: Bool) {
        guard record.overrideRedirect != overrideRedirect else { return }
        record.overrideRedirect = overrideRedirect
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] overrideRedirect wid=\(record.id) -> \(overrideRedirect) topLevel=\(record.isTopLevel) hasWindow=\(record.nsWindow != nil)\n".data(using: .utf8)!)
        }
        guard record.isTopLevel, !record.inputOnly, record.nsWindow != nil else { return }
        let wid = record.id
        if overrideRedirect, lastOrdinaryTopLevelID == wid { lastOrdinaryTopLevelID = nil }
        // `.sync` for the same reason as `handleCreateWindow`: the next
        // MapWindow must already see the new window.
        DispatchQueue.main.sync {
            guard let old = record.nsWindow, let view = record.view else { return }
            let wasVisible = old.isVisible
            let title = old.title
            let owner = old.parent
            let children = old.childWindows ?? []
            owner?.removeChildWindow(old)
            for child in children { old.removeChildWindow(child) }
            old.delegate = nil // no didResize/willClose echoes for a window being retired
            old.contentView = NSView() // hands `record.view` back before the window goes
            old.orderOut(nil)
            old.close()
            if overrideRedirect { X11DockIntegration.shared.windowDidUnmap(wid) }

            let window = self.makeTopLevelWindow(frame: record.frame, overrideRedirect: overrideRedirect)
            if !overrideRedirect { window.title = title }
            window.contentView = view
            record.nsWindow = window
            for child in children { window.addChildWindow(child, ordered: .above) }
            guard wasVisible else { return }
            window.orderFrontRegardless()
            if overrideRedirect {
                owner?.addChildWindow(window, ordered: .above)
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                X11DockIntegration.shared.windowDidMap(wid, window: window)
            }
        }
    }

    /// Adds `record`'s view as a mapped subview of its parent (a no-op if
    /// already mapped) and sends the `Expose` a newly-visible window
    /// needs - shared by `handleMapWindow` and `handleMapSubwindows`
    /// (`MapSubwindows` maps every child the exact same way, just for
    /// several windows in one request instead of one).
    private func mapChild(_ record: X11State.WindowRecord) {
        guard !record.isTopLevel else { return }
        record.mapped = true
        guard let parentView = state.window(record.parent)?.view, let view = record.view else {
            X11Trace.mapExpose(windowID: record.id, sent: false, eventMask: record.eventMask)
            return
        }
        DispatchQueue.main.async {
            view.frame = record.frame
            if view.superview !== parentView { parentView.addSubview(view) }
        }
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendMapNotify(windowID: record.id)
        }
        let shouldExpose = record.eventMask & 0x0000_8000 != 0 // ExposureMask
        X11Trace.mapExpose(windowID: record.id, sent: shouldExpose, eventMask: record.eventMask)
        if shouldExpose {
            sendExposeEvent(windowID: record.id, width: UInt16(clamping: Int(record.frame.width)), height: UInt16(clamping: Int(record.frame.height)))
        }
    }

    /// `WM_TRANSIENT_FOR` - predefined atom 68, a CARD32 window id saying
    /// "this window belongs to that one" (dialogs, utility panels).
    private static let wmTransientForAtom: UInt32 = 68

    /// Makes a popup/dialog track the window it belongs to, instead of
    /// being an unrelated free-floating `NSWindow`.
    ///
    /// A menu, combo dropdown or modal dialog is a SEPARATE top-level in
    /// X11 - override-redirect for menus, `WM_TRANSIENT_FOR` for dialogs -
    /// positioned by the client in absolute ROOT coordinates at the moment
    /// it opens. With no window manager here each of those became a
    /// completely independent `NSWindow`: correct at the instant it
    /// appeared, then left behind the moment its owner moved, and freely
    /// orderable BEHIND the window it belongs to. That is the "menus and
    /// dialogs go haywire" report.
    ///
    /// AppKit already has exactly this relationship: `addChildWindow` keeps
    /// the child ordered above its parent and moves it by the same delta
    /// whenever the parent moves. The child's own `windowDidMove` still
    /// fires for those automatic moves, so the CLIENT is told its popup
    /// moved (`ConfigureNotify`) and its own coordinate bookkeeping stays
    /// truthful rather than silently drifting.
    ///
    /// Owner resolution, in order: an explicit `WM_TRANSIENT_FOR`, else -
    /// for an override-redirect popup, which never sets it - the current
    /// input-focus window, else this connection's own most recently mapped
    /// ordinary top-level. A connection is one app here, so that last
    /// fallback is the window the menu actually spawned from.
    private func attachToOwnerWindow(_ record: X11State.WindowRecord) {
        guard record.isTopLevel, let childWindow = record.nsWindow else { return }
        var ownerID: UInt32?
        var ownerVia = "none"
        if let prop = record.properties[Self.wmTransientForAtom], prop.data.count >= 4 {
            let r = X11ByteReader(prop.data, littleEndian: littleEndian)
            let candidate = r.readU32()
            if candidate != 0, candidate != record.id { ownerID = candidate; ownerVia = "WM_TRANSIENT_FOR" }
        }
        if ownerID == nil, record.overrideRedirect {
            let focused = state.currentFocusWindow()
            if focused != 0, focused != record.id, state.window(focused)?.isTopLevel == true {
                ownerID = focused; ownerVia = "focusWindow"
            } else {
                ownerID = lastOrdinaryTopLevelID; ownerVia = "lastOrdinaryTopLevel"
            }
        }
        guard let ownerID, ownerID != record.id,
              let owner = state.window(ownerID), owner.isTopLevel,
              let ownerWindow = owner.nsWindow, ownerWindow !== childWindow
        else { return }
        // Never build a cycle: if the prospective owner is itself already
        // a descendant of this window, attaching would deadlock AppKit's
        // own parent walk.
        var ancestor: NSWindow? = ownerWindow
        while let a = ancestor {
            if a === childWindow { return }
            ancestor = a.parent
        }
        if let existing = childWindow.parent, existing !== ownerWindow {
            existing.removeChildWindow(childWindow)
        }
        guard childWindow.parent !== ownerWindow else { return }
        ownerWindow.addChildWindow(childWindow, ordered: .above)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] attachOwner child=\(record.id) owner=\(ownerID) via=\(ownerVia) overrideRedirect=\(record.overrideRedirect) ownerFrame=\(owner.frame)\n".data(using: .utf8)!)
        }
    }

    /// Detaches a popup/dialog from its owner - see `attachToOwnerWindow`.
    /// A child window AppKit still owns would otherwise be dragged around
    /// by (and ordered above) a parent it no longer has anything to do
    /// with once it has been unmapped or destroyed.
    private func detachFromOwnerWindow(_ record: X11State.WindowRecord) {
        guard let childWindow = record.nsWindow, let parent = childWindow.parent else { return }
        parent.removeChildWindow(childWindow)
    }

    private func handleMapWindow(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        guard let record = state.window(wid) else { return }
        guard record.isTopLevel else {
            mapChild(record)
            return
        }
        record.mapped = true
        if !record.overrideRedirect { lastOrdinaryTopLevelID = record.id }
        DispatchQueue.main.async {
            // `activate` here too, not just once in `X11Server.start()` -
            // this app has `.accessory` policy and no Dock icon, so a
            // window mapped while some OTHER app is frontmost (completely
            // normal - the user switching away and back) isn't guaranteed
            // to come forward on its own otherwise. `orderFrontRegardless`
            // alongside `makeKeyAndOrderFront` for the same reason - it
            // doesn't consult app-activation/key-window state the way
            // `makeKeyAndOrderFront` alone does.
            NSApplication.shared.activate(ignoringOtherApps: true)
            record.nsWindow?.orderFrontRegardless()
            record.nsWindow?.makeKeyAndOrderFront(nil)
            // `makeKeyAndOrderFront` alone only makes the WINDOW key - it
            // does NOT promote this window's view to first responder.
            // Keyboard events (`keyDown`/`keyUp`) follow the responder
            // chain starting from `NSWindow.firstResponder`, which
            // defaults to the window itself (a plain `NSResponder` with
            // no keyboard handling of its own) until something explicitly
            // calls `makeFirstResponder` - unlike mouse events, which
            // AppKit delivers by hit-testing regardless of responder
            // state. Without this, a window could be genuinely key
            // (clicks work, `ensureActivated`'s guard sees `isKeyWindow
            // == true` and never re-fires) while every keystroke still
            // silently went nowhere - confirmed live as the real cause of
            // "abiword renders but isn't inputable": clicking placed the
            // text cursor correctly (hit-testing-based), but typing
            // afterward produced nothing at all (responder-chain-based).
            record.nsWindow?.makeFirstResponder(record.view)
            // See `x11Frame(fromCocoaWindow:)`'s doc comment - catches
            // AppKit silently repositioning a newly-shown window (e.g. to
            // keep its title bar from landing above the real screen top)
            // without ever telling this window's own client, which the
            // ORIGINAL `ConfigureNotify` already sent at creation time
            // (with the client's own, now-stale, requested position)
            // can't retroactively correct.
            if record.nsWindow != nil {
                // Reconciles the WHOLE frame, not just the origin (which
                // is all this did until 2026-09-06). AppKit runs
                // `constrainFrameRect(_:to:)` on a window's first
                // `orderFront`, and it does not only MOVE a window that
                // doesn't fit the screen's visible area - it SHRINKS one
                // that is taller than the screen minus the menu bar. That
                // resize fires no delegate callback and goes through no
                // `ConfigureWindow`, so the client kept its original,
                // now-wrong idea of its own size for the rest of the
                // session AND `record.view`'s backing bitmap stayed at the
                // requested size while its on-screen frame was smaller -
                // i.e. the client drew a layout for a window bigger than
                // the one the user could see, with the overflow simply
                // never visible. `NSWindow.contentMinSize`, set from
                // `WM_NORMAL_HINTS` (see `applyWMNormalHints`), can grow a
                // window here for the same silent reason.
                //
                // `syncFrameFromWindow` already does exactly this
                // reconciliation for the external-move/resize case, down
                // to resizing the view's bitmap and sending the Expose a
                // size change needs - reused here rather than duplicated.
                self.syncFrameFromWindow(record)
                // AFTER the geometry fix-up above, so the popup is attached
                // at its already-corrected location rather than dragging a
                // stale origin along with it.
                self.attachToOwnerWindow(record)
                self.synthesizeCrossingIfPointerAlreadyInside(record, windowID: wid)
                // Dock/menu-bar registration. Ordinary top-levels only -
                // `windowDidMap` is what promotes the process to a
                // `.regular` app with a Dock tile, and a menu popping open
                // must not do that.
                if !record.overrideRedirect, let window = record.nsWindow {
                    X11DockIntegration.shared.windowDidMap(wid, window: window)
                    // The icon usually arrives BEFORE the map (GTK and Qt
                    // both set `_NET_WM_ICON` right after `CreateWindow`),
                    // so re-apply whatever the record already has rather
                    // than waiting for a property change that won't come.
                    if let icon = record.iconImage {
                        X11DockIntegration.shared.setIcon(icon, forWindow: wid, window: window)
                    }
                    if let name = record.appName {
                        X11DockIntegration.shared.setAppName(name, forWindow: wid)
                    }
                }
            }
        }
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendMapNotify(windowID: wid)
        }
        // Confirmed live this is NOT optional: a client like `xterm` draws
        // its initial content ONLY in response to being told "you're
        // newly visible, here's what needs painting" - it does not just
        // eagerly draw on `MapWindow` itself. A real X server always
        // sends this after a window's first map; skipping it left a
        // genuinely mapped, on-screen, correctly-sized window that just
        // never got told to draw anything, staying blank forever.
        let shouldExpose = record.eventMask & 0x0000_8000 != 0 // ExposureMask
        X11Trace.mapExpose(windowID: wid, sent: shouldExpose, eventMask: record.eventMask)
        if shouldExpose {
            sendExposeEvent(windowID: wid, width: UInt16(clamping: Int(record.frame.width)), height: UInt16(clamping: Int(record.frame.height)))
        }
    }

    /// Maps every direct child of `wid` at once - real X11 semantics
    /// (children only, not `wid` itself, not grandchildren). Confirmed
    /// live `xterm` relies on exactly this to show its actual terminal
    /// content: the outer shell window gets its own explicit `MapWindow`,
    /// but the inner content window - where text is actually drawn - is
    /// mapped ONLY via this request on the shell, never its own
    /// `MapWindow`. Previously a silent no-op (see the git history on
    /// this line) - the shell showed up, decorated and correctly sized,
    /// but its content window never appeared: a structurally blank
    /// window forever, regardless of how correct the drawing code itself
    /// was.
    private func handleMapSubwindows(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        for child in state.children(ofParent: wid) where !child.mapped {
            mapChild(child)
        }
    }

    private func handleUnmapWindow(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        guard let record = state.window(wid) else { return }
        record.mapped = false
        // A window that is no longer on screen cannot still contain the
        // pointer, and AppKit will never send it the matching `mouseExited`
        // - leaving `pointerInside` set would make the Enter after a remap
        // (a menu reopening, say) look redundant and get suppressed.
        record.pointerInside = false
        if record.isTopLevel {
            DispatchQueue.main.async {
                // Detach BEFORE ordering out - see `attachToOwnerWindow`.
                self.detachFromOwnerWindow(record)
                record.nsWindow?.orderOut(nil)
                X11DockIntegration.shared.windowDidUnmap(wid)
            }
        } else {
            DispatchQueue.main.async { record.view?.removeFromSuperview() }
            // Same family as `handleConfigureWindow`'s Expose-on-grow fix
            // (see its doc comment) and the ORIGINAL "black border on
            // resize" fix `windowDidResize` already has - a region is
            // becoming newly visible with nothing telling the CLIENT it
            // needs to paint there, just via unmapping a child instead of
            // resizing a window. This server keeps every window's
            // `bitmapContext` around indefinitely (there's no real
            // backing-store-None "content is undefined" concept here -
            // whatever was last drawn just stays), so removing this
            // child subview doesn't blank the area underneath - it reveals
            // the PARENT's own bitmap exactly as it was last drawn,
            // stale or not. A toolkit that swaps one child-window-based
            // view for another (e.g. Qt swapping a welcome-screen layout
            // for a document/canvas layout, `gui-bugs.md`'s "welcome
            // page content ghosts into the canvas area" report) typically
            // does this via unmap/remap rather than a full top-level
            // re-paint, and relies on the server telling its PARENT to
            // repaint whatever region the removed child used to own -
            // without this, any area the new layout doesn't itself cover
            // keeps showing leftover content from whatever used to be
            // there, indefinitely.
            if let parent = state.window(record.parent), parent.eventMask & 0x0000_8000 != 0 { // ExposureMask
                sendExposeEvent(
                    windowID: record.parent,
                    x: UInt16(clamping: Int(record.frame.origin.x)), y: UInt16(clamping: Int(record.frame.origin.y)),
                    width: UInt16(clamping: Int(record.frame.width)), height: UInt16(clamping: Int(record.frame.height))
                )
            }
        }
    }

    /// `ReparentWindow` (opcode 7). Tk (IDLE, gitk, every Tkinter app)
    /// creates its toplevel on the root, then a "wrapper" on the root, and
    /// reparents the toplevel into the wrapper at (0,0) before mapping
    /// anything (tkUnixWm.c `CreateWrapper`). WM_NAME and the MapWindow go
    /// to the wrapper; all drawing goes to the toplevel. Answering
    /// BadImplementation left them as two unrelated NSWindows: a titled,
    /// blank wrapper and an "X11 Window" holding the real content.
    ///
    /// Protocol order: unmap if mapped, reparent, `ReparentNotify`, remap.
    /// A top-level moving under another window gives up its NSWindow and
    /// becomes an embedded view. The reverse (child to root) only detaches
    /// the view - Tk does that immediately before destroying the window,
    /// and nothing else observed sends it - so such a window is not shown
    /// again as its own NSWindow.
    private func handleReparentWindow(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let newParent = r.readU32()
        let x = r.readI16()
        let y = r.readI16()
        guard let record = state.window(wid), newParent != wid else { return }
        let toRoot = newParent == rootWindowID
        if !toRoot {
            // The new parent must exist and must not be inside `wid`
            // (real servers answer BadMatch; a cycle here would hang
            // every parent walk, `windowOrigin` included).
            guard state.window(newParent) != nil else { return }
            var ancestor = newParent
            for _ in 0..<64 {
                if ancestor == wid { return }
                guard let next = state.window(ancestor)?.parent, next != ancestor else { break }
                ancestor = next
            }
        }
        if toRoot && record.isTopLevel { return } // already there; nothing observed needs the move

        let idBytes = X11ByteWriter(littleEndian: littleEndian)
        idBytes.writeU32(wid)
        let wasMapped = record.mapped
        if wasMapped { handleUnmapWindow(body: idBytes.bytes) }

        let oldParent = record.parent
        record.parent = newParent
        record.frame.origin = CGPoint(x: Double(x), y: Double(y))
        let frame = record.frame
        if record.isTopLevel {
            record.isTopLevel = false
            let window = record.nsWindow
            record.nsWindow = nil
            if lastOrdinaryTopLevelID == wid { lastOrdinaryTopLevelID = nil }
            // `.sync` for the same reason as `handleCreateWindow`: requests
            // that follow (ConfigureWindow, MapWindow, drawing) must already
            // see a plain child view. Runs after `handleUnmapWindow`'s own
            // async block, which was queued first.
            DispatchQueue.main.sync {
                if let window {
                    window.parent?.removeChildWindow(window)
                    window.delegate = nil // no windowWillClose/didResize echoes for a window being retired
                    window.contentView = NSView() // hands `record.view` back before the window goes
                    window.orderOut(nil)
                    window.close()
                }
                record.view?.frame = frame
            }
        } else {
            DispatchQueue.main.async {
                record.view?.removeFromSuperview()
                record.view?.frame = frame
            }
        }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] reparent wid=\(wid) from=\(oldParent) to=\(newParent) at=(\(x),\(y)) wasMapped=\(wasMapped)\n".data(using: .utf8)!)
        }

        let structureNotify: UInt32 = 0x0002_0000, substructureNotify: UInt32 = 0x0008_0000
        if record.eventMask & structureNotify != 0 {
            sendReparentNotify(event: wid, window: wid, parent: newParent, x: x, y: y, overrideRedirect: record.overrideRedirect)
        }
        for parentID in Set([oldParent, newParent]) {
            if let parent = state.window(parentID), parent.eventMask & substructureNotify != 0 {
                sendReparentNotify(event: parentID, window: wid, parent: newParent, x: x, y: y, overrideRedirect: record.overrideRedirect)
            }
        }
        if wasMapped && !toRoot { mapChild(record) }
    }

    private func handleDestroyWindow(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        // Real X11 destroys the whole subtree, not just `wid` - a client
        // tearing down a shell window expects its content windows to go
        // with it, not linger as orphaned, still-tracked records nothing
        // will ever reference again.
        for child in state.children(ofParent: wid) { destroyWindowRecursive(child.id) }
        destroyWindowRecursive(wid)
    }

    private func destroyWindowRecursive(_ wid: UInt32) {
        for child in state.children(ofParent: wid) { destroyWindowRecursive(child.id) }
        guard let record = state.removeWindow(wid) else { return }
        if record.isTopLevel {
            DispatchQueue.main.async {
                self.detachFromOwnerWindow(record) // see `attachToOwnerWindow`
                X11DockIntegration.shared.windowDidUnmap(wid)
                record.nsWindow?.close()
            }
        } else {
            DispatchQueue.main.async { record.view?.removeFromSuperview() }
        }
    }

    private func handleConfigureWindow(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let valueMask = UInt32(r.readU16())
        r.skip(2)
        guard let record = state.window(wid) else { return }
        let oldFrame = record.frame
        let oldSize = oldFrame.size
        var frame = record.frame
        for bit: UInt32 in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40] {
            guard valueMask & bit != 0 else { continue }
            let raw = r.readU32()
            switch bit {
            case 0x01: frame.origin.x = Double(Int32(bitPattern: raw))
            case 0x02: frame.origin.y = Double(Int32(bitPattern: raw))
            case 0x04: frame.size.width = Double(raw)
            case 0x08: frame.size.height = Double(raw)
            default: break // border-width/sibling/stack-mode - not tracked in this skeleton
            }
        }
        record.frame = frame
        X11Trace.geometry("configure(mask=0x\(String(valueMask, radix: 16)))", windowID: wid, x: Int(frame.origin.x), y: Int(frame.origin.y), width: Int(frame.width), height: Int(frame.height))
        // A request that changes neither position nor size (stack-mode or
        // border-width only, or the same values again) must not touch AppKit
        // geometry. The block below captures `frame` now and runs later: if
        // macOS has shrunk the window in between (a window taller than the
        // screen is constrained on its first orderFront), it re-applied the
        // stale size - the canvas re-grew to 1012 inside a 968-high window
        // and its top 44 points (LibreOffice Math's menu bar and half its
        // toolbar) sat above the visible content area.
        let geometryChanged = Int(frame.origin.x) != Int(oldFrame.origin.x) || Int(frame.origin.y) != Int(oldFrame.origin.y)
            || Int(frame.width) != Int(oldSize.width) || Int(frame.height) != Int(oldSize.height)
        if geometryChanged { DispatchQueue.main.async {
            record.view?.resize(width: Int(frame.width), height: Int(frame.height))
            if record.isTopLevel {
                // `NSWindow.setFrame(_:display:)`, unlike the `contentRect:`
                // parameter to `NSWindow(contentRect:styleMask:...)` used at
                // CREATE time (which AppKit auto-expands for the title bar),
                // takes its rect as the OUTER frame verbatim - no implicit
                // content->frame conversion. `cocoaScreenFrame(fromX11:)`
                // returns a CONTENT-sized rect (X11's width/height ARE the
                // content size a client expects to draw into), so passing
                // it straight to `setFrame` on a `.titled` window silently
                // shrank the actual visible content view by exactly the
                // title bar's height on every resize after creation -
                // confirmed live via Krita's "New Image" dialog (which
                // resizes itself taller once its real content loads):
                // `MSL_X11_SNAPSHOT_DIR`'s own dump of the window's
                // `bitmapContext` showed the Create/Cancel button row
                // fully, correctly rendered, while the actual on-screen
                // NSWindow cut them off at the bottom - the content was
                // right, the window just wasn't tall enough to show all of
                // it. `NSWindow.frameRect(forContentRect:styleMask:)` does
                // the same expansion `contentRect:` gets for free at
                // construction time, growing the frame upward from the
                // content's bottom edge (matching `x11Frame(fromCocoaWindow:)`'s
                // own doc comment on that direction) - using it here keeps
                // every later resize consistent with the window's initial,
                // correctly-sized creation.
                let contentFrame = Self.cocoaScreenFrame(fromX11: frame)
                let styleMask = record.nsWindow?.styleMask ?? []
                let outerFrame = NSWindow.frameRect(forContentRect: contentFrame, styleMask: styleMask)
                // `setFrame` is a silent no-op - no `windowDidResize`/
                // `windowDidMove` delegate call at all - for whichever of
                // size/origin already matches `outerFrame` (e.g. a client
                // that only MOVED itself, or only grew, produces a
                // `ConfigureWindow` whose other dimension is unchanged;
                // this dialog's own first resize did exactly that - same
                // 505x270 size as its creation, only the position changed).
                // `pendingProgrammatic*` used to be incremented
                // unconditionally, before this fix, which happened to be
                // safe only because the OLD (buggy) `setFrame` call always
                // used the wrong height and therefore always differed from
                // the window's real current frame, always firing both
                // delegate methods, always consuming both counts. Now that
                // `setFrame` gets the truly-correct outer frame, a same-
                // size-or-same-origin configure is a genuine no-op for
                // that dimension - incrementing its counter regardless
                // would leak it forever, and the NEXT real user-driven
                // drag-resize/drag-move would then be wrongly swallowed as
                // an echo of a server-initiated change that never actually
                // fired (`windowDidResize`/`windowDidMove` return early
                // whenever their count is > 0), silently dropping a real
                // `ConfigureNotify`/`Expose` the client needed.
                // Remember WHAT we asked for, rather than counting how
                // many callbacks to expect - see
                // `WindowRecord.programmaticOuterFrame` for why counting
                // leaked and what it broke.
                record.programmaticOuterFrame = outerFrame
                record.nsWindow?.setFrame(outerFrame, display: true)
            } else {
                // A top-level `NSWindow.setFrame` covers both position
                // and size at once; `X11CanvasView.resize` only ever
                // touched size (a top-level window's contentView origin
                // is always (0,0), so it never needed to). A child's
                // `frame.origin` is meaningful, though - it's the child's
                // position WITHIN its parent's view - and `resize` alone
                // leaves it wherever it last was.
                record.view?.frame.origin = frame.origin
            }
        } }
        // `xterm` (and most real clients) expect a `ConfigureNotify` after
        // any actual geometry change, mapped or not - some redraw logic
        // is gated on receiving one, not just on `Expose`.
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendConfigureNotify(record)
        }
        // See `windowDidResize`'s doc comment - the exact same "growing a
        // window reveals a region nothing has ever painted, and
        // `ConfigureNotify` alone doesn't guarantee a repaint there" gap,
        // just for a CLIENT-initiated resize (a real `ConfigureWindow`
        // request, e.g. a toolkit growing its own window once a widget
        // needs more space) instead of a real drag-resize - confirmed
        // live via galculator, which resizes itself taller right after
        // creation (293 -> 352, no user interaction at all): the window
        // grew to the correct final size (this file's earlier title-bar
        // fix already gets that part right), but the newly-revealed
        // button-grid area stayed permanently blank - only a manual
        // real drag-resize afterward (going through `windowDidResize`'s
        // OWN already-correct Expose-on-grow) ever painted it, matching
        // the user's exact "cutoff, fixes the moment I slightly resize
        // it" report. `windowDidResize` had this fix already; this path
        // never did.
        if record.eventMask & 0x0000_8000 != 0, // ExposureMask
           frame.width > oldSize.width || frame.height > oldSize.height {
            sendExposeEvent(windowID: wid, width: UInt16(clamping: Int(frame.width)), height: UInt16(clamping: Int(frame.height)))
        }
        // Same "a region is becoming visible with nothing telling the
        // client to paint it" gap as the grow-case above, just the
        // PARENT's side of it: a non-top-level window that SHRINKS (or
        // moves away from where it was) uncovers whatever area of its
        // PARENT it used to sit on top of - see `handleUnmapWindow`'s
        // doc comment for the identical unmap-driven case and why this
        // server's indefinitely-persistent `bitmapContext` per window
        // makes this matter (stale content reappears, not a blank
        // reveal). Exposes the child's OLD full rect on the parent
        // (rather than computing the precise uncovered sliver) - the
        // same "whole area, not precise sub-rects" simplification this
        // file already uses for `handleMapWindow`/`windowDidResize`.
        if !record.isTopLevel,
           let parent = state.window(record.parent), parent.eventMask & 0x0000_8000 != 0, // ExposureMask
           (frame.width < oldFrame.width || frame.height < oldFrame.height || frame.origin != oldFrame.origin) {
            sendExposeEvent(
                windowID: record.parent,
                x: UInt16(clamping: Int(oldFrame.origin.x)), y: UInt16(clamping: Int(oldFrame.origin.y)),
                width: UInt16(clamping: Int(oldFrame.width)), height: UInt16(clamping: Int(oldFrame.height))
            )
        }
    }

    private func handleGetGeometry(body: [UInt8]) {
        let drawable = X11ByteReader(body, littleEndian: littleEndian).readU32()
        let frame = state.window(drawable)?.frame ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        if X11Trace.enabled {
            let kind = state.window(drawable) != nil ? "window" : (state.pixmap(drawable) != nil ? "pixmap" : "unknown")
            FileHandle.standardError.write("[x11] getGeometry drawable=\(drawable) kind=\(kind) -> \(frame)\n".data(using: .utf8)!)
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(rootWindowID)
        fw.writeI16(Int16(clamping: Int(frame.origin.x)))
        fw.writeI16(Int16(clamping: Int(frame.origin.y)))
        fw.writeU16(UInt16(clamping: Int(frame.width)))
        fw.writeU16(UInt16(clamping: Int(frame.height)))
        fw.writeU16(0) // border-width
        fw.writePadding(10)
        sendReply(fixed24: fw, detail: 24) // detail byte here is the drawable's depth
    }

    /// `QueryTree` - a window's root, parent, and direct children.
    /// Genuinely unimplemented before the Layer-0 subwindows test (`Guest/
    /// init/x11-tests/06_subwindows.c`) went looking for it: not just
    /// missing a feature, an unhandled opcode here means the SERVER SENDS
    /// NO REPLY AT ALL, so any real client calling `XQueryTree` (window
    /// managers enumerating a screen's windows, most toolkits' `-geometry`/
    /// reparenting-detection logic) blocks forever waiting for a reply
    /// that will never come - a silent, total hang, not a clean error.
    private func handleQueryTree(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        let parent: UInt32 = wid == rootWindowID ? 0 : (state.window(wid)?.parent ?? 0)
        let children = state.children(ofParent: wid).map(\.id)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(rootWindowID)
        fw.writeU32(parent)
        fw.writeU16(UInt16(children.count))
        fw.writePadding(14)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        for child in children { extra.writeU32(child) }
        sendReply(fixed24: fw, extra: extra.bytes)
    }

    private func handleChangeWindowAttributes(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let valueMask = r.readU32()
        guard let record = state.window(wid) else { return }
        var overrideRedirect: Bool?
        for bit: UInt32 in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000] {
            guard valueMask & bit != 0 else { continue }
            let value = r.readU32()
            if bit == 0x02 { record.backgroundPixel = value }
            if bit == 0x200 { overrideRedirect = value != 0 } // CWOverrideRedirect
            if bit == 0x800 {
                record.eventMask = value
                X11Trace.eventMask(windowID: wid, mask: value, source: "ChangeWindowAttributes")
            }
        }
        if let overrideRedirect { applyOverrideRedirect(record, overrideRedirect) }
    }

    /// Fixed reply part is 36 bytes here (not the usual 24
    /// `sendReply(fixed24:)` assumes), same reasoning as `handleQueryFont`
    /// - built by hand. `visual`/`class` are made up (there's only ever
    /// the one TrueColor visual `X11ConnectionSetup` advertised at
    /// connection setup) but structurally valid, which is what clients
    /// that just want to confirm a window's current map-state actually
    /// check this for.
    private func handleGetWindowAttributes(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        let record = state.window(wid)
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1) // Reply
        w.writeU8(1) // backing-store: WhenMapped
        w.writeU16(sequenceNumber)
        w.writeU32(3) // reply length: (44 - 32) / 4
        w.writeU32(visualID)
        w.writeU16(1) // class: InputOutput
        w.writeU8(0) // bit-gravity
        w.writeU8(0) // win-gravity
        w.writeU32(0) // backing-planes
        w.writeU32(0) // backing-pixel
        w.writeU8(0) // save-under
        w.writeU8(1) // map-is-installed
        w.writeU8((record?.mapped ?? false) ? 2 : 0) // map-state: Viewable / Unmapped
        w.writeU8((record?.overrideRedirect ?? false) ? 1 : 0) // override-redirect
        w.writeU32(colormapID)
        w.writeU32(0x01FF_FFFF) // all-event-masks: everything this server understands
        w.writeU32(record?.eventMask ?? 0)
        w.writeU16(0) // do-not-propagate-mask
        w.writePadding(2)
        writeFull(w.bytes)
    }

    // MARK: - Graphics context requests

    private func handleCreateGC(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let cid = r.readU32()
        r.skip(4) // drawable
        let valueMask = r.readU32()
        let record = state.makeGC(id: cid)
        applyGCValues(valueMask: valueMask, reader: r, into: record)
    }

    private func handleChangeGC(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let cid = r.readU32()
        let valueMask = r.readU32()
        let record = state.gc(cid) ?? state.makeGC(id: cid)
        applyGCValues(valueMask: valueMask, reader: r, into: record)
    }

    private func applyGCValues(valueMask: UInt32, reader r: X11ByteReader, into record: X11State.GCRecord) {
        // GCClipMask (bit 19, 0x8_0000): a client sets this to reset the
        // GC's clip - either to `None` (fully unclipped) or to an
        // arbitrary bitmap pixmap mask, which this server doesn't
        // implement. Confirmed live via GDK/galculator: a shared GC gets
        // `SetClipRectangles`'d to one widget's damaged region, then
        // `ChangeGC(gc, clip_mask=None)`'d back to unclipped before an
        // UNRELATED widget's own flush reuses the same GC - if this bit
        // is silently dropped (as it was before this fix, alongside every
        // other bit except foreground/background), that reset never
        // happens and the stale rectangle-based clip from the FIRST
        // widget keeps clipping the SECOND widget's blits forever after,
        // near-invisibly (most of the blit gets clipped away, but
        // whatever coincidentally overlaps the stale rect still shows
        // through - this is exactly what made galculator's display look
        // like it "stopped updating" after the first keystroke). Either
        // value (None or a real pixmap) clears our rectangle-based clip -
        // a stale WRONG clip is worse than no clip, and a real bitmap
        // clip mask isn't implemented here regardless.
        for bit: UInt32 in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000, 0x8000, 0x1_0000, 0x2_0000, 0x4_0000, 0x8_0000, 0x10_0000, 0x20_0000, 0x40_0000] {
            guard valueMask & bit != 0 else { continue }
            let value = r.readU32()
            if bit == 0x04 { record.foreground = value }
            if bit == 0x08 { record.background = value }
            if bit == 0x4000 { record.font = value } // GCFont
            if bit == 0x8_0000 { record.clipRectangles = nil }
        }
    }

    /// `SetClipRectangles` (core opcode 59) - wire layout: `gc`(4) +
    /// `clip-x-origin`(INT16) + `clip-y-origin`(INT16), then a
    /// `LISTofRECTANGLE` (8 bytes each: x,y,w,h - each rect is relative
    /// to the given origin, per spec). An EMPTY rectangle list is a
    /// real, meaningful case, not just "nothing to parse" - it's how a
    /// client resets a GC back to unclipped, and confirmed live GDK
    /// does exactly this routinely (clip to a widget's damaged region,
    /// draw, then clip-to-nothing/reset) - so `nil` (not an empty array)
    /// specifically means "no clip" throughout this file.
    private func handleSetClipRectangles(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let gcId = r.readU32()
        let originX = Double(r.readI16())
        let originY = Double(r.readI16())
        guard let gc = state.gc(gcId) else { return }
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: originX + Double(x), y: originY + Double(y), width: Double(w), height: Double(h)))
        }
        gc.clipRectangles = rects.isEmpty ? nil : rects
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] setClipRectangles gc=\(gcId) origin=(\(originX),\(originY)) rects=\(rects)\n".data(using: .utf8)!)
        }
    }

    private func handleFreeGC(body: [UInt8]) {
        let cid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        state.removeGC(cid)
    }

    // MARK: - Colors

    /// No real colormap/palette exists (this server only ever advertised
    /// one TrueColor visual - direct RGB, no indexed palette to allocate
    /// from), so this just packs the request's own 16-bit-per-channel RGB
    /// down to the 8-bit-per-channel `0x00RRGGBB` pixel encoding used
    /// everywhere else here (`fillWithColor`, `drawText`, ...) and echoes
    /// it straight back as both the "actual" color and the pixel value -
    /// always exactly representable, never approximated, on a TrueColor
    /// visual.
    private func handleAllocColor(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // colormap - only one exists
        let red = r.readU16()
        let green = r.readU16()
        let blue = r.readU16()
        let pixel = (UInt32(red >> 8) << 16) | (UInt32(green >> 8) << 8) | UInt32(blue >> 8)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(red)
        fw.writeU16(green)
        fw.writeU16(blue)
        fw.writePadding(2)
        fw.writeU32(pixel)
        fw.writePadding(12)
        sendReply(fixed24: fw)
    }

    /// The inverse of `handleAllocColor` - since a pixel value already
    /// directly encodes its own RGB (this server chose that encoding, see
    /// above), this just decodes each requested pixel back out rather
    /// than looking anything up in a table that doesn't exist.
    private func handleQueryColors(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // colormap
        var entries: [UInt8] = []
        while r.remaining >= 4 {
            let pixel = r.readU32()
            let ew = X11ByteWriter(littleEndian: littleEndian)
            ew.writeU16(UInt16((pixel >> 16) & 0xFF) * 257) // scale 8-bit -> 16-bit
            ew.writeU16(UInt16((pixel >> 8) & 0xFF) * 257)
            ew.writeU16(UInt16(pixel & 0xFF) * 257)
            ew.writePadding(2)
            entries.append(contentsOf: ew.bytes)
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writePadding(24)
        sendReply(fixed24: fw, extra: entries)
    }

    /// `LookupColor` (92): a colour name to its RGB, from `X11ColorNames`.
    /// Mirrors xorg's `ProcLookupColor`: exact and screen values are the
    /// same (a TrueColor visual represents every colour exactly), and an
    /// unknown name is `BadName`. Emacs aborted on the `BadImplementation`
    /// this used to get.
    private func handleLookupColor(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // colormap - only one exists
        let length = Int(r.readU16())
        r.skip(2)
        let name = String(decoding: r.readBytes(length), as: UTF8.self)
        guard let color = X11ColorNames.lookup(name) else {
            sendError(code: X11ErrorCode.name, badValue: 0, minorOpcode: 0, majorOpcode: X11Opcode.lookupColor)
            return
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(color.red) // exact
        fw.writeU16(color.green)
        fw.writeU16(color.blue)
        fw.writeU16(color.red) // screen
        fw.writeU16(color.green)
        fw.writeU16(color.blue)
        fw.writePadding(12)
        sendReply(fixed24: fw)
    }

    /// `AllocNamedColor` (85): `LookupColor` plus `AllocColor` in one
    /// request, as xorg's `ProcAllocNamedColor` does it. The pixel is
    /// encoded exactly as `handleAllocColor` encodes one, so the same name
    /// and the same RGB always agree.
    private func handleAllocNamedColor(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // colormap
        let length = Int(r.readU16())
        r.skip(2)
        let name = String(decoding: r.readBytes(length), as: UTF8.self)
        guard let color = X11ColorNames.lookup(name) else {
            sendError(code: X11ErrorCode.name, badValue: 0, minorOpcode: 0, majorOpcode: X11Opcode.allocNamedColor)
            return
        }
        let pixel = (UInt32(color.red >> 8) << 16) | (UInt32(color.green >> 8) << 8) | UInt32(color.blue >> 8)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(pixel)
        fw.writeU16(color.red) // exact
        fw.writeU16(color.green)
        fw.writeU16(color.blue)
        fw.writeU16(color.red) // screen
        fw.writeU16(color.green)
        fw.writeU16(color.blue)
        fw.writePadding(8)
        sendReply(fixed24: fw)
    }

    /// `ListInstalledColormaps` - the one request in the colormap family
    /// that DOES expect a reply (`CreateColormap`/`FreeColormap`/
    /// `CopyColormapAndFree`/`InstallColormap`/`UninstallColormap`, wired
    /// as no-ops in `dispatch`, are all fire-and-forget per spec). Always
    /// answers with exactly the one fixed `colormapID` this server ever
    /// advertised (`X11ConnectionSetup`) - there is only ever one
    /// colormap, and it's always "installed."
    private func handleListInstalledColormaps() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(1) // n
        fw.writePadding(22)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU32(colormapID)
        sendReply(fixed24: fw, extra: extra.bytes)
    }

    // MARK: - Drawing requests

    private func handlePolyFillRectangle(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h)))
        }
        DispatchQueue.main.async {
            for rect in rects { target.fillWithColor(color, rect: rect, clip: clip) }
        }
    }

    /// `ClearArea` (opcode 61) - `detail`'s bit 0 is the request's own
    /// `exposures` `BOOL` (the request header's second byte, same slot
    /// `ImageText8`'s own `detail` uses for an unrelated purpose - see
    /// `handleImageText8`), NOT part of `body`. Confirmed live this is
    /// the real mechanism behind a GTK/cairo "renders right for a second,
    /// then blanks again" ghosting symptom (`galculator`'s button labels,
    /// reported live): GTK's incremental-repaint idiom is routinely
    /// `XClearArea(exposures: True)` immediately followed by relying on
    /// the `Expose` event that's supposed to trigger - to redraw its
    /// REAL content (background AND label) back over that area. Per the
    /// X11 spec, when `exposures` is `True` the server MUST generate an
    /// `Expose` for the cleared region regardless of whether anything
    /// was actually obscured (`handleUnmapWindow`'s/`handleConfigureWindow`'s
    /// own Expose-on-uncover fixes only cover the "something else was
    /// drawn over this" case, a different trigger entirely). This
    /// handler used to just clear the pixels and stop there - GTK erased
    /// its own drawing waiting for a repaint cue that this server never
    /// sent, leaving every subsequently-cleared area permanently blank
    /// until an unrelated repaint happened to touch it.
    private func handleClearArea(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let x = r.readI16(); let y = r.readI16()
        let w = r.readU16(); let h = r.readU16()
        guard let record = state.window(wid) else { return }
        let bg = record.backgroundPixel
        // Width/height of 0 means "to the window's current edge" per spec -
        // each dimension independently, not resetting x/y to 0 (the
        // previous code's bug: collapsed to the WHOLE window, discarding
        // x/y, whenever EITHER dimension was 0).
        let fullWidth = w == 0 ? max(0, record.frame.width - Double(x)) : Double(w)
        let fullHeight = h == 0 ? max(0, record.frame.height - Double(y)) : Double(h)
        let requestedRect = CGRect(x: Double(x), y: Double(y), width: fullWidth, height: fullHeight)
        DispatchQueue.main.async { record.view?.fillWithColor(bg, rect: requestedRect) }
        if detail & 0x1 != 0 {
            // `Expose`'s x/y/width/height are all unsigned (`CARD16`) -
            // clip the requested rect to the window's own visible bounds
            // first (`ClearArea`'s x/y are signed, and a real client can
            // legitimately pass a negative origin or a rect extending
            // past the window edge) so this never feeds a negative value
            // into `UInt16(bitPattern:)`, which would wrap to a huge,
            // garbage coordinate instead of clamping.
            let windowBounds = CGRect(x: 0, y: 0, width: record.frame.width, height: record.frame.height)
            let exposedRect = requestedRect.intersection(windowBounds)
            if !exposedRect.isNull, !exposedRect.isEmpty {
                sendExposeEvent(
                    windowID: wid,
                    x: UInt16(clamping: Int(exposedRect.origin.x)),
                    y: UInt16(clamping: Int(exposedRect.origin.y)),
                    width: UInt16(clamping: Int(exposedRect.width)),
                    height: UInt16(clamping: Int(exposedRect.height))
                )
            }
        }
    }

    private func handleCopyArea(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let src = r.readU32()
        let dst = r.readU32()
        let gcId = r.readU32()
        let srcX = r.readI16(); let srcY = r.readI16()
        let dstX = r.readI16(); let dstY = r.readI16()
        let w = r.readU16(); let h = r.readU16()
        guard let srcDrawable = state.drawable(src), let dstDrawable = state.drawable(dst) else { return }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] copyArea gc=\(gcId) src=\(src) dst=\(dst) srcXY=(\(srcX),\(srcY)) dstXY=(\(dstX),\(dstY)) wh=(\(w),\(h)) clipRects=\(String(describing: state.gc(gcId)?.clipRectangles))\n".data(using: .utf8)!)
        }
        // Resolved synchronously, same reasoning as `handleRenderComposite`'s
        // own doc comment on why: reading GC state (or a drawable, by ID)
        // from INSIDE the deferred block below - after other requests may
        // have already run and mutated/removed it - reads whatever the
        // state happens to be LATER, not what it was for THIS request.
        let clipRects = state.gc(gcId)?.clipRectangles
        DispatchQueue.main.async {
            // `CGImage.cropping(to:)` on a `makeImage()` snapshot of THIS
            // server's own `bitmapContext`s addresses the image using the
            // SAME top-left-origin convention `bitmapContext`'s CTM flip
            // already presents for drawing - confirmed live via a targeted
            // A/B dump (`Guest/init/gtk-tests`-style small-region blit:
            // Krita's own single-menu-label `PutImage`-then-`CopyArea`
            // repaint on hover) that cropping at `srcY` DIRECTLY reproduces
            // the correct source content, while the previous
            // `pixelHeight - srcY - h` inversion grabbed a totally
            // unrelated row range instead (off by up to `pixelHeight`,
            // not just a small fencepost). That inversion went unnoticed
            // by every Layer 0-3 test because every `CopyArea` call site
            // in this test suite copies a pixmap's FULL height in one shot
            // (`srcY=0`, `h=pixelHeight`) - the exact case where
            // `pixelHeight - 0 - h` and `0` are numerically identical, so
            // the bug was invisible to full-height copies and only
            // surfaced on a partial, offset-into-the-middle blit like a
            // real toolkit's single-widget backing-store flush. Confirmed
            // live as the actual cause of gui-bugs.md's "text/menu
            // disappearing" symptom: Krita's XCB backend repaints one
            // menu label at a time via exactly this pattern, and the
            // wrong-row crop silently blitted blank background over the
            // correct on-screen text.
            guard let cropped = srcDrawable.bitmapContext.makeImage()?
                .cropping(to: CGRect(x: Double(srcX), y: Double(srcY), width: Double(w), height: Double(h)))
            else { return }
            let dstRect = CGRect(x: Double(dstX), y: Double(dstY), width: Double(w), height: Double(h))
            let ctx = dstDrawable.bitmapContext
            // Confirmed live via real GDK/GTK usage (galculator, after a
            // window resize): GDK's own offscreen-double-buffer flush
            // issues `CopyArea` for the BOUNDING BOX of everything that
            // changed, but clips the GC to just the actual damaged sub-
            // rectangles within that box - GDK does NOT re-render the
            // gaps between them, relying on the clip to leave whatever
            // was already correctly on-screen there untouched. Ignoring
            // the clip (this handler used to skip the GC entirely) let
            // the blit copy the WHOLE bounding box regardless, painting
            // stale pixels from the offscreen buffer's own un-updated
            // gaps directly over correct, already-rendered window
            // content - the ghosting/overlapping-text glitches seen after
            // a resize.
            if let clipRects {
                ctx.saveGState()
                ctx.clip(to: clipRects)
                drawImageTopLeftOriented(cropped, in: dstRect, on: ctx)
                ctx.restoreGState()
            } else {
                drawImageTopLeftOriented(cropped, in: dstRect, on: ctx)
            }
            dstDrawable.notifyChanged()
        }
    }

    private func handleCreatePixmap(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pid = r.readU32()
        r.skip(4) // drawable (depth/screen context) - unused, only the one TrueColor format exists
        let width = Int(r.readU16())
        let height = Int(r.readU16())
        // The header's second byte is the depth. Storage is RGBA whatever it
        // is; it's recorded so GetImage can return alpha for depth 32.
        _ = state.makePixmap(id: pid, width: width, height: height, depth: detail)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] createPixmap id=\(pid) w=\(width) h=\(height) depth=\(detail)\n".data(using: .utf8)!)
        }
    }

    private func handleFreePixmap(body: [UInt8]) {
        state.removePixmap(X11ByteReader(body, littleEndian: littleEndian).readU32())
    }

    /// A depth-1 image as depth-8 coverage, 255 where a bit is set, in rows
    /// of `rowBytes`. `lsbFirst` is the bitmap bit order the connection
    /// setup advertised, which follows the client's byte order. Returns an
    /// empty array for short input, so the caller's length check drops it.
    static func expandBitmap(_ bits: [UInt8], width: Int, height: Int, leftPad: Int, lsbFirst: Bool, rowBytes: Int) -> [UInt8] {
        let bitRowBytes = ((leftPad + width + 31) / 32) * 4
        guard bits.count == bitRowBytes * height else { return [] }
        var coverage = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let bit = leftPad + x
                let byte = bits[y * bitRowBytes + bit / 8]
                let shift = UInt8(lsbFirst ? bit % 8 : 7 - bit % 8)
                if (byte >> shift) & 1 != 0 { coverage[y * rowBytes + x] = 255 }
            }
        }
        return coverage
    }

    /// Confirmed live this is the mechanism this project's own `xterm`
    /// build actually uses to draw its terminal text - Xft/freetype
    /// glyphs rasterized client-side, uploaded as a raw pixel image (a
    /// `CreatePixmap` scratch buffer, then usually `CopyArea`'d onto the
    /// real window - both already `X11Drawable`-generic, see their doc
    /// comments), not the X core-font path (`ImageText8`) `X11FakeFont`
    /// exists for as a fallback. Only `format=2` (ZPixmap) is handled -
    /// the only format a TrueColor-depth client actually sends; `Bitmap`/
    /// `XYPixmap` (1-bit-plane formats) are silently ignored.
    ///
    /// The byte layout this decodes matches `X11ConnectionSetup`'s own
    /// advertised pixmap format exactly (32 bits-per-pixel, LSBFirst when
    /// `littleEndian`, red/green/blue masks `0x00FF0000`/`0x0000FF00`/
    /// `0x000000FF`) - a little-endian 4-byte read of that layout IS this
    /// server's `0x00RRGGBB` pixel convention already, no repacking
    /// needed. `scanline-pad`=32 means each row is already a whole number
    /// of pixels wide with no extra row padding to skip.
    private func handlePutImage(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        // GC's color fields are irrelevant to a raw pixel upload, but its
        // clip IS still spec-relevant (PutImage is a GC-relative drawing
        // request like any other) - kept, not skipped, for that reason.
        let gcId = r.readU32()
        let width = Int(r.readU16())
        let height = Int(r.readU16())
        let dstX = r.readI16()
        let dstY = r.readI16()
        let leftPad = Int(r.readU8()) // only meaningful for a bitmap
        let depth = r.readU8()
        r.skip(2) // unused
        // At depth 1 there is only one plane, so Bitmap (0), XYPixmap (1)
        // and ZPixmap (2) all carry the same bits.
        guard detail == 2 || depth == 1, width > 0, height > 0 else {
            X11Trace.putImage(drawableID: drawableId, width: width, height: height, depth: depth, outcome: "dropped: format/size")
            return
        }
        guard let target = state.drawable(drawableId) else {
            X11Trace.putImage(drawableID: drawableId, width: width, height: height, depth: depth, outcome: "dropped: no target")
            return
        }
        // Only 24/32-bit ZPixmap uploads use this server's one declared
        // TrueColor/ARGB pixmap format (`X11ConnectionSetup`'s "scanline-
        // pad=32, bits-per-pixel=32" for depth 24/32) - but a real client
        // can still `CreatePixmap` at depth 8 (this server's own
        // `handleCreatePixmap` ignores the requested depth and always
        // backs it with a full 32-bit context, so it never rejects the
        // CreatePixmap - it just doesn't remember the 8 was requested)
        // and then `PutImage` into it with genuinely 1-byte-per-pixel
        // data. Confirmed live: GTK/cairo's XRender text path does
        // exactly this for antialiased glyph coverage masks (a `PutImage`
        // straight into an 8-bit pixmap, later wrapped in a `Picture` and
        // used as a `Composite` mask - see `handleRenderComposite`'s
        // `ctx.clip(to:mask:)`, which already treats a plain no-alpha
        // image's LUMINANCE as coverage, exactly matching an 8-bit
        // coverage mask's semantics). Before this handled ONLY the 32bpp
        // case, so every depth-8 upload's byte count (`width*height`,
        // scanline-padded to a 4-byte boundary per X11's own
        // scanline-pad=32 convention - NOT `width*height*4`) failed the
        // `width*height*4` check and got silently dropped outright -
        // confirmed live as why a second/third typed character's glyph
        // mask pixmap stayed blank (a `Composite` using it as `mask`
        // still ran and repainted the target rect, just with nothing
        // in it) even though the app's own state and layout math (the
        // `Composite`'s `dstX` advancing correctly for each new
        // character) were both already correct - not a keyboard-input
        // bug at all, a rendering bug that happened to make correctly-
        // delivered keystrokes LOOK like they weren't registering.
        let bytesPerPixel = (depth == 24 || depth == 32) ? 4 : 1
        let rowBytes = X11Wire.pad(width * bytesPerPixel)
        let expectedBytes = rowBytes * height
        // Depth 1 (cursors, shape masks, stipples) arrives one bit per
        // pixel, rows padded to 32 bits. It is expanded to the depth-8
        // coverage layout below and takes that same path: a set bit is
        // full coverage.
        let pixelBytes = depth == 1
            ? Self.expandBitmap(r.readBytes(((leftPad + width + 31) / 32) * 4 * height), width: width, height: height,
                                leftPad: leftPad, lsbFirst: littleEndian, rowBytes: rowBytes)
            : r.readBytes(expectedBytes)
        guard pixelBytes.count == expectedBytes else {
            X11Trace.putImage(drawableID: drawableId, width: width, height: height, depth: depth, outcome: "dropped: byte mismatch got=\(pixelBytes.count) expected=\(expectedBytes)")
            return
        }
        X11Trace.putImage(drawableID: drawableId, width: width, height: height, depth: depth, outcome: "ok x=\(dstX) y=\(dstY)")
        let isLittleEndian = littleEndian
        let clip = state.gc(gcId)?.clipRectangles
        DispatchQueue.main.async {
            guard let provider = CGDataProvider(data: Data(pixelBytes) as CFData) else { return }
            let image: CGImage?
            if bytesPerPixel == 1 {
                // An 8-bit (A8) upload is pure COVERAGE: 0 = transparent
                // gap, 255 = fully covered. It has to be expanded into a
                // real alpha channel here, NOT left as a no-alpha
                // grayscale image.
                //
                // This used to build a `DeviceGray`/`.none` image and rely
                // on `clip(to:mask:)` reading its LUMINANCE. That is true
                // of a no-alpha gray image in isolation - but the mask
                // handed to `clip(to:mask:)` is never this image. It is
                // the DESTINATION pixmap's own `makeImage()`, and every
                // pixmap here is RGBA premultiplied
                // (`makeFlippedBitmapContext`). Drawing an opaque gray
                // image into it stored coverage in RGB with alpha = 255
                // EVERYWHERE it drew.
                //
                // Measured directly (`CGContextClipToMask`, 4x1 probes):
                //   RGBA alpha=[0,85,170,255] grey=255 -> [0,85,170,170]
                //   RGBA alpha=255 grey=[0,85,170,255] -> [255,255,255,255]
                //   DeviceGray no-alpha  [0,85,170,255] -> [0,85,170,255]
                // So CoreGraphics uses ALPHA whenever the mask image has
                // one, and ignores luminance entirely. An A8 mask built
                // this way therefore read as FULLY OPAQUE, and a solid
                // colour composited through it painted a hard slab where a
                // soft anti-aliased edge belonged.
                //
                // That is `gui-bugs.md` #25 - galculator's "heavy
                // artifacting". Traced end to end: a 1x24 depth-8 gradient
                // tile -> `Trapezoids` into a 37x12 depth-8 mask pixmap ->
                // `Composite(op=Over, src=solid, mask=that pixmap)` at
                // window (212,187). Text was never affected because
                // `CompositeGlyphs` is its own path and does not build
                // masks this way.
                //
                // Coverage goes into alpha, and RGB is premultiplied WHITE
                // (= the coverage value), so the same buffer is correct
                // both as a mask (alpha) and as a source (a white shape
                // with the right alpha) - and, unlike the old opaque gray,
                // it composites correctly instead of painting flat gray.
                //
                // ONLY for a PIXMAP destination, though. Core `PutImage`
                // is a raw pixel REPLACE, not a composite, so depth-8
                // bytes written straight onto a WINDOW are visible
                // grayscale CONTENT and must stay opaque - that is what
                // `Guest/init/x11-tests/03_pixmap_putimage.c` Part 3
                // asserts (a black-to-white diagonal ramp), and it broke
                // outright when this path started emitting coverage-alpha
                // for every destination: premultiplied white at alpha `c`
                // replaced the black fill underneath and rendered as flat
                // white. An offscreen pixmap is the RENDER-mask case (a
                // depth-8 pixmap can't legally be `CopyArea`d onto a
                // depth-24 window anyway - that is a `BadMatch` in real
                // X11), so the destination cleanly separates the two.
                let coverageInAlpha = target is X11Pixmap
                var rgba = [UInt8](repeating: 0, count: width * height * 4)
                pixelBytes.withUnsafeBufferPointer { src in
                    for y in 0..<height {
                        let rowStart = y * rowBytes
                        for x in 0..<width {
                            let c = src[rowStart + x]
                            let o = (y * width + x) * 4
                            rgba[o] = c; rgba[o + 1] = c; rgba[o + 2] = c
                            rgba[o + 3] = coverageInAlpha ? c : 255
                        }
                    }
                }
                image = CGDataProvider(data: Data(rgba) as CFData).flatMap {
                    CGImage(
                        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: x11DeviceRGB,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                    )
                }
            } else {
                // depth 32 (the ARGB visual - see `argbVisualID`'s doc
                // comment) carries real, meaningful, PREMULTIPLIED alpha
                // from cairo's ARGB32 image surfaces (anti-aliased glyph/
                // shape coverage, transparent margins around rounded
                // widget corners, ...): the stored RGB bytes are already
                // scaled by alpha, so a mostly-transparent pixel's RGB is
                // near-zero. Forcing that opaque (the old, unconditional
                // `.noneSkipFirst`) discarded alpha and left those
                // near-zero-RGB "transparent" areas rendered as solid
                // BLACK - confirmed live as the exact cause of galculator's
                // black-window regions post-ARGB-visual. depth 24 has no
                // real alpha byte (just padding) and must stay
                // `.noneSkipFirst`, unchanged from before.
                let alphaInfo: CGImageAlphaInfo = depth == 32 ? .premultipliedFirst : .noneSkipFirst
                let byteOrder: CGBitmapInfo = isLittleEndian ? .byteOrder32Little : .byteOrder32Big
                let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue | byteOrder.rawValue)
                image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                )
            }
            guard let image else { return }
            // See `drawImageTopLeftOriented`'s doc comment - a plain
            // `ctx.draw(image, in:)` here would place this upload's row 0
            // at the VISUAL BOTTOM of the rect, not the top (confirmed
            // live via `Guest/init/cairo-tests/99_flip_diag.c`: this went
            // unnoticed all session because every prior `PutImage` test
            // also happened to go through exactly one `CopyArea`, itself
            // carrying the identical extra flip, and two of them cancel).
            withClip(clip, on: target.bitmapContext) {
                drawImageTopLeftOriented(image, in: CGRect(x: Double(dstX), y: Double(dstY), width: Double(width), height: Double(height)), on: target.bitmapContext)
            }
            target.notifyChanged()
        }
    }

    /// `GetImage` (core opcode 73) - the read-back counterpart to
    /// `PutImage`, previously completely unhandled (confirmed live as a
    /// real `BadImplementation` crash for `gpick`, a GTK color-picker
    /// app: its whole reason to exist is sampling real on-screen pixel
    /// colors, which is exactly what this request is for). Only
    /// `format=2` (`ZPixmap`) is answered with real data - the only
    /// format any modern toolkit actually sends (matches `handlePutImage`
    /// only ever accepting `detail == 2` on the write side); `XYPixmap`
    /// gets an honest error rather than a silently-wrong reply, since
    /// producing real bitplane-separated data is a materially different
    /// job this server has no other reason to implement yet.
    ///
    /// Reads directly out of the drawable's OWN `bitmapContext` (the
    /// exact same backing store `notifyChanged`'s snapshot dump reads),
    /// not a fresh render - whatever this server would show on screen
    /// right now is exactly what a real client should read back.
    ///
    /// Raw buffer row = X11 row DIRECTLY, no flip needed - confirmed
    /// empirically (a temporary full-buffer byte scan, not re-derived
    /// from CTM theory, given this exact class of flip bug has bitten
    /// this file more than once already): a pixel `PutImage`'d at X11
    /// window coordinate (24,19) landed at raw buffer (row=19,col=24).
    /// The naive assumption - that `.data`'s memory is CoreGraphics'
    /// usual bottom-up layout, needing a `(pixelHeight - 1 - y)`
    /// inversion to reach from top-left-origin X11 coordinates - is
    /// WRONG for this particular context: `makeFlippedBitmapContext`'s
    /// CTM flip plus `drawImageTopLeftOriented`'s own extra counter-flip
    /// (needed to cancel `CGContext.draw`'s built-in image flip - see
    /// that function's own doc comment) combine to leave the RAW MEMORY
    /// itself already top-down, not just the drawing-time coordinate
    /// system. Output format matches `handlePutImage`'s own depth-24
    /// ZPixmap convention exactly (BGR + 1 pad byte per pixel, little-
    /// endian) - anything written by a real `PutImage` and read back via
    /// `GetImage` round-trips byte-for-byte (regression test:
    /// `x11-tests/09_getimage_roundtrip.c`).
    private func handleGetImage(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let x = Int(r.readI16())
        let y = Int(r.readI16())
        let width = Int(r.readU16())
        let height = Int(r.readU16())
        // planemask (4 bytes) - unused, this server has no notion of a
        // partial-plane read; every GetImage answers with all planes.

        guard detail == 2 else {
            sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: 0, majorOpcode: X11Opcode.getImage)
            return
        }
        guard width > 0, height > 0, let target = state.drawable(drawableId) else {
            // Still a REPLY, not silence - a missing/zero-size source is
            // reported as an all-black image of the requested size rather
            // than hanging the client (same "always answer" policy
            // `handleGetGeometry` already uses for a missing window).
            let fw = X11ByteWriter(littleEndian: littleEndian)
            fw.writeU32(0) // visual = None
            fw.writePadding(20)
            let blackBytes = [UInt8](repeating: 0, count: X11Wire.pad(max(width, 0) * 4) * max(height, 0))
            sendReply(fixed24: fw, extra: blackBytes, detail: 24)
            return
        }

        // A depth-32 pixmap is ARGB: its fourth byte is alpha, not pad. See
        // `zPixmapBytes` for the GTK3 popover-menu bug this was.
        let depth: UInt8 = (target as? X11Pixmap)?.depth == 32 ? 32 : 24
        let pixels = Self.zPixmapBytes(from: target.bitmapContext, sourceWidth: target.pixelWidth, sourceHeight: target.pixelHeight,
                                       x: x, y: y, width: width, height: height, includeAlpha: depth == 32)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(0) // visual - None, matches this server's other Pixmap/Window-agnostic replies
        fw.writePadding(20)
        sendReply(fixed24: fw, extra: pixels, detail: depth) // detail: depth
    }

    /// ZPixmap bytes (32 bits per pixel, B G R X) for a region of a
    /// drawable's `premultipliedLast` RGBA backing store (see
    /// `makeFlippedBitmapContext`); the raw buffer row is the X11 row. The
    /// fourth byte is the pad for a depth-24 image and the premultiplied
    /// ALPHA for a depth-32 (ARGB) one.
    ///
    /// It used to be 0 for both. GTK3 builds a popover's shape by drawing
    /// its outline into a depth-32 surface
    /// (`gdk_window_create_similar_surface`) and reading it back with
    /// GetImage (`gdk_cairo_region_create_from_surface`). Zero alpha
    /// everywhere gave an EMPTY shape, so GDK's hit test never picked the
    /// popover: every click in a popover menu went to the window underneath,
    /// the menu closed, and no item ever activated (gtk3-widget-factory's
    /// hamburger menu, 2026-09-15).
    static func zPixmapBytes(from ctx: CGContext, sourceWidth: Int, sourceHeight: Int,
                             x: Int, y: Int, width: Int, height: Int, includeAlpha: Bool) -> [UInt8] {
        let rowBytes = X11Wire.pad(width * 4)
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        guard let base = ctx.data else { return pixels }
        let srcBytesPerRow = ctx.bytesPerRow
        let srcPtr = base.bindMemory(to: UInt8.self, capacity: srcBytesPerRow * sourceHeight)
        for row in 0..<height {
            let srcY = y + row
            guard srcY >= 0, srcY < sourceHeight else { continue }
            let srcRowStart = srcY * srcBytesPerRow
            for col in 0..<width {
                let srcX = x + col
                guard srcX >= 0, srcX < sourceWidth else { continue }
                let srcOffset = srcRowStart + srcX * 4
                let dstOffset = row * rowBytes + col * 4
                pixels[dstOffset + 0] = srcPtr[srcOffset + 2] // B
                pixels[dstOffset + 1] = srcPtr[srcOffset + 1] // G
                pixels[dstOffset + 2] = srcPtr[srcOffset + 0] // R
                pixels[dstOffset + 3] = includeAlpha ? srcPtr[srcOffset + 3] : 0 // A (depth 32) or pad
            }
        }
        return pixels
    }

    private func handlePolyLine(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var points: [CGPoint] = []
        var last = CGPoint.zero
        while r.remaining >= 4 {
            let x = r.readI16(); let y = r.readI16()
            // CoordModePrevious (detail=1): every point after the first is
            // a delta from the last one, not an absolute coordinate.
            let point = (detail == 1 && !points.isEmpty)
                ? CGPoint(x: last.x + Double(x), y: last.y + Double(y))
                : CGPoint(x: Double(x), y: Double(y))
            points.append(point)
            last = point
        }
        guard points.count >= 2 else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setStrokeColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.setLineWidth(1)
            ctx.beginPath()
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    /// `PolyPoint` (opcode 64, `XDrawPoints`): one pixel per point in the
    /// GC foreground. Tk draws with it; BadImplementation killed IDLE.
    private func handlePolyPoint(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var points: [CGPoint] = []
        var last = CGPoint.zero
        while r.remaining >= 4 {
            let x = r.readI16(); let y = r.readI16()
            // CoordModePrevious (detail=1), as in PolyLine.
            let point = (detail == 1 && !points.isEmpty)
                ? CGPoint(x: last.x + Double(x), y: last.y + Double(y))
                : CGPoint(x: Double(x), y: Double(y))
            points.append(point)
            last = point
        }
        guard !points.isEmpty else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setFillColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.fill(points.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) })
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    /// `PolyRectangle` (opcode 67 - a real client's `XDrawRectangle`/
    /// `XDrawRectangles`, the UNFILLED counterpart to `PolyFillRectangle`).
    /// Wire layout is `RECTANGLE`s (x, y, width, height - 8 bytes each),
    /// not `ARC`s - do not fold this into `handlePolyArc`'s parsing even
    /// though the two opcodes are adjacent; see `X11Opcode.polyRectangle`'s
    /// doc comment for the confusion this fixed.
    private func handlePolyRectangle(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h)))
        }
        guard !rects.isEmpty else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setStrokeColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.setLineWidth(1)
            for rect in rects { ctx.stroke(rect) }
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    private func handlePolySegment(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var segments: [(CGPoint, CGPoint)] = []
        while r.remaining >= 8 {
            let x1 = r.readI16(); let y1 = r.readI16()
            let x2 = r.readI16(); let y2 = r.readI16()
            segments.append((CGPoint(x: Double(x1), y: Double(y1)), CGPoint(x: Double(x2), y: Double(y2))))
        }
        guard !segments.isEmpty else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setStrokeColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.setLineWidth(1)
            ctx.beginPath()
            for (p1, p2) in segments {
                ctx.move(to: p1)
                ctx.addLine(to: p2)
            }
            ctx.strokePath()
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    /// Shared by `PolyArc`/`PolyFillArc` - chord-approximates an X11 arc
    /// into a polyline, one point per subdivision step. `angle1`/`angle2`
    /// are X11's own units (64ths of a degree; `angle1` measured from the
    /// +x axis, `angle2` a signed sweep) - deliberately NOT handed to
    /// `CGContext.addArc`'s `clockwise` flag, whose sign convention under
    /// this context's already-flipped CTM (see `flipContextToTopLeftOrigin`)
    /// is easy to get backwards. Manually walking the same
    /// `x = cx + rx·cos(θ), y = cy − ry·sin(θ)` formula real X server
    /// implementations use (cross-checked against a from-scratch X11
    /// server's own arc rasterizer, itself verified against Xorg's
    /// `XDrawArc` test suite) removes that ambiguity entirely - the minus
    /// sign on the y term is what makes a positive (mathematically
    /// counterclockwise) sweep come out visually clockwise once this
    /// context's flipped CTM renders it, matching every real X server.
    private static func arcPolylinePoints(x: Int16, y: Int16, width: UInt16, height: UInt16, angle1: Int16, angle2: Int16) -> [CGPoint] {
        let cx = Double(x) + Double(width) / 2
        let cy = Double(y) + Double(height) / 2
        let rx = Double(width) / 2
        let ry = Double(height) / 2
        guard rx > 0, ry > 0 else { return [] }
        let start = Double(angle1) / 64 * .pi / 180
        let sweep = Double(angle2) / 64 * .pi / 180
        let r = max(rx, ry, 1)
        let dtheta = min(max(2 / r.squareRoot(), 0.001), .pi / 8)
        let steps = max(Int((abs(sweep) / dtheta).rounded(.up)), 1)
        let step = sweep / Double(steps)
        return (0...steps).map { i in
            let theta = start + step * Double(i)
            return CGPoint(x: cx + rx * cos(theta), y: cy - ry * sin(theta))
        }
    }

    private func handlePolyArc(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var paths: [[CGPoint]] = []
        while r.remaining >= 12 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            let a1 = r.readI16(); let a2 = r.readI16()
            let pts = Self.arcPolylinePoints(x: x, y: y, width: w, height: h, angle1: a1, angle2: a2)
            if pts.count >= 2 { paths.append(pts) }
        }
        guard !paths.isEmpty else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setStrokeColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.setLineWidth(1)
            for pts in paths {
                ctx.beginPath()
                ctx.move(to: pts[0])
                for point in pts.dropFirst() { ctx.addLine(to: point) }
                ctx.strokePath()
            }
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    /// `Chord` closure only (arc endpoints joined directly, no centre
    /// vertex) - X11's default `arc-mode` and, in practice, the only mode
    /// that matters for a full circle/ellipse (`PieSlice` vs. `Chord` are
    /// visually identical once `angle2` covers a full 360°, which is what
    /// `xeyes`-style filled circles use). `ArcMode` isn't tracked per-GC
    /// anywhere else in this skeleton, so `PieSlice`'s wedge-to-centre
    /// behavior for a genuine partial arc isn't implemented yet.
    private func handlePolyFillArc(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var polygons: [[CGPoint]] = []
        while r.remaining >= 12 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            let a1 = r.readI16(); let a2 = r.readI16()
            let pts = Self.arcPolylinePoints(x: x, y: y, width: w, height: h, angle1: a1, angle2: a2)
            if pts.count >= 3 { polygons.append(pts) }
        }
        guard !polygons.isEmpty else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setFillColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            for pts in polygons {
                ctx.beginPath()
                ctx.move(to: pts[0])
                for point in pts.dropFirst() { ctx.addLine(to: point) }
                ctx.closePath()
                ctx.fillPath()
            }
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    private func handleFillPoly(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawableId = r.readU32()
        let gcId = r.readU32()
        _ = r.readU8() // shape - fill algorithm hint only, no correctness difference here
        let coordMode = r.readU8() // 1 = CoordModePrevious
        _ = r.readU16() // unused
        guard let target = state.drawable(drawableId) else { return }
        let color = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var points: [CGPoint] = []
        var last = CGPoint.zero
        while r.remaining >= 4 {
            let x = r.readI16(); let y = r.readI16()
            let point = (coordMode == 1 && !points.isEmpty)
                ? CGPoint(x: last.x + Double(x), y: last.y + Double(y))
                : CGPoint(x: Double(x), y: Double(y))
            points.append(point)
            last = point
        }
        guard points.count >= 3 else { return }
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setFillColor(x11Color(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255, blue: CGFloat(color & 0xFF) / 255))
            ctx.beginPath()
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    private func handleImageText8(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawable = r.readU32()
        let gcId = r.readU32()
        let x = r.readI16()
        let y = r.readI16()
        let n = Int(detail) // string length, per the request's own header layout
        let bytes = r.readBytes(n)
        guard let target = state.drawable(drawable) else { return }
        let gc = state.gc(gcId)
        let text = X11CoreText.decode(bytes, symbolFont: state.isSymbolFont(gc?.font ?? 0))
        let foreground = gc?.foreground ?? 0x0000_0000
        let background = gc?.background ?? state.window(drawable)?.backgroundPixel ?? 0x00FF_FFFF
        let clip = gc?.clipRectangles
        DispatchQueue.main.async {
            target.drawText(text, x: x, y: y, foreground: foreground, background: background, clip: clip)
        }
    }

    /// A simplified `TEXTITEM8` parser - only plain string items (a CARD8
    /// length, an INT8 delta-x, then that many STRING8 bytes) advance the
    /// pen and draw; a `FONT` item (length byte `255` + a 4-byte font ID)
    /// is skipped rather than switched to, since every "font" this server
    /// has is the same one anyway (see `X11FakeFont`). `PolyText8` draws
    /// transparently (no background fill), unlike `ImageText8`.
    private func handlePolyText8(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let drawable = r.readU32()
        let gcId = r.readU32()
        let x = r.readI16()
        var penX = Int32(x)
        let y = r.readI16()
        guard let target = state.drawable(drawable) else { return }
        let foreground = state.gc(gcId)?.foreground ?? 0x0000_0000
        let clip = state.gc(gcId)?.clipRectangles
        var symbolFont = state.isSymbolFont(state.gc(gcId)?.font ?? 0)
        while r.remaining > 0 {
            let len = r.readU8()
            if len == 0 { break }
            if len == 255 {
                // Font-shift item: the FONT is always MSB-first on the
                // wire, whatever the connection's byte order. Metrics stay
                // `X11FakeFont`'s; only the byte mapping follows it.
                guard r.remaining >= 4 else { break }
                let b = r.readBytes(4)
                let fid = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                state.gc(gcId)?.font = fid
                symbolFont = state.isSymbolFont(fid)
                continue
            }
            let deltaX = Int32(Int8(bitPattern: r.readU8()))
            let text = X11CoreText.decode(r.readBytes(Int(len)), symbolFont: symbolFont)
            penX += deltaX
            let drawX = penX
            DispatchQueue.main.async {
                target.drawText(text, x: Int16(clamping: drawX), y: y, foreground: foreground, background: nil, clip: clip)
            }
            penX += Int32(len) * Int32(X11FakeFont.charWidth)
        }
    }

    // MARK: - Atoms and properties

    private func handleInternAtom(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let nameLen = Int(r.readU16())
        r.skip(2)
        let name = r.readString8(nameLen)
        let atom = state.internAtom(name, onlyIfExists: detail != 0)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(atom)
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    // MARK: - Selections
    //
    // Real X11 copy/paste (`xterm`'s own mouse-drag-select, then
    // middle-click or Cmd+V-equivalent paste very much included) runs
    // entirely through these four requests - no clipboard DATA is ever
    // stored server-side, only which window currently OWNS a selection
    // atom (`SetSelectionOwner`/`GetSelectionOwner`); `ConvertSelection`
    // then asks that owner - via a `SelectionRequest` EVENT, the first
    // place this server needs to deliver an event to a DIFFERENT
    // client's connection, not just reply to whoever's asking (see
    // `X11State.connection(forWindow:)`) - to actually produce the data,
    // on demand, by writing it into a property and sending `SelectionNotify`
    // back (via `SendEvent`, generic enough to carry that AND other
    // window-manager-style synthetic events this server doesn't
    // special-case itself).

    private func handleSetSelectionOwner(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let owner = r.readU32()
        let selection = r.readU32()
        state.setSelectionOwner(selection, owner: owner)
    }

    private func handleGetSelectionOwner(body: [UInt8]) {
        let selection = X11ByteReader(body, littleEndian: littleEndian).readU32()
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(state.selectionOwner(selection))
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    private func handleConvertSelection(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let requestor = r.readU32()
        let selection = r.readU32()
        let target = r.readU32()
        let property = r.readU32()

        let owner = state.selectionOwner(selection)
        guard owner != 0, let ownerConnection = state.connection(forWindow: owner) else {
            // No owner (or its connection is already gone) - ICCCM says
            // to notify with `property = None` rather than leave the
            // requestor waiting forever for a response that isn't coming.
            sendSelectionNotify(requestor: requestor, selection: selection, target: target, property: 0)
            return
        }
        ownerConnection.sendSelectionRequest(owner: owner, requestor: requestor, selection: selection, target: target, property: property)
    }

    /// Generic synthetic-event delivery - real clients use this for the
    /// second half of the selection handshake (the owner, after writing
    /// the converted data into `property` via `ChangeProperty`, sends
    /// itself a `SelectionNotify` addressed to the REQUESTOR through
    /// here) and for other WM-facing conventions (`_NET_WM_STATE`
    /// changes, etc.) this server doesn't need to understand the
    /// contents of to relay correctly. `destination` values `0`/`1`
    /// (`PointerWindow`/`InputFocus`) aren't resolved to a real window -
    /// an edge case no client in this project's actual test coverage
    /// relies on.
    private func handleSendEvent(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let destination = r.readU32()
        r.skip(4) // event-mask - propagation-by-mask isn't implemented; delivered directly to `destination` only
        let event = r.readBytes(32)
        // Root-targeted `SendEvent`s (`destination == rootWindowID`) are
        // EWMH client requests meant for a WINDOW MANAGER selecting
        // SubstructureRedirect on root (`_NET_WM_STATE`, `_NET_ACTIVE_
        // WINDOW`, ...) - never for the sender to receive back. Confirmed
        // live this matters, not just spec-purity: `rootWindowID` is a
        // per-connection synthetic ID (see its own doc comment) that
        // resolves right back to the SAME client that just sent it, so
        // without this guard a client's own outgoing WM request (`
        // galculator` unhiding itself via `_NET_WM_STATE_REMOVE`/
        // `_NET_WM_STATE_HIDDEN` was the case that caught this) gets
        // echoed straight back as an unexpected incoming event - GDK has
        // no handler for receiving its own WM-directed request and exits
        // outright. No real WM is ever running here to actually act on
        // these, so dropping them is the correct degraded behavior, not
        // a workaround for a case that should otherwise be handled.
        guard destination != rootWindowID, destination > 1,
              let destConnection = state.connection(forWindow: destination) else { return }
        destConnection.deliverEvent(event)
    }

    private func handleGetAtomName(body: [UInt8]) {
        let atom = X11ByteReader(body, littleEndian: littleEndian).readU32()
        let name = state.atomName(atom) ?? ""
        let nameBytes = Array(name.utf8)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(UInt16(nameBytes.count))
        fw.writePadding(22)
        sendReply(fixed24: fw, extra: padded(nameBytes))
    }

    private func handleChangeProperty(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let property = r.readU32()
        let type = r.readU32()
        let format = r.readU8()
        r.skip(3)
        let dataLenUnits = Int(r.readU32())
        let unitBytes = format == 32 ? 4 : (format == 16 ? 2 : 1)
        let data = r.readBytes(dataLenUnits * unitBytes)
        // `mode` (Replace/Prepend/Append, the request's detail byte) is
        // always treated as Replace - a known simplification; almost
        // every real-world caller (window titles, WM_PROTOCOLS, ...) uses
        // Replace anyway.
        guard let record = state.window(wid) else { return }
        record.properties[property] = (type: type, format: format, data: data)
        if property == wmNormalHintsAtom, format == 32 {
            applyWMNormalHints(data, to: record)
        }
        if property == wmNameAtom || property == netWMNameAtom {
            applyWindowTitle(to: record)
        }
        if property == netWMIconAtom, format == 32 {
            applyWindowIcon(data, to: record)
        }
        if property == Self.wmClassAtom {
            applyAppName(data, to: record)
        }
        sendPropertyNotify(record, atom: property, state: 0) // 0 = NewValue
    }

    /// `WM_NAME` is a predefined atom (39, ICCCM's Latin-1 title);
    /// `_NET_WM_NAME` is EWMH's UTF-8 replacement and takes precedence
    /// wherever both are set, which for GTK and Qt is always.
    private var wmNameAtom: UInt32 { 39 }
    private lazy var netWMNameAtom: UInt32 = state.internAtom("_NET_WM_NAME", onlyIfExists: false)

    /// Puts the client's own title on the `NSWindow`.
    ///
    /// Every window this server has ever shown was titled the literal
    /// placeholder "X11 Window" - confirmed live 2026-09-06 with five
    /// windows on screen from three different apps, all identically
    /// labelled, which is also what made them impossible to tell apart in
    /// `System Events`/`CGWindowList` when driving them from a test
    /// script. Titles were not "unimplemented" so much as unreachable:
    /// this needs the PREDEFINED atom numbers, which the atom table did
    /// not have until the same day (see `X11State.predefinedAtomNames`).
    ///
    /// Recomputed from the record's stored properties on every change
    /// rather than tracked incrementally, so `_NET_WM_NAME` keeps winning
    /// no matter which of the two the client updates last.
    private lazy var netWMIconAtom: UInt32 = state.internAtom("_NET_WM_ICON", onlyIfExists: false)
    /// Predefined atom 67 - see `X11State.predefinedAtomNames`.
    private static let wmClassAtom: UInt32 = 67

    /// `_NET_WM_ICON` -> the window's Dock/minimized icon.
    ///
    /// Decoding runs on this connection's own thread (it is a few hundred
    /// KB of pixel work for a large icon, and happens once per window, not
    /// per paint); only the `NSWindow`/`NSApp` handoff hops to main.
    private func applyWindowIcon(_ data: [UInt8], to record: X11State.WindowRecord) {
        guard record.isTopLevel, !record.overrideRedirect else { return }
        guard let icon = X11WindowIcon.decode(data, littleEndian: littleEndian) else {
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] icon wid=\(record.id) UNDECODABLE bytes=\(data.count)\n".data(using: .utf8)!)
            }
            return
        }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] icon wid=\(record.id) decoded \(Int(icon.size.width))x\(Int(icon.size.height)) from \(data.count) bytes\n".data(using: .utf8)!)
        }
        record.iconImage = icon
        X11WindowIcon.dumpForDebug(icon, windowID: record.id)
        DispatchQueue.main.async {
            guard let window = record.nsWindow else { return }
            X11DockIntegration.shared.setIcon(icon, forWindow: record.id, window: window)
        }
    }

    /// `WM_CLASS` is two NUL-terminated STRING8s back to back:
    /// `instance\0class\0`. The CLASS (second) is the conventional app
    /// name - "Gtk4-demo", "Krita" - and it is stable across whatever
    /// document the window happens to have open, which is exactly what the
    /// menu bar and Dock menu want and what `WM_NAME` is not.
    private func applyAppName(_ data: [UInt8], to record: X11State.WindowRecord) {
        guard record.isTopLevel else { return }
        let parts = data.split(separator: 0, omittingEmptySubsequences: true).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard let name = parts.count >= 2 ? parts[1] : parts.first, !name.isEmpty else { return }
        record.appName = name
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] wmClass wid=\(record.id) parts=\(parts) -> \(name)\n".data(using: .utf8)!)
        }
        DispatchQueue.main.async {
            X11DockIntegration.shared.setAppName(name, forWindow: record.id)
        }
    }

    private func applyWindowTitle(to record: X11State.WindowRecord) {
        guard record.isTopLevel, !record.overrideRedirect else { return }
        let raw = record.properties[netWMNameAtom]?.data ?? record.properties[wmNameAtom]?.data
        // Clients terminate these strings with a NUL as often as not; a
        // trailing one becomes a visible box in an AppKit title bar.
        guard var bytes = raw else { return }
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return }
        // `_NET_WM_NAME` is UTF8_STRING, `WM_NAME` is Latin-1 STRING -
        // try UTF-8 first so the common case is exact, and fall back
        // rather than dropping a title that is merely not valid UTF-8.
        guard let title = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1), !title.isEmpty
        else { return }
        DispatchQueue.main.async {
            record.nsWindow?.title = title
            // What the Dock shows under a minimized window - AppKit does
            // NOT derive it from `title` after the fact, only at minimize
            // time, so set it alongside.
            record.nsWindow?.miniwindowTitle = title
        }
    }

    /// `WM_NORMAL_HINTS` (ICCCM 4.1.2.3) - real GTK/Qt apps set this
    /// (usually right after `CreateWindow`, before mapping) to tell a
    /// real window manager the smallest/largest sensible size for this
    /// window; a real WM enforces it so the user can't drag-resize a
    /// window into a broken, clipped layout. This server had NO window-
    /// manager-level sizing policy at all before this (`gui-bugs.md`'s
    /// "better initial window sizing" ask) - applying `min`/`max` here
    /// via `NSWindow.contentMinSize`/`contentMaxSize` is the missing
    /// piece: AppKit itself then enforces the constraint on every future
    /// drag-resize automatically, no per-resize checking needed on this
    /// server's own side.
    private lazy var wmNormalHintsAtom: UInt32 = state.internAtom("WM_NORMAL_HINTS", onlyIfExists: false)

    /// Wire layout (18 `CARD32`s, ICCCM's `xPropSizeHints`): `flags`,
    /// then 4 obsolete/padding units (`x`/`y`/`width`/`height` - long
    /// superseded by the request's own geometry), `min_width`,
    /// `min_height`, `max_width`, `max_height`, then resize-increment/
    /// aspect-ratio/base-size/win-gravity fields this server doesn't act
    /// on (resize increments matter mainly for terminal emulators
    /// snapping to whole character cells - a real gap, but a smaller,
    /// separate one from "can the window be resized into garbage at
    /// all").
    private func applyWMNormalHints(_ data: [UInt8], to record: X11State.WindowRecord) {
        let r = X11ByteReader(data, littleEndian: littleEndian)
        let flags = r.readU32()
        r.skip(16) // x, y, width, height - obsolete
        let minWidth = r.readU32()
        let minHeight = r.readU32()
        let maxWidth = r.readU32()
        let maxHeight = r.readU32()
        let hasMin = flags & 0x10 != 0 // PMinSize
        let hasMax = flags & 0x20 != 0 // PMaxSize
        X11Trace.normalHints(windowID: record.id, flags: flags, minW: minWidth, minH: minHeight, maxW: maxWidth, maxH: maxHeight)
        DispatchQueue.main.async {
            guard let window = record.nsWindow else { return }
            if hasMin, minWidth > 0, minHeight > 0 {
                window.contentMinSize = NSSize(width: CGFloat(minWidth), height: CGFloat(minHeight))
            }
            if hasMax, maxWidth > 0, maxHeight > 0 {
                // `0x7FFFFFFF` ("no real maximum") is a real, common value
                // real clients send here - `CGFloat`/`NSSize` handle it
                // fine as "effectively unbounded", no special-casing
                // needed.
                window.contentMaxSize = NSSize(width: CGFloat(maxWidth), height: CGFloat(maxHeight))
            }
        }
    }

    private func handleGetProperty(detail: UInt8, body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let property = r.readU32()
        r.skip(4) // requested type - ignored, this always returns whatever's actually stored
        r.skip(4) // long-offset - ignored, always returns from the start (simplification)
        let longLength = r.readU32()
        let deleteFlag = detail != 0
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] getProperty wid=\(wid) rootWindowID=\(rootWindowID) property=\(property) name=\(state.atomName(property) ?? "?")\n".data(using: .utf8)!)
        }

        var replyType: UInt32 = 0
        var replyFormat: UInt8 = 0
        var value: [UInt8] = []
        // REVERTED 2026-09-04: this used to also synthesize `_NET_
        // SUPPORTING_WM_CHECK`/`_NET_ACTIVE_WINDOW`/`_NET_SUPPORTED`/
        // `_NET_WORKAREA` on root while chasing Krita's `QMenuBar` not
        // opening on click. It didn't fix that (Qt's own trace never
        // even asked for `_NET_ACTIVE_WINDOW`), and - caught only once
        // the user reported galculator's buttons had gone from fully
        // rendering to a near-blank grid with a `GTK_IS_STYLE_CONTEXT`
        // assertion failure - it very likely CAUSED a real regression:
        // `_NET_SUPPORTED` advertised `_NET_WM_STATE`/`_NET_WM_NAME` as
        // supported when this server answers neither, and `_NET_WORKAREA`
        // ignored that EWMH defines it as 4 CARDINALs PER DESKTOP (this
        // server never answers `_NET_NUMBER_OF_DESKTOPS` at all) - GTK's
        // `GdkScreen` init reads exactly these atoms at startup, before
        // any widget exists, which lines up with a first-paint failure
        // far better than the "broken guest theme engine" theory this
        // was initially (wrongly - the user was right to push back)
        // written off as. Before this existed, GTK saw "no EWMH WM at
        // all" and took its own clean, well-exercised fallback path; a
        // WM that claims support and then lies has no such fallback.
        // Reverted rather than fixed narrower, since it never achieved
        // its actual goal (the menu bug) and this server has no real use
        // for claiming EWMH WM presence otherwise.
        if let record = state.window(wid), let prop = record.properties[property] {
            replyType = prop.type
            replyFormat = prop.format
            value = Array(prop.data.prefix(Int(longLength) * 4))
            if deleteFlag { record.properties.removeValue(forKey: property) }
        }
        let unitBytes = replyFormat == 32 ? 4 : (replyFormat == 16 ? 2 : 1)
        let unitCount = replyFormat == 0 ? 0 : value.count / unitBytes

        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(replyType)
        fw.writeU32(0) // bytes-after - always 0 (this skeleton never returns a partial value)
        fw.writeU32(UInt32(unitCount))
        fw.writePadding(12)
        sendReply(fixed24: fw, extra: padded(value), detail: replyFormat)
    }

    private func handleDeleteProperty(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let property = r.readU32()
        guard let record = state.window(wid) else { return }
        record.properties.removeValue(forKey: property)
        sendPropertyNotify(record, atom: property, state: 1) // 1 = Deleted
    }

    // MARK: - Misc

    private func handleQueryExtension(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let nameLen = Int(r.readU16())
        _ = r.readU16() // unused
        let name = r.readString8(nameLen)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        if name == "RENDER" {
            fw.writeU8(1) // present = True
            fw.writeU8(X11Opcode.renderExtension)
            fw.writeU8(0) // first-event - RENDER defines none this server generates
            fw.writeU8(0) // first-error - no RENDER-specific errors implemented; never actually emitted
        } else if name == "BIG-REQUESTS" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.bigRequestsExtension)
            fw.writeU8(0)
            fw.writeU8(0)
        } else if name == "XInputExtension" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.xinputExtension)
            // XI2 events ride core `GenericEvent` (35), but libXi still
            // registers XInput-1 converters for 17 codes from this base -
            // 0 hijacked core Expose/Key/Button events. See
            // `X11ExtensionBase`.
            fw.writeU8(X11ExtensionBase.xinputFirstEvent)
            fw.writeU8(X11ExtensionBase.xinputFirstError)
        } else if name == "XKEYBOARD" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.xkbExtension)
            // A real (nonzero) event base: confirmed live that
            // `first-event=0` here made `libX11`'s `XkbQueryExtension()`
            // retry `XkbUseExtension` a few times and then quietly give
            // up (GDK fell straight back to its legacy non-XKB path -
            // this whole extension existing for it - without ever
            // calling `XkbGetMap` at all). `0` likely reads as "no event
            // registered" / not-really-present to that client-side check.
            // Now that this server DOES send a real XKB event
            // (`sendXkbStateNotify`), this is also the actual value that
            // event's `type` byte uses - `XKBEventCode.eventBase`.
            fw.writeU8(XKBEventCode.eventBase)
            fw.writeU8(0)
        } else if name == "RANDR" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.randrExtension)
            // This server never sends `RRScreenChangeNotify`/`RRNotify`
            // (geometry is fixed for the life of a connection) - the
            // event-base value doesn't matter to any client that isn't
            // actually watching for those, which is every client that
            // only wants monitor/DPI info at startup.
            fw.writeU8(0)
            fw.writeU8(0)
        } else if name == "XC-MISC" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.xcMiscExtension)
            fw.writeU8(0)
            fw.writeU8(0)
        } else if name == "SHAPE" {
            fw.writeU8(1)
            fw.writeU8(X11Opcode.shapeExtension)
            // Real event base for `ShapeNotify` (fired when a window
            // using `ShapeSelectInput` has its shape change) - this
            // server never sends one (shapes here are set once, by the
            // client itself, never changed server-side), so the exact
            // value is inert the same way RANDR's is above, but a
            // nonzero one costs nothing and matches real servers more
            // closely for any client that DOES compare against it.
            fw.writeU8(X11ExtensionBase.shapeFirstEvent)
            fw.writeU8(0)
        } else {
            fw.writeU8(0) // present = False - every other extension (SHM, XFIXES, ...) still unimplemented
            fw.writeU8(0)
            fw.writeU8(0)
            fw.writeU8(0)
        }
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    private func handleListExtensions() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writePadding(24)
        sendReply(fixed24: fw, detail: 0) // detail = number of STRs = 0
    }

    // MARK: - BIG-REQUESTS extension

    /// Confirmed live this is the actual root cause of a much bigger
    /// symptom than its own name suggests: GTK3 apps (`galculator` first
    /// caught it) queued draws/invalidations constantly (`gtk_widget_
    /// queue_draw` alone: 106 times in one startup) but never actually
    /// painted anything - the window stayed solid black forever, correctly
    /// created/sized/mapped/exposed the whole time. A real minimal X
    /// server with no window manager (`Xvfb`) rendered the exact same app
    /// perfectly, ruling out "GTK doesn't work without a WM" and pointing
    /// squarely at something this server was missing that Xvfb has.
    /// `xdpyinfo` against Xvfb showed the answer: BIG-REQUESTS, raising
    /// the maximum single request from the base protocol's ~256KB (a
    /// 16-bit length field, 4-byte units) to whatever `BigReqEnable`'s
    /// reply advertises. A 331x343 24-bit window's full-surface `PutImage`
    /// is already ~454KB - over that base limit - and without BIG-
    /// REQUESTS to safely split or size such a request, Xlib silently
    /// never sends it at all rather than erroring. `QueryExtension("BIG-
    /// REQUESTS")` reporting present is only half of this fix - the wire-
    /// level length-extension decoding in `run()`'s read loop is the
    /// other, required half.
    private func handleBigReqEnable() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(4_000_000) // max-request-size in 4-byte units - ~16MB, comfortably past any single window surface this server will ever composite
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    // MARK: - XInput2 extension

    /// Confirmed live (2026-09-02, `gui-bugs.md` issue #2's investigation)
    /// this is what was actually behind "keyboard input reaches the app
    /// but only the FIRST keypress ever does anything, every later one is
    /// silently dropped" - not a keysym/timing/debounce bug (all ruled
    /// out first, with trace logging still in `keyEvent` proving the
    /// server sent correct, distinctly-timestamped core `KeyPress`/
    /// `KeyRelease` events every time), and NOT a general event-delivery
    /// problem either (the identical repeated-action test via synthetic
    /// MOUSE clicks worked perfectly, using the same `sendPointerEvent`
    /// wire path this file's core `ButtonPress` events also go through).
    /// This server never implemented XInput2 at all - `QueryExtension
    /// ("XInputExtension")` always answered `present = 0`. Modern GDK's
    /// X11 backend is built assuming XI2 is available (`Require XInput2.h
    /// in X11 backend` - upstream GTK commit) and falls back to a legacy
    /// core-event compatibility path when it isn't; that fallback path is
    /// evidently NOT exercised often upstream (most real X servers have
    /// had XI2 for over a decade) and apparently loses sync after the
    /// very first key event in this server's case specifically. Rather
    /// than chase GDK's own fallback-path bug further, implementing
    /// enough of XI2 for GDK to use its NORMAL path sidesteps the problem
    /// entirely - real Xorg servers don't special-case "no XInput2"
    /// either, so this is also just filling in a real, previously-total
    /// gap, not a workaround specific to one bug.
    ///
    /// Deliberately minimal: exactly two devices, both fixed "virtual
    /// core" master devices (id 2 = pointer, 3 = keyboard, matching the
    /// IDs a real server's core protocol already reserves for them) -
    /// no slave/hardware devices, no touch, no scroll-valuator classes,
    /// no per-device grabs. `XISelectEvents`' device-id targeting is
    /// intentionally NOT tracked per-device - every mask a client selects
    /// (whichever device/`AllDevices`/`AllMasterDevices` it names) is
    /// just unioned into `WindowRecord.xiEventMask`, since this server
    /// only ever has the two devices to report anyway and GDK selects
    /// the same events on `AllMasterDevices` in practice. Enough for
    /// GDK's own X11 backend, not a general-purpose XI2 implementation.
    private func handleXInputRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case XIOpcode.getExtensionVersion: handleXIGetExtensionVersion(body: body)
        case XIOpcode.queryVersion: handleXIQueryVersion(body: body)
        case XIOpcode.queryDevice: handleXIQueryDevice(body: body)
        case XIOpcode.selectEvents: handleXISelectEvents(body: body)
        case XIOpcode.getSelectedEvents: handleXIGetSelectedEvents(body: body)
        case XIOpcode.getClientPointer: handleXIGetClientPointer(body: body)
        case XIOpcode.getProperty: handleXIGetProperty(body: body)
        case XIOpcode.queryPointer: handleXIQueryPointer(body: body)
        case XIOpcode.grabDevice: handleXIGrabDevice(body: body)
        case XIOpcode.ungrabDevice: break // no reply per spec; single-client grabs aren't meaningfully contested, same reasoning as core UngrabPointer/UngrabKeyboard
        // No reply per spec (`xXIChangeCursorReq`, XI2proto.h) - same
        // fire-and-forget shape as ungrabDevice above. GTK calls this the
        // moment it sees a real `XI_Enter` (see `sendXICrossingEvent`'s
        // doc comment, `gui-bugs.md` #10) to set the cursor for whatever
        // widget the pointer just entered - confirmed live: BEFORE this
        // fix, `default:`'s error-reply fallback below triggered GDK's
        // own default X-error handler, which `exit()`s the whole process
        // on an unexpected error code (same failure class the doc comment
        // above already predicted for `XIQueryPointer`/minor 40, and the
        // exact "if this shows up again" case it names). This server has
        // no real cursor theme to honor, so silently accepting and doing
        // nothing is the correct behavior, not a stopgap.
        case XIOpcode.changeCursor: break
        // XIWarpPointer, touch/scroll requests, ... - not
        // implemented, but NOT silently ignored either: confirmed live
        // that `default: break` here (matching `handleRenderRequest`'s
        // own, apparently never-actually-hit, equivalent) hangs the
        // WHOLE connection dead the first time GDK calls a
        // reply-expecting XI2 request this server doesn't recognize
        // (`XIGetProperty`, minor 59, was the first one that did it -
        // GDK's XI2 init queries a device property right after
        // `XIQueryDevice`). An error response - same "always answer
        // something" policy `dispatch`'s own top-level default already
        // uses for unrecognized CORE opcodes - keeps the client's
        // synchronous request/reply wait from blocking forever.
        //
        // BUT: confirmed live this trades one failure mode for another
        // for a reply-expecting request GDK calls OUTSIDE a synchronous
        // wait too - `XIQueryPointer` (minor 40, added as a real handler
        // above after hitting exactly this) triggered GDK's DEFAULT X
        // error handler, which for an unexpected error code just
        // `exit()`s the whole process outright ("received an X Window
        // System error... BadImplementation... request_code 152
        // (XInputExtension) minor_code 40" in galculator's own stderr,
        // right before it died) - the same class of "app doesn't
        // tolerate an error for this particular request" issue
        // `handleSetClipRectangles`'s doc comment already ran into once
        // for a CORE request. Net effect: an error reply here is a
        // strictly-better-than-silence fallback for whatever XI2 request
        // comes up NEXT that this server hasn't seen yet, but any
        // specific one GDK turns out to actually depend on for normal
        // operation (not just feature-probing) needs a REAL handler,
        // not just this fallback - if a fresh "GDK exits right after an
        // XInputExtension BadImplementation" report shows up again, that
        // minor_code in the error message is where to look first.
        default: sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: UInt16(minor), majorOpcode: X11Opcode.xinputExtension)
        }
    }

    /// See `XIOpcode.getExtensionVersion`'s doc comment - `libXi` sends
    /// this BEFORE the real `XIQueryVersion`, as part of `XIQueryVersion`
    /// itself, not a caller's own explicit step. Reply field layout
    /// (`major_version`/`minor_version`/`present`, then padding) is a
    /// reasonable reconstruction from the XInput 1.x SPEC TEXT's logical
    /// field list (`present: BOOL`, `protocol-major-version: CARD16`,
    /// `protocol-minor-version: CARD16`) - the exact historical byte
    /// offsets weren't findable in any still-hosted source, but this
    /// call is purely a compatibility formality libXi uses to decide
    /// whether to proceed to the real `XIQueryVersion` handshake, not
    /// something GDK itself reads fields out of - reporting the SAME
    /// major/minor as `handleXIQueryVersion` and a truthy `present` is
    /// what actually matters here.
    private func handleXIGetExtensionVersion(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(2) // major_version
        fw.writeU16(2) // minor_version
        fw.writeU8(1) // present
        fw.writePadding(19)
        sendReply(fixed24: fw)
    }

    /// GDK's own probe: it asks for the highest version IT understands
    /// (currently 2.4) and expects the server to answer with whatever
    /// version it actually supports, capped at that ask - reporting 2.2
    /// unconditionally (this server doesn't parse the client's requested
    /// version at all) is enough for GDK's own feature checks, which all
    /// gate on `>= 2.0`/`>= 2.2` for the functionality this server
    /// actually implements (basic device enumeration + key/button/motion
    /// events), not the touch/gesture features 2.3/2.4 added.
    private func handleXIQueryVersion(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(2) // major_version
        fw.writeU16(2) // minor_version
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    /// `xXIQueryDeviceReq.deviceid` (which single device vs. "all") IS
    /// filtered on (see below) - a client asking about ONE specific
    /// device (e.g. re-querying just the master pointer after a
    /// hierarchy-changed event) needs to see exactly that device back,
    /// not the full list padded in front of/behind it; a reply shaped
    /// differently than what was asked for is exactly the kind of thing
    /// that desyncs a client's own per-device bookkeeping - see the XTEST
    /// slave device doc comment below for a live example of that.
    ///
    /// Confirmed live (2026-09-02) this device data needs to be
    /// realistic, not just structurally well-formed: an earlier version
    /// of this handler reported `num_keycodes = 0` for the keyboard's
    /// `KeyClass` (and no button labels/valuators for the pointer either)
    /// - "structurally valid but empty" the way this server's OTHER
    /// deliberately-minimal replies usually get away with. That crashed
    /// GDK/galculator outright on the very FIRST real `KeyPress` XI2
    /// event delivered afterward (reproduced deterministically: a SINGLE
    /// synthetic key events every time, not a race) - almost certainly
    /// GDK indexing into a per-device keycode/valuator table it sized
    /// from `XIQueryDevice`'s own reply, using a keycode/axis this
    /// "empty" table said didn't exist. A real keycode list (matching
    /// this server's own `min-keycode`/`max-keycode` from `X11Connection
    /// Setup`) and real button/valuator classes fixed it.
    /// The master pointer's XI2 button list, in X11 button-number order
    /// (index 0 == button 1). Names are the real ones from
    /// `xserver`/`xf86-input-evdev`'s `BTN_LABEL_PROP_*` - toolkits match
    /// on them by atom.
    ///
    /// This used to advertise **3** buttons, and that alone silently
    /// disabled wheel scrolling in every Qt app. Qt's
    /// `QXcbConnection::xi2SetupDevice` only enables its legacy
    /// wheel-as-button-4/5 path when the XIButtonClass reports
    /// `num_buttons >= 5` (and horizontal 6/7 only at `>= 7`); below that
    /// it never sets `scrollingDevice.legacyOrientations`, so every
    /// `XI_ButtonPress` with detail 4-7 this server sent was dropped
    /// client-side with no error and nothing to see in any trace. Same
    /// shape of gate for the 8/9 back/forward buttons. GTK reads the wheel
    /// off `detail` regardless, which is exactly why scrolling could be
    /// verified working in `abiword` (GTK3) while still being completely
    /// dead in Krita (Qt) - see `gui-bugs.md` #28.
    ///
    /// Labels are interned rather than left as `None`: Qt accepts either
    /// (`label4 == ButtonWheelUp || label4 == 0`), but a real server sends
    /// them and a toolkit that matches strictly on the atom then has
    /// something to match.
    private static let pointerButtonLabels = [
        "Button Left", "Button Middle", "Button Right",
        "Button Wheel Up", "Button Wheel Down",
        "Button Horiz Wheel Left", "Button Horiz Wheel Right",
        "Button Side", "Button Extra",
    ]

    private func handleXIQueryDevice(body: [UInt8]) {
        // `xXIQueryDeviceReq` body: `deviceid`(2) + `pad`(2). `0` =
        // XIAllDevices, `1` = XIAllMasterDevices - both mean "everything
        // below", anything else names one specific device id.
        let requestedDeviceID: UInt16? = body.count >= 2
            ? X11ByteReader(body, littleEndian: littleEndian).readU16()
            : nil
        func included(_ id: UInt16, isMaster: Bool) -> Bool {
            switch requestedDeviceID {
            case nil, 0: return true // XIAllDevices
            case 1: return isMaster // XIAllMasterDevices
            case let want?: return id == want
            }
        }

        let extra = X11ByteWriter(littleEndian: littleEndian)
        var numDevicesWritten: UInt16 = 0
        // `xXIDeviceInfo` (12 bytes) + `name` (padded) + `numClasses`
        // class structs, one device at a time.
        func writeDevice(id: UInt16, use: UInt16, attachment: UInt16, name: String, numClasses: Int, classBytes: [UInt8]) {
            guard included(id, isMaster: use == XIDeviceUse.masterPointer || use == XIDeviceUse.masterKeyboard) else { return }
            numDevicesWritten += 1
            let nameBytes = Array(name.utf8)
            extra.writeU16(id)
            extra.writeU16(use)
            extra.writeU16(attachment)
            extra.writeU16(UInt16(numClasses)) // num_classes - a COUNT of classes, not a byte/word length
            extra.writeU16(UInt16(nameBytes.count))
            extra.writeU8(1) // enabled
            extra.writeU8(0) // pad
            extra.writeBytes(nameBytes)
            extra.writePadding(X11Wire.pad(nameBytes.count) - nameBytes.count)
            extra.writeBytes(classBytes)
        }

        // `xXIButtonInfo` (8-byte header) + a button-state BITMASK (padded
        // to 4-byte chunks) + `numButtons` label Atoms, IN THAT ORDER -
        // real xorgproto's `XI2proto.h` doc comment on the struct spells
        // this out explicitly, and it's not optional padding: this
        // bitmask was previously missing entirely (only the header +
        // labels were written), silently shrinking this class's actual
        // byte length below what a byte-precise client parser (one that
        // walks header->bitmask->labels structurally, not just trusting
        // `length` to skip to the next class) would expect - which
        // desyncs EVERY class read after this one for the rest of the
        // device's class list. Near-certainly the real cause of a GDK
        // `_gdk_x11_device_xi2_add_scroll_valuator` assertion seen live
        // with `mousepad` (garbage bytes from the resulting misalignment
        // decoding as a bogus extra class) - adding 4 valuators to the
        // pointer device alone (a separate, real gap - GDK does expect a
        // scroll-capable pointer to report 4 axes) did not fix it alone;
        // this framing bug is what actually explains a phantom/garbage
        // class appearing at all.
        func buttonClass(sourceid: UInt16, labels: [String]) -> [UInt8] {
            let numButtons = labels.count
            let w = X11ByteWriter(littleEndian: littleEndian)
            let maskBytes = 4 * ((numButtons + 31) / 32) // bitmask, padded to 4-byte chunks
            w.writeU16(1) // type = ButtonClass
            w.writeU16(UInt16(2 + maskBytes / 4 + numButtons)) // length in 4-byte units: 2-unit header + bitmask + numButtons*4 bytes of labels
            w.writeU16(sourceid)
            w.writeU16(UInt16(numButtons))
            w.writePadding(maskBytes) // button state bitmask - all zero, nothing currently pressed
            for label in labels { w.writeU32(state.internAtom(label, onlyIfExists: false)) }
            return w.bytes
        }

        // `xXIKeyInfo` (8 bytes) + `numKeycodes` CARD32 keycodes - the
        // full `minKeycode...maxKeycode` range this server's own
        // `X11ConnectionSetup` already advertises (8...255), not a
        // sparse/partial list, so ANY keycode `X11KeyCodes` can ever
        // produce is present here too.
        func keyClass(sourceid: UInt16, keycodes: ClosedRange<UInt8>) -> [UInt8] {
            let count = Int(keycodes.upperBound) - Int(keycodes.lowerBound) + 1
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writeU16(0) // type = XIKeyClass (real value from XI2.h - NOT 2, that's XIValuatorClass)
            w.writeU16(UInt16(2 + count))
            w.writeU16(sourceid)
            w.writeU16(UInt16(count))
            for kc in keycodes { w.writeU32(UInt32(kc)) }
            return w.bytes
        }

        // `xXIValuatorInfo` (44 bytes, no trailing data) - relative
        // motion (this server reports pointer position directly in each
        // event's `event_x`/`event_y`, never through a valuator delta),
        // `label`/`min`/`max`/`resolution` all zero since nothing reads
        // them back for a relative axis.
        func valuatorClass(sourceid: UInt16, number: UInt16) -> [UInt8] {
            let w = X11ByteWriter(littleEndian: littleEndian)
            // type = XIValuatorClass. Real value from `XI2.h`: XIKeyClass=0,
            // XIButtonClass=1, XIValuatorClass=2, XIScrollClass=3 - this
            // was previously writing 3 (actually XIScrollClass), so GDK
            // read every one of these as a bogus scroll-class announcement
            // instead of a real axis and tried to register scroll
            // valuators against it directly - explains the `_gdk_x11_
            // device_xi2_add_scroll_valuator` assertion seen live with
            // `mousepad` exactly (4 fake "scroll" entries x 2 devices = 8
            // failed calls, matching the observed count precisely), since
            // real XIValuatorClass entries never existed at all and
            // `n_axes` for the device stayed 0.
            w.writeU16(2)
            w.writeU16(11) // length: 44 bytes / 4
            w.writeU16(sourceid)
            w.writeU16(number)
            w.writeU32(0) // label = None
            w.writeI32(0); w.writeU32(0) // min (FP3232)
            w.writeI32(0); w.writeU32(0) // max (FP3232)
            w.writeI32(0); w.writeU32(0) // value (FP3232)
            w.writeU32(0) // resolution
            w.writeU8(0) // mode = ModeRelative
            w.writePadding(3)
            return w.bytes
        }

        // 4 valuators, not 2: confirmed live `_gdk_x11_device_xi2_add_
        // scroll_valuator` asserts (`n_valuator < gdk_device_get_n_axes`)
        // trying to register scroll-wheel valuators at indices 2/3 - GDK
        // unconditionally expects a master pointer to have X/Y motion
        // PLUS horizontal/vertical scroll axes, not just the two motion
        // axes a real touchpad/mouse's core motion alone would suggest.
        func pointerClasses(sourceid: UInt16) -> [UInt8] {
            buttonClass(sourceid: sourceid, labels: Self.pointerButtonLabels)
                + valuatorClass(sourceid: sourceid, number: 0)
                + valuatorClass(sourceid: sourceid, number: 1)
                + valuatorClass(sourceid: sourceid, number: 2)
                + valuatorClass(sourceid: sourceid, number: 3)
        }
        writeDevice(
            id: XIDeviceUse.corePointerID, use: XIDeviceUse.masterPointer,
            attachment: XIDeviceUse.coreKeyboardID, name: "Virtual core pointer",
            numClasses: 5, classBytes: pointerClasses(sourceid: XIDeviceUse.corePointerID)
        )
        writeDevice(
            id: XIDeviceUse.coreKeyboardID, use: XIDeviceUse.masterKeyboard,
            attachment: XIDeviceUse.corePointerID, name: "Virtual core keyboard",
            numClasses: 1, classBytes: keyClass(sourceid: XIDeviceUse.coreKeyboardID, keycodes: 8...255)
        )
        // Every real X server also reports a pair of XTEST slave devices,
        // attached to the two masters above - present unconditionally,
        // independent of real hardware. GDK's XI2 device setup sizes its
        // PER-DEVICE (not just per-master) valuator/axis table by walking
        // every device this reply lists, including slaves - with no slave
        // pointer ever listed, GDK fell back to a zero-axis device object
        // for whichever slave it expected, so ANY later scroll-valuator
        // registration on it hit `n_valuator < gdk_device_get_n_axes`
        // (0 axes) - confirmed live: this GDK critical persisted even
        // after the master pointer above already had all 4 valuators.
        writeDevice(
            id: XIDeviceUse.xtestPointerID, use: XIDeviceUse.slavePointer,
            attachment: XIDeviceUse.corePointerID, name: "Virtual core XTEST pointer",
            numClasses: 5, classBytes: pointerClasses(sourceid: XIDeviceUse.xtestPointerID)
        )
        writeDevice(
            id: XIDeviceUse.xtestKeyboardID, use: XIDeviceUse.slaveKeyboard,
            attachment: XIDeviceUse.coreKeyboardID, name: "Virtual core XTEST keyboard",
            numClasses: 1, classBytes: keyClass(sourceid: XIDeviceUse.xtestKeyboardID, keycodes: 8...255)
        )

        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(numDevicesWritten)
        fw.writePadding(22)
        sendReply(fixed24: fw, extra: extra.bytes)
    }

    /// No reply (per spec) - just parses and stores which events were
    /// asked for. `body`: `window`(4) + `num_masks`(2) + `pad`(2), then
    /// `num_masks` `EVENTMASK` entries (`deviceid`(2) + `mask_len`(2),
    /// then `mask_len` CARD32 words of actual mask bits) - every word
    /// from every entry just gets OR'd into one `WindowRecord.
    /// xiEventMask` regardless of device targeting (see this section's
    /// top-level doc comment for why that's enough here).
    private func handleXISelectEvents(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let windowID = r.readU32()
        let numMasks = Int(r.readU16())
        r.skip(2) // pad
        var combined: UInt32 = 0
        var perDevice: [UInt16: UInt32] = [:]
        for _ in 0..<numMasks {
            guard r.remaining >= 4 else { break }
            let deviceID = r.readU16()
            let maskLen = Int(r.readU16())
            var deviceMask: UInt32 = 0
            for word in 0..<maskLen {
                guard r.remaining >= 4 else { break }
                let bits = r.readU32()
                if word == 0 { deviceMask = bits } // every XI2.2 event type fits in the first word
                combined |= bits
            }
            perDevice[deviceID] = deviceMask
        }
        // The root window has no WindowRecord, so its selections used to be
        // dropped - xeyes selects XI_RawMotion there and its pupils never
        // moved. Selections replace per device, as XISelectEvents specifies.
        if windowID == rootWindowID {
            rootXIEventMasks.merge(perDevice) { _, new in new }
            let wantsRawMotion = rootXIEventMasks.values.contains { $0 & (UInt32(1) << UInt32(XIEventType.rawMotion)) != 0 }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if wantsRawMotion {
                    X11PointerMonitor.shared.subscribe(self) { [weak self] dx, dy in self?.sendXIRawMotion(dx: dx, dy: dy) }
                } else {
                    X11PointerMonitor.shared.unsubscribe(self)
                }
            }
            return
        }
        guard let record = state.window(windowID) else { return }
        record.xiEventMask = combined
    }

    /// Root-window XI2 selections, per device id. Connection thread only.
    private var rootXIEventMasks: [UInt16: UInt32] = [:]

    /// Sends one `XI_RawMotion` (called on the main thread by
    /// `X11PointerMonitor`, like every other input event).
    private func sendXIRawMotion(dx: Double, dy: Double) {
        writeFull(Self.xiRawMotionEvent(sequence: sequenceNumber, time: currentX11Timestamp, dx: dx, dy: dy,
                                        littleEndian: littleEndian))
    }

    /// `xXIRawEvent` (XI2proto.h) for `XI_RawMotion`: the 32-byte header, a
    /// one-unit valuator mask with axes 0 and 1 set, then the two values and
    /// the two raw values as FP3232. Real servers always send the relative
    /// x/y axes; `valuators_len = 0` would work for xeyes (it only calls
    /// XQueryPointer), but other raw-event clients read the deltas.
    static func xiRawMotionEvent(sequence: UInt16, time: UInt32, dx: Double, dy: Double, littleEndian: Bool) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(35) // GenericEvent
        w.writeU8(X11Opcode.xinputExtension)
        w.writeU16(sequence)
        w.writeU32(9) // length: (4 mask + 16 values + 16 raw values) / 4
        w.writeU16(XIEventType.rawMotion)
        w.writeU16(XIDeviceUse.corePointerID) // deviceid
        w.writeU32(time)
        w.writeU32(0) // detail
        w.writeU16(XIDeviceUse.xtestPointerID) // sourceid: the one slave pointer
        w.writeU16(1) // valuators_len, in 4-byte units
        w.writeU32(0) // flags
        w.writePadding(4)
        w.writeU32(0b11) // valuator mask: axes 0 (x) and 1 (y)
        func fp3232(_ value: Double) {
            let integral = value.rounded(.down)
            w.writeI32(Int32(clamping: Int(integral)))
            w.writeU32(UInt32(clamping: Int((value - integral) * 4_294_967_296.0)))
        }
        fp3232(dx); fp3232(dy) // axisvalues
        fp3232(dx); fp3232(dy) // axisvalues_raw (no acceleration curve here)
        return w.bytes
    }

    /// `XIGetSelectedEvents` (minor 60). Emacs calls it while creating
    /// its first frame and treats any error as fatal. Device ids aren't
    /// tracked (see `handleXISelectEvents`), so whatever was selected is
    /// reported once, for `XIAllMasterDevices` (1).
    private func handleXIGetSelectedEvents(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let mask = state.window(r.readU32())?.xiEventMask ?? 0
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(mask == 0 ? 0 : 1) // num_masks
        fw.writePadding(22)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        if mask != 0 {
            extra.writeU16(1) // deviceid = XIAllMasterDevices
            extra.writeU16(1) // mask_len, in 4-byte units
            extra.writeU32(mask)
        }
        sendReply(fixed24: fw, extra: extra.bytes)
    }

    /// GDK's XI2 init queries a handful of well-known device properties
    /// (libinput/synaptics scroll/tap-to-click config atoms, mostly)
    /// right after `XIQueryDevice` - this server tracks none of them, so
    /// every one is answered the same way core `handleGetProperty`
    /// answers a property that was never set: `type=None`, zero items.
    /// Real Xorg would error `BadAtom` for a genuinely-unknown atom
    /// instead, but GDK's own property-probing code already treats
    /// `type=None`/zero-length as "not present, use defaults" for
    /// exactly this kind of optional capability query - an error here
    /// risks being the ONE code path this whole XI2 addition was meant
    /// to avoid (a hard stop on an unhandled reply-expecting request),
    /// so the lenient "not found" reply is deliberately the safer choice
    /// even though it's less protocol-accurate than a real `BadAtom`.
    private func handleXIGetProperty(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(0) // type = None
        fw.writeU32(0) // bytes-after
        fw.writeU32(0) // num-items
        fw.writeU8(0) // format
        fw.writePadding(11)
        sendReply(fixed24: fw)
    }

    /// XI2 analogue of core `handleQueryPointer` - same real-cursor-
    /// position lookup (`NSEvent.mouseLocation`, main-thread-only, see
    /// `handleQueryPointer`'s own doc comment), reshaped into
    /// `xXIQueryPointerReply`'s wider layout (`FP1616` coordinates, a
    /// modifier/group block, a trailing per-button state array - empty
    /// here, `buttons_len = 0`, since button state isn't tracked
    /// server-side). Reconstructed from the XI2 protocol's general reply
    /// conventions (not a verbatim spec quote - the exact historical
    /// byte layout wasn't findable in any still-hosted source during
    /// this implementation), but this is a REAL handler either way, not
    /// a placeholder - see `handleXInputRequest`'s `default` case for
    /// why an error reply here specifically is NOT an acceptable
    /// fallback (confirmed live: GDK's default X error handler treats
    /// an error from THIS particular request as fatal and exits the
    /// whole app).
    private func handleXIQueryPointer(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        // `windowOrigin(_:)`, not `frame.origin` directly - correct for
        // a top-level window either way, but `frame.origin` alone is only
        // PARENT-relative for a child window (see `sendPointerEvent`'s
        // doc comment for the sibling bug this was found alongside).
        let origin = windowOrigin(wid)
        var rootX = 0, rootY = 0
        DispatchQueue.main.sync {
            let screenHeight = NSScreen.main?.frame.height ?? 1080
            let cocoa = NSEvent.mouseLocation
            rootX = Int(cocoa.x)
            rootY = Int(screenHeight - cocoa.y)
        }
        let winX = rootX - Int(origin.x)
        let winY = rootY - Int(origin.y)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(rootWindowID)
        fw.writeU32(0) // child = None
        fw.writeI32(Int32(clamping: rootX) << 16) // root_x, FP1616
        fw.writeI32(Int32(clamping: rootY) << 16) // root_y
        fw.writeI32(Int32(clamping: winX) << 16) // win_x
        fw.writeI32(Int32(clamping: winY) << 16) // win_y

        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU16(0) // buttons_len
        extra.writePadding(2)
        extra.writeU32(0); extra.writeU32(0); extra.writeU32(0); extra.writeU32(0) // mods: base/latched/locked/effective
        extra.writeU8(0); extra.writeU8(0); extra.writeU8(0); extra.writeU8(0) // group: base/latched/locked/effective
        sendReply(fixed24: fw, extra: extra.bytes, detail: 1) // detail: same-screen = True
    }

    /// Confirmed live (2026-09-02, investigating `gui-bugs.md` issue #5 -
    /// "modal dialogs/menus severely broken"): GTK's in-window menu-bar
    /// popup (`GtkMenuBar`, e.g. galculator's own File/Edit/View/
    /// Calculator/Help row) grabs the pointer via `gdk_seat_grab` when a
    /// menu opens - so a click on any of those actually reaches this
    /// server fine (confirmed via `mouseButton`'s own trace firing
    /// correctly), but the FOLLOW-UP `XIGrabDevice` request (minor 51)
    /// this server didn't handle yet hit the same defensive
    /// `BadImplementation`-error default `XIGetProperty`/`XIQueryPointer`
    /// both hit earlier - and unlike THOSE (a hang, then a hard crash),
    /// this one just makes GTK silently give up opening the menu
    /// (a real, if less catastrophic, failure mode: no error dialog, no
    /// crash, the click just does nothing user-visible - which is
    /// EXACTLY what "menus/dialogs are broken" looks like from outside).
    /// Same reasoning as core `GrabPointer`/`GrabKeyboard`
    /// (`handleGrabReply`) - single client, nothing to actually contend
    /// against, so every grab trivially succeeds.
    private func handleXIGrabDevice(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writePadding(24)
        sendReply(fixed24: fw, detail: 0) // detail: status = GrabSuccess
    }

    /// GDK asks this once at startup to learn which device ID to treat
    /// as "the" pointer for client-pointer-relative APIs - always the
    /// one master pointer this server has.
    private func handleXIGetClientPointer(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU8(1) // set = True
        fw.writeU8(0) // pad0
        fw.writeU16(XIDeviceUse.corePointerID)
        fw.writePadding(20)
        sendReply(fixed24: fw)
    }

    /// `xXIDeviceEvent` - the shared wire layout for XI2 `KeyPress`/
    /// `KeyRelease`/`ButtonPress`/`ButtonRelease`/`Motion` (real field
    /// offsets confirmed against `<X11/extensions/XI2proto.h>`'s actual
    /// struct definition, not a paraphrase - `flags` comes BEFORE `mods`/
    /// `group` in both the struct's field order and its wire bytes).
    /// Fixed 80-byte size here (`buttons_len`/`valuators_len` both 0 -
    /// no button-state bitmask or axis values trail this event, which is
    /// fine: GDK reads `detail` for which button/key and doesn't need
    /// the full button-state snapshot for a plain press/release/motion).
    /// `mods` carries the real keyboard state (`X11KeyboardState`); `group`
    /// stays 0 because the Mac layout's first group is always the active one.
    private func sendXIDeviceEvent(evtype: UInt16, detail: UInt32, deviceid: UInt16, windowID: UInt32, x: Int16, y: Int16,
                                   mods: X11KeyboardSnapshot? = nil, buttons: Set<UInt8>? = nil) {
        // The modifier fields were all zero until 2026-09-14, and GTK3 reads
        // an XI2 event's modifier state from exactly these - so Ctrl, Shift
        // and Alt never reached any XI2 client's shortcut handling.
        let modState = mods ?? X11KeyboardState.shared.current
        // See `sendPointerEvent`'s doc comment (`gui-bugs.md` issue #10) -
        // same root-vs-window-relative bug, same fix, just FP1616-encoded
        // here instead of a plain `INT16`.
        let origin = windowOrigin(windowID)
        let rootX = Int32(origin.x) + Int32(x)
        let rootY = Int32(origin.y) + Int32(y)
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(35) // GenericEvent
        w.writeU8(X11Opcode.xinputExtension)
        w.writeU16(sequenceNumber)
        w.writeU32(13) // length: (80 + 4 - 32) / 4 - fixed part plus one button-mask unit
        w.writeU16(evtype)
        w.writeU16(deviceid)
        w.writeU32(currentX11Timestamp)
        w.writeU32(detail)
        w.writeU32(rootWindowID)
        w.writeU32(windowID) // event
        w.writeU32(0) // child = None
        w.writeI32(rootX << 16) // root_x, FP1616
        w.writeI32(rootY << 16) // root_y
        w.writeI32(Int32(x) << 16) // event_x - window-relative, correct as-is
        w.writeI32(Int32(y) << 16) // event_y
        // One 4-byte unit of button bitmask follows the fixed part. It was
        // 0 (no mask) until 2026-09-15, and GDK3 builds GDK_BUTTON1_MASK
        // for every XI2 event from exactly this, so GTK saw every drag as
        // "no button held": sliders couldn't be dragged, and clicks on
        // buttons and checkboxes didn't stick.
        w.writeU16(1) // buttons_len, in 4-byte units
        w.writeU16(0) // valuators_len
        w.writeU16(deviceid) // sourceid
        w.writeU16(0) // pad0
        w.writeU32(0) // flags
        w.writeU32(UInt32(modState.baseMods)) // mods.base_mods
        w.writeU32(0) // mods.latched_mods
        w.writeU32(UInt32(modState.lockedMods)) // mods.locked_mods
        w.writeU32(UInt32(modState.effectiveMods)) // mods.effective_mods
        w.writeU8(0) // group.base_group
        w.writeU8(0) // group.latched_group
        w.writeU8(0) // group.locked_group
        w.writeU8(0) // group.effective_group
        // Buttons down BEFORE this event, like xorg's `event_set_state`: a
        // press doesn't include its own button, a release does, motion
        // carries whatever is held.
        w.writeBytes(Self.xi2ButtonMask(buttons ?? pressedButtons))
        writeFull(w.bytes)
    }

    /// `XI_Enter`/`XI_Leave` (evtype 7/8) - a DIFFERENT wire layout than
    /// `sendXIDeviceEvent`'s (`xXIEnterEvent`, not `xXIDeviceEvent` - see
    /// `<X11/extensions/XI2proto.h>`, confirmed from the real header on
    /// this machine rather than guessed): `mode`/`detail` sit right after
    /// `sourceid` instead of a `detail` CARD32 up front, and the tail is
    /// `same_screen`/`focus`/`buttons_len`/`mods`/`group` (72 bytes total)
    /// instead of `buttons_len`/`valuators_len`/`sourceid`/`pad0`/`flags`/
    /// `mods`/`group` (80 bytes). `gui-bugs.md` issue #10 (the "menu opens
    /// but items don't activate" bug): GTK's `gtk_menu_shell` tracks
    /// `active_menu_item` from crossing (enter/leave) events on each menu
    /// item's own child window, NOT from button events alone - a
    /// `ButtonRelease` with perfect coordinates still resolves to "no
    /// item" if GTK never saw the matching `XI_Enter` first. This server
    /// never sent ANY crossing event at all before this fix (confirmed via
    /// a full grep - `EnterNotify`/`XI_Enter` had zero call sites), despite
    /// `X11CanvasView` already wiring up an AppKit `NSTrackingArea` with
    /// `.mouseEnteredAndExited` - the view had no `mouseEntered`/
    /// `mouseExited` overrides at all, so AppKit's default (a no-op) silently
    /// swallowed every crossing.
    ///
    /// `XI_FocusIn`/`XI_FocusOut` (evtype 9/10) share this EXACT struct
    /// (`XI2proto.h` literally `typedef`s `xXIFocusInEvent` to
    /// `xXIEnterEvent`), so they go out through here too - see
    /// `sendXIFocusEvent`.
    private func sendXICrossingEvent(evtype: UInt16, deviceid: UInt16, windowID: UInt32, x: Int16, y: Int16, detail: UInt8 = 3, focus: UInt8 = 0) {
        let origin = windowOrigin(windowID)
        let rootX = Int32(origin.x) + Int32(x)
        let rootY = Int32(origin.y) + Int32(y)
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(35) // GenericEvent
        w.writeU8(X11Opcode.xinputExtension)
        w.writeU16(sequenceNumber)
        w.writeU32(10) // length: (72 - 32) / 4
        w.writeU16(evtype)
        w.writeU16(deviceid)
        w.writeU32(currentX11Timestamp)
        w.writeU16(deviceid) // sourceid
        w.writeU8(0) // mode = XINotifyNormal
        w.writeU8(detail) // crossing: XINotifyNonlinear; focus: XINotifyAncestor
        w.writeU32(rootWindowID)
        w.writeU32(windowID) // event
        w.writeU32(0) // child = None
        w.writeI32(rootX << 16) // root_x, FP1616
        w.writeI32(rootY << 16) // root_y
        w.writeI32(Int32(x) << 16) // event_x - window-relative, correct as-is
        w.writeI32(Int32(y) << 16) // event_y
        w.writeU8(1) // same_screen
        w.writeU8(focus)
        w.writeU16(0) // buttons_len
        w.writeU32(0) // mods.base_mods
        w.writeU32(0) // mods.latched_mods
        w.writeU32(0) // mods.locked_mods
        w.writeU32(0) // mods.effective_mods
        w.writeU8(0) // group.base_group
        w.writeU8(0) // group.latched_group
        w.writeU8(0) // group.locked_group
        w.writeU8(0) // group.effective_group
        writeFull(w.bytes)
    }

    /// `XI_FocusIn`/`XI_FocusOut` (evtype 9/10). Confirmed live this is
    /// why `abiword` could not be typed into AT ALL despite every
    /// keystroke reaching the server with the correct keycode and keysym
    /// (traced: `keyEvent ... keysyms=Optional((104, 72))` and friends,
    /// spelling out exactly what was typed) and despite the XI2
    /// `KeyPress` itself being delivered: a GTK3 client that has switched
    /// to XI2 selects NO core key or focus bits at all (abiword's
    /// toplevel event-mask was `0x438000` - PropertyChange/
    /// StructureNotify/VisibilityChange/Exposure only, confirmed by
    /// scanning every window's mask across a live 4-app session, where
    /// abiword had ZERO windows selecting core `FocusChangeMask` while
    /// Qt/Krita's had it on all of theirs). Such a client learns it holds
    /// the keyboard focus ONLY from an XI2 focus event - and
    /// `XIEventType` was missing evtypes 9/10 entirely (it jumped
    /// 8 -> 11), so this server had never sent one. GTK will happily
    /// receive key events and route them nowhere while it still believes
    /// its toplevel is unfocused.
    ///
    /// `x`/`y` are reported as 0: a focus event's pointer coordinates
    /// carry no meaning for focus handling (unlike a crossing event's,
    /// which GTK really does read for menu-item tracking), so there's
    /// nothing to resolve a real pointer position for here.
    private func sendXIFocusEvent(focusIn: Bool, windowID: UInt32) {
        sendXICrossingEvent(
            evtype: focusIn ? XIEventType.focusIn : XIEventType.focusOut,
            deviceid: XIDeviceUse.coreKeyboardID, windowID: windowID, x: 0, y: 0,
            detail: 0, // XINotifyAncestor - matches core `sendFocusEvent`'s own detail
            focus: focusIn ? 1 : 0
        )
    }

    /// Core `EnterNotify`(7)/`LeaveNotify`(8) - see `sendXICrossingEvent`'s
    /// doc comment for why this exists at all (`gui-bugs.md` #10). Layout
    /// confirmed from the real `xEnterLeaveEvent` union member in
    /// `<X11/Xproto.h>` on this machine: identical field order to
    /// `sendPointerEvent`'s `keyButtonPointer` layout up through
    /// `event-y`/`state`, then `mode`(1) + `same-screen,focus` flags(1)
    /// instead of `same-screen`(1) + `unused`(1) - still 32 bytes.
    private func sendCoreCrossingEvent(code: UInt8, windowID: UInt32, x: Int16, y: Int16) {
        let origin = windowOrigin(windowID)
        let rootX = Int16(clamping: Int(origin.x) + Int(x))
        let rootY = Int16(clamping: Int(origin.y) + Int(y))
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(code)
        w.writeU8(3) // detail = NotifyNonlinear - see sendXICrossingEvent's doc comment
        w.writeU16(sequenceNumber)
        w.writeU32(currentX11Timestamp)
        w.writeU32(rootWindowID)
        w.writeU32(windowID)
        w.writeU32(0) // child = None
        w.writeI16(rootX)
        w.writeI16(rootY)
        w.writeI16(x)
        w.writeI16(y)
        w.writeU16(0) // state
        w.writeU8(0) // mode = NotifyNormal
        w.writeU8(0x02) // flags: same-screen set, focus unset
        writeFull(w.bytes)
    }

    /// `FocusIn`/`FocusOut` (core opcodes 9/10) - this server had NO
    /// implementation of either before this, at all (confirmed by grep:
    /// zero references anywhere in this file). Real, previously-
    /// unidentified gap: Qt's `QMenuBar` - unlike a plain `QPushButton`,
    /// confirmed live to already work fine via ordinary `ButtonPress`/
    /// `ButtonRelease` alone - only opens its dropdown for a click on an
    /// ACTIVE window; Qt's xcb backend tracks "is this window active" via
    /// real `FocusIn`/`FocusOut` events, which a real X11 WM sends on
    /// every focus change (`SetInputFocus`-driven, or - as here, with no
    /// separate WM - tied directly to real macOS key-window status).
    /// Confirmed live via `MSL_X11_TRACE`: a `File` click on Krita's menu
    /// bar delivered a perfectly plausible `ButtonPress`/`ButtonRelease`
    /// pair (correct window, correct (20,10) coordinate, both core AND
    /// XI2 channels passing their event-mask checks) and NOTHING
    /// happened afterward - no error, no crash, just silence, meaning
    /// Qt received the click and chose not to act on it. `makeFirstResponder`
    /// (a much earlier fix, see this file's own history) was enough to
    /// get KEYBOARD input flowing but never sent the explicit `FocusIn`
    /// event a toolkit's own "is my window active" bookkeeping depends on
    /// independently of whether it can receive keystrokes. Detail
    /// `NotifyAncestor` (0) + mode `NotifyNormal` (0) - the simplest
    /// legal combination, matching this server's existing "no real WM,
    /// no separate focus-proxy window" simplifications elsewhere (e.g.
    /// `sendCoreCrossingEvent`'s own `NotifyNonlinear` choice for the
    /// equivalent no-common-ancestor case).
    private func sendFocusEvent(code: UInt8, windowID: UInt32) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(code)
        w.writeU8(0) // detail = NotifyAncestor
        w.writeU16(sequenceNumber)
        w.writeU32(windowID)
        w.writeU8(0) // mode = NotifyNormal
        w.writePadding(23)
        writeFull(w.bytes)
    }

    // MARK: - XKEYBOARD extension

    /// Confirmed live via `gdb` (not a guess - see the actual crash
    /// investigation this fixes, `gui-bugs.md` issue #2) that implementing
    /// XInput2 alone wasn't enough to unblock real keyboard input: GDK's
    /// XI2 `KeyPress` handling calls `gdk_x11_keymap_key_is_modifier()`,
    /// which - correctly detecting this server has no XKEYBOARD extension
    /// (`QueryExtension("XKEYBOARD")` used to always answer `present=0`,
    /// same as every other unimplemented extension) - takes GDK's
    /// documented non-XKB fallback path (iterating `keymap_x11->
    /// mod_keymap->modifiermap`, built from plain core `GetModifierMapping`
    /// - a request this server already implements). But that fallback's
    /// own lazy-init (`update_keymaps()`, populating `mod_keymap` on
    /// first use) apparently never actually runs before an XI2 `KeyPress`
    /// reaches this function - a real `gdb` backtrace against the
    /// (unstripped-of-symbols-enough-to-tell) crash showed `x0` (loaded
    /// from `keymap_x11->mod_keymap`) was NULL right before dereferencing
    /// it, taking the whole app down on the very first real keystroke.
    /// Rather than chase GDK's own legacy-path init-ordering bug further
    /// (this exact "XI2 present, XKB absent" combination is almost
    /// certainly untested upstream - virtually every real X server has
    /// had XKB for 20+ years), implementing enough real XKB for GDK to
    /// use its OWN (better-exercised) XKB code path instead sidesteps it
    /// entirely - same reasoning as implementing XInput2 itself instead
    /// of chasing GDK's non-XI2 fallback.
    ///
    /// Deliberately minimal, same spirit as the XInput2 section above:
    /// `handleXkbGetMap` only ever reports the ONE map component
    /// (`ModifierMap`) actually confirmed necessary (the exact field
    /// `gdk_x11_keymap_key_is_modifier` dereferences) even though GDK's
    /// own `XkbGetMap` call asks for key types/symbols/virtual mods too -
    /// a real client is expected to tolerate the server including LESS
    /// than requested (`present` says what's actually included), so this
    /// is deliberately staged as "prove the exact known-needed piece
    /// first, expand only if a NEW specific crash says so" rather than
    /// front-loading a full XKB implementation no evidence yet supports
    /// needing.
    private func handleXkbRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case XKBOpcode.useExtension: handleXkbUseExtension(body: body)
        case XKBOpcode.getMap: handleXkbGetMap(body: body)
        case XKBOpcode.getNames: handleXkbGetNames(body: body)
        case XKBOpcode.getControls: handleXkbGetControls(body: body)
        case XKBOpcode.getState: handleXkbGetState(body: body)
        case XKBOpcode.selectEvents: handleXkbSelectEvents(body: body) // no reply per spec - same fire-and-forget shape as core SelectInput/XISelectEvents
        case XKBOpcode.getDeviceInfo: handleXkbGetDeviceInfo(body: body)
        case XKBOpcode.getCompatMap: handleXkbGetCompatMap(body: body)
        case XKBOpcode.getIndicatorMap: handleXkbGetIndicatorMap(body: body)
        case XKBOpcode.getIndicatorState: handleXkbGetIndicatorState()
        case XKBOpcode.perClientFlags: handleXkbPerClientFlags(body: body)
        // Requests that change the keyboard's configuration and expect no
        // reply. The configuration is the Mac's, so they are accepted and
        // ignored - an error here made GTK log an X error on every beep
        // (`XkbBell`).
        case XKBOpcode.bell, XKBOpcode.latchLockState, XKBOpcode.setControls, XKBOpcode.setMap,
             XKBOpcode.setCompatMap, XKBOpcode.setIndicatorMap, XKBOpcode.setNamedIndicator,
             XKBOpcode.setNames, XKBOpcode.setDeviceInfo:
            break
        // Same defensive policy as `handleXInputRequest`'s own default -
        // see its doc comment for why silence (a hang) is worse than an
        // error here, even though an error isn't always safe either.
        default: sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: UInt16(minor), majorOpcode: X11Opcode.xkbExtension)
        }
    }

    /// See `X11XkbEventSelection` for the request's variable-length
    /// layout - reading only `affectWhich`, as this used to, misreads every
    /// detail pair after the first.
    private func handleXkbSelectEvents(body: [UInt8]) {
        xkbSelection.apply(body: body, littleEndian: littleEndian)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] xkbSelectEvents newKeyboard=0x\(String(xkbSelection.newKeyboard, radix: 16)) map=0x\(String(xkbSelection.map, radix: 16)) state=0x\(String(xkbSelection.state, radix: 16))\n".data(using: .utf8)!)
        }
    }

    /// `XkbUseExtension` - XKB's own version-negotiation request,
    /// analogous to RENDER's `queryVersion`/XI2's `XIQueryVersion`.
    /// Echoes back whatever `wantedMajor`/`wantedMinor` the CLIENT sent,
    /// rather than claiming a fixed version - confirmed live that a
    /// hardcoded "1.0" (a real, valid XKB version) made GDK call
    /// `XkbUseExtension` three times and then give up, never calling
    /// `XkbGetMap` at all, consistent with libX11's `XkbQueryExtension()`
    /// historically enforcing `server_major == client_major` (NOT just
    /// "server version is new enough") - unlike most other extensions'
    /// looser `>=` version negotiation. Echoing the request's own
    /// version trivially satisfies that check regardless of which XKB
    /// version any particular client happens to want.
    private func handleXkbUseExtension(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wantedMajor = r.readU16()
        let wantedMinor = r.readU16()
        // `supported` (a BOOL) is NOT the first byte of the 24-byte fixed
        // body - confirmed against the real `xkbUseExtensionReply` C
        // struct (`<X11/extensions/XKBproto.h>`) that, like several
        // other X11 replies (core `QueryPointer`'s `same-screen`, this
        // file's own `detail:` param elsewhere), it rides the reply
        // HEADER's second byte (`type, supported, sequenceNumber,
        // length, ...`) instead - the position `sendReply`'s `detail`
        // parameter writes. Confirmed LIVE via `gdb`, breakpointing the
        // real `XkbQueryExtension()` C function and reading its return
        // register directly, that writing `supported` as fixed24's
        // FIRST byte (this function's original, wrong version) made
        // every real client read `supported` from what was actually
        // `serverMajor`'s low byte - always landing on a value that
        // read as "not supported", regardless of everything else this
        // section implements being individually correct.
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(wantedMajor) // serverMajor
        fw.writeU16(wantedMinor) // serverMinor
        fw.writePadding(20)
        sendReply(fixed24: fw, detail: 1) // detail: supported = True
    }

    // The keymap requests are answered from `X11Keymap`, one model shared
    // with the core `GetKeyboardMapping`/`GetModifierMapping` replies - see
    // its doc comment for why they used to disagree and what that broke.

    private func handleXkbGetMap(body: [UInt8]) {
        writeFull(X11KeymapProvider.shared.keymap.getMapReply(body: body, sequence: sequenceNumber, littleEndian: littleEndian))
    }

    private func handleXkbGetNames(body: [UInt8]) {
        let state = self.state
        let reply = X11KeymapProvider.shared.keymap.getNamesReply(body: body, sequence: sequenceNumber, littleEndian: littleEndian) {
            state.internAtom($0, onlyIfExists: false)
        }
        writeFull(reply)
    }

    private func handleXkbGetControls(body: [UInt8]) {
        writeFull(X11KeymapProvider.shared.keymap.getControlsReply(sequence: sequenceNumber, littleEndian: littleEndian))
    }

    /// The real state now - it was hard-coded to "nothing held", so a
    /// client that asked while Shift was down was told it wasn't.
    private func handleXkbGetState(body: [UInt8]) {
        var snapshot = X11KeyboardState.shared.current
        snapshot.buttons = Self.x11ButtonMask(pressedButtons)
        writeFull(X11Keymap.getStateReply(snapshot, sequence: sequenceNumber, littleEndian: littleEndian))
    }

    /// `XkbGetCompatMap` and `XkbGetIndicatorMap` used to be errors, and
    /// were what made every libxkbcommon client give up - Qt, so Krita,
    /// with "failed to compile a keymap". `xkbcomp :1 -` in the guest
    /// showed it plainly: "Could not load indicator map", "Could not load
    /// compatibility map", then an empty keymap.
    private func handleXkbGetCompatMap(body: [UInt8]) {
        writeFull(X11KeymapProvider.shared.keymap.getCompatMapReply(body: body, sequence: sequenceNumber, littleEndian: littleEndian))
    }

    private func handleXkbGetIndicatorMap(body: [UInt8]) {
        writeFull(X11KeymapProvider.shared.keymap.getIndicatorMapReply(body: body, sequence: sequenceNumber, littleEndian: littleEndian))
    }

    /// Which indicators are lit: Caps Lock, when it is locked.
    private func handleXkbGetIndicatorState() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(X11KeyboardState.shared.current.lockedMods & X11ModMask.lock != 0 ? 1 : 0)
        fw.writePadding(20)
        sendReply(fixed24: fw, detail: X11Keymap.deviceID)
    }

    /// GTK and Qt both turn on DetectableAutoRepeat through this at
    /// startup; it used to be answered with an error.
    private func handleXkbPerClientFlags(body: [UInt8]) {
        let result = X11Keymap.perClientFlagsReply(body: body, current: xkbClientFlags, sequence: sequenceNumber, littleEndian: littleEndian)
        xkbClientFlags = result.flags
        writeFull(result.reply)
    }

    /// `XkbGetDeviceInfo` (extended device - LED feedbacks/extra buttons
    /// - capability query) was previously unhandled, hitting the shared
    /// `default: sendError(...)` case - confirmed live as the source of
    /// Qt's xcb backend startup warning `"failed to get core keyboard
    /// device info"` (harmless in practice - Qt just falls back to
    /// defaults - but a real unimplemented request, not actually XI2-
    /// related despite the similar wording). All-zero/none reply: no LED
    /// feedbacks, no extra buttons, no device-specific state - the same
    /// "structurally valid, nothing to report" policy `handleXkbGetControls`/
    /// `handleXkbGetState` already use. `xkbGetDeviceInfoReply` (real
    /// struct from xorgproto's `XKBproto.h`) is exactly 24 bytes past the
    /// standard 8-byte reply header, fitting `fixed24` alone with no
    /// extra/trailing data.
    private func handleXkbGetDeviceInfo(body: [UInt8]) {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU16(0) // present - no optional device info present
        fw.writeU16(0) // supported
        fw.writeU16(0) // unsupported
        fw.writeU16(0) // nDeviceLedFBs
        fw.writeU8(0) // firstBtnWanted
        fw.writeU8(0) // nBtnsWanted
        fw.writeU8(0) // firstBtnRtrn
        fw.writeU8(0) // nBtnsRtrn
        fw.writeU8(0) // totalBtns - this device has no buttons
        fw.writeU8(0) // hasOwnState = false
        fw.writeU16(0) // dfltKbdFB
        fw.writeU16(0) // dfltLedFB
        fw.writeU16(0) // pad
        fw.writeU32(0) // devType = None
        sendReply(fixed24: fw, detail: X11Keymap.deviceID)
    }

    /// `XkbStateNotify`, only to a client that selected the parts of the
    /// state that changed - `xkb/xkbEvents.c`'s `XkbSendStateNotify`
    /// filters on exactly that. Carries the state after the change; the key
    /// event itself carries the state before it.
    ///
    /// It used to go out on every key event whether anything changed or
    /// not, with the same value in every field.
    private func sendXkbStateNotify(_ transition: X11KeyboardState.Transition) {
        let buttons = Self.x11ButtonMask(pressedButtons)
        var before = transition.before, after = transition.after
        before.buttons = buttons
        after.buttons = buttons
        let changed = X11Keymap.stateChanges(from: before, to: after)
        guard changed != 0, xkbSelection.state & UInt32(changed) != 0 else { return }
        writeFull(X11Keymap.stateNotify(after, changed: changed, keycode: transition.keycode,
                                        eventType: transition.pressed ? 2 : 3, eventBase: XKBEventCode.eventBase,
                                        sequence: sequenceNumber, time: currentX11Timestamp, littleEndian: littleEndian))
    }

    /// The user switched keyboard layout, or the Option key arrangement
    /// changed. Core `MappingNotify` goes to every client, as a real server
    /// sends it; the XKB events only to clients that selected them. Either
    /// way the client re-reads the keymap and the next keystroke types in
    /// the new layout.
    private func keymapDidChange() {
        writeFull(X11Keymap.mappingNotify(request: 1, sequence: sequenceNumber, littleEndian: littleEndian))
        writeFull(X11Keymap.mappingNotify(request: 0, sequence: sequenceNumber, littleEndian: littleEndian))
        if xkbSelection.newKeyboard & 0x01 != 0 {
            writeFull(X11Keymap.newKeyboardNotify(eventBase: XKBEventCode.eventBase, sequence: sequenceNumber,
                                                  time: currentX11Timestamp, littleEndian: littleEndian))
        }
        if xkbSelection.map & X11Keymap.MapPart.all != 0 {
            writeFull(X11Keymap.mapNotify(eventBase: XKBEventCode.eventBase, sequence: sequenceNumber,
                                          time: currentX11Timestamp, littleEndian: littleEndian))
        }
    }

    // MARK: - RANDR extension

    /// This server's ONE virtual output/crtc/mode, given fixed resource
    /// IDs the same way `rootWindowID`/`colormapID` are (see their own
    /// doc comment above `resourceIdBase`): parked at the top of this
    /// connection's private ID range, far past anything a client would
    /// ever self-allocate into. A real multi-monitor setup would need
    /// per-screen tracking instead of these three fixed constants - out
    /// of scope for a single-virtual-screen server.
    private var randrOutputID: UInt32 { resourceIdBase | (resourceIdMask - 2) }
    private var randrCrtcID: UInt32 { resourceIdBase | (resourceIdMask - 3) }
    private var randrModeID: UInt32 { resourceIdBase | (resourceIdMask - 4) }

    /// GDK's X11 backend queries RANDR unconditionally at startup for
    /// monitor geometry/DPI (`gdk_x11_display_open` →
    /// `init_randr_support`) - before this was implemented,
    /// `QueryExtension("RANDR")` always answered `present=0` and GDK just
    /// silently fell back to treating the whole core screen as one
    /// pseudo-monitor, which happens to work fine for a single-screen
    /// server like this one. So unlike XI2/XKB, there was no confirmed
    /// live crash/hang motivating this - it's here because a "have a
    /// feeling we're missing extensions real apps want" pass through
    /// XQuartz's own `mi/miinitext.c` static-extension list flagged it as
    /// present in every real server and genuinely queried by GDK, and
    /// having it removes one more "untested no-RANDR combination" the way
    /// implementing XKB removed the "XI2 without XKB" one.
    private func handleRandRRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case RandRRequest.queryVersion: handleRRQueryVersion()
        case RandRRequest.selectInput: break // no reply per spec; this server never emits RRScreenChangeNotify (fixed geometry), nothing to actually select into
        case RandRRequest.getScreenSizeRange: handleRRGetScreenSizeRange()
        case RandRRequest.getScreenResources, RandRRequest.getScreenResourcesCurrent: handleRRGetScreenResources()
        case RandRRequest.getOutputInfo: handleRRGetOutputInfo(body: body)
        case RandRRequest.getCrtcInfo: handleRRGetCrtcInfo(body: body)
        case RandRRequest.getOutputPrimary: handleRRGetOutputPrimary()
        case RandRRequest.getMonitors: handleRRGetMonitors()
        default: sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: UInt16(minor), majorOpcode: X11Opcode.randrExtension)
        }
    }

    private func handleRRQueryVersion() {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(1) // majorVersion
        // Report 1.5 (not just 1.2) specifically so a modern GDK/GTK
        // client prefers `RRGetMonitors` (one request, this server's
        // simplest path to implement correctly) over walking the older
        // `GetScreenResources`+`GetOutputInfo`+`GetCrtcInfo` per-output
        // graph - both paths ARE implemented here (older toolkits/direct
        // Xlib callers may still use the graph walk), but 1.5 lets a
        // client that supports it skip straight to the simpler one.
        w.writeU32(5) // minorVersion
        w.writePadding(16)
        sendReply(fixed24: w)
    }

    private func handleRRGetScreenSizeRange() {
        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        let w = X11ByteWriter(littleEndian: littleEndian)
        // A fixed-size virtual screen: min == max == current, matching
        // this server's actual behavior (no live resolution changes).
        w.writeU16(UInt16(screenW))
        w.writeU16(UInt16(screenH))
        w.writeU16(UInt16(screenW))
        w.writeU16(UInt16(screenH))
        w.writePadding(16)
        sendReply(fixed24: w)
    }

    private func handleRRGetScreenResources() {
        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(currentX11Timestamp) // timestamp
        w.writeU32(currentX11Timestamp) // configTimestamp
        w.writeU16(1) // nCrtcs
        w.writeU16(1) // nOutputs
        w.writeU16(1) // nModes
        let modeName = "\(screenW)x\(screenH)"
        w.writeU16(UInt16(modeName.utf8.count)) // nbytesNames
        w.writePadding(8) // pad1, pad2
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU32(randrCrtcID)
        extra.writeU32(randrOutputID)
        // xRRModeInfo (32 bytes) - dotClock/hSync/vSync/hTotal/vTotal are
        // fabricated (this is a virtual screen with no real scanout
        // timing), matching real xorg-server's own approach for a
        // synthetic/virtual mode.
        extra.writeU32(randrModeID)
        extra.writeU16(UInt16(screenW))
        extra.writeU16(UInt16(screenH))
        extra.writeU32(UInt32(screenW * screenH * 60)) // dotClock, ~60Hz nominal
        extra.writeU16(UInt16(screenW)) // hSyncStart
        extra.writeU16(UInt16(screenW)) // hSyncEnd
        extra.writeU16(UInt16(screenW)) // hTotal
        extra.writeU16(0) // hSkew
        extra.writeU16(UInt16(screenH)) // vSyncStart
        extra.writeU16(UInt16(screenH)) // vSyncEnd
        extra.writeU16(UInt16(screenH)) // vTotal
        extra.writeU16(UInt16(modeName.utf8.count)) // nameLength
        extra.writeU32(0) // modeFlags
        extra.writeString8Padded(modeName)
        sendReply(fixed24: w, extra: extra.bytes)
    }

    private func handleRRGetOutputInfo(body: [UInt8]) {
        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        // `output`/`configTimestamp` in the request aren't validated -
        // this server has exactly one output and answers for it
        // regardless of the ID sent, same reasoning as XI2's fixed
        // device IDs.
        let name = "MSL-1"
        // `xRRGetOutputInfoReply` is 36 bytes total (8-byte common header
        // + 28 fixed bytes), 4 bytes over this server's `sendReply`
        // convention of a 24-byte fixed part - `nClones`/`nameLength`
        // (the last 4 bytes of the real struct) are pushed into the
        // FRONT of `extra` instead. The wire bytes end up byte-for-byte
        // identical either way; only which Swift variable holds which
        // byte differs.
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(currentX11Timestamp) // timestamp
        w.writeU32(randrCrtcID) // crtc - this output is always driven by the one crtc
        // 25.4mm/inch / 96dpi = 0.264583 mm/pixel - matches
        // `X11ConnectionSetup`'s own `screenWidthPixels * 254 / 960`
        // exactly (this is the SAME nominal-96dpi convention, just
        // computed as a `Double` here instead of integer math). Confirmed
        // live (2026-09-03) this genuinely matters, not just cosmetic: an
        // earlier version of this line had a stray extra `* 1000 / 96`
        // factor, reporting a 1710px-wide screen as ~4714mm (4.7 METERS)
        // instead of ~452mm - implying a real DPI of ~9 instead of 96.
        // GTK3's monitor/DPI-aware layout code prefers exactly the
        // `XRRGetMonitors` reply this value feeds (RandR 1.5, the whole
        // reason this server advertises it - see `handleRRQueryVersion`'s
        // doc comment) over older core-protocol screen info, so Pango's
        // OWN font-rendering DPI could disagree with whatever DPI
        // reference GTK's layout/size-negotiation pass used - a
        // systematic mismatch that plausibly explains "every GTK app's
        // default window renders its content slightly taller than its
        // own computed natural window size, clipping the last widget" -
        // reproduced live with a custom test app (`gtk-tests/
        // 02_menus_dialogs.c`) where a bottom-packed label never even
        // got a draw call sent for it (a client-side layout decision, not
        // an mslgd rendering bug) regardless of whether an explicit
        // window size hint was given.
        w.writeU32(UInt32(Double(screenW) * 0.264583)) // mmWidth
        w.writeU32(UInt32(Double(screenH) * 0.264583)) // mmHeight
        w.writeU8(RandROutputConnection.connected)
        w.writeU8(0) // subpixelOrder: SubPixelUnknown
        w.writeU16(1) // nCrtcs (possible crtcs this output could use)
        w.writeU16(1) // nModes
        w.writeU16(1) // nPreferred (the first mode in the list below IS the preferred one)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU16(0) // nClones
        extra.writeU16(UInt16(name.utf8.count)) // nameLength
        extra.writeU32(randrCrtcID) // possible-crtcs list
        extra.writeU32(randrModeID) // modes list
        // (no clone IDs - nClones is 0)
        extra.writeString8Padded(name)
        sendReply(fixed24: w, extra: extra.bytes, detail: 0) // detail: status = Success
    }

    private func handleRRGetCrtcInfo(body: [UInt8]) {
        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(currentX11Timestamp) // timestamp
        w.writeI16(0) // x
        w.writeI16(0) // y
        w.writeU16(UInt16(screenW))
        w.writeU16(UInt16(screenH))
        w.writeU32(randrModeID)
        w.writeU16(1) // rotation: Rotate_0
        w.writeU16(1) // rotations: only Rotate_0 supported
        w.writeU16(1) // nOutput
        w.writeU16(1) // nPossibleOutput
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU32(randrOutputID) // outputs currently driven by this crtc
        extra.writeU32(randrOutputID) // possible outputs
        sendReply(fixed24: w, extra: extra.bytes, detail: 0) // detail: status = Success
    }

    private func handleRRGetOutputPrimary() {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(randrOutputID)
        w.writePadding(20)
        sendReply(fixed24: w)
    }

    private func handleRRGetMonitors() {
        let (screenW, screenH) = Self.mainScreenSizeInPixels()
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(currentX11Timestamp) // timestamp
        w.writeU32(1) // nmonitors
        w.writeU32(1) // noutputs
        w.writePadding(12)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU32(state.internAtom("MSL-1", onlyIfExists: false)) // xRRMonitorInfo.name
        extra.writeU8(1) // primary = True
        extra.writeU8(1) // automatic = True
        extra.writeU16(1) // noutput
        extra.writeI16(0) // x
        extra.writeI16(0) // y
        extra.writeU16(UInt16(screenW))
        extra.writeU16(UInt16(screenH))
        // See `handleRRGetOutputInfo`'s doc comment on this exact formula
        // - the corrected, dimensionally-right nominal-96dpi conversion.
        extra.writeU32(UInt32(Double(screenW) * 0.264583)) // widthInMillimeters
        extra.writeU32(UInt32(Double(screenH) * 0.264583)) // heightInMillimeters
        extra.writeU32(randrOutputID)
        sendReply(fixed24: w, extra: extra.bytes)
    }

    // MARK: - XC-MISC extension

    /// Real resource-ID range bookkeeping, not stubbed-out: `libX11`
    /// itself (`_XAllocID`'s low-on-IDs path) can call
    /// `XCMiscGetXIDRange`/`GetXIDList` when a connection is running low
    /// on self-allocatable resource IDs within its `resourceIdBase`/
    /// `resourceIdMask` range - this server hands out exactly that same
    /// range back (see `resourceIdBase`'s own doc comment for why a huge,
    /// mostly-unused 0x00200000-wide range per connection already makes
    /// this a rare real-world path either way).
    private func handleXCMiscRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case XCMiscRequest.getVersion:
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writeU16(1) // majorVersion
            w.writeU16(1) // minorVersion
            w.writePadding(20)
            sendReply(fixed24: w)
        case XCMiscRequest.getXIDRange:
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writeU32(resourceIdBase | 1) // start_id - `1` (not `0`, a reserved/invalid XID) is the lowest real ID this server hands a client
            w.writeU32(resourceIdMask - 5) // count - the full range, minus the handful of fixed IDs (root/colormap/randr output+crtc+mode) parked at its top
            w.writePadding(16)
            sendReply(fixed24: w)
        case XCMiscRequest.getXIDList:
            // A real server would hand back `count` currently-UNUSED IDs
            // from within its range; this server's resource-ID space is
            // enormous relative to any realistic single-app usage (see
            // `GetXIDRange` above), so reporting "none pre-allocated, use
            // GetXIDRange's plain sequential range instead" (an empty
            // list) is a real, spec-legal answer, not a placeholder.
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writeU32(0) // count
            w.writePadding(20)
            sendReply(fixed24: w)
        default:
            sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: UInt16(minor), majorOpcode: X11Opcode.xcMiscExtension)
        }
    }

    // MARK: - SHAPE extension

    /// Answers every SHAPE request for real protocol correctness (no
    /// hangs/`BadImplementation` errors - the same class of bug XI2/XKB
    /// both hit early in their own implementations) and stores the
    /// requested BOUNDING shape on `WindowRecord.boundingShapeRects`, but
    /// does NOT yet actually clip the window's paintable area or hit-
    /// testing to a non-rectangular shape - `X11CanvasView`'s rendering
    /// path and `mouseDown`/pointer-event routing both still treat every
    /// window as its full rectangular frame regardless of what shape was
    /// set. Real follow-up to close that gap: build a `CGPath` from
    /// `boundingShapeRects` (union of the rects, per spec) and apply it
    /// as `NSView.layer?.mask` (a `CAShapeLayer`) in the window's own
    /// paint path, PLUS check the shape before delivering a synthesized
    /// click through to a window whose shape doesn't cover that point
    /// (this second half matters more in practice - an unshaped click-
    /// through is what makes a shaped popup/systray icon feel "off",
    /// more than the visual clipping alone).
    private func handleShapeRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case ShapeRequest.queryVersion:
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writeI16(1) // majorVersion
            w.writeI16(1) // minorVersion
            w.writePadding(20)
            sendReply(fixed24: w)
        case ShapeRequest.rectangles: handleShapeRectangles(body: body)
        case ShapeRequest.mask: handleShapeMask(body: body)
        case ShapeRequest.combine: handleShapeCombine(body: body)
        case ShapeRequest.offset: handleShapeOffset(body: body)
        case ShapeRequest.queryExtents: handleShapeQueryExtents(body: body)
        case ShapeRequest.selectInput: break // no reply per spec; this server never emits ShapeNotify (shapes only ever change via a client's own request, which it already knows about)
        case ShapeRequest.inputSelected:
            // `xShapeInputSelectedReply`'s `detail` byte IS the whole
            // answer (`enabled`/`bReply`) - no fixed-body fields beyond
            // the common reply header at all, unlike every other SHAPE
            // reply.
            let w = X11ByteWriter(littleEndian: littleEndian)
            w.writePadding(24)
            sendReply(fixed24: w, detail: 0) // detail: enabled = False - ShapeSelectInput is a no-op above, nothing is ever actually "selected"
        case ShapeRequest.getRectangles: handleShapeGetRectangles(body: body)
        default:
            sendError(code: X11ErrorCode.implementation, badValue: 0, minorOpcode: UInt16(minor), majorOpcode: X11Opcode.shapeExtension)
        }
    }

    /// `ShapeRectangles` (minor 1) - wire layout: `window`(4) +
    /// `ordering`(1, unused here - rect order never affects a union) +
    /// pad(3) + `xOffset`(2) + `yOffset`(2), then `LISTofRECTANGLE` (8
    /// bytes each). No reply per spec.
    private func handleShapeRectangles(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(1) // operation (Set/Union/...) - this server always just REPLACES with the new list, matching the common `Set` case every real client actually sends
        r.skip(1) // destKind (bounding/clip/input) - only bounding is tracked, see WindowRecord.boundingShapeRects' doc comment
        r.skip(2) // pad
        let wid = r.readU32()
        let xOffset = Double(r.readI16())
        let yOffset = Double(r.readI16())
        guard let record = state.window(wid) else { return }
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: xOffset + Double(x), y: yOffset + Double(y), width: Double(w), height: Double(h)))
        }
        record.boundingShapeRects = rects.isEmpty ? nil : rects
    }

    /// `ShapeMask` (minor 2) - a bitmap-pixmap-defined shape (1 = inside,
    /// 0 = outside) rather than an explicit rectangle list. Real clients
    /// use this far less often than `ShapeRectangles`/`ShapeCombine`
    /// (mostly for genuinely irregular shapes like an app icon's alpha
    /// silhouette) - this server doesn't rasterize the mask pixmap into
    /// rectangles, so a client using ONLY this call sees no shape
    /// enforcement even once the visual/hit-testing follow-up above
    /// lands. No reply per spec.
    ///
    /// Implemented for a TOP-LEVEL window's bounding shape with op Set, which
    /// is what shaped Xt clients (xeyes) send: the window becomes
    /// non-opaque and `X11CanvasView.shapeMask` cuts its content to the
    /// mask. `src = None` removes the shape. Clip/input kinds, other ops and
    /// child windows are still accepted without effect. Nothing else shapes
    /// visually, so ordinary windows draw exactly as before.
    private func handleShapeMask(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let op = r.readU8()
        let destKind = r.readU8()
        r.skip(2)
        let wid = r.readU32()
        let xOff = Int(r.readI16())
        let yOff = Int(r.readI16())
        let src = r.readU32()
        guard op == 0, destKind == 0, let record = state.window(wid), record.isTopLevel else { return }
        let pixmap = src == 0 ? nil : state.pixmap(src)
        guard src == 0 || pixmap != nil else { return }
        // Async on main, like the drawing requests that filled the mask
        // pixmap: the main queue runs them in order, so the pixmap is
        // complete by the time this reads it.
        DispatchQueue.main.async {
            guard let view = record.view, let window = record.nsWindow else { return }
            guard let pixmap else {
                view.shapeMask = nil
                window.isOpaque = true
                window.invalidateShadow()
                return
            }
            let bytes = Self.shapeMaskRGBA(from: pixmap.bitmapContext, sourceWidth: pixmap.pixelWidth, sourceHeight: pixmap.pixelHeight,
                                           width: view.pixelWidth, height: view.pixelHeight, xOffset: xOff, yOffset: yOff)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let mask = CGImage(width: view.pixelWidth, height: view.pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: view.pixelWidth * 4, space: x11DeviceRGB,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            view.shapeMask = mask
            window.invalidateShadow()
        }
    }

    /// RGBA (premultiplied white, alpha 255 inside / 0 outside) for a
    /// `width` x `height` window from a depth-1 mask pixmap placed at
    /// (`xOffset`, `yOffset`). Rows are raw buffer rows, the X11 row order
    /// `bitmapContext.makeImage()` also uses. A mask bit is SET where the
    /// pixmap pixel is non-zero: a depth-1 GC foreground 1 draws a non-zero
    /// colour, foreground 0 draws black, and never-drawn pixels are all 0.
    static func shapeMaskRGBA(from ctx: CGContext, sourceWidth: Int, sourceHeight: Int,
                              width: Int, height: Int, xOffset: Int, yOffset: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        guard let base = ctx.data else { return out }
        let srcRow = ctx.bytesPerRow
        let src = base.bindMemory(to: UInt8.self, capacity: srcRow * sourceHeight)
        for y in 0..<height {
            let sy = y - yOffset
            guard sy >= 0, sy < sourceHeight else { continue }
            for x in 0..<width {
                let sx = x - xOffset
                guard sx >= 0, sx < sourceWidth else { continue }
                let s = sy * srcRow + sx * 4
                guard src[s] | src[s + 1] | src[s + 2] != 0 else { continue }
                let d = (y * width + x) * 4
                out[d] = 255; out[d + 1] = 255; out[d + 2] = 255; out[d + 3] = 255
            }
        }
        return out
    }

    /// `ShapeCombine` (minor 3) - combines one window's existing shape
    /// with another window's shape (e.g. "clip my shape to my parent's").
    /// This server doesn't track per-window shape COMBINATION graphs
    /// (only the last-set rectangle list per window), so this is
    /// accepted (no hang/error) but not actually applied. No reply per
    /// spec.
    private func handleShapeCombine(body: [UInt8]) {}

    /// `ShapeOffset` (minor 4) - shifts an already-set shape in place. No
    /// reply per spec; not applied for the same reason as `ShapeMask`.
    private func handleShapeOffset(body: [UInt8]) {}

    /// `ShapeQueryExtents` (minor 5) - real layout matches
    /// `xShapeQueryExtentsReply`: `boundingShaped`/`clipShaped` (1 byte
    /// each, via `detail` and the fixed body's first byte respectively),
    /// then the bounding/clip shapes' own bounding boxes.
    private func handleShapeQueryExtents(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        let record = state.window(wid)
        let rects = record?.boundingShapeRects
        let bounds = rects?.reduce(CGRect.null) { $0.union($1) } ?? .zero
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(rects != nil ? 1 : 0) // clipShaped - this server never sets a SEPARATE clip shape from the bounding one, so they're always identical
        w.writePadding(3)
        w.writeI16(Int16(bounds.origin.x)) // xBoundingShape
        w.writeI16(Int16(bounds.origin.y)) // yBoundingShape
        w.writeU16(UInt16(max(0, bounds.width))) // widthBoundingShape
        w.writeU16(UInt16(max(0, bounds.height))) // heightBoundingShape
        w.writeI16(Int16(bounds.origin.x)) // xClipShape
        w.writeI16(Int16(bounds.origin.y)) // yClipShape
        w.writeU16(UInt16(max(0, bounds.width))) // widthClipShape
        w.writeU16(UInt16(max(0, bounds.height))) // heightClipShape
        sendReply(fixed24: w, detail: rects != nil ? 1 : 0) // detail: boundingShaped
    }

    /// `ShapeGetRectangles` (minor 8) - echoes back whatever
    /// `ShapeRectangles` last set (or the window's full rectangular frame
    /// if nothing was ever set - the correct default per spec: an
    /// unshaped window's "shape" IS its whole frame).
    private func handleShapeGetRectangles(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let wid = r.readU32()
        r.skip(4) // kind(1) + pad(3) - only bounding is ever tracked
        let record = state.window(wid)
        let rects = record?.boundingShapeRects ?? [CGRect(origin: .zero, size: record?.frame.size ?? .zero)]
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU32(UInt32(rects.count))
        w.writeU8(0) // ordering: Unsorted
        w.writePadding(19)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        for rect in rects {
            extra.writeI16(Int16(rect.origin.x))
            extra.writeI16(Int16(rect.origin.y))
            extra.writeU16(UInt16(max(0, rect.width)))
            extra.writeU16(UInt16(max(0, rect.height)))
        }
        sendReply(fixed24: w, extra: extra.bytes)
    }

    // MARK: - RENDER extension

    /// This server's only three `PictFormat` IDs - deliberately not real
    /// XIDs allocated through the normal resource-ID scheme (see
    /// `resourceIdBase`'s doc comment elsewhere): `QueryPictFormats`
    /// hands these out as fixed, well-known constants and every other
    /// RENDER request just echoes one back, so there's nothing to look up
    /// or collide with. A8 (coverage-only masks - anti-aliased text/shape
    /// edges), RGB24 (opaque window content, matches this server's one
    /// real visual), ARGB32 (translucent content, icons). Real Xorg
    /// servers report more (X8R8G8B8 at depth 24 with padding bits, A1,
    /// indexed formats, ...) - GTK/cairo's actual hot paths only ever
    /// touch these three.
    private static let renderFormatA8: UInt32 = 1
    private static let renderFormatRGB24: UInt32 = 2
    private static let renderFormatARGB32: UInt32 = 3
    private static let renderFormatA1: UInt32 = 4

    private func handleRenderRequest(minor: UInt8, body: [UInt8]) {
        switch minor {
        case X11RenderOpcode.queryVersion: handleRenderQueryVersion()
        case X11RenderOpcode.queryPictFormats: handleRenderQueryPictFormats()
        case X11RenderOpcode.createPicture: handleRenderCreatePicture(body: body)
        case X11RenderOpcode.changePicture: handleRenderChangePicture(body: body)
        case X11RenderOpcode.setPictureClipRectangles: handleRenderSetPictureClipRectangles(body: body)
        case X11RenderOpcode.freePicture: handleRenderFreePicture(body: body)
        case X11RenderOpcode.composite: handleRenderComposite(body: body)
        case X11RenderOpcode.trapezoids: handleRenderTrapezoids(body: body)
        case X11RenderOpcode.createGlyphSet: handleRenderCreateGlyphSet(body: body)
        case X11RenderOpcode.freeGlyphSet: handleRenderFreeGlyphSet(body: body)
        case X11RenderOpcode.addGlyphs: handleRenderAddGlyphs(body: body)
        case X11RenderOpcode.compositeGlyphs8: handleRenderCompositeGlyphs(body: body, idSize: 1)
        case X11RenderOpcode.compositeGlyphs16: handleRenderCompositeGlyphs(body: body, idSize: 2)
        case X11RenderOpcode.compositeGlyphs32: handleRenderCompositeGlyphs(body: body, idSize: 4)
        case X11RenderOpcode.fillRectangles: handleRenderFillRectangles(body: body)
        case X11RenderOpcode.createSolidFill: handleRenderCreateSolidFill(body: body)
        case X11RenderOpcode.createLinearGradient: handleRenderCreateLinearGradient(body: body)
        case X11RenderOpcode.setPictureTransform: handleRenderSetPictureTransform(body: body)
        case X11RenderOpcode.setPictureFilter: handleRenderSetPictureFilter(body: body)
        default:
            // ChangePicture, radial/conical gradients, SetPictureTransform, ... - not implemented
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] renderUnhandled minor=\(minor)\n".data(using: .utf8)!)
            }
        }
    }

    /// `SetPictureTransform` (RENDER 28, no reply): picture + 9 FIXED.
    /// Was unhandled, so every image cairo scaled or rotated was drawn at
    /// 1:1 from its untransformed origin (Audacity's banner came out cut
    /// off on the left). Honoured for image sources - see
    /// `drawPictureImageSource`.
    private func handleRenderSetPictureTransform(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        guard r.remaining >= 36, let picture = state.picture(pictureID) else { return }
        let fixed = (0..<9).map { _ in Int32(bitPattern: r.readU32()) }
        picture.transform = renderPictureTransform(fixed)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] setPictureTransform picture=\(pictureID) matrix=\(fixed.map { Double($0) / 65536 }) -> \(String(describing: picture.transform))\n".data(using: .utf8)!)
        }
    }

    /// `SetPictureFilter` (RENDER 30, no reply): picture, name length, name,
    /// optional params (ignored). Only nearest vs smooth is honoured.
    private func handleRenderSetPictureFilter(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        let nameLength = Int(r.readU16())
        r.skip(2)
        guard r.remaining >= nameLength, let picture = state.picture(pictureID) else { return }
        let name = r.readString8(nameLength).lowercased()
        picture.filterNearest = name == "nearest" || name == "fast"
    }

    private func handleRenderQueryVersion() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(0) // major
        fw.writeU32(11) // minor - 0.11 comfortably covers what GTK/cairo actually probe for
        fw.writePadding(16)
        sendReply(fixed24: fw)
    }

    /// One screen, one depth (24-bit - this server's only real visual,
    /// mapped to `renderFormatRGB24`). `renderFormatARGB32`/`A8` are
    /// still fully usable via `CreatePicture` against a *pixmap* (no
    /// visual needed for those - visuals only matter for windows) - real
    /// GTK/cairo usage (offscreen glyph/icon compositing) goes through
    /// pixmaps almost exclusively anyway.
    private func handleRenderQueryPictFormats() {
        let fixed = X11ByteWriter(littleEndian: littleEndian)
        fixed.writeU32(4) // num-formats
        fixed.writeU32(1) // num-screens
        fixed.writeU32(2) // num-depths
        fixed.writeU32(2) // num-visuals
        fixed.writeU32(0) // num-subpixel
        fixed.writeU32(0) // pad

        let extra = X11ByteWriter(littleEndian: littleEndian)
        func writeFormat(id: UInt32, depth: UInt8, redShift: UInt16, redMask: UInt16, greenShift: UInt16, greenMask: UInt16, blueShift: UInt16, blueMask: UInt16, alphaShift: UInt16, alphaMask: UInt16) {
            extra.writeU32(id)
            extra.writeU8(1) // type = Direct
            extra.writeU8(depth)
            extra.writePadding(2)
            extra.writeU16(redShift); extra.writeU16(redMask)
            extra.writeU16(greenShift); extra.writeU16(greenMask)
            extra.writeU16(blueShift); extra.writeU16(blueMask)
            extra.writeU16(alphaShift); extra.writeU16(alphaMask)
            extra.writeU32(0) // colormap
        }
        writeFormat(id: Self.renderFormatA8, depth: 8, redShift: 0, redMask: 0, greenShift: 0, greenMask: 0, blueShift: 0, blueMask: 0, alphaShift: 0, alphaMask: 0xFF)
        writeFormat(id: Self.renderFormatRGB24, depth: 24, redShift: 16, redMask: 0xFF, greenShift: 8, greenMask: 0xFF, blueShift: 0, blueMask: 0xFF, alphaShift: 0, alphaMask: 0)
        writeFormat(id: Self.renderFormatARGB32, depth: 32, redShift: 16, redMask: 0xFF, greenShift: 8, greenMask: 0xFF, blueShift: 0, blueMask: 0xFF, alphaShift: 24, alphaMask: 0xFF)
        // PictStandardA1 - see the depth-1 pixmap format in
        // `X11ConnectionSetup` for the GTK crash its absence caused.
        writeFormat(id: Self.renderFormatA1, depth: 1, redShift: 0, redMask: 0, greenShift: 0, greenMask: 0, blueShift: 0, blueMask: 0, alphaShift: 0, alphaMask: 0x1)

        extra.writeU32(2) // this screen's nDepth
        extra.writeU32(Self.renderFormatRGB24) // fallback format
        extra.writeU8(24) // depth
        extra.writeU8(0) // pad
        extra.writeU16(1) // nVisuals
        extra.writePadding(4)
        extra.writeU32(visualID)
        extra.writeU32(Self.renderFormatRGB24)
        // Depth 32 entry - see `argbVisualID`'s doc comment. Real Xorg
        // maps each visual to exactly one format; giving the ARGB visual
        // ARGB32 (not XRGB32) here is what actually lets clients get
        // real alpha compositing when they create a Picture straight
        // from a window using this visual (not just from a pixmap).
        extra.writeU8(32) // depth
        extra.writeU8(0) // pad
        extra.writeU16(1) // nVisuals
        extra.writePadding(4)
        extra.writeU32(argbVisualID)
        extra.writeU32(Self.renderFormatARGB32)

        sendReply(fixed24: fixed, extra: extra.bytes)
    }

    /// `format` selects a pixel layout this server doesn't actually vary
    /// per-Picture (see `GCRecord.foreground`'s doc comment on the same
    /// simplification for GCs) - not tracked. Of the remaining optional
    /// `values` (repeat, clip, alpha-map, ...), only `CPRepeat` (value-mask
    /// bit `0x1`) is - see `PictureRecord.repeatNormal`'s doc comment for
    /// why: confirmed live real toolkits actually set it through
    /// `ChangePicture` (`handleRenderChangePicture`) rather than here, but
    /// nothing stops a client from passing it at creation time too (the
    /// protocol explicitly allows both), so both parse it identically.
    private func handleRenderCreatePicture(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        let drawableID = r.readU32()
        let format = r.readU32()
        let valueMask = r.readU32()
        let picture = state.makePicture(id: pictureID)
        picture.drawableID = drawableID
        applyPictureValues(valueMask: valueMask, from: r, to: picture)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] createPicture picture=\(pictureID) drawable=\(drawableID) format=\(format) valueMask=0x\(String(valueMask, radix: 16)) repeatNormal=\(picture.repeatNormal)\n".data(using: .utf8)!)
        }
    }

    /// A Picture's optional attribute `values` are a `LISTofVALUE`: one
    /// `CARD32` per set `value-mask` bit, **in ascending bit order** (the
    /// real xserver walks them with `lowbit(vmask)`, see `render/picture.c`'s
    /// `ChangePicture`). Every present bit's value must be consumed in order
    /// even when it isn't acted on, or the reader desyncs and every value
    /// after it is garbage - which is why this walks the whole list rather
    /// than seeking directly to the one or two bits actually tracked.
    ///
    /// Only two are acted on:
    ///
    /// - `CPRepeat` (`0x1`) - see `PictureRecord.repeatNormal`.
    /// - `CPClipMask` (`0x40`) - resets the Picture's clip. Confirmed live
    ///   this is what broke `galculator`'s ENTIRE button grid (blank fills,
    ///   invisible labels, only a stray top/left border sliver per button):
    ///   cairo reuses ONE destination Picture for every widget in the
    ///   window, sets a tight per-widget clip via
    ///   `SetPictureClipRectangles` before drawing that widget, then issues
    ///   `ChangePicture(clip-mask: None)` to reset it back to unclipped
    ///   before the next one. That reset fired 522 times in a single
    ///   galculator launch (201 of them on its one main destination
    ///   Picture) and was read-and-discarded here, so the PREVIOUS widget's
    ///   12x12 clip stayed in force and silently clipped away everything
    ///   drawn afterwards - button backgrounds, borders and label glyphs
    ///   alike. Traced exactly this: glyph runs placing real glyphs at
    ///   (294,129) while the stale clip was a 12x12 box at (269,118),
    ///   consistently ~25-33px away, i.e. the button drawn one grid cell
    ///   EARLIER. Exactly the same bug (and the same fix) as the core-GC
    ///   `GCClipMask` gap fixed previously - see `applyGCValues`.
    ///
    /// A non-`None` clip-mask names a real 1-bit Pixmap to clip through,
    /// which this server doesn't implement; clearing the rectangle clip is
    /// the closer approximation either way (the rectangles it replaces are
    /// definitively no longer in force), and matches what `applyGCValues`
    /// already does for the same attribute.
    private func applyPictureValues(valueMask: UInt32, from r: X11ByteReader, to picture: X11State.PictureRecord) {
        var remainingMask = valueMask
        while remainingMask != 0, r.remaining >= 4 {
            let bit = remainingMask & (~remainingMask &+ 1) // lowest set bit
            remainingMask &= ~bit
            let value = r.readU32()
            switch bit {
            case 0x1: picture.repeatNormal = value != 0
            case 0x40:
                // `CPClipMask` with `None` (0) genuinely means "drop the
                // clip". A NON-zero value is a real mask Pixmap and
                // clearing the clip for it silently draws UNCLIPPED -
                // traced here because that is exactly how a rounded
                // corner would come out square.
                if X11Trace.enabled, value != 0 {
                    FileHandle.standardError.write("[x11] CPClipMask NON-NONE value=\(value) picture=\(picture.id)\n".data(using: .utf8)!)
                }
                picture.clipRectangles = nil
            default:
                if X11Trace.enabled {
                    FileHandle.standardError.write("[x11] pictureValue unhandled bit=0x\(String(bit, radix: 16)) value=\(value) picture=\(picture.id)\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// `ChangePicture` (RENDER opcode 5) - confirmed live (tracing every
    /// otherwise-silently-dropped RENDER minor opcode while chasing
    /// galculator's blank/partial button rendering, see
    /// `handleRenderRequest`'s `renderUnhandled` trace) this is the
    /// request cairo's xlib-render backend actually uses to set
    /// `CPRepeat` on a small, reusable rounded-corner alpha-coverage
    /// "stamp" Picture - not `CreatePicture`'s own value-mask, which is
    /// why that Picture's creation trace never showed the repeat bit set
    /// even though `Trapezoids`/`Composite` went on to sample it at
    /// `srcX`/`srcY` offsets far outside its tiny (e.g. 17x17) pixel
    /// bounds - offsets that only make sense under wraparound (tiling)
    /// sampling. Fired 300+ times in one `galculator` launch alone.
    ///
    /// It carries a SECOND, even more consequential attribute this server
    /// originally ignored: `CPClipMask`, cairo's per-widget clip RESET -
    /// see `applyPictureValues`' doc comment for the full trace evidence
    /// (it was single-handedly responsible for galculator's entire button
    /// grid rendering as blank/partial).
    private func handleRenderChangePicture(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        let valueMask = r.readU32()
        guard let picture = state.picture(pictureID) else { return }
        applyPictureValues(valueMask: valueMask, from: r, to: picture)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] changePicture picture=\(pictureID) valueMask=0x\(String(valueMask, radix: 16)) repeatNormal=\(picture.repeatNormal) clip=\(String(describing: picture.clipRectangles))\n".data(using: .utf8)!)
        }
    }

    /// `SetPictureClipRectangles` (RENDER opcode 6) - the RENDER-extension
    /// equivalent of core `SetClipRectangles` (opcode 59,
    /// `handleSetClipRectangles`), same wire shape (`picture`(4) +
    /// `clip-x-origin`/`clip-y-origin` (INT16 each) + a `LISTofRECTANGLE`,
    /// 8 bytes each). Was previously COMPLETELY unimplemented - fell into
    /// `handleRenderRequest`'s `default: break` alongside `ChangePicture`
    /// and the gradient variants this server doesn't support, silently
    /// dropping every clip a client ever set on a Picture. This is a
    /// bigger gap in practice than the core-protocol version: cairo (and
    /// therefore most of GTK's and Qt's own actual drawing) issues nearly
    /// all its output through RENDER Pictures, not core GCs, so a client
    /// clipping a Picture to a widget's damaged region before compositing
    /// (routine - the same "clip to just what changed" pattern
    /// `handleCopyArea`'s own doc comment documents for the core-GC case)
    /// got that composite drawn completely unclipped instead - confirmed
    /// as a real, live bug via complex real-world apps (Krita, GNOME
    /// Chess) showing overlapping/misplaced icon and text content.
    /// Same "empty rectangle list means reset to unclipped" convention as
    /// the core version - `nil`, not an empty array, means "no clip"
    /// throughout this file.
    private func handleRenderSetPictureClipRectangles(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        let originX = Double(r.readI16())
        let originY = Double(r.readI16())
        guard let picture = state.picture(pictureID) else { return }
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: originX + Double(x), y: originY + Double(y), width: Double(w), height: Double(h)))
        }
        picture.clipRectangles = rects.isEmpty ? nil : rects
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] setPictureClipRectangles picture=\(pictureID) origin=(\(originX),\(originY)) rects=\(rects)\n".data(using: .utf8)!)
        }
    }

    private func handleRenderFreePicture(body: [UInt8]) {
        state.removePicture(X11ByteReader(body, littleEndian: littleEndian).readU32())
    }

    private func handleRenderCreateSolidFill(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        let red = r.readU16(); let green = r.readU16(); let blue = r.readU16(); let alpha = r.readU16()
        state.makePicture(id: pictureID).solidColor = (
            CGFloat(red) / 65535, CGFloat(green) / 65535, CGFloat(blue) / 65535, CGFloat(alpha) / 65535
        )
    }

    /// `CreateLinearGradient` - `cairo_pattern_create_linear`'s wire form
    /// (`cairo_set_source`+ any non-solid fill/stroke sends this, then
    /// `RenderComposite` with THIS picture as `src`). Wire layout: pid(4)
    /// + p1(POINTFIXED: x,y as FIXED, 4 bytes each) + p2(same) + nStops
    /// (4) + nStops FIXED offsets (4 each, 0.0-1.0 along the p1->p2 axis)
    /// + nStops COLORs (8 bytes each: red/green/blue/alpha as CARD16,
    /// same convention as `CreateSolidFill`). Confirmed live via the
    /// Layer-1 harness (`Guest/init/cairo-tests/03_clip_gradient.c`):
    /// silently unimplemented before this - the gradient Picture never
    /// existed server-side, so the `RenderComposite` that was supposed to
    /// paint it found no `src` picture and correctly no-opped, leaving a
    /// real gap (any GTK/cairo gradient - a common CSS button-background
    /// style) as blank space rather than an error.
    private func handleRenderCreateLinearGradient(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let pictureID = r.readU32()
        func readFixed() -> CGFloat { CGFloat(r.readI32()) / 65536 }
        let p1 = CGPoint(x: readFixed(), y: readFixed())
        let p2 = CGPoint(x: readFixed(), y: readFixed())
        let nStops = Int(r.readU32())
        guard nStops > 0, nStops < 1000 else { return }
        var stops: [CGFloat] = []
        stops.reserveCapacity(nStops)
        for _ in 0..<nStops { stops.append(readFixed()) }
        var colors: [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = []
        colors.reserveCapacity(nStops)
        for _ in 0..<nStops {
            let red = r.readU16(); let green = r.readU16(); let blue = r.readU16(); let alpha = r.readU16()
            colors.append((CGFloat(red) / 65535, CGFloat(green) / 65535, CGFloat(blue) / 65535, CGFloat(alpha) / 65535))
        }
        state.makePicture(id: pictureID).linearGradient = (p1: p1, p2: p2, stops: stops, colors: colors)
    }

    /// X11 RENDER's `PictOp` values, mapped to the closest native
    /// `CGBlendMode` - covers every op a real client is likely to send;
    /// anything unmapped (`Dst`, `Saturate`, ...) falls back to plain
    /// `Over`, the overwhelmingly common case in practice.
    private static func cgBlendMode(forPictOp op: UInt8) -> CGBlendMode {
        switch op {
        case 0: return .clear
        case 1: return .copy
        case 4: return .destinationOver
        case 5: return .sourceIn
        case 6: return .destinationIn
        case 7: return .sourceOut
        case 8: return .destinationOut
        case 9: return .sourceAtop
        case 10: return .destinationAtop
        case 11: return .xor
        case 12: return .plusLighter
        default: return .normal // Over (op=3), and anything unmapped
        }
    }

    private func handleRenderFillRectangles(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let op = r.readU8()
        r.skip(3)
        let dstID = r.readU32()
        let red = r.readU16(); let green = r.readU16(); let blue = r.readU16(); let alpha = r.readU16()
        guard let dstPicture = state.picture(dstID), let drawableID = dstPicture.drawableID,
              let target = state.drawable(drawableID) else { return }
        var rects: [CGRect] = []
        while r.remaining >= 8 {
            let x = r.readI16(); let y = r.readI16()
            let w = r.readU16(); let h = r.readU16()
            rects.append(CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h)))
        }
        guard !rects.isEmpty else { return }
        let color = x11Color(red: CGFloat(red) / 65535, green: CGFloat(green) / 65535, blue: CGFloat(blue) / 65535, alpha: CGFloat(alpha) / 65535)
        let blendMode = Self.cgBlendMode(forPictOp: op)
        let clip = dstPicture.clipRectangles
        DispatchQueue.main.async {
            let ctx = target.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setBlendMode(blendMode)
            ctx.setFillColor(color)
            for rect in rects { ctx.fill(rect) }
            ctx.restoreGState()
            target.notifyChanged()
        }
    }

    /// The one RENDER request that actually matters for how apps look:
    /// GTK/cairo composite anti-aliased text and shapes as "a solid (or
    /// image) source, drawn through an A8 coverage mask, blended onto the
    /// destination" - almost always `src`=`CreateSolidFill` + `mask`=a
    /// glyph/shape's alpha coverage rendered into a pixmap beforehand.
    /// `CGContext.clip(to:mask:)` maps onto that pattern directly (mask's
    /// luminosity/alpha becomes the clip), so there's no need to hand-roll
    /// per-pixel alpha blending the way a raw-framebuffer server has to.
    private func handleRenderComposite(body: [UInt8]) {
        guard body.count >= 32 else { return }
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let op = r.readU8()
        r.skip(3)
        let srcID = r.readU32()
        let maskID = r.readU32()
        let dstID = r.readU32()
        let srcX = r.readI16(); let srcY = r.readI16()
        let maskX = r.readI16(); let maskY = r.readI16()
        let dstX = r.readI16(); let dstY = r.readI16()
        let width = r.readU16(); let height = r.readU16()
        guard width > 0, height > 0 else { return }

        guard let dstPicture = state.picture(dstID), let dstDrawableID = dstPicture.drawableID,
              let dstTarget = state.drawable(dstDrawableID) else {
            X11Trace.composite(op: op, srcPictureID: srcID, srcHasSolid: false, srcDrawableID: nil, maskPictureID: maskID, dstPictureID: dstID, dstDrawableID: nil, outcome: "dropped: no dst picture/drawable")
            return
        }
        guard let srcPicture = state.picture(srcID) else {
            X11Trace.composite(op: op, srcPictureID: srcID, srcHasSolid: false, srcDrawableID: nil, maskPictureID: maskID, dstPictureID: dstID, dstDrawableID: dstDrawableID, outcome: "dropped: no src picture")
            return
        }
        let maskPicture = maskID == 0 ? nil : state.picture(maskID)
        let blendMode = Self.cgBlendMode(forPictOp: op)
        guard op != 2 else { return } // Dst: destination unchanged by definition, nothing to draw

        // Resolve every drawable this request touches to its actual
        // `X11Drawable` object HERE, synchronously, on the request-reading
        // thread - exactly like `handleCopyArea` already does - rather
        // than re-looking-up by ID inside the `DispatchQueue.main.async`
        // block below. Confirmed live via the Layer-0 harness (`Guest/
        // init/x11-tests/04_render_extension.c`'s pixmap-backed-image
        // composite): a client that composites from a scratch pixmap and
        // then immediately frees it (the standard offscreen/glyph-cache
        // idiom cairo/GDK use constantly) races `handleFreePixmap`, which
        // removes the pixmap from `state` SYNCHRONOUSLY, against this
        // handler's own drawing, which used to be entirely deferred - the
        // free could land before the deferred block ever ran, so its
        // by-ID re-lookup silently returned nil and the whole composite
        // got dropped. Capturing the object reference up front (a class,
        // so the object itself stays alive via ARC even after `state`
        // drops its dictionary entry) sidesteps the race completely.
        let maskTarget = maskPicture?.drawableID.flatMap { state.drawable($0) }
        let srcTarget = srcPicture.drawableID.flatMap { state.drawable($0) }
        // Captured now, like the drawables above: cairo resets a picture's
        // transform right after compositing with it.
        let srcTransform = srcPicture.transform
        let srcNearest = srcPicture.filterNearest
        let maskTransform = maskPicture?.transform
        let dstClip = dstPicture.clipRectangles
        X11Trace.composite(op: op, srcPictureID: srcID, srcHasSolid: srcPicture.solidColor != nil, srcDrawableID: srcPicture.drawableID, maskPictureID: maskID, dstPictureID: dstID, dstDrawableID: dstDrawableID, outcome: "dispatched w=\(width) h=\(height) dstX=\(dstX) dstY=\(dstY) srcX=\(srcX) srcY=\(srcY)")

        DispatchQueue.main.async {
            let ctx = dstTarget.bitmapContext
            let dstRect = CGRect(x: Double(dstX), y: Double(dstY), width: Double(width), height: Double(height))
            ctx.saveGState()
            // The destination Picture's own `SetPictureClipRectangles`
            // clip, applied BEFORE the mask-image clip below - CGContext
            // clips intersect when stacked, matching RENDER's own "both
            // the picture's clip AND the mask must be satisfied" semantic.
            if let dstClip { ctx.clip(to: dstClip) }
            ctx.setBlendMode(blendMode)

            var constantAlpha: CGFloat = 1
            if let maskPicture {
                if let maskTarget {
                    if X11Trace.enabled {
                        FileHandle.standardError.write("[x11] maskDebug maskID=\(maskID) maskDrawableID=\(String(describing: maskPicture.drawableID)) maskX=\(maskX) maskY=\(maskY) maskPixelH=\(maskTarget.pixelHeight) maskPixelW=\(maskTarget.pixelWidth) width=\(width) height=\(height)\n".data(using: .utf8)!)
                    }
                    // Cropped in top-left space and clipped with the matching
                    // orientation - see `clipToMaskTopLeftOriented`. The old
                    // flipped crop mirrored every asymmetric mask (GIMP's
                    // tool-option labels). A partly out-of-bounds mask clips
                    // to the part that exists instead of being stretched.
                    if let maskTransform {
                        // Mirrored/scaled mask (GTK's linked-button corners) -
                        // see `clipToTransformedMask`. Untransformed masks
                        // keep the path below unchanged.
                        if let fullMask = maskTarget.bitmapContext.makeImage() {
                            clipToTransformedMask(fullMask, sourceWidth: maskTarget.pixelWidth, sourceHeight: maskTarget.pixelHeight,
                                                  transform: maskTransform, sampleX: Int(maskX), sampleY: Int(maskY),
                                                  destRect: dstRect, on: ctx)
                        }
                    } else if let rects = imageSampleRects(sourceWidth: maskTarget.pixelWidth, sourceHeight: maskTarget.pixelHeight,
                                                    sampleX: Int(maskX), sampleY: Int(maskY), destRect: dstRect),
                       let maskImage = maskTarget.bitmapContext.makeImage()?.cropping(to: rects.source) {
                        clipToMaskTopLeftOriented(maskImage, in: rects.destination, on: ctx)
                    } else if X11Trace.enabled {
                        FileHandle.standardError.write("[x11] maskDebug CROP FAILED (nil) for maskID=\(maskID)\n".data(using: .utf8)!)
                    }
                } else if let solid = maskPicture.solidColor {
                    constantAlpha = solid.a
                }
            }
            ctx.setAlpha(constantAlpha)

            if let solid = srcPicture.solidColor {
                ctx.setFillColor(x11Color(red: solid.r, green: solid.g, blue: solid.b, alpha: solid.a))
                ctx.fill(dstRect)
            } else if let gradient = srcPicture.linearGradient, !gradient.colors.isEmpty {
                // `gradient.p1`/`p2` are already in this same top-left-
                // origin, Y-down coordinate space as `dstRect` (cairo's
                // pattern coordinates align 1:1 with the destination
                // surface's own here, no separate pattern matrix in play
                // for the common case this exists to cover) - usable
                // as-is, no extra flip/offset math needed.
                let cgColors = gradient.colors.map { x11Color(red: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) } as CFArray
                if let cgGradient = CGGradient(colorsSpace: x11DeviceRGB, colors: cgColors, locations: gradient.stops) {
                    ctx.saveGState()
                    ctx.clip(to: dstRect)
                    ctx.drawLinearGradient(cgGradient, start: gradient.p1, end: gradient.p2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    ctx.restoreGState()
                }
            } else if let srcTarget {
                // See `drawPictureImageSource`'s doc comment - handles
                // both a plain one-shot image source and a `ChangePicture`
                // `CPRepeat=Normal` tiling source (the common cairo
                // "small reusable stamp" idiom) identically.
                self.drawPictureImageSource(srcTarget, sampleOriginX: Int(srcX), sampleOriginY: Int(srcY), repeatNormal: srcPicture.repeatNormal, destRect: dstRect,
                                            transform: srcTransform, nearest: srcNearest, on: ctx)
            }

            ctx.restoreGState()
            dstTarget.notifyChanged()
        }
    }

    /// `RenderTrapezoids` (RENDER minor opcode 10) - cairo's actual anti-
    /// aliased-fill primitive for anything that isn't an axis-aligned
    /// rectangle: a filled circle, a rounded corner, an arbitrary path,
    /// and (depending on font backend/config) even glyph rendering all go
    /// through this on cairo's xlib/RENDER backend - `cairo_fill`/
    /// `cairo_arc` tessellate the shape into trapezoids client-side, then
    /// send them all in one request to be rasterized+composited server-
    /// side. Confirmed live via the Layer-1 harness (`Guest/init/cairo-
    /// tests/01_shapes.c`): a `cairo_arc`+`cairo_fill` circle was
    /// SILENTLY DROPPED entirely (an unhandled RENDER minor opcode, not a
    /// crash - `handleRenderRequest`'s old `default: break`) before this
    /// existed - a far bigger gap than its narrow-sounding name suggests,
    /// since it's not a rare/advanced feature, it's the ordinary path for
    /// any non-rectangle shape.
    ///
    /// Real X servers rasterize each trapezoid into a shared A8 coverage
    /// mask, then composite `src` through it once (an `op`/`src`/mask-
    /// format-implied-A8 dance mirroring `handleRenderComposite`'s own
    /// mask handling). This skeleton takes a shortcut that produces the
    /// same visual result for the overwhelmingly common case (`src` a
    /// solid color) - which is what cairo's `cairo_set_source_rgb(a)` +
    /// any non-rectangular fill always sends: build ONE combined
    /// `CGPath` from every trapezoid's quadrilateral and fill it in a
    /// SINGLE pass. Accumulating into one path (not filling each
    /// trapezoid separately) matters - an anti-aliased fill per-trapezoid
    /// would leave faint seams where adjacent trapezoids meet, since
    /// each one's edge antialiasing wouldn't know about its neighbor's.
    ///
    /// An image (non-solid) `src` IS supported (see the `srcTarget`
    /// branch below) - originally believed unnecessary ("unused by
    /// cairo's own solid-color fill/stroke path"), but confirmed live
    /// this is exactly the path cairo's xlib-render backend uses for
    /// ANY anti-aliased non-rectangular fill through a raster source:
    /// every GTK rounded-corner button border rendered as a totally
    /// blank grid until this was added (see `drawPictureImageSource`'s
    /// doc comment for the follow-up repeat/tiling bug this then
    /// exposed).
    ///
    /// Shared by `handleRenderComposite` and `handleRenderTrapezoids`'
    /// own image-source branches. `sampleOriginX`/`sampleOriginY` is the
    /// source-image pixel (top-left-oriented, not yet Y-flipped for
    /// `CGImage`) that lines up with `destRect`'s own top-left corner -
    /// `Composite`'s `srcX`/`srcY` directly, or `Trapezoids`' `srcX +
    /// pathBounds.origin.{x,y}` (each call site already computed this
    /// the same way before this helper existed; unchanged here).
    ///
    /// Confirmed live (tracing every silently-dropped RENDER minor
    /// opcode - `handleRenderRequest`'s `renderUnhandled`) that cairo's
    /// xlib-render backend routinely issues `Trapezoids`/`Composite`
    /// with `srcX`/`srcY` offsets far OUTSIDE the source Picture's own
    /// pixel bounds (e.g. offset 149 into a 17x17 pixmap) - not a bug in
    /// cairo, but `ChangePicture` (opcode 5, `handleRenderChangePicture`)
    /// having set `CPRepeat=Normal` on that Picture beforehand: a small
    /// reusable "stamp" (one rounded-corner alpha-coverage mask reused
    /// across every button) that's meant to tile/wrap, not a one-shot
    /// image sampled once. A single hard crop against an out-of-bounds
    /// rect just silently draws nothing (`CGImage.cropping(to:)` returns
    /// `nil` when the rects don't intersect) - which is exactly the
    /// "border partially renders, most of it blank" symptom seen live in
    /// `galculator` even after `Trapezoids` gained image-source support.
    ///
    /// The tiling implementation deliberately does NOT hand-slice the
    /// wraparound seam into sub-rects - it draws the WHOLE source image
    /// repeatedly at every tile-aligned grid position overlapping
    /// `destRect` and lets the caller's own clip (`ctx.clip()`/`ctx.clip
    /// (to:)`, already applied at both call sites before this runs) cut
    /// each copy down to the actually-wanted shape. Every real case seen
    /// live is a handful of tiles at most (a 17x17 stamp against a
    /// 17x17-or-smaller destination); `maxTiles` is a defensive cap
    /// against a pathological case never actually observed (e.g. a 1x1
    /// repeating "solid color via RENDER" picture tiled across a huge
    /// window, which would mean thousands of 1-pixel draws) - falls back
    /// to the plain non-repeating crop rather than hang.
    private func drawPictureImageSource(_ srcTarget: X11Drawable, sampleOriginX: Int, sampleOriginY: Int, repeatNormal: Bool, destRect: CGRect,
                                        transform: CGAffineTransform? = nil, nearest: Bool = true, on ctx: CGContext) {
        let tileW = srcTarget.pixelWidth, tileH = srcTarget.pixelHeight
        guard tileW > 0, tileH > 0 else { return }
        // The single funnel every image-source draw passes through, for
        // BOTH `Composite` and `Trapezoids` - so one trace line answers
        // "which op put pixels at this rect, sampling what, tiled how?".
        // See `gui-bugs.md` #25 (galculator's inter-button smears).
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] imgSrc dest=(\(Int(destRect.minX)),\(Int(destRect.minY)),\(Int(destRect.width)),\(Int(destRect.height))) tile=\(tileW)x\(tileH) sample=(\(sampleOriginX),\(sampleOriginY)) repeat=\(repeatNormal)\n".data(using: .utf8)!)
        }
        // A transformed source (cairo scaling or rotating an image) is
        // sampled through the transform - see `drawTransformedImage`.
        // Untransformed pictures take exactly the paths below, unchanged.
        if let transform {
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] imgSrc transformed \(transform) nearest=\(nearest)\n".data(using: .utf8)!)
            }
            if let fullImage = srcTarget.bitmapContext.makeImage() {
                drawTransformedImage(fullImage, sourceWidth: tileW, sourceHeight: tileH, transform: transform,
                                     sampleX: sampleOriginX, sampleY: sampleOriginY, destRect: destRect,
                                     repeatNormal: repeatNormal, nearest: nearest, on: ctx)
            }
            return
        }
        if repeatNormal {
            func floorMod(_ a: Int, _ n: Int) -> Int { let m = a % n; return m < 0 ? m + n : m }
            let phaseX = floorMod(sampleOriginX, tileW)
            let phaseY = floorMod(sampleOriginY, tileH)
            let startX = destRect.minX - CGFloat(phaseX)
            let startY = destRect.minY - CGFloat(phaseY)
            let tileCountX = Int(((destRect.maxX - startX) / CGFloat(tileW)).rounded(.up))
            let tileCountY = Int(((destRect.maxY - startY) / CGFloat(tileH)).rounded(.up))
            let maxTiles = 256
            if tileCountX > 0, tileCountY > 0, tileCountX * tileCountY <= maxTiles, let fullImage = srcTarget.bitmapContext.makeImage() {
                var y = startY
                while y < destRect.maxY {
                    var x = startX
                    while x < destRect.maxX {
                        drawImageTopLeftOriented(fullImage, in: CGRect(x: x, y: y, width: CGFloat(tileW), height: CGFloat(tileH)), on: ctx)
                        x += CGFloat(tileW)
                    }
                    y += CGFloat(tileH)
                }
                return
            }
            // Falls through to the plain crop below on the pathological-
            // tile-count bailout - best-effort (may render one tile's
            // worth instead of the full wraparound), never a hang.
        }
        // `CGImage.cropping(to:)` CLAMPS to the image's bounds - ask for a
        // rect that hangs off the edge and you get back a SMALLER image,
        // not a padded one (and `nil` only when there's no overlap at all).
        // Handing that undersized image to `drawImageTopLeftOriented` with
        // the full `destRect` then STRETCHES it to fit, smearing the
        // source across the whole destination.
        //
        // Confirmed live as the cause of both remaining render defects
        // (`gui-bugs.md` #23): GTK's 17x17 rounded-corner coverage stamps
        // are drawn with a `src-y` that is sometimes NEGATIVE (traced
        // `srcY=-13` on a repaint, where the first paint's offsets were
        // all in-bounds - which is exactly why the first paint looked
        // right and only the repaint was wrong). Stretching a partial
        // corner stamp over the full tile fills the transparent side of
        // the curve, turning a rounded corner square; in galculator the
        // same stretch is what smears grey blocks into the gaps between
        // buttons.
        //
        // The fix is to clip in SOURCE space and shift the destination by
        // the same amount, so the pixels that do exist land where they
        // belong at 1:1 scale and the missing region is simply not drawn.
        //
        // Computed in top-left space since 2026-09-15 (`imageSampleRects`):
        // the flipped-space version was right only for a whole-tile sample,
        // and picked mirrored rows for every offset or partial one.
        guard let rects = imageSampleRects(sourceWidth: tileW, sourceHeight: tileH, sampleX: sampleOriginX,
                                           sampleY: sampleOriginY, destRect: destRect),
              let srcImage = srcTarget.bitmapContext.makeImage()?.cropping(to: rects.source)
        else { return }
        drawImageTopLeftOriented(srcImage, in: rects.destination, on: ctx)
    }

    private func handleRenderTrapezoids(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let op = r.readU8()
        r.skip(3)
        let srcID = r.readU32()
        let dstID = r.readU32()
        r.skip(4) // mask-format (PICTFORMAT) - not tracked, same simplification as `handleRenderCreatePicture`'s own `format` parameter
        // src-x/src-y: meaningful for an IMAGE src (see below) - offsets
        // the source picture relative to the trapezoid geometry's own
        // coordinate origin, same role as `handleRenderComposite`'s own
        // `srcX`/`srcY`.
        let srcX = r.readI16(); let srcY = r.readI16()
        guard let dstPicture = state.picture(dstID), let dstDrawableID = dstPicture.drawableID,
              let dstTarget = state.drawable(dstDrawableID) else { return }
        // Confirmed live (investigating why EVERY GTK button/widget with
        // a rounded-corner border rendered as completely blank, not just
        // galculator's - a from-scratch single-`GtkButton` test program
        // reproduced this with zero galculator-specific state involved):
        // this handler used to require `srcPicture.solidColor`, silently
        // dropping (returning with nothing drawn) any `Trapezoids`
        // request whose source isn't a flat color. Traced exactly this
        // happening for real: cairo's xlib-render backend renders a
        // rounded corner's anti-aliased coverage ONCE into a small A8
        // pixmap (via `PutImage`, confirmed correctly received - a real
        // 0-255 gray gradient, right values), then STAMPS that image
        // through `Trapezoids`' own path geometry into the actual mask
        // Picture used by the following `Composite` - an IMAGE source,
        // not a solid one. Every single corner/edge of the border did
        // this identically (confirmed via `srcSolid=false` on every one)
        // - the mask Picture used downstream was ALWAYS whatever blank,
        // never-drawn-into pixmap `CreatePixmap` produces by default,
        // and `Composite`'s own mask-clip correctly (if uselessly)
        // clipped out 100% of the fill, matching the exact "nothing
        // renders, not even wrong-shaped" symptom live-tested. This is
        // NOT a galculator- or even GTK-specific bug: it's the ordinary
        // path cairo's xlib-render backend uses for ANY anti-aliased
        // non-rectangular fill through a raster (not solid) source -
        // rounded corners, soft shadows, non-trivial icon shapes.
        let srcPicture = state.picture(srcID)
        let solid = srcPicture?.solidColor
        let srcTarget = srcPicture?.drawableID.flatMap { state.drawable($0) }
        guard srcPicture != nil, solid != nil || srcTarget != nil else { return }
        let blendMode = Self.cgBlendMode(forPictOp: op)

        func fixedToDouble(_ v: Int32) -> Double { Double(v) / 65536.0 }
        // A trapezoid's LEFT/RIGHT edges are each a full LINE (two
        // points), not necessarily touching `top`/`bottom` themselves -
        // find each edge's actual x at y=top and y=bottom by intersection,
        // per the RENDER protocol's TRAPEZOID definition.
        func xAt(_ y: Double, p1x: Double, p1y: Double, p2x: Double, p2y: Double) -> Double {
            guard p2y != p1y else { return p1x }
            return p1x + (p2x - p1x) * (y - p1y) / (p2y - p1y)
        }
        let path = CGMutablePath()
        var vertexDebug: [String] = []
        // The FIRST trapezoid's left.p1, floored to whole pixels - real
        // X11 subtracts exactly this from `src-x`/`src-y` before
        // compositing. See `firstLeftP1` use below `guard !path.isEmpty`.
        var firstLeftP1: CGPoint?
        while r.remaining >= 40 {
            let top = fixedToDouble(r.readI32())
            let bottom = fixedToDouble(r.readI32())
            let leftP1x = fixedToDouble(r.readI32()); let leftP1y = fixedToDouble(r.readI32())
            let leftP2x = fixedToDouble(r.readI32()); let leftP2y = fixedToDouble(r.readI32())
            let rightP1x = fixedToDouble(r.readI32()); let rightP1y = fixedToDouble(r.readI32())
            let rightP2x = fixedToDouble(r.readI32()); let rightP2y = fixedToDouble(r.readI32())
            if X11Trace.enabled {
                vertexDebug.append("[top=\(top) bot=\(bottom) L=(\(leftP1x),\(leftP1y))-(\(leftP2x),\(leftP2y)) R=(\(rightP1x),\(rightP1y))-(\(rightP2x),\(rightP2y))]")
            }
            // Recorded from the first trapezoid in the REQUEST, before the
            // `bottom > top` guard can skip it - real X11 indexes
            // `traps[0]` unconditionally, without checking whether that
            // trapezoid is degenerate.
            if firstLeftP1 == nil { firstLeftP1 = CGPoint(x: leftP1x.rounded(.down), y: leftP1y.rounded(.down)) }
            guard bottom > top else { continue }
            let leftTopX = xAt(top, p1x: leftP1x, p1y: leftP1y, p2x: leftP2x, p2y: leftP2y)
            let leftBottomX = xAt(bottom, p1x: leftP1x, p1y: leftP1y, p2x: leftP2x, p2y: leftP2y)
            let rightTopX = xAt(top, p1x: rightP1x, p1y: rightP1y, p2x: rightP2x, p2y: rightP2y)
            let rightBottomX = xAt(bottom, p1x: rightP1x, p1y: rightP1y, p2x: rightP2x, p2y: rightP2y)
            path.move(to: CGPoint(x: leftTopX, y: top))
            path.addLine(to: CGPoint(x: rightTopX, y: top))
            path.addLine(to: CGPoint(x: rightBottomX, y: bottom))
            path.addLine(to: CGPoint(x: leftBottomX, y: bottom))
            path.closeSubpath()
        }
        guard !path.isEmpty else { return }
        let clip = dstPicture.clipRectangles
        let pathBounds = path.boundingBoxOfPath

        DispatchQueue.main.async {
            let ctx = dstTarget.bitmapContext
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.setBlendMode(blendMode)
            ctx.setAlpha(1)
            if let solid {
                ctx.setFillColor(x11Color(red: solid.r, green: solid.g, blue: solid.b, alpha: solid.a))
                ctx.addPath(path)
                ctx.fillPath()
            } else if let srcTarget {
                // Image source (the actual path this project's real
                // GTK/cairo apps use - see this function's own doc
                // comment): clip to the trapezoid path itself, THEN
                // draw the source image straight through it - see
                // `drawPictureImageSource`'s doc comment for the
                // repeat/tiling handling this needs (`sampleOriginX/Y`
                // anchored at the PATH's bounding box, matching
                // `Composite`'s own image-source branch's use of the
                // same helper with its explicit `dstX`/`dstY` instead -
                // trapezoids carry their own absolute destination
                // geometry, so the path's own origin plays that role).
                ctx.addPath(path)
                ctx.clip()
                if X11Trace.enabled {
                    FileHandle.standardError.write("[x11] trapDraw srcID=\(srcID) srcX=\(srcX) srcY=\(srcY) firstLeftP1=\(String(describing: firstLeftP1)) origin=(\(Int(srcX) - Int(firstLeftP1?.x ?? 0) + Int(pathBounds.origin.x)),\(Int(srcY) - Int(firstLeftP1?.y ?? 0) + Int(pathBounds.origin.y))) oldOrigin=(\(Int(srcX) + Int(pathBounds.origin.x)),\(Int(srcY) + Int(pathBounds.origin.y))) dst=\(dstDrawableID) pathBounds=\(pathBounds) repeatNormal=\(srcPicture?.repeatNormal ?? false)\n".data(using: .utf8)!)
                }
                // Source alignment, confirmed against real xorg-server +
                // pixman source rather than derived from the spec prose
                // (`XQuartz/xorg-server`): `fb/fbtrap.c`'s `fbTrapezoids`
                // does `xSrc -= (traps[0].left.p1.x >> 16)` BEFORE
                // handing off, and pixman's `pixman_composite_trapezoids`
                // then composites the rasterized mask at the trapezoid
                // bounding box with source offset `x_src + bounds.x1`.
                // Net: `srcX - traps[0].left.p1.x + bounds.x1`.
                //
                // This server had only `srcX + bounds.x1` - the
                // `- traps[0].left.p1` term was missing outright, so every
                // trapezoid whose first left edge doesn't start at the
                // bounding box's own origin sampled the source at the
                // wrong offset. That is `gui-bugs.md` #24, and it is the
                // real cause of galculator's remaining "heavy artifacting"
                // (grey bars smeared into the gaps between buttons: a
                // repeating edge stamp tiled at the wrong phase). It is
                // also what pushed the crop in `drawPictureImageSource`
                // out of bounds in the first place - traced a stamp with
                // `srcY=-7` whose own `left.p1.y` was `-7`, i.e. a correct
                // offset of exactly 0.
                let originX = Int(srcX) - Int(firstLeftP1?.x ?? 0) + Int(pathBounds.origin.x)
                let originY = Int(srcY) - Int(firstLeftP1?.y ?? 0) + Int(pathBounds.origin.y)
                self.drawPictureImageSource(srcTarget, sampleOriginX: originX, sampleOriginY: originY, repeatNormal: srcPicture?.repeatNormal ?? false, destRect: pathBounds,
                                            transform: srcPicture?.transform, nearest: srcPicture?.filterNearest ?? true, on: ctx)
            }
            ctx.restoreGState()
            dstTarget.notifyChanged()
        }
    }

    /// `CreateGlyphSet`/`FreeGlyphSet` - just resource bookkeeping (see
    /// `X11State.GlyphSetRecord`'s doc comment); the interesting parts are
    /// `handleRenderAddGlyphs` (upload) and `handleRenderCompositeGlyphs8`
    /// (draw).
    private func handleRenderCreateGlyphSet(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let gsid = r.readU32()
        let format = r.readU32()
        _ = state.makeGlyphSet(id: gsid, format: format)
    }

    private func handleRenderFreeGlyphSet(body: [UInt8]) {
        state.removeGlyphSet(X11ByteReader(body, littleEndian: littleEndian).readU32())
    }

    /// `AddGlyphs` - uploads one or more glyphs' bitmaps into a
    /// `GLYPHSET`, keyed by a client-chosen `GLYPHID`. Wire layout:
    /// `glyphset`(4) + `nglyphs`(4), then `nglyphs` `GLYPHID`s (4 bytes
    /// each), then `nglyphs` `GLYPHINFO`s (12 bytes each: width/height:
    /// CARD16, x/y/xOff/yOff: INT16), then each glyph's raw pixel bytes
    /// back-to-back IN THE SAME ORDER - one byte/pixel for an A8
    /// (coverage-mask) glyphset, four for ARGB32 (color glyphs/emoji;
    /// untested here, cairo's ordinary text path uses A8), each row
    /// padded to a 4-byte boundary same as a `PutImage` upload.
    private func handleRenderAddGlyphs(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let glyphsetID = r.readU32()
        let count = Int(r.readU32())
        guard let glyphSet = state.glyphSet(glyphsetID), count > 0, count < 10_000 else { return }
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        for _ in 0..<count { ids.append(r.readU32()) }
        struct Info { let width: Int; let height: Int; let x: Int; let y: Int; let xOff: Int; let yOff: Int }
        var infos: [Info] = []
        infos.reserveCapacity(count)
        for _ in 0..<count {
            let width = Int(r.readU16())
            let height = Int(r.readU16())
            let x = Int(r.readI16())
            let y = Int(r.readI16())
            let xOff = Int(r.readI16())
            let yOff = Int(r.readI16())
            infos.append(Info(width: width, height: height, x: x, y: y, xOff: xOff, yOff: yOff))
        }
        let bytesPerPixel = glyphSet.format == Self.renderFormatA8 ? 1 : 4
        for i in 0..<count {
            let info = infos[i]
            let stride = ((info.width * bytesPerPixel + 3) / 4) * 4
            let data = r.readBytes(stride * info.height)
            glyphSet.glyphs[ids[i]] = X11State.GlyphRecord(
                width: info.width, height: info.height, x: info.x, y: info.y,
                xOff: info.xOff, yOff: info.yOff, imageData: data
            )
        }
    }

    /// `CompositeGlyphs8` - draws a run of previously-`AddGlyphs`-uploaded
    /// glyphs as `src` (almost always a solid color - cairo's ordinary
    /// text path) composited through each glyph's own A8 bitmap as a
    /// coverage mask, walking a pen position exactly like a real
    /// rasterizer would. `glyphcmds` is a sequence of `GLYPHELT8`s: each
    /// is either `len`(1 byte, the glyph count) + pad(1) + deltaX/deltaY
    /// (INT16 each, added to the pen BEFORE this element's glyphs) +
    /// `len` glyph IDs (1 byte each), OR (when `len == 0xFF`) an escape
    /// meaning "the next 4 bytes are a different GLYPHSET id to switch
    /// to" - real clients rarely mix glyphsets mid-run, but it costs
    /// little to honor. Confirmed live via the Layer-1 harness (`Guest/
    /// init/cairo-tests/02_text.c`): before this and the three handlers
    /// above existed, `cairo_show_text` successfully rasterized real
    /// glyphs via fontconfig/freetype and sent the whole
    /// CreateGlyphSet/AddGlyphs/CompositeGlyphs8 sequence correctly - this
    /// server just silently dropped all of it (an unhandled RENDER minor
    /// opcode each time), leaving text-drawing real clients (this
    /// project's own galculator very much included, via GTK/Pango, which
    /// drives cairo's xlib backend the exact same way) with blank space
    /// where every glyph should be.
    /// `idSize` is the on-the-wire width of each `GLYPHID` in the glyph-ID
    /// list - 1/2/4 bytes for `CompositeGlyphs8`/`16`/`32` respectively
    /// (opcodes 23/24/25). Confirmed against the real xserver
    /// (`render/render.c`'s `ProcRenderCompositeGlyphs`, which dispatches
    /// all three through this exact same parsing with only `size`
    /// varying) that the fixed `GLYPHELT` header, its padding formula, and
    /// everything else about the wire format are IDENTICAL across all
    /// three - a real `GLYPHID` is always a `GlyphSetRecord`-scoped `CARD32`
    /// resource id at the protocol level; 8/16 only exist as a wire-size
    /// optimization for glyphsets with few enough glyphs to fit. Originally
    /// only `CompositeGlyphs8` (`idSize: 1`) was implemented, on the
    /// assumption cairo's ordinary text path always uses it - true for the
    /// SMALL ASCII-range glyphsets `xterm`'s Xft/freetype path and cairo's
    /// own `cairo_show_text` build, but confirmed live via `galculator`'s
    /// button labels: GTK/Pango, rendering from a much larger font-wide
    /// glyph index space, uses `CompositeGlyphs32` for those specifically -
    /// silently dropped entirely (an unhandled RENDER minor, same failure
    /// shape as every other bug found this session) while the SAME
    /// process's display digits, going through a different/smaller
    /// glyphset, happened to fit in `CompositeGlyphs8` and rendered fine -
    /// which is exactly why "digits render, button labels don't" looked
    /// like a narrower bug than it was.
    private func handleRenderCompositeGlyphs(body: [UInt8], idSize: Int) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let op = r.readU8()
        r.skip(3)
        let srcID = r.readU32()
        let dstID = r.readU32()
        r.skip(4) // mask-format (PICTFORMAT) - not tracked, same simplification as `handleRenderCreatePicture`'s `format`
        let glyphsetID = r.readU32()
        r.skip(4) // src-x, src-y - only meaningful for an image src, unsupported here (see handleRenderTrapezoids)

        guard let dstPicture = state.picture(dstID), let dstDrawableID = dstPicture.drawableID,
              let dstTarget = state.drawable(dstDrawableID) else { return }
        guard let srcPicture = state.picture(srcID), let solid = srcPicture.solidColor else { return }
        guard let initialGlyphSet = state.glyphSet(glyphsetID) else { return }
        let blendMode = Self.cgBlendMode(forPictOp: op)

        struct Placed { let glyph: X11State.GlyphRecord; let isColor: Bool; let originX: Double; let originY: Double }
        var placed: [Placed] = []
        var penX: Double = 0
        var penY: Double = 0
        var currentGlyphSet = initialGlyphSet

        while r.remaining >= 1 {
            let len = r.readU8()
            if len == 0xFF {
                guard r.remaining >= 4 else { break }
                guard let newSet = state.glyphSet(r.readU32()) else { break }
                currentGlyphSet = newSet
                continue
            }
            // Confirmed live via the Layer-1 harness's raw hex trace
            // (`Guest/init/cairo-tests/02_text.c`): this fixed header is
            // 8 bytes, not the 4 a plain `len(1)+pad(1)+deltaX(2)+
            // deltaY(2)` reading would suggest - `len` is padded out to
            // a full CARD32-width slot (3 pad bytes, not 1) before
            // `deltaX`/`deltaY`, presumably so the fixed portion stays a
            // clean multiple of 4 regardless of `len`'s own single byte.
            guard r.remaining >= 7 else { break } // pad(3) + deltaX(2) + deltaY(2)
            r.skip(3)
            penX += Double(r.readI16())
            penY += Double(r.readI16())
            guard r.remaining >= Int(len) * idSize else { break }
            let isColor = currentGlyphSet.format != Self.renderFormatA8
            for _ in 0..<len {
                let glyphID: UInt32
                switch idSize {
                case 1: glyphID = UInt32(r.readU8())
                case 2: glyphID = UInt32(r.readU16())
                default: glyphID = r.readU32()
                }
                guard let glyph = currentGlyphSet.glyphs[glyphID] else { continue }
                if glyph.width > 0, glyph.height > 0 {
                    placed.append(Placed(glyph: glyph, isColor: isColor, originX: penX, originY: penY))
                }
                penX += Double(glyph.xOff)
                penY += Double(glyph.yOff)
            }
            // Cross-checked against the real xorg-server
            // (`render/render.c`'s `ProcRenderCompositeGlyphs`, the
            // `space = size * elt->len; if (space & 3) space += 4 -
            // (space & 3)` padding math): each `GLYPHELT8`'s glyph-ID list
            // is padded to a 4-byte boundary before the NEXT element
            // starts - missing here entirely. Any text with more than one
            // glyph run in the same `CompositeGlyphs8` request (pango
            // splits on every space, so this is the COMMON case, not an
            // edge case) desynced the reader by however many bytes the
            // first chunk's padding was, misreading the next chunk's
            // padding bytes as a bogus `len`/delta and corrupting every
            // glyph after the first run - live-confirmed via a byte-count
            // cross-check ("Top label"/"<<< BOTTOM >>>" both truncated
            // exactly where their first space falls) and a snapshot PNG
            // showing literally that: "T" alone, and "<<< BOTTOM" with the
            // trailing ">>>" gone. Not the `gui-bugs.md` #9 "window too
            // short" bug at all - a horizontal RENDER-protocol parsing bug
            // that happened to look like vertical clipping in a narrow
            // window where the truncated text still fit on one line.
            let idBytes = Int(len) * idSize
            let pad = (4 - (idBytes % 4)) % 4
            if pad > 0 { r.skip(pad) }
        }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] compositeGlyphs idSize=\(idSize) dstID=\(dstID) dstDrawableID=\(dstDrawableID) glyphsetID=\(glyphsetID) solid=\(solid) clip=\(String(describing: dstPicture.clipRectangles)) placedCount=\(placed.count) penX=\(penX) penY=\(penY) sizes=\(placed.map { ($0.glyph.width, $0.glyph.height) }) origins=\(placed.map { ($0.originX, $0.originY) })\n".data(using: .utf8)!)
        }
        guard !placed.isEmpty else {
            if X11Trace.enabled { FileHandle.standardError.write("[x11] compositeGlyphs idSize=\(idSize): placed EMPTY (glyph lookup failed for all)\n".data(using: .utf8)!) }
            return
        }
        let clip = dstPicture.clipRectangles

        DispatchQueue.main.async {
            let ctx = dstTarget.bitmapContext
            for p in placed {
                let g = p.glyph
                // GLYPHINFO's `x`/`y` are the glyph origin's offset FROM
                // the bitmap's top-left corner (freetype's bitmap_left/
                // bitmap_top convention this protocol was modeled on) -
                // so the bitmap's top-left, in destination space, is the
                // pen position MINUS that offset.
                let destRect = CGRect(x: p.originX - Double(g.x), y: p.originY - Double(g.y), width: Double(g.width), height: Double(g.height))
                let stride = ((g.width * (p.isColor ? 4 : 1) + 3) / 4) * 4
                let image: CGImage?
                if p.isColor {
                    // Untested (no Layer 0-3 test exercises a color/
                    // ARGB32 glyphset - cairo's ordinary text path always
                    // uses A8) - built the same way `handlePutImage`
                    // builds its images (raw bytes, unreversed) since it
                    // goes through `drawImageTopLeftOriented` just like
                    // `PutImage` does, NOT the manual row-reversal the A8
                    // branch below needs for its own, different
                    // `clip(to:mask:)` call - see `drawImageTopLeftOriented`'s
                    // doc comment for why these two need different
                    // treatment despite looking like the same problem.
                    guard let provider = CGDataProvider(data: Data(g.imageData) as CFData) else { continue }
                    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    image = CGImage(
                        width: g.width, height: g.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: stride, space: x11DeviceRGB, bitmapInfo: bitmapInfo,
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                    )
                } else {
                    // Confirmed live via the Layer-1 harness
                    // (`Guest/init/cairo-tests/02_text.c`): drawing the raw
                    // `AddGlyphs` row data top-to-bottom through
                    // `CGContext.clip(to:mask:)` on this flipped-CTM
                    // context came out vertically mirrored (an upside-
                    // down "M" reads as a "W", an upside-down "L" as a
                    // "Γ") - reversing the row order here, once, up
                    // front, is simpler and more certain than chasing
                    // whichever CTM-interaction quirk specifically makes
                    // `clip(to:mask:)` behave differently from a plain
                    // `draw(image:in:)` call (see `drawImageTopLeftOriented`'s
                    // doc comment for that one's own, separate quirk).
                    var rows = stride > 0 ? g.imageData.count / stride : 0
                    rows = min(rows, g.height)
                    var flipped = g.imageData
                    if rows > 1 {
                        for row in 0..<(rows / 2) {
                            let top = row * stride
                            let bottom = (rows - 1 - row) * stride
                            for i in 0..<stride { flipped.swapAt(top + i, bottom + i) }
                        }
                    }
                    guard let provider = CGDataProvider(data: Data(flipped) as CFData) else { continue }
                    image = CGImage(
                        width: g.width, height: g.height, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: stride, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                    )
                }
                guard let image else { continue }
                ctx.saveGState()
                if let clip { ctx.clip(to: clip) }
                ctx.setBlendMode(blendMode)
                if p.isColor {
                    drawImageTopLeftOriented(image, in: destRect, on: ctx)
                } else {
                    // A8 coverage mask: composite `src`'s solid color
                    // through it, exactly the "solid fill through a
                    // luminosity/alpha mask" pattern `handleRenderComposite`
                    // already uses for an image-backed mask Picture - a
                    // grayscale image with no alpha channel uses its own
                    // luminosity as the mask value (white = fully
                    // visible), which is precisely what an A8 coverage
                    // byte already means (0 = no ink, 255 = full ink).
                    ctx.clip(to: destRect, mask: image)
                    ctx.setFillColor(x11Color(red: solid.r, green: solid.g, blue: solid.b, alpha: solid.a))
                    ctx.fill(destRect)
                }
                ctx.restoreGState()
            }
            dstTarget.notifyChanged()
        }
    }

    /// Reports the REAL focus window (see `X11State.focusWindow`), not a
    /// hardcoded root. Confirmed live this is what kept Krita's `QMenuBar`
    /// from ever staying open (`gui-bugs.md` #14, open for several
    /// sessions): on clicking "File", Qt correctly creates, positions and
    /// maps its popup, then immediately calls `GetInputFocus` to check
    /// that its own window really holds the focus - and this server always
    /// answered "the ROOT window does". Traced Qt's reaction, every time,
    /// in exactly this order: `GetInputFocus` -> `GrabKeyboard` ->
    /// `XIGrabDevice` -> `XIUngrabDevice` (immediately giving the grab
    /// straight back) -> `GetInputFocus` again -> `UngrabKeyboard` ->
    /// `UnmapWindow`. A toolkit that believes it doesn't hold the focus
    /// will not keep a menu up, no matter how correctly the popup itself
    /// was mapped. `revert-to` is `Parent` (2) rather than the previous
    /// `None` (0) - `None` tells a client focus can evaporate entirely.
    private func handleGetInputFocus() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(state.currentFocusWindow())
        fw.writePadding(20)
        sendReply(fixed24: fw, detail: 2) // revert-to: Parent
    }

    /// `SetInputFocus` (opcode 42) - previously a total no-op (it sat in
    /// `dispatch`'s "no reply per spec" catch-all alongside the ungrab
    /// requests, which reply-wise is true, but it still has real state to
    /// record). Body is `focus`(4) + `time`(4); `revert-to` rides the
    /// request header's `detail` byte and isn't modelled. `PointerRoot`
    /// (1) and `None` (0) are stored as-is - a client that asks for
    /// either gets it back verbatim from `GetInputFocus`.
    private func handleSetInputFocus(body: [UInt8]) {
        let focus = X11ByteReader(body, littleEndian: littleEndian).readU32()
        state.setFocusWindow(focus)
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] setInputFocus focus=\(focus)\n".data(using: .utf8)!)
        }
    }

    /// `xeyes` (and anything else polling cursor position rather than just
    /// reacting to `MotionNotify`) hammers this in a tight loop - confirmed
    /// live it renders as a blank window otherwise (it never even gets to
    /// draw the pupils, since it can't find out where they should point).
    /// `child` is always reported `None` (0) - real servers only fill this
    /// in when the pointer is over a *child* of the queried window, and
    /// nothing here does anything with that extra precision, so `None` is
    /// spec-legal and simplest. `mask` (button/modifier state) is always 0 -
    /// not tracked anywhere in this skeleton; fine for `xeyes`, which only
    /// reads position, but a real client checking button state here would
    /// see it as "nothing held," always.
    private func handleQueryPointer(body: [UInt8]) {
        let wid = X11ByteReader(body, littleEndian: littleEndian).readU32()
        // `windowOrigin`, not `frame.origin`: a child window's frame is
        // parent-relative, so win_x/win_y came out offset for any child
        // (xeyes queries its Eyes widget window, a child of the shell).
        // Same fix `handleXIQueryPointer` already has.
        let origin = windowOrigin(wid)
        var rootX = 0, rootY = 0
        // NSEvent.mouseLocation/NSScreen.main are AppKit - same main-thread
        // requirement as everything else here (see GetKeyboardMapping's
        // doc comment for the TIS crash this exact pattern was added to
        // avoid elsewhere; AppKit calls off the main thread aren't all
        // guaranteed safe even where they don't outright crash).
        DispatchQueue.main.sync {
            let screenHeight = NSScreen.main?.frame.height ?? 1080
            let cocoa = NSEvent.mouseLocation // bottom-left origin, screen space
            rootX = Int(cocoa.x)
            rootY = Int(screenHeight - cocoa.y) // -> top-left origin, matching X11
        }
        let winX = rootX - Int(origin.x)
        let winY = rootY - Int(origin.y)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(rootWindowID)
        fw.writeU32(0) // child: None
        fw.writeI16(Int16(clamping: rootX))
        fw.writeI16(Int16(clamping: rootY))
        fw.writeI16(Int16(clamping: winX))
        fw.writeI16(Int16(clamping: winY))
        fw.writeU16(0) // mask: no buttons/modifiers tracked
        fw.writePadding(6)
        sendReply(fixed24: fw, detail: 1) // detail: same-screen = True
    }

    /// Root-relative origin of any window ID this server knows about -
    /// `0,0` for the root window itself (not stored in `state.windows`,
    /// since nothing ever creates it) and for an unknown/stale ID, same
    /// fallback `handleGetGeometry` already uses. Recursive through the
    /// parent chain - `record.frame.origin` is only screen-relative for a
    /// TOP-LEVEL window; a child window's is relative to ITS PARENT (see
    /// `handleCreateWindow`'s own doc comment on the parent/child
    /// distinction), so a non-top-level window needs its ancestors'
    /// origins accumulated too. Originally computed this correctly ONLY
    /// for `TranslateCoordinates`, but `sendPointerEvent`/
    /// `sendXIDeviceEvent` used a much cruder approximation (window-
    /// relative coordinates copied straight into the "root" fields,
    /// correct by coincidence only for a window at screen origin `(0,0)`)
    /// - see their own doc comments for the real bug that caused (`gui-
    /// bugs.md` issue #10: a click landing exactly on a menu item, by
    /// every window-relative measure, still didn't activate it, because
    /// GTK's own hit-testing during a grab uses root coordinates).
    private func windowOrigin(_ id: UInt32) -> CGPoint {
        guard id != rootWindowID, let record = state.window(id) else { return .zero }
        if record.isTopLevel { return record.frame.origin }
        let parentOrigin = windowOrigin(record.parent)
        return CGPoint(x: parentOrigin.x + record.frame.origin.x, y: parentOrigin.y + record.frame.origin.y)
    }

    /// GTK/GDK calls this constantly for popup/menu placement (converting
    /// a point between a widget's own window and the root) - confirmed
    /// live that leaving it unimplemented isn't a soft degradation the
    /// way most `BadImplementation`s here are: GDK's default X-error
    /// handler treats it as fatal and aborts the whole client outright
    /// (`galculator` never even got to `MapWindow`). `child` is always
    /// reported `None` - same simplification as `QueryPointer`'s, and for
    /// the same reason (nothing here needs the extra precision of "which
    /// child of dst-window is the point actually over").
    private func handleTranslateCoordinates(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let srcWindow = r.readU32()
        let dstWindow = r.readU32()
        let srcX = r.readI16()
        let srcY = r.readI16()
        let srcOrigin = windowOrigin(srcWindow)
        let dstOrigin = windowOrigin(dstWindow)
        let dstX = srcOrigin.x + Double(srcX) - dstOrigin.x
        let dstY = srcOrigin.y + Double(srcY) - dstOrigin.y
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] translateCoords src=\(srcWindow)@\(srcOrigin) in=(\(srcX),\(srcY)) dst=\(dstWindow)@\(dstOrigin) -> (\(Int(dstX)),\(Int(dstY)))\n".data(using: .utf8)!)
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(0) // child: None
        fw.writeI16(Int16(clamping: Int(dstX)))
        fw.writeI16(Int16(clamping: Int(dstY)))
        fw.writePadding(16)
        sendReply(fixed24: fw, detail: 1) // detail: same-screen = True
    }

    /// `GrabPointer`/`GrabKeyboard` share this exact reply shape (a single
    /// status byte, `0` = `Success`, then 24 unused bytes) - unlike
    /// `GrabButton` (no reply at all, see `dispatch`), these two DO expect
    /// one, and real clients (`xterm`'s mouse-drag text selection uses
    /// `GrabPointer`) aren't guaranteed to tolerate a `BadImplementation`
    /// error in its place the way most other unimplemented requests are.
    /// Always granting the grab is correct here specifically because
    /// nothing else could ever hold a conflicting one - every connected
    /// client shares one flat, ungated resource space (see `X11State`'s
    /// doc comment), so there's no real contention to model.
    private func handleGrabReply() {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writePadding(24)
        sendReply(fixed24: fw, detail: 0) // detail=0: GrabSuccess
    }

    // MARK: - Font requests

    /// No real font/glyph rendering exists yet (RENDER isn't implemented -
    /// see `X11Server`'s doc comment) - every "font" this server ever
    /// reports is the same fake, uniform-width metrics below, regardless of
    /// the name a client asked for in `OpenFont`. That's why `OpenFont`/
    /// `CloseFont` are plain no-ops in `dispatch` (nothing to allocate or
    /// free) and `QueryFont` never even looks at which font ID it was
    /// asked about: this is enough for `xterm` (which needs *some*
    /// plausible cell width/ascent/descent to size its window at startup -
    /// confirmed live it gets stuck at `X_OpenFont`/`X_QueryFont` with
    /// `BadImplementation` otherwise, never even reaching `CreateWindow`)
    /// but text will look/measure wrong until real glyph metrics land.
    /// Measured from the real font `X11CanvasView.drawText` actually
    /// draws with (`X11FakeFont`) rather than made up separately - the two
    /// used to disagree, which sized a client's cell grid using numbers
    /// its glyphs then didn't match, over- or under-lapping characters.
    /// `OpenFont`: still allocates nothing (see above), but remembers
    /// whether the name is the Adobe Symbol font so text drawn with it
    /// decodes through `X11CoreText`'s Symbol table instead of Latin-1.
    private func handleOpenFont(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let fid = r.readU32()
        let nameLen = Int(r.readU16())
        r.skip(2)
        guard r.remaining >= nameLen else { return }
        let name = r.readString8(nameLen)
        state.setFont(fid, isSymbol: X11CoreText.isSymbolFontName(name))
    }

    private static let fakeCharWidth = Int16(X11FakeFont.charWidth.rounded())
    private static let fakeFontAscent = Int16(X11FakeFont.ascent.rounded())
    private static let fakeFontDescent = Int16(X11FakeFont.descent.rounded())

    /// `QueryFont`'s reply has a 52-byte reply-specific fixed part (not the
    /// usual 24 `sendReply(fixed24:)` assumes), so this builds the whole
    /// reply by hand the same way `performHandshake`'s success/failure
    /// responses do. `n_charinfos=0` is the protocol's documented shorthand
    /// for "every character uses `min_bounds`/`max_bounds`" - skips ever
    /// needing a real per-glyph table for this fake, uniform-width font.
    private func handleQueryFont() {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1) // Reply
        w.writeU8(0) // unused
        w.writeU16(sequenceNumber)
        w.writeU32(7) // reply length: (60 total - 32) / 4
        writeCharInfo(into: w) // min_bounds
        w.writePadding(4)
        writeCharInfo(into: w) // max_bounds
        w.writePadding(4)
        w.writeU16(32) // min_char_or_byte2 (space)
        w.writeU16(126) // max_char_or_byte2 (~)
        w.writeU16(32) // default_char
        w.writeU16(0) // n_font_props
        w.writeU8(0) // draw_direction: LeftToRight
        w.writeU8(0) // min_byte1
        w.writeU8(0) // max_byte1
        w.writeU8(1) // all_chars_exist
        w.writeI16(Self.fakeFontAscent)
        w.writeI16(Self.fakeFontDescent)
        w.writeU32(0) // n_charinfos
        writeFull(w.bytes)
    }

    private func writeCharInfo(into w: X11ByteWriter) {
        w.writeI16(0) // left_side_bearing
        w.writeI16(Self.fakeCharWidth) // right_side_bearing
        w.writeI16(Self.fakeCharWidth) // character_width
        w.writeI16(Self.fakeFontAscent) // ascent
        w.writeI16(-Self.fakeFontDescent) // descent (negative = below baseline, per spec)
        w.writeU16(0) // attributes
    }

    /// Fixed reply part is exactly the usual 24 bytes here, so this can go
    /// through `sendReply(fixed24:)` - `detail` doubles as the reply's
    /// draw-direction field, matching the request's own layout.
    private func handleQueryTextExtents(detail: UInt8, body: [UInt8]) {
        // body: 4-byte fontable ID, then a CHAR2B[] string (2 bytes each;
        // `detail`'s low bit means the string was an odd count of CHAR2Bs,
        // i.e. the wire had one fewer padding byte - close enough for a
        // fake-metrics reply that only cares about the count).
        let char2BCount = max(0, body.count - 4) / 2
        let width = Int32(char2BCount) * Int32(Self.fakeCharWidth)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeI16(Self.fakeFontAscent)
        fw.writeI16(Self.fakeFontDescent)
        fw.writeI16(Self.fakeFontAscent)
        fw.writeI16(Self.fakeFontDescent)
        fw.writeI32(width) // overall_width
        fw.writeI32(0) // overall_left
        fw.writeI32(width) // overall_right
        fw.writePadding(4)
        sendReply(fixed24: fw, detail: detail & 0x01)
    }

    // MARK: - Keyboard mapping requests

    /// Both answered from `X11Keymap`. Leaving them unimplemented is fatal
    /// for Xt clients like `xterm`: Xlib's `XGetKeyboardMapping` has no
    /// error path and desyncs on one, which is why these were the first
    /// keyboard requests this server ever handled.
    private func handleGetKeyboardMapping(body: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        let firstKeycode = r.readU8()
        let count = Int(r.readU8())
        writeFull(X11KeymapProvider.shared.keymap.keyboardMappingReply(
            firstKeycode: firstKeycode, count: count, sequence: sequenceNumber, littleEndian: littleEndian))
    }

    private func handleGetModifierMapping() {
        writeFull(X11KeymapProvider.shared.keymap.modifierMappingReply(sequence: sequenceNumber, littleEndian: littleEndian))
    }

    // MARK: - Reply/error/event wire helpers

    private func padded(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        result.append(contentsOf: [UInt8](repeating: 0, count: X11Wire.pad(bytes.count) - bytes.count))
        return result
    }

    /// `fixed24` must contain exactly 24 bytes (the reply-specific data
    /// that always follows the 4-byte common reply header) - `extra` is
    /// any further variable-length data, already padded to a 4-byte
    /// boundary by the caller.
    private func sendReply(fixed24: X11ByteWriter, extra: [UInt8] = [], detail: UInt8 = 0) {
        precondition(fixed24.bytes.count == 24, "X11 reply fixed portion must be exactly 24 bytes")
        precondition(extra.count % 4 == 0, "X11 reply extra data must be padded to a 4-byte boundary")
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1) // Reply
        w.writeU8(detail)
        w.writeU16(sequenceNumber)
        w.writeU32(UInt32(extra.count / 4))
        w.writeBytes(fixed24.bytes)
        w.writeBytes(extra)
        writeFull(w.bytes)
    }

    private func sendError(code: UInt8, badValue: UInt32, minorOpcode: UInt16, majorOpcode: UInt8) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(0) // Error
        w.writeU8(code)
        w.writeU16(sequenceNumber)
        w.writeU32(badValue)
        w.writeU16(minorOpcode)
        w.writeU8(majorOpcode)
        w.writePadding(21)
        writeFull(w.bytes)
    }

    /// Cross-checked live against real GTK/GDK behavior (`gui-bugs.md`
    /// issue #10 - clicking a menu item never activates it): `root-x`/
    /// `root-y` here used to be a straight copy of the window-relative
    /// `event-x`/`event-y` ("no real multi-window root coordinate space
    /// yet"). That's only correct by coincidence for a window sitting at
    /// screen origin `(0,0)` - for anything else (every popup, every
    /// cascaded/second window), it silently reports the wrong root
    /// position. GDK's own menu-item hit-testing (`gtkmenushell.c`) uses
    /// root coordinates, not just the window-relative ones, to decide
    /// which item a button release lands on while a grab is active - a
    /// wrong root position meant a click that visually, and even by
    /// window-relative coordinates, landed exactly on "About" still got
    /// treated as landing nowhere, so the menu closed (unmap + ungrab,
    /// confirmed via trace) without ever activating the item underneath.
    private func sendPointerEvent(code: UInt8, detail: UInt8, windowID: UInt32, x: Int16, y: Int16, state stateMask: UInt16) {
        let origin = windowOrigin(windowID)
        let rootX = Int16(clamping: Int(origin.x) + Int(x))
        let rootY = Int16(clamping: Int(origin.y) + Int(y))
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(code)
        w.writeU8(detail)
        w.writeU16(sequenceNumber)
        w.writeU32(currentX11Timestamp)
        w.writeU32(rootWindowID)
        w.writeU32(windowID)
        w.writeU32(0) // child = None
        w.writeI16(rootX)
        w.writeI16(rootY)
        w.writeI16(x) // event-x - window-relative, correct as-is
        w.writeI16(y) // event-y
        w.writeU16(stateMask)
        w.writeU8(1) // same-screen
        w.writePadding(1)
        writeFull(w.bytes)
    }

    /// `Expose` (code 12) - a different 32-byte layout than the pointer/
    /// key events `sendPointerEvent` builds (no `root`/`child`/state -
    /// just the exposed rectangle and a same-sequence `count`). `count=0`
    /// unconditionally: this server only ever sends one Expose per map,
    /// never a batched sequence of exposed sub-rectangles, so there's
    /// never a "more still coming" case to report.
    /// `MapNotify` (code 19) - confirms a window actually became mapped,
    /// distinct from `Expose` ("here's what needs painting"). Confirmed
    /// live via the Layer-2 harness (`Guest/init/gtk-tests/01_window.c`):
    /// a `GtkDrawingArea` gets its OWN native child X11 window (not just
    /// a region within its top-level's), and GDK - having selected
    /// `StructureNotifyMask` on it - never invoked the widget's "draw"
    /// signal no matter how long the test waited, even though `mapChild`
    /// correctly mapped the window and sent it a well-formed `Expose`.
    /// This server sent no `MapNotify` for a mapped CHILD window at all
    /// (only `Expose`) - GDK apparently treats `MapNotify` as the
    /// authoritative "you're now really visible, geometry is final" signal
    /// for a window it's watching `StructureNotifyMask` on, and won't
    /// schedule a paint from `Expose` alone without having seen it first.
    /// `ReparentNotify` (21): event, window, parent, x, y, override-redirect.
    private func sendReparentNotify(event: UInt32, window: UInt32, parent: UInt32, x: Int16, y: Int16, overrideRedirect: Bool) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(21) // ReparentNotify
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(event)
        w.writeU32(window)
        w.writeU32(parent)
        w.writeI16(x)
        w.writeI16(y)
        w.writeU8(overrideRedirect ? 1 : 0)
        w.writePadding(11)
        writeFull(w.bytes)
    }

    private func sendMapNotify(windowID: UInt32) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(19) // MapNotify
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(windowID) // event
        w.writeU32(windowID) // window
        w.writeU8((state.window(windowID)?.overrideRedirect ?? false) ? 1 : 0) // override-redirect
        w.writePadding(19)
        writeFull(w.bytes)
    }

    private func sendExposeEvent(windowID: UInt32, x: UInt16 = 0, y: UInt16 = 0, width: UInt16, height: UInt16) {
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] sendExposeEvent wid=\(windowID) x=\(x) y=\(y) w=\(width) h=\(height)\n".data(using: .utf8)!)
        }
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(12) // Expose
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(windowID)
        w.writeU16(x)
        w.writeU16(y)
        w.writeU16(width)
        w.writeU16(height)
        w.writeU16(0) // count
        w.writePadding(14)
        writeFull(w.bytes)
    }

    /// `ConfigureNotify` (code 22) - tells a client its window's actual
    /// current geometry, whether the change came from the client's own
    /// `ConfigureWindow` request or (see `windowDidResize(_:)`) the user
    /// dragging the real macOS window's edge. Needed for real dynamic
    /// resizing to work at all: `xterm` reflows its terminal grid in
    /// response to one of these, not just from calling `ConfigureWindow`
    /// itself - a resize this server never reports back leaves the
    /// client's own idea of its size stale forever.
    /// Re-reads a top-level's REAL geometry off its `NSWindow` and, if it
    /// disagrees with what we have recorded, updates the record and tells
    /// the client.
    ///
    /// `windowDidMove`/`windowDidResize` each fire mid-flight, while
    /// AppKit is still settling: an external (Accessibility-driven) change
    /// that both moves and resizes delivers them in an arbitrary order,
    /// and each one sees a frame where the OTHER dimension has not been
    /// applied yet. Krita being tiled logged exactly that - a move
    /// callback at `origin=(855,-235)` while the window still had its old
    /// 740pt height, then a resize callback to 493pt. Deriving the X11
    /// origin from either of those instants gives an answer that was
    /// briefly true and then wrong, which is why Krita went on placing its
    /// File menu hundreds of points away from its own menu bar.
    ///
    /// Scheduling this for the next main-runloop turn steps outside that
    /// window entirely: by then AppKit has settled and there is exactly
    /// one correct answer to read. Idempotent, so both callbacks queueing
    /// it is harmless.
    ///
    /// Also the map-time reconciliation (`handleMapWindow` calls this right
    /// after `orderFront`), where it catches AppKit's `constrainFrameRect`
    /// silently shrinking a window taller than the screen - see that call
    /// site.
    ///
    /// HONEST STATUS on the RACE it was originally written for: still
    /// belt-and-braces, not a fix for a reproduced failure. Across every
    /// tiling run since `windowDidResize` started re-deriving the origin
    /// too, the post-resize queueing has found nothing to correct. It is
    /// kept because the callback-ordering race is real and cheap to cover,
    /// but do not read its presence as evidence that race was observed.
    /// The map-time call above is a different matter - that one corrects a
    /// change AppKit genuinely makes and reports to nobody.
    private func syncFrameFromWindow(_ record: X11State.WindowRecord) {
        guard record.isTopLevel, let window = record.nsWindow, let view = record.view else { return }
        let real = Self.x11Frame(fromCocoaWindow: window)
        let originChanged = Int(real.origin.x) != Int(record.frame.origin.x) || Int(real.origin.y) != Int(record.frame.origin.y)
        let sizeChanged = Int(real.width) != Int(record.frame.width) || Int(real.height) != Int(record.frame.height)
        guard originChanged || sizeChanged else { return }
        record.frame = real
        if sizeChanged { view.resize(width: Int(real.width), height: Int(real.height)) }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] syncFrame wid=\(record.id) -> \(real)\n".data(using: .utf8)!)
        }
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendConfigureNotify(record)
        }
        if sizeChanged, record.eventMask & 0x0000_8000 != 0 { // ExposureMask
            sendExposeEvent(windowID: record.id, width: UInt16(clamping: Int(real.width)), height: UInt16(clamping: Int(real.height)))
        }
    }

    fileprivate func sendConfigureNotify(_ record: X11State.WindowRecord) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(22) // ConfigureNotify
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(record.id) // event
        w.writeU32(record.id) // window
        w.writeU32(0) // above-sibling: None
        w.writeI16(Int16(clamping: Int(record.frame.origin.x)))
        w.writeI16(Int16(clamping: Int(record.frame.origin.y)))
        w.writeU16(UInt16(clamping: Int(record.frame.width)))
        w.writeU16(UInt16(clamping: Int(record.frame.height)))
        w.writeU16(0) // border-width
        // The window's REAL flag, not a hardcoded 0 - a client that keeps
        // its own override-redirect bookkeeping (and Qt does) would
        // otherwise be told every popup it ever created is a normal
        // managed window.
        w.writeU8(record.overrideRedirect ? 1 : 0) // override-redirect
        // Every core X11 event is EXACTLY 32 bytes, always - the fixed
        // fields above only add up to 27, so this needs 5 bytes of
        // trailing padding, not 1. Confirmed live getting this wrong
        // (padding(1), a 28-byte event) silently desynced the client's
        // read stream by the missing 4 bytes from here on - everything
        // after looked like protocol corruption to `xterm`, which
        // eventually gave up and disconnected with no useful error on
        // this side (`sendPointerEvent`/`sendExposeEvent` both happen to
        // already total exactly 32 - only this one was wrong).
        w.writePadding(5)
        writeFull(w.bytes)
    }

    /// `PropertyNotify` (code 28) - tells a client one of its own
    /// properties changed, gated on `PropertyChangeMask` like every other
    /// event type here (see `record.eventMask &` call sites throughout
    /// this file). Genuinely unimplemented before the Layer-0 harness's
    /// events test (`Guest/init/x11-tests/05_events.c`) went looking for
    /// it: `handleChangeProperty`/`handleDeleteProperty` updated `state`
    /// but never told the client anything happened - fine for the
    /// write-only properties (window titles, WM hints) this server's
    /// existing handlers exercise, but a real gap for any client using
    /// property change as a synchronization signal (ICCCM selection
    /// negotiation, `_NET_WM_STATE` watchers).
    fileprivate func sendPropertyNotify(_ record: X11State.WindowRecord, atom: UInt32, state propertyState: UInt8) {
        guard record.eventMask & 0x0040_0000 != 0 else { return } // PropertyChangeMask
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(28) // PropertyNotify
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(record.id) // window
        w.writeU32(atom)
        w.writeU32(currentX11Timestamp)
        w.writeU8(propertyState)
        w.writePadding(15) // 1+1+2+4+4+4+1 = 17 so far; pad to the mandatory 32-byte event size
        writeFull(w.bytes)
    }

    /// `ClientMessage` (code 33) - the mechanism used for the
    /// `WM_PROTOCOLS`/`WM_DELETE_WINDOW` graceful-close handshake (see
    /// `windowShouldClose(_:)`), and general-purpose enough other window-
    /// manager/toolkit conventions build on it too. `format=32`: `data0`
    /// occupies the first of five CARD32 data slots, the rest zero -
    /// exactly what `WM_DELETE_WINDOW` needs (a timestamp in the second
    /// slot is technically ICCCM-correct but optional; `0` is a
    /// documented valid "no timestamp" value, not a lie).
    fileprivate func sendClientMessage(windowID: UInt32, type: UInt32, data0: UInt32) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(33) // ClientMessage
        w.writeU8(32) // format
        w.writeU16(sequenceNumber)
        w.writeU32(windowID)
        w.writeU32(type)
        w.writeU32(data0)
        w.writePadding(16) // 4 remaining CARD32 data slots
        writeFull(w.bytes)
    }

    /// `SelectionRequest` (event 30) - asks a selection OWNER to produce
    /// data (see `handleConvertSelection`). Called on the OWNER's own
    /// `X11Connection` instance (cross-connection - `state.connection
    /// (forWindow:)` found it), so `littleEndian`/`sequenceNumber` here
    /// are correctly the OWNER's, not the requestor's.
    fileprivate func sendSelectionRequest(owner: UInt32, requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(30) // SelectionRequest
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(currentX11Timestamp)
        w.writeU32(owner)
        w.writeU32(requestor)
        w.writeU32(selection)
        w.writeU32(target)
        w.writeU32(property)
        w.writePadding(4)
        writeFull(w.bytes)
    }

    /// `SelectionNotify` (event 31) - only sent directly by this server
    /// for the "nobody owns this selection" immediate-failure case (see
    /// `handleConvertSelection`); the SUCCESS path has the owner CLIENT
    /// send its own `SelectionNotify` back via `SendEvent`/
    /// `handleSendEvent`'s generic relay instead, once it's actually
    /// written the converted data - this method exists so the immediate-
    /// failure path doesn't need to hand-roll a second, one-off 32-byte
    /// event builder just for that.
    fileprivate func sendSelectionNotify(requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32) {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(31) // SelectionNotify
        w.writePadding(1)
        w.writeU16(sequenceNumber)
        w.writeU32(currentX11Timestamp)
        w.writeU32(requestor)
        w.writeU32(selection)
        w.writeU32(target)
        w.writeU32(property)
        w.writePadding(8)
        writeFull(w.bytes)
    }

    // MARK: - Raw fd I/O

    private func readFull(_ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        // Replayed bytes first - see `pendingPrefix`. Only ever non-empty
        // at the very start of a handed-off connection, so this costs one
        // `isEmpty` check per read after that.
        if !pendingPrefix.isEmpty {
            let take = min(count, pendingPrefix.count)
            for i in 0..<take { buf[i] = pendingPrefix[i] }
            pendingPrefix.removeFirst(take)
            got = take
            if got == count { return buf }
        }
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            let base = ptr.baseAddress!
            while got < count {
                let n = read(fd, base + got, count - got)
                if n > 0 { got += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    // The socket is non-blocking (see `run`): wait for data.
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&pfd, 1, -1) < 0, errno != EINTR { return false }
                    continue
                }
                return false // EOF or a real error
            }
            return true
        }
        return ok ? buf : nil
    }

    private func writeFull(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        // Every event this server sends leaves through here, so this is the
        // one place that can answer "what did the client actually receive?"
        // - the question that matters when a toolkit reacts to something
        // rather than to a request it made. Events are exactly 32 bytes
        // with a code in 2...35 in byte 0; replies (code 0/1) and the
        // variable-length reply tails are skipped.
        if X11Trace.enabled, bytes.count == 32, bytes[0] >= 2, bytes[0] <= 35 {
            let wid = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
            FileHandle.standardError.write("[x11] >>EVT code=\(bytes[0]) detail=\(bytes[1]) w4=\(wid)\n".data(using: .utf8)!)
        }
        // Never blocks. This is called on the main thread for every mouse
        // move, key and focus change, and a blocking `write` into a guest
        // that is not reading - paused for sleep, idle suspend, low battery -
        // parked the main thread once the socket buffer filled: a beachball
        // that needed Force Quit (confirmed by `sample` after a lid close).
        // What the socket won't take waits in `writeBacklog`, in order, for a
        // background drain; replies and events after it queue behind it.
        // Pointer motion is dropped instead while there is a backlog - a
        // client wants the latest position, not every one it missed.
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !writeClosed else { return }
        if !writeBacklog.isEmpty {
            if Self.isDroppableMotion(bytes, littleEndian: littleEndian) { return }
            writeBacklog.append(contentsOf: bytes)
            enforceWriteBacklogLimit()
            return
        }
        let sent = sendAvailable(bytes)
        guard !writeClosed, sent < bytes.count else { return }
        if sent == 0, Self.isDroppableMotion(bytes, littleEndian: littleEndian) { return }
        writeBacklog.append(contentsOf: bytes[sent...])
        enforceWriteBacklogLimit()
        if !writeClosed, !writeBacklogDraining {
            writeBacklogDraining = true
            Thread.detachNewThread { [self] in drainWriteBacklog() }
        }
    }

    /// Sends as much of `bytes` as the socket takes without blocking and
    /// returns the count. Sets `writeClosed` on a real error. `writeLock`
    /// must be held.
    private func sendAvailable(_ bytes: [UInt8]) -> Int {
        var sent = 0
        bytes.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!
            while sent < ptr.count {
                // Non-blocking because `run` made the descriptor so.
                let n = write(fd, base + sent, ptr.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                writeClosed = true
                return
            }
        }
        return sent
    }

    /// `writeLock` must be held.
    private func enforceWriteBacklogLimit() {
        guard writeBacklog.count > Self.writeBacklogLimit else { return }
        writeBacklog.removeAll()
        writeClosed = true
        shutdown(fd, SHUT_RDWR) // ends `run`'s read loop, which cleans up
    }

    /// Waits for the socket to accept more and hands it the backlog, until
    /// the backlog is empty or the connection is gone.
    private func drainWriteBacklog() {
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 500)
            writeLock.lock()
            if !writeClosed, !writeBacklog.isEmpty {
                let sent = sendAvailable(writeBacklog)
                if sent > 0 { writeBacklog.removeFirst(sent) }
            }
            let done = writeClosed || writeBacklog.isEmpty
            if done {
                writeBacklog.removeAll()
                writeBacklogDraining = false
            }
            writeLock.unlock()
            if done { return }
        }
    }

    /// Core `MotionNotify`, `XI_Motion` or `XI_RawMotion` - the only events
    /// safe to drop when the client is behind, because the next one
    /// supersedes them. Button, key, crossing and focus events never are.
    static func isDroppableMotion(_ bytes: [UInt8], littleEndian: Bool) -> Bool {
        if bytes.count == 32, bytes[0] & 0x7F == 6 { return true }
        guard bytes.count >= 10, bytes[0] == 35, bytes[1] == X11Opcode.xinputExtension else { return false }
        let evtype = littleEndian
            ? UInt16(bytes[8]) | UInt16(bytes[9]) << 8
            : UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return evtype == XIEventType.motion || evtype == XIEventType.rawMotion
    }

    /// Delivers a raw, already-encoded 32-byte event straight onto this
    /// connection's wire - `SendEvent`'s "deliver this to some window"
    /// mechanism (`handleSendEvent`, the only caller: resolves the
    /// destination `X11Connection` via `X11State.connection(forWindow:)`,
    /// then calls this on it). Kept `fileprivate` rather than exposing
    /// `writeFull` itself (which callers could otherwise misuse to send
    /// non-event, non-32-byte payloads and corrupt this connection's
    /// stream).
    ///
    /// Overwrites the event's own sequence-number field (bytes 2-3) with
    /// THIS (the destination) connection's current `sequenceNumber`
    /// before sending, exactly like every other event-sender in this file
    /// already does implicitly by reading `sequenceNumber` live - a
    /// client's own `XSendEvent(...)` never fills that field in
    /// meaningfully (it's for the SERVER to stamp on relay, per the core
    /// protocol spec), so forwarding it verbatim leaves whatever the
    /// caller's `XEvent` struct happened to contain - `0` for anything
    /// freshly `memset`, as a synthetic event most callers build. Real
    /// X11 clients track sequence numbers strictly (matching replies to
    /// requests); an event bearing a sequence number that doesn't
    /// correlate with anything the destination has actually sent reads as
    /// protocol corruption. Confirmed live via the Layer-0 harness
    /// (`Guest/init/x11-tests/05_events.c`'s synthetic `ButtonPress` via
    /// `XSendEvent`): without this fix, Xlib's XCB compatibility layer
    /// aborted outright with "Unknown sequence number while processing
    /// queue" the moment the relayed event arrived.
    fileprivate func deliverEvent(_ bytes: [UInt8]) {
        var patched = bytes
        guard patched.count >= 4 else { return }
        if littleEndian {
            patched[2] = UInt8(sequenceNumber & 0xFF)
            patched[3] = UInt8(sequenceNumber >> 8)
        } else {
            patched[2] = UInt8(sequenceNumber >> 8)
            patched[3] = UInt8(sequenceNumber & 0xFF)
        }
        writeFull(patched)
    }
}

// MARK: - Input events

/// Detects the user dragging a top-level window's own edge/corner (real
/// window-server-driven resizing, as opposed to the client resizing
/// itself via `ConfigureWindow`) and propagates it back: resizes the
/// view's backing bitmap (preserving content, same as `ConfigureWindow`'s
/// own path) and tells the client via `ConfigureNotify` so it can reflow
/// - without this, dragging the real macOS window's corner changed the
/// window's on-screen size but left both the client's own idea of its
/// size AND this server's drawing surface stuck at whatever they were
/// when the window was created.
extension X11Connection: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let view = window.contentView as? X11CanvasView,
              let record = state.window(view.windowID)
        else { return }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] windowDidResize wid=\(record.id) viewSize=\(view.frame.size) recordSize=\(record.frame.size)\n".data(using: .utf8)!)
        }
        // No echo counter - the size comparison below is the reliable
        // test, for exactly the reasons spelled out in `windowDidMove`.
        // Observed leaking the same way (`pending=1` on a no-op callback
        // whose sizes already matched, consuming the count a later real
        // resize needed).
        if record.matchesProgrammaticFrame(window.frame) {
            record.programmaticOuterFrame = nil
            return
        }
        let size = view.frame.size // AppKit already resized the content view to match
        guard Int(size.width) != Int(record.frame.width) || Int(size.height) != Int(record.frame.height) else { return }
        record.frame.size = size
        // A resize MOVES the X11 origin as well. AppKit's window origin is
        // its BOTTOM-left corner, so a window resized with its top edge
        // held still (what an Accessibility-driven or top-anchored resize
        // does) keeps `frame.origin.y` fixed while the content TOP - which
        // is what X11's top-left origin is measured from - shifts by the
        // height delta. Updating only `size` here left `frame.origin`
        // describing the pre-resize position forever.
        //
        // Confirmed live as the second half of the "menus go haywire"
        // bug: tiling Krita fired `windowDidMove` first (while the window
        // still had its OLD height) and `windowDidResize` second, so even
        // with the move correctly recorded the origin was computed against
        // a height that was about to change, and the File menu still
        // opened hundreds of points off. Re-deriving the whole frame from
        // the window itself makes both callbacks agree no matter which
        // order they arrive in.
        record.frame.origin = Self.x11Frame(fromCocoaWindow: window).origin
        view.resize(width: Int(size.width), height: Int(size.height))
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendConfigureNotify(record)
        }
        // Confirmed live this was the "black border on resize" bug: a
        // GROWING resize reveals a region that was previously off the
        // edge of the window entirely - real X servers send `Expose` for
        // that newly-visible area (same as a fresh `MapWindow` needs one
        // for its whole, previously-nonexistent-on-screen area), and GTK
        // relies on receiving it to know it needs to actually PAINT
        // there; `ConfigureNotify` alone only updates the client's idea
        // of its own size, it doesn't by itself guarantee a repaint of
        // the newly-revealed pixels. Sending Expose for the whole window
        // (not just the delta) is simpler and spec-valid - `handleMapWindow`
        // already does the same "whole window, not precise sub-rects"
        // simplification for the exact same reason.
        if record.eventMask & 0x0000_8000 != 0 { // ExposureMask
            sendExposeEvent(windowID: record.id, width: UInt16(clamping: Int(size.width)), height: UInt16(clamping: Int(size.height)))
        }
        // See `syncFrameFromWindow` - a resize that arrives before the
        // matching move leaves the ORIGIN derived from a frame AppKit has
        // not finished updating.
        DispatchQueue.main.async { self.syncFrameFromWindow(record) }
    }

    /// The `windowDidResize` counterpart for a pure drag-move (no size
    /// change) - genuinely missing before, confirmed live to cause a
    /// real, visible bug: without this, dragging a window updates
    /// AppKit's OWN idea of the window's position but leaves `record.
    /// frame.origin` (this server's own tracked position) stale at
    /// wherever it last was - usually right where the window was
    /// CREATED. That's silently wrong until something else calls
    /// `setFrame(Self.cocoaScreenFrame(fromX11: record.frame), ...)`
    /// using that stale origin (`handleConfigureWindow`, whenever the
    /// CLIENT resizes itself - very common, GTK does this routinely) -
    /// at which point the window snaps back to that stale position,
    /// which if never updated is close to (0,0): exactly the "moving or
    /// resizing pins the window to the top-left, phasing into the menu
    /// bar" bug reported from live use. Mirrors `windowDidResize`'s own
    /// `pendingProgrammatic*` suppression so a `handleConfigureWindow`-
    /// initiated `setFrame` doesn't ALSO trigger a redundant `
    /// ConfigureNotify` back to the same client that just set it.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let view = window.contentView as? X11CanvasView,
              let record = state.window(view.windowID)
        else { return }
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] windowDidMove wid=\(record.id) winOrigin=\(window.frame.origin) recordOrigin=\(record.frame.origin)\n".data(using: .utf8)!)
        }
        // NO echo counter here any more - see the guard below. This used
        // to early-return whenever a `pendingProgrammaticMoves` count was
        // outstanding, to swallow the delegate callback a server-initiated
        // `setFrame` causes. Counting expected callbacks is fragile: any
        // `setFrame` whose callback does not arrive (or arrives merged
        // with another) leaves the count high, and the NEXT genuine move
        // is silently eaten.
        //
        // Confirmed live, and it is the "menus and dialogs go haywire"
        // bug: tiling Krita logged
        //   windowDidMove wid=41943058 pending=1
        //     winOrigin=(855,-235) recordOrigin=(285,186)
        // - a REAL move to (855,-235) discarded as an echo. The record
        // kept the original (285,186) forever, so Krita placed its File
        // menu at root (291,208) - correct for where it believed it was,
        // hundreds of pixels from where it actually was on screen.
        //
        // The `guard` below already distinguishes the two cases perfectly
        // and cannot leak: if the window's real position already matches
        // the record, this IS the echo of a change we recorded and there
        // is nothing to do; if it differs, it is a real move that MUST be
        // recorded whoever caused it. A `ConfigureNotify` that repeats one
        // `handleConfigureWindow` already sent is harmless - clients
        // tolerate repeats, and real X11 sends one for server-initiated
        // moves anyway. Dropping a real one is not harmless.
        if record.matchesProgrammaticFrame(window.frame) {
            record.programmaticOuterFrame = nil
            return
        }
        // `x11Frame(fromCocoaWindow:)` rather than re-deriving the flip
        // here: this used to do its own `screenHeight - frame.origin.y -
        // record.frame.height`, which silently disagrees with the shared
        // converter whenever `record.frame.height` has drifted from the
        // content view's REAL height (mid-resize, or after a client
        // resize this delegate hasn't caught up with). Two different
        // answers for "where is this window in X11 coordinates" is
        // exactly how a client's popup-placement math ends up off by a
        // title bar - see the converter's own doc comment on
        // `gui-bugs.md` #5.
        let newOrigin = Self.x11Frame(fromCocoaWindow: window).origin
        guard Int(newOrigin.x) != Int(record.frame.origin.x) || Int(newOrigin.y) != Int(record.frame.origin.y) else { return }
        record.frame.origin = newOrigin
        if record.eventMask & 0x0002_0000 != 0 { // StructureNotifyMask
            sendConfigureNotify(record)
        }
        // See `syncFrameFromWindow` - this callback can be reporting a
        // half-applied external change, so re-read once AppKit settles.
        DispatchQueue.main.async { self.syncFrameFromWindow(record) }
    }

    /// See `sendFocusEvent`'s doc comment - `FocusIn`/`FocusOut` was
    /// genuinely missing before this and is a real, independent gap
    /// (confirmed live: Qt visibly reacted to it, repainting a focus-
    /// border decoration). Originally believed - based on a test that
    /// turned out to be running against a misconnected guest client - to
    /// ALSO be why `QMenuBar` never opened on click; a clean re-test
    /// after fixing that connection showed `FocusIn` firing correctly
    /// with the menu still not opening, so that specific claim was
    /// wrong. An EWMH `_NET_SUPPORTING_WM_CHECK` handshake was tried
    /// next (also chasing the same menu bug), didn't fix it EITHER, and
    /// was reverted outright after it turned out to cause a real
    /// regression elsewhere (galculator's rendering broke - see
    /// `handleGetProperty`'s "REVERTED 2026-09-04" comment). `FocusIn`/
    /// `FocusOut` themselves are kept - real, independent, Qt visibly
    /// reacts. The `QMenuBar` click issue itself is still open - see
    /// `gui-bugs.md` for the current state of that investigation and why
    /// it now needs a real (non-`CGEventPost`) click to make progress on.
    /// `makeKeyAndOrderFront` at `MapWindow` time already makes a
    /// freshly-created window key, which fires this the same way any
    /// later focus change would - no separate call needed at map time.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let view = window.contentView as? X11CanvasView,
              let record = state.window(view.windowID)
        else {
            if X11Trace.mouseEnabled { FileHandle.standardError.write("[x11] windowDidBecomeKey: no record/view\n".data(using: .utf8)!) }
            return
        }
        // Core and XI2 focus delivery are independent, exactly like
        // `keyEvent`/`mouseButton`'s dual delivery - a GTK3/XI2 client
        // selects NO core focus bit at all, so gating the XI2 send on the
        // core mask (or vice versa) silently drops focus for one whole
        // class of client. See `sendXIFocusEvent`'s doc comment.
        let xiFocusBit = UInt32(1) << UInt32(XIEventType.focusIn)
        if X11Trace.mouseEnabled { FileHandle.standardError.write("[x11] windowDidBecomeKey wid=\(record.id) eventMask=0x\(String(record.eventMask, radix: 16)) core=\(record.eventMask & 0x0020_0000 != 0) xi=\(record.xiEventMask & xiFocusBit != 0) overrideRedirect=\(record.overrideRedirect)\n".data(using: .utf8)!) }
        // An override-redirect window (a menu/popup) is override-redirect
        // PRECISELY so that it bypasses the window manager and never takes
        // the input focus - see `windowDidResignKey` for the other half of
        // this, and why reporting focus for one breaks menus outright. It
        // must also NOT become the reported `GetInputFocus` window: while
        // a menu is up, focus stays on the toplevel underneath it.
        guard !record.overrideRedirect else { return }
        // Key coming back from this window's own popup: its FocusOut was
        // suppressed, so in X11 terms focus never left and a real server
        // would send nothing. The extra FocusIn landed while Tk's menu was
        // posted and closed it (IDLE/gitk menus vanishing on open). If a
        // DIFFERENT window takes key instead, the owed FocusOut goes first.
        let previousFocus = state.currentFocusWindow()
        let focusNeverLeft = record.focusOutSuppressed && previousFocus == record.id
        record.focusOutSuppressed = false
        if previousFocus != record.id, let previous = state.window(previousFocus), previous.focusOutSuppressed {
            previous.focusOutSuppressed = false
            releaseHeldKeys(windowID: previous.id)
            if previous.eventMask & 0x0020_0000 != 0 { sendFocusEvent(code: 10, windowID: previous.id) }
            if previous.xiEventMask & xiFocusBit != 0 { sendXIFocusEvent(focusIn: false, windowID: previous.id) }
        }
        if focusNeverLeft {
            if X11Trace.mouseEnabled { FileHandle.standardError.write("[x11] windowDidBecomeKey wid=\(record.id) focus never left; no FocusIn\n".data(using: .utf8)!) }
            return
        }
        // Retarget the single shared Dock tile at whichever Linux app the
        // user just switched to - see `X11DockIntegration`'s doc comment
        // on why there is only one tile to retarget. Below the
        // override-redirect guard on purpose: a menu opening must not
        // change which app the Dock claims to be showing.
        X11DockIntegration.shared.keyWindowChanged(to: record.id)
        // With no real window manager here, AppKit's key window IS the
        // X11 input focus - keep the two in sync so `GetInputFocus`
        // answers truthfully (see `handleGetInputFocus`).
        state.setFocusWindow(record.id)
        if record.eventMask & 0x0020_0000 != 0 { // FocusChangeMask
            sendFocusEvent(code: 9, windowID: record.id) // FocusIn
        }
        if record.xiEventMask & xiFocusBit != 0 {
            sendXIFocusEvent(focusIn: true, windowID: record.id)
        }
        syncModifiersOnFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let view = window.contentView as? X11CanvasView,
              let record = state.window(view.windowID)
        else { return }
        // Suppressed while ANY override-redirect window is mapped, i.e.
        // while a menu is open. Confirmed live as the reason Krita's
        // `QMenuBar` never opened (`gui-bugs.md` #14, open across several
        // sessions): clicking "File" made Qt correctly create, position
        // (443x516, real menu geometry), and MAP its popup - but this
        // server backs an override-redirect window with a real `NSWindow`
        // that takes AppKit key status, so the main window resigned key
        // and got a `FocusOut`. Qt reads that as "my window lost the
        // focus" and tears the menu straight back down - traced as
        // `UngrabKeyboard` + `UnmapWindow` landing immediately after the
        // popup became key, every time. In real X11 none of that happens:
        // an override-redirect window is unmanaged and NEVER takes the
        // input focus, so the menu's own toplevel keeps focus the whole
        // time the menu is up. Suppressing both halves (no `FocusIn` for
        // the popup in `windowDidBecomeKey`, no `FocusOut` for whoever it
        // stole AppKit key status from here) reproduces that.
        let menuOpen = state.hasMappedOverrideRedirectWindow
        if X11Trace.mouseEnabled { FileHandle.standardError.write("[x11] windowDidResignKey wid=\(record.id) eventMask=0x\(String(record.eventMask, radix: 16)) suppressed=\(menuOpen)\n".data(using: .utf8)!) }
        guard !menuOpen else {
            record.focusOutSuppressed = true
            return
        }
        releaseHeldKeys(windowID: record.id)
        if record.eventMask & 0x0020_0000 != 0 { // FocusChangeMask
            sendFocusEvent(code: 10, windowID: record.id) // FocusOut
        }
        if record.xiEventMask & (UInt32(1) << UInt32(XIEventType.focusIn)) != 0 {
            sendXIFocusEvent(focusIn: false, windowID: record.id)
        }
    }

    /// The red traffic-light button, without this, would just let AppKit
    /// close the real `NSWindow` directly - the X11 CLIENT (`xterm`,
    /// still running, still connected) would never hear about it at all,
    /// leaving the process alive with an invisible window. Real X11
    /// clients that care about a graceful close (save-changes prompts,
    /// cleanup) register for it via ICCCM's `WM_PROTOCOLS`/
    /// `WM_DELETE_WINDOW` convention: setting a `WM_PROTOCOLS` property
    /// (a list of atoms) on their window naming which optional protocols
    /// they handle themselves. When that includes `WM_DELETE_WINDOW`,
    /// the "close" affordance is supposed to become a `ClientMessage`
    /// event instead of the server unilaterally destroying anything -
    /// this is that. A client that never registered it (simpler/older
    /// clients) gets the old unilateral-destroy behavior instead, since
    /// there's no one listening for the polite version.
    /// Keeps the Dock integration's window list honest no matter HOW a
    /// window went away.
    ///
    /// The normal paths already report it - `windowShouldClose` and
    /// `handleUnmapWindow`/`destroyWindowRecursive` all call
    /// `windowDidUnmap`. This catches the ones that don't: `X11State.
    /// closeAllWindows()` on server stop, and any future host-side close.
    /// A stale entry is not cosmetic - the list is what keeps the process
    /// `.regular`, so one dead window means a Dock tile that never goes
    /// away and a Dock menu offering to raise a closed `NSWindow`.
    /// Idempotent, so the paths that already report are unaffected.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let view = window.contentView as? X11CanvasView
        else { return }
        X11DockIntegration.shared.windowDidUnmap(view.windowID)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let view = sender.contentView as? X11CanvasView,
              let record = state.window(view.windowID)
        else { return true }

        let wmProtocols = state.internAtom("WM_PROTOCOLS", onlyIfExists: true)
        let wmDeleteWindow = state.internAtom("WM_DELETE_WINDOW", onlyIfExists: true)
        if wmProtocols != 0, wmDeleteWindow != 0,
           let prop = record.properties[wmProtocols], prop.format == 32 {
            let atoms = stride(from: 0, to: prop.data.count - 3, by: 4).map { i in
                UInt32(prop.data[i]) | UInt32(prop.data[i + 1]) << 8 | UInt32(prop.data[i + 2]) << 16 | UInt32(prop.data[i + 3]) << 24
            }
            if atoms.contains(wmDeleteWindow) {
                sendClientMessage(windowID: view.windowID, type: wmProtocols, data0: wmDeleteWindow)
                return false // let the client decide - it'll DestroyWindow itself, or just disconnect, when ready
            }
        }
        // No graceful-close support registered - same as a real X server
        // facing a client with no WM_PROTOCOLS: just take the window down.
        destroyWindowRecursive(view.windowID)
        return false // this connection's own state just handled teardown; AppKit doesn't need to also close it
    }
}

extension X11Connection {
    /// Whether the sandbox is currently dropping input for this instance.
    ///
    /// Checked per event, which is cheap - `X11InputGate` caches and only
    /// re-reads the policy file when its modification date moves.
    ///
    /// **Crossing events are deliberately never gated.** A dropped Leave
    /// after a delivered Enter wedges GTK4's pointer focus outright (no
    /// hover, no selection, no scrolling in any scrolled list) - a bug that
    /// took a long time to find once already. Enter/Leave carry no user
    /// intent worth blocking anyway; they describe where the pointer is,
    /// not what it did.
    var inputIsFrozen: Bool { X11InputGate.shared.isFrozen(instance: instance) }
}

extension X11Connection: X11EventSink {
    /// `state` used to be hardcoded `0` for every button event - meaning a
    /// `ButtonRelease` always reported "no buttons were down going into
    /// this release" even though, per the X11 spec, `state` on a release
    /// MUST include the very button being released (it was down a moment
    /// ago) plus any modifier keys held. Found while investigating Krita's
    /// `QMenuBar` not opening on click: `ButtonPress`/`ButtonRelease` both
    /// delivered at exactly the right coordinates (confirmed via trace)
    /// with zero visible reaction, no new popup window, nothing - Qt's
    /// xcb backend cross-checks `state` when resolving a release against
    /// the press that opened it (the same class of "grab-based state
    /// machine silently rejects a click that LOOKS right" bug already
    /// found for GTK's root-coordinate case, `gui-bugs.md` #10, just a
    /// different field). `pressedButtons` tracks what's actually down so
    /// `x11ButtonMask` can report it correctly on the release without
    /// needing a separate per-button grab/ungrab protocol.
    func mouseButton(_ event: NSEvent, in view: X11CanvasView, pressed: Bool, button: UInt8) {
        guard !inputIsFrozen else { return }
        guard let record = state.window(view.windowID) else {
            if X11Trace.mouseEnabled { FileHandle.standardError.write("[x11] mouseButton: NO RECORD for wid=\(view.windowID)\n".data(using: .utf8)!) }
            return
        }
        let mask: UInt32 = pressed ? 0x0000_0004 : 0x0000_0008 // ButtonPressMask / ButtonReleaseMask
        if X11Trace.mouseEnabled {
            FileHandle.standardError.write("[x11] mouseButton t=\(currentX11Timestamp) appkit=\(Int(event.timestamp * 1000)) eventNumber=\(event.eventNumber) wid=\(view.windowID) pressed=\(pressed) button=\(button) eventMask=0x\(String(record.eventMask, radix: 16)) needsMask=0x\(String(mask, radix: 16)) passes=\(record.eventMask & mask != 0) locInWindow=\(event.locationInWindow) viewBounds=\(view.bounds) viewFrame=\(view.frame) winFrame=\(view.window?.frame ?? .zero)\n".data(using: .utf8)!)
        }
        let point = view.convert(event.locationInWindow, from: nil)
        let x = Int16(clamping: Int(point.x)), y = Int16(clamping: Int(point.y))
        // Read `pressedButtons` BEFORE mutating it: on a press this button
        // genuinely isn't in the set yet (correctly excluded from state,
        // per spec - state reflects buttons down *before* this one), and
        // on a release it's still sitting there from the matching press
        // that hasn't been removed yet (correctly included - it WAS down
        // going into the release), so no special-casing needed either way.
        let stateMask = UInt16(X11KeyboardState.shared.current.effectiveMods) | Self.x11ButtonMask(pressedButtons)
        let buttonsBefore = pressedButtons
        if pressed { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        // XI2 FIRST, core only as a fallback - see `xi2TakesPrecedence`.
        let xiEvtype = pressed ? XIEventType.buttonPress : XIEventType.buttonRelease
        let xiPasses = xi2TakesPrecedence(record, evtype: xiEvtype)
        if X11Trace.mouseEnabled {
            FileHandle.standardError.write("[x11] mouseButton XI2 wid=\(view.windowID) xiEventMask=0x\(String(record.xiEventMask, radix: 16)) needsBit=\(xiEvtype) passes=\(xiPasses)\n".data(using: .utf8)!)
        }
        if xiPasses {
            sendXIDeviceEvent(evtype: xiEvtype, detail: UInt32(button), deviceid: XIDeviceUse.corePointerID, windowID: view.windowID, x: x, y: y,
                              buttons: buttonsBefore)
        } else if record.eventMask & mask != 0 {
            if X11Trace.mouseEnabled {
                FileHandle.standardError.write("[x11] mouseButton delivering core event at (\(point.x),\(point.y)) state=0x\(String(stateMask, radix: 16))\n".data(using: .utf8)!)
            }
            sendPointerEvent(code: pressed ? 4 : 5, detail: button, windowID: view.windowID, x: x, y: y, state: stateMask)
        }
    }

    /// Whether an XI2 selection exists for `evtype` on `record` - and, by
    /// answering `true`, that the CORE event for the same physical input
    /// must NOT also be sent.
    ///
    /// This server used to deliver both channels unconditionally, each
    /// gated only on its own mask. That was wrong, and it is the real
    /// cause of Krita's `QMenuBar` never staying open (`gui-bugs.md` #14,
    /// chased across many sessions and blamed on focus twice). Qt selects
    /// BOTH core `ButtonPress` (`eventMask` 0x4) and XI2 `XI_ButtonPress`
    /// (`xiEventMask` bit 4) on its toplevel, so one physical click on
    /// "File" arrived as TWO presses. `QMenuBar` toggles: press #1 opened
    /// the popup (traced: `CreateWindow`, geometry 443x516, `MapWindow`,
    /// `MapNotify`, `Expose`, `GrabKeyboard`, `XIGrabDevice` - all
    /// correct), press #2 immediately closed it again (`XIUngrabDevice`,
    /// `UngrabKeyboard`, `UnmapWindow`). Confirmed against the trace that
    /// this server sent Qt NOTHING between the map and the teardown - no
    /// focus event, no crossing, no input - so the second press was the
    /// only possible trigger.
    ///
    /// Real X11 has never allowed both. `dix/events.c`'s
    /// `DeliverDeviceEvents` (xorg-server source, the `XQuartz/xorg-server`
    /// repository) tries XI2 first and `break`s the moment it
    /// delivers, falls through to XI1, and only reaches the core branch
    /// when neither delivered anything. The fallback ordering matters as
    /// much as the exclusion: a GDK switched to XI2 (see
    /// `handleXInputRequest`) may never set the core bits at all, so core
    /// can't simply be preferred either.
    private func xi2TakesPrecedence(_ record: X11State.WindowRecord, evtype: UInt16) -> Bool {
        record.xiEventMask & (UInt32(1) << UInt32(evtype)) != 0
    }

    func mouseMoved(_ event: NSEvent, in view: X11CanvasView) {
        guard !inputIsFrozen else { return }
        var view = view
        guard var record = state.window(view.windowID) else { return }
        // A plain move reaches every nested view whose tracking area holds
        // the pointer, plus the first responder again - Tk's menubar (a
        // child of its wrapper) got each move three times. X11 reports it
        // once, on the deepest window, propagating up to the first ancestor
        // that selects motion. Drags are left alone: they belong to the
        // window that took the press, wherever the pointer is.
        if event.type == .mouseMoved {
            guard let content = view.window?.contentView,
                  content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) === view,
                  view.lastMotionTimestamp != event.timestamp
            else { return }
            view.lastMotionTimestamp = event.timestamp
            while record.eventMask & 0x0000_0040 == 0, !xi2TakesPrecedence(record, evtype: XIEventType.motion) {
                guard !record.isTopLevel, let parent = state.window(record.parent), let parentView = parent.view else { return }
                record = parent
                view = parentView
            }
        }
        let point = view.convert(event.locationInWindow, from: nil)
        let x = Int16(clamping: Int(point.x)), y = Int16(clamping: Int(point.y))
        let corePasses = record.eventMask & 0x0000_0040 != 0 // PointerMotionMask
        let xiPasses = xi2TakesPrecedence(record, evtype: XIEventType.motion)
        if X11Trace.mouseEnabled {
            FileHandle.standardError.write("[x11] mouseMoved t=\(currentX11Timestamp) appkit=\(Int(event.timestamp * 1000)) wid=\(view.windowID) x=\(x) y=\(y) corePasses=\(corePasses) xiPasses=\(xiPasses)\n".data(using: .utf8)!)
        }
        if xiPasses {
            sendXIDeviceEvent(evtype: XIEventType.motion, detail: 0, deviceid: XIDeviceUse.corePointerID, windowID: view.windowID, x: x, y: y)
        } else if corePasses {
            // Real state, not 0: a core client (Xt, Tk) tells a drag from a
            // plain move by Button1Mask here.
            let state = UInt16(X11KeyboardState.shared.current.effectiveMods) | Self.x11ButtonMask(pressedButtons)
            sendPointerEvent(code: 6, detail: 0, windowID: view.windowID, x: x, y: y, state: state)
        }
    }

    /// See `sendXICrossingEvent`'s doc comment (`gui-bugs.md` #10) - the
    /// fix that was actually missing for GTK menu-item activation. Same
    /// independent-core/XI2 gating pattern as `mouseButton`/`mouseMoved`
    /// above: a GDK build that's switched to XI2 selects crossing events
    /// via `XISelectEvents` (`1 << XIEventType.enter/.leave`) and may
    /// never set the core `EnterWindowMask`/`LeaveWindowMask` bits at all.
    func mouseCrossing(_ event: NSEvent, in view: X11CanvasView, entered: Bool) {
        let point = view.convert(event.locationInWindow, from: nil)
        deliverCrossing(windowID: view.windowID, x: Int16(clamping: Int(point.x)), y: Int16(clamping: Int(point.y)), entered: entered)
    }

    /// Split out of `mouseCrossing` above so `handleMapWindow` can
    /// synthesize an initial `entered=true` for a POPUP window the
    /// pointer is already sitting inside the moment it's mapped (a real
    /// `NSTrackingArea` only fires `mouseEntered`/`mouseExited` on an
    /// actual crossing MOTION - it does NOT retroactively synthesize one
    /// just because the cursor happens to already be inside when the
    /// tracking area becomes active). `gui-bugs.md` #10: confirmed live
    /// this is exactly what was still missing after `sendXICrossingEvent`
    /// itself started working - a GTK dropdown opens centered right where
    /// the pointer already is, so the popup's own `X11CanvasView` never
    /// sees a real AppKit crossing at all, only a stray `mouseMoved` with
    /// coordinates relative to the OLD (pre-map) view geometry (observed
    /// live as wildly out-of-bounds negative values). Without a real
    /// `XI_Enter` on the popup, GTK's `active_menu_item` never gets set,
    /// so a subsequent `ButtonRelease` - however correctly delivered -
    /// resolves to "no item".
    private func deliverCrossing(windowID: UInt32, x: Int16, y: Int16, entered: Bool) {
        guard let record = state.window(windowID) else { return }
        // Enter and Leave STRICTLY alternate in real X11 - a window is
        // either the one the pointer is in or it isn't, and a second Enter
        // with no Leave between describes a transition that cannot happen.
        // AppKit hands us exactly that (see `WindowRecord.pointerInside`
        // for the observed triple-Enter), and a toolkit's pointer-focus
        // bookkeeping is a state machine that has every right to be
        // confused by it. Drop the redundant one rather than forwarding a
        // transition the protocol says is impossible.
        guard record.pointerInside != entered else {
            if X11Trace.mouseEnabled {
                FileHandle.standardError.write("[x11] mouseCrossing wid=\(windowID) entered=\(entered) SUPPRESSED (already \(entered ? "inside" : "outside"))\n".data(using: .utf8)!)
            }
            return
        }
        record.pointerInside = entered
        let coreMask: UInt32 = entered ? 0x0000_0010 : 0x0000_0020 // EnterWindowMask / LeaveWindowMask
        let xiEvtype = entered ? XIEventType.enter : XIEventType.leave
        let corePasses = record.eventMask & coreMask != 0
        let xiPasses = xi2TakesPrecedence(record, evtype: xiEvtype)
        if X11Trace.mouseEnabled {
            FileHandle.standardError.write("[x11] mouseCrossing wid=\(windowID) entered=\(entered) x=\(x) y=\(y) corePasses=\(corePasses) xiPasses=\(xiPasses)\n".data(using: .utf8)!)
        }
        if xiPasses {
            sendXICrossingEvent(evtype: xiEvtype, deviceid: XIDeviceUse.corePointerID, windowID: windowID, x: x, y: y)
        } else if corePasses {
            sendCoreCrossingEvent(code: entered ? 7 : 8, windowID: windowID, x: x, y: y)
        }
    }

    /// Called right after a window is ordered front (`handleMapWindow`) -
    /// if the real pointer is already sitting inside the window's bounds
    /// at that instant, synthesizes the `entered=true` crossing AppKit
    /// itself won't (see `deliverCrossing`'s doc comment). A no-op for the
    /// overwhelmingly common case (a top-level window mapping somewhere
    /// the pointer isn't), so this costs nothing there.
    private func synthesizeCrossingIfPointerAlreadyInside(_ record: X11State.WindowRecord, windowID: UInt32) {
        guard let window = record.nsWindow, let view = record.view else { return }
        let windowLoc = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewLoc = view.convert(windowLoc, from: nil)
        guard view.bounds.contains(viewLoc) else { return }
        deliverCrossing(windowID: windowID, x: Int16(clamping: Int(viewLoc.x)), y: Int16(clamping: Int(viewLoc.y)), entered: true)
    }

    /// A key from AppKit (or from `X11KeyboardRouter`, for Command combos).
    ///
    /// Modifiers are resynced first: if the event's flags disagree with
    /// what is tracked, a modifier changed while this window wasn't hearing
    /// about it (see `X11ModifierTracker`), and the key must not go out
    /// against stale state - Ctrl held while clicking into the window, then
    /// C, has to arrive as Ctrl+C.
    func keyEvent(_ event: NSEvent, in view: X11CanvasView, pressed: Bool) {
        guard !inputIsFrozen else { return }
        guard let keycode = X11KeyCodes.keycode(forMac: event.keyCode) else {
            if X11Trace.enabled { FileHandle.standardError.write("[x11] keyEvent: no keycode for macKeyCode=\(event.keyCode)\n".data(using: .utf8)!) }
            return
        }
        let point = view.convert(event.locationInWindow, from: nil)
        let x = Int16(clamping: Int(point.x)), y = Int16(clamping: Int(point.y))
        let keyboard = X11KeyboardState.shared
        let remapper = X11ShortcutRemapper(MSLExperimentalSettingsWatcher.shared.current)
        keyboard.setHiddenModifiers(remapper.hidesCommand
            ? [X11KeyCodes.Modifier.leftCommand, X11KeyCodes.Modifier.rightCommand] : [])
        for transition in keyboard.resync(rawFlags: event.modifierFlags.rawValue) {
            deliverKey(transition, windowID: view.windowID, x: x, y: y)
        }
        // Experimental Mac-to-Linux shortcuts (off unless turned on in MSL).
        // A remapped key is delivered whole - press and release - on its
        // keyDown, so its keyUp is swallowed, whatever modifiers are held
        // by then.
        if !pressed, remappedMacKeys.remove(event.keyCode) != nil { return }
        if pressed, let chords = remapper.remap(macKeyCode: event.keyCode, flags: event.modifierFlags) {
            remappedMacKeys.insert(event.keyCode)
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] remap macKeyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16)) -> \(chords.map { "\($0.modifiers)+\($0.keycode)" })\n".data(using: .utf8)!)
            }
            for transition in keyboard.chordTransitions(chords) {
                deliverKey(transition, windowID: view.windowID, x: x, y: y)
            }
            return
        }
        // AppKit repeats a held key as more keyDowns with no keyUp between.
        // A client that didn't ask for DetectableAutoRepeat expects the
        // classic X shape instead - a release before every repeated press.
        if pressed, event.isARepeat, xkbClientFlags & X11Keymap.ClientFlag.detectableAutoRepeat == 0 {
            deliverKey(keyboard.key(keycode, pressed: false), windowID: view.windowID, x: x, y: y)
        }
        let transition = keyboard.key(keycode, pressed: pressed)
        if X11Trace.enabled {
            let keysym = X11KeymapProvider.shared.keymap.keysym(keycode: keycode, mods: transition.before.effectiveMods)
            FileHandle.standardError.write("[x11] keyEvent wid=\(view.windowID) pressed=\(pressed) macKeyCode=\(event.keyCode) keycode=\(keycode) keysym=0x\(String(keysym, radix: 16)) mods=0x\(String(transition.before.effectiveMods, radix: 16)) repeat=\(event.isARepeat) detectable=\(xkbClientFlags & 1) ts=\(currentX11Timestamp)\n".data(using: .utf8)!)
        }
        deliverKey(transition, windowID: view.windowID, x: x, y: y)
    }

    /// A modifier key on its own - AppKit reports those only through
    /// `flagsChanged`, never `keyDown`/`keyUp`.
    func modifierFlagsChanged(_ event: NSEvent, in view: X11CanvasView) {
        guard !inputIsFrozen else { return }
        guard let keycode = X11KeyCodes.keycode(forMac: event.keyCode) else { return } // Fn has no X11 key
        let point = view.convert(event.locationInWindow, from: nil)
        let x = Int16(clamping: Int(point.x)), y = Int16(clamping: Int(point.y))
        for transition in X11KeyboardState.shared.flagsChanged(keycode: keycode, rawFlags: event.modifierFlags.rawValue) {
            if X11Trace.enabled {
                FileHandle.standardError.write("[x11] modifier wid=\(view.windowID) keycode=\(transition.keycode) pressed=\(transition.pressed) mods=0x\(String(transition.before.effectiveMods, radix: 16))->0x\(String(transition.after.effectiveMods, radix: 16))\n".data(using: .utf8)!)
            }
            deliverKey(transition, windowID: view.windowID, x: x, y: y)
        }
    }

    /// One key transition to the client: the key event - XI2 or core,
    /// never both (see `xi2TakesPrecedence`) - carrying the modifier state
    /// from before it, then `XkbStateNotify` if the modifiers changed.
    private func deliverKey(_ transition: X11KeyboardState.Transition, windowID: UInt32, x: Int16, y: Int16) {
        guard var record = state.window(windowID) else { return }
        let pressed = transition.pressed
        let xiEvtype = pressed ? XIEventType.keyPress : XIEventType.keyRelease
        let coreMask: UInt32 = pressed ? 0x0000_0001 : 0x0000_0002 // KeyPressMask / KeyReleaseMask
        // The view that took the click can be a child that selects no key
        // events (Firefox draws into child windows under its toplevel). X11
        // propagates the key up to the first ancestor that selects it; this
        // used to drop it, so Firefox was untypable while GTK apps and
        // Chromium - one X window each - were fine.
        var windowID = windowID, x = x, y = y
        while !xi2TakesPrecedence(record, evtype: xiEvtype), record.eventMask & coreMask == 0 {
            guard !record.isTopLevel, let parent = state.window(record.parent) else { break }
            x = x &+ Int16(clamping: Int(record.frame.origin.x))
            y = y &+ Int16(clamping: Int(record.frame.origin.y))
            record = parent
            windowID = parent.id
        }
        if xi2TakesPrecedence(record, evtype: xiEvtype) {
            sendXIDeviceEvent(evtype: xiEvtype, detail: UInt32(transition.keycode), deviceid: XIDeviceUse.coreKeyboardID,
                              windowID: windowID, x: x, y: y, mods: transition.before)
        } else if record.eventMask & coreMask != 0 {
            sendPointerEvent(code: pressed ? 2 : 3, detail: transition.keycode, windowID: windowID, x: x, y: y,
                             state: UInt16(transition.before.effectiveMods) | Self.x11ButtonMask(pressedButtons))
        }
        sendXkbStateNotify(transition)
    }

    /// Losing key status: release everything held. After this the Mac
    /// delivers the key-ups to some other app, and a client that never sees
    /// a key go up treats its next press as auto-repeat, or keeps Command
    /// "held" and turns every later keystroke into a shortcut.
    private func releaseHeldKeys(windowID: UInt32) {
        for transition in X11KeyboardState.shared.releaseAll() {
            deliverKey(transition, windowID: windowID, x: 0, y: 0)
        }
    }

    /// Gaining key status: bring the modifier state up to date without
    /// inventing key presses - the keys went down while another app had
    /// focus. The client learns the state from `XkbStateNotify` and from
    /// the `state` of the next event.
    private func syncModifiersOnFocus() {
        for transition in X11KeyboardState.shared.resync(rawFlags: NSEvent.modifierFlags.rawValue) {
            sendXkbStateNotify(transition)
        }
    }

    /// Button1Mask (0x100) through Button5Mask (0x1000) - the `state`
    /// field's button-down bits, per the core protocol's `KeyButMask`
    /// layout. See `mouseButton`'s doc comment for why `pressedButtons`
    /// (this connection's one-per-connection set, matching the rest of
    /// this file's "single client, no real contention" simplifications)
    /// needs to feed into `state` at all.
    private static func x11ButtonMask(_ buttons: Set<UInt8>) -> UInt16 {
        var mask: UInt16 = 0
        for button in buttons where (1...5).contains(button) {
            mask |= UInt16(0x0080) << UInt16(button)
        }
        return mask
    }

    /// The 4-byte XI2 button bitmask (`buttons_len` = 1): bit N of the byte
    /// array is button N, as xorg's `SetBit(ptr, i)` writes it. It's a byte
    /// array, so it doesn't depend on the connection's byte order. Buttons
    /// above 31 don't fit and are left out.
    static func xi2ButtonMask(_ buttons: Set<UInt8>) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: 4)
        for button in buttons where button < 32 {
            mask[Int(button) / 8] |= UInt8(1) << (button % 8)
        }
        return mask
    }
}
