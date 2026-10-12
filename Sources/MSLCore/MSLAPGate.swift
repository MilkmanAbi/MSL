import Foundation

/// The one way host-side code asks whether MSLAP permits something.
///
/// Tier-2 capabilities are refused in the process that performs them,
/// because the daemon never sees them. Every such check goes through here
/// so they all agree about three things that are easy to get subtly
/// different: an unmanaged Mac allows everything, a TAMPERED policy falls
/// back to the last one that verified rather than to freedom, and the
/// reason shown to the person names the rule and its issuer.
public enum MSLAPGate {

    /// The policy in force, including the tamper fallback.
    public static var policy: MSLAPPolicy? {
        switch MSLAPPolicyStore.cached() {
        case .managed(let loaded): return loaded.policy
        case .broken(_, let fallback): return fallback
        case .unmanaged: return nil
        }
    }

    public static func allows(_ capability: String, instance: String?) -> Bool {
        guard let policy else { return true }
        return policy.allows(MSLAPCapability(capability), instance: instance)
    }

    /// Why it was refused, for a tooltip or an error line. Nil when
    /// allowed.
    public static func reason(_ capability: String, instance: String?) -> String? {
        guard let policy else { return nil }
        let decision = policy.decision(for: MSLAPCapability(capability), instance: instance)
        guard !decision.allowed else { return nil }
        var text = "Not allowed by the MSL Admin Portal"
        if let by = decision.deniedByCapability, by != MSLAPCapability(capability) {
            text += " (denied by \(by.key))"
        }
        if let why = decision.deniedBy?.reason { text += ": \(why)" }
        if let issuer = policy.issuer { text += " — set by \(issuer)" }
        return text
    }
}

/// Thrown when an administrator's policy forbids something.
///
/// Carries the reason rather than a bare failure, because every refusal a
/// person sees has to say who decided and why - a managed Mac that will not
/// explain itself is the thing people hate most about managed machines.
public struct MSLAPRefusal: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var localizedDescription: String { description }
}
