import Foundation

/// Finds and loads the MSLAP policy, and reports honestly how strong it is.
///
/// The strength question is the whole point. MSL runs as the user, so a
/// policy in the user's own library is advisory; one owned by root is not.
/// An administrator who believes they are managed while sitting on an
/// advisory policy is the failure this type exists to prevent, so the
/// provenance travels with the policy everywhere it goes.
public enum MSLAPPolicyStore {
    /// Root-owned, world-readable. Installing here needs one `sudo` at
    /// enrolment, and it is what makes the policy unwritable by the person
    /// using the Mac.
    public static var systemURL: URL {
        URL(fileURLWithPath: "/Library/Application Support/MSL/policy.json")
    }

    /// The user's own copy - for trying a policy out. Writable by its
    /// owner, so it can only ever be advisory.
    public static var userURL: URL {
        MSLPaths.appSupport.appendingPathComponent("policy.json")
    }

    /// Whether a file is genuinely beyond this user's reach: owned by root
    /// and not writable by group or world.
    ///
    /// **Checked, not assumed from the path.** Reporting "Enforceable"
    /// because a file sits under /Library would be a lie if the file were
    /// user-owned, and an administrator reading that line is deciding
    /// whether to trust this machine. `/Library/Application Support` is
    /// root-owned on a stock macOS, but it is group-writable by admin on
    /// some systems and a policy placed there by a non-root user would
    /// otherwise claim the top rung.
    static func isRootOwnedAndProtected(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path) else { return false }
        let owner = attributes[.ownerAccountID] as? NSNumber
        guard owner?.uint32Value == 0 else { return false }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        else { return false }
        // No group or world write bit.
        return permissions & 0o022 == 0
    }

    /// Where a loaded policy came from, and therefore what it is worth.
    public enum Source: String, Sendable {
        case system
        case user

        public var isWritableByUser: Bool { self == .user }
    }

    /// How much a deployment actually guarantees. Reported by
    /// `msl admin status` and shown in the panel, never inferred by eye.
    public enum Strength: Int, Sendable, Comparable {
        /// A policy the person using the Mac can simply edit.
        case advisory = 1
        /// User-writable, but signed: it can be deleted, not forged.
        case tamperEvident = 2
        /// Root-owned and signed. Enforceable against a non-admin user.
        case enforceable = 3

        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .advisory: return "Advisory"
            case .tamperEvident: return "Tamper-evident"
            case .enforceable: return "Enforceable"
            }
        }

        /// Deliberately blunt. Somebody is going to deploy on the strength
        /// of this sentence.
        public var detail: String {
            switch self {
            case .advisory:
                return "This policy is in a file the person using this Mac can edit. "
                     + "It stops accidents, not someone who wants around it."
            case .tamperEvident:
                return "This policy is signed, so it cannot be altered without detection - "
                     + "but it lives in a file the person using this Mac can delete."
            case .enforceable:
                return "This policy is owned by root and signed. Someone who is not an "
                     + "administrator of this Mac cannot change or remove it."
            }
        }
    }

    /// What `load` found. A policy always arrives with its provenance.
    public struct Loaded: Sendable {
        public let policy: MSLAPPolicy
        public let source: Source
        public let url: URL
        /// True when a pinned key verified it. Nil means unsigned or
        /// unverifiable, which caps strength at `.advisory`.
        public let signatureValid: Bool?
        /// Why verification did not succeed, for the UI. "Nobody signed
        /// this" and "somebody changed this" are very different news.
        public let signatureProblem: MSLAPSigning.Failure?
        /// Which pinned key signed it, when one did.
        public let signedBy: String?

        public init(policy: MSLAPPolicy, source: Source, url: URL,
                    signatureValid: Bool?, signatureProblem: MSLAPSigning.Failure? = nil,
                    signedBy: String? = nil) {
            self.policy = policy
            self.source = source
            self.url = url
            self.signatureValid = signatureValid
            self.signatureProblem = signatureProblem
            self.signedBy = signedBy
        }

        /// True only when the file is really beyond this user's reach.
        public var rootProtected: Bool { MSLAPPolicyStore.isRootOwnedAndProtected(url) }

        public var strength: Strength {
            switch (source, signatureValid) {
            // The system PATH is not enough - the file has to actually be
            // root-owned and not group-writable.
            case (.system, true) where rootProtected: return .enforceable
            case (.system, true): return .tamperEvident
            case (.user, true): return .tamperEvident
            // Unsigned is advisory wherever it sits: root ownership stops
            // the person editing the file, but says nothing about whether
            // what is in it came from the administrator.
            default: return .advisory
            }
        }
    }

    /// Why no policy is in force. Absence and tampering are different
    /// things and must not be reported as one.
    public enum Failure: Error, Equatable, Sendable {
        case none
        case unreadable(path: String)
        case malformed(path: String, detail: String)
        case schemaTooNew(path: String, schema: Int)
        case needsNewerMSL(path: String, required: String)
        /// The policy was altered after signing, or signed by a key this
        /// Mac does not trust.
        case signatureInvalid(path: String, detail: String)
    }

    public enum Result: Sendable {
        case managed(Loaded)
        /// Working normally, with nothing to enforce.
        case unmanaged
        /// A policy is there and cannot be honoured. **Never silently the
        /// same as unmanaged**: a deployment that switches off when its
        /// file is corrupted is not a deployment.
        ///
        /// `fallback` is the last policy that verified, and it is what
        /// stays in force. Tampering must never GRANT anything.
        case broken(Failure, fallback: MSLAPPolicy? = nil)
    }

    /// The system path wins when both exist, so a user copy cannot shadow
    /// a managed one.
    public static func load(currentVersion: String = MSLVersion.marketing) -> Result {
        for (url, source) in [(systemURL, Source.system), (userURL, Source.user)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else {
                return .broken(.unreadable(path: url.path))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let policy: MSLAPPolicy
            do {
                policy = try decoder.decode(MSLAPPolicy.self, from: data)
            } catch {
                return .broken(.malformed(path: url.path, detail: "\(error)"))
            }
            guard policy.schema <= MSLAPPolicy.currentSchema else {
                return .broken(.schemaTooNew(path: url.path, schema: policy.schema))
            }
            if let required = policy.minimumMSLVersion,
               MSLVersion.compare(currentVersion, isAtLeast: required) == false {
                return .broken(.needsNewerMSL(path: url.path, required: required))
            }
            switch MSLAPSigning.verify(policy, pinned: MSLAPKeyStore.pinned()) {
            case .success(let keyID):
                rememberGood(policy)
                return .managed(Loaded(policy: policy, source: source, url: url,
                                       signatureValid: true, signedBy: keyID))
            case .failure(let problem):
                // A policy whose signature does not MATCH has been edited
                // since it was signed, and that is tampering, not weakness:
                // honouring it would mean honouring whatever the editor
                // wrote. Being unsigned, or signed by a key this Mac has
                // not pinned, is merely unverifiable - the policy still
                // applies, at Advisory strength, because refusing it would
                // break every machine that never enrolled a key.
                if problem == .mismatch || problem == .unknownKey(id: policy.signature?.key ?? "") {
                    return .broken(.signatureInvalid(path: url.path, detail: problem.detail),
                                   fallback: lastGood())
                }
                return .managed(Loaded(policy: policy, source: source, url: url,
                                       signatureValid: nil, signatureProblem: problem))
            }
        }
        return .unmanaged
    }

    // MARK: - Last known good

    /// The last policy that verified, kept so tampering cannot GRANT
    /// anything.
    ///
    /// **Without this, signing makes a deployment weaker, not stronger.**
    /// A tampered policy is refused - correctly - and if refusing simply
    /// meant "unmanaged", then editing the file would be the easiest way
    /// to remove every restriction on the machine. So a verified policy is
    /// remembered, and a broken one falls back to it rather than to
    /// freedom. Removing the restrictions then requires removing the
    /// fallback too, which lives beside the pinned keys where a non-admin
    /// user cannot reach it.
    public static var lastGoodURL: URL {
        MSLAPKeyStore.directory.appendingPathComponent("mslap-last-good.json")
    }

    static func rememberGood(_ policy: MSLAPPolicy) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(policy) else { return }
        try? FileManager.default.createDirectory(
            at: MSLAPKeyStore.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: lastGoodURL, options: .atomic)
    }

    static func lastGood() -> MSLAPPolicy? {
        guard let data = try? Data(contentsOf: lastGoodURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MSLAPPolicy.self, from: data)
    }

    /// Forgetting the fallback is itself an administrative act, so it is
    /// deliberate and separate from editing the policy.
    public static func forgetLastGood() throws {
        try? FileManager.default.removeItem(at: lastGoodURL)
    }

    // MARK: - Cached access

    /// Cheap repeated access for hot paths like the daemon's control loop.
    ///
    /// Reloading the file on every control request would be wasteful;
    /// caching it until the daemon restarts would mean an administrator's
    /// change does not apply until something is rebooted, which is a bad
    /// answer when the change is "stop allowing that". So the cache is
    /// invalidated by the file's modification date and size - one `stat`
    /// per request instead of a parse.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stamp: (date: Date, size: Int)?
        private var value: Result = .unmanaged
        private var loaded = false

        func get() -> Result {
            lock.lock(); defer { lock.unlock() }
            let current = Self.stamp(of: systemURL) ?? Self.stamp(of: userURL)
            if loaded, stamp?.date == current?.date, stamp?.size == current?.size {
                return value
            }
            value = load()
            stamp = current
            loaded = true
            return value
        }

        private static func stamp(of url: URL) -> (date: Date, size: Int)? {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path) else { return nil }
            let date = attributes[.modificationDate] as? Date ?? .distantPast
            let size = attributes[.size] as? Int ?? 0
            return (date, size)
        }
    }

    private static let cache = Cache()

    /// The current state, re-read only when the policy file has changed.
    public static func cached() -> Result { cache.get() }

    /// The policy in force, or nil when unmanaged.
    ///
    /// **A broken policy denies nothing here, and callers must not treat
    /// that as permission.** `load` reports `.broken` precisely so the app
    /// and CLI can refuse loudly; this convenience exists for read-only
    /// display, not for gating.
    public static func current() -> MSLAPPolicy? {
        if case .managed(let loaded) = load() { return loaded.policy }
        return nil
    }
}
