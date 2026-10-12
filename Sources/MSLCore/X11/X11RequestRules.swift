import Foundation

/// What a core request must carry before its handler may run: a minimum
/// body length, and the resource ids it names.
///
/// Why this exists, found by the xhell suite (`Guest/x11-torture`): handlers
/// read their fields with `X11ByteReader`, which returns 0 past the end of
/// the body, so a request sent with no body at all ran as if every field
/// were 0. A 4-byte `DestroyWindow` became "destroy window 0", walked the
/// synthetic root's bookkeeping and recursed until the thread's stack
/// overflowed - one malformed request from any client killed the whole app
/// host. And a stale id - a window the client itself destroyed - was
/// silently accepted where every real server answers BadWindow, which is
/// exactly how a client's error trap learns the window is gone.
///
/// Policy on ids, deliberately narrower than a real server's: the error is
/// sent for id 0 (None never names a resource) and for ids in the client's
/// OWN range that do not exist. Ids from anyone else's range are let
/// through: each app runs in its own host here, so another app's windows
/// genuinely do not exist in this one even though they would on a real
/// server - and Xlib's default error handler exits the app. A handler met
/// with a foreign id keeps its old lenient behaviour.
enum X11RequestRules {
    enum Kind { case window, drawable, pixmap, gc, atom, newID }

    struct Rule {
        let minBody: Int
        let ids: [(Kind, Int)]   // resource kind, byte offset in the body
    }

    private static func r(_ minBody: Int, _ ids: (Kind, Int)...) -> Rule { Rule(minBody: minBody, ids: ids) }

    /// Core opcodes. Body sizes are the protocol's fixed request size minus
    /// the 4-byte header.
    static let core: [UInt8: Rule] = [
        1: r(28, (.newID, 0), (.window, 4)),          // CreateWindow
        2: r(8, (.window, 0)),                         // ChangeWindowAttributes
        3: r(4, (.window, 0)),                         // GetWindowAttributes
        4: r(4, (.window, 0)),                         // DestroyWindow
        5: r(4, (.window, 0)),                         // DestroySubwindows
        6: r(4, (.window, 0)),                         // ChangeSaveSet
        7: r(12, (.window, 0), (.window, 4)),          // ReparentWindow
        8: r(4, (.window, 0)),                         // MapWindow
        9: r(4, (.window, 0)),                         // MapSubwindows
        10: r(4, (.window, 0)),                        // UnmapWindow
        11: r(4, (.window, 0)),                        // UnmapSubwindows
        12: r(8, (.window, 0)),                        // ConfigureWindow
        13: r(4, (.window, 0)),                        // CirculateWindow
        14: r(4, (.drawable, 0)),                      // GetGeometry
        15: r(4, (.window, 0)),                        // QueryTree
        16: r(4),                                      // InternAtom
        17: r(4, (.atom, 0)),                          // GetAtomName
        18: r(20, (.window, 0)),                       // ChangeProperty
        19: r(8, (.window, 0)),                        // DeleteProperty
        20: r(20, (.window, 0)),                       // GetProperty
        21: r(4, (.window, 0)),                        // ListProperties
        22: r(12),                                     // SetSelectionOwner (owner may be None)
        23: r(4),                                      // GetSelectionOwner
        24: r(20, (.window, 0)),                       // ConvertSelection
        25: r(40),                                     // SendEvent (destination may be PointerWindow/InputFocus)
        26: r(20, (.window, 0)),                       // GrabPointer
        27: r(4),
        28: r(20, (.window, 0)),                       // GrabButton
        29: r(8, (.window, 0)),                        // UngrabButton
        30: r(12),
        31: r(12, (.window, 0)),                       // GrabKeyboard
        32: r(4),
        33: r(12, (.window, 0)),                       // GrabKey
        34: r(8, (.window, 0)),                        // UngrabKey
        35: r(4),
        38: r(4, (.window, 0)),                        // QueryPointer
        39: r(12), 40: r(12, (.window, 0), (.window, 4)), // TranslateCoordinates
        41: r(20), 42: r(8),
        45: r(8, (.newID, 0)),                         // OpenFont
        46: r(4), 47: r(4), 48: r(4), 49: r(4), 50: r(4), 51: r(4),
        53: r(12, (.newID, 0), (.drawable, 4)),        // CreatePixmap
        54: r(4, (.pixmap, 0)),                        // FreePixmap
        55: r(12, (.newID, 0), (.drawable, 4)),        // CreateGC
        56: r(8, (.gc, 0)),                            // ChangeGC
        57: r(12, (.gc, 0), (.gc, 4)),                 // CopyGC
        58: r(8, (.gc, 0)),                            // SetDashes
        59: r(8, (.gc, 0)),                            // SetClipRectangles
        60: r(4, (.gc, 0)),                            // FreeGC
        61: r(12, (.window, 0)),                       // ClearArea
        62: r(24, (.drawable, 0), (.drawable, 4), (.gc, 8)), // CopyArea
        63: r(28, (.drawable, 0), (.drawable, 4), (.gc, 8)), // CopyPlane
        64: r(8, (.drawable, 0), (.gc, 4)), 65: r(8, (.drawable, 0), (.gc, 4)),
        66: r(8, (.drawable, 0), (.gc, 4)), 67: r(8, (.drawable, 0), (.gc, 4)),
        68: r(8, (.drawable, 0), (.gc, 4)), 69: r(12, (.drawable, 0), (.gc, 4)),
        70: r(8, (.drawable, 0), (.gc, 4)), 71: r(8, (.drawable, 0), (.gc, 4)),
        72: r(20, (.drawable, 0), (.gc, 4)),           // PutImage
        73: r(16, (.drawable, 0)),                     // GetImage
        74: r(12, (.drawable, 0), (.gc, 4)), 75: r(12, (.drawable, 0), (.gc, 4)),
        76: r(12, (.drawable, 0), (.gc, 4)), 77: r(12, (.drawable, 0), (.gc, 4)),
        78: r(12, (.newID, 0), (.window, 4)),          // CreateColormap
        79: r(4), 80: r(8), 81: r(4), 82: r(4),
        83: r(4, (.window, 0)),                        // ListInstalledColormaps
        84: r(12), 85: r(8), 86: r(8), 87: r(12), 88: r(8), 89: r(4), 90: r(12),
        91: r(4), 92: r(8),
        93: r(28, (.newID, 0)), 94: r(28, (.newID, 0)), 95: r(4), 96: r(16),
        97: r(8), 98: r(4), 100: r(4), 101: r(4), 102: r(4), 105: r(8), 107: r(8),
        109: r(4), 113: r(4), 114: r(8),
    ]

    /// Opcodes the core protocol leaves unassigned.
    static func isUnassignedCore(_ opcode: UInt8) -> Bool {
        opcode == 0 || (120...126).contains(opcode)
    }
}
