// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Which instances an administrator means to keep from being copied, and
/// which routes out are still open.
///
/// **An instance is protected because of what the policy already says**,
/// not because of a separate switch. Denying `instance.clone` or
/// `shipment.export` for an instance says "this must not be copied"; MSL
/// reads that as the intent it is and reports accordingly, rather than
/// asking an administrator to state the same thing twice.
///
/// See `READMES/32-PROTECTED-INSTANCES.md`. This type is the whole of step
/// one: no encryption, no new policy, just an honest answer to "is this
/// actually protected?" - because the answer today is usually no, for a
/// reason nobody would guess.
public enum ProtectedInstance {

    /// Why an instance counts as protected. Both reasons mean the same
    /// thing about intent and are reported separately because an
    /// administrator who denied one may simply not have thought of the
    /// other.
    public enum Reason: String, Sendable, CaseIterable {
        case noClone = "instance.clone"
        case noExport = "shipment.export"

        public var intent: String {
            switch self {
            case .noClone: return "cloning is denied"
            case .noExport: return "exporting is denied"
            }
        }
    }

    /// A route by which the instance's **disk image** can still leave this
    /// Mac, and the capability that closes it.
    ///
    /// Deliberately only disk routes. What is *inside* an instance is
    /// readable by anyone who can open a shell in it, and guest root is
    /// unpoliced by design (the capability catalogue says so, and the
    /// reason holds - it cannot be enforced from the host). Listing those
    /// as "leaks" would imply they were closeable. The image file is a
    /// different matter: it is MSL's own file, on the Mac, and MSL decides
    /// who can reach it.
    public struct Gap: Sendable, Equatable {
        public let capability: String
        public let title: String
        public let detail: String
        /// The worst one first, so a report that is read halfway is still
        /// read in the right order.
        public let severity: Int
    }

    /// The Mac's home folder, shared into every guest, writable.
    ///
    /// **This is the gap that matters and it is not obvious.** `mslhd`
    /// shares `NSHomeDirectory()` as `mac_home`, and instance disks live
    /// under it at `Library/Application Support/MSL/disks`. So a Linux
    /// terminal in *any* instance can copy *any* instance's disk with one
    /// `cp`, and - because the share is not read-only - write into one
    /// that is running.
    ///
    /// No Mac administrator rights, no filesystem tricks. Every other
    /// protection is worth very little while this is open, which is why it
    /// is severity 0.
    static let macHomeGap = Gap(
        capability: "sharing.macHome",
        title: "the Mac's home folder is shared into this instance",
        detail: "Any Linux terminal in it can copy any instance's disk image straight out "
              + "of /mnt/mac/Library/Application Support/MSL/disks - and write into one, "
              + "because the share is not read-only. Deny sharing.macHome for this instance.",
        severity: 0)

    /// Whether the policy treats this instance as one that must not be
    /// copied. `nil` policy - an unmanaged Mac - protects nothing, because
    /// there is no administrator whose intent there would be to read.
    public static func reasons(for instance: String, policy: MSLAPPolicy?) -> [Reason] {
        guard let policy else { return [] }
        return Reason.allCases.filter {
            !policy.allows(MSLAPCapability($0.rawValue), instance: instance)
        }
    }

    public static func isProtected(_ instance: String, policy: MSLAPPolicy?) -> Bool {
        !reasons(for: instance, policy: policy).isEmpty
    }

    /// Every disk route still open for a protected instance, worst first.
    ///
    /// Empty for an instance the policy does not protect: an open route is
    /// only a gap against a stated intention to close it, and reporting
    /// "you could copy this" about an instance nobody asked to protect
    /// would be noise that trains people to ignore the real thing.
    public static func gaps(for instance: String, policy: MSLAPPolicy?) -> [Gap] {
        let reasons = reasons(for: instance, policy: policy)
        guard !reasons.isEmpty, let policy else { return [] }
        var found: [Gap] = []

        if policy.allows(MSLAPCapability("sharing.macHome"), instance: instance) {
            found.append(macHomeGap)
        }
        // The other half of the pair, when only one was denied. Someone who
        // denied cloning to protect an image has very likely not thought
        // about a shipment, which copies the whole disk by design.
        if !reasons.contains(.noExport),
           policy.allows(MSLAPCapability("shipment.export"), instance: instance) {
            found.append(Gap(
                capability: "shipment.export",
                title: "it can still be exported as a shipment",
                detail: "A .mslship is the whole disk, compressed - a copy by another name. "
                      + "Deny shipment.export too.",
                severity: 1))
        }
        if !reasons.contains(.noClone),
           policy.allows(MSLAPCapability("instance.clone"), instance: instance) {
            found.append(Gap(
                capability: "instance.clone",
                title: "it can still be cloned",
                detail: "A clone is a second instance with the same contents. "
                      + "Deny instance.clone too.",
                severity: 1))
        }
        return found.sorted { $0.severity < $1.severity }
    }

    /// One line per protected instance, for `msl admin status` and the
    /// panel. Nil when nothing is protected, so callers print nothing
    /// rather than an empty heading.
    public static func summary(instances: [String], policy: MSLAPPolicy?) -> String? {
        let rows: [(String, [Reason], [Gap])] = instances.sorted().compactMap { name in
            let why = reasons(for: name, policy: policy)
            return why.isEmpty ? nil : (name, why, gaps(for: name, policy: policy))
        }
        guard !rows.isEmpty else { return nil }
        var lines: [String] = []
        for (name, why, gaps) in rows {
            let intent = why.map(\.intent).joined(separator: ", ")
            if gaps.isEmpty {
                lines.append("  \(name): protected (\(intent)) - no disk route out")
            } else {
                lines.append("  \(name): protected (\(intent)) - \(gaps.count) route\(gaps.count == 1 ? "" : "s") still open")
                for gap in gaps { lines.append("      \(gap.capability): \(gap.title)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}
