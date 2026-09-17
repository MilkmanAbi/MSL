import AppKit
import Carbon.HIToolbox

/// What the Mac says about its keyboard.
public struct X11MacKeyboardInfo: Equatable, Sendable {
    /// `com.apple.keylayout.US`, `com.apple.keylayout.Russian`, ...
    public let inputSourceID: String
    /// The name System Settings shows, e.g. "U.S." or "ABC".
    public let localizedName: String
    /// Languages the layout is for, most specific first.
    public let layoutLanguages: [String]
    /// The user's preferred system languages, in order.
    public let systemLanguages: [String]
    public let region: String?
    /// Whether the layout types Latin letters. When it doesn't, a second
    /// (Latin) group is added so shortcuts keep working.
    public let isASCIICapable: Bool
    public let latinFallbackID: String?
    /// The physical keyboard: ANSI, ISO or JIS.
    public let physicalLayout: String
    /// xkeyboard-config's name for the layout (`us`, `de`, `ru`...).
    public let xkbLayout: String
    public let repeatDelayMs: UInt16
    public let repeatIntervalMs: UInt16
}

/// Reads the Mac's keyboard layout through Text Input Source Services.
///
/// Everything here must run on the main thread: TIS asserts it, and the
/// crash that assertion produces took `mslhd` down once already (see the
/// history of `handleXkbGetMap`). The translation closures it hands back
/// are safe anywhere - they hold a copy of the layout data and only call
/// `UCKeyTranslate`, which is pure.
public enum X11MacKeyboard {
    public static func currentInfo() -> X11MacKeyboardInfo {
        dispatchPrecondition(condition: .onQueue(.main))
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let id = current.flatMap { stringProperty($0, kTISPropertyInputSourceID) } ?? "unknown"
        let asciiCapable = current.flatMap { boolProperty($0, kTISPropertyInputSourceIsASCIICapable) } ?? true
        var fallbackID: String?
        if !asciiCapable, let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            fallbackID = stringProperty(ascii, kTISPropertyInputSourceID)
        }
        return X11MacKeyboardInfo(
            inputSourceID: id,
            localizedName: current.flatMap { stringProperty($0, kTISPropertyLocalizedName) } ?? id,
            layoutLanguages: current.flatMap { arrayProperty($0, kTISPropertyInputSourceLanguages) } ?? [],
            systemLanguages: Locale.preferredLanguages,
            region: Locale.current.region?.identifier,
            isASCIICapable: asciiCapable,
            latinFallbackID: fallbackID,
            physicalLayout: physicalLayoutName(),
            xkbLayout: xkbLayoutName(forInputSourceID: id),
            repeatDelayMs: UInt16(clamping: Int((NSEvent.keyRepeatDelay * 1000).rounded())),
            repeatIntervalMs: UInt16(clamping: max(1, Int((NSEvent.keyRepeatInterval * 1000).rounded())))
        )
    }

    /// Builds the keymap for the layout that is selected right now.
    static func buildKeymap(optionMode: X11OptionKeyMode) -> (keymap: X11Keymap, info: X11MacKeyboardInfo) {
        dispatchPrecondition(condition: .onQueue(.main))
        let info = currentInfo()
        let keyboardType = UInt32(LMGetKbdType())
        let primary = (TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            .flatMap { layoutSource($0, keyboardType: keyboardType) }
        var fallback: X11LayoutSource?
        if !info.isASCIICapable, let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            fallback = layoutSource(ascii, keyboardType: keyboardType)
        }
        // A layout with no Unicode data (vanishingly rare - some very old
        // resource-based layouts) still gets every non-layout key.
        let source = primary ?? fallback ?? X11LayoutSource(name: info.localizedName) { _, _, _ in nil }
        var keymap = X11Keymap(primary: source, latinFallback: primary == nil ? nil : fallback, optionMode: optionMode)
        let secondGroup = keymap.numGroups > 1 ? "+us:2" : ""
        keymap.symbolsName = "pc+\(info.xkbLayout)\(secondGroup)+inet(evdev)"
        keymap.repeatDelayMs = info.repeatDelayMs
        keymap.repeatIntervalMs = info.repeatIntervalMs
        return (keymap, info)
    }

    /// A translation function over one input source's layout data.
    static func layoutSource(_ inputSource: TISInputSource, keyboardType: UInt32) -> X11LayoutSource? {
        guard let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let name = stringProperty(inputSource, kTISPropertyLocalizedName) ?? "Layout"
        return X11LayoutSource(name: name) { macKeyCode, shift, option in
            translate(layoutData: layoutData, keyboardType: keyboardType, macKeyCode: macKeyCode, shift: shift, option: option)
        }
    }

    /// One key through `UCKeyTranslate`.
    ///
    /// Dead keys are translated with dead-key processing ON, which is the
    /// only way to see them: the key produces no characters and leaves a
    /// dead-key state behind. Pressing Space in that state yields the
    /// accent's spacing form - the one thing that names the accent.
    static func translate(layoutData: Data, keyboardType: UInt32, macKeyCode: UInt16, shift: Bool, option: Bool) -> X11KeyOutput? {
        layoutData.withUnsafeBytes { raw -> X11KeyOutput? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var modifiers: UInt32 = 0
            if shift { modifiers |= UInt32(shiftKey >> 8) }
            if option { modifiers |= UInt32(optionKey >> 8) }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            var status = UCKeyTranslate(layout, macKeyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                        0, &deadKeyState, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            if length == 0, deadKeyState != 0 {
                status = UCKeyTranslate(layout, UInt16(kVK_Space), UInt16(kUCKeyActionDown), 0, keyboardType,
                                        0, &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                let accent = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespaces)
                return accent.isEmpty ? nil : .dead(accent: accent)
            }
            guard length > 0 else { return nil }
            return .text(String(utf16CodeUnits: chars, count: length))
        }
    }

    // MARK: - Properties

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key) as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let value = property(source, key) else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func arrayProperty(_ source: TISInputSource, _ key: CFString) -> [String]? {
        property(source, key) as? [String]
    }

    private static func physicalLayoutName() -> String {
        switch KBGetLayoutType(Int16(LMGetKbdType())) {
        case OSType(kKeyboardJIS): return "JIS"
        case OSType(kKeyboardISO): return "ISO"
        case OSType(kKeyboardANSI): return "ANSI"
        default: return "unknown"
        }
    }

    /// The xkeyboard-config layout closest to a Mac layout. Informational -
    /// the keysyms always come from the Mac layout itself - but it is what
    /// a keymap dump and `setxkbmap -query` show, and a wrong name there
    /// sends anyone debugging a keyboard problem the wrong way.
    static func xkbLayoutName(forInputSourceID id: String) -> String {
        let name = id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
        let table: [String: String] = [
            "US": "us", "ABC": "us", "USExtended": "us", "USInternational-PC": "us(intl)",
            "Dvorak": "us(dvorak)", "DVORAK-QWERTYCMD": "us(dvorak)", "Colemak": "us(colemak)",
            "British": "gb", "British-PC": "gb", "Australian": "au", "Irish": "ie", "IrishExtended": "ie",
            "Canadian": "ca(eng)", "Canadian-CSA": "ca(multix)", "CanadianFrench-PC": "ca",
            "German": "de", "Austrian": "at", "SwissGerman": "ch", "SwissFrench": "ch(fr)",
            "French": "fr(mac)", "French-PC": "fr", "French-numerical": "fr(mac)", "Belgian": "be",
            "Italian": "it(mac)", "Italian-Pro": "it", "Spanish": "es(mac)", "Spanish-ISO": "es",
            "Portuguese": "pt(mac)", "Brazilian": "br", "Brazilian-ABNT2": "br", "Brazilian-Pro": "br",
            "Dutch": "nl(mac)", "Danish": "dk(mac)", "Norwegian": "no(mac)", "Swedish": "se(mac)",
            "Swedish-Pro": "se", "Finnish": "fi(mac)", "Icelandic": "is(mac)",
            "Polish": "pl", "PolishPro": "pl", "Czech": "cz", "Czech-QWERTY": "cz(qwerty)", "Slovak": "sk",
            "Hungarian": "hu", "Romanian": "ro", "Croatian": "hr", "Slovenian": "si", "Serbian": "rs",
            "Turkish": "tr(f)", "Turkish-QWERTY": "tr", "Turkish-QWERTY-PC": "tr",
            "Russian": "ru(mac)", "RussianWin": "ru", "Russian-Phonetic": "ru(phonetic)", "Ukrainian": "ua",
            "Ukrainian-PC": "ua", "Greek": "gr", "Hebrew": "il", "Hebrew-PC": "il", "Arabic": "ara(mac)",
            "Thai": "th", "Korean": "kr", "Vietnamese": "vn", "Hindi": "in", "Georgian-QWERTY": "ge",
            "Armenian-HMQWERTY": "am", "Kazakh": "kz", "Lithuanian": "lt", "Latvian": "lv", "Estonian": "ee",
        ]
        if let mapped = table[name] { return mapped }
        if id.contains("Kotoeri") || id.contains("Japanese") { return "jp" }
        return "us"
    }

    /// A plain-text report of what was detected and what Linux apps get -
    /// `msl keyboard`.
    public static func report(optionMode: X11OptionKeyMode = .leftAltRightAltGr, keysyms: Bool = false) -> String {
        let (keymap, info) = buildKeymap(optionMode: optionMode)
        var lines = [
            "Layout:            \(info.localizedName) (\(info.inputSourceID))",
            // TIS lists every language a Latin layout can type - ~100 for
            // U.S. - most specific first, so the head is what matters.
            "Layout languages:  \(info.layoutLanguages.isEmpty ? "-" : info.layoutLanguages.prefix(3).joined(separator: ", ") + (info.layoutLanguages.count > 3 ? " (+\(info.layoutLanguages.count - 3) more)" : ""))",
            "System languages:  \(info.systemLanguages.joined(separator: ", "))",
            "Region:            \(info.region ?? "-")",
            "Physical keyboard: \(info.physicalLayout)",
            "Types Latin:       \(info.isASCIICapable ? "yes" : "no - shortcuts use \(info.latinFallbackID ?? "no Latin layout")")",
            "Key repeat:        \(info.repeatDelayMs) ms delay, every \(info.repeatIntervalMs) ms",
            "",
            "Linux apps see:",
            "  XKB symbols:     \(keymap.symbolsName)",
            "  Groups:          \(keymap.groupNames.joined(separator: " / "))",
            "  Option keys:     \(optionModeDescription(optionMode))",
            "  Command:         Super (Mod4)",
        ]
        if keysyms {
            lines.append("")
            lines.append("keycode  name  keysyms (base, Shift, AltGr, Shift+AltGr)")
            for keycode in X11KeyCodes.min...X11KeyCodes.max {
                guard let groups = keymap.keys[keycode] else { continue }
                let rendered = groups.map { group in group.syms.map(keysymName).joined(separator: " ") }.joined(separator: " | ")
                lines.append(String(format: "%7d  %-4@  %@", Int(keycode), X11KeyCodes.name(forKeycode: keycode) as NSString, rendered as NSString))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func optionModeDescription(_ mode: X11OptionKeyMode) -> String {
        switch mode {
        case .leftAltRightAltGr: return "left = Alt, right = AltGr (special characters)"
        case .bothAlt: return "both Alt"
        case .bothAltGr: return "both AltGr (type like a Mac app)"
        }
    }

    private static func keysymName(_ keysym: UInt32) -> String {
        if keysym == 0 { return "NoSymbol" }
        if let scalar = X11Keysym.scalar(for: keysym) { return String(scalar) }
        return String(format: "0x%X", keysym)
    }
}

/// The one keymap everything in this process serves, kept current with
/// the Mac's selected layout.
///
/// Built lazily on first use, then again whenever the user switches layout
/// (the input menu, Ctrl+Space, a second keyboard) - at which point
/// `didChangeNotification` is posted and every connection tells its client
/// the keymap changed, so a running Linux app follows the switch the way a
/// Mac app does rather than keeping the layout it started with.
final class X11KeymapProvider: @unchecked Sendable {
    static let shared = X11KeymapProvider()
    static let didChangeNotification = Notification.Name("MSLX11KeymapDidChange")

    private let lock = NSLock()
    private var current: (keymap: X11Keymap, info: X11MacKeyboardInfo)?
    private var optionModeValue: X11OptionKeyMode = .leftAltRightAltGr
    private var observers: [NSObjectProtocol] = []

    var keymap: X11Keymap {
        if let keymap = lockedCurrent()?.keymap { return keymap }
        if Thread.isMainThread {
            rebuild(notify: false)
        } else {
            DispatchQueue.main.sync { if self.lockedCurrent() == nil { self.rebuild(notify: false) } }
        }
        return lockedCurrent()!.keymap
    }

    var optionMode: X11OptionKeyMode {
        lock.lock(); defer { lock.unlock() }
        return optionModeValue
    }

    /// Changing the Option key arrangement rebuilds the keymap and tells
    /// clients, exactly like a layout switch.
    func setOptionMode(_ mode: X11OptionKeyMode) {
        lock.lock()
        let changed = optionModeValue != mode
        optionModeValue = mode
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { self.rebuild(notify: true) }
    }

    private func lockedCurrent() -> (keymap: X11Keymap, info: X11MacKeyboardInfo)? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Idempotent. Main thread.
    func startObserving() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard observers.isEmpty else { return }
        let rebuild: (Notification) -> Void = { [weak self] _ in self?.rebuild(notify: true) }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main, using: rebuild))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main, using: rebuild))
        // The Option key arrangement is an experimental setting; follow the
        // file live, like everything else there.
        let watcher = MSLExperimentalSettingsWatcher.shared
        watcher.startWatching()
        setOptionMode(watcher.current.optionKeyMode)
        observers.append(NotificationCenter.default.addObserver(
            forName: MSLExperimentalSettingsWatcher.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setOptionMode(watcher.current.optionKeyMode) })
    }

    private func rebuild(notify: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        let built = X11MacKeyboard.buildKeymap(optionMode: optionMode)
        lock.lock()
        let previous = current
        current = built
        lock.unlock()
        let changed = previous == nil || previous!.info != built.info || previous!.keymap.optionMode != built.keymap.optionMode
        if X11Trace.enabled {
            FileHandle.standardError.write("[x11] keymap built layout=\(built.info.inputSourceID) groups=\(built.keymap.numGroups) option=\(built.keymap.optionMode.rawValue) changed=\(changed)\n".data(using: .utf8)!)
        }
        if notify, changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
