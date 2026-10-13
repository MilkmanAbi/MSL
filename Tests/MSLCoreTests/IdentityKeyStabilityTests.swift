import XCTest
import CryptoKit
@testable import MSLCore

/// This Mac's signing key, and why it must never be replaced quietly.
///
/// Every instance identity is signed by it. Mint a new one and every
/// identity this Mac issued becomes unverifiable, with no way back - refusing
/// to re-sign an identity is the entire point of the scheme. So the one thing
/// that must not happen is a new key appearing because a read went wrong.
final class IdentityKeyStabilityTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idkey-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Accepting a key must add to the list, never replace it: a Mac has to
    /// go on accepting identities it issued under an earlier key.
    func testPinningAccumulatesRatherThanReplacing() throws {
        let accepted = directory.appendingPathComponent("signers.json")
        var all: [String: String] = [:]
        for _ in 0..<3 {
            let key = Curve25519.Signing.PrivateKey().publicKey
            all[MSLAPSigning.keyID(for: key)] = key.rawRepresentation.base64EncodedString()
            try JSONEncoder().encode(all).write(to: accepted, options: .atomic)
        }
        let read = try JSONDecoder().decode([String: String].self,
                                            from: Data(contentsOf: accepted))
        XCTAssertEqual(read.count, 3, "a Mac must keep accepting the keys it issued under")
    }

    /// **The regression.** A key file that is present but unreadable is not a
    /// Mac that has never had one. Generating for both orphaned every
    /// identity on this Mac - twice, under two different keys.
    func testAnUnreadableKeyIsAnErrorRatherThanANewKey() throws {
        let path = directory.appendingPathComponent("machine-key")
        try "this is not a key".write(to: path, atomically: true, encoding: .utf8)

        // The shape the fix turns on: present-but-unparseable must not be
        // treated as absent.
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertNil(try? MSLAPSigning.privateKey(fromBase64: text),
                     "this fixture must be unparseable for the test to mean anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "and it must exist - that is the whole distinction")
    }

    /// The error says what happened and what was *not* done, because the
    /// reassuring half is the part that matters.
    func testTheErrorSaysNothingWasReplaced() {
        let message = String(describing: IdentityKeyError.unreadable("/x/machine-key"))
        XCTAssertTrue(message.contains("has not been replaced"))
        XCTAssertTrue(message.contains("unverifiable"))
    }
}
