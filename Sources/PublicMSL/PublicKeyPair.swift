// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

/// The key MSL generates so *this Mac* can reach a published instance
/// straight away.
///
/// ## Why it is not in Application Support
///
/// MSL shares the whole home directory into every guest as `/mnt/mac`, and
/// virtiofs hands guest root whatever the Mac user can read. So a key under
/// `~/Library/Application Support/MSL` is readable from inside **any**
/// instance - measured, not assumed:
///
/// ```
/// $ msl Ubuntu find /mnt/mac/Library -path '*MSL/ssh*'
/// /mnt/mac/Library/Application Support/MSL/ssh/msl_ed25519
/// ```
///
/// That is survivable for the local key, which only opens instances on this
/// Mac to somebody already inside one. It is not survivable for a key that
/// opens an instance *from the internet*: one compromised guest would hand
/// out a public foothold on another. Which is the whole reason the public
/// key is separate from the local one, so putting it in the same directory
/// would have been a separate key and no actual separation.
///
/// The per-user temporary directory is outside the share and a guest cannot
/// traverse into it, so that is where it lives.
///
/// ## What that costs, and why it is the right trade
///
/// The directory is cleared on restart, so the key does not survive one.
/// That is fine, because it is a convenience and not the mechanism: a key
/// here is for "let me get in from this Mac right now". A machine you
/// actually intend to reach - the other laptop, a colleague - is
/// authorized by its *own* public key with `msl public authorize`, which
/// persists in the guest and never moves a private key anywhere. When this
/// key is regenerated, stale copies are purged from `authorized_keys` by
/// their comment, so they do not pile up.
public enum PublicKeyPair {
    /// Beside the other secret MSL keeps, and for the same reason.
    ///
    /// This used to be the per-user temporary directory, which kept it out
    /// of the guests but threw it away on every restart - so a Mac that
    /// rebooted came back with a working tunnel and a key nobody had any
    /// more. `/Users/Shared/MSL` is outside the home directory, so outside
    /// the share, **and** it persists, which makes the temporary directory
    /// simply the worse of two options once this one existed.
    ///
    /// The directory is created 0700 and its ownership verified before use
    /// - /Users/Shared is world-writable, so another account could
    /// otherwise put a directory there first.
    public static var directory: URL {
        ResendCredentials.secureDirectory()?.appendingPathComponent("keys", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MSL-public")
    }

    /// Where an earlier MSL put it. Cleaned up so a stale copy is not left
    /// lying about after an upgrade.
    static var legacyTemporaryDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MSL-public")
    }

    /// Where the first version put these: inside the home directory, and
    /// so readable from every guest through /mnt/mac.
    public static var legacyDirectory: URL {
        MSLPaths.appSupport.appendingPathComponent("public")
    }

    /// Deletes keys an older MSL left in the shared home directory.
    ///
    /// Only the key files: that directory also holds the policy and pid
    /// files this version still uses.
    public static func removeLegacyKeys(log: (String) -> Void = { _ in }) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: legacyDirectory.path)
        else { return }
        for name in names where name.hasPrefix("msl_public_") {
            try? manager.removeItem(at: legacyDirectory.appendingPathComponent(name))
            log("removed \(name), left where any instance could read it by an older MSL")
        }
    }

    public static func removeLegacyTemporaryKeys() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: legacyTemporaryDirectory.path)
        else { return }
        for name in names where name.hasPrefix("msl_public_") {
            try? manager.removeItem(at: legacyTemporaryDirectory.appendingPathComponent(name))
        }
    }

    public static func privateKeyURL(instance: String) -> URL {
        directory.appendingPathComponent("msl_public_\(instance)")
    }

    public static func publicKeyURL(instance: String) -> URL {
        directory.appendingPathComponent("msl_public_\(instance).pub")
    }

    /// Makes one if there is not one already, and returns the public half
    /// ready for `authorized_keys`.
    ///
    /// Ed25519 with no passphrase: a passphrase on a key a daemon must use
    /// unattended only moves the secret somewhere else.
    ///
    /// Returns nil rather than throwing when a key cannot be made - the
    /// convenience key is not required for publishing, and losing it should
    /// degrade the feature, not block it.
    public static func ensure(instance: String) -> String? {
        let fileManager = FileManager.default
        let directory = Self.directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        // Re-asserted every time: the directory may predate this version,
        // and a key is only as private as the directory holding it.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let privateKey = privateKeyURL(instance: instance)
        let publicKey = publicKeyURL(instance: instance)
        if fileManager.fileExists(atPath: publicKey.path), fileManager.fileExists(atPath: privateKey.path),
           let existing = try? String(contentsOf: publicKey, encoding: .utf8) {
            return normalize(existing, instance: instance)
        }
        // A half-written pair - one file but not the other - would make
        // ssh-keygen refuse rather than overwrite.
        try? fileManager.removeItem(at: privateKey)
        try? fileManager.removeItem(at: publicKey)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-N", "", "-q",
                             // The comment is how stale copies are found in
                             // `authorized_keys` later, so it is fixed
                             // rather than descriptive.
                             "-C", "msl-public-convenience-\(instance)",
                             "-f", privateKey.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = try? String(contentsOf: publicKey, encoding: .utf8) else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
        return normalize(text, instance: instance)
    }

    /// One line, with the marker the guest side greps for.
    private static func normalize(_ raw: String, instance: String) -> String? {
        guard let key = PublicHardening.sanitizedPublicKey(raw) else { return nil }
        return "\(key) msl-public-convenience-\(instance)"
    }

    /// Whether the private key is still on disk - the temporary directory
    /// is cleared on restart, so this is not a given.
    public static func privateKeyExists(instance: String) -> Bool {
        FileManager.default.fileExists(atPath: privateKeyURL(instance: instance).path)
    }

    public static func remove(instance: String) {
        try? FileManager.default.removeItem(at: privateKeyURL(instance: instance))
        try? FileManager.default.removeItem(at: publicKeyURL(instance: instance))
    }
}
