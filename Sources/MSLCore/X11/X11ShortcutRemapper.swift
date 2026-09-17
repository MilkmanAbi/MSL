import AppKit

/// One key as a Linux app should receive it: the modifier keys to hold, in
/// press order, and the key itself.
struct X11KeyChord: Equatable {
    let keycode: UInt8
    let modifiers: [UInt8]
}

/// Mac shortcuts, translated for Linux apps. Experimental, every part off
/// by default - see `MSLExperimentalSettings`.
///
/// Pure: a Mac key and the modifiers held in, the chords to send out (or
/// `nil` for "deliver the key as it is"). Delivery - hiding the modifiers
/// the user is physically holding, pressing and releasing the ones the
/// chord needs - is `X11Connection.deliverChords`'s job.
///
/// A key maps to a *list* of chords because some Mac editing commands have
/// no single-key equivalent: Cmd+Delete ("delete to the start of the
/// line") is Shift+Home, then BackSpace.
struct X11ShortcutRemapper: Equatable {
    var shortcuts = false
    var textNavigation = false
    var screenshotKeys = false

    init(shortcuts: Bool = false, textNavigation: Bool = false, screenshotKeys: Bool = false) {
        self.shortcuts = shortcuts
        self.textNavigation = textNavigation
        self.screenshotKeys = screenshotKeys
    }

    init(_ settings: MSLExperimentalSettings) {
        self.init(shortcuts: settings.linuxShortcuts, textNavigation: settings.macTextNavigation,
                  screenshotKeys: settings.screenshotKeys)
    }

    var isActive: Bool { shortcuts || textNavigation || screenshotKeys }

    /// With shortcut remapping on, Command belongs to the remapper: Linux
    /// apps never see it go down as Super, or Cmd+C would reach them as
    /// Super+Ctrl+C and match nothing.
    var hidesCommand: Bool { shortcuts }

    private enum Mac {
        static let left: UInt16 = 0x7B, right: UInt16 = 0x7C, down: UInt16 = 0x7D, up: UInt16 = 0x7E
        static let backspace: UInt16 = 0x33, forwardDelete: UInt16 = 0x75
        static let three: UInt16 = 0x14, four: UInt16 = 0x15, five: UInt16 = 0x17
    }

    private enum Key {
        static let home: UInt8 = 110, end: UInt8 = 115, backspace: UInt8 = 22, delete: UInt8 = 119
    }

    func remap(macKeyCode: UInt16, flags: NSEvent.ModifierFlags) -> [X11KeyChord]? {
        guard isActive, let keycode = X11KeyCodes.keycode(forMac: macKeyCode) else { return nil }
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let m = X11KeyCodes.Modifier.self
        let keepShift: [UInt8] = shift ? [m.leftShift] : []

        if screenshotKeys, command, shift, !option, !control {
            switch macKeyCode {
            case Mac.three: return [X11KeyChord(keycode: X11KeyCodes.Virtual.print, modifiers: [])]
            case Mac.four: return [X11KeyChord(keycode: X11KeyCodes.Virtual.print, modifiers: [m.leftShift])]
            case Mac.five: return [X11KeyChord(keycode: X11KeyCodes.Virtual.print, modifiers: [m.leftOption])]
            default: break
            }
        }

        if textNavigation, command, !option, !control {
            switch macKeyCode {
            case Mac.left: return [X11KeyChord(keycode: Key.home, modifiers: keepShift)]
            case Mac.right: return [X11KeyChord(keycode: Key.end, modifiers: keepShift)]
            case Mac.up: return [X11KeyChord(keycode: Key.home, modifiers: [m.leftControl] + keepShift)]
            case Mac.down: return [X11KeyChord(keycode: Key.end, modifiers: [m.leftControl] + keepShift)]
            case Mac.backspace:
                return [X11KeyChord(keycode: Key.home, modifiers: [m.leftShift]), X11KeyChord(keycode: Key.backspace, modifiers: [])]
            case Mac.forwardDelete:
                return [X11KeyChord(keycode: Key.end, modifiers: [m.leftShift]), X11KeyChord(keycode: Key.delete, modifiers: [])]
            default: break
            }
        }

        if textNavigation, option, !command, !control {
            switch macKeyCode {
            case Mac.left, Mac.right, Mac.up, Mac.down:
                return [X11KeyChord(keycode: keycode, modifiers: [m.leftControl] + keepShift)]
            case Mac.backspace: return [X11KeyChord(keycode: Key.backspace, modifiers: [m.leftControl])]
            case Mac.forwardDelete: return [X11KeyChord(keycode: Key.delete, modifiers: [m.leftControl])]
            default: break
            }
        }

        if shortcuts, command {
            // Everything else with Command: the same key with Control, the
            // other modifiers kept - Cmd+Shift+Z is Ctrl+Shift+Z.
            var modifiers = [m.leftControl]
            if shift { modifiers.append(m.leftShift) }
            if option { modifiers.append(m.leftOption) }
            return [X11KeyChord(keycode: keycode, modifiers: modifiers)]
        }
        return nil
    }

    /// Key transitions that deliver `chords` to an app currently seeing the
    /// modifier keys in `visibleHeld` as down.
    ///
    /// For each chord: release the held modifiers it doesn't want (Option,
    /// for Option+Left -> Ctrl+Left), press the ones it does, press and
    /// release the key, then put everything back as the user is holding it.
    /// Setting the `state` bits alone would not do: `XkbStateNotify` and
    /// the XI2 modifier fields would still describe the physical keys, and
    /// Qt and GTK believe those over a key event's `state`.
    static func transitions(for chords: [X11KeyChord], visibleHeld: Set<UInt8>, lockedMods: UInt8,
                            modMap: [UInt8: UInt8]) -> [X11KeyboardState.Transition] {
        var held = visibleHeld
        var result: [X11KeyboardState.Transition] = []
        func snapshot() -> X11KeyboardSnapshot {
            X11KeyboardSnapshot(baseMods: held.reduce(0) { $0 | (modMap[$1] ?? 0) }, lockedMods: lockedMods)
        }
        func step(_ keycode: UInt8, pressed: Bool) {
            let before = snapshot()
            if modMap[keycode] != nil {
                if pressed { held.insert(keycode) } else { held.remove(keycode) }
            }
            result.append(.init(keycode: keycode, pressed: pressed, before: before, after: snapshot()))
        }
        for chord in chords {
            let released = held.subtracting(chord.modifiers).sorted()
            for keycode in released { step(keycode, pressed: false) }
            let added = chord.modifiers.filter { !held.contains($0) }
            for keycode in added { step(keycode, pressed: true) }
            step(chord.keycode, pressed: true)
            step(chord.keycode, pressed: false)
            for keycode in added.reversed() { step(keycode, pressed: false) }
            for keycode in released.reversed() { step(keycode, pressed: true) }
        }
        return result
    }
}
