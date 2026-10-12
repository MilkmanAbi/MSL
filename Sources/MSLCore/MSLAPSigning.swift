import Foundation
import CryptoKit

/// Signs and verifies MSLAP policies.
///
/// Signing is what makes a policy *tamper-evident* rather than merely
/// present: the file can be deleted, which is visible, but not altered
/// without detection. Combined with a root-owned path, that is the
/// difference between a suggestion and a managed deployment.
///
/// Ed25519 via CryptoKit - no dependency, and the keys are short enough to
/// paste into a terminal, which matters because a fleet administrator has
/// to move the public half between machines by hand.
public enum MSLAPSigning {

    /// Why a signature did not verify. Each is reported differently,
    /// because "nobody signed this" and "somebody changed this" are very
    /// different situations for an administrator.
    public enum Failure: Error, Equatable, Sendable {
        /// The policy carries no signature at all.
        case unsigned
        /// Signed, but this Mac has pinned no key to check it against.
        case noPinnedKey
        /// Signed by a key this Mac has not pinned.
        case unknownKey(id: String)
        /// The signature does not match the contents. **Someone edited the
        /// policy after it was signed.**
        case mismatch
        case malformed(String)

        public var detail: String {
            switch self {
            case .unsigned:
                return "This policy is not signed, so there is no way to tell who wrote it."
            case .noPinnedKey:
                return "This policy is signed, but no signing key is pinned on this Mac."
            case .unknownKey(let id):
                return "Signed by key \(id), which is not pinned on this Mac."
            case .mismatch:
                return "The signature does not match the policy. It has been edited since it was signed."
            case .malformed(let why):
                return "The signature could not be read: \(why)"
            }
        }
    }

    // MARK: - Canonical bytes

    /// The exact bytes a signature covers: the policy with its `signature`
    /// field removed, encoded with sorted keys.
    ///
    /// **Both halves matter.** Without removing the signature there is
    /// nothing to sign over - the value would have to exist before it was
    /// computed. Without sorted keys the same policy encodes differently on
    /// different runs and a valid signature starts failing at random, which
    /// would look exactly like tampering and send an administrator hunting
    /// something that never happened.
    public static func canonicalBytes(of policy: MSLAPPolicy) throws -> Data {
        var unsigned = policy
        unsigned.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(unsigned)
    }

    // MARK: - Keys

    /// A short, stable identifier for a public key, so a policy can say
    /// which key signed it and a person can compare two by eye.
    public static func keyID(for publicKey: Curve25519.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func publicKey(fromBase64 text: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.malformed("public key is not valid base64")
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    public static func privateKey(fromBase64 text: String) throws -> Curve25519.Signing.PrivateKey {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.malformed("private key is not valid base64")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Sign and verify

    /// Returns the policy with a signature attached.
    public static func sign(_ policy: MSLAPPolicy,
                            with key: Curve25519.Signing.PrivateKey) throws -> MSLAPPolicy {
        var signed = policy
        signed.signature = nil
        let bytes = try canonicalBytes(of: signed)
        let signature = try key.signature(for: bytes)
        signed.signature = MSLAPPolicy.Signature(
            key: keyID(for: key.publicKey),
            value: signature.base64EncodedString())
        return signed
    }

    /// Checks a policy against the keys this Mac has pinned.
    public static func verify(_ policy: MSLAPPolicy,
                              pinned: [String: Curve25519.Signing.PublicKey]) -> Result<String, Failure> {
        guard let signature = policy.signature else { return .failure(.unsigned) }
        guard !pinned.isEmpty else { return .failure(.noPinnedKey) }
        guard signature.alg.lowercased() == "ed25519" else {
            return .failure(.malformed("unsupported algorithm '\(signature.alg)'"))
        }
        guard let key = pinned[signature.key] else {
            return .failure(.unknownKey(id: signature.key))
        }
        guard let raw = Data(base64Encoded: signature.value) else {
            return .failure(.malformed("signature is not valid base64"))
        }
        guard let bytes = try? canonicalBytes(of: policy) else {
            return .failure(.malformed("policy could not be re-encoded for checking"))
        }
        guard key.isValidSignature(raw, for: bytes) else { return .failure(.mismatch) }
        return .success(signature.key)
    }
}

/// The signing keys this Mac trusts, and the private key when MSL is acting
/// as its own administrator.
///
/// Lives in `/Users/Shared/MSL` for the same reasons PublicMSL's secrets
/// do: outside the guest's `/mnt/mac` view, surviving restarts, and not the
/// Keychain - a daemon cannot answer a Keychain prompt, and
/// `SecItemCopyMatching` blocks forever when it tries.
public enum MSLAPKeyStore {
    public static var directory: URL { URL(fileURLWithPath: "/Users/Shared/MSL") }
    static var pinnedURL: URL { directory.appendingPathComponent("mslap-pinned-keys.json") }
    static var localPrivateURL: URL { directory.appendingPathComponent("mslap-local-key") }

    /// Whether the key store itself can be trusted.
    ///
    /// **The signature check is only worth as much as this directory.**
    /// Pinned public keys decide which policies are honoured, so a
    /// directory anyone can write is a directory where anyone can pin
    /// their own key and sign whatever they like. /Users/Shared is
    /// world-writable by default on macOS, which is exactly why the
    /// subdirectory is created 0700 and why that is verified rather than
    /// assumed.
    public static func storeIsProtected() -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: directory.path) else { return false }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        else { return false }
        // Nothing writable by group or other.
        guard permissions & 0o022 == 0 else { return false }
        // And owned by this user or root - not by somebody else entirely.
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? .max
        return owner == 0 || owner == getuid()
    }

    /// Public keys allowed to sign a policy for this Mac, by key id.
    public static func pinned() -> [String: Curve25519.Signing.PublicKey] {
        // An unprotected store pins nothing. Failing closed here is right:
        // the result is that signed policies stop verifying and MSL says
        // so loudly, rather than quietly trusting keys anyone could have
        // written.
        guard storeIsProtected() else { return [:] }
        guard let data = try? Data(contentsOf: pinnedURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues { try? MSLAPSigning.publicKey(fromBase64: $0) }
    }

    @discardableResult
    public static func pin(_ key: Curve25519.Signing.PublicKey) throws -> String {
        try ensureDirectory()
        var all = (try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: pinnedURL))) ?? [:]
        let id = MSLAPSigning.keyID(for: key)
        all[id] = key.rawRepresentation.base64EncodedString()
        try JSONEncoder().encode(all).write(to: pinnedURL, options: .atomic)
        return id
    }

    public static func unpin(_ id: String) throws {
        guard var all = try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: pinnedURL)) else { return }
        all.removeValue(forKey: id)
        try JSONEncoder().encode(all).write(to: pinnedURL, options: .atomic)
    }

    // MARK: - Local admin mode

    /// The private key, when this Mac signs its own policies.
    ///
    /// **Weaker than fleet mode on purpose, and the UI must say so.**
    /// Anyone with root here can read this file and re-sign a policy. What
    /// it still buys is that casually editing the policy breaks it, which
    /// is the whole point for one person locking down their own Mac. A
    /// fleet deployment keeps its private key off the machine entirely.
    public static func localPrivateKey() -> Curve25519.Signing.PrivateKey? {
        guard let text = try? String(contentsOf: localPrivateURL, encoding: .utf8) else { return nil }
        return try? MSLAPSigning.privateKey(fromBase64: text)
    }

    public static var isLocalAdminMode: Bool {
        FileManager.default.fileExists(atPath: localPrivateURL.path)
    }

    /// Creates a local signing key, pins its public half, and returns the id.
    @discardableResult
    public static func createLocalKey() throws -> String {
        try ensureDirectory()
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.base64EncodedString()
            .write(to: localPrivateURL, atomically: true, encoding: .utf8)
        // 0600: the private half is readable only by its owner.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: localPrivateURL.path)
        return try pin(key.publicKey)
    }

    private static func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }
}
