// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Whether an instance may start, given what its identity says.
///
/// See `READMES/31-INSTANCE-IDENTITY.md` §5. Pure and injected, so the
/// decision can be exercised against every combination without a virtual
/// machine, a policy file or a key store anywhere near it - which matters
/// more here than almost anywhere else in MSL, because this runs on the
/// boot path of every instance.
public enum InstanceAdmission {

    /// Everything the decision depends on. Passed in rather than looked up
    /// for the reason above.
    public struct Situation: Sendable {
        public let instance: String
        public let verdict: InstanceIdentityStore.Verdict
        /// Other instances claiming this one's serial.
        public let duplicates: [String]
        /// Nil on an unmanaged Mac.
        public let policy: MSLAPPolicy?
        /// What the administrator has certified about this instance's
        /// lineage, if anything.
        public let certificate: LineageCertificateStore.Verdict

        /// Whether one of the conflicting instances is itself named by the
        /// identity's `origin`.
        ///
        /// If two of them both match - which takes deliberate work - the
        /// tiebreak is genuinely ambiguous and every one is refused.
        public let duplicatesClaimOrigin: Bool
        /// Whether an unidentified instance may be given an identity now -
        /// `InstanceIdentityMigration.mayAdopt`. Defaults to false so a
        /// test has to opt in rather than accidentally exercise adoption.
        public let mayAdopt: Bool

        public init(instance: String, verdict: InstanceIdentityStore.Verdict,
                    duplicates: [String] = [], policy: MSLAPPolicy? = nil,
                    duplicatesClaimOrigin: Bool = false,
                    mayAdopt: Bool = false,
                    certificate: LineageCertificateStore.Verdict = .none) {
            self.certificate = certificate
            self.duplicatesClaimOrigin = duplicatesClaimOrigin
            self.mayAdopt = mayAdopt
            self.instance = instance
            self.verdict = verdict
            self.duplicates = duplicates
            self.policy = policy
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Allowed, but something is worth saying in the log.
        case allowWithNote(String)
        case refuse(String)

        public var isRefusal: Bool {
            if case .refuse = self { return true }
            return false
        }

        public var note: String? {
            switch self {
            case .allow: return nil
            case .allowWithNote(let text), .refuse(let text): return text
            }
        }
    }

    /// Whether a capability is allowed for this instance **and** for the
    /// name it was born under.
    ///
    /// **Both names, and that is the whole point of a signed `origin`.**
    /// MSLAP scopes match by instance name, so a copy of `Company` called
    /// `Sneaky` is not matched by a scope on `Company*`. Checking only the
    /// current name would make renaming a copy the way around every rule
    /// written about the original - the same escape found in the rename
    /// work two weeks ago.
    static func allows(_ capability: String, _ situation: Situation) -> Bool {
        guard let policy = situation.policy else { return true }
        let needle = MSLAPCapability(capability)
        guard policy.allows(needle, instance: situation.instance) else { return false }
        if let origin = situation.verdict.identity?.origin, origin != situation.instance {
            return policy.allows(needle, instance: origin)
        }
        return true
    }

    /// Nil-safe reason text, for a refusal that has to explain itself.
    static func reason(_ capability: String, _ situation: Situation) -> String {
        guard let policy = situation.policy else { return "" }
        let needle = MSLAPCapability(capability)
        let name = policy.allows(needle, instance: situation.instance)
            ? (situation.verdict.identity?.origin ?? situation.instance)
            : situation.instance
        let decision = policy.decision(for: needle, instance: name)
        var text = "refused by MSL Admin Portal: \(capability) is not allowed"
        if name != situation.instance {
            text += " for '\(name)', the name it was created under"
        }
        if let why = decision.deniedBy?.reason { text += " - \(why)" }
        if let issuer = policy.issuer { text += ". Set by \(issuer)." }
        return text
    }

    /// The decision.
    public static func decide(_ situation: Situation) -> Decision {
        // **Refused with no policy at all, and it is the only such case.**
        // Two registered instances cannot both be the same instance, so one
        // of them is a copy that did not come through MSL. That is
        // self-contradictory rather than merely unproven, which is what
        // separates it from everything below - and refusing the one asking
        // to start cannot strand anybody's only copy, because the other is
        // still there.
        if !situation.duplicates.isEmpty {
            // **Which one is the original is answerable, and `origin` is
            // the answer.** It is the name the instance was created under
            // and it is signed, so copying an identity file onto a second
            // instance cannot make that second name match it.
            //
            // Without this the refusal was symmetric - both instances
            // refused, neither startable - which punished the person for a
            // copy they may not have made and left them with nothing
            // running. Now the original starts and the copy is refused.
            // Measured as symmetric on a live Mac before the tiebreak
            // existed; that is how it was found.
            if situation.verdict.identity?.origin == situation.instance,
               !situation.duplicatesClaimOrigin {
                return .allowWithNote(
                    "\(situation.instance) shares its identity with "
                    + "\(situation.duplicates.joined(separator: ", ")) - started because this is "
                    + "the name it was created under, so the other one is the copy.")
            }
            return .refuse(
                "\(situation.instance) and \(situation.duplicates.joined(separator: ", ")) claim to be "
                + "the same instance"
                + (situation.verdict.identity.map { ", which was created as '\($0.origin)'" } ?? "")
                + ". This one is the copy, and a copy that did not come through MSL is not "
                + "started. `msl identity` says more; removing it clears this.")
        }

        // **A revocation outranks everything, including no policy at
        // all.** It is an administrator's signed statement that an image
        // is retired or has leaked, signed OFF this machine - so nobody
        // holding only this Mac could have minted it, and a capability
        // that could override it would make it no revocation at all.
        if case .revoked(let label, let reason) = situation.certificate {
            // **No claim about where the key is.** An earlier draft said
            // "signed by a key held off this Mac", which is true of a
            // fleet and false in local admin mode - where the private key
            // is right here and its own `msl admin status` line says so.
            // Asserting it in a refusal would be the feature
            // overstating itself at the worst possible moment.
            var text = "\(situation.instance) is an instance of \(label), which has been "
                     + "withdrawn by its administrator."
            if let reason, !reason.isEmpty { text += " Reason: \(reason)." }
            return .refuse(text + " No capability can set a revocation aside - "
                           + "`msl admin status` shows how strongly it is held.")
        }

        switch situation.verdict {
        case .valid(let identity):
            // A copy answers to `instance.clone`, which is exactly what was
            // asked for: one switch blocks the button AND refuses a copy
            // that arrived some other way.
            // A fleet that wants only images it blessed. Checked before
            // the copy rule, because "this is not our image at all" is a
            // more basic objection than "this is a copy of one".
            if case .none = situation.certificate,
               !allows("instance.acceptUncertified", situation) {
                return .refuse(
                    reason("instance.acceptUncertified", situation)
                    + " \(situation.instance)'s lineage carries no certificate from this "
                    + "deployment's administrator.")
            }
            if case .invalid(let why) = situation.certificate {
                return .refuse(
                    "\(situation.instance)'s lineage certificate does not verify: \(why)")
            }
            if identity.isClone, !allows("instance.clone", situation) {
                return .refuse(
                    reason("instance.clone", situation)
                    + " This instance is copy \(identity.generation) of its lineage"
                    + (identity.origin == situation.instance ? "" : ", created as '\(identity.origin)'")
                    + ".")
            }
            return .allow

        case .invalid(let why):
            // Somebody edited it. On a managed Mac that is a refusal; with
            // no policy it is reported loudly and allowed, because
            // enforcement exists to serve an administrator's stated intent
            // and there is none to serve. The rule
            // `MSLAPEnforcement.check` already states: loud and working
            // beats silent and bricked.
            guard situation.policy != nil else {
                return .allowWithNote(
                    "\(situation.instance)'s identity does not verify (\(why)) - allowed because "
                    + "this Mac is not managed, but something edited it.")
            }
            return .refuse(
                "\(situation.instance)'s identity does not verify: \(why) "
                + "An instance whose provenance has been edited is not started on a managed Mac. "
                + "`msl identity \(situation.instance)` says more.")

        case .unidentified:
            // Every instance in existence before this feature is here, so
            // it allows by default and refuses only when an administrator
            // asks for it by name.
            guard !allows("instance.acceptUnidentified", situation) else {
                // Adoption, and **only where it cannot launder a copy.**
                // `InstanceIdentityMigration.mayAdopt` is the rule: before
                // the one-shot pass, or on an unmanaged Mac, yes;
                // afterwards on a managed Mac, never - everything that
                // existed then has an identity, so one without appeared
                // since, and handing it a fresh generation-0 lineage would
                // bless a copy as an original.
                // Reported as a state, not as an action: this function
                // is pure and issues nothing. `adoptIfAllowed` below does
                // the issuing, before the decision is taken, so by the
                // time an adopted instance reaches here its verdict is
                // already `.valid`. Seeing this note means adoption was
                // permitted and did not happen - worth saying, because the
                // usual cause is an unwritable key store.
                if situation.mayAdopt {
                    return .allowWithNote(
                        "\(situation.instance) has no identity and one could not be issued "
                        + "for it - check that \(MSLAPKeyStore.directory.path) is writable.")
                }
                return .allow
            }
            return .refuse(
                reason("instance.acceptUnidentified", situation)
                + " \(situation.instance) carries no provenance, so MSL cannot tell whether it "
                + "is an original or a copy.")
        }
    }

    /// The decision for a live instance, reading the real stores.
    ///
    /// Separate from `decide` so the decision stays testable without
    /// touching the machine, and so there is exactly one place that knows
    /// how to assemble the situation.
    public static func decide(instance: String,
                              appSupport: URL = MSLPaths.appSupport) -> Decision {
        let managed = MSLAPGate.policy != nil
        let mayAdopt = InstanceIdentityMigration.mayAdopt(appSupport: appSupport, managed: managed)
        // **Adoption happens here, before the decision, and only here.**
        // Doing it before means an adopted instance is judged on the
        // identity it now has rather than on the absence it had a moment
        // ago, so there is one answer rather than two that disagree.
        if mayAdopt {
            adoptIfAllowed(instance: instance, appSupport: appSupport)
        }
        let accepted = InstanceIdentityKey.accepted()
        let verdict = InstanceIdentityStore.verdict(
            for: instance, appSupport: appSupport, accepting: accepted)
        var duplicates: [String] = []
        if let serial = verdict.identity?.serial {
            duplicates = (InstanceIdentityStore.duplicateSerials(
                appSupport: appSupport, accepting: accepted)[serial] ?? [])
                .filter { $0 != instance }
        }
        return decide(Situation(instance: instance, verdict: verdict,
                                duplicates: duplicates, policy: MSLAPGate.policy,
                                // A rival that is also named by `origin`
                                // makes the tiebreak ambiguous.
                                duplicatesClaimOrigin: duplicates.contains {
                                    $0 == verdict.identity?.origin
                                },
                                mayAdopt: mayAdopt,
                                certificate: verdict.identity.map {
                                    LineageCertificateStore.verdict(for: $0.lineage)
                                } ?? .none))
    }

    /// Gives an unidentified instance an identity, where that cannot
    /// launder a copy.
    ///
    /// Only ever for an instance with NO identity: one that does not
    /// verify is left exactly as it is, because overwriting it would
    /// destroy the evidence of tampering and replace it with a clean
    /// original - the single worst thing this code could do.
    static func adoptIfAllowed(instance: String, appSupport: URL) {
        guard case .unidentified = InstanceIdentityStore.verdict(
            for: instance, appSupport: appSupport) else { return }
        guard InstanceIdentityStore.issueFresh(
            for: instance, appSupport: appSupport) != nil else { return }
        MSLLog.line("identity", "\(instance): had no identity, issued one")
    }
}
