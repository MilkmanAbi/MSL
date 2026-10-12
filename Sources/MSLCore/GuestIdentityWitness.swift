// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// The copy of an instance's identity that lives **inside** the guest.
///
/// The host record alone cannot catch one attack: replacing the disk under
/// a name whose identity is perfectly valid. Swap `lab-1.img` for a copy of
/// `Company.img` and every host-side check passes, because the host record
/// was never touched.
///
/// So the token is also written into the guest's own filesystem. The host
/// record does not travel with the disk; this does. When the two disagree,
/// the disk is not the one the record describes.
///
/// See `READMES/31-INSTANCE-IDENTITY.md` §4.
public enum GuestIdentityWitness {

    /// Inside the guest. `/etc` exists on all twelve images.
    public static let guestPath = "/etc/msl-instance"

    /// What comparing the two homes says.
    public enum Finding: Equatable, Sendable {
        /// They agree. The disk is the one the record describes.
        case consistent
        /// Nothing inside the guest yet, and nothing has ever been written
        /// - a new instance on its first boot. Write one.
        case notYetWritten
        /// One was written and is now gone.
        ///
        /// **Inconclusive, never a pass and never a refusal.** Guest root
        /// is unpoliced by design, so a guest can always delete its own
        /// witness - what it cannot do is forge a valid one. A guest can
        /// make itself inconclusive; it cannot make itself innocent.
        case missing
        /// Present, and says it belongs to a different lineage. **The
        /// disk was swapped.**
        case differentLineage(found: String, expected: String)
        /// Present and does not parse or verify.
        case unreadable(String)
        /// The host has no identity to compare against.
        case nothingToCompare
    }

    /// Compares the two.
    ///
    /// Pure, and takes the guest's bytes as a string, so every combination
    /// is testable without a virtual machine - which matters because this
    /// decides whether to shut an instance down.
    public static func compare(hostToken: String?, guestContents: String?,
                               everWritten: Bool,
                               accepting keys: [String: Any] = [:]) -> Finding {
        guard let hostToken, let hostIdentity = try? InstanceIdentity.parse(
            payload: (try? InstanceIdentity.split(token: hostToken))?.payload ?? hostToken)
        else { return .nothingToCompare }

        let trimmed = guestContents?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return everWritten ? .missing : .notYetWritten
        }
        // Byte-identical is the common case and the cheapest check: the
        // token is stored in both homes in the same form precisely so this
        // is string equality rather than field-by-field logic that could
        // drift.
        if trimmed == hostToken { return .consistent }

        guard let found = try? InstanceIdentity.parse(
            payload: (try? InstanceIdentity.split(token: trimmed))?.payload ?? trimmed)
        else { return .unreadable("the witness inside the guest is not a readable identity") }

        // **Lineage, not serial.** A legitimate clone's disk starts as a
        // byte copy of its parent's, so its witness says the parent's
        // serial until the first boot rewrites it. Comparing serials would
        // call every fresh clone a swap. Comparing lineage asks the
        // question that matters: is this disk from the family the record
        // claims?
        if found.lineage != hostIdentity.lineage {
            return .differentLineage(found: found.lineage, expected: hostIdentity.lineage)
        }
        // Same family, different generation: a clone on its first boot,
        // still carrying its parent's token. Expected, and the caller
        // rewrites it.
        return .notYetWritten
    }

    /// The shell command that writes the witness.
    ///
    /// `0444` and root-owned: a guest can still remove it - it has root,
    /// and nothing on the host can change that - but an ordinary process
    /// inside the guest will not clobber it by accident, which is the only
    /// thing permissions can buy here.
    public static func writeCommand(token: String) -> String? {
        // Refuse anything that could break out of the single-quoted
        // argument. The token's own alphabet contains none of this, so a
        // value that does is not a token MSL produced.
        guard !token.contains("'"), !token.contains("\n"),
              !token.contains("\\"), !token.contains("`"),
              token.count < 4096 else { return nil }
        return "printf '%s' '\(token)' > \(guestPath) && chmod 0444 \(guestPath)"
    }

    public static let readCommand = "cat \(guestPath) 2>/dev/null || true"

    /// What to do about a finding, and what to say.
    ///
    /// Split from `compare` so the policy decision is one readable table
    /// rather than scattered through the comparison.
    public enum Action: Equatable, Sendable {
        case nothing
        case write
        case report(String)
        /// Shut the instance down. **Cleanly** - see
        /// `DaemonServer.respondToWitness`.
        case stop(String)
    }

    public static func action(for finding: Finding, instance: String,
                              managed: Bool) -> Action {
        switch finding {
        case .consistent, .nothingToCompare:
            return .nothing

        case .notYetWritten:
            return .write

        case .missing:
            // **Never rewritten from the host record.** That is the
            // tempting "self-healing" behaviour and it destroys the
            // feature: it would stamp lab-1's identity onto whatever bytes
            // are actually there, which is the exact swap this exists to
            // catch. Recorded as inconclusive and said out loud.
            return .report(
                "\(instance): the provenance marker inside the guest is gone. It is not "
                + "rewritten, because writing it would stamp this instance's identity onto "
                + "whatever disk is actually there. `msl identity \(instance)` shows what the "
                + "host still records.")

        case .differentLineage(let found, let expected):
            let detail = "\(instance): the disk inside it belongs to lineage \(found), but this "
                       + "instance is recorded as lineage \(expected). The disk has been "
                       + "replaced with a copy of another instance."
            // Managed: stop it. Unmanaged: say so loudly and leave it
            // running, by the rule the enforcement code already states -
            // with no administrator there is no intent to serve, and loud
            // and working beats silent and bricked.
            return managed ? .stop(detail) : .report(detail + " Allowed because this Mac is not managed.")

        case .unreadable(let why):
            return .report("\(instance): \(why). It is not rewritten, for the same reason a "
                         + "missing one is not.")
        }
    }
}
