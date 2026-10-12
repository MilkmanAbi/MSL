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

    /// The Mac keyboard reaches Linux apps out of the box now. It is only
    /// safe to ship that way because macOS keeps its own shortcuts
    /// (`isReservedForMac`) and terminals get Ctrl+Shift, both covered below.
    func testKeyboardMappingIsOnByDefault() {
        let remapper = X11ShortcutRemapper(MSLExperimentalSettings())
        XCTAssertTrue(remapper.isActive)
        XCTAssertTrue(remapper.shortcuts)
        XCTAssertTrue(remapper.textNavigation)
        XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: [.command]),
                       [X11KeyChord(keycode: 54, modifiers: [m.leftControl])])
    }

    /// Turning every part off must still mean "deliver the key as it is".
    func testNothingIsRemappedWhenEveryPartIsOff() {
        let remapper = X11ShortcutRemapper()
        XCTAssertFalse(remapper.isActive)
        XCTAssertNil(remapper.remap(macKeyCode: 0x08, flags: [.command]))
    }

    /// **⌘C in a terminal must copy, not kill the running command.**
    /// Ctrl+C at a shell is SIGINT, so the plain ⌘→Ctrl mapping would make
    /// "copy" interrupt whatever is running - the one thing that would make
    /// this feature unshippable as a default.
    func testTerminalsGetControlShiftInsteadOfControl() {
        let remapper = X11ShortcutRemapper(shortcuts: true)
        let cmdC: NSEvent.ModifierFlags = [.command]
        // Ordinary app: Ctrl+C.
        XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: cmdC, appClass: "Mousepad"),
                       [X11KeyChord(keycode: 54, modifiers: [m.leftControl])])
        // Terminal that binds Ctrl+Shift: Ctrl+Shift+C. (xterm and the other
        // classic X terminals are the exception - see
        // `testClassicTerminalsGetNoCommandTranslationAtAll`.)
        for terminal in ["gnome-terminal-server", "Konsole", "org.kde.konsole", "kitty"] {
            XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: cmdC, appClass: terminal),
                           [X11KeyChord(keycode: 54, modifiers: [m.leftControl, m.leftShift])],
                           terminal)
        }
        // An unknown app is not a terminal: a wrong guess the other way
        // would send Ctrl+Shift+C to an app where it means nothing.
        XCTAssertFalse(X11TerminalApps.isTerminal("SomeEditor"))
        XCTAssertFalse(X11TerminalApps.isTerminal(nil))
        // Versioned class names still match.
        XCTAssertTrue(X11TerminalApps.isTerminal("com.mitchellh.ghostty"))
    }

    /// **⌘C must never reach a classic X terminal.** Ctrl+Shift+C is a
    /// VTE/Konsole/kitty convention; xterm, urxvt and st bind neither, and
    /// Shift does not change the control character - so Ctrl+Shift+C arrives
    /// at the pty as a plain Ctrl+C and interrupts the running command.
    /// Measured in xterm: `sleep 300` died and `^C` appeared.
    func testClassicTerminalsGetNoCommandTranslationAtAll() {
        let remapper = X11ShortcutRemapper(shortcuts: true)
        for terminal in ["xterm", "urxvt", "st", "eterm"] {
            XCTAssertFalse(X11TerminalApps.bindsControlShift(terminal), terminal)
            // An EMPTY chord list, not nil: nil would deliver the key bare,
            // and with Command hidden ⌘C would type a stray "c" at the shell.
            XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: [.command], appClass: terminal),
                           [], terminal)
        }
        // The terminals that do bind it still get Ctrl+Shift.
        for terminal in ["gnome-terminal-server", "konsole", "kitty", "alacritty"] {
            XCTAssertTrue(X11TerminalApps.bindsControlShift(terminal), terminal)
        }
        // An ordinary app is unaffected either way.
        XCTAssertFalse(X11TerminalApps.bindsControlShift("Mousepad"))
        XCTAssertEqual(remapper.remap(macKeyCode: 0x08, flags: [.command], appClass: "Mousepad"),
                       [X11KeyChord(keycode: 54, modifiers: [m.leftControl])])
    }

    /// A terminal has no "select to the line start"; it has Ctrl+U and
    /// Ctrl+W, and Shift+Home would scroll the scrollback instead.
    func testTerminalLineAndWordDeletionUseShellKeys() {
        let remapper = X11ShortcutRemapper(textNavigation: true)
        // Cmd+Delete -> Ctrl+U in a terminal, Shift+Home then BackSpace elsewhere.
        XCTAssertEqual(remapper.remap(macKeyCode: 0x33, flags: [.command], appClass: "xterm"),
                       [X11KeyChord(keycode: 30, modifiers: [m.leftControl])])
        XCTAssertEqual(remapper.remap(macKeyCode: 0x33, flags: [.command], appClass: "Mousepad")?.count, 2)
        // Option+Delete -> Ctrl+W in a terminal.
        XCTAssertEqual(remapper.remap(macKeyCode: 0x33, flags: [.option], appClass: "xterm"),
                       [X11KeyChord(keycode: 25, modifiers: [m.leftControl])])
    }

    /// Control+Command is macOS's, whatever the key: ⌃⌘F is full screen and
    /// ⌃⌘Q locks the screen. Without this the remapper turned ⌃⌘F into a
    /// plain Ctrl+F and full screen stopped working in Linux windows.
    func testControlCommandStaysWithMacOS() {
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x03, flags: [.command, .control]))
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x0C, flags: [.command, .control]))
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x31, flags: [.command, .control]))
        // The window and session commands keep their own entries.
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x0C, flags: [.command]))   // Cmd+Q
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x04, flags: [.command]))   // Cmd+H
        XCTAssertTrue(X11KeyboardRouter.isReservedForMac(keyCode: 0x2E, flags: [.command]))   // Cmd+M
        // Ordinary Command shortcuts go to the Linux app.
        XCTAssertFalse(X11KeyboardRouter.isReservedForMac(keyCode: 0x08, flags: [.command]))  // Cmd+C
        XCTAssertFalse(X11KeyboardRouter.isReservedForMac(keyCode: 0x0D, flags: [.command]))  // Cmd+W
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
        // A flag this build knows and the file doesn't gets the shipped
        // default; this file has no generation, so it is also migrated to
        // the current one (see `MSLExperimentalSettingsTests`).
        XCTAssertTrue(partial.macTextNavigation)
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
