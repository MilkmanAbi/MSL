import Foundation

/// The state of the one physical keyboard, shared by every connection in
/// this process.
///
/// Per process, not per connection: modifier state belongs to the
/// keyboard, and Krita alone opens five connections. The old code kept a
/// `lastModifierFlags` per connection, so a Shift pressed while one of an
/// app's windows had focus was never pressed as far as its other
/// connections were concerned.
///
/// Every change comes back as a `Transition` carrying the state on both
/// sides of it, because X11 needs both: a `KeyPress`'s `state` field is the
/// modifier state *before* the key (pressing Shift reports Shift not yet
/// down), while `XkbStateNotify` reports the state *after*.
final class X11KeyboardState: @unchecked Sendable {
    static let shared = X11KeyboardState()

    struct Transition: Equatable {
        let keycode: UInt8
        let pressed: Bool
        let before: X11KeyboardSnapshot
        let after: X11KeyboardSnapshot
    }

    private let lock = NSLock()
    private var tracker = X11ModifierTracker()
    /// Non-modifier keys currently down - so losing key status can release
    /// them. A client that never sees a key go up treats the next press as
    /// auto-repeat, or keeps scrolling, or keeps a game character running.
    private var heldKeys: Set<UInt8> = []
    /// Modifier keys Linux apps must not see, though they are still
    /// tracked: the Command keys while the shortcut remapper owns them.
    private var hidden: Set<UInt8> = []

    /// Read outside the lock: building the keymap may hop to the main
    /// thread, and the main thread takes this lock too.
    private func modMap() -> [UInt8: UInt8] {
        X11KeymapProvider.shared.keymap.modMap
    }

    /// Callers hold `lock`.
    private func visibleMap(_ map: [UInt8: UInt8]) -> [UInt8: UInt8] {
        hidden.isEmpty ? map : map.filter { !hidden.contains($0.key) }
    }

    var current: X11KeyboardSnapshot {
        let map = modMap()
        lock.lock(); defer { lock.unlock() }
        return tracker.snapshot(modMap: visibleMap(map))
    }

    func setHiddenModifiers(_ keycodes: Set<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        hidden = keycodes
    }

    func flagsChanged(keycode: UInt8, rawFlags: UInt) -> [Transition] {
        mutate { $0.flagsChanged(keycode: keycode, rawFlags: rawFlags) }
    }

    func resync(rawFlags: UInt) -> [Transition] {
        mutate { $0.resync(rawFlags: rawFlags) }
    }

    /// Releases everything - held modifiers first, then ordinary keys.
    func releaseAll() -> [Transition] {
        var transitions = mutate { $0.releaseAll() }
        let map = modMap()
        lock.lock()
        let snapshot = tracker.snapshot(modMap: visibleMap(map))
        let keys = heldKeys.sorted()
        heldKeys.removeAll()
        lock.unlock()
        transitions += keys.map { Transition(keycode: $0, pressed: false, before: snapshot, after: snapshot) }
        return transitions
    }

    /// An ordinary (non-modifier) key going down or up.
    func key(_ keycode: UInt8, pressed: Bool) -> Transition {
        let map = modMap()
        lock.lock(); defer { lock.unlock() }
        if pressed { heldKeys.insert(keycode) } else { heldKeys.remove(keycode) }
        let snapshot = tracker.snapshot(modMap: visibleMap(map))
        return Transition(keycode: keycode, pressed: pressed, before: snapshot, after: snapshot)
    }

    /// The transitions that send `chords` from the remapper, starting from
    /// the modifiers Linux apps can currently see.
    func chordTransitions(_ chords: [X11KeyChord]) -> [Transition] {
        let map = modMap()
        lock.lock()
        let visible = visibleMap(map)
        let held = tracker.held.filter { visible[$0] != nil }
        let locked = tracker.capsLocked ? X11ModMask.lock : 0
        lock.unlock()
        return X11ShortcutRemapper.transitions(for: chords, visibleHeld: held, lockedMods: locked, modMap: map)
    }

    /// Replays the tracker's changes one at a time so each transition gets
    /// the state immediately before and after itself, not the batch's.
    /// Changes to hidden modifiers are tracked but not returned.
    private func mutate(_ body: (inout X11ModifierTracker) -> [X11ModifierTracker.Change]) -> [Transition] {
        let map = modMap()
        lock.lock(); defer { lock.unlock() }
        let visible = visibleMap(map)
        let old = tracker
        let changes = body(&tracker)
        var held = old.held
        var capsLocked = old.capsLocked
        func snapshot() -> X11KeyboardSnapshot {
            var base: UInt8 = 0
            for keycode in held { base |= visible[keycode] ?? 0 }
            return X11KeyboardSnapshot(baseMods: base, lockedMods: capsLocked ? X11ModMask.lock : 0)
        }
        return changes.compactMap { change in
            let before = snapshot()
            if change.keycode == X11KeyCodes.Modifier.capsLock {
                // The lock takes effect on the press, as on a PC keyboard.
                if change.pressed { capsLocked = tracker.capsLocked }
            } else if change.pressed {
                held.insert(change.keycode)
            } else {
                held.remove(change.keycode)
            }
            guard !hidden.contains(change.keycode) else { return nil }
            return Transition(keycode: change.keycode, pressed: change.pressed, before: before, after: snapshot())
        }
    }
}
