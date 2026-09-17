import AppKit
import XCTest
@testable import MSLCore

final class X11ShortcutRemapperTests: XCTestCase {
    private let m = X11KeyCodes.Modifier.self
    private let all = X11ShortcutRemapper(shortcuts: true, textNavigation: true, screenshotKeys: true)

    private var modMap: [UInt8: UInt8] {
        [m.leftShift: X11ModMask.shift, m.rightShift: X11ModMask.shift, m.leftControl: X11ModMask.control,
         m.leftOption: X11ModMask.mod1, m.leftCommand: X11ModMask.mod4, m.rightCommand: X11ModMask.mod4]
    }

    func testEverythingIsOffByDefault() {
        let remapper = X11ShortcutRemapper(MSLExperimentalSettings())
        XCTAssertFalse(remapper.isActive)
        XCTAssertNil(remapper.remap(macKeyCode: 0x08, flags: [.command]))
    }

    func testCommandShortcutsBecomeControl() {
        let remapper = X11ShortcutRemapper(shortcuts: true)
        XCTAssertTrue(remapper.hidesCommand)
        // Cmd+C -> Ctrl+C (keycode 54)
        XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: [.command]), [X11KeyChord(keycode: 54, modifiers: [m.leftControl])])
        // Cmd+Shift+Z keeps Shift.
        XCTAssertEqual(remapper.remap(macKeyCode: 0x06, flags: [.command, .shift]), [X11KeyChord(keycode: 52, modifiers: [m.leftControl, m.leftShift])])
        // Keys without Command are untouched.
        XCTAssertNil(remapper.remap(macKeyCode: 0x08, flags: [.control]))
        XCTAssertNil(remapper.remap(macKeyCode: 0x08, flags: []))
    }

    func testTextNavigationOnlyWhenEnabled() {
        XCTAssertNil(X11ShortcutRemapper(shortcuts: true).remap(macKeyCode: 0x7B, flags: [.option]))
        let nav = X11ShortcutRemapper(textNavigation: true)
        XCTAssertFalse(nav.hidesCommand)
        XCTAssertEqual(nav.remap(macKeyCode: 0x7B, flags: [.command]), [X11KeyChord(keycode: 110, modifiers: [])]) // Home
        XCTAssertEqual(nav.remap(macKeyCode: 0x7C, flags: [.command, .shift]), [X11KeyChord(keycode: 115, modifiers: [m.leftShift])]) // Shift+End
        XCTAssertEqual(nav.remap(macKeyCode: 0x7E, flags: [.command]), [X11KeyChord(keycode: 110, modifiers: [m.leftControl])]) // Ctrl+Home
        XCTAssertEqual(nav.remap(macKeyCode: 0x7B, flags: [.option]), [X11KeyChord(keycode: 113, modifiers: [m.leftControl])]) // Ctrl+Left
        XCTAssertEqual(nav.remap(macKeyCode: 0x33, flags: [.option]), [X11KeyChord(keycode: 22, modifiers: [m.leftControl])]) // Ctrl+BackSpace
        XCTAssertEqual(nav.remap(macKeyCode: 0x33, flags: [.command]),
                       [X11KeyChord(keycode: 110, modifiers: [m.leftShift]), X11KeyChord(keycode: 22, modifiers: [])])
        // A plain Cmd+letter is not text navigation.
        XCTAssertNil(nav.remap(macKeyCode: 0x08, flags: [.command]))
    }

    func testScreenshotKeys() {
        XCTAssertEqual(all.remap(macKeyCode: 0x14, flags: [.command, .shift]), [X11KeyChord(keycode: X11KeyCodes.Virtual.print, modifiers: [])])
        XCTAssertEqual(all.remap(macKeyCode: 0x15, flags: [.command, .shift]), [X11KeyChord(keycode: X11KeyCodes.Virtual.print, modifiers: [m.leftShift])])
        // Off: Cmd+Shift+3 is just Ctrl+Shift+3 under shortcut remapping.
        XCTAssertEqual(X11ShortcutRemapper(shortcuts: true).remap(macKeyCode: 0x14, flags: [.command, .shift]),
                       [X11KeyChord(keycode: 12, modifiers: [m.leftControl, m.leftShift])])
    }

    func testChordReleasesUnwantedModifiersAndRestoresThem() {
        // Option held, Option+Left -> Ctrl+Left.
        let transitions = X11ShortcutRemapper.transitions(
            for: [X11KeyChord(keycode: 113, modifiers: [m.leftControl])],
            visibleHeld: [m.leftOption], lockedMods: 0, modMap: modMap)
        XCTAssertEqual(transitions.map { "\($0.keycode)\($0.pressed ? "+" : "-")" },
                       ["64-", "37+", "113+", "113-", "37-", "64+"])
        let keyPress = transitions[2]
        XCTAssertEqual(keyPress.before.effectiveMods, X11ModMask.control) // no Alt on the key itself
        XCTAssertEqual(transitions.last?.after.effectiveMods, X11ModMask.mod1) // back to Option held
    }

    func testChordKeepsModifiersItAlsoWants() {
        // Shift held, Cmd+Shift+Z (Command hidden) -> Ctrl+Shift+Z: Shift stays down throughout.
        let transitions = X11ShortcutRemapper.transitions(
            for: [X11KeyChord(keycode: 52, modifiers: [m.leftControl, m.leftShift])],
            visibleHeld: [m.leftShift], lockedMods: X11ModMask.lock, modMap: modMap)
        XCTAssertEqual(transitions.map(\.keycode), [37, 52, 52, 37])
        XCTAssertEqual(transitions[1].before, X11KeyboardSnapshot(baseMods: X11ModMask.control | X11ModMask.shift, lockedMods: X11ModMask.lock))
    }

    func testSettingsDecodeWithMissingAndUnknownKeys() throws {
        let partial = try JSONDecoder().decode(MSLExperimentalSettings.self, from: Data(#"{"linuxShortcuts": true, "someFutureFlag": 3}"#.utf8))
        XCTAssertTrue(partial.linuxShortcuts)
        XCTAssertFalse(partial.macTextNavigation)
        XCTAssertEqual(partial.optionKeyMode, .leftAltRightAltGr)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msl-experimental-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = MSLExperimentalSettings()
        settings.screenshotKeys = true
        settings.optionKeyMode = .bothAltGr
        try MSLExperimentalSettingsStore.save(settings, to: url)
        XCTAssertEqual(MSLExperimentalSettingsStore.load(from: url), settings)
        XCTAssertEqual(MSLExperimentalSettingsStore.load(from: url.appendingPathExtension("missing")), MSLExperimentalSettings())
    }
}
