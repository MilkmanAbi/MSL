import XCTest
@testable import MSLCore

/// The keymap's replies, checked the way the clients that failed on them
/// check them: every `FAIL_UNLESS` in libxkbcommon's `src/x11/keymap.c`
/// (the loader behind every Qt app, and Krita's "failed to compile a
/// keymap") is repeated here against the bytes mslgd actually sends.
final class X11KeymapTests: XCTestCase {
    // MARK: - Fixtures

    /// A small but honest US layout: letters with case, digits with their
    /// shifted symbols, and a few Option-layer characters including a dead
    /// key - the shapes that decide key types.
    private static func usLayout() -> X11LayoutSource {
        let letters: [UInt16: Character] = [
            0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x08: "c", 0x09: "v", 0x0C: "q", 0x0E: "e", 0x06: "z",
        ]
        let digits: [UInt16: (String, String)] = [0x12: ("1", "!"), 0x13: ("2", "@"), 0x1B: ("-", "_")]
        return X11LayoutSource(name: "English (US)") { mac, shift, option in
            if option {
                switch mac {
                case 0x00: return .text(shift ? "Å" : "å")
                case 0x0E: return .dead(accent: "´")
                case 0x13: return .text(shift ? "€" : "™")
                default: return nil
                }
            }
            if let letter = letters[mac] { return .text(shift ? String(letter).uppercased() : String(letter)) }
            if let pair = digits[mac] { return .text(shift ? pair.1 : pair.0) }
            return nil
        }
    }

    private static func russianLayout() -> X11LayoutSource {
        let letters: [UInt16: String] = [0x00: "ф", 0x08: "с", 0x09: "м"]
        return X11LayoutSource(name: "Russian") { mac, shift, option in
            guard !option, let letter = letters[mac] else { return nil }
            return .text(shift ? letter.uppercased() : letter)
        }
    }

    private final class Atoms {
        var byName: [String: UInt32] = [:]
        func intern(_ name: String) -> UInt32 {
            if let atom = byName[name] { return atom }
            let atom = UInt32(100 + byName.count)
            byName[name] = atom
            return atom
        }
    }

    private func getMapRequest(full: UInt16) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: true)
        w.writeU16(0x100) // XkbUseCoreKbd
        w.writeU16(full)
        w.writeU16(0) // partial
        w.writePadding(8)
        w.writeU16(0) // virtualMods
        w.writePadding(8)
        return w.bytes
    }

    private func namesRequest(which: UInt32) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: true)
        w.writeU16(0x100)
        w.writePadding(2)
        w.writeU32(which)
        return w.bytes
    }

    /// Checks the generic reply framing and hands back a reader positioned
    /// after the 8-byte header.
    private func openReply(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> X11ByteReader {
        XCTAssertEqual(bytes.first, 1, "not a reply", file: file, line: line)
        let r = X11ByteReader(bytes, littleEndian: true)
        r.skip(4)
        let length = Int(r.readU32())
        XCTAssertEqual(bytes.count, 32 + length * 4, "reply length field disagrees with the bytes sent", file: file, line: line)
        return r
    }

    // MARK: - Keycodes

    func testEveryMacKeyHasItsOwnKeycodeAndAValidName() {
        var seen: [UInt8: UInt16] = [:]
        for (mac, entry) in X11KeyCodes.macKeys {
            XCTAssertNil(seen[entry.keycode], "Mac keys \(mac) and \(seen[entry.keycode] ?? 0) share keycode \(entry.keycode)")
            seen[entry.keycode] = mac
            XCTAssertTrue((X11KeyCodes.min...X11KeyCodes.max).contains(entry.keycode))
        }
        var names = Set<String>()
        for keycode in X11KeyCodes.min...X11KeyCodes.max {
            let name = X11KeyCodes.name(forKeycode: keycode)
            XCTAssertLessThanOrEqual(name.utf8.count, 4, name)
            XCTAssertTrue(names.insert(name).inserted, "duplicate key name \(name)")
        }
    }

    func testKeycodesAreLinuxEvdevNumbers() {
        // The values every Linux X server reports - Wine, SDL and Electron
        // hard-code these.
        XCTAssertEqual(X11KeyCodes.keycode(forMac: 0x00), 38) // a
        XCTAssertEqual(X11KeyCodes.keycode(forMac: 0x35), 9) // Escape
        XCTAssertEqual(X11KeyCodes.keycode(forMac: 0x24), 36) // Return
        XCTAssertEqual(X11KeyCodes.keycode(forMac: 0x37), 133) // Command -> Super_L
        XCTAssertEqual(X11KeyCodes.macKeyCode(forKeycode: 38), 0x00)
    }

    // MARK: - Keysyms and types

    func testCharactersBeyondLatin1GetUnicodeKeysyms() {
        XCTAssertEqual(X11Keysym.forText("a"), 0x61)
        XCTAssertEqual(X11Keysym.forText("é"), 0xE9)
        XCTAssertEqual(X11Keysym.forText("ф"), 0x0100_0444)
        XCTAssertEqual(X11Keysym.forText("€"), 0x0100_20AC)
        XCTAssertNil(X11Keysym.forText("\r"))
        XCTAssertEqual(X11Keysym.deadKey(forSpacingAccent: "´"), 0xFE51)
        XCTAssertTrue(X11Keysym.isCasePair(0x0100_0444, 0x0100_0424))
        XCTAssertFalse(X11Keysym.isCasePair(0x31, 0x21))
    }

    func testLayoutLevelsPickTheNarrowestType() {
        let keymap = X11Keymap(primary: Self.usLayout())
        // "s": letter, nothing on Option -> ALPHABETIC so Caps Lock applies.
        XCTAssertEqual(keymap.keys[39], [X11KeyGroup(type: X11Keymap.TypeIndex.alphabetic, syms: [0x73, 0x53])])
        // "a" with å/Å on Option -> four levels, Caps reaching only the letters.
        XCTAssertEqual(keymap.keys[38], [X11KeyGroup(type: X11Keymap.TypeIndex.fourLevelSemiAlphabetic, syms: [0x61, 0x41, 0xE5, 0xC5])])
        // "e" with a dead acute on Option.
        XCTAssertEqual(keymap.keysym(keycode: 26, mods: X11ModMask.mod5), 0xFE51)
        // "2": not a letter.
        XCTAssertEqual(keymap.keys[11]?.first?.type, X11Keymap.TypeIndex.fourLevel)
        XCTAssertEqual(keymap.keysym(keycode: 11, mods: X11ModMask.shift), 0x40)
        XCTAssertEqual(keymap.keysym(keycode: 11, mods: X11ModMask.shift | X11ModMask.mod5), 0x0100_20AC)
        // Caps Lock uppercases a letter but not a digit.
        XCTAssertEqual(keymap.keysym(keycode: 39, mods: X11ModMask.lock), 0x53)
        XCTAssertEqual(keymap.keysym(keycode: 11, mods: X11ModMask.lock), 0x32)
        // Fixed keys don't depend on the layout at all.
        XCTAssertEqual(keymap.keysym(keycode: 23, mods: 0), X11Keysym.tab)
        XCTAssertEqual(keymap.keysym(keycode: 23, mods: X11ModMask.shift), X11Keysym.isoLeftTab)
        XCTAssertEqual(keymap.keysym(keycode: X11KeyCodes.Virtual.print, mods: 0), X11Keysym.print)
    }

    func testOptionKeyModes() {
        let m = X11KeyCodes.Modifier.self
        let pc = X11Keymap(primary: Self.usLayout(), optionMode: .leftAltRightAltGr)
        XCTAssertEqual(pc.keysym(keycode: m.leftOption, mods: 0), X11Keysym.altL)
        XCTAssertEqual(pc.modMap[m.leftOption], X11ModMask.mod1)
        XCTAssertEqual(pc.keysym(keycode: m.rightOption, mods: 0), X11Keysym.isoLevel3Shift)
        XCTAssertEqual(pc.modMap[m.rightOption], X11ModMask.mod5)

        let alt = X11Keymap(primary: Self.usLayout(), optionMode: .bothAlt)
        XCTAssertEqual(alt.modMap[m.rightOption], X11ModMask.mod1)
        // With no AltGr there is no third level to put Option characters on.
        XCTAssertEqual(alt.keys[38]?.first?.type, X11Keymap.TypeIndex.alphabetic)

        let mac = X11Keymap(primary: Self.usLayout(), optionMode: .bothAltGr)
        XCTAssertEqual(mac.modMap[m.leftOption], X11ModMask.mod5)
        XCTAssertFalse(mac.modMap.values.contains(X11ModMask.mod1))
    }

    func testCommandIsSuperOnMod4() {
        let keymap = X11Keymap(primary: Self.usLayout())
        XCTAssertEqual(keymap.keysym(keycode: X11KeyCodes.Modifier.leftCommand, mods: 0), X11Keysym.superL)
        XCTAssertEqual(keymap.modMap[X11KeyCodes.Modifier.leftCommand], X11ModMask.mod4)
        XCTAssertEqual(keymap.modMap[X11KeyCodes.Modifier.rightCommand], X11ModMask.mod4)
        XCTAssertFalse(keymap.repeats(X11KeyCodes.Modifier.leftCommand))
        XCTAssertTrue(keymap.repeats(38))
    }

    func testNonLatinLayoutCarriesALatinGroupForShortcuts() {
        let keymap = X11Keymap(primary: Self.russianLayout(), latinFallback: Self.usLayout())
        XCTAssertEqual(keymap.numGroups, 2)
        XCTAssertEqual(keymap.groupNames, ["Russian", "English (US)"])
        // Keycode 54 is "c": Cyrillic "с" first, Latin "c" in group 2.
        XCTAssertEqual(keymap.keysym(keycode: 54, group: 0, mods: 0), 0x0100_0441)
        XCTAssertEqual(keymap.keysym(keycode: 54, group: 1, mods: 0), 0x63)
        XCTAssertEqual(keymap.coreKeysyms(for: 54)[2], 0x63)

        // A Latin layout never grows a pointless copy of itself.
        XCTAssertEqual(X11Keymap(primary: Self.usLayout(), latinFallback: Self.usLayout()).numGroups, 1)
    }

    // MARK: - Core replies

    func testCoreModifierMappingHasTwoKeysPerModifier() {
        let bytes = X11Keymap(primary: Self.usLayout()).modifierMappingReply(sequence: 7, littleEndian: true)
        let r = openReply(bytes)
        XCTAssertEqual(bytes[1], 2) // keycodes per modifier
        r.skip(24)
        let slots = r.readBytes(16)
        XCTAssertEqual(Array(slots[0..<2]), [50, 62]) // Shift
        XCTAssertEqual(Array(slots[2..<4]), [66, 0]) // Lock
        XCTAssertEqual(Array(slots[4..<6]), [37, 105]) // Control
        XCTAssertEqual(Array(slots[6..<8]), [64, 0]) // Mod1: left Option
        XCTAssertEqual(Array(slots[12..<14]), [133, 134]) // Mod4: Command
        XCTAssertEqual(Array(slots[14..<16]), [108, 0]) // Mod5: right Option
    }

    func testCoreKeyboardMappingColumns() {
        let keymap = X11Keymap(primary: Self.usLayout())
        let bytes = keymap.keyboardMappingReply(firstKeycode: 38, count: 2, sequence: 1, littleEndian: true)
        let r = openReply(bytes)
        XCTAssertEqual(bytes[1], 6)
        r.skip(24)
        XCTAssertEqual((0..<6).map { _ in r.readU32() }, [0x61, 0x41, 0x61, 0x41, 0xE5, 0xC5])
        XCTAssertEqual((0..<6).map { _ in r.readU32() }, [0x73, 0x53, 0x73, 0x53, 0, 0])
    }

    // MARK: - XKB replies, against libxkbcommon's rules

    func testGetMapSatisfiesLibxkbcommon() throws {
        for keymap in [X11Keymap(primary: Self.usLayout()),
                       X11Keymap(primary: Self.russianLayout(), latinFallback: Self.usLayout())] {
            let bytes = keymap.getMapReply(body: getMapRequest(full: 0xFF), sequence: 3, littleEndian: true)
            XCTAssertEqual(bytes[1], X11Keymap.deviceID)
            let r = openReply(bytes)
            r.skip(2)
            let minKC = r.readU8(), maxKC = r.readU8()
            let present = r.readU16()
            let firstType = r.readU8(), nTypes = r.readU8()
            _ = r.readU8()
            let firstKeySym = r.readU8()
            let totalSyms = Int(r.readU16())
            let nKeySyms = r.readU8()
            let firstKeyAct = r.readU8()
            let totalActs = Int(r.readU16())
            let nKeyActs = r.readU8()
            _ = r.readU8(); _ = r.readU8()
            let totalBehaviors = Int(r.readU8())
            _ = r.readU8(); _ = r.readU8()
            let totalExplicit = Int(r.readU8())
            _ = r.readU8(); _ = r.readU8()
            let totalModMap = Int(r.readU8())
            _ = r.readU8(); _ = r.readU8()
            let totalVModMap = Int(r.readU8())
            _ = r.readU8()
            let virtualMods = r.readU16()

            XCTAssertEqual(present, 0xFF)
            XCTAssertLessThanOrEqual(minKC, maxKC) // get_sym_maps
            XCTAssertEqual(firstType, 0) // get_types

            var levelsPerType: [Int] = []
            for _ in 0..<nTypes {
                _ = r.readU8(); _ = r.readU8(); _ = r.readU16()
                let numLevels = Int(r.readU8())
                let nEntries = Int(r.readU8())
                let preserve = r.readU8()
                _ = r.readU8()
                XCTAssertGreaterThan(numLevels, 0)
                XCTAssertEqual(preserve, 0)
                for _ in 0..<nEntries {
                    _ = r.readU8(); _ = r.readU8()
                    XCTAssertLessThan(Int(r.readU8()), numLevels)
                    _ = r.readU8(); _ = r.readU16(); r.skip(2)
                }
                levelsPerType.append(numLevels)
            }

            XCTAssertGreaterThanOrEqual(firstKeySym, minKC)
            XCTAssertLessThanOrEqual(Int(firstKeySym) + Int(nKeySyms), Int(maxKC) + 1)
            var symCount = 0
            var symsPerKey: [Int] = []
            for _ in 0..<nKeySyms {
                let ktIndex = (0..<4).map { _ in Int(r.readU8()) }
                let groupInfo = r.readU8()
                let width = Int(r.readU8())
                let nSyms = Int(r.readU16())
                let groups = Int(groupInfo & 0x0F)
                XCTAssertLessThanOrEqual(groups, 4)
                for g in 0..<groups {
                    XCTAssertLessThan(ktIndex[g], levelsPerType.count)
                    XCTAssertLessThanOrEqual(levelsPerType[ktIndex[g]], width)
                }
                XCTAssertEqual(nSyms, width * groups)
                r.skip(nSyms * 4)
                symCount += nSyms
                symsPerKey.append(nSyms)
            }
            XCTAssertEqual(symCount, totalSyms)

            XCTAssertEqual(firstKeyAct, minKC) // get_actions
            XCTAssertEqual(Int(firstKeyAct) + Int(nKeyActs), Int(maxKC) + 1)
            let counts = r.readBytes(Int(nKeyActs))
            r.skip(X11Wire.pad(Int(nKeyActs)) - Int(nKeyActs))
            var actionCount = 0
            for (i, count) in counts.enumerated() {
                XCTAssertTrue(count == 0 || Int(count) == symsPerKey[i], "keycode \(Int(minKC) + i): \(count) actions for \(symsPerKey[i]) syms")
                actionCount += Int(count)
            }
            XCTAssertEqual(actionCount, totalActs)
            for _ in 0..<totalActs {
                let action = r.readBytes(8)
                XCTAssertTrue([0x00, 0x01, 0x03].contains(action[0]))
            }
            XCTAssertEqual(totalBehaviors, 0)

            XCTAssertEqual(virtualMods, 0xFFFF)
            r.skip(X11Wire.pad(16))

            for _ in 0..<totalExplicit {
                XCTAssertTrue((minKC...maxKC).contains(r.readU8())) // get_explicits
                _ = r.readU8()
            }
            r.skip(X11Wire.pad(totalExplicit * 2) - totalExplicit * 2)
            var modMap: [UInt8: UInt8] = [:]
            for _ in 0..<totalModMap {
                let keycode = r.readU8()
                XCTAssertTrue((minKC...maxKC).contains(keycode)) // get_modmaps
                modMap[keycode] = r.readU8()
            }
            r.skip(X11Wire.pad(totalModMap * 2) - totalModMap * 2)
            XCTAssertEqual(modMap, keymap.modMap)
            for _ in 0..<totalVModMap {
                XCTAssertTrue((minKC...maxKC).contains(r.readU8())) // get_vmodmaps
                r.skip(3)
            }
            XCTAssertEqual(r.remaining, 0, "trailing bytes after the last map component")
        }
    }

    func testGetMapHonoursPartialRequests() {
        let keymap = X11Keymap(primary: Self.usLayout())
        let clientParts: UInt16 = 0x07 // types, syms, modmap - what GDK asks for
        let bytes = keymap.getMapReply(body: getMapRequest(full: clientParts), sequence: 1, littleEndian: true)
        let r = openReply(bytes)
        r.skip(4)
        XCTAssertEqual(r.readU16(), clientParts)
    }

    func testGetNamesSatisfiesLibxkbcommon() {
        let atoms = Atoms()
        for keymap in [X11Keymap(primary: Self.usLayout()),
                       X11Keymap(primary: Self.russianLayout(), latinFallback: Self.usLayout())] {
            // libxkbcommon's get_names_wanted.
            let wanted: UInt32 = 0x01 | 0x04 | 0x10 | 0x20 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x1000
            let bytes = keymap.getNamesReply(body: namesRequest(which: wanted), sequence: 9, littleEndian: true, intern: atoms.intern)
            let r = openReply(bytes)
            let which = r.readU32()
            let minKC = r.readU8(), maxKC = r.readU8()
            let nTypes = Int(r.readU8())
            let groupNames = r.readU8()
            let virtualMods = r.readU16()
            let firstKey = r.readU8()
            let nKeys = Int(r.readU8())
            let indicators = r.readU32()
            let nRadioGroups = r.readU8(), nKeyAliases = r.readU8()
            let nKTLevels = Int(r.readU16())
            r.skip(4)

            let required: UInt32 = 0x40 | 0x80 | 0x200 | 0x800
            XCTAssertEqual(which & required, required)
            XCTAssertEqual(nTypes, X11Keymap.types.count)
            XCTAssertEqual(firstKey, minKC)
            XCTAssertEqual(Int(firstKey) + nKeys - 1, Int(maxKC))
            XCTAssertEqual(nRadioGroups, 0)
            XCTAssertEqual(nKeyAliases, 0)

            r.skip(4 * 4) // keycodes, symbols, types, compat
            let typeNames = (0..<nTypes).map { _ in r.readU32() }
            XCTAssertEqual(typeNames, X11Keymap.types.map { atoms.intern($0.name) })
            let levels = r.readBytes(nTypes)
            r.skip(X11Wire.pad(nTypes) - nTypes)
            XCTAssertEqual(levels.map(Int.init), X11Keymap.types.map(\.levels)) // levels <= num_levels
            XCTAssertEqual(levels.reduce(0) { $0 + Int($1) }, nKTLevels)
            r.skip(nKTLevels * 4)

            XCTAssertLessThanOrEqual(32 - indicators.leadingZeroBitCount, 32) // msb_pos <= num_leds
            r.skip(indicators.nonzeroBitCount * 4)
            XCTAssertLessThanOrEqual(4 + 16 - virtualMods.leadingZeroBitCount, 20)
            XCTAssertEqual(virtualMods.nonzeroBitCount, X11Keymap.virtualMods.count)
            r.skip(virtualMods.nonzeroBitCount * 4)
            XCTAssertEqual(groupNames.nonzeroBitCount, keymap.numGroups)
            r.skip(groupNames.nonzeroBitCount * 4)
            let keyNames = (0..<nKeys).map { _ in String(decoding: r.readBytes(4).prefix { $0 != 0 }, as: UTF8.self) }
            XCTAssertEqual(keyNames[38 - 8], "AC01")
            XCTAssertEqual(keyNames[133 - 8], "LWIN")
            XCTAssertEqual(r.remaining, 0)
        }
    }

    func testControlsReportGroupsRepeatAndPerKeyRepeat() {
        var keymap = X11Keymap(primary: Self.russianLayout(), latinFallback: Self.usLayout())
        keymap.repeatDelayMs = 250
        keymap.repeatIntervalMs = 30
        let bytes = keymap.getControlsReply(sequence: 2, littleEndian: true)
        XCTAssertEqual(bytes.count, 92) // sz_xkbGetControlsReply
        let r = openReply(bytes)
        _ = r.readU8()
        let numGroups = r.readU8()
        XCTAssertTrue(numGroups > 0 && numGroups <= 4) // get_controls
        XCTAssertEqual(numGroups, 2)
        r.skip(10)
        XCTAssertEqual(r.readU16(), 250)
        XCTAssertEqual(r.readU16(), 30)
        r.skip(36) // slowKeysDelay .. enabledCtrls
        let perKey = r.readBytes(32)
        func repeats(_ keycode: Int) -> Bool { perKey[keycode / 8] & (1 << (keycode % 8)) != 0 }
        XCTAssertTrue(repeats(38))
        XCTAssertFalse(repeats(50)) // Shift
        XCTAssertFalse(repeats(133)) // Command
    }

    func testIndicatorAndCompatMapsParse() {
        let keymap = X11Keymap(primary: Self.usLayout())
        let request = X11ByteWriter(littleEndian: true)
        request.writeU16(0x100); request.writePadding(2); request.writeU32(0xFFFF_FFFF)
        let indicators = keymap.getIndicatorMapReply(body: request.bytes, sequence: 4, littleEndian: true)
        let r = openReply(indicators)
        XCTAssertEqual(r.readU32(), 0xFFFF_FFFF)
        _ = r.readU32()
        XCTAssertEqual(r.readU8(), 32)
        XCTAssertEqual(indicators.count, 32 + 32 * 12)

        let compatRequest = X11ByteWriter(littleEndian: true)
        compatRequest.writeU16(0x100); compatRequest.writeU8(0); compatRequest.writeU8(1); compatRequest.writeU16(0); compatRequest.writeU16(0)
        let compat = keymap.getCompatMapReply(body: compatRequest.bytes, sequence: 5, littleEndian: true)
        let c = openReply(compat)
        c.skip(2)
        XCTAssertEqual(c.readU16(), 0) // firstSIRtrn == 0
        XCTAssertEqual(c.readU16(), c.readU16()) // nSIRtrn == nTotalSI
    }

    func testRepliesAreByteOrderAware() {
        let keymap = X11Keymap(primary: Self.usLayout())
        let little = keymap.getMapReply(body: getMapRequest(full: 0xFF), sequence: 0x0102, littleEndian: true)
        let bigRequest = X11ByteWriter(littleEndian: false)
        bigRequest.writeU16(0x100); bigRequest.writeU16(0xFF); bigRequest.writeU16(0); bigRequest.writePadding(8)
        bigRequest.writeU16(0); bigRequest.writePadding(8)
        let big = keymap.getMapReply(body: bigRequest.bytes, sequence: 0x0102, littleEndian: false)
        XCTAssertEqual(little.count, big.count)
        XCTAssertEqual(Array(big[2..<4]), [0x01, 0x02])
        XCTAssertEqual(Array(little[2..<4]), [0x02, 0x01])
    }

    func testStateNotifyIsThirtyTwoBytesAndCarriesMods() {
        let snapshot = X11KeyboardSnapshot(baseMods: X11ModMask.mod4, lockedMods: X11ModMask.lock)
        let event = X11Keymap.stateNotify(snapshot, changed: 1, keycode: 133, eventType: 2, eventBase: 92, sequence: 1, time: 5, littleEndian: true)
        XCTAssertEqual(event.count, 32)
        XCTAssertEqual(event[8], X11Keymap.deviceID)
        XCTAssertEqual(event[9], X11ModMask.mod4 | X11ModMask.lock)
        XCTAssertEqual(X11Keymap.newKeyboardNotify(eventBase: 92, sequence: 1, time: 1, littleEndian: true).count, 32)
        XCTAssertEqual(X11Keymap.mapNotify(eventBase: 92, sequence: 1, time: 1, littleEndian: true).count, 32)
        XCTAssertEqual(X11Keymap.mappingNotify(request: 1, sequence: 1, littleEndian: true).count, 32)
    }

    // MARK: - SelectEvents and per-client flags

    func testSelectEventsParsesDetailPairsInOrder() {
        var selection = X11XkbEventSelection()
        let w = X11ByteWriter(littleEndian: true)
        w.writeU16(0x100)
        w.writeU16(0x01 | 0x02 | 0x04 | 0x08) // NewKeyboard, Map, State, Controls
        w.writeU16(0) // clear
        w.writeU16(0) // selectAll
        w.writeU16(0x07) // affectMap
        w.writeU16(0x07) // map
        w.writeU16(0x0007); w.writeU16(0x0005) // NewKeyboard detail (2+2)
        w.writeU16(0x0FFF); w.writeU16(0x0001) // State detail (2+2)
        w.writeU32(0xFFFF_FFFF); w.writeU32(0) // Controls detail (4+4)
        selection.apply(body: w.bytes, littleEndian: true)
        XCTAssertEqual(selection.newKeyboard, 0x05)
        XCTAssertEqual(selection.map, 0x07)
        XCTAssertEqual(selection.state, 0x01)

        let clear = X11ByteWriter(littleEndian: true)
        clear.writeU16(0x100); clear.writeU16(0x04); clear.writeU16(0x04); clear.writeU16(0); clear.writeU16(0); clear.writeU16(0)
        selection.apply(body: clear.bytes, littleEndian: true)
        XCTAssertEqual(selection.state, 0)
        XCTAssertEqual(selection.newKeyboard, 0x05)
    }

    func testPerClientFlagsApplyTheChangeMask() {
        let w = X11ByteWriter(littleEndian: true)
        w.writeU16(0x100); w.writePadding(2)
        w.writeU32(0x01) // change: DetectableAutoRepeat
        w.writeU32(0x03) // value (bit 1 outside the change mask is ignored)
        w.writePadding(12)
        let result = X11Keymap.perClientFlagsReply(body: w.bytes, current: 0, sequence: 1, littleEndian: true)
        XCTAssertEqual(result.flags, 0x01)
        XCTAssertEqual(result.reply.count, 32)
    }

    // MARK: - Modifier tracking

    func testLeftAndRightModifiersAreTrackedApart() {
        var tracker = X11ModifierTracker()
        let m = X11KeyCodes.Modifier.self
        let commandFlag: UInt = 1 << 20
        // Left Command down.
        XCTAssertEqual(tracker.flagsChanged(keycode: m.leftCommand, rawFlags: commandFlag | 0x08), [.init(keycode: m.leftCommand, pressed: true)])
        // Right Command down too - still Command in AppKit's eyes.
        XCTAssertEqual(tracker.flagsChanged(keycode: m.rightCommand, rawFlags: commandFlag | 0x18), [.init(keycode: m.rightCommand, pressed: true)])
        // Left released while right is held: the generic flag stays set.
        XCTAssertEqual(tracker.flagsChanged(keycode: m.leftCommand, rawFlags: commandFlag | 0x10), [.init(keycode: m.leftCommand, pressed: false)])
        XCTAssertEqual(tracker.held, [m.rightCommand])
        // A duplicate report changes nothing.
        XCTAssertEqual(tracker.flagsChanged(keycode: m.rightCommand, rawFlags: commandFlag | 0x10), [])
    }

    func testRightOptionIsAltGrInTheSnapshot() {
        var tracker = X11ModifierTracker()
        let keymap = X11Keymap(primary: Self.usLayout())
        _ = tracker.flagsChanged(keycode: X11KeyCodes.Modifier.rightOption, rawFlags: (1 << 19) | 0x40)
        XCTAssertEqual(tracker.snapshot(modMap: keymap.modMap).baseMods, X11ModMask.mod5)
    }

    func testFlagsWithoutDeviceBitsCountAsTheLeftKey() {
        var tracker = X11ModifierTracker()
        XCTAssertEqual(tracker.flagsChanged(keycode: X11KeyCodes.Modifier.leftShift, rawFlags: 1 << 17),
                       [.init(keycode: X11KeyCodes.Modifier.leftShift, pressed: true)])
    }

    func testCapsLockIsAPressReleasePairPerToggle() {
        var tracker = X11ModifierTracker()
        let caps = X11KeyCodes.Modifier.capsLock
        XCTAssertEqual(tracker.flagsChanged(keycode: caps, rawFlags: X11ModifierTracker.capsLockFlag),
                       [.init(keycode: caps, pressed: true), .init(keycode: caps, pressed: false)])
        XCTAssertTrue(tracker.capsLocked)
        XCTAssertEqual(tracker.snapshot(modMap: [:]).lockedMods, X11ModMask.lock)
        XCTAssertEqual(tracker.flagsChanged(keycode: caps, rawFlags: 0).count, 2)
        XCTAssertFalse(tracker.capsLocked)
    }

    func testResyncAndReleaseAllRecoverFromMissedEvents() {
        var tracker = X11ModifierTracker()
        let m = X11KeyCodes.Modifier.self
        _ = tracker.flagsChanged(keycode: m.leftControl, rawFlags: (1 << 18) | 0x01)
        // Control went up while another app had the keyboard; Shift came
        // down. The next event this window sees says so.
        let changes = tracker.resync(rawFlags: (1 << 17) | 0x02)
        XCTAssertEqual(Set(changes.map(\.keycode)), [m.leftControl, m.leftShift])
        XCTAssertEqual(tracker.held, [m.leftShift])
        XCTAssertEqual(tracker.releaseAll(), [.init(keycode: m.leftShift, pressed: false)])
        XCTAssertTrue(tracker.held.isEmpty)
    }
}
