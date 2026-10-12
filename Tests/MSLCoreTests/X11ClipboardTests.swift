import AppKit
import XCTest
@testable import MSLCore

/// The Mac side of Linux copy and paste.
///
/// Everything here runs against a private `NSPasteboard`, never the real
/// one: a test suite that overwrites what the person running it had copied
/// is a test suite nobody runs twice.
final class X11ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var state: X11State!
    private var clipboard: X11Clipboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("msl.tests.\(UUID().uuidString)"))
        clipboard = X11Clipboard(pasteboard: pasteboard, enabled: true)
        state = X11State()
        clipboard.attach(to: state)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testUTF8AndLatin1Decode() {
        let utf8 = clipboard.utf8Atom()
        XCTAssertEqual(X11Clipboard.decode(type: utf8, format: 8, data: Array("héllo ✨".utf8), utf8Atom: utf8),
                       "héllo ✨")
        XCTAssertEqual(X11Clipboard.decode(type: X11Clipboard.stringAtom, format: 8, data: [0xE9], utf8Atom: utf8),
                       "é", "STRING is Latin-1, not UTF-8")
        XCTAssertNil(X11Clipboard.decode(type: utf8, format: 8, data: [], utf8Atom: utf8))
        XCTAssertNil(X11Clipboard.decode(type: utf8, format: 32, data: [1, 2, 3, 4], utf8Atom: utf8),
                     "text is always format 8")
    }

    /// GTK re-asserts CLIPBOARD ownership on focus changes. Converting on
    /// every one of those is a round trip per focus change.
    func testRepeatedClaimsAreDebounced() {
        let now = Date()
        // `TARGETS` first: what the owner can produce decides what to ask
        // for, so an image copy is found instead of assumed to be text.
        XCTAssertEqual(clipboard.targetForGuestClaim(owner: 0x4000_0001, now: now), clipboard.targetsAtom())
        XCTAssertNil(clipboard.targetForGuestClaim(owner: 0x4000_0001, now: now.addingTimeInterval(0.05)))
        XCTAssertNotNil(clipboard.targetForGuestClaim(owner: 0x4000_0001,
                                                      now: now.addingTimeInterval(X11Clipboard.reclaimDebounce + 0.01)))
    }

    /// A different app copying is a real second copy, not a re-assertion.
    func testADifferentOwnerIsNotDebounced() {
        let now = Date()
        XCTAssertNotNil(clipboard.targetForGuestClaim(owner: 0x4000_0001, now: now))
        XCTAssertNotNil(clipboard.targetForGuestClaim(owner: 0x8000_0001, now: now.addingTimeInterval(0.01)))
    }

    /// MSL's own claim, on the Mac's behalf, must never start a conversion
    /// round trip with itself.
    func testMSLsOwnClaimIsIgnored() {
        XCTAssertNil(clipboard.targetForGuestClaim(owner: X11Clipboard.macOwnerWindowID))
        XCTAssertNil(clipboard.targetForGuestClaim(owner: 0))
    }

    /// A client that cannot produce UTF8_STRING refuses with a
    /// SelectionNotify carrying no property, and nothing else. STRING is
    /// worth one more ask; after that, give up rather than loop.
    func testFallbackHappensOnceThenStops() {
        _ = clipboard.targetForGuestClaim(owner: 0x4000_0001)
        XCTAssertEqual(clipboard.fallbackTarget(), X11Clipboard.stringAtom)
        XCTAssertNil(clipboard.fallbackTarget())
        XCTAssertFalse(clipboard.hasPendingConversion)
    }

    func testAnUnansweredConversionExpires() {
        _ = clipboard.targetForGuestClaim(owner: 0x4000_0001)
        clipboard.expirePending(now: Date().addingTimeInterval(X11Clipboard.conversionTimeout / 2))
        XCTAssertTrue(clipboard.hasPendingConversion)
        clipboard.expirePending(now: Date().addingTimeInterval(X11Clipboard.conversionTimeout + 1))
        XCTAssertFalse(clipboard.hasPendingConversion)
    }

    /// The whole guest-copies path: a claim, then the client's answer,
    /// leaves the text on the Mac's pasteboard.
    @MainActor
    func testGuestCopyReachesThePasteboard() {
        _ = clipboard.targetForGuestClaim(owner: 0x4000_0001)
        // The outcome says what the CALLER must do next, not what the text
        // was - an ordinary single-property value needs nothing further.
        // (INCR is the case that does; see `X11IncrSelectionTests`.)
        let outcome = clipboard.receivedConversion(type: clipboard.utf8Atom(), format: 8,
                                                   data: Array("from linux".utf8))
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(pasteboard.string(forType: .string), "from linux")
        XCTAssertFalse(clipboard.hasPendingConversion)
        XCTAssertNil(clipboard.textForGuest(), "a Linux app owns it now, so MSL must not answer for the Mac")
    }

    /// What MSL offers when it stands in as the selection owner. A zero
    /// atom in this list would be an invalid TARGETS reply.
    func testOfferedTargetsAreRealAtoms() {
        clipboard.claimForMac(X11Clipboard.MacPayload(text: "hi"))
        let targets = clipboard.offeredTargets()
        XCTAssertTrue(targets.contains(clipboard.utf8Atom()))
        XCTAssertTrue(targets.contains(X11Clipboard.stringAtom))
        XCTAssertTrue(targets.contains(clipboard.targetsAtom()))
        XCTAssertTrue(targets.contains(clipboard.timestampAtom()))
        XCTAssertFalse(targets.contains(0))
        XCTAssertEqual(Set(targets).count, targets.count, "no duplicates")
    }

    /// The offer follows what is actually held: offering `image/png` for a
    /// copy with no image makes every toolkit ask for it and get a refusal,
    /// and offering the text targets for an image-only copy is a promise
    /// MSL cannot keep.
    func testOfferedTargetsFollowThePayload() {
        clipboard.claimForMac(X11Clipboard.MacPayload(text: "just text"))
        XCTAssertFalse(clipboard.offeredTargets().contains(clipboard.imagePNGAtom()))

        clipboard.claimForMac(X11Clipboard.MacPayload(text: nil, png: [0x89, 0x50, 0x4E, 0x47]))
        let imageOnly = clipboard.offeredTargets()
        XCTAssertTrue(imageOnly.contains(clipboard.imagePNGAtom()))
        XCTAssertFalse(imageOnly.contains(clipboard.utf8Atom()))
        // TARGETS and TIMESTAMP are always answerable.
        XCTAssertTrue(imageOnly.contains(clipboard.targetsAtom()))
    }

    func testDataForTargets() {
        clipboard.claimForMac(X11Clipboard.MacPayload(text: "hi ✨"))
        XCTAssertEqual(clipboard.data(for: clipboard.utf8Atom())?.data, Array("hi ✨".utf8))
        XCTAssertNil(clipboard.data(for: X11Clipboard.stringAtom),
                     "STRING is Latin-1; a client asking for it can't be handed UTF-8 bytes")
        XCTAssertNil(clipboard.data(for: 99_999), "an unknown target is refused, not guessed at")

        clipboard.claimForMac(X11Clipboard.MacPayload(text: "hi"))
        XCTAssertEqual(clipboard.data(for: X11Clipboard.stringAtom)?.data, Array("hi".utf8))

        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D]
        clipboard.claimForMac(X11Clipboard.MacPayload(text: nil, png: png))
        XCTAssertEqual(clipboard.data(for: clipboard.imagePNGAtom())?.data, png)
        XCTAssertNil(clipboard.data(for: clipboard.utf8Atom()), "no text in an image-only copy")
    }

    /// A copy that is text *and* an image takes one conversion each, so the
    /// bridge asks for what the owner listed rather than guessing, and text
    /// comes first so a picture-of-text copy keeps its text.
    func testTargetNegotiationAsksForTextThenImage() {
        let utf8 = clipboard.utf8Atom(), png = clipboard.imagePNGAtom()
        XCTAssertEqual(clipboard.wantedTargets(fromOffered: [utf8, png]), [utf8, png])
        XCTAssertEqual(clipboard.wantedTargets(fromOffered: [png]), [png])
        XCTAssertEqual(clipboard.wantedTargets(fromOffered: [utf8]), [utf8])
        // STRING only when UTF8_STRING isn't on offer.
        XCTAssertEqual(clipboard.wantedTargets(fromOffered: [X11Clipboard.stringAtom]),
                       [X11Clipboard.stringAtom])
        XCTAssertEqual(clipboard.wantedTargets(fromOffered: [utf8, X11Clipboard.stringAtom]), [utf8])
        XCTAssertTrue(clipboard.wantedTargets(fromOffered: [99_999]).isEmpty)
    }

    /// Copying a file in Finder puts the file's **icon** on the pasteboard
    /// as TIFF next to the file URL. Offering `image/png` because "an image
    /// is present" would paste a Finder icon into GIMP - which looks like
    /// the bridge working and is entirely wrong.
    func testFilesWinOverTheFinderIcon() {
        let payload = X11Clipboard.MacPayload(text: "notes.txt", png: nil,
                                              files: ["/mnt/mac/Desktop/notes.txt"])
        clipboard.claimForMac(payload)
        let targets = clipboard.offeredTargets()
        XCTAssertTrue(targets.contains(clipboard.uriListAtom()))
        XCTAssertTrue(targets.contains(clipboard.gnomeCopiedAtom()))
        XCTAssertFalse(targets.contains(clipboard.imagePNGAtom()))
    }

    /// The two ways a Linux desktop reads files off a clipboard.
    func testFileTargetsAreEncodedTheWayLinuxExpects() {
        let paths = ["/mnt/mac/Desktop/a file.txt", "/mnt/mac/Documents/b.png"]
        let uriList = String(decoding: X11Clipboard.uriList(paths), as: UTF8.self)
        XCTAssertEqual(uriList,
                       "file:///mnt/mac/Desktop/a%20file.txt\r\nfile:///mnt/mac/Documents/b.png\r\n")
        // A space must be escaped, or one path arrives as two URIs.
        XCTAssertTrue(uriList.contains("a%20file.txt"))

        let gnome = String(decoding: X11Clipboard.gnomeCopiedFiles(paths), as: UTF8.self)
        XCTAssertTrue(gnome.hasPrefix("copy\n"),
                      "always copy - a cut would delete the Mac's original")
        XCTAssertFalse(gnome.contains("cut"))
        XCTAssertEqual(gnome.split(separator: "\n").count, 3)
    }

    /// A `TARGETS` reply is a list of 32-bit atoms, little-endian.
    func testAtomListDecoding() {
        let bytes: [UInt8] = [1, 0, 0, 0, 0xFF, 0x01, 0, 0]
        XCTAssertEqual(X11Clipboard.atomList(bytes), [1, 511])
        XCTAssertEqual(X11Clipboard.atomList([]), [])
        XCTAssertEqual(X11Clipboard.atomList([1, 2]), [], "a partial atom is not half an atom")
    }

    /// A host that starts after the copy still has to serve it: the first
    /// Linux window you open is exactly where you try to paste.
    func testTextAlreadyOnThePasteboardIsClaimed() {
        pasteboard.clearContents()
        pasteboard.setString("copied before the app existed", forType: .string)
        XCTAssertNil(clipboard.textForGuest())
        clipboard.adoptCurrentPasteboard()
        XCTAssertEqual(clipboard.textForGuest(), "copied before the app existed")
        XCTAssertEqual(state.selectionOwner(clipboard.clipboardAtom()), X11Clipboard.macOwnerWindowID,
                       "MSL stands in as the selection owner")
    }

    /// Turned off - which is how it ships - the bridge must be completely
    /// inert: no claim, no answer, no poll. A Linux app's clipboard stays
    /// its own.
    func testDisabledBridgeDoesNothing() {
        let off = X11Clipboard(pasteboard: pasteboard, enabled: false)
        off.attach(to: state)
        pasteboard.clearContents()
        pasteboard.setString("mac text", forType: .string)
        off.adoptCurrentPasteboard()
        XCTAssertNil(off.textForGuest())
        XCTAssertNil(off.targetForGuestClaim(owner: 0x4000_0001))
        XCTAssertEqual(off.receivedConversion(type: off.utf8Atom(), format: 8, data: Array("x".utf8)), .done)
        XCTAssertNil(off.textForGuest(), "a disabled bridge publishes nothing")
        XCTAssertEqual(state.selectionOwner(off.clipboardAtom()), 0, "nothing was claimed")
    }

    /// The reserved IDs must sit below every client's range
    /// (`clientIndex << 21`, with client indices starting at 1), or MSL
    /// would be trampling a real window.
    func testReservedWindowIDsCannotCollideWithAClient() {
        XCTAssertLessThan(X11Clipboard.requestorWindowID, 1 << 21)
        XCTAssertLessThan(X11Clipboard.macOwnerWindowID, 1 << 21)
        XCTAssertNotEqual(X11Clipboard.requestorWindowID, X11Clipboard.macOwnerWindowID)
        XCTAssertNil(state.window(X11Clipboard.requestorWindowID))
        XCTAssertNil(state.window(X11Clipboard.macOwnerWindowID))
    }
}
