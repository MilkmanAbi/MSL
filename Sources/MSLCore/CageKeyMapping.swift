import Carbon.HIToolbox

/// Maps AppKit `NSEvent.keyCode` (a Mac virtual keycode) to a real Linux
/// evdev keycode, for `CageCanvasView` to feed `CageInputBridge.sendKey`/
/// `Guest/init/wayland-tests/cageinput.c`'s `zwp_virtual_keyboard_v1.key`.
///
/// This is a DIFFERENT problem from `X11Keyboard`'s `macKeyCode + 8` -
/// that scheme is `mslgd`'s own private, self-consistent numbering (its
/// own doc comment says so explicitly: "nothing requires them to match
/// real Linux/evdev numbering"), valid only because `mslgd` is also the
/// one answering `GetKeyboardMapping` with that same made-up scheme. A
/// REAL Wayland compositor's virtual-keyboard protocol expects REAL evdev
/// codes (`KEY_A` = 30, not `kVK_ANSI_A` = 0 or `macKeyCode + 8` = 8) -
/// two completely different vendor-assigned numbering systems with no
/// arithmetic relationship, so this needs its own explicit table, not a
/// reuse of `X11Keyboard`'s.
///
/// Deliberately incomplete - covers the common ANSI-US-layout keys needed
/// to type/navigate for Phase 4's smoke-test verification (letters,
/// digits, space/return/tab/backspace/escape, arrows), not a full
/// hardware-independent remap (that would need to go through the host's
/// active keyboard layout the way `X11Keyboard`'s `UCKeyTranslate` path
/// does for keysyms, which is out of scope for this pass). An unmapped
/// key is silently dropped, matching `X11Keyboard`'s own "outside the
/// populated range reports nothing" precedent.
enum CageKeyMapping {
    static func evdevKeycode(forMacKeyCode macKeyCode: UInt16) -> UInt32? {
        table[macKeyCode]
    }

    /// Mac virtual keycodes (`Carbon.HIToolbox`'s `kVK_*` constants) on
    /// the left, Linux evdev codes (`linux/input-event-codes.h`'s
    /// `KEY_*` constants, hand-transcribed since this project doesn't
    /// vendor that header host-side) on the right.
    private static let table: [UInt16: UInt32] = [
        UInt16(kVK_ANSI_A): 30, UInt16(kVK_ANSI_S): 31, UInt16(kVK_ANSI_D): 32,
        UInt16(kVK_ANSI_F): 33, UInt16(kVK_ANSI_H): 35, UInt16(kVK_ANSI_G): 34,
        UInt16(kVK_ANSI_Z): 44, UInt16(kVK_ANSI_X): 45, UInt16(kVK_ANSI_C): 46,
        UInt16(kVK_ANSI_V): 47, UInt16(kVK_ANSI_B): 48, UInt16(kVK_ANSI_Q): 16,
        UInt16(kVK_ANSI_W): 17, UInt16(kVK_ANSI_E): 18, UInt16(kVK_ANSI_R): 19,
        UInt16(kVK_ANSI_Y): 21, UInt16(kVK_ANSI_T): 20, UInt16(kVK_ANSI_1): 2,
        UInt16(kVK_ANSI_2): 3, UInt16(kVK_ANSI_3): 4, UInt16(kVK_ANSI_4): 5,
        UInt16(kVK_ANSI_6): 7, UInt16(kVK_ANSI_5): 6, UInt16(kVK_ANSI_Equal): 13,
        UInt16(kVK_ANSI_9): 10, UInt16(kVK_ANSI_7): 8, UInt16(kVK_ANSI_Minus): 12,
        UInt16(kVK_ANSI_8): 9, UInt16(kVK_ANSI_0): 11, UInt16(kVK_ANSI_RightBracket): 27,
        UInt16(kVK_ANSI_O): 24, UInt16(kVK_ANSI_U): 22, UInt16(kVK_ANSI_LeftBracket): 26,
        UInt16(kVK_ANSI_I): 23, UInt16(kVK_ANSI_P): 25, UInt16(kVK_Return): 28,
        UInt16(kVK_ANSI_L): 38, UInt16(kVK_ANSI_J): 36, UInt16(kVK_ANSI_Quote): 40,
        UInt16(kVK_ANSI_K): 37, UInt16(kVK_ANSI_Semicolon): 39, UInt16(kVK_ANSI_Backslash): 43,
        UInt16(kVK_ANSI_Comma): 51, UInt16(kVK_ANSI_Slash): 53, UInt16(kVK_ANSI_N): 49,
        UInt16(kVK_ANSI_M): 50, UInt16(kVK_ANSI_Period): 52, UInt16(kVK_Tab): 15,
        UInt16(kVK_Space): 57, UInt16(kVK_ANSI_Grave): 41, UInt16(kVK_Delete): 14,
        UInt16(kVK_Escape): 1,
        UInt16(kVK_LeftArrow): 105, UInt16(kVK_RightArrow): 106,
        UInt16(kVK_DownArrow): 108, UInt16(kVK_UpArrow): 103,
    ]
}
