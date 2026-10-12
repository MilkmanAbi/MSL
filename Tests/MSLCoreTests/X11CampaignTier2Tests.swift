import XCTest
@testable import MSLCore

/// Tier-2 findings from `READMES/MSLGD-CAMPAIGN.md`.
final class X11CampaignTier2Tests: XCTestCase {
    private func crossing(deviceid: UInt16 = XIDeviceUse.corePointerID,
                          mods: X11KeyboardSnapshot = X11KeyboardSnapshot(),
                          buttons: Set<UInt8> = []) -> [UInt8] {
        X11Connection.xiCrossingEventBytes(
            evtype: XIEventType.enter, deviceid: deviceid, sequence: 7, time: 1234,
            detail: 3, focus: 0, root: 0x400, event: 0x401,
            rootX: 100, rootY: 50, x: 10, y: 5,
            mods: mods, buttons: buttons, littleEndian: true)
    }

    // MARK: K1 — the length field and the byte count must agree

    /// This is the landmine, not the fix. `length` counts 4-byte units
    /// past the 32-byte header, and it is written forty lines away from
    /// the bytes it describes. When the two disagreed the symptom was not
    /// a wrong event - it was every *later* event in the stream being
    /// misframed, which reads as the client behaving arbitrarily.
    func testTheDeclaredLengthMatchesTheBytesActuallyWritten() {
        let bytes = crossing()
        let declared = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        XCTAssertEqual(bytes.count, 32 + Int(declared) * 4,
                       "declared length \(declared) vs \(bytes.count) bytes on the wire")
        XCTAssertEqual(bytes.count, 76, "xXIEnterEvent (72) plus one 4-byte button mask")
    }

    /// GDK3 builds its button state for XI2 events only from this mask, so
    /// a crossing while a button was held used to report nothing held -
    /// dragging a slider off its widget, DND entering a target.
    func testAHeldButtonIsVisibleInACrossingEvent() {
        let idle = crossing()
        let dragging = crossing(buttons: [1])
        XCTAssertEqual(Array(idle.suffix(4)), [0, 0, 0, 0])
        XCTAssertEqual(Array(dragging.suffix(4)), [0x02, 0, 0, 0], "button 1 is bit 1")
        XCTAssertEqual(idle.count, dragging.count)
    }

    func testButtonsLenIsDeclaredAsOneUnit() {
        XCTAssertEqual(crossing()[50], 1, "buttons_len low byte")
        XCTAssertEqual(crossing()[51], 0)
    }

    // MARK: K2 — modifier state, for keyboards only

    /// xorg fills these from the device's XKB state but guards the whole
    /// block on `if (dev->key)`, so a pointer writes zeros there and a
    /// keyboard does not. Matching that exactly, rather than being
    /// generous with it, is the point.
    func testFocusEventsCarryModifiersAndCrossingEventsDoNot() {
        var shifted = X11KeyboardSnapshot()
        shifted.baseMods = 0x01

        let fromKeyboard = crossing(deviceid: XIDeviceUse.coreKeyboardID, mods: shifted)
        XCTAssertEqual(fromKeyboard[52], 0x01, "mods.base_mods")
        XCTAssertEqual(fromKeyboard[64], 0x01, "mods.effective_mods")

        // The pointer path passes an empty snapshot, as xorg does.
        let fromPointer = crossing(deviceid: XIDeviceUse.corePointerID)
        XCTAssertEqual(fromPointer[52], 0)
        XCTAssertEqual(fromPointer[64], 0)
    }

    // MARK: C1 — the event trace can see XI2 at all

    /// The inline check this replaced required exactly 32 bytes, so it
    /// never once logged an XI2 event - leaving the subsystem with the
    /// most findings as the one the trace could not see.
    func testTheTraceAcceptsBothEventShapes() {
        // Not asserting on the emitted text (it only writes when the env
        // var is set); asserting it doesn't reject the shapes by length.
        XCTAssertGreaterThanOrEqual(crossing().count, 32)
        X11Trace.event(crossing(), littleEndian: true)
        X11Trace.event([UInt8](repeating: 0, count: 32), littleEndian: true)
    }

    func testTheOpcodeFilterParsesAList() {
        XCTAssertTrue(X11Trace.tracedOpcodes.isEmpty, "unset means trace everything")
    }

    /// `buttons_len` sits at 48 in a device event and 50 in a crossing
    /// event, and the byte count cannot tell the two apart. Reading the
    /// wrong one printed `buttonsLen=0` for every motion event while the
    /// code was plainly writing 1 - which would have sent the next person
    /// hunting a fix that was already in.
    // MARK: N1 — host slots cannot wrap onto another host's IDs

    /// A client index is the top 11 bits of every resource ID its
    /// connection mints, so it must stay <= 2047. Swift masks an over-wide
    /// shift rather than trapping, so slot 64 would seed index 2049 and
    /// `UInt32(2049) << 21` lands on `1 << 21` - the base the FIRST host
    /// already owns. Two processes minting identical window IDs is
    /// `gui-bugs.md` #36, already fixed here once.
    func testTheLastHostSlotStillFitsTheResourceIdSpace() {
        let lastIndex = X11AppRouter.maxHostSlot * X11State.clientIndexStride + 1
        XCTAssertLessThanOrEqual(lastIndex, X11State.maxClientIndex)
        XCTAssertEqual(X11AppRouter.maxHostSlot, 63)

        // And one slot further is exactly the wrap this guards against.
        let overflowed = (X11AppRouter.maxHostSlot + 1) * X11State.clientIndexStride + 1
        XCTAssertGreaterThan(overflowed, X11State.maxClientIndex)
        XCTAssertEqual(UInt32(overflowed) << 21, UInt32(1) << 21, "wraps onto the first host")
    }

    func testTheButtonMaskLengthIsWhereEachShapePutsIt() {
        let crossingBytes = crossing()
        XCTAssertEqual(crossingBytes[50], 1, "xXIEnterEvent buttons_len @50")

        // A device event's mask length lands after four FP1616 coordinates
        // rather than after same_screen/focus.
        let deviceLayoutOffset = 32 + 16
        XCTAssertEqual(deviceLayoutOffset, 48)
    }
}

/// CL1 — the selection timestamp, which had nowhere to come from.
final class X11SelectionTimestampTests: XCTestCase {
    func testOwnershipRecordsWhenItWasTaken() {
        let state = X11State()
        let selection: UInt32 = 0x1234
        XCTAssertTrue(state.setSelectionOwner(selection, owner: 0x100, time: 5_000))
        XCTAssertEqual(state.selectionTime(selection), 5_000)
        XCTAssertEqual(state.selectionOwner(selection), 0x100)
    }

    /// The protocol says to ignore a claim whose time is earlier than the
    /// selection's current last-change time. Without a stored time there
    /// was nothing to compare against, so a late-arriving stale claim won.
    func testAStaleClaimIsIgnored() {
        let state = X11State()
        let selection: UInt32 = 0x1234
        state.setSelectionOwner(selection, owner: 0x100, time: 5_000)
        XCTAssertFalse(state.setSelectionOwner(selection, owner: 0x200, time: 4_999))
        XCTAssertEqual(state.selectionOwner(selection), 0x100, "the newer claim keeps it")

        XCTAssertTrue(state.setSelectionOwner(selection, owner: 0x300, time: 5_001))
        XCTAssertEqual(state.selectionOwner(selection), 0x300)
    }

    /// CurrentTime means "now" and always wins, as it does in xorg.
    func testCurrentTimeAlwaysWins() {
        let state = X11State()
        let selection: UInt32 = 0x1234
        state.setSelectionOwner(selection, owner: 0x100, time: 9_000)
        XCTAssertTrue(state.setSelectionOwner(selection, owner: 0x200, time: 0))
        XCTAssertEqual(state.selectionOwner(selection), 0x200)
    }

    func testReleasingClearsTheTime() {
        let state = X11State()
        let selection: UInt32 = 0x1234
        state.setSelectionOwner(selection, owner: 0x100, time: 5_000)
        state.setSelectionOwner(selection, owner: 0, time: 6_000)
        XCTAssertEqual(state.selectionOwner(selection), 0)
        XCTAssertEqual(state.selectionTime(selection), 0)
    }
}

/// F10 / F12b — the requests that used to answer `BadImplementation`.
///
/// `BadImplementation` is not a soft failure: Xlib's default error handler
/// exits the process. The log already records this catch-all killing
/// galculator and abiword outright.
final class X11MissingOpcodeTests: XCTestCase {
    /// `ListExtensions` answered "none" while `QueryExtension` said yes to
    /// seven - a direct self-contradiction, and what blocked `xdpyinfo`.
    func testTheAdvertisedExtensionListIsNotEmpty() {
        // Named, not counted: the list grows as extensions land, and a
        // magic number just makes the next person edit a test they have
        // not read. What matters is that everything `QueryExtension`
        // answers "present" for is listed here too - the contradiction
        // between those two is what blocked `xdpyinfo`.
        for name in ["RENDER", "BIG-REQUESTS", "XInputExtension", "XKEYBOARD",
                     "RANDR", "XC-MISC", "SHAPE", "XTEST"] {
            XCTAssertTrue(X11Connection.advertisedExtensions.contains(name), name)
        }
        XCTAssertEqual(Set(X11Connection.advertisedExtensions).count,
                       X11Connection.advertisedExtensions.count, "no duplicates")
    }

    /// A LISTofSTR is each name prefixed by its own length byte, packed
    /// with no padding between entries.
    func testTheExtensionListEncodesAsStringsWithLengthPrefixes() {
        var encoded: [UInt8] = []
        for name in X11Connection.advertisedExtensions {
            encoded.append(UInt8(name.utf8.count))
            encoded += Array(name.utf8)
        }
        // "RENDER" is 6 characters, so the first byte is its length.
        XCTAssertEqual(encoded.first, 6)
        XCTAssertEqual(encoded[1], UInt8(ascii: "R"))
        // Nothing zero-length, or the client would stop reading early.
        var index = 0
        var seen = 0
        while index < encoded.count {
            let length = Int(encoded[index])
            XCTAssertGreaterThan(length, 0)
            index += 1 + length
            seen += 1
        }
        XCTAssertEqual(seen, X11Connection.advertisedExtensions.count)
    }

    /// `GetPointerMapping` answered with an EMPTY map would tell Qt the
    /// pointer has zero buttons - worse than the error it replaced.
    func testThePointerMapIsNotEmpty() {
        XCTAssertEqual(X11Connection.pointerButtonLabels.count, 9)
    }

    /// The vector `QueryKeymap` answers with comes from the same held-key
    /// set the events are built from, so the two cannot disagree.
    func testTheKeymapVectorSetsTheRightBit() {
        let vector = X11KeyboardState.shared.keymapVector
        XCTAssertEqual(vector.count, 32)
    }
}

/// M4 — the A1 glyph stride, which corrupted every glyph after the first.
final class X11A1GlyphStrideTests: XCTestCase {
    /// A1 is one bit per pixel with rows padded to 32 bits. With no A1
    /// branch the reader consumed `w * 4` bytes a row - 8x for an 8-pixel
    /// glyph - and because `AddGlyphs` parses glyphs sequentially out of
    /// one buffer, the first wrong stride desynchronises everything after.
    func testTheStrideFormulasDisagreeExactlyWhereTheyShould() {
        func a1Stride(_ w: Int) -> Int { ((w + 31) / 32) * 4 }
        func a8Stride(_ w: Int) -> Int { ((w * 1 + 3) / 4) * 4 }
        func argbStride(_ w: Int) -> Int { ((w * 4 + 3) / 4) * 4 }

        XCTAssertEqual(a1Stride(8), 4, "8 pixels is one byte, padded to 4")
        XCTAssertEqual(argbStride(8), 32, "what an A1 glyph used to read")
        XCTAssertEqual(a1Stride(32), 4)
        XCTAssertEqual(a1Stride(33), 8, "one bit over is a whole extra unit")
        XCTAssertEqual(a8Stride(8), 8)
    }

    /// And the bits become A8 coverage, because that is what
    /// `CompositeGlyphs` reads.
    func testBitsExpandToCoverageBytes() {
        // One row of 8 pixels, but the row occupies a full 32-bit unit -
        // which is the stride rule, and `expandBitmap` refuses anything
        // else rather than guessing. 0b10000001 LSB-first is pixels 0 and 7.
        let row: [UInt8] = [0x81, 0, 0, 0]
        let coverage = X11Connection.expandBitmap(row, width: 8, height: 1,
                                                  leftPad: 0, lsbFirst: true, rowBytes: 8)
        XCTAssertEqual(coverage, [255, 0, 0, 0, 0, 0, 0, 255])
    }

    /// The padded-row requirement is exactly what the A1 branch in
    /// `AddGlyphs` now satisfies, and what it could not have satisfied
    /// while reading `w * 4` bytes a row.
    func testTheStrideFedToExpandBitmapIsTheOneItDemands() {
        for width in [1, 8, 31, 32, 33, 100] {
            let stride = ((width + 31) / 32) * 4
            let bits = [UInt8](repeating: 0, count: stride * 2)
            let coverage = X11Connection.expandBitmap(bits, width: width, height: 2,
                                                      leftPad: 0, lsbFirst: true, rowBytes: width)
            XCTAssertEqual(coverage.count, width * 2, "width \(width)")
        }
    }
}

/// F2 — sibling stacking order, which used to be a hash-order accident.
final class X11StackingOrderTests: XCTestCase {
    private func state(children: [UInt32], parent: UInt32 = 1) -> X11State {
        let s = X11State()
        _ = s.makeWindow(id: parent, parent: 0, isTopLevel: true, frame: .zero)
        for id in children {
            _ = s.makeWindow(id: id, parent: parent, isTopLevel: false, frame: .zero)
        }
        return s
    }

    private func order(_ s: X11State, parent: UInt32 = 1) -> [UInt32] {
        s.children(ofParent: parent).map(\.id)
    }

    /// Creation order, bottom-to-top, every time - not `Dictionary`
    /// iteration order, which Swift seeds per process and which therefore
    /// differed between runs of the same application.
    func testChildrenComeBackInCreationOrder() {
        for _ in 0..<5 {
            XCTAssertEqual(order(state(children: [10, 11, 12])), [10, 11, 12])
        }
    }

    /// `XRaiseWindow` is `Above` with no sibling. It was a complete no-op.
    func testRaiseMovesToTheTop() {
        let s = state(children: [10, 11, 12])
        s.restack(10, parent: 1, mode: .above, sibling: nil)
        XCTAssertEqual(order(s), [11, 12, 10])
    }

    func testLowerMovesToTheBottom() {
        let s = state(children: [10, 11, 12])
        s.restack(12, parent: 1, mode: .below, sibling: nil)
        XCTAssertEqual(order(s), [12, 10, 11])
    }

    func testAboveAndBelowASpecificSibling() {
        let s = state(children: [10, 11, 12])
        s.restack(10, parent: 1, mode: .above, sibling: 11)
        XCTAssertEqual(order(s), [11, 10, 12])
        s.restack(12, parent: 1, mode: .below, sibling: 11)
        XCTAssertEqual(order(s), [12, 11, 10])
    }

    func testOppositeFlipsTopAndBottom() {
        let s = state(children: [10, 11, 12])
        s.restack(12, parent: 1, mode: .opposite, sibling: nil) // at top -> bottom
        XCTAssertEqual(order(s), [12, 10, 11])
        s.restack(12, parent: 1, mode: .opposite, sibling: nil) // at bottom -> top
        XCTAssertEqual(order(s), [10, 11, 12])
    }

    /// A destroyed window must leave the order, or `children` would keep
    /// handing back an id nothing can resolve.
    func testRemovingAWindowRemovesItFromTheOrder() {
        let s = state(children: [10, 11, 12])
        _ = s.removeWindow(11)
        XCTAssertEqual(order(s), [10, 12])
    }

    func testReparentingMovesTheChildBetweenLists() {
        let s = state(children: [10, 11])
        _ = s.makeWindow(id: 2, parent: 0, isTopLevel: true, frame: .zero)
        s.reparent(11, from: 1, to: 2)
        XCTAssertEqual(order(s), [10])
        XCTAssertEqual(order(s, parent: 2), [11])
    }
}

/// MIT-SCREEN-SAVER — cheap to answer, and several toolkits poll on a
/// timer when it is absent.
final class X11ScreenSaverExtensionTests: XCTestCase {
    func testItIsAdvertisedAlongsideTheRest() {
        XCTAssertTrue(X11Connection.advertisedExtensions.contains("MIT-SCREEN-SAVER"))
    }

    /// Distinct major opcodes, or a request for one extension is dispatched
    /// to another - the kind of bug that presents as an unrelated feature
    /// misbehaving.
    func testExtensionMajorOpcodesAreDistinct() {
        let majors: [UInt8] = [
            X11Opcode.renderExtension, X11Opcode.bigRequestsExtension,
            X11Opcode.xinputExtension, X11Opcode.xkbExtension,
            X11Opcode.randrExtension, X11Opcode.xcMiscExtension,
            X11Opcode.shapeExtension, X11Opcode.xtestExtension,
            X11Opcode.screenSaverExtension, X11Opcode.glxExtension,
            X11Opcode.xfixesExtension,
        ]
        XCTAssertEqual(Set(majors).count, majors.count)
        // Extension majors live at 128...255; a collision with a CORE
        // opcode would silently shadow a real request.
        for major in majors { XCTAssertGreaterThanOrEqual(major, 128, "major \(major)") }
    }

    /// The advertised set, named. `ListExtensions` and `QueryExtension`
    /// answering differently is what blocked `xdpyinfo`, so this pins the
    /// whole list rather than its length - a count tells the next person
    /// to edit a number, not to check a name.
    func testTheAdvertisedSetIsExactlyWhatIsImplemented() {
        XCTAssertEqual(Set(X11Connection.advertisedExtensions), [
            "RENDER", "BIG-REQUESTS", "XInputExtension", "XKEYBOARD",
            "RANDR", "XC-MISC", "SHAPE", "XTEST", "MIT-SCREEN-SAVER", "GLX",
            "XFIXES",
        ])
    }
}

/// XFIXES. The extension exists for one request - `SelectSelectionInput` -
/// but the things that break silently are the numbering and the version
/// negotiation, so those are what is pinned.
final class X11XFixesTests: XCTestCase {
    /// An event base that overlaps another extension's means a client
    /// decodes someone else's event as its own - a bug that shows up as an
    /// unrelated feature misbehaving, which is the worst kind to chase.
    func testEventAndErrorBasesDoNotOverlapAnyOtherExtension() {
        let xfixesEvents = Set(
            Int(X11ExtensionBase.xfixesFirstEvent)
            ..< Int(X11ExtensionBase.xfixesFirstEvent) + X11ExtensionBase.xfixesEventCount)
        let takenEvents = Set(
            Int(X11ExtensionBase.shapeFirstEvent)
            ..< Int(X11ExtensionBase.shapeFirstEvent) + X11ExtensionBase.shapeEventCount)
            .union(Int(X11ExtensionBase.xinputFirstEvent)
                   ..< Int(X11ExtensionBase.xinputFirstEvent) + X11ExtensionBase.xinputEventCount)
            .union([Int(XKBEventCode.eventBase)])
            .union(Int(X11ExtensionBase.glxFirstEvent)
                   ..< Int(X11ExtensionBase.glxFirstEvent) + X11ExtensionBase.glxEventCount)
        XCTAssertTrue(xfixesEvents.isDisjoint(with: takenEvents),
                      "XFIXES events \(xfixesEvents.sorted()) overlap \(takenEvents.sorted())")

        let xfixesErrors = Set(
            Int(X11ExtensionBase.xfixesFirstError)
            ..< Int(X11ExtensionBase.xfixesFirstError) + X11ExtensionBase.xfixesErrorCount)
        let takenErrors = Set(
            Int(X11ExtensionBase.xinputFirstError)
            ..< Int(X11ExtensionBase.xinputFirstError) + X11ExtensionBase.xinputErrorCount)
            .union(Int(X11ExtensionBase.glxFirstError)
                   ..< Int(X11ExtensionBase.glxFirstError) + X11ExtensionBase.glxErrorCount)
            .union(Int(X11ExtensionBase.renderFirstError)
                   ..< Int(X11ExtensionBase.renderFirstError) + X11ExtensionBase.renderErrorCount)
        XCTAssertTrue(xfixesErrors.isDisjoint(with: takenErrors))
        // Core events end at 34 (GenericEvent is 35); an extension event
        // below that would shadow a real one.
        XCTAssertGreaterThan(Int(X11ExtensionBase.xfixesFirstEvent), 35)
    }

    /// The masks are bits 0-2. `allMasks` is what
    /// `SelectSelectionInput` validates against, so a wrong value here
    /// either refuses a legal subscription or accepts a meaningless one.
    func testSelectionEventMasksAreTheThreeDefinedBits() {
        XCTAssertEqual(X11XFixesSelectionEvent.setSelectionOwnerMask, 1)
        XCTAssertEqual(X11XFixesSelectionEvent.selectionWindowDestroyMask, 2)
        XCTAssertEqual(X11XFixesSelectionEvent.selectionClientCloseMask, 4)
        XCTAssertEqual(X11XFixesSelectionEvent.allMasks, 7)
        // The subtypes are the mask bits' positions, not the masks.
        XCTAssertEqual(X11XFixesSelectionEvent.setSelectionOwner, 0)
        XCTAssertEqual(X11XFixesSelectionEvent.selectionWindowDestroy, 1)
        XCTAssertEqual(X11XFixesSelectionEvent.selectionClientClose, 2)
    }

    /// `lastInVersion1` decides where "unimplemented" (BadImplementation)
    /// stops and "does not exist" (BadRequest) starts.
    func testVersionOneEndsAtGetCursorImage() {
        XCTAssertEqual(X11XFixesOpcode.lastInVersion1, X11XFixesOpcode.getCursorImage)
        XCTAssertEqual(X11XFixesOpcode.queryVersion, 0)
        XCTAssertEqual(X11XFixesOpcode.selectSelectionInput, 2)
    }
}

/// A disconnecting client's resources. mslgd freed only its windows, so
/// everything else survived for the life of the host process - and a host
/// process is reused across relaunches of the same app on purpose, so the
/// growth had no ceiling. Found 2026-09-29 while chasing the board's
/// "xrestop for the FreeGlyphs leak" item; the leak was far wider than
/// glyphs.
final class X11ClientResourceReleaseTests: XCTestCase {
    /// Resource ids carry their owning client in the high 11 bits.
    private func id(client: UInt32, _ n: UInt32) -> UInt32 { (client << 21) | n }

    func testEveryResourceKindIsFreedForTheDisconnectingClientOnly() {
        let state = X11State()
        let going: UInt32 = 3, staying: UInt32 = 4
        let font: UInt8 = 1, cursor: UInt8 = 2, colormap: UInt8 = 3

        for client in [going, staying] {
            _ = state.makePixmap(id: id(client: client, 1), width: 8, height: 8)
            _ = state.makeGC(id: id(client: client, 2))
            _ = state.makePicture(id: id(client: client, 3))
            _ = state.makeGlyphSet(id: id(client: client, 4), format: 0)
            state.setFont(id(client: client, 5), isSymbol: true)
            state.addFlatResource(font, id(client: client, 5))
            state.addFlatResource(cursor, id(client: client, 6))
            state.addFlatResource(colormap, id(client: client, 7))
        }

        state.releaseResources(ownedByClientIndex: going)

        XCTAssertNil(state.pixmap(id(client: going, 1)))
        XCTAssertNil(state.gc(id(client: going, 2)))
        XCTAssertNil(state.picture(id(client: going, 3)))
        XCTAssertNil(state.glyphSet(id(client: going, 4)))
        XCTAssertFalse(state.isSymbolFont(id(client: going, 5)))
        XCTAssertFalse(state.hasFlatResource(font, id(client: going, 5)))
        XCTAssertFalse(state.hasFlatResource(cursor, id(client: going, 6)))
        XCTAssertFalse(state.hasFlatResource(colormap, id(client: going, 7)))

        // The other client is untouched - resources are shared in one table,
        // so a filter that is too eager takes a live client's state with it.
        XCTAssertNotNil(state.pixmap(id(client: staying, 1)))
        XCTAssertNotNil(state.gc(id(client: staying, 2)))
        XCTAssertNotNil(state.picture(id(client: staying, 3)))
        XCTAssertNotNil(state.glyphSet(id(client: staying, 4)))
        XCTAssertTrue(state.isSymbolFont(id(client: staying, 5)))
        XCTAssertTrue(state.hasFlatResource(font, id(client: staying, 5)))
        XCTAssertTrue(state.hasFlatResource(cursor, id(client: staying, 6)))
        XCTAssertTrue(state.hasFlatResource(colormap, id(client: staying, 7)))
    }

    /// The flat table is keyed by kind<<32 | id, so a filter that reads the
    /// whole 64-bit key as an id frees nothing (or everything).
    func testFlatResourcesOfDifferentKindsShareAnIDWithoutConfusingTheFilter() {
        let state = X11State()
        let going: UInt32 = 5
        let shared = id(client: going, 9)
        state.addFlatResource(1, shared)
        state.addFlatResource(2, shared)
        state.addFlatResource(3, shared)
        state.releaseResources(ownedByClientIndex: going)
        for kind: UInt8 in [1, 2, 3] {
            XCTAssertFalse(state.hasFlatResource(kind, shared), "kind \(kind)")
        }
    }
}

/// The host's App Nap guard. A per-app host holds the live X11 socket, and a
/// napped or auto-terminated host freezes the Linux app inside it.
final class X11HostActivityTests: XCTestCase {
    override func tearDown() {
        X11HostActivity.connectionCountChanged(to: 0)
        super.tearDown()
    }

    func testHeldWhileClientsAreConnectedAndReleasedWhenTheLastOneGoes() {
        X11HostActivity.connectionCountChanged(to: 0)
        XCTAssertFalse(X11HostActivity.isHeld, "an idle host should be nappable like anything else")
        X11HostActivity.connectionCountChanged(to: 1)
        XCTAssertTrue(X11HostActivity.isHeld)
        // More clients must not stack a second token - `endActivity` takes
        // the one token back, so a leaked extra would never be released.
        X11HostActivity.connectionCountChanged(to: 3)
        XCTAssertTrue(X11HostActivity.isHeld)
        X11HostActivity.connectionCountChanged(to: 1)
        XCTAssertTrue(X11HostActivity.isHeld, "still one client attached")
        X11HostActivity.connectionCountChanged(to: 0)
        XCTAssertFalse(X11HostActivity.isHeld)
    }

    /// Re-releasing must be harmless: the count can reach zero more than once
    /// (a host outlives its windows and is reused).
    func testReleasingTwiceIsSafe() {
        X11HostActivity.connectionCountChanged(to: 1)
        X11HostActivity.connectionCountChanged(to: 0)
        X11HostActivity.connectionCountChanged(to: 0)
        XCTAssertFalse(X11HostActivity.isHeld)
        X11HostActivity.connectionCountChanged(to: 1)
        XCTAssertTrue(X11HostActivity.isHeld, "and it can be taken again afterwards")
    }
}

/// The file chooser's path translation. A Linux app gets back whatever this
/// returns and opens it directly, so a path the guest cannot reach is not a
/// cosmetic error - it is a file the app will fail to open, or worse, a
/// different file than the person picked.
final class HostFilePickerTests: XCTestCase {
    private let mount = "/Volumes/127.0.0.1"

    func testAPickInsideTheGuestMountBecomesAGuestPath() {
        let paths = HostFilePicker.guestPaths(
            for: ["\(mount)/home/abinaash/notes.txt"], instance: "Milk", mountPath: mount)
        XCTAssertEqual(paths, ["/home/abinaash/notes.txt"])
    }

    /// The Mac's home is visible to the guest at `/mnt/mac`, so a pick there
    /// is reachable - that is the whole point of letting the Mac panel show
    /// the Mac's own disk.
    func testAPickInTheMacHomeBecomesTheMacShare() {
        let home = NSHomeDirectory()
        let paths = HostFilePicker.guestPaths(
            for: ["\(home)/Documents/report.pdf"], instance: "Milk", mountPath: mount)
        XCTAssertEqual(paths, ["/mnt/mac/Documents/report.pdf"])
    }

    /// Anything else is dropped rather than returned. Handing back a path
    /// the guest cannot see gives the app a file that silently does not
    /// exist.
    func testUnreachablePicksAreDropped() {
        XCTAssertEqual(HostFilePicker.guestPaths(
            for: ["/Volumes/SomeUSBStick/thing.txt"], instance: "Milk", mountPath: mount), [])
        XCTAssertEqual(HostFilePicker.guestPaths(
            for: ["/System/Library/CoreServices/Finder.app"], instance: "Milk", mountPath: mount), [])
    }

    /// Another instance's mount is not this app's filesystem.
    func testAnotherInstancesMountIsNotReturned() {
        let paths = HostFilePicker.guestPaths(
            for: ["/Volumes/127.0.0.1-1/home/x/f"], instance: "Milk", mountPath: mount)
        XCTAssertEqual(paths, [])
    }

    func testMixedSelectionKeepsOnlyTheReachableOnes() {
        let paths = HostFilePicker.guestPaths(
            for: ["\(mount)/etc/hostname", "/Volumes/USB/x", "\(mount)/tmp/y"],
            instance: "Milk", mountPath: mount)
        XCTAssertEqual(paths, ["/etc/hostname", "/tmp/y"])
    }

    /// With no mount there is no guest filesystem to translate against, but
    /// the Mac share still works - the guest can always see `/mnt/mac`.
    func testWithoutAMountOnlyTheMacShareResolves() {
        XCTAssertEqual(HostFilePicker.guestPaths(
            for: ["\(mount)/home/x"], instance: "Milk", mountPath: nil), [])
        XCTAssertEqual(HostFilePicker.guestPaths(
            for: ["\(NSHomeDirectory())/a.txt"], instance: "Milk", mountPath: nil), ["/mnt/mac/a.txt"])
    }

    /// The panel opens where the app asked, and falls back to the mount root
    /// rather than nowhere.
    func testStartDirectory() {
        XCTAssertEqual(HostFilePicker.startDirectory(guestPath: "/", mountPath: mount), mount)
        XCTAssertEqual(HostFilePicker.startDirectory(guestPath: "/nope/missing", mountPath: mount), mount)
        XCTAssertNil(HostFilePicker.startDirectory(guestPath: "/", mountPath: nil))
    }

    /// Cancelling and declining are different answers and must stay so: an
    /// empty list means the person said no, `declined` means fall back to
    /// the Linux dialog. Confusing them re-shows a dialog they dismissed.
    func testCancelledIsNotDeclined() {
        // Parsed, not substring-matched: JSON key order is not guaranteed.
        func paths(_ reply: String) -> [String]? {
            guard let data = reply.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            XCTAssertEqual(object["result"] as? String, "picked")
            return object["paths"] as? [String]
        }
        XCTAssertEqual(paths(HostOpenService.pickReply([])), [],
                       "cancelled is an empty list, not the word 'declined'")
        XCTAssertNotEqual(HostOpenService.pickReply([]), "declined")
        XCTAssertEqual(paths(HostOpenService.pickReply(["/home/x/a"])), ["/home/x/a"])
    }

    /// A suggested "name" from the guest must not be able to move the panel:
    /// only the last component is kept.
    func testSuggestedNameCannotCarryAPath() {
        let line = Data(#"{"kind":"pick","targets":["/"],"mode":"save","name":"../../etc/passwd"}"#.utf8)
        let request = HostOpenRequest.parse(line)
        XCTAssertEqual(request?.suggestedName, "passwd")
    }

    func testPickIsGatedOnThePreferMSLFilesToggle() {
        var off = MSLExperimentalSettings(); off.preferMSLFiles = false
        let request = HostOpenRequest(kind: .pick, targets: ["/home/x"])
        guard case .decline = HostOpenPlan.make(for: request, settings: off) else {
            return XCTFail("with the toggle off the app must get its own Linux dialog")
        }
        var on = MSLExperimentalSettings(); on.preferMSLFiles = true
        guard case .pickFiles(let pick) = HostOpenPlan.make(for: request, settings: on) else {
            return XCTFail("with the toggle on MSL Files should show the picker")
        }
        XCTAssertEqual(pick.startGuestPath, "/home/x")
    }
}

/// The three-party handshake behind a Linux app's file dialog: the guest app
/// waits, mslhd holds the request, MSL Files shows the picker. Every failure
/// here is an app hanging on a dialog, so the states are pinned.
final class PendingFilePicksTests: XCTestCase {
    private func request() -> HostFilePickRequest {
        HostFilePickRequest(mode: .save, startGuestPath: "/home/x", suggestedName: "a.txt")
    }

    func testAClaimedPickReturnsWhatWasChosen() {
        let picks = PendingFilePicks()
        let token = picks.register(request(), instance: "Milk")
        XCTAssertEqual(picks.claim(token: token)?.instance, "Milk")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            picks.complete(token: token, outcome: .picked(["/home/x/a.txt"]))
        }
        XCTAssertEqual(picks.wait(token: token), .picked(["/home/x/a.txt"]))
        XCTAssertEqual(picks.pendingCount, 0, "a finished pick must not be left behind")
    }

    /// Cancelling is a decision the person made. If this leaked out as
    /// `unavailable` the app would open its own dialog straight after they
    /// dismissed one, which reads as the dialog refusing to close.
    func testCancelIsDistinctFromUnavailable() {
        let picks = PendingFilePicks()
        let token = picks.register(request(), instance: "Milk")
        _ = picks.claim(token: token)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            picks.complete(token: token, outcome: .cancelled)
        }
        XCTAssertEqual(picks.wait(token: token), .cancelled)
    }

    /// Nobody claimed it - MSL Files could not start. The app must be told
    /// so it opens its own dialog, not left waiting.
    func testAnUnclaimedPickGivesUpAndIsForgotten() {
        let picks = PendingFilePicks()
        let token = picks.register(request(), instance: "Milk")
        let started = Date()
        // The real deadline is 20s; this asserts the shape, not the clock,
        // by completing it as unavailable from the other side.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            picks.complete(token: token, outcome: .unavailable)
        }
        XCTAssertEqual(picks.wait(token: token), .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), PendingFilePicks.claimDeadline)
        XCTAssertEqual(picks.pendingCount, 0)
    }

    /// **Claiming removes the deadline entirely.** Getting MSL Files on
    /// screen is bounded; browsing is not, and a person may take minutes.
    ///
    /// This is the property `FilePickerModel.claim()` is shaped around. The
    /// claim used to run after a ten-second instance refresh while the
    /// deadline here was six, so a slow daemon meant the guest app was told
    /// no picker was coming and opened its own dialog, while MSL Files
    /// opened anyway to say nobody was waiting for it.
    func testAClaimedPickHasNoDeadline() {
        let picks = PendingFilePicks()
        let request = HostFilePickRequest(mode: .open, startGuestPath: "/home/u",
                                          suggestedName: "", allowsMultiple: false, title: "Open")
        let token = picks.register(request, instance: "work")
        XCTAssertNotNil(picks.claim(token: token), "claiming a live token must succeed")

        DispatchQueue.global().asyncAfter(deadline: .now() + PendingFilePicks.claimDeadline + 1.5) {
            picks.complete(token: token, outcome: .picked(["/home/u/late.txt"]))
        }
        XCTAssertEqual(picks.wait(token: token), .picked(["/home/u/late.txt"]))
    }

    func testAnUnknownTokenIsUnavailableRatherThanACrash() {
        let picks = PendingFilePicks()
        XCTAssertNil(picks.claim(token: "nope"))
        XCTAssertEqual(picks.wait(token: "nope"), .unavailable)
    }

    /// Two answers for one pick: the first wins. A double reply otherwise
    /// signals a semaphore nobody is waiting on any more.
    func testCompletingTwiceKeepsTheFirstAnswer() {
        let picks = PendingFilePicks()
        let token = picks.register(request(), instance: "Milk")
        _ = picks.claim(token: token)
        picks.complete(token: token, outcome: .picked(["/a"]))
        picks.complete(token: token, outcome: .cancelled)
        XCTAssertEqual(picks.wait(token: token), .picked(["/a"]))
    }

    /// The daemon is going away: nothing may be left blocked on an answer
    /// that can no longer arrive.
    func testAbandonAllReleasesEveryWaiter() {
        let picks = PendingFilePicks()
        let token = picks.register(request(), instance: "Milk")
        _ = picks.claim(token: token)
        let done = expectation(description: "waiter returned")
        DispatchQueue.global().async {
            _ = picks.wait(token: token)
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { picks.abandonAll() }
        wait(for: [done], timeout: 5)
    }
}
