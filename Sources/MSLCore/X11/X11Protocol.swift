import Foundation

/// X11 core-protocol constants actually used by this skeleton - request
/// major-opcodes, error codes, and event codes, straight from the X Window
/// System Protocol spec (version 11, revision 0). Only the subset needed
/// for `X11Server`'s current handlers is listed; extend as more requests
/// get implemented rather than front-loading the full opcode table.
public enum X11Opcode {
    public static let createWindow: UInt8 = 1
    public static let changeWindowAttributes: UInt8 = 2
    public static let getWindowAttributes: UInt8 = 3
    public static let destroyWindow: UInt8 = 4
    public static let mapWindow: UInt8 = 8
    public static let unmapWindow: UInt8 = 10
    public static let configureWindow: UInt8 = 12
    public static let getGeometry: UInt8 = 14
    public static let queryTree: UInt8 = 15
    public static let internAtom: UInt8 = 16
    public static let getAtomName: UInt8 = 17
    public static let changeProperty: UInt8 = 18
    public static let deleteProperty: UInt8 = 19
    public static let getProperty: UInt8 = 20
    public static let setSelectionOwner: UInt8 = 22
    public static let getSelectionOwner: UInt8 = 23
    public static let convertSelection: UInt8 = 24
    public static let sendEvent: UInt8 = 25
    public static let queryPointer: UInt8 = 38
    public static let translateCoordinates: UInt8 = 40
    public static let getInputFocus: UInt8 = 43
    public static let queryKeymap: UInt8 = 44
    public static let openFont: UInt8 = 45
    public static let closeFont: UInt8 = 46
    public static let queryFont: UInt8 = 47
    public static let queryTextExtents: UInt8 = 48
    public static let listFonts: UInt8 = 49
    public static let polyText8: UInt8 = 74
    public static let imageText8: UInt8 = 76
    public static let createGC: UInt8 = 55
    public static let setClipRectangles: UInt8 = 59
    public static let mapSubwindows: UInt8 = 9
    public static let createPixmap: UInt8 = 53
    public static let freePixmap: UInt8 = 54
    public static let polyLine: UInt8 = 65
    public static let polySegment: UInt8 = 66
    /// Confirmed live via the Layer-0 conformance harness
    /// (`Guest/init/x11-tests/02_gc_primitives.c`): this was `67` before,
    /// which is actually `PolyRectangle` in the real X11 core protocol -
    /// `XDrawArc` requests (opcode 68) fell through completely unhandled
    /// as a result, and any real `PolyRectangle` request landing on the
    /// old (wrong) `67` would have been misparsed as arc data (12 bytes/
    /// entry) instead of rectangle data (8 bytes/entry).
    public static let polyRectangle: UInt8 = 67
    public static let polyArc: UInt8 = 68
    public static let fillPoly: UInt8 = 69
    public static let polyFillArc: UInt8 = 71
    public static let createCursor: UInt8 = 93
    public static let createGlyphCursor: UInt8 = 94
    public static let freeCursor: UInt8 = 95
    public static let recolorCursor: UInt8 = 96
    public static let allocColor: UInt8 = 84
    public static let allocNamedColor: UInt8 = 85
    public static let lookupColor: UInt8 = 92
    public static let queryColors: UInt8 = 91
    public static let createColormap: UInt8 = 78
    public static let freeColormap: UInt8 = 79
    public static let copyColormapAndFree: UInt8 = 80
    public static let installColormap: UInt8 = 81
    public static let uninstallColormap: UInt8 = 82
    public static let listInstalledColormaps: UInt8 = 83
    public static let grabButton: UInt8 = 28
    public static let ungrabButton: UInt8 = 29
    public static let grabPointer: UInt8 = 26
    public static let ungrabPointer: UInt8 = 27
    public static let grabServer: UInt8 = 36
    public static let ungrabServer: UInt8 = 37
    public static let grabKeyboard: UInt8 = 31
    public static let ungrabKeyboard: UInt8 = 32
    public static let grabKey: UInt8 = 33
    public static let ungrabKey: UInt8 = 34
    public static let polyPoint: UInt8 = 64
    public static let reparentWindow: UInt8 = 7
    public static let setInputFocus: UInt8 = 42
    public static let changeGC: UInt8 = 56
    public static let clearArea: UInt8 = 61
    public static let copyArea: UInt8 = 62
    public static let polyFillRectangle: UInt8 = 70
    public static let putImage: UInt8 = 72
    public static let getImage: UInt8 = 73
    public static let freeGC: UInt8 = 60
    public static let queryExtension: UInt8 = 98
    public static let listExtensions: UInt8 = 99
    public static let getKeyboardMapping: UInt8 = 101
    public static let getModifierMapping: UInt8 = 119
    public static let bell: UInt8 = 104
    public static let noOperation: UInt8 = 127

    /// The RENDER extension's server-chosen major opcode - reported back
    /// to any client that asks for it by name via `QueryExtension` (see
    /// `X11Connection.handleQueryExtension`), then used by that client on
    /// every subsequent `Render*` request as the request's own major
    /// opcode, with the specific `Render*` request type riding in the
    /// minor-opcode slot instead (X11's `detail` byte - already how this
    /// server reads it for core requests, no new framing needed). Not a
    /// spec-mandated value - real Xorg picks whatever's free at runtime;
    /// clients never hardcode it, only ever use whatever `QueryExtension`
    /// told them.
    public static let renderExtension: UInt8 = 150

    /// BIG-REQUESTS' server-chosen major opcode - see `X11Connection.
    /// handleBigReqEnable`'s doc comment for why this extension matters
    /// well beyond its own one request.
    public static let bigRequestsExtension: UInt8 = 151

    /// XInput2's server-chosen major opcode - see `X11Connection.
    /// handleXInputRequest`'s doc comment for why this extension turned
    /// out to matter for basic keyboard input, not just exotic
    /// multi-device setups.
    public static let xinputExtension: UInt8 = 152

    /// XKEYBOARD's server-chosen major opcode - see `X11Connection.
    /// handleXkbRequest`'s doc comment for the live-crash investigation
    /// (full `gdb` backtrace, not a guess) that found GDK's XI2 keyboard
    /// path needs this too, not just XInput2 alone.
    public static let xkbExtension: UInt8 = 153

    /// RANDR's server-chosen major opcode. Implemented because GDK's X11
    /// backend queries RANDR unconditionally at startup for monitor/DPI
    /// info - modern GTK3/4 (>= 3.22-ish) prefers the RandR 1.5
    /// `GetMonitors` request over the older output/crtc graph walk, and
    /// this server advertises 1.5 for exactly that reason (one request
    /// instead of `GetScreenResources` + `GetOutputInfo` + `GetCrtcInfo`
    /// per output). A single fixed "virtual monitor" matching this
    /// server's one real screen - no actual multi-monitor/hotplug
    /// modeling, same reasoning as XI2's two fixed "virtual core" devices.
    public static let randrExtension: UInt8 = 154

    /// XC-MISC's server-chosen major opcode - trivial extension (just
    /// resource-ID range bookkeeping), implemented mainly because `libX11`
    /// itself (not just toolkits) can call this when it thinks it's
    /// getting close to exhausting a connection's allocatable resource-ID
    /// range, and an unimplemented/erroring reply there is a worse failure
    /// mode than the few lines this takes to answer for real.
    public static let xcMiscExtension: UInt8 = 155

    /// SHAPE's server-chosen major opcode - real GTK/Qt popups, tooltips,
    /// and (less commonly) app icons use non-rectangular window shapes via
    /// this extension (`gtk_widget_shape_combine_region` and its Qt
    /// equivalents). This server answers every SHAPE request for real
    /// protocol correctness (no hangs/errors) and stores the requested
    /// shape region per-window, but does not yet visually clip a window
    /// to a non-rectangular shape - see `handleShapeRequest`'s doc
    /// comment for the concrete follow-up that would close that gap.
    public static let shapeExtension: UInt8 = 156
}

/// Minor (request) opcodes within the XInput2 extension (see `X11Opcode.
/// xinputExtension`'s doc comment) - real values from `<X11/extensions/
/// XI2proto.h>` (`X_XIQueryVersion` etc.), NOT made up: a client that
/// happens to hardcode them (none should, everyone goes through
/// `QueryExtension` for the major opcode, but the MINOR numbers here are
/// spec-fixed either way) needs the real ones.
public enum XIOpcode {
    /// The OLD XInput 1.x extension's `GetExtensionVersion` (minor
    /// opcode 1 - a completely different, decade-older numbering scheme
    /// than XI2's own minors below, since XInput 1.x and 2.x share the
    /// SAME extension name/major-opcode slot ("XInputExtension") for
    /// backward compatibility). Confirmed live: `libXi`'s real XI2
    /// initialization path (`_XiGetExtensionVersionRequest`, called
    /// internally by `XIQueryVersion` itself, not something a caller
    /// invokes directly) sends THIS request first, before ever sending
    /// an actual `X_XIQueryVersion` - a from-scratch server that only
    /// implements the real XI2 minors and ignores/errors this one never
    /// gets a working XI2 handshake at all, no matter how correct the
    /// rest of the implementation is.
    public static let getExtensionVersion: UInt8 = 1
    public static let queryPointer: UInt8 = 40
    public static let changeCursor: UInt8 = 42
    public static let getClientPointer: UInt8 = 45
    public static let selectEvents: UInt8 = 46
    public static let queryVersion: UInt8 = 47
    public static let queryDevice: UInt8 = 48
    public static let grabDevice: UInt8 = 51
    public static let ungrabDevice: UInt8 = 52
    public static let getProperty: UInt8 = 59
    public static let getSelectedEvents: UInt8 = 60
}

/// XI2 event-type numbers (the GenericEvent payload's own `evtype` field,
/// NOT an X11 core event code - GenericEvent itself is always core event
/// type 35 regardless of which XI2 event this is). Values from `<X11/
/// extensions/XI2.h>`. A client's `XISelectEvents` mask uses `1 <<
/// evtype` per event type it wants - `X11State.WindowRecord.xiEventMask`
/// stores exactly that bitmask, so `(1 << XIEventType.keyPress) &
/// window.xiEventMask != 0` is the "did they ask for this" check
/// throughout `X11Connection`'s XI2 event-sending code.
public enum XIEventType {
    public static let deviceChanged: UInt16 = 1
    public static let keyPress: UInt16 = 2
    public static let keyRelease: UInt16 = 3
    public static let buttonPress: UInt16 = 4
    public static let buttonRelease: UInt16 = 5
    public static let motion: UInt16 = 6
    public static let enter: UInt16 = 7
    public static let leave: UInt16 = 8
    /// Real values from `<X11/extensions/XI2.h>`. These two were MISSING
    /// (the enum jumped 8 -> 11), so no XI2 focus event was ever sent -
    /// see `X11Connection.sendXIFocusEvent`'s doc comment for why that
    /// silently broke keyboard input for every GTK3/XI2 client.
    public static let focusIn: UInt16 = 9
    public static let focusOut: UInt16 = 10
    public static let hierarchyChanged: UInt16 = 11
    /// `XI_RawMotion`. xeyes selects it on the root window to follow the
    /// pointer anywhere on screen; see `X11PointerMonitor`.
    public static let rawMotion: UInt16 = 17
}

/// XI2 device-use values (`xXIDeviceInfo.use` / `xXIHierarchyInfo.use`).
/// Besides the two REQUIRED "virtual core" master devices, every real X
/// server also always reports a pair of XTEST slave devices (present on
/// every X install regardless of real hardware, used by `XTest` fake-
/// input calls) attached to those masters - GDK's own XI2 setup expects
/// to find at least one slave per master to size its per-device valuator/
/// axis tables from (see `handleXIQueryDevice`'s doc comment: master-only
/// devices are not enough, confirmed live via a GDK assertion). Device
/// IDs (2=pointer, 3=keyboard) match a real X server's core protocol
/// reservation for "the" pointer/keyboard, in case any client hardcodes a
/// comparison against those (most shouldn't, but costs nothing to match).
public enum XIDeviceUse {
    public static let masterPointer: UInt16 = 1
    public static let masterKeyboard: UInt16 = 2
    public static let slavePointer: UInt16 = 3
    public static let slaveKeyboard: UInt16 = 4
    public static let corePointerID: UInt16 = 2
    public static let coreKeyboardID: UInt16 = 3
    public static let xtestPointerID: UInt16 = 4
    public static let xtestKeyboardID: UInt16 = 5
}

/// Minor (request) opcodes within the XKEYBOARD extension - real values
/// from `xkb.xml` (the XCB protocol description xorgproto itself is
/// generated from), not made up.
public enum XKBOpcode {
    public static let useExtension: UInt8 = 0
    public static let selectEvents: UInt8 = 1
    public static let bell: UInt8 = 3
    public static let getState: UInt8 = 4
    public static let latchLockState: UInt8 = 5
    public static let getControls: UInt8 = 6
    public static let setControls: UInt8 = 7
    public static let getMap: UInt8 = 8
    public static let setMap: UInt8 = 9
    public static let getCompatMap: UInt8 = 10
    public static let setCompatMap: UInt8 = 11
    public static let getIndicatorState: UInt8 = 12
    public static let getIndicatorMap: UInt8 = 13
    public static let setIndicatorMap: UInt8 = 14
    public static let setNamedIndicator: UInt8 = 16
    public static let getNames: UInt8 = 17
    public static let setNames: UInt8 = 18
    public static let perClientFlags: UInt8 = 21
    public static let getDeviceInfo: UInt8 = 24
    public static let setDeviceInfo: UInt8 = 25
    public static let setDebuggingFlags: UInt8 = 101
}

/// `MapPart` mask bits (`GetMap`'s `present`/`full`/`partial` fields) -
/// only the one this server actually ever reports (`modifierMap`) is
/// listed; real values from `<X11/extensions/XKB.h>`.
public enum XKBMapPart {
    public static let keyTypes: UInt16 = 0x01
    public static let keySyms: UInt16 = 0x02
    public static let modifierMap: UInt16 = 0x04
}

/// `NamesMask` bits (`GetNames`/`SetNames`' `which` field) - real values
/// from `<X11/extensions/XKB.h>`. Only `keyTypeNames` is used
/// (`handleXkbGetNames`) - see that function's doc comment for why.
public enum XKBNamesMask {
    public static let keyTypeNames: UInt32 = 1 << 6
}

/// `XkbStateNotify`'s own event sub-type (the `xkbType` byte inside the
/// XKB event's shared header - distinct from the CORE event type, which
/// is `XKBEventBase.eventBase + XKBEventBase.state` for every XKB event
/// regardless of which one it is) and its `XkbSelectEvents` mask bit -
/// real values confirmed against the actual `<X11/extensions/XKB.h>`
/// installed on this machine (`/opt/homebrew/include/X11/extensions/
/// XKB.h`), not a paraphrase.
public enum XKBEventCode {
    public static let stateNotify: UInt8 = 2
    public static let stateNotifyMask: UInt16 = 1 << 2
    /// The CORE event-type number every XKB event (of any `xkbType`)
    /// rides - this server's own arbitrary-but-fixed choice, echoed
    /// back as `first-event` in `handleQueryExtension`'s `"XKEYBOARD"`
    /// branch so it's the SAME value on both the advertising and the
    /// sending side (a client computes "is this an XKB event" as
    /// `event.type == first_event`, using whatever `QueryExtension`
    /// told it - this has to match, not be independently re-guessed).
    public static let eventBase: UInt8 = 92
}

/// Event/error bases advertised by `QueryExtension` for the extensions
/// whose client libraries install wire converters over a whole BLOCK of
/// codes starting at the base. A base of 0 is not "none": libXi used to
/// get `first-event=0` and registered its 17 XInput-1 converters over
/// core codes 0-16, so every Expose/KeyPress/ButtonPress reaching a
/// libXi client (GTK, Qt, Xt apps like xeyes) was mangled - xeyes got
/// `Expose window=0` and never drew. Blocks must sit above the core
/// range (0-35) and never overlap each other.
public enum X11ExtensionBase {
    /// SHAPE: 1 event (`ShapeNotify`).
    public static let shapeFirstEvent: UInt8 = 64
    public static let shapeEventCount = 1
    /// XInputExtension: `IEVENTS` = 17 (codes 66-82), `IERRORS` = 5
    /// (XIproto.h). XI2 events ride core `GenericEvent` (35) and are
    /// unaffected by this base.
    public static let xinputFirstEvent: UInt8 = 66
    public static let xinputEventCount = 17
    public static let xinputFirstError: UInt8 = 129
    public static let xinputErrorCount = 5
    /// XKEYBOARD: `XkbNumberEvents` = 1.
    public static let xkbEventCount = 1
}

/// `xkbStateNotify`'s own `changed`-field bits (which parts of state
/// actually changed) - only the ones this server ever sets. Real values
/// from `<X11/extensions/XKB.h>`.
public enum XKBStateChange {
    public static let modifierState: UInt16 = 1 << 0
    public static let modifierBase: UInt16 = 1 << 1
    public static let modifierLatch: UInt16 = 1 << 2
    public static let modifierLock: UInt16 = 1 << 3
    public static let groupState: UInt16 = 1 << 4
}

/// Minor opcodes within the RENDER extension (see `X11Opcode.
/// renderExtension`'s doc comment) - a small, deliberately incomplete
/// subset: enough for the common "solid color composited through an A8
/// coverage mask" pattern GTK/cairo lean on constantly for anti-aliased
/// text and shapes, plus a plain image composite/fill, plus `trapezoids`
/// (see `X11Connection.handleRenderTrapezoids`'s doc comment - cairo's
/// actual anti-aliased-fill primitive for anything non-rectangular).
/// Gradients, glyph sets, and picture transforms still aren't implemented.
public enum X11RenderOpcode {
    public static let queryVersion: UInt8 = 0
    public static let queryPictFormats: UInt8 = 1
    public static let createPicture: UInt8 = 4
    public static let changePicture: UInt8 = 5
    public static let setPictureClipRectangles: UInt8 = 6
    public static let freePicture: UInt8 = 7
    public static let composite: UInt8 = 8
    public static let trapezoids: UInt8 = 10
    public static let createGlyphSet: UInt8 = 17
    public static let freeGlyphSet: UInt8 = 19
    public static let addGlyphs: UInt8 = 20
    public static let compositeGlyphs8: UInt8 = 23
    public static let compositeGlyphs16: UInt8 = 24
    public static let compositeGlyphs32: UInt8 = 25
    public static let fillRectangles: UInt8 = 26
    public static let createSolidFill: UInt8 = 33
    public static let createLinearGradient: UInt8 = 34
    public static let setPictureTransform: UInt8 = 28
    public static let setPictureFilter: UInt8 = 30
}

/// Error codes (the second byte of a 32-byte Error response).
public enum X11ErrorCode {
    public static let request: UInt8 = 1
    public static let value: UInt8 = 2
    public static let window: UInt8 = 3
    public static let pixmap: UInt8 = 4
    public static let atom: UInt8 = 5
    public static let cursor: UInt8 = 6
    public static let font: UInt8 = 7
    public static let match: UInt8 = 8
    public static let drawable: UInt8 = 9
    public static let access: UInt8 = 10
    public static let alloc: UInt8 = 11
    public static let colormap: UInt8 = 12
    public static let gContext: UInt8 = 13
    public static let idChoice: UInt8 = 14
    public static let name: UInt8 = 15
    public static let length: UInt8 = 16
    public static let implementation: UInt8 = 17
}

/// Minor (request) opcodes within RANDR (see `X11Opcode.randrExtension`'s
/// doc comment) - real values from `<X11/extensions/randr.h>`. Only the
/// subset a typical GDK/Qt startup handshake actually sends against a
/// single, non-hotpluggable virtual screen.
public enum RandRRequest {
    public static let queryVersion: UInt8 = 0
    public static let selectInput: UInt8 = 4
    public static let getScreenSizeRange: UInt8 = 6
    public static let getScreenResources: UInt8 = 8
    public static let getOutputInfo: UInt8 = 9
    public static let getCrtcInfo: UInt8 = 20
    public static let getScreenResourcesCurrent: UInt8 = 25
    public static let getOutputPrimary: UInt8 = 31
    public static let getMonitors: UInt8 = 42
}

/// RANDR's `connection` byte (`xRRGetOutputInfoReply`) - real values from
/// `<X11/extensions/randr.h>`; this server's one output always reports
/// `connected`.
public enum RandROutputConnection {
    public static let connected: UInt8 = 0
    public static let disconnected: UInt8 = 1
    public static let unknown: UInt8 = 2
}

/// Minor (request) opcodes within XC-MISC (see `X11Opcode.
/// xcMiscExtension`'s doc comment) - real values from `<X11/extensions/
/// xcmiscproto.h>`. All three of this tiny extension's requests.
public enum XCMiscRequest {
    public static let getVersion: UInt8 = 0
    public static let getXIDRange: UInt8 = 1
    public static let getXIDList: UInt8 = 2
}

/// Minor (request) opcodes within SHAPE (see `X11Opcode.shapeExtension`'s
/// doc comment) - real values from `<X11/extensions/shapeproto.h>`/
/// `shapeconst.h`. Only the ones a real client (GTK's shape-combine-region
/// path, or a client just probing for the extension) actually sends.
public enum ShapeRequest {
    public static let queryVersion: UInt8 = 0
    public static let rectangles: UInt8 = 1
    public static let mask: UInt8 = 2
    public static let combine: UInt8 = 3
    public static let offset: UInt8 = 4
    public static let queryExtents: UInt8 = 5
    public static let selectInput: UInt8 = 6
    public static let inputSelected: UInt8 = 7
    public static let getRectangles: UInt8 = 8
}

/// SHAPE's `kind` byte (which of a window's THREE independent shape
/// regions a request targets) - real values from `shapeconst.h`. This
/// server only actually tracks `bounding` (the one that affects a
/// window's visible/paintable area); `clip` (child-clipping) and `input`
/// (pointer hit-testing) are accepted and stored per protocol but not yet
/// enforced - see `handleShapeRequest`'s doc comment.
public enum ShapeKind {
    public static let bounding: UInt8 = 0
    public static let clip: UInt8 = 1
    public static let input: UInt8 = 2
}
