import Foundation

/// What the two Option keys mean to a Linux app.
///
/// A Mac Option key does two jobs a PC keyboard splits between two keys:
/// it is the modifier shortcuts use (Alt/Meta - Emacs, terminal word
/// motion, menu accelerators) and it is the key that types a layout's
/// extra characters (Option+e for an acute accent, Option+2 for ™). X11
/// needs to be told which one each key is, because they are different
/// modifiers (Mod1 versus Mod5/LevelThree).
public enum X11OptionKeyMode: String, Codable, CaseIterable, Sendable {
    /// Left Option is Alt, right Option types special characters (AltGr).
    /// A PC keyboard's arrangement, and the default.
    case leftAltRightAltGr
    /// Both are Alt. Option never types special characters.
    case bothAlt
    /// Both type special characters, as in a Mac app. No Alt key at all.
    case bothAltGr
}

/// What one key produces with one set of modifiers held.
enum X11KeyOutput: Equatable {
    case text(String)
    /// A dead key, identified by the spacing form of its accent.
    case dead(accent: String)
}

/// Where the keymap's symbols come from - the live Mac layout
/// (`X11MacKeyboard`), or a fixture in tests.
struct X11LayoutSource {
    var name: String
    var translate: (_ macKeyCode: UInt16, _ shift: Bool, _ option: Bool) -> X11KeyOutput?
}

struct X11KeyType {
    let name: String
    let mods: UInt8
    let entries: [(mods: UInt8, level: UInt8)]
    let levelNames: [String]
    var levels: Int { levelNames.count }
}

struct X11KeyGroup: Equatable {
    var type: Int
    var syms: [UInt32]
}

/// The eight real modifier bits of the core protocol's `state` field.
enum X11ModMask {
    static let shift: UInt8 = 0x01
    static let lock: UInt8 = 0x02
    static let control: UInt8 = 0x04
    static let mod1: UInt8 = 0x08
    static let mod2: UInt8 = 0x10
    static let mod3: UInt8 = 0x20
    static let mod4: UInt8 = 0x40
    static let mod5: UInt8 = 0x80
}

/// The keyboard's modifier state as XKB reports it.
struct X11KeyboardSnapshot: Equatable {
    var baseMods: UInt8 = 0
    var lockedMods: UInt8 = 0
    var buttons: UInt16 = 0
    var effectiveMods: UInt8 { baseMods | lockedMods }
}

/// The complete keymap mslgd serves - core and XKB views of the same data.
///
/// One model, every encoder. The old server wrote `GetKeyboardMapping`,
/// `GetModifierMapping` and `XkbGetMap` as three separately hand-built
/// replies, each with its own idea of the modifier map, and answered the
/// rest of what libxkbcommon asks (`GetCompatMap`, `GetIndicatorMap`, real
/// names) with errors - which is precisely "failed to compile a keymap".
/// Here the replies are derived from one structure, so they cannot
/// disagree, and the tests re-parse every one of them with libxkbcommon's
/// own acceptance rules.
struct X11Keymap {
    enum TypeIndex {
        static let oneLevel = 0
        static let twoLevel = 1
        static let alphabetic = 2
        static let keypad = 3
        static let fourLevel = 4
        static let fourLevelSemiAlphabetic = 5
    }

    /// The first four are XKB's canonical types at their canonical indices,
    /// which libX11 assumes (`XkbTwoLevelIndex == 1` is a compile-time
    /// constant). The two four-level types are what xkeyboard-config calls
    /// them.
    static let types: [X11KeyType] = {
        let shift = X11ModMask.shift, lock = X11ModMask.lock, mod2 = X11ModMask.mod2, mod5 = X11ModMask.mod5
        let fourLevelNames = ["Base", "Shift", "Alt Base", "Shift Alt"]
        return [
            X11KeyType(name: "ONE_LEVEL", mods: 0, entries: [], levelNames: ["Any"]),
            X11KeyType(name: "TWO_LEVEL", mods: shift, entries: [(shift, 1)], levelNames: ["Base", "Shift"]),
            X11KeyType(name: "ALPHABETIC", mods: shift | lock, entries: [(shift, 1), (lock, 1)], levelNames: ["Base", "Caps"]),
            X11KeyType(name: "KEYPAD", mods: shift | mod2, entries: [(shift, 1), (mod2, 1)], levelNames: ["Base", "Number"]),
            X11KeyType(name: "FOUR_LEVEL", mods: shift | mod5,
                       entries: [(shift, 1), (mod5, 2), (shift | mod5, 3)], levelNames: fourLevelNames),
            // Caps Lock reaches the letters but not the Option layer.
            X11KeyType(name: "FOUR_LEVEL_SEMIALPHABETIC", mods: shift | lock | mod5,
                       entries: [(shift, 1), (lock, 1), (mod5, 2), (shift | mod5, 3), (lock | mod5, 2), (shift | lock | mod5, 3)],
                       levelNames: fourLevelNames),
        ]
    }()

    /// Virtual modifiers, in index order, with the real modifier each is
    /// bound to. The names are not decoration: Qt and GTK decide which real
    /// modifier *is* Super, Meta or Alt by looking these up, so without
    /// "Super" bound to Mod4 a Command-based shortcut can never match.
    static let virtualMods: [(name: String, realMods: UInt8)] = [
        ("NumLock", X11ModMask.mod2), ("Alt", X11ModMask.mod1), ("LevelThree", X11ModMask.mod5),
        ("Super", X11ModMask.mod4), ("Meta", X11ModMask.mod1),
    ]
    private enum VMod {
        static let alt: UInt16 = 1 << 1
        static let levelThree: UInt16 = 1 << 2
        static let superMod: UInt16 = 1 << 3
        static let meta: UInt16 = 1 << 4
    }

    static let indicatorNames = ["Caps Lock", "Num Lock", "Scroll Lock"]

    /// The XKB device ID of the one keyboard, matching the XI2 master
    /// keyboard's ID. Qt drops XKB events whose device ID differs from the
    /// one `XkbGetDeviceInfo` reported, so every reply and event must agree.
    static let deviceID: UInt8 = 3

    private(set) var keys: [UInt8: [X11KeyGroup]] = [:]
    private(set) var modMap: [UInt8: UInt8] = [:]
    private(set) var vmodMap: [UInt8: UInt16] = [:]
    let groupNames: [String]
    let optionMode: X11OptionKeyMode
    /// xkeyboard-config's name for the layout, e.g. `pc+us+inet(evdev)` -
    /// what `setxkbmap -query` and a keymap dump show.
    var symbolsName = "pc+us+inet(evdev)"
    var repeatDelayMs: UInt16 = 500
    var repeatIntervalMs: UInt16 = 33

    var numGroups: Int { groupNames.count }

    /// - Parameter latinFallback: a second group for non-Latin layouts.
    ///   Linux does exactly this ("ru,us"): with only Cyrillic symbols on
    ///   the keys, Ctrl+C would be Ctrl+с and no shortcut in any app would
    ///   ever match. GTK and Qt both look through the other groups of the
    ///   same keycode for a Latin symbol when matching shortcuts.
    init(primary: X11LayoutSource, latinFallback: X11LayoutSource? = nil, optionMode: X11OptionKeyMode = .leftAltRightAltGr) {
        self.optionMode = optionMode
        let level3 = optionMode != .bothAlt
        var names = [primary.name]
        var fallbackUsed = false

        for (mac, entry) in X11KeyCodes.macKeys {
            let keycode = entry.keycode
            if keycode == X11KeyCodes.Modifier.leftOption || keycode == X11KeyCodes.Modifier.rightOption { continue }
            if let fixed = X11Keysym.fixed[keycode] {
                keys[keycode] = [Self.fixedGroup(fixed)]
                continue
            }
            let primaryGroup = Self.layoutGroup(mac: mac, source: primary, level3: level3)
            let fallbackGroup = latinFallback.flatMap { Self.layoutGroup(mac: mac, source: $0, level3: level3) }
            switch (primaryGroup, fallbackGroup) {
            case let (p?, f?) where p != f:
                keys[keycode] = [p, f]
                fallbackUsed = true
            case let (p?, _):
                keys[keycode] = [p]
            case let (nil, f?):
                keys[keycode] = [f]
            case (nil, nil):
                break
            }
        }
        if fallbackUsed, let latinFallback { names.append(latinFallback.name) }
        groupNames = names

        for virtual in [X11KeyCodes.Virtual.print, X11KeyCodes.Virtual.scrollLock, X11KeyCodes.Virtual.pause] {
            if let fixed = X11Keysym.fixed[virtual] { keys[virtual] = [Self.fixedGroup(fixed)] }
        }

        let m = X11KeyCodes.Modifier.self
        modMap[m.leftShift] = X11ModMask.shift
        modMap[m.rightShift] = X11ModMask.shift
        modMap[m.capsLock] = X11ModMask.lock
        modMap[m.leftControl] = X11ModMask.control
        modMap[m.rightControl] = X11ModMask.control
        modMap[m.leftCommand] = X11ModMask.mod4
        modMap[m.rightCommand] = X11ModMask.mod4
        vmodMap[m.leftCommand] = VMod.superMod
        vmodMap[m.rightCommand] = VMod.superMod

        func makeAlt(_ keycode: UInt8, _ keysym: UInt32) {
            keys[keycode] = [X11KeyGroup(type: TypeIndex.oneLevel, syms: [keysym])]
            modMap[keycode] = X11ModMask.mod1
            vmodMap[keycode] = VMod.alt | VMod.meta
        }
        func makeAltGr(_ keycode: UInt8) {
            keys[keycode] = [X11KeyGroup(type: TypeIndex.oneLevel, syms: [X11Keysym.isoLevel3Shift])]
            modMap[keycode] = X11ModMask.mod5
            vmodMap[keycode] = VMod.levelThree
        }
        switch optionMode {
        case .leftAltRightAltGr:
            makeAlt(m.leftOption, X11Keysym.altL)
            makeAltGr(m.rightOption)
        case .bothAlt:
            makeAlt(m.leftOption, X11Keysym.altL)
            makeAlt(m.rightOption, X11Keysym.altR)
        case .bothAltGr:
            makeAltGr(m.leftOption)
            makeAltGr(m.rightOption)
        }
    }

    private static func fixedGroup(_ syms: [UInt32]) -> X11KeyGroup {
        X11KeyGroup(type: syms.count > 1 ? TypeIndex.twoLevel : TypeIndex.oneLevel, syms: syms)
    }

    /// One layout's symbols for one key, with the narrowest type that
    /// describes them. Narrow matters: a key typed FOUR_LEVEL whose extra
    /// levels just repeat its base symbols makes AltGr "consume" nothing
    /// useful and confuses shortcut matching.
    static func layoutGroup(mac: UInt16, source: X11LayoutSource, level3: Bool) -> X11KeyGroup? {
        func keysym(shift: Bool, option: Bool) -> UInt32? {
            switch source.translate(mac, shift, option) {
            case .text(let text)?: return X11Keysym.forText(text)
            case .dead(let accent)?: return X11Keysym.deadKey(forSpacingAccent: accent)
            case nil: return nil
            }
        }
        guard let l1 = keysym(shift: false, option: false) else { return nil }
        let l2 = keysym(shift: true, option: false) ?? l1
        let alphabetic = X11Keysym.isCasePair(l1, l2)
        if level3, let l3 = keysym(shift: false, option: true) {
            let l4 = keysym(shift: true, option: true) ?? l3
            if l3 != l1 || l4 != l2 {
                return X11KeyGroup(type: alphabetic ? TypeIndex.fourLevelSemiAlphabetic : TypeIndex.fourLevel,
                                   syms: [l1, l2, l3, l4])
            }
        }
        if alphabetic { return X11KeyGroup(type: TypeIndex.alphabetic, syms: [l1, l2]) }
        if l1 == l2 { return X11KeyGroup(type: TypeIndex.oneLevel, syms: [l1]) }
        return X11KeyGroup(type: TypeIndex.twoLevel, syms: [l1, l2])
    }

    // MARK: - Lookups

    /// The keysym a client resolves for `keycode` with `mods` held - the
    /// same walk through the key type a real XKB client does.
    func keysym(keycode: UInt8, group: Int = 0, mods: UInt8) -> UInt32 {
        guard let groups = keys[keycode], !groups.isEmpty else { return X11Keysym.noSymbol }
        let keyGroup = groups[min(group, groups.count - 1)]
        let type = Self.types[keyGroup.type]
        let relevant = mods & type.mods
        let level = type.entries.first { $0.mods == relevant }.map { Int($0.level) } ?? 0
        return level < keyGroup.syms.count ? keyGroup.syms[level] : X11Keysym.noSymbol
    }

    /// Whether holding `keycode` should auto-repeat. Modifiers never do.
    func repeats(_ keycode: UInt8) -> Bool {
        keys[keycode] != nil && modMap[keycode] == nil
    }

    /// Core keysyms for one keycode, in the column order xorg's
    /// `XkbUpdateCoreDescription` produces: group 1 levels 1-2, group 2
    /// levels 1-2, then group 1 levels 3-4.
    static let coreKeysymsPerKeycode = 6
    func coreKeysyms(for keycode: UInt8) -> [UInt32] {
        var columns = [UInt32](repeating: X11Keysym.noSymbol, count: Self.coreKeysymsPerKeycode)
        guard let groups = keys[keycode], let first = groups.first else { return columns }
        let second = groups.count > 1 ? groups[1] : first
        func sym(_ group: X11KeyGroup, _ level: Int) -> UInt32 { level < group.syms.count ? group.syms[level] : 0 }
        columns[0] = sym(first, 0)
        columns[1] = sym(first, 1)
        columns[2] = sym(second, 0)
        columns[3] = sym(second, 1)
        columns[4] = sym(first, 2)
        columns[5] = sym(first, 3)
        return columns
    }

    /// Up to two keycodes per real modifier, Shift through Mod5.
    static let keycodesPerModifier = 2
    func modifierKeycodes() -> [[UInt8]] {
        (0..<8).map { bit in
            let mask = UInt8(1) << UInt8(bit)
            return modMap.filter { $0.value & mask != 0 }.map(\.key).sorted()
        }
    }

    // MARK: - Core replies

    func keyboardMappingReply(firstKeycode: UInt8, count: Int, sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1)
        w.writeU8(UInt8(Self.coreKeysymsPerKeycode))
        w.writeU16(sequence)
        w.writeU32(UInt32(Self.coreKeysymsPerKeycode * count))
        w.writePadding(24)
        for i in 0..<count {
            let keycode = Int(firstKeycode) + i
            let syms = keycode <= 255 ? coreKeysyms(for: UInt8(keycode)) : [UInt32](repeating: 0, count: Self.coreKeysymsPerKeycode)
            for sym in syms { w.writeU32(sym) }
        }
        return w.bytes
    }

    func modifierMappingReply(sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1)
        w.writeU8(UInt8(Self.keycodesPerModifier))
        w.writeU16(sequence)
        w.writeU32(UInt32(8 * Self.keycodesPerModifier / 4))
        w.writePadding(24)
        for keycodes in modifierKeycodes() {
            for slot in 0..<Self.keycodesPerModifier {
                w.writeU8(slot < keycodes.count ? keycodes[slot] : 0)
            }
        }
        return w.bytes
    }

    /// Core `MappingNotify`. `request` is 0 for Modifier, 1 for Keyboard.
    static func mappingNotify(request: UInt8, sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(34)
        w.writeU8(0)
        w.writeU16(sequence)
        w.writeU8(request)
        w.writeU8(request == 1 ? X11KeyCodes.min : 0)
        w.writeU8(request == 1 ? UInt8(X11KeyCodes.count) : 0)
        w.writePadding(25)
        return w.bytes
    }

    // MARK: - XKB replies

    private static func reply(detail: UInt8, sequence: UInt16, littleEndian: Bool, fixed: X11ByteWriter, extra: X11ByteWriter) -> [UInt8] {
        precondition(fixed.bytes.count == 24, "XKB reply fixed part must be 24 bytes, got \(fixed.bytes.count)")
        pad(extra)
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(1)
        w.writeU8(detail)
        w.writeU16(sequence)
        w.writeU32(UInt32(extra.bytes.count / 4))
        w.writeBytes(fixed.bytes)
        w.writeBytes(extra.bytes)
        return w.bytes
    }

    private static func pad(_ w: X11ByteWriter) {
        w.writePadding(X11Wire.pad(w.bytes.count) - w.bytes.count)
    }

    enum MapPart {
        static let keyTypes: UInt16 = 1 << 0
        static let keySyms: UInt16 = 1 << 1
        static let modifierMap: UInt16 = 1 << 2
        static let explicitComponents: UInt16 = 1 << 3
        static let keyActions: UInt16 = 1 << 4
        static let keyBehaviors: UInt16 = 1 << 5
        static let virtualMods: UInt16 = 1 << 6
        static let virtualModMap: UInt16 = 1 << 7
        static let all: UInt16 = 0xFF
    }

    /// `XkbGetMap`. Always answers for the whole keycode range rather than a
    /// requested sub-range - every client parses the ranges from the reply,
    /// and the whole map is what libxkbcommon asks for anyway.
    ///
    /// `body` is the request after its 4-byte header.
    func getMapReply(body: [UInt8], sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(2) // deviceSpec
        let full = r.readU16()
        let partial = r.readU16()
        r.skip(8) // firstType .. nKeyBehaviors
        let requestedVMods = r.readU16()
        let present = (full | partial) & MapPart.all
        let minKC = X11KeyCodes.min, maxKC = X11KeyCodes.max, nKeys = UInt8(X11KeyCodes.count)
        let keycodes = Array(minKC...maxKC)

        let extra = X11ByteWriter(littleEndian: littleEndian)

        var nTypes: UInt8 = 0
        if present & MapPart.keyTypes != 0 {
            nTypes = UInt8(Self.types.count)
            for type in Self.types {
                extra.writeU8(type.mods) // mask
                extra.writeU8(type.mods) // realMods
                extra.writeU16(0) // virtualMods
                extra.writeU8(UInt8(type.levels))
                extra.writeU8(UInt8(type.entries.count))
                extra.writeU8(0) // preserve
                extra.writePadding(1)
                for entry in type.entries {
                    extra.writeU8(1) // active
                    extra.writeU8(entry.mods) // mask
                    extra.writeU8(entry.level)
                    extra.writeU8(entry.mods) // realMods
                    extra.writeU16(0) // virtualMods
                    extra.writePadding(2)
                }
            }
        }

        var totalSyms = 0
        if present & MapPart.keySyms != 0 {
            for keycode in keycodes {
                let groups = keys[keycode] ?? []
                let width = groups.map { Self.types[$0.type].levels }.max() ?? 0
                for i in 0..<4 {
                    extra.writeU8(UInt8(i < groups.count ? groups[i].type : (groups.first?.type ?? 0)))
                }
                extra.writeU8(UInt8(groups.count)) // groupInfo: group count, WrapIntoRange
                extra.writeU8(UInt8(width))
                extra.writeU16(UInt16(width * groups.count))
                for group in groups {
                    for level in 0..<width {
                        extra.writeU32(level < group.syms.count ? group.syms[level] : X11Keysym.noSymbol)
                    }
                }
                totalSyms += width * groups.count
            }
        }

        var totalActs = 0
        if present & MapPart.keyActions != 0 {
            var counts: [UInt8] = []
            var actions: [[UInt8]] = []
            for keycode in keycodes {
                guard let action = self.action(for: keycode), let groups = keys[keycode] else {
                    counts.append(0)
                    continue
                }
                let width = groups.map { Self.types[$0.type].levels }.max() ?? 0
                let n = width * groups.count
                counts.append(UInt8(n))
                actions.append(contentsOf: [[UInt8]](repeating: action, count: n))
                totalActs += n
            }
            extra.writeBytes(counts)
            Self.pad(extra)
            for action in actions { extra.writeBytes(action) }
        }

        var vmodsMask: UInt16 = 0
        if present & MapPart.virtualMods != 0 {
            vmodsMask = full & MapPart.virtualMods != 0 ? 0xFFFF : requestedVMods
            var count = 0
            for i in 0..<16 where vmodsMask & (1 << UInt16(i)) != 0 {
                extra.writeU8(i < Self.virtualMods.count ? Self.virtualMods[i].realMods : 0)
                count += 1
            }
            _ = count
            Self.pad(extra)
        }

        var totalExplicit = 0
        if present & MapPart.explicitComponents != 0 {
            for keycode in keycodes {
                guard let groups = keys[keycode] else { continue }
                var explicit: UInt8 = 0x10 | 0x80 // Interpret, VModMap
                for g in 0..<groups.count { explicit |= UInt8(1) << UInt8(g) } // KeyTypeN
                extra.writeU8(keycode)
                extra.writeU8(explicit)
                totalExplicit += 1
            }
            Self.pad(extra)
        }

        var totalModMap = 0
        if present & MapPart.modifierMap != 0 {
            for keycode in modMap.keys.sorted() {
                extra.writeU8(keycode)
                extra.writeU8(modMap[keycode]!)
                totalModMap += 1
            }
            Self.pad(extra)
        }

        var totalVModMap = 0
        if present & MapPart.virtualModMap != 0 {
            for keycode in vmodMap.keys.sorted() {
                extra.writeU8(keycode)
                extra.writePadding(1)
                extra.writeU16(vmodMap[keycode]!)
                totalVModMap += 1
            }
        }

        func range(_ part: UInt16) -> (first: UInt8, n: UInt8) {
            present & part != 0 ? (minKC, nKeys) : (0, 0)
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writePadding(2)
        fw.writeU8(minKC)
        fw.writeU8(maxKC)
        fw.writeU16(present)
        fw.writeU8(0) // firstType
        fw.writeU8(nTypes)
        fw.writeU8(UInt8(Self.types.count)) // totalTypes
        fw.writeU8(range(MapPart.keySyms).first)
        fw.writeU16(UInt16(totalSyms))
        fw.writeU8(range(MapPart.keySyms).n)
        fw.writeU8(range(MapPart.keyActions).first)
        fw.writeU16(UInt16(totalActs))
        fw.writeU8(range(MapPart.keyActions).n)
        fw.writeU8(range(MapPart.keyBehaviors).first)
        fw.writeU8(range(MapPart.keyBehaviors).n)
        fw.writeU8(0) // totalKeyBehaviors
        fw.writeU8(range(MapPart.explicitComponents).first)
        fw.writeU8(range(MapPart.explicitComponents).n)
        fw.writeU8(UInt8(totalExplicit))
        fw.writeU8(range(MapPart.modifierMap).first) // 24 bytes through here
        let tail = X11ByteWriter(littleEndian: littleEndian)
        tail.writeU8(range(MapPart.modifierMap).n)
        tail.writeU8(UInt8(totalModMap))
        tail.writeU8(range(MapPart.virtualModMap).first)
        tail.writeU8(range(MapPart.virtualModMap).n)
        tail.writeU8(UInt8(totalVModMap))
        tail.writePadding(1)
        tail.writeU16(vmodsMask)
        tail.writeBytes(extra.bytes)
        return Self.reply(detail: Self.deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: tail)
    }

    /// The action a modifier key performs. Clients mostly learn modifier
    /// state from `XkbStateNotify`, but a keymap whose modifier keys have
    /// no actions compiles to one where pressing Shift does nothing - which
    /// is what libxkbcommon's own state machine, `xkbcomp` and any client
    /// driving `xkb_state_update_key` would then do.
    private func action(for keycode: UInt8) -> [UInt8]? {
        guard modMap[keycode] != nil else { return nil }
        let useModMapMods: UInt8 = 0x04, clearLocks: UInt8 = 0x01
        if keycode == X11KeyCodes.Modifier.capsLock {
            return [0x03, useModMapMods, 0, 0, 0, 0, 0, 0] // LockMods
        }
        return [0x01, useModMapMods | clearLocks, 0, 0, 0, 0, 0, 0] // SetMods
    }

    enum NamePart {
        static let keycodes: UInt32 = 1 << 0
        static let geometry: UInt32 = 1 << 1
        static let symbols: UInt32 = 1 << 2
        static let physSymbols: UInt32 = 1 << 3
        static let types: UInt32 = 1 << 4
        static let compat: UInt32 = 1 << 5
        static let keyTypeNames: UInt32 = 1 << 6
        static let ktLevelNames: UInt32 = 1 << 7
        static let indicatorNames: UInt32 = 1 << 8
        static let keyNames: UInt32 = 1 << 9
        static let keyAliases: UInt32 = 1 << 10
        static let virtualModNames: UInt32 = 1 << 11
        static let groupNames: UInt32 = 1 << 12
        static let rgNames: UInt32 = 1 << 13
        static let all: UInt32 = 0x3FFF
    }

    /// `XkbGetNames`, value list in exactly `XkbSendNames`' order.
    func getNamesReply(body: [UInt8], sequence: UInt16, littleEndian: Bool, intern: (String) -> UInt32) -> [UInt8] {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // deviceSpec, pad
        let which = r.readU32() & NamePart.all
        let extra = X11ByteWriter(littleEndian: littleEndian)

        let components: [(UInt32, String)] = [
            (NamePart.keycodes, "evdev"), (NamePart.geometry, "pc(pc105)"), (NamePart.symbols, symbolsName),
            (NamePart.physSymbols, symbolsName), (NamePart.types, "complete"), (NamePart.compat, "complete"),
        ]
        for (bit, name) in components where which & bit != 0 { extra.writeU32(intern(name)) }

        if which & NamePart.keyTypeNames != 0 {
            for type in Self.types { extra.writeU32(intern(type.name)) }
        }
        var nKTLevels = 0
        if which & NamePart.ktLevelNames != 0 {
            for type in Self.types { extra.writeU8(UInt8(type.levels)) }
            Self.pad(extra)
            for type in Self.types {
                for name in type.levelNames { extra.writeU32(intern(name)) }
                nKTLevels += type.levels
            }
        }
        var indicators: UInt32 = 0
        if which & NamePart.indicatorNames != 0 {
            for (i, name) in Self.indicatorNames.enumerated() {
                indicators |= 1 << UInt32(i)
                extra.writeU32(intern(name))
            }
        }
        var virtualModsMask: UInt16 = 0
        if which & NamePart.virtualModNames != 0 {
            for (i, vmod) in Self.virtualMods.enumerated() {
                virtualModsMask |= 1 << UInt16(i)
                extra.writeU32(intern(vmod.name))
            }
        }
        var groupNamesMask: UInt8 = 0
        if which & NamePart.groupNames != 0 {
            for (i, name) in groupNames.enumerated() {
                groupNamesMask |= 1 << UInt8(i)
                extra.writeU32(intern(name))
            }
        }
        if which & NamePart.keyNames != 0 {
            for keycode in X11KeyCodes.min...X11KeyCodes.max {
                let name = Array(X11KeyCodes.name(forKeycode: keycode).utf8.prefix(4))
                extra.writeBytes(name)
                extra.writePadding(4 - name.count)
            }
        }
        // No key aliases and no radio groups: counts stay zero, no data.

        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(which)
        fw.writeU8(X11KeyCodes.min)
        fw.writeU8(X11KeyCodes.max)
        fw.writeU8(UInt8(Self.types.count))
        fw.writeU8(groupNamesMask)
        fw.writeU16(virtualModsMask)
        fw.writeU8(X11KeyCodes.min) // firstKey
        fw.writeU8(UInt8(X11KeyCodes.count)) // nKeys
        fw.writeU32(indicators)
        fw.writeU8(0) // nRadioGroups
        fw.writeU8(0) // nKeyAliases
        fw.writeU16(UInt16(nKTLevels))
        fw.writePadding(4)
        return Self.reply(detail: Self.deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: extra)
    }

    /// `XkbGetCompatMap`. No symbol interpretations: every key carries its
    /// actions and types explicitly (`explicitComponents`), which is what
    /// interpretations would otherwise be used to fill in.
    func getCompatMapReply(body: [UInt8], sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(2) // deviceSpec
        let groups = r.readU8() & 0x0F
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU8(groups)
        fw.writePadding(1)
        fw.writeU16(0) // firstSI
        fw.writeU16(0) // nSI
        fw.writeU16(0) // nTotalSI
        fw.writePadding(16)
        let extra = X11ByteWriter(littleEndian: littleEndian)
        for bit in 0..<4 where groups & (1 << UInt8(bit)) != 0 {
            extra.writePadding(4) // xkbModsWireDesc: no group compat mods
        }
        return Self.reply(detail: Self.deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: extra)
    }

    /// `XkbGetIndicatorMap`. Echoes the requested indicator bits, as xorg
    /// does; Caps Lock and Num Lock light from their locked modifiers.
    func getIndicatorMapReply(body: [UInt8], sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // deviceSpec, pad
        let which = r.readU32()
        let extra = X11ByteWriter(littleEndian: littleEndian)
        var n: UInt8 = 0
        for i in 0..<32 where which & (UInt32(1) << UInt32(i)) != 0 {
            n += 1
            let lockedMods: UInt8 = i == 0 ? X11ModMask.lock : (i == 1 ? X11ModMask.mod2 : 0)
            extra.writeU8(0) // flags
            extra.writeU8(0) // whichGroups
            extra.writeU8(0) // groups
            extra.writeU8(lockedMods != 0 ? 0x04 : 0) // whichMods: UseLocked
            extra.writeU8(lockedMods) // mods
            extra.writeU8(lockedMods) // realMods
            extra.writeU16(0) // virtualMods
            extra.writeU32(0) // ctrls
        }
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(which)
        fw.writeU32(0) // realIndicators: no physical LEDs
        fw.writeU8(n)
        fw.writePadding(15)
        return Self.reply(detail: Self.deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: extra)
    }

    /// `XkbGetControls`. The repeat rate is the Mac's own (System Settings >
    /// Keyboard), so held keys repeat in a Linux app at the speed they do
    /// everywhere else.
    func getControlsReply(sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU8(0) // mkDfltBtn
        fw.writeU8(UInt8(numGroups))
        fw.writeU8(0) // groupsWrap: WrapIntoRange
        fw.writeU8(0) // internalMods
        fw.writeU8(0) // ignoreLockMods
        fw.writeU8(0) // internalRealMods
        fw.writeU8(0) // ignoreLockRealMods
        fw.writePadding(1)
        fw.writeU16(0) // internalVMods
        fw.writeU16(0) // ignoreLockVMods
        fw.writeU16(repeatDelayMs)
        fw.writeU16(repeatIntervalMs)
        fw.writeU16(0) // slowKeysDelay
        fw.writeU16(0) // debounceDelay
        fw.writeU16(0) // mkDelay
        fw.writeU16(0) // mkInterval -- 24 bytes through here
        let extra = X11ByteWriter(littleEndian: littleEndian)
        extra.writeU16(0) // mkTimeToMax
        extra.writeU16(0) // mkMaxSpeed
        extra.writeI16(0) // mkCurve
        extra.writeU16(0) // axOptions
        extra.writeU16(0) // axTimeout
        extra.writeU16(0) // axtOptsMask
        extra.writeU16(0) // axtOptsValues
        extra.writePadding(2)
        extra.writeU32(0) // axtCtrlsMask
        extra.writeU32(0) // axtCtrlsValues
        extra.writeU32(1) // enabledCtrls: RepeatKeys
        var perKeyRepeat = [UInt8](repeating: 0, count: 32)
        for keycode in X11KeyCodes.min...X11KeyCodes.max where repeats(keycode) {
            perKeyRepeat[Int(keycode) / 8] |= 1 << UInt8(Int(keycode) % 8)
        }
        extra.writeBytes(perKeyRepeat)
        return Self.reply(detail: Self.deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: extra)
    }

    static func getStateReply(_ state: X11KeyboardSnapshot, sequence: UInt16, littleEndian: Bool) -> [UInt8] {
        let mods = state.effectiveMods
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU8(mods)
        fw.writeU8(state.baseMods)
        fw.writeU8(0) // latchedMods
        fw.writeU8(state.lockedMods)
        fw.writeU8(0) // group
        fw.writeU8(0) // lockedGroup
        fw.writeI16(0) // baseGroup
        fw.writeI16(0) // latchedGroup
        fw.writeU8(mods) // compatState
        fw.writeU8(mods) // grabMods
        fw.writeU8(mods) // compatGrabMods
        fw.writeU8(mods) // lookupMods
        fw.writeU8(mods) // compatLookupMods
        fw.writePadding(1)
        fw.writeU16(state.buttons)
        fw.writePadding(6)
        return reply(detail: deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: X11ByteWriter(littleEndian: littleEndian))
    }

    /// Per-client flags xorg supports - the reply advertises all of them;
    /// the one mslgd acts on is DetectableAutoRepeat.
    enum ClientFlag {
        static let detectableAutoRepeat: UInt32 = 1 << 0
        static let all: UInt32 = 0x1F
    }

    /// `XkbPerClientFlags`: applies the change and answers with the result.
    static func perClientFlagsReply(body: [UInt8], current: UInt32, sequence: UInt16, littleEndian: Bool) -> (flags: UInt32, reply: [UInt8]) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(4) // deviceSpec, pad
        let change = r.readU32() & ClientFlag.all
        let value = r.readU32()
        let flags = (current & ~change) | (value & change)
        let fw = X11ByteWriter(littleEndian: littleEndian)
        fw.writeU32(ClientFlag.all) // supported
        fw.writeU32(flags)
        fw.writeU32(0) // autoCtrls
        fw.writeU32(0) // autoCtrlValues
        fw.writePadding(8)
        return (flags, reply(detail: deviceID, sequence: sequence, littleEndian: littleEndian, fixed: fw, extra: X11ByteWriter(littleEndian: littleEndian)))
    }

    // MARK: - XKB events

    enum EventType {
        static let newKeyboardNotify: UInt8 = 0
        static let mapNotify: UInt8 = 1
        static let stateNotify: UInt8 = 2
    }

    static func stateNotify(_ state: X11KeyboardSnapshot, changed: UInt16, keycode: UInt8, eventType: UInt8,
                            eventBase: UInt8, sequence: UInt16, time: UInt32, littleEndian: Bool) -> [UInt8] {
        let mods = state.effectiveMods
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(eventBase)
        w.writeU8(EventType.stateNotify)
        w.writeU16(sequence)
        w.writeU32(time)
        w.writeU8(deviceID)
        w.writeU8(mods)
        w.writeU8(state.baseMods)
        w.writeU8(0) // latchedMods
        w.writeU8(state.lockedMods)
        w.writeU8(0) // group
        w.writeI16(0) // baseGroup
        w.writeI16(0) // latchedGroup
        w.writeU8(0) // lockedGroup
        w.writeU8(mods) // compatState
        w.writeU8(mods) // grabMods
        w.writeU8(mods) // compatGrabMods
        w.writeU8(mods) // lookupMods
        w.writeU8(mods) // compatLookupMods
        w.writeU16(state.buttons)
        w.writeU16(changed)
        w.writeU8(keycode)
        w.writeU8(eventType)
        w.writeU8(0) // requestMajor
        w.writeU8(0) // requestMinor
        return w.bytes
    }

    /// Which parts of `XkbStateNotify.changed` differ between two states.
    static func stateChanges(from old: X11KeyboardSnapshot, to new: X11KeyboardSnapshot) -> UInt16 {
        var changed: UInt16 = 0
        if old.effectiveMods != new.effectiveMods { changed |= 1 << 0 } // ModifierState
        if old.baseMods != new.baseMods { changed |= 1 << 1 } // ModifierBase
        if old.lockedMods != new.lockedMods { changed |= 1 << 3 } // ModifierLock
        if old.effectiveMods != new.effectiveMods { changed |= 1 << 8 | 1 << 9 | 1 << 10 | 1 << 11 } // compat/grab/lookup mods
        if old.buttons != new.buttons { changed |= 1 << 13 } // PointerButtons
        return changed
    }

    static func newKeyboardNotify(eventBase: UInt8, sequence: UInt16, time: UInt32, littleEndian: Bool) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(eventBase)
        w.writeU8(EventType.newKeyboardNotify)
        w.writeU16(sequence)
        w.writeU32(time)
        w.writeU8(deviceID)
        w.writeU8(deviceID) // oldDeviceID
        w.writeU8(X11KeyCodes.min)
        w.writeU8(X11KeyCodes.max)
        w.writeU8(X11KeyCodes.min) // oldMinKeyCode
        w.writeU8(X11KeyCodes.max) // oldMaxKeyCode
        w.writeU8(0) // requestMajor
        w.writeU8(0) // requestMinor
        w.writeU16(0x01) // changed: Keycodes
        w.writeU8(0) // detail
        w.writePadding(13)
        return w.bytes
    }

    static func mapNotify(eventBase: UInt8, sequence: UInt16, time: UInt32, littleEndian: Bool) -> [UInt8] {
        let minKC = X11KeyCodes.min, nKeys = UInt8(X11KeyCodes.count)
        let w = X11ByteWriter(littleEndian: littleEndian)
        w.writeU8(eventBase)
        w.writeU8(EventType.mapNotify)
        w.writeU16(sequence)
        w.writeU32(time)
        w.writeU8(deviceID)
        w.writeU8(0) // ptrBtnActions
        w.writeU16(MapPart.all) // changed
        w.writeU8(minKC)
        w.writeU8(X11KeyCodes.max)
        w.writeU8(0) // firstType
        w.writeU8(UInt8(types.count))
        for _ in 0..<6 { // keysyms, actions, behaviors, explicit, modmap, vmodmap ranges
            w.writeU8(minKC)
            w.writeU8(nKeys)
        }
        w.writeU16(0xFFFF) // virtualMods
        w.writePadding(2)
        return w.bytes
    }
}

/// One connection's `XkbSelectEvents` choices.
///
/// The request is a variable-length list of (affect, values) mask pairs,
/// one per selected event type, each 1, 2 or 4 bytes wide depending on the
/// type. Reading it wrong doesn't just misread one mask - every later pair
/// shifts - so this follows `ProcXkbSelectEvents` exactly, including its
/// quirk that one-byte masks still occupy a four-byte slot.
struct X11XkbEventSelection: Equatable {
    var newKeyboard: UInt32 = 0
    var map: UInt16 = 0
    var state: UInt32 = 0

    mutating func apply(body: [UInt8], littleEndian: Bool) {
        let r = X11ByteReader(body, littleEndian: littleEndian)
        r.skip(2) // deviceSpec
        let affectWhich = r.readU16()
        let clear = r.readU16()
        let selectAll = r.readU16()
        let affectMap = r.readU16()
        let mapValues = r.readU16()
        if affectWhich & (1 << 1) != 0, affectMap != 0 {
            map = (map & ~affectMap) | (affectMap & mapValues)
        }
        var remaining = affectWhich & ~(1 << 1)
        var index: UInt16 = 0
        while remaining != 0 {
            let bit: UInt16 = 1 << index
            defer { index += 1 }
            guard remaining & bit != 0 else { continue }
            remaining &= ~bit
            let size: Int
            switch index {
            case 0, 2, 6, 10, 11: size = 2
            case 3, 4, 5: size = 4
            case 7, 8, 9: size = 1
            default: return
            }
            var value: UInt32
            if clear & bit != 0 {
                value = 0
            } else if selectAll & bit != 0 {
                value = 0xFFFF_FFFF
            } else {
                let affect: UInt32, values: UInt32
                switch size {
                case 4: affect = r.readU32(); values = r.readU32()
                case 2: affect = UInt32(r.readU16()); values = UInt32(r.readU16())
                default: affect = UInt32(r.readU8()); values = UInt32(r.readU8()); r.skip(2)
                }
                let current = index == 0 ? newKeyboard : (index == 2 ? state : 0)
                value = (current & ~affect) | (affect & values)
            }
            if index == 0 { newKeyboard = value }
            if index == 2 { state = value }
        }
    }
}
