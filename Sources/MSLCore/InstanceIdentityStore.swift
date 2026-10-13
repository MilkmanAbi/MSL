// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import CryptoKit

/// The key this Mac signs instance identities with.
///
/// **Not the MSLAP admin key.** The admin does not sign each instance -
/// the admin writes a *rule* about identities, and the rule lives in the
/// already-signed policy. That separation is what keeps the policy format
/// untouched, and it is also what makes issuing possible at all: a fleet
/// keeps its admin key off the machine, so an instance created there could
/// never be signed if the admin had to do it.
///
/// Lives in `/Users/Shared/MSL` beside the MSLAP keys, and the reason is
/// sharper than "convention". `mac_home` shares `NSHomeDirectory()` into
/// every guest, **writable** - so a key anywhere in the home folder is
/// readable by any Linux terminal in any instance.  `/Users/Shared` is a
/// sibling of the home directory, not a child, so it is outside that share.
/// See `READMES/32-PROTECTED-INSTANCES.md` §1.
public enum InstanceIdentityKey {
    static var fileURL: URL {
        MSLAPKeyStore.directory.appendingPathComponent("machine-key")
    }

    /// Creates the key on first use and returns it.
    ///
    /// **Honest about what it is worth:** `mslhd` runs as the user, from a
    /// binary in the user's own home, so a key it can read to sign with,
    /// the user can read to sign with. This makes identities
    /// *tamper-evident* and accident-proof, not unforgeable. The
    /// unforgeable tier is an admin-signed lineage certificate, signed off
    /// the machine - see `READMES/31-INSTANCE-IDENTITY.md` §1.
    /// Why a key is only ever generated when there is **no** key file.
    ///
    /// This used to generate one whenever the read failed for any reason at
    /// all. A key that cannot be read for a moment - a permission, an
    /// interrupted write, a file owned by the other process - is not the
    /// same as a Mac that has never had one, and treating them alike mints a
    /// brand new signing authority and orphans every identity this Mac ever
    /// issued. `msl doctor` then says, for every instance:
    ///
    ///     BAD  <name>'s identity does not verify
    ///          issued by key <old>, which this Mac does not accept
    ///
    /// and there is no way back, because refusing to re-sign an identity is
    /// the entire point of the scheme. Seen here twice, with two different
    /// keys, after the file was replaced underneath.
    ///
    /// So a missing file means a first run and a new key. A file that is
    /// there and unreadable is an error, said out loud.
    public static func load() throws -> Curve25519.Signing.PrivateKey {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8),
           let key = try? MSLAPSigning.privateKey(fromBase64: text) {
            return key
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw IdentityKeyError.unreadable(fileURL.path)
        }
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(
            at: MSLAPKeyStore.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try key.rawRepresentation.base64EncodedString()
            .write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
        try pin(key.publicKey)
        return key
    }

    /// This Mac's id, which is its machine key's id. Used as an identity's
    /// `machine` field: the Mac an instance was born on.
    public static func machineID() -> String? {
        guard let key = try? load() else { return nil }
        return MSLAPSigning.keyID(for: key.publicKey)
    }

    // MARK: - Which signers this Mac accepts

    static var acceptedURL: URL {
        MSLAPKeyStore.directory.appendingPathComponent("identity-signers.json")
    }

    /// Public keys whose identities this Mac will verify.
    ///
    /// Fails **closed** when the store is not protected, exactly as
    /// `MSLAPKeyStore.pinned()` does: a directory anyone can write is a
    /// directory where anyone can add their own signer and issue whatever
    /// they like. `/Users/Shared` is world-writable by default on macOS,
    /// which is why the subdirectory is 0700 and why that is verified
    /// rather than assumed.
    public static func accepted() -> [String: Curve25519.Signing.PublicKey] {
        guard MSLAPKeyStore.storeIsProtected() else { return [:] }
        guard let data = try? Data(contentsOf: acceptedURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.compactMapValues { try? MSLAPSigning.publicKey(fromBase64: $0) }
    }

    @discardableResult
    public static func pin(_ key: Curve25519.Signing.PublicKey) throws -> String {
        try FileManager.default.createDirectory(
            at: MSLAPKeyStore.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var all = (try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: acceptedURL))) ?? [:]
        let id = MSLAPSigning.keyID(for: key)
        all[id] = key.rawRepresentation.base64EncodedString()
        try JSONEncoder().encode(all).write(to: acceptedURL, options: .atomic)
        return id
    }
}

/// Each instance's identity, on disk.
///
/// One small JSON file per instance under `identity/`, matching
/// `resources/`, `sandbox/` and `ssh/`. The file holds the signed token and
/// nothing else that matters - everything is inside the token, so the file
/// is a container rather than a second source of truth that could disagree
/// with it.
/// Why this Mac's signing key could not be used. Deliberately not a silent
/// fallback: everything downstream treats a new key as a new authority.
public enum IdentityKeyError: Error, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let path):
            return "MSL's signing key at \(path) is there but cannot be read. "
                 + "It has not been replaced - doing that would make every instance "
                 + "on this Mac unverifiable. Check the file's permissions."
        }
    }
}

public enum InstanceIdentityStore {

    public static func directory(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("identity", isDirectory: true)
    }

    public static func file(for instance: String,
                            appSupport: URL = MSLPaths.appSupport) -> URL {
        directory(appSupport: appSupport).appendingPathComponent("\(instance).json")
    }

    /// Files in `identity/` that are not an instance's identity.
    ///
    /// `migration.json` lives here because it IS identity state and
    /// belongs beside the rest of it - but `all()` scans this directory by
    /// filename, so without this it read as an instance called
    /// `migration` and `msl identity` reported it as state left by a
    /// removed instance. Caught on the first live run.
    ///
    /// Reserved rather than excluded ad hoc, so an instance can never be
    /// created with a name that would collide: see
    /// `CLICommands.nameRefusal`, which refuses names MSL itself owns for
    /// the same reason.
    public static let reservedNames: Set<String> = ["migration"]

    struct Stored: Codable {
        /// The full `MSLI1:…~signature` token.
        var token: String
        /// What the token said when it was written, for a status line
        /// without a verify. **Never trusted** - anything that decides
        /// something re-verifies the token.
        var display: String?
        /// Whether the matching marker has ever been written inside the
        /// guest.
        ///
        /// **This is what separates "new" from "deleted".** Without it, a
        /// first boot and a guest whose witness somebody removed look
        /// identical - and treating the second as the first means
        /// rewriting the marker, which stamps this instance's identity
        /// onto whatever disk is actually there. Absent means false, which
        /// is right for every record written before this field existed.
        var witnessed: Bool?
    }

    /// Whether the guest-side marker has ever been written for this
    /// instance.
    public static func hasBeenWitnessed(_ instance: String,
                                        appSupport: URL = MSLPaths.appSupport) -> Bool {
        guard let data = try? Data(contentsOf: file(for: instance, appSupport: appSupport)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        return stored.witnessed ?? false
    }

    /// Records that it has been. Leaves the token untouched.
    @discardableResult
    public static func markWitnessed(_ instance: String,
                                     appSupport: URL = MSLPaths.appSupport) -> Bool {
        let url = file(for: instance, appSupport: appSupport)
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        stored.witnessed = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let updated = try? encoder.encode(stored) else { return false }
        return (try? updated.write(to: url, options: .atomic)) != nil
    }

    /// What this Mac knows about an instance's identity.
    public enum Verdict: Equatable, Sendable {
        /// No identity recorded.
        case unidentified
        /// Verified against an accepted signer.
        case valid(InstanceIdentity)
        /// Present, and does not verify. The signal that matters.
        case invalid(String)

        public var identity: InstanceIdentity? {
            if case .valid(let identity) = self { return identity }
            return nil
        }
    }

    /// Reads and **verifies** in one step, so a caller cannot hold an
    /// unverified identity and mistake it for a checked one.
    public static func verdict(for instance: String,
                               appSupport: URL = MSLPaths.appSupport,
                               accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> Verdict {
        guard let data = try? Data(contentsOf: file(for: instance, appSupport: appSupport)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .unidentified }
        do {
            return .valid(try InstanceIdentity.verify(
                token: stored.token, accepting: keys ?? InstanceIdentityKey.accepted()))
        } catch {
            return .invalid("\(error)")
        }
    }

    /// The recorded token, **unverified**, for moving, re-signing and
    /// writing into the guest.
    ///
    /// Unverified on purpose: the guest-side marker has to carry exactly
    /// what the host holds, byte for byte, so the comparison between the
    /// two can be string equality. Verifying here would be the wrong
    /// question - whether this Mac accepts the signer is
    /// `verdict(for:)`'s job, and it is asked separately.
    public static func rawToken(for instance: String,
                         appSupport: URL = MSLPaths.appSupport) -> String? {
        guard let data = try? Data(contentsOf: file(for: instance, appSupport: appSupport)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return stored.token
    }

    @discardableResult
    public static func write(_ identity: InstanceIdentity, for instance: String,
                             signedWith key: Curve25519.Signing.PrivateKey,
                             appSupport: URL = MSLPaths.appSupport) -> Bool {
        guard let token = try? identity.signed(with: key) else { return false }
        // `witnessed` deliberately starts absent: a newly issued identity
        // has no marker inside the guest yet, whatever the previous one
        // did. A rename re-signs and so resets it, which is correct - the
        // marker holds the old token and has to be rewritten.
        let stored = Stored(token: token, display: identity.displayForm, witnessed: nil)
        let url = file(for: instance, appSupport: appSupport)
        guard MSLPaths.ensureDirectory(url.deletingLastPathComponent()) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: - Issuing

    /// Gives a brand-new instance a brand-new lineage.
    ///
    /// Best-effort: an instance that could not be issued one reads as
    /// `unidentified`, which the acceptance rules already have an answer
    /// for. A failure here must never stop an instance being created -
    /// that would make a new feature able to break the oldest one.
    @discardableResult
    public static func issueFresh(for instance: String,
                                  appSupport: URL = MSLPaths.appSupport) -> InstanceIdentity? {
        // **Never over an identity that already exists.** Ordering made
        // this necessary and it is right regardless: importing a shipment
        // records its lineage first, and `ensureRegistered` then runs and
        // would have issued a fresh generation-0 identity straight over
        // the top - turning every import into an original, which is the
        // exact laundering the migration rule exists to prevent.
        //
        // An identity that fails to verify is also left alone: replacing
        // it would destroy the evidence of tampering.
        if case .unidentified = verdict(for: instance, appSupport: appSupport) {} else {
            return verdict(for: instance, appSupport: appSupport).identity
        }
        guard let key = try? InstanceIdentityKey.load(),
              let machine = InstanceIdentityKey.machineID() else { return nil }
        let identity = InstanceIdentity.issue(
            origin: instance, machine: machine,
            issuer: MSLAPSigning.keyID(for: key.publicKey))
        guard write(identity, for: instance, signedWith: key, appSupport: appSupport) else {
            return nil
        }
        return identity
    }

    /// Gives a clone an identity deriving from its parent's.
    ///
    /// **A clone is ISSUED an identity, never handed a copy of one.** That
    /// is the whole mechanism: the copy keeps the parent's lineage, so an
    /// administrator who forbids copies of that lineage catches it, and
    /// gains a generation, so the depth says how far from the original it
    /// is.
    ///
    /// If the parent has no usable identity, the clone gets a fresh lineage
    /// - because inventing a parent would be a lie, and refusing to record
    /// anything would leave the copy looking like an original either way.
    @discardableResult
    public static func issueCopy(of parent: String, to copy: String,
                                 appSupport: URL = MSLPaths.appSupport)
        -> InstanceIdentity? {
        guard let key = try? InstanceIdentityKey.load(),
              let machine = InstanceIdentityKey.machineID() else { return nil }
        let issuer = MSLAPSigning.keyID(for: key.publicKey)

        guard case .valid(let parentIdentity) = verdict(for: parent, appSupport: appSupport) else {
            return issueFresh(for: copy, appSupport: appSupport)
        }
        // The next free index among this lineage's recorded children, so
        // the path reads sensibly. Uniqueness does not depend on it - the
        // serial handles that - so a race produces an odd-looking path
        // rather than a collision.
        let index = nextChildIndex(of: parentIdentity, appSupport: appSupport,
                                   accepting: InstanceIdentityKey.accepted())
        guard let identity = parentIdentity.copy(
            index: index, origin: copy, machine: machine, issuer: issuer) else {
            // Past the depth cap. Recorded as what it is rather than
            // silently restarted as an original: a copy sixteen deep is
            // still a copy.
            return nil
        }
        guard write(identity, for: copy, signedWith: key, appSupport: appSupport) else { return nil }
        return identity
    }

    /// Records what an imported instance says about itself.
    ///
    /// **An import is a copy by definition, and that is the whole point.**
    /// Whatever the shipment's token claims, the instance arriving here is
    /// not the one that was packed - so it is recorded one generation
    /// deeper, which is what makes `instance.clone` refuse it on a Mac
    /// where copying is forbidden. That closes the route the whole feature
    /// was asked about: export where cloning is allowed, import where it
    /// is not.
    ///
    /// **The token is read, never trusted.** It was signed by a key the
    /// sender holds and this Mac has no reason to accept, so it is parsed
    /// for what it says and re-signed locally. That is safe in the only
    /// direction that matters: claiming a lineage can make an instance
    /// *more* restricted here, never less, and the generation is forced
    /// deeper regardless of what the token claims - so a crafted shipment
    /// cannot arrive looking like an original.
    ///
    /// `machine` is preserved from the token, so the Mac an instance was
    /// born on survives being passed along even though the signature does
    /// not.
    @discardableResult
    public static func adoptImported(_ token: String?, as instance: String,
                                     appSupport: URL = MSLPaths.appSupport)
        -> InstanceIdentity? {
        guard let key = try? InstanceIdentityKey.load(),
              let machine = InstanceIdentityKey.machineID() else { return nil }
        let issuer = MSLAPSigning.keyID(for: key.publicKey)

        // No token, or one this version cannot read: a fresh lineage. Not
        // a pretence of provenance MSL does not have.
        guard let token,
              let parsed = try? InstanceIdentity.parse(
                  payload: (try? InstanceIdentity.split(token: token))?.payload ?? token)
        else { return issueFresh(for: instance, appSupport: appSupport) }

        let index = nextChildIndex(of: parsed, appSupport: appSupport,
                                  accepting: InstanceIdentityKey.accepted())
        guard let identity = parsed.copy(index: index, origin: instance,
                                         machine: parsed.machine, issuer: issuer) else {
            // Past the depth cap - a shipment of a shipment of a shipment,
            // sixteen deep. Recorded as a fresh lineage rather than
            // silently flattened to generation 0 of the original's, which
            // would read as the original itself.
            _ = machine
            return issueFresh(for: instance, appSupport: appSupport)
        }
        guard write(identity, for: instance, signedWith: key, appSupport: appSupport) else {
            return nil
        }
        return identity
    }

    /// Re-signs an identity under a new instance name on rename.
    ///
    /// `origin` is deliberately **not** updated - it is the name at birth,
    /// and keeping it is what stops a rename escaping a policy scope.
    @discardableResult
    public static func reSign(for instance: String,
                              appSupport: URL = MSLPaths.appSupport) -> InstanceIdentity? {
        guard let key = try? InstanceIdentityKey.load() else { return nil }
        guard case .valid(let identity) = verdict(for: instance, appSupport: appSupport) else {
            return nil
        }
        let reissued = InstanceIdentity(
            lineage: identity.lineage, generation: identity.generation,
            serial: identity.serial,
            issuer: MSLAPSigning.keyID(for: key.publicKey),
            origin: identity.origin, machine: identity.machine, born: identity.born)
        guard write(reissued, for: instance, signedWith: key, appSupport: appSupport) else {
            return nil
        }
        return reissued
    }

    public static func forget(instance: String, appSupport: URL = MSLPaths.appSupport) {
        try? FileManager.default.removeItem(at: file(for: instance, appSupport: appSupport))
    }

    // MARK: - Reading across every instance

    /// Every recorded identity, by instance name. Unverified entries are
    /// included as `.invalid` rather than dropped, because "this one does
    /// not verify" is the finding, not an absence.
    public static func all(appSupport: URL = MSLPaths.appSupport,
                           accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> [String: Verdict] {
        let accepted = keys ?? InstanceIdentityKey.accepted()
        guard let files = try? FileManager.default.contentsOfDirectory(
            atPath: directory(appSupport: appSupport).path) else { return [:] }
        var result: [String: Verdict] = [:]
        for file in files where file.hasSuffix(".json") {
            let name = String(file.dropLast(".json".count))
            guard !reservedNames.contains(name) else { continue }
            result[name] = verdict(for: name, appSupport: appSupport, accepting: accepted)
        }
        return result
    }

    /// `accepting` is threaded through rather than defaulted inside,
    /// because defaulting it here reads the real key store - so a caller
    /// working against another directory saw every sibling as unverified,
    /// counted none of them, and handed out index 1 every time. Found by
    /// its own test.
    static func nextChildIndex(of parent: InstanceIdentity,
                               appSupport: URL = MSLPaths.appSupport,
                               accepting keys: [String: Curve25519.Signing.PublicKey]? = nil) -> Int {
        let prefix = parent.generation + "."
        let used = all(appSupport: appSupport, accepting: keys).values.compactMap { verdict -> Int? in
            guard let identity = verdict.identity, identity.lineage == parent.lineage,
                  identity.generation.hasPrefix(prefix) else { return nil }
            // Direct children only: `0.1.1` is a grandchild of `0`.
            let tail = identity.generation.dropFirst(prefix.count)
            return tail.contains(".") ? nil : Int(tail)
        }
        return (used.max() ?? 0) + 1
    }

    /// Instances whose identities claim the same serial.
    ///
    /// **Self-contradictory rather than merely unproven**, which is why
    /// this is the one verdict refused even on an unmanaged Mac: two
    /// registered instances cannot both be the same instance, so somebody
    /// copied something.
    public static func duplicateSerials(appSupport: URL = MSLPaths.appSupport,
                                        accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> [String: [String]] {
        var bySerial: [String: [String]] = [:]
        for (name, verdict) in all(appSupport: appSupport, accepting: keys) {
            guard let identity = verdict.identity else { continue }
            bySerial[identity.serial, default: []].append(name)
        }
        return bySerial.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }
}
