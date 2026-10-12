// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import CryptoKit

/// Issues identities to the instances that already existed, exactly once.
///
/// **Why "exactly once" is the whole design.** The obvious rule - "issue an
/// identity whenever one is missing" - launders clones: `cp Company.img
/// Sneaky.img`, add a registry line, start it, and MSL hands the copy a
/// brand-new generation-0 identity. The copy becomes an original, blessed
/// by us, and every later check agrees it is genuine.
///
/// So adoption is bounded in time rather than open-ended. One pass stamps
/// whatever is on the Mac when the feature arrives - those instances are
/// genuinely of unknown provenance and there is nothing better to say about
/// them - and the pass records that it ran. Afterwards, an instance with no
/// identity is one that appeared *since*, which is a different and much
/// more interesting fact.
///
/// See `READMES/31-INSTANCE-IDENTITY.md` §6.
public enum InstanceIdentityMigration {

    public static func file(appSupport: URL = MSLPaths.appSupport) -> URL {
        InstanceIdentityStore.directory(appSupport: appSupport)
            .appendingPathComponent("migration.json")
    }

    public struct Record: Codable, Equatable, Sendable {
        /// When the pass ran.
        public var completed: Date
        /// What existed at that moment, for the record. Not consulted when
        /// deciding anything - the *fact* that the pass ran is what
        /// matters, since everything that existed then has an identity now.
        /// Kept because an administrator asking "what did this Mac have
        /// before you started tracking?" deserves an answer.
        public var instances: [String]
        /// Signed so the record cannot be back-dated or invented to make a
        /// later arrival look like an old resident.
        public var signature: String?

        var payload: String {
            "MSLM1:\(Int(completed.timeIntervalSince1970)):\(instances.sorted().joined(separator: ","))"
        }
    }

    /// Whether the one-shot pass has run **and** its record verifies.
    ///
    /// A record that does not verify counts as "not run", which is the
    /// conservative answer in the direction that matters: it means MSL will
    /// still adopt, rather than refusing instances because somebody
    /// corrupted a file. The tampering itself is reported separately.
    public static func hasRun(appSupport: URL = MSLPaths.appSupport,
                              accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> Bool {
        record(appSupport: appSupport, accepting: keys) != nil
    }

    /// The verified record, or nil.
    public static func record(appSupport: URL = MSLPaths.appSupport,
                              accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> Record? {
        guard let data = try? Data(contentsOf: file(appSupport: appSupport)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Record.self, from: data),
              let signature = stored.signature,
              let raw = Data(base64Encoded: signature) else { return nil }
        let accepted = keys ?? InstanceIdentityKey.accepted()
        // Any accepted signer: the record says what this Mac did, and a Mac
        // whose key rolled over should not lose its own history.
        for key in accepted.values where key.isValidSignature(raw, for: Data(stored.payload.utf8)) {
            return stored
        }
        return nil
    }

    /// Runs the pass if it has not run. Returns the instances it issued
    /// identities to, or nil if there was nothing to do.
    ///
    /// Idempotent and cheap to call on every daemon start, which is where
    /// it is called from: there is no upgrade hook in MSL, and "the first
    /// time the new daemon runs" is the closest honest equivalent.
    @discardableResult
    public static func runIfNeeded(instances: [String],
                                  appSupport: URL = MSLPaths.appSupport,
                                  now: Date = Date()) -> [String]? {
        guard !hasRun(appSupport: appSupport) else { return nil }
        guard let key = try? InstanceIdentityKey.load() else { return nil }

        var issued: [String] = []
        for name in instances.sorted() {
            // Anything already carrying one keeps it - a reinstall over an
            // existing MSL must not reissue and so renumber everything.
            if case .unidentified = InstanceIdentityStore.verdict(
                for: name, appSupport: appSupport) {
                if InstanceIdentityStore.issueFresh(for: name, appSupport: appSupport) != nil {
                    issued.append(name)
                }
            }
        }

        var record = Record(completed: now, instances: instances.sorted(), signature: nil)
        guard let signature = try? key.signature(for: Data(record.payload.utf8)) else {
            // No record written means the pass will run again next start.
            // Safe: it only ever issues to instances that have none.
            return issued
        }
        record.signature = signature.base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if MSLPaths.ensureDirectory(file(appSupport: appSupport).deletingLastPathComponent()),
           let data = try? encoder.encode(record) {
            try? data.write(to: file(appSupport: appSupport), options: .atomic)
        }
        return issued
    }

    /// Whether an instance with no identity should be given one now.
    ///
    /// **The anti-laundering rule, in one place.**
    ///
    /// - Before the pass has run: yes. Whatever is on the Mac predates the
    ///   feature and there is nothing better to say about it.
    /// - After the pass, on an **unmanaged** Mac: yes. There is no
    ///   administrator to protect, and the alternative is an instance that
    ///   reports a problem forever for no one's benefit.
    /// - After the pass, on a **managed** Mac: **no.** Everything that
    ///   existed at the pass has an identity, so one without is something
    ///   that appeared since - and handing it a fresh generation-0 lineage
    ///   would be exactly the laundering this exists to stop.
    /// `accepting` is threaded through rather than defaulted inside,
    /// because defaulting reads the real key store - the same mistake that
    /// made `nextChildIndex` hand out index 1 for every sibling, found the
    /// same way, by a test against a temporary directory.
    public static func mayAdopt(appSupport: URL = MSLPaths.appSupport,
                                managed: Bool,
                                accepting keys: [String: Curve25519.Signing.PublicKey]? = nil)
        -> Bool {
        guard hasRun(appSupport: appSupport, accepting: keys) else { return true }
        return !managed
    }
}
