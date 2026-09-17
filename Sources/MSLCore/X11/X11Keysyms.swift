import Foundation

/// Keysym values and the character -> keysym rules.
///
/// All values are the real `<X11/keysymdef.h>` / `XF86keysym.h` constants.
enum X11Keysym {
    static let noSymbol: UInt32 = 0

    static let backSpace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    /// Shift+Tab. The old table said 0xFE01, which is `ISO_Lock`, not
    /// `ISO_Left_Tab` - reverse tabbing only ever worked by accident.
    static let isoLeftTab: UInt32 = 0xFE20
    static let clear: UInt32 = 0xFF0B
    static let returnKey: UInt32 = 0xFF0D
    static let pause: UInt32 = 0xFF13
    static let scrollLock: UInt32 = 0xFF14
    static let escape: UInt32 = 0xFF1B
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let print: UInt32 = 0xFF61
    static let insert: UInt32 = 0xFF63
    static let menu: UInt32 = 0xFF67
    static let delete: UInt32 = 0xFFFF
    static let space: UInt32 = 0x0020

    static let shiftL: UInt32 = 0xFFE1
    static let shiftR: UInt32 = 0xFFE2
    static let controlL: UInt32 = 0xFFE3
    static let controlR: UInt32 = 0xFFE4
    static let capsLock: UInt32 = 0xFFE5
    static let altL: UInt32 = 0xFFE9
    static let altR: UInt32 = 0xFFEA
    static let superL: UInt32 = 0xFFEB
    static let superR: UInt32 = 0xFFEC
    /// AltGr. What a right Option key is by default: the key that reaches a
    /// layout's third and fourth levels (Option+e, Option+2 and so on).
    static let isoLevel3Shift: UInt32 = 0xFE03

    static let eisuToggle: UInt32 = 0xFF2F
    static let hiraganaKatakana: UInt32 = 0xFF27

    static let audioLowerVolume: UInt32 = 0x1008_FF11
    static let audioMute: UInt32 = 0x1008_FF12
    static let audioRaiseVolume: UInt32 = 0x1008_FF13

    static func function(_ n: Int) -> UInt32 { 0xFFBE + UInt32(n - 1) }

    /// Keysyms for keys whose meaning doesn't come from the layout, keyed by
    /// X11 keycode. The two Option keys are absent on purpose - what they
    /// are depends on `X11OptionKeyMode`.
    static let fixed: [UInt8: [UInt32]] = {
        var table: [UInt8: [UInt32]] = [
            9: [escape], 22: [backSpace], 23: [tab, isoLeftTab], 36: [returnKey], 65: [space],
            119: [delete], 118: [insert], 110: [home], 115: [end], 112: [pageUp], 117: [pageDown],
            113: [left], 114: [right], 116: [down], 111: [up], 135: [menu],
            50: [shiftL], 62: [shiftR], 37: [controlL], 105: [controlR],
            133: [superL], 134: [superR], 66: [capsLock],
            // Keypad: a Mac keypad has no Num Lock, so its keys are always
            // the numeric ones.
            90: [0xFFB0], 87: [0xFFB1], 88: [0xFFB2], 89: [0xFFB3], 83: [0xFFB4],
            84: [0xFFB5], 85: [0xFFB6], 79: [0xFFB7], 80: [0xFFB8], 81: [0xFFB9],
            91: [0xFFAE], 63: [0xFFAA], 86: [0xFFAB], 82: [0xFFAD], 106: [0xFFAF],
            104: [0xFF8D], 125: [0xFFBD], 77: [clear], 129: [0xFFAC],
            121: [audioMute], 122: [audioLowerVolume], 123: [audioRaiseVolume],
            102: [eisuToggle], 101: [hiraganaKatakana],
            X11KeyCodes.Virtual.print: [print],
            X11KeyCodes.Virtual.scrollLock: [scrollLock],
            X11KeyCodes.Virtual.pause: [pause],
        ]
        let functionKeycodes: [UInt8] = [67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 95, 96,
                                         191, 192, 193, 194, 195, 196, 197, 198]
        for (index, keycode) in functionKeycodes.enumerated() {
            table[keycode] = [function(index + 1)]
        }
        return table
    }()

    /// The keysym for text a key produces.
    ///
    /// Latin-1 keysyms are numerically the code point. Everything else uses
    /// the Unicode keysym range (`0x0100_0000 | codepoint`), which Xlib,
    /// libxkbcommon, GTK and Qt all understand. The old code answered
    /// NoSymbol for anything past U+00FF, so every Cyrillic, Greek, Hebrew
    /// or Arabic key typed nothing at all.
    static func forText(_ text: String) -> UInt32? {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        let value = scalar.value
        // Control characters are what non-printing keys translate to; those
        // keys get real keysyms from `fixed` instead.
        if value < 0x20 || value == 0x7F || (0x80..<0xA0).contains(value) { return nil }
        if value <= 0xFF { return value }
        return 0x0100_0000 | value
    }

    /// The code point a keysym stands for, if it stands for one - the inverse
    /// of `forText`, used to spot letter case pairs.
    static func scalar(for keysym: UInt32) -> Unicode.Scalar? {
        if (0x20...0x7E).contains(keysym) || (0xA0...0xFF).contains(keysym) {
            return Unicode.Scalar(keysym)
        }
        if keysym & 0xFF00_0000 == 0x0100_0000 {
            return Unicode.Scalar(keysym & 0x00FF_FFFF)
        }
        return nil
    }

    /// Dead keys, by the spacing accent a Mac layout reports for them.
    ///
    /// A dead key produces no text on its own, so there is nothing to derive
    /// a keysym from. What UCKeyTranslate does give back, once the dead key is
    /// followed by Space, is the spacing form of the accent - and every
    /// accent has exactly one `dead_*` keysym. Linux toolkits compose
    /// `dead_acute` + `e` into "é" themselves.
    static func deadKey(forSpacingAccent text: String) -> UInt32? {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x60: return 0xFE50 // ` dead_grave
        case 0xB4, 0x27: return 0xFE51 // ´ ' dead_acute
        case 0x5E, 0x2C6: return 0xFE52 // ^ ˆ dead_circumflex
        case 0x7E, 0x2DC: return 0xFE53 // ~ ˜ dead_tilde
        case 0xAF: return 0xFE54 // ¯ dead_macron
        case 0x2D8: return 0xFE55 // ˘ dead_breve
        case 0x2D9: return 0xFE56 // ˙ dead_abovedot
        case 0xA8, 0x22: return 0xFE57 // ¨ " dead_diaeresis
        case 0x2DA: return 0xFE58 // ˚ dead_abovering
        case 0x2DD: return 0xFE59 // ˝ dead_doubleacute
        case 0x2C7: return 0xFE5A // ˇ dead_caron
        case 0xB8: return 0xFE5B // ¸ dead_cedilla
        case 0x2DB: return 0xFE5C // ˛ dead_ogonek
        default: return nil
        }
    }

    /// Whether `lower`/`upper` are one letter in two cases - which decides
    /// whether Caps Lock should reach the key (`ALPHABETIC`) or not.
    static func isCasePair(_ lower: UInt32, _ upper: UInt32) -> Bool {
        guard lower != upper, let l = scalar(for: lower), let u = scalar(for: upper) else { return false }
        let ls = String(l), us = String(u)
        return ls.uppercased() == us && us.lowercased() == ls
    }
}
