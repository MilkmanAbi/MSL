import Foundation
import CryptoKit

/// The administrator password that unlocks the MSL Admin Portal panel.
///
/// **This is not a cryptographic control and must not be described as one.**
/// It gates the panel so a passer-by cannot flip settings on an unlocked
/// Mac. What actually protects a policy is its signature (it cannot be
/// forged) and its location (it cannot be written). Those three do
/// different jobs and the UI keeps them apart.
///
/// Stored as a PBKDF2-SHA256 hash with a per-install random salt, never the
/// password, beside the signing keys in `/Users/Shared/MSL`. Not the
/// Keychain: a daemon cannot answer a Keychain prompt, and
/// `SecItemCopyMatching` blocks forever when it tries - see
/// [[msl-publicmsl]].
public enum MSLAPAdminPassword {
    static var fileURL: URL {
        MSLAPKeyStore.directory.appendingPathComponent("mslap-admin.json")
    }

    /// High enough to make guessing expensive, low enough that unlocking a
    /// panel still feels instant.
    static let iterations = 310_000

    private struct Stored: Codable {
        let salt: String
        let hash: String
        let iterations: Int
    }

    public static var isSet: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public static func set(_ password: String) throws {
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let hash = derive(password: password, salt: salt, iterations: iterations)
        let stored = Stored(salt: salt.base64EncodedString(),
                            hash: hash.base64EncodedString(),
                            iterations: iterations)
        try FileManager.default.createDirectory(
            at: MSLAPKeyStore.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    /// Failed attempts, so guessing costs time.
    ///
    /// 310k PBKDF2 rounds make one guess expensive, but nothing stopped a
    /// script making thousands of them, and the panel would answer every
    /// one instantly after the first. The delay is held in memory rather
    /// than on disk on purpose: persisting it would let someone lock an
    /// administrator out of their own panel by failing a few times and
    /// walking away.
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var lockedUntil: Date?
    private static let lock = NSLock()

    /// Nil when a guess is allowed, otherwise how long to wait.
    public static func throttleRemaining() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let until = lockedUntil, until > Date() else { return nil }
        return until.timeIntervalSinceNow
    }

    public static func verify(_ password: String) -> Bool {
        if let _ = throttleRemaining() { return false }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let salt = Data(base64Encoded: stored.salt),
              let expected = Data(base64Encoded: stored.hash) else { return false }
        let actual = derive(password: password, salt: salt, iterations: stored.iterations)
        // Constant-time: a length check and an early return would leak how
        // much of a guess was right.
        guard actual.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(actual, expected) { difference |= a ^ b }
        let matched = difference == 0
        lock.lock()
        if matched {
            failures = 0
            lockedUntil = nil
        } else {
            failures += 1
            // Nothing for the first few - a mistyped password is normal -
            // then a delay that doubles, capped so it cannot become a
            // permanent lockout.
            if failures >= 3 {
                let seconds = min(pow(2.0, Double(failures - 2)), 60)
                lockedUntil = Date().addingTimeInterval(seconds)
            }
        }
        lock.unlock()
        return matched
    }

    /// For tests, and for the panel after a successful unlock.
    public static func resetThrottle() {
        lock.lock(); failures = 0; lockedUntil = nil; lock.unlock()
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// PBKDF2-SHA256, built from CryptoKit's HMAC so there is no
    /// CommonCrypto bridging to get wrong.
    static func derive(password: String, salt: Data, iterations: Int) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        // One 32-byte block is all that is needed for SHA256 output.
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var result = u
        for _ in 1..<max(iterations, 1) {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for index in 0..<result.count { result[index] ^= u[index] }
        }
        return result
    }
}
