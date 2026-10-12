import AppKit
import Carbon.HIToolbox

/// Text that has no key behind it - the Mac's emoji & symbols picker,
/// dictation, press-and-hold style input, and input methods (Pinyin,
/// Japanese, Korean...) - reaching Linux apps.
///
/// mslgd turns key events into X11 keycodes and nothing else, which is right
/// for keys (shortcuts, games, terminals and Vim all want the key, not a
/// character) but meant none of the above ever reached a Linux app: they
/// deliver *text*. So the view is an `NSTextInputClient` too. Text arrives in
/// `insertText` and goes to `X11Connection.insertText`, which types it through
/// the Unicode slot keycodes.
///
/// Keys still take the raw path unless there is a reason not to:
/// - an input method is active (or composing): the key goes through the
///   input context first, and whatever the input method hands back as a plain
///   key (`doCommand`, or a single character it didn't transform) is sent raw;
/// - a key event whose characters are not what its key produces - a
///   synthetic Unicode key event (automation, remote-control and accessibility
///   tools post these with keycode 0, which X would read as "a").
extension X11CanvasView: NSTextInputClient {
    /// Whether this keyDown was taken as text. Called first from `keyDown`.
    func routeAsText(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }

        if hasMarkedText() || Self.inputMethodIsActive() {
            routingKeyEvent = event
            routedKeyWentRaw = false
            defer { routingKeyEvent = nil }
            let handled = inputContext?.handleEvent(event) ?? false
            if routedKeyWentRaw { return true } // already forwarded as a key
            if handled {
                textRoutedKeys.insert(event.keyCode)
                return true
            }
            return false
        }

        if let text = Self.syntheticText(event) {
            textRoutedKeys.insert(event.keyCode)
            eventSink?.insertText(text, in: self)
            return true
        }
        return false
    }

    /// The text a key event carries that its key could not have produced.
    ///
    /// `charactersIgnoringModifiers` is the tell: for a real key it is the
    /// layout's character for that key (Shift included, Option not), which is
    /// why Option combinations and dead-key compositions - "é" after Option+E -
    /// never qualify and keep composing the X11 way. A posted Unicode event
    /// carries its string there instead.
    static func syntheticText(_ event: NSEvent) -> String? {
        guard let text = event.characters, let base = event.charactersIgnoringModifiers,
              !text.isEmpty, text == base else { return nil }
        guard text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil } // control keys, arrows, function keys
        // Compared against mslgd's own keymap (built from the same layout),
        // so this costs a dictionary lookup per key, not a layout translation.
        // A real key yields one code point; "👍🏽" or a flag is text.
        if text.unicodeScalars.count > 1 { return text }
        guard let keycode = X11KeyCodes.keycode(forMac: event.keyCode) else { return text }
        var mods: UInt8 = 0
        if event.modifierFlags.contains(.shift) { mods |= X11ModMask.shift }
        if event.modifierFlags.contains(.capsLock) { mods |= X11ModMask.lock }
        let expected = X11KeymapProvider.shared.keymap.keysym(keycode: keycode, mods: mods)
        guard let actual = X11Keysym.forText(text) else { return nil }
        return expected == actual ? nil : text
    }

    /// An input method (not a plain keyboard layout) is the selected source.
    static func inputMethodIsActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let wasComposing = hasMarkedText()
        markedText = nil
        guard !text.isEmpty else { return }
        // An input method passing a plain key straight through (English mode,
        // or a key it doesn't compose): send the key itself, so shortcuts,
        // key repeat and key-reading apps behave exactly as without one.
        if let event = routingKeyEvent, !wasComposing,
           let base = event.charactersIgnoringModifiers, text == event.characters, text == base {
            eventSink?.keyEvent(event, in: self, pressed: true)
            routedKeyWentRaw = true
            return
        }
        eventSink?.insertText(text, in: self)
    }

    /// The responder-chain form. The Emoji & Symbols palette (and some
    /// services) send this one, not the NSTextInputClient method above.
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Return, Backspace, arrows and friends, handed back by the input method.
    override func doCommand(by selector: Selector) {
        guard let event = routingKeyEvent else { return }
        eventSink?.keyEvent(event, in: self, pressed: true)
        routedKeyWentRaw = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = text.isEmpty ? nil : text
    }

    func unmarkText() { markedText = nil }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        guard let markedText, !markedText.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !(markedText ?? "").isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the candidate window goes. The Linux app's text caret is not
    /// visible from here, so: just below the pointer, which is where the
    /// person clicked to type.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 18)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
