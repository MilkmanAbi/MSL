// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import CryptoKit

/// Who an instance is, and where it came from.
///
/// See `READMES/31-INSTANCE-IDENTITY.md`. The short version: `instance.clone`
/// gates the *action* of cloning, and nothing gates the *arrival* of an
/// instance copied some other way - `cp` the disk and add a registry line,
/// or export a shipment where cloning is allowed and import it where it is
/// not. An identity makes that answerable.
///
/// **This type is pure on purpose.** It parses, signs and verifies; it does
/// not read files, consult a policy or know what an instance is doing. The
/// storage, the issuing rules and the acceptance decision are separate and
/// each has its own tests, because the mistake that would hurt most here is
/// a parser that accepts something it should refuse.
public struct InstanceIdentity: Equatable, Sendable {

    /// The format signifier. An MSL that meets `MSLI2` must **refuse**
    /// rather than guess: the catalogue learned this when a policy written
    /// for a newer MSL named capabilities this build had never heard of,
    /// and silently dropping what it could not read was the wrong answer.
    public static let signifier = "MSLI1"

    /// The root ancestor, shared by every descendant. 128 bits.
    ///
    /// This is what an administrator means by "my company image": every
    /// instance ever derived from it carries the same lineage, however many
    /// times it has been copied.
    public let lineage: String

    /// The clone path: `0` for an original, `0.1` for its first clone,
    /// `0.1.2` for the second clone of that. **The number of dots is how
    /// many times this instance has been copied.**
    public let generation: String

    /// Unique to this instance, even among siblings. 64 bits.
    ///
    /// Needed because two clones of one parent would both want to be `0.1`
    /// - each would have to know how many siblings already exist, and a
    /// copied disk does not carry that count. Random makes every instance
    /// distinct with nothing to coordinate, and leaves the path readable.
    public let serial: String

    /// The key that signed this, as `MSLAPSigning.keyID`.
    public let issuer: String

    /// The instance's name **at birth**, never updated.
    ///
    /// Load-bearing, and the reason is a hole found two weeks ago:
    /// **renaming escapes a scope.** A clone of `Company` called `Sneaky`
    /// is not matched by a scope on `Company*`. Acceptance checks the
    /// policy against the current name *and* this one, and this one is
    /// signed, so it cannot be edited to something unrestricted.
    public let origin: String

    /// Which Mac issued it.
    public let machine: String

    /// When, to the second. Not used in any comparison - only reported -
    /// so nothing here depends on a correct clock.
    public let born: UInt64

    public init(lineage: String, generation: String, serial: String, issuer: String,
                origin: String, machine: String, born: UInt64) {
        self.lineage = lineage
        self.generation = generation
        self.serial = serial
        self.issuer = issuer
        self.origin = origin
        self.machine = machine
        self.born = born
    }

    // MARK: - Shape rules

    /// Lowercase RFC 4648 base32 without padding. Lowercase so a lineage is
    /// never confused with the hex `issuer`/`machine` fields beside it.
    public static let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    public static let lineageLength = 26   // 128 bits
    public static let serialLength = 13    // 64 bits
    static let keyIDLength = 16            // 8 bytes, hex

    /// How deep a clone chain may go.
    ///
    /// A cap because the path is attacker-influenced data that MSL parses
    /// on a boot path: without one, a hand-written identity could carry a
    /// megabyte of dots. Sixteen is far past anything real - nobody clones
    /// a clone sixteen times - and the refusal says what the limit is.
    public static let maximumDepth = 16

    /// `:` separates fields, and it is the one punctuation that cannot
    /// collide: `InstanceRegistry.isValidName` permits only letters,
    /// numbers, `-` and `_`, so an `origin` can never contain it, and
    /// neither base32 nor hex does. `-` would have been unsafe for exactly
    /// that reason.
    static let fieldSeparator: Character = ":"
    /// Separates the signed payload from the signature.
    static let signatureSeparator: Character = "~"

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case notAnIdentity
        case unsupportedVersion(String)
        case wrongFieldCount(Int)
        case malformedField(String, String)
        case depthTooGreat(Int)
        case badSignature
        case unknownIssuer(String)

        public var description: String {
            switch self {
            case .notAnIdentity:
                return "this is not an MSL instance identity"
            case .unsupportedVersion(let found):
                return "this identity is format '\(found)', which this version of MSL cannot read - "
                     + "it was written by a newer MSL, and guessing at it would be worse than saying so"
            case .wrongFieldCount(let count):
                return "an identity has \(InstanceIdentity.fieldCount) fields, this one has \(count)"
            case .malformedField(let name, let why):
                return "the \(name) field is not usable: \(why)"
            case .depthTooGreat(let depth):
                return "this identity claims \(depth) generations of copying, more than the \(InstanceIdentity.maximumDepth) MSL will read"
            case .badSignature:
                return "the signature does not match - this identity has been edited since it was issued"
            case .unknownIssuer(let id):
                return "issued by key \(id), which this Mac does not accept"
            }
        }
    }

    static let fieldCount = 7

    // MARK: - The token

    /// Everything the signature covers: the whole record, with no
    /// signature on it.
    ///
    /// The signed payload is the **complete** record rather than a few
    /// chosen fields, so a token is self-verifying wherever it is found -
    /// in the host record or in the guest witness - with nothing else
    /// needed to check it. A signature over a subset would have let the
    /// unsigned remainder be edited freely, which is the classic way this
    /// goes wrong.
    public var payload: String {
        [Self.signifier, lineage, generation, serial, issuer, origin, machine, String(born)]
            .joined(separator: String(Self.fieldSeparator))
    }

    /// The full token, `payload~signature`. What gets stored, in both
    /// homes, byte-identically - so comparing the two is string equality
    /// rather than field-by-field logic that can drift apart.
    public func token(signature: String) -> String {
        payload + String(Self.signatureSeparator) + signature
    }

    /// For a person: `MSLI1·k7m2…·0.1`. Enough to recognise and compare by
    /// eye, short enough for a status line. Never parsed.
    public var displayForm: String {
        "\(Self.signifier)·\(lineage.prefix(6))…·\(generation)"
    }

    /// How many times this instance has been copied. `0` is an original.
    public var depth: Int { generation.filter { $0 == "." }.count }

    public var isClone: Bool { depth > 0 }

    // MARK: - Parsing

    /// Parses a token's payload. **Does not check the signature** - that is
    /// `verify`, and keeping them apart means a caller cannot accidentally
    /// get a parsed-but-unverified identity and treat it as trusted.
    public static func parse(payload: String) throws -> InstanceIdentity {
        let fields = payload.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = fields.first, first.hasPrefix("MSLI") else { throw Invalid.notAnIdentity }
        guard first == signifier else { throw Invalid.unsupportedVersion(first) }
        guard fields.count == fieldCount + 1 else { throw Invalid.wrongFieldCount(fields.count - 1) }

        let lineage = fields[1], generation = fields[2], serial = fields[3]
        let issuer = fields[4], origin = fields[5], machine = fields[6], born = fields[7]

        try check(base32: lineage, length: lineageLength, name: "lineage")
        try check(base32: serial, length: serialLength, name: "serial")
        try check(hex: issuer, length: keyIDLength, name: "issuer")
        try check(hex: machine, length: keyIDLength, name: "machine")
        try checkGeneration(generation)
        guard InstanceRegistry.isValidName(origin) else {
            throw Invalid.malformedField("origin", "'\(origin)' is not a usable instance name")
        }
        guard let bornValue = UInt64(born), bornValue > 0 else {
            throw Invalid.malformedField("born", "'\(born)' is not a time")
        }
        return InstanceIdentity(lineage: lineage, generation: generation, serial: serial,
                                issuer: issuer, origin: origin, machine: machine,
                                born: bornValue)
    }

    /// Splits a stored token into the part that was signed and the
    /// signature over it.
    public static func split(token: String) throws -> (payload: String, signature: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // `omittingEmptySubsequences: false` so `payload~` fails as a bad
        // signature rather than silently parsing as an unsigned identity.
        let parts = trimmed.split(separator: signatureSeparator, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw Invalid.badSignature
        }
        return (String(parts[0]), String(parts[1]))
    }

    private static func check(base32 value: String, length: Int, name: String) throws {
        guard value.count == length else {
            throw Invalid.malformedField(name, "expected \(length) characters, got \(value.count)")
        }
        guard value.allSatisfy({ alphabet.contains($0) }) else {
            throw Invalid.malformedField(name, "contains something outside the alphabet")
        }
    }

    private static func check(hex value: String, length: Int, name: String) throws {
        guard value.count == length else {
            throw Invalid.malformedField(name, "expected \(length) hex characters, got \(value.count)")
        }
        guard value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw Invalid.malformedField(name, "is not lowercase hex")
        }
    }

    /// `0`, or `0` followed by dot-separated indices.
    ///
    /// The leading `0` is required so a path always says where it started,
    /// and an index is capped so the whole field stays a bounded size.
    private static func checkGeneration(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= maximumDepth + 1 else { throw Invalid.depthTooGreat(parts.count - 1) }
        guard parts.first == "0" else {
            throw Invalid.malformedField("generation", "'\(value)' does not start at 0")
        }
        for part in parts.dropFirst() {
            // No leading zeros: `0.01` and `0.1` would otherwise be two
            // spellings of one path, and two spellings means two identities
            // that compare unequal while meaning the same thing.
            guard let index = Int(part), index >= 1, index <= 9999, String(index) == part else {
                throw Invalid.malformedField("generation", "'\(part)' is not a clone index")
            }
        }
    }

    // MARK: - Issuing

    static func randomBase32(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let letters = Array(alphabet)
        // One random byte per character, reduced modulo 32. The bias is
        // 256 % 32 == 0, so there is none.
        return String(bytes.map { letters[Int($0) % letters.count] })
    }

    /// A brand-new lineage: an instance that is nobody's copy.
    public static func issue(origin: String, machine: String, issuer: String,
                             now: Date = Date()) -> InstanceIdentity {
        InstanceIdentity(lineage: randomBase32(lineageLength),
                         generation: "0",
                         serial: randomBase32(serialLength),
                         issuer: issuer, origin: origin, machine: machine,
                         born: UInt64(max(now.timeIntervalSince1970, 1)))
    }

    /// A copy of this instance: same lineage, one generation deeper.
    ///
    /// `index` is which child this is, for readability only - uniqueness
    /// comes from the fresh serial, so two callers racing to make the
    /// "first" clone produce different identities rather than a collision.
    ///
    /// Returns nil past `maximumDepth`, so a caller must decide what to do
    /// rather than silently producing an identity nothing can parse.
    public func copy(index: Int, origin: String, machine: String, issuer: String,
                     now: Date = Date()) -> InstanceIdentity? {
        guard depth + 1 <= Self.maximumDepth, index >= 1, index <= 9999 else { return nil }
        return InstanceIdentity(lineage: lineage,
                                generation: "\(generation).\(index)",
                                serial: Self.randomBase32(Self.serialLength),
                                issuer: issuer, origin: origin, machine: machine,
                                born: UInt64(max(now.timeIntervalSince1970, 1)))
    }

    // MARK: - Signing

    /// Signs and returns the full token.
    public func signed(with key: Curve25519.Signing.PrivateKey) throws -> String {
        let signature = try key.signature(for: Data(payload.utf8))
        return token(signature: signature.base64EncodedString())
    }

    /// Parses **and** verifies a stored token against the keys this Mac
    /// accepts.
    ///
    /// One call, because the two must never come apart: a parsed identity
    /// that has not been verified looks exactly like a trustworthy one, and
    /// somebody would eventually use it as if it were.
    public static func verify(token: String,
                              accepting keys: [String: Curve25519.Signing.PublicKey]) throws
        -> InstanceIdentity {
        let (payload, signature) = try split(token: token)
        let identity = try parse(payload: payload)
        guard let key = keys[identity.issuer] else {
            throw Invalid.unknownIssuer(identity.issuer)
        }
        guard let raw = Data(base64Encoded: signature) else { throw Invalid.badSignature }
        guard key.isValidSignature(raw, for: Data(payload.utf8)) else { throw Invalid.badSignature }
        return identity
    }
}
