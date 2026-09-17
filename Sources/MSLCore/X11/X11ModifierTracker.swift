import Foundation

/// Which modifier keys are physically down, left and right tracked apart.
///
/// **Why not just read `NSEvent.modifierFlags`.** AppKit's flags say
/// "Shift is down", never which Shift - and X11 has separate keycodes, and
/// may give them separate meanings (the right Option key is AltGr here,
/// the left one Alt). The same `modifierFlags` raw value does carry the
/// answer: its low 16 bits are IOKit's device-dependent `NX_DEVICE*KEYMASK`
/// bits, one per physical key.
///
/// **Why it is its own state machine.** The old code diffed flags against
/// the last event it saw, which silently breaks the moment an event is
/// missed - and events are missed routinely: a modifier released while
/// another app is frontmost, or while a menu has the keyboard, never
/// reaches this window. The app then believes Command is still held and
/// every later keystroke arrives as a shortcut. `resync` and `releaseAll`
/// are the two points where the truth is re-established.
struct X11ModifierTracker: Equatable {
    struct Change: Equatable {
        let keycode: UInt8
        let pressed: Bool
    }

    /// `NX_DEVICELCTLKEYMASK` and friends, from `IOLLEvent.h`.
    private static let deviceBits: [(keycode: UInt8, mask: UInt)] = [
        (X11KeyCodes.Modifier.leftControl, 0x0001), (X11KeyCodes.Modifier.leftShift, 0x0002),
        (X11KeyCodes.Modifier.rightShift, 0x0004), (X11KeyCodes.Modifier.leftCommand, 0x0008),
        (X11KeyCodes.Modifier.rightCommand, 0x0010), (X11KeyCodes.Modifier.leftOption, 0x0020),
        (X11KeyCodes.Modifier.rightOption, 0x0040), (X11KeyCodes.Modifier.rightControl, 0x2000),
    ]

    /// Device-independent flags (`NSEvent.ModifierFlags`), paired with the
    /// left and right keys that can set them. Synthetic events - and some
    /// third-party keyboards - set only these, so when neither side's
    /// device bit is present the left key is assumed.
    private static let genericFlags: [(flag: UInt, left: UInt8, right: UInt8)] = [
        (1 << 17, X11KeyCodes.Modifier.leftShift, X11KeyCodes.Modifier.rightShift),
        (1 << 18, X11KeyCodes.Modifier.leftControl, X11KeyCodes.Modifier.rightControl),
        (1 << 19, X11KeyCodes.Modifier.leftOption, X11KeyCodes.Modifier.rightOption),
        (1 << 20, X11KeyCodes.Modifier.leftCommand, X11KeyCodes.Modifier.rightCommand),
    ]

    static let capsLockFlag: UInt = 1 << 16

    private(set) var held: Set<UInt8> = []
    private(set) var capsLocked = false

    /// Whether `keycode` is down according to `rawFlags`.
    private static func isDown(_ keycode: UInt8, in rawFlags: UInt) -> Bool {
        guard let bit = deviceBits.first(where: { $0.keycode == keycode })?.mask else { return false }
        if rawFlags & bit != 0 { return true }
        guard let generic = genericFlags.first(where: { $0.left == keycode || $0.right == keycode }),
              rawFlags & generic.flag != 0 else { return false }
        let leftBit = deviceBits.first { $0.keycode == generic.left }!.mask
        let rightBit = deviceBits.first { $0.keycode == generic.right }!.mask
        let noDeviceBits = rawFlags & (leftBit | rightBit) == 0
        return noDeviceBits && keycode == generic.left
    }

    static func isModifier(_ keycode: UInt8) -> Bool {
        keycode == X11KeyCodes.Modifier.capsLock || deviceBits.contains { $0.keycode == keycode }
    }

    /// One `flagsChanged` event, for the key that changed.
    ///
    /// Caps Lock is a toggle on a Mac: AppKit reports the lock turning on or
    /// off, not the key going down and up. X11 expects a press and a
    /// release per toggle, with the Lock modifier *locked* in between.
    mutating func flagsChanged(keycode: UInt8, rawFlags: UInt) -> [Change] {
        if keycode == X11KeyCodes.Modifier.capsLock {
            let locked = rawFlags & Self.capsLockFlag != 0
            guard locked != capsLocked else { return [] }
            capsLocked = locked
            return [Change(keycode: keycode, pressed: true), Change(keycode: keycode, pressed: false)]
        }
        guard Self.deviceBits.contains(where: { $0.keycode == keycode }) else { return [] }
        let down = Self.isDown(keycode, in: rawFlags)
        guard down != held.contains(keycode) else { return [] }
        if down { held.insert(keycode) } else { held.remove(keycode) }
        return [Change(keycode: keycode, pressed: down)]
    }

    /// Brings the tracker in line with flags read at a point where events
    /// may have been missed - a window becoming key, or any key event whose
    /// flags disagree with what is recorded.
    mutating func resync(rawFlags: UInt) -> [Change] {
        var changes: [Change] = []
        for (keycode, _) in Self.deviceBits {
            let down = Self.isDown(keycode, in: rawFlags)
            guard down != held.contains(keycode) else { continue }
            if down { held.insert(keycode) } else { held.remove(keycode) }
            changes.append(Change(keycode: keycode, pressed: down))
        }
        let locked = rawFlags & Self.capsLockFlag != 0
        if locked != capsLocked {
            capsLocked = locked
            changes.append(Change(keycode: X11KeyCodes.Modifier.capsLock, pressed: true))
            changes.append(Change(keycode: X11KeyCodes.Modifier.capsLock, pressed: false))
        }
        return changes
    }

    /// Releases every held modifier - for a window losing key status, after
    /// which this app will not hear about the keys going up. Caps Lock stays
    /// as it is: it is a lock, not a held key.
    mutating func releaseAll() -> [Change] {
        let changes = held.sorted().map { Change(keycode: $0, pressed: false) }
        held.removeAll()
        return changes
    }

    func snapshot(modMap: [UInt8: UInt8], buttons: UInt16 = 0) -> X11KeyboardSnapshot {
        var base: UInt8 = 0
        for keycode in held { base |= modMap[keycode] ?? 0 }
        return X11KeyboardSnapshot(baseMods: base, lockedMods: capsLocked ? X11ModMask.lock : 0, buttons: buttons)
    }
}
