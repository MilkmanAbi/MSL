import Foundation

/// The keycodes this server reports, and the XKB name of every one of them.
///
/// **Linux evdev numbering, not Mac virtual keycodes.** mslgd used to report
/// `NSEvent.keyCode + 8`, which put "a" at 8 and Escape at 61. The core
/// protocol allows any numbering as long as events and `GetKeyboardMapping`
/// agree, and for plain typing that was enough. It stops being enough the
/// moment anything reasons about *which physical key* was pressed rather
/// than which symbol it produced:
///
/// - libxkbcommon (every Qt app, and Krita's startup keymap compile) needs a
///   real XKB key name per keycode - `<AC01>`, `<LFSH>` - and a keymap with
///   no names fails outright ("failed to compile a keymap").
/// - Wine, SDL, Blender's GHOST and Electron's `KeyboardEvent.code` all carry
///   tables of evdev keycodes, because every X server on Linux uses them.
///
/// X11 keycode = evdev code + 8, exactly as xf86-input-evdev and
/// xkeyboard-config's `evdev` keycodes file define them.
enum X11KeyCodes {
    static let min: UInt8 = 8
    static let max: UInt8 = 255
    static var count: Int { Int(max) - Int(min) + 1 }

    /// `NSEvent.keyCode` (Carbon `kVK_*`) -> X11 keycode and XKB key name.
    static let macKeys: [UInt16: (keycode: UInt8, name: String)] = [
        // Letters and digits, by physical position (the names are positions
        // too - AC01 is "row C, key 1" whatever the layout prints on it).
        0x00: (38, "AC01"), 0x01: (39, "AC02"), 0x02: (40, "AC03"), 0x03: (41, "AC04"),
        0x04: (43, "AC06"), 0x05: (42, "AC05"), 0x06: (52, "AB01"), 0x07: (53, "AB02"),
        0x08: (54, "AB03"), 0x09: (55, "AB04"), 0x0B: (56, "AB05"), 0x0C: (24, "AD01"),
        0x0D: (25, "AD02"), 0x0E: (26, "AD03"), 0x0F: (27, "AD04"), 0x10: (29, "AD06"),
        0x11: (28, "AD05"), 0x12: (10, "AE01"), 0x13: (11, "AE02"), 0x14: (12, "AE03"),
        0x15: (13, "AE04"), 0x16: (15, "AE06"), 0x17: (14, "AE05"), 0x18: (21, "AE12"),
        0x19: (18, "AE09"), 0x1A: (16, "AE07"), 0x1B: (20, "AE11"), 0x1C: (17, "AE08"),
        0x1D: (19, "AE10"), 0x1E: (35, "AD12"), 0x1F: (32, "AD09"), 0x20: (30, "AD07"),
        0x21: (34, "AD11"), 0x22: (31, "AD08"), 0x23: (33, "AD10"), 0x25: (46, "AC09"),
        0x26: (44, "AC07"), 0x27: (48, "AC11"), 0x28: (45, "AC08"), 0x29: (47, "AC10"),
        0x2A: (51, "BKSL"), 0x2B: (59, "AB08"), 0x2C: (61, "AB10"), 0x2D: (57, "AB06"),
        0x2E: (58, "AB07"), 0x2F: (60, "AB09"), 0x32: (49, "TLDE"),
        // The extra key on ISO keyboards. Apple reports it as "section", the
        // PC world calls the same slot <LSGT>; the symbol still comes from
        // the Mac layout either way.
        0x0A: (94, "LSGT"),

        0x24: (36, "RTRN"), 0x30: (23, "TAB"), 0x31: (65, "SPCE"), 0x33: (22, "BKSP"),
        0x35: (9, "ESC"), 0x75: (119, "DELE"), 0x72: (118, "INS"), // Help sits where Insert does
        0x73: (110, "HOME"), 0x77: (115, "END"), 0x74: (112, "PGUP"), 0x79: (117, "PGDN"),
        0x7B: (113, "LEFT"), 0x7C: (114, "RGHT"), 0x7D: (116, "DOWN"), 0x7E: (111, "UP"),
        0x6E: (135, "COMP"),

        // Modifiers.
        0x38: (50, "LFSH"), 0x3C: (62, "RTSH"), 0x3B: (37, "LCTL"), 0x3E: (105, "RCTL"),
        0x3A: (64, "LALT"), 0x3D: (108, "RALT"), 0x37: (133, "LWIN"), 0x36: (134, "RWIN"),
        0x39: (66, "CAPS"),

        // Function keys.
        0x7A: (67, "FK01"), 0x78: (68, "FK02"), 0x63: (69, "FK03"), 0x76: (70, "FK04"),
        0x60: (71, "FK05"), 0x61: (72, "FK06"), 0x62: (73, "FK07"), 0x64: (74, "FK08"),
        0x65: (75, "FK09"), 0x6D: (76, "FK10"), 0x67: (95, "FK11"), 0x6F: (96, "FK12"),
        0x69: (191, "FK13"), 0x6B: (192, "FK14"), 0x71: (193, "FK15"), 0x6A: (194, "FK16"),
        0x40: (195, "FK17"), 0x4F: (196, "FK18"), 0x50: (197, "FK19"), 0x5A: (198, "FK20"),

        // Keypad. Clear sits on the Num Lock slot.
        0x52: (90, "KP0"), 0x53: (87, "KP1"), 0x54: (88, "KP2"), 0x55: (89, "KP3"),
        0x56: (83, "KP4"), 0x57: (84, "KP5"), 0x58: (85, "KP6"), 0x59: (79, "KP7"),
        0x5B: (80, "KP8"), 0x5C: (81, "KP9"), 0x41: (91, "KPDL"), 0x43: (63, "KPMU"),
        0x45: (86, "KPAD"), 0x4E: (82, "KPSU"), 0x4B: (106, "KPDV"), 0x4C: (104, "KPEN"),
        0x51: (125, "KPEQ"), 0x47: (77, "NMLK"), 0x5F: (129, "I129"),

        // Media keys (only reach an app when the F-row sends them as keys).
        0x4A: (121, "MUTE"), 0x49: (122, "VOL-"), 0x48: (123, "VOL+"),

        // JIS keyboards.
        0x5D: (132, "AE13"), 0x5E: (97, "AB11"), 0x66: (102, "MUHE"), 0x68: (101, "HKTG"),
    ]

    /// Keys a Mac keyboard doesn't have, reachable only through the shortcut
    /// remapper (Cmd+Shift+3 -> Print and so on). They still get real
    /// keycodes, names and keysyms, or clients would drop them as NoSymbol.
    enum Virtual {
        static let print: UInt8 = 107
        static let scrollLock: UInt8 = 78
        static let pause: UInt8 = 127
    }

    private static let virtualNames: [UInt8: String] = [
        Virtual.print: "PRSC", Virtual.scrollLock: "SCLK", Virtual.pause: "PAUS",
    ]

    private static let macByKeycode: [UInt8: UInt16] = {
        var table: [UInt8: UInt16] = [:]
        for (mac, entry) in macKeys { table[entry.keycode] = mac }
        return table
    }()

    private static let namesByKeycode: [UInt8: String] = {
        var table = virtualNames
        for entry in macKeys.values { table[entry.keycode] = entry.name }
        return table
    }()

    static func keycode(forMac macKeyCode: UInt16) -> UInt8? {
        macKeys[macKeyCode]?.keycode
    }

    static func macKeyCode(forKeycode keycode: UInt8) -> UInt16? {
        macByKeycode[keycode]
    }

    /// Every keycode in range has a name - xorg's evdev file names the
    /// unused slots `<Innn>`, and a keymap with gaps in its names is legal
    /// but makes `xkbcomp` output noisy. Always four bytes or fewer, the
    /// limit `XkbKeyNameRec` imposes.
    static func name(forKeycode keycode: UInt8) -> String {
        namesByKeycode[keycode] ?? "I\(keycode)"
    }

    /// The modifier keys, by keycode. Their levels never depend on the
    /// layout, and they are the keys that need actions and modmap entries.
    enum Modifier {
        static let leftShift: UInt8 = 50
        static let rightShift: UInt8 = 62
        static let leftControl: UInt8 = 37
        static let rightControl: UInt8 = 105
        static let leftOption: UInt8 = 64
        static let rightOption: UInt8 = 108
        static let leftCommand: UInt8 = 133
        static let rightCommand: UInt8 = 134
        static let capsLock: UInt8 = 66
    }
}
