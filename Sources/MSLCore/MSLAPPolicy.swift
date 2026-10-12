import Foundation

/// An MSLAP policy: what the person at this Mac may not change.
///
/// Allow-all with explicit denials, so a machine with no policy behaves
/// exactly as MSL always has, and a policy only ever takes things away.
/// See `READMES/30-MSLAP-DESIGN.md` for the threat model - this is a
/// managed-configuration layer, not a boundary against a local admin.
public struct MSLAPPolicy: Codable, Equatable, Sendable {
    /// Bumped only for changes an older build could MISREAD. Added keys do
    /// not count: unknown ones are ignored, so old builds stay safe.
    public static let currentSchema = 1

    public var schema: Int
    public var issued: Date?
    /// Who set this, shown to the managed user. A denial with no author is
    /// the thing people hate most about managed machines.
    public var issuer: String?
    /// MSL refuses to enforce a policy it is too old to understand rather
    /// than enforcing the half it recognises.
    public var minimumMSLVersion: String?
    public var scopes: [Scope]
    public var ui: UIOptions
    /// Shown in the MSLAP panel, e.g. where to ask for an exception.
    public var message: String?
    public var signature: Signature?

    public init(schema: Int = MSLAPPolicy.currentSchema,
                issued: Date? = nil,
                issuer: String? = nil,
                minimumMSLVersion: String? = nil,
                scopes: [Scope] = [],
                ui: UIOptions = UIOptions(),
                message: String? = nil,
                signature: Signature? = nil) {
        self.schema = schema
        self.issued = issued
        self.issuer = issuer
        self.minimumMSLVersion = minimumMSLVersion
        self.scopes = scopes
        self.ui = ui
        self.message = message
        self.signature = signature
    }

    // A hand-written decoder, because Swift's synthesized one IGNORES
    // default values and demands every non-optional key. This document is
    // written by hand by administrators, so a policy that omits `ui` or
    // `scopes` - or `schema`, which most people will forget - must load,
    // not fail with a decoding error about a key they have never heard of.
    private enum CodingKeys: String, CodingKey {
        case schema, issued, issuer, minimumMSLVersion, scopes, ui, message, signature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? MSLAPPolicy.currentSchema
        issued = try c.decodeIfPresent(Date.self, forKey: .issued)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
        minimumMSLVersion = try c.decodeIfPresent(String.self, forKey: .minimumMSLVersion)
        scopes = try c.decodeIfPresent([Scope].self, forKey: .scopes) ?? []
        ui = try c.decodeIfPresent(UIOptions.self, forKey: .ui) ?? UIOptions()
        message = try c.decodeIfPresent(String.self, forKey: .message)
        signature = try c.decodeIfPresent(Signature.self, forKey: .signature)
    }

    /// One rule: which instances it applies to, and what it takes away.
    public struct Scope: Codable, Equatable, Sendable {
        /// `*` for every instance, an exact name, or a `lab-*` style glob.
        /// Matching is case-insensitive, because instance names are.
        public var match: String
        public var deny: [MSLAPCapability]
        /// Optional, for the resolved view: why this rule exists.
        public var reason: String?

        public init(match: String = "*", deny: [MSLAPCapability] = [], reason: String? = nil) {
            self.match = match
            self.deny = deny
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey { case match, deny, reason }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A scope with no `match` means every instance, which is what
            // somebody writing a quick fleet-wide rule expects.
            match = try c.decodeIfPresent(String.self, forKey: .match) ?? "*"
            deny = try c.decodeIfPresent([MSLAPCapability].self, forKey: .deny) ?? []
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        /// Whether this scope applies to an instance. A nil instance means
        /// an app-wide action with no instance in play (installing a
        /// distro, updating MSL); only `*` covers those, because a rule
        /// written for one instance cannot sensibly govern a global action.
        public func matches(instance: String?) -> Bool {
            if match == "*" { return true }
            guard let instance else { return false }
            return Self.glob(match.lowercased(), matches: instance.lowercased())
        }

        /// `*` wildcards only - no character classes. Deliberately small:
        /// an admin writing `lab-*` should not have to reason about regex,
        /// and a surprising match here silently changes what is denied.
        static func glob(_ pattern: String, matches text: String) -> Bool {
            if pattern == "*" { return true }
            let parts = pattern.components(separatedBy: "*")
            if parts.count == 1 { return pattern == text }
            var cursor = text.startIndex
            for (index, part) in parts.enumerated() where !part.isEmpty {
                guard let found = text.range(of: part, range: cursor..<text.endIndex) else { return false }
                // A leading literal must sit at the very start, and a
                // trailing one must reach the very end.
                if index == 0, found.lowerBound != text.startIndex { return false }
                if index == parts.count - 1, found.upperBound != text.endIndex { return false }
                cursor = found.upperBound
            }
            return true
        }
    }

    public struct UIOptions: Codable, Equatable, Sendable {
        /// False by default: a denied control is greyed out WITH its reason
        /// rather than vanishing, so the person learns the rule exists.
        public var hideDeniedControls: Bool
        public init(hideDeniedControls: Bool = false) { self.hideDeniedControls = hideDeniedControls }

        private enum CodingKeys: String, CodingKey { case hideDeniedControls }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hideDeniedControls = try c.decodeIfPresent(Bool.self, forKey: .hideDeniedControls) ?? false
        }
    }

    public struct Signature: Codable, Equatable, Sendable {
        public var alg: String
        /// Identifies which pinned key signed this.
        public var key: String
        /// Base64 Ed25519 signature over the policy with this field removed.
        public var value: String
        public init(alg: String = "ed25519", key: String, value: String) {
            self.alg = alg
            self.key = key
            self.value = value
        }

        private enum CodingKeys: String, CodingKey { case alg, key, value }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alg = try c.decodeIfPresent(String.self, forKey: .alg) ?? "ed25519"
            key = try c.decode(String.self, forKey: .key)
            value = try c.decode(String.self, forKey: .value)
        }
    }

    // MARK: - Resolution

    public struct Decision: Equatable, Sendable {
        public let allowed: Bool
        /// The scope that denied it, for "denied by the rule for lab-*".
        public let deniedBy: Scope?
        /// The catalogue key actually responsible - denying `network`
        /// denies `network.vpn`, and the person should be told which.
        public let deniedByCapability: MSLAPCapability?

        public static let allow = Decision(allowed: true, deniedBy: nil, deniedByCapability: nil)
    }

    /// Whether a capability is permitted for an instance.
    ///
    /// **Deny wins, and a narrower scope never undoes a broader deny.** The
    /// alternative - most-specific-wins - lets a per-instance entry
    /// silently re-enable something a `*` rule took away, which is never
    /// what an admin meant by writing the `*` rule.
    public func decision(for capability: MSLAPCapability, instance: String? = nil) -> Decision {
        for scope in scopes where scope.matches(instance: instance) {
            for denied in scope.deny where denied.covers(capability) {
                return Decision(allowed: false, deniedBy: scope, deniedByCapability: denied)
            }
        }
        return .allow
    }

    public func allows(_ capability: MSLAPCapability, instance: String? = nil) -> Bool {
        decision(for: capability, instance: instance).allowed
    }

    /// Capabilities named in this policy that this build does not know.
    /// Reported, never enforced - a policy written for a newer MSL must not
    /// brick an older one, and must not be silently rewritten either.
    public var unknownCapabilities: [MSLAPCapability] {
        var seen: [MSLAPCapability] = []
        for scope in scopes {
            for denied in scope.deny where MSLAPCapability.entry(for: denied) == nil {
                // A group key like `network` is known if anything beneath
                // it is, since denying a whole group is the point.
                let coversKnown = MSLAPCapability.catalogue.contains { denied.covers($0.capability) }
                if !coversKnown, !seen.contains(denied) { seen.append(denied) }
            }
        }
        return seen
    }
}
