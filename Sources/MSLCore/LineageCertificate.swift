// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import CryptoKit

/// An administrator's signed statement about a lineage: *this image is
/// mine*, or *this image is retired*.
///
/// **This is the one tier a local user cannot forge**, and it is worth
/// being exact about why. Plan 31 §1.1 measured the ceiling: `mslhd` runs
/// as the user, from a binary in the user's own home, so the *machine* key
/// that signs instance identities is readable by the person using the Mac.
/// Those identities are tamper-evident, not unforgeable.
///
/// A lineage certificate is different because it is signed **off the
/// machine**, with the fleet key that `msl admin pin` already distributes
/// the public half of. Nobody holding only this Mac can mint one. They can
/// delete it, and they can replace the daemon so nothing checks - but they
/// cannot produce a valid certificate for a lineage of their own.
///
/// So this answers *"is this genuinely the company's image, blessed by the
/// company?"* with certainty. It does not answer *"has the user stopped MSL
/// from asking?"* - see `READMES/31-INSTANCE-IDENTITY.md` §1.2.
public struct LineageCertificate: Codable, Equatable, Sendable {

    public static let formatVersion = 1

    /// What the administrator is saying about this lineage.
    public enum Trust: String, Codable, Sendable {
        /// This image is ours. Carries a label people can read.
        case certified
        /// This image is retired, or has leaked. **Refused wherever this
        /// certificate is installed**, whatever else the policy allows -
        /// which is the point: a revocation that an ordinary capability
        /// could override would be no revocation at all.
        case revoked
    }

    public var format: Int
    public var lineage: String
    public var trust: Trust
    /// Shown to whoever is looking - "Acme Standard Image 2026".
    public var label: String
    /// Who signed it, for display. The *authority* comes from the
    /// signature, never from this string.
    public var issuer: String?
    public var issued: Date
    /// Why, for a revocation. Shown in the refusal.
    public var reason: String?
    public var signature: Signature?

    public struct Signature: Codable, Equatable, Sendable {
        public var alg: String
        public var key: String
        public var value: String

        public init(alg: String = "ed25519", key: String, value: String) {
            self.alg = alg
            self.key = key
            self.value = value
        }
    }

    public init(lineage: String, trust: Trust, label: String,
                issuer: String? = nil, issued: Date = Date(),
                reason: String? = nil, signature: Signature? = nil) {
        self.format = Self.formatVersion
        self.lineage = lineage
        self.trust = trust
        self.label = label
        self.issuer = issuer
        self.issued = issued
        self.reason = reason
        self.signature = signature
    }

    /// Hand-written so a certificate from a newer MSL, carrying fields
    /// this build has never heard of, still decodes - the lesson the
    /// capability catalogue and the shipment manifest both learned. Every
    /// optional really is optional.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? Self.formatVersion
        lineage = try container.decode(String.self, forKey: .lineage)
        trust = try container.decodeIfPresent(Trust.self, forKey: .trust) ?? .certified
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "an administrator's image"
        issuer = try container.decodeIfPresent(String.self, forKey: .issuer)
        issued = try container.decodeIfPresent(Date.self, forKey: .issued) ?? Date(timeIntervalSince1970: 1)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        signature = try container.decodeIfPresent(Signature.self, forKey: .signature)
    }

    /// The bytes a signature covers: this certificate with the signature
    /// removed, sorted keys.
    ///
    /// Both halves matter, for exactly the reasons `MSLAPSigning
    /// .canonicalBytes` spells out: without removing the signature there
    /// is nothing to sign over, and without sorted keys a valid signature
    /// starts failing at random, which looks precisely like tampering.
    public func canonicalBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(unsigned)
    }

    public func signed(with key: Curve25519.Signing.PrivateKey) throws -> LineageCertificate {
        var copy = self
        copy.signature = nil
        let bytes = try copy.canonicalBytes()
        copy.signature = Signature(key: MSLAPSigning.keyID(for: key.publicKey),
                                   value: try key.signature(for: bytes).base64EncodedString())
        return copy
    }

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case unsigned
        case unsupportedFormat(Int)
        case unknownKey(String)
        case badAlgorithm(String)
        case mismatch
        case malformedLineage

        public var description: String {
            switch self {
            case .unsigned:
                return "this certificate is not signed, so there is no way to tell who wrote it"
            case .unsupportedFormat(let found):
                return "this certificate is format \(found), which this version of MSL cannot read"
            case .unknownKey(let id):
                return "signed by key \(id), which is not pinned on this Mac - "
                     + "`msl admin pin` adds a signer"
            case .badAlgorithm(let alg):
                return "unsupported signature algorithm '\(alg)'"
            case .mismatch:
                return "the signature does not match - this certificate has been edited since "
                     + "it was signed"
            case .malformedLineage:
                return "the lineage in this certificate is not a lineage MSL could have issued"
            }
        }
    }

    /// Checks a certificate against the keys this Mac has pinned **for
    /// MSLAP**.
    ///
    /// Deliberately `MSLAPKeyStore.pinned()` and not the identity signers:
    /// a certificate is an administrator's statement, so the authority
    /// behind it has to be the administrator's key - the same one that
    /// signs the policy. Accepting an identity signer here would let the
    /// machine key certify its own lineages, which is the whole thing this
    /// tier exists not to allow.
    public func verify(pinned: [String: Curve25519.Signing.PublicKey]) -> Invalid? {
        guard format <= Self.formatVersion else { return .unsupportedFormat(format) }
        guard lineage.count == InstanceIdentity.lineageLength,
              lineage.allSatisfy({ InstanceIdentity.alphabet.contains($0) })
        else { return .malformedLineage }
        guard let signature else { return .unsigned }
        guard signature.alg.lowercased() == "ed25519" else { return .badAlgorithm(signature.alg) }
        guard let key = pinned[signature.key] else { return .unknownKey(signature.key) }
        guard let raw = Data(base64Encoded: signature.value),
              let bytes = try? canonicalBytes() else { return .mismatch }
        return key.isValidSignature(raw, for: bytes) ? nil : .mismatch
    }
}

/// The lineage certificates installed on this Mac.
///
/// Two locations, mirroring `MSLAPPolicyStore` because the trust question
/// is the same one: a root-owned directory cannot be added to by a
/// non-admin, and a user-owned one can. The strength is reported, never
/// inferred.
public enum LineageCertificateStore {
    public static var systemDirectory: URL {
        URL(fileURLWithPath: "/Library/Application Support/MSL/lineages")
    }
    public static var userDirectory: URL {
        MSLPaths.appSupport.appendingPathComponent("lineages", isDirectory: true)
    }

    /// Where a certificate for this lineage is, preferring the system
    /// location - so a user-writable copy can never shadow an
    /// administrator's.
    public static func file(for lineage: String) -> URL? {
        for directory in [systemDirectory, userDirectory] {
            let candidate = directory.appendingPathComponent("\(lineage).json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public enum Verdict: Equatable, Sendable {
        /// No certificate for this lineage.
        case none
        /// Verified, and the administrator vouches for it.
        case certified(label: String, issuer: String?, rootOwned: Bool)
        /// Verified, and the administrator has withdrawn it.
        case revoked(label: String, reason: String?)
        /// Present and does not verify.
        case invalid(String)
    }

    public static func verdict(for lineage: String,
                               pinned: [String: Curve25519.Signing.PublicKey]? = nil) -> Verdict {
        guard let url = file(for: lineage) else { return .none }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let certificate = try? decoder.decode(LineageCertificate.self, from: data)
        else { return .invalid("it is not a certificate MSL can read") }
        if let problem = certificate.verify(pinned: pinned ?? MSLAPKeyStore.pinned()) {
            return .invalid("\(problem)")
        }
        switch certificate.trust {
        case .certified:
            return .certified(label: certificate.label, issuer: certificate.issuer,
                              rootOwned: MSLAPPolicyStore.isRootOwnedAndProtected(url))
        case .revoked:
            return .revoked(label: certificate.label, reason: certificate.reason)
        }
    }

    /// Writes one into the user location. The system location needs `sudo`,
    /// which belongs at a terminal rather than behind a daemon.
    public static func install(_ certificate: LineageCertificate) throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory,
                                                withIntermediateDirectories: true)
        let url = userDirectory.appendingPathComponent("\(certificate.lineage).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(certificate).write(to: url, options: .atomic)
        return url
    }

    /// Every installed certificate, by lineage, for a status listing.
    public static func all(pinned: [String: Curve25519.Signing.PublicKey]? = nil)
        -> [String: Verdict] {
        var found: [String: Verdict] = [:]
        // User first then system, so a system certificate overwrites the
        // entry a user one put there - the same precedence as `file(for:)`.
        for directory in [userDirectory, systemDirectory] {
            guard let files = try? FileManager.default
                .contentsOfDirectory(atPath: directory.path) else { continue }
            for file in files where file.hasSuffix(".json") {
                let lineage = String(file.dropLast(".json".count))
                found[lineage] = verdict(for: lineage, pinned: pinned)
            }
        }
        return found
    }
}
