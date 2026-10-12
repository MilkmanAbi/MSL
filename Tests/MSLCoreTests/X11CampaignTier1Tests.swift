import XCTest
@testable import MSLCore

/// The Tier-1 findings of the mslgd audit (`READMES/MSLGD-CAMPAIGN.md`)
/// that can be pinned down without a live server.
///
/// Each of these was a one-line disagreement with the X11 protocol that
/// survived for months because nothing in the test suite could see it.
final class X11CampaignTier1Tests: XCTestCase {
    // MARK: M1 — QueryTextExtents' character count

    /// The request is `FONTABLE`(4) + `STRING16`(2n) + p padding bytes,
    /// and for odd n the wire carries `p = 2`. The byte count alone
    /// therefore cannot tell n from n+1 - which is exactly why the request
    /// has an `odd length` flag. Ignoring it measured every odd-length
    /// string one full character too wide.
    func testOddLengthStringsAreNotMeasuredOneCharacterTooWide() {
        // "AB" -> 4 + 4 bytes, even, no padding.
        XCTAssertEqual(X11Connection.textExtentsCharCount(bodyByteCount: 8, oddLength: false), 2)
        // "A" -> 4 + 2 bytes + 2 padding = 8 on the wire, but one CHAR2B.
        XCTAssertEqual(X11Connection.textExtentsCharCount(bodyByteCount: 8, oddLength: true), 1)
    }

    /// The two cases are indistinguishable by length, which is the whole
    /// point: the same body size must give different answers.
    func testTheFlagIsTheOnlyThingThatDistinguishesThem() {
        for bytes in stride(from: 4, through: 64, by: 4) {
            let even = X11Connection.textExtentsCharCount(bodyByteCount: bytes, oddLength: false)
            let odd = X11Connection.textExtentsCharCount(bodyByteCount: bytes, oddLength: true)
            XCTAssertEqual(even - odd, bytes == 4 ? 0 : 1, "body \(bytes)")
        }
    }

    func testAnEmptyStringMeasuresZero() {
        XCTAssertEqual(X11Connection.textExtentsCharCount(bodyByteCount: 4, oddLength: false), 0)
        XCTAssertEqual(X11Connection.textExtentsCharCount(bodyByteCount: 0, oddLength: true), 0)
    }

    // MARK: K3 — XkbStateNotify's changed mask

    /// `stateNotify` writes `compatLookupMods` as a real field, and
    /// `sendXkbStateNotify` only delivers when the client's selection
    /// overlaps `changed`. Leaving bit 12 out meant a client that selected
    /// only that part never heard about a change to the field it asked
    /// for.
    func testCompatLookupModsIsReportedAsChanged() {
        let idle = X11KeyboardSnapshot()
        var shifted = X11KeyboardSnapshot()
        shifted.baseMods = 0x01

        let changed = X11Keymap.stateChanges(from: idle, to: shifted)
        XCTAssertNotEqual(changed & (1 << 12), 0, "XkbCompatLookupModsMask")
        for bit in 8...11 {
            XCTAssertNotEqual(changed & (1 << bit), 0, "bit \(bit)")
        }
    }

    func testAnUnchangedStateReportsNothing() {
        let state = X11KeyboardSnapshot()
        XCTAssertEqual(X11Keymap.stateChanges(from: state, to: state), 0)
    }

    // MARK: F8a — which RENDER requests get an error rather than silence

    /// Only the two that carry replies. A request with no reply costs its
    /// sender nothing when ignored, but an error reaches the client's
    /// error handler - and Xlib's default handler exits the process. The
    /// audit asked for an error on everything; this project has already
    /// watched that catch-all kill galculator and abiword, so the fix is
    /// deliberately narrower than the finding.
    func testOnlyReplyBearingRenderMinorsAreAnsweredWithAnError() {
        XCTAssertTrue(X11Connection.renderMinorsWithReplies.contains(2), "QueryPictIndexValues")
        // QueryFilters (29) is implemented now (a real reply), so it no
        // longer needs the error fallback.
        XCTAssertFalse(X11Connection.renderMinorsWithReplies.contains(29), "QueryFilters is answered for real")
        for silent: UInt8 in [11, 12, 13, 22, 32, 35, 36] {
            XCTAssertFalse(X11Connection.renderMinorsWithReplies.contains(silent),
                           "minor \(silent) has no reply - an error would be worse than silence")
        }
    }
}
