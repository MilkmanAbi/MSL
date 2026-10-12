// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// What has to be true before an instance can be renamed or cloned, and
/// why each one is a refusal rather than a warning.
///
/// Both operations are "the same instance under another name", and that is
/// exactly what makes them dangerous in a managed deployment: **MSLAP
/// scopes match by instance name.** A policy that denies `instance.delete`
/// for `Ubuntu` says nothing about `Ubuntu2`, so a rename would be a
/// one-command way out of every rule written about an instance, and a clone
/// would hand over its disk with none of them attached. That is the first
/// thing checked here.
public enum InstanceRename {

    public enum Blocker: Equatable, CustomStringConvertible {
        case noSuchInstance(String)
        case alreadyExists(String)
        case invalidName(String)
        case sameName
        case running(String)
        case busy(String)
        /// Hibernated or suspended state, which cannot survive the change.
        case savedState(String, snapshots: [String])
        /// The rename or clone would leave a scope that restricts it.
        case escapesPolicy(capability: String, from: String, to: String)
        case atCapacity(limit: Int)

        public var description: String {
            switch self {
            case .noSuchInstance(let name):
                return "no such instance '\(name)'"
            case .alreadyExists(let name):
                return "'\(name)' already exists - pick another name"
            case .invalidName(let name):
                return "'\(name)' isn't a usable instance name: letters, numbers, - and _, up to 32 characters"
            case .sameName:
                return "that is already its name"
            case .running(let name):
                return "\(name) is running - stop it first (`msl stop \(name)`)"
            case .busy(let name):
                return "\(name) is starting or under maintenance - try again when that finishes"
            case .savedState(let name, let snapshots):
                // Spelled out because the alternative - renaming anyway -
                // produces `VZErrorDomain Code=12 "invalid argument"` on
                // the next start, which tells the person nothing at all.
                var text = "\(name) has saved memory that cannot move with it: a guest's network address "
                    + "is derived from its name, and macOS refuses to restore a saved VM whose address "
                    + "has changed. Start \(name) once to use the saved state up"
                if !snapshots.isEmpty {
                    text += ", and delete its snapshot\(snapshots.count == 1 ? "" : "s") "
                        + "(\(snapshots.joined(separator: ", ")))"
                }
                return text + "."
            case .escapesPolicy(let capability, let from, let to):
                return "refused by MSL Admin Portal: \(capability) is denied for '\(from)' but not for "
                     + "'\(to)', so this would be a way around it"
            case .atCapacity(let limit):
                return "already at the \(limit)-instance limit - remove one before cloning"
            }
        }
    }

    /// Every capability a policy denies for `from` but allows for `to`.
    ///
    /// **This is the check that makes renaming and cloning safe to offer at
    /// all.** Without it, `lab-*` denied `shipment.export` is undone by
    /// renaming `lab-3` to `mine`, and a policy is only ever as strong as
    /// the names it happens to mention.
    ///
    /// Compared over the whole catalogue rather than a chosen few, because
    /// the one that matters is whichever one the administrator wrote, and a
    /// shortlist would be a guess about that.
    ///
    /// Deliberately one-directional: moving INTO a more restricted name is
    /// fine, by the same rule as everywhere else in MSLAP - an operation
    /// that reduces what can be done is never refused.
    public static func policyEscapes(from: String, to: String,
                                     policy: MSLAPPolicy?) -> [String] {
        guard let policy else { return [] }
        return MSLAPCapability.catalogue.compactMap { entry in
            let deniedHere = !policy.allows(entry.capability, instance: from)
            let allowedThere = policy.allows(entry.capability, instance: to)
            return (deniedHere && allowedThere) ? entry.capability.key : nil
        }
    }

    /// The state of the instance as the caller sees it. Passed in rather
    /// than discovered, because only the daemon knows what is running and
    /// only it can say what is mid-maintenance.
    public struct Situation {
        public let exists: Bool
        public let targetExists: Bool
        public let isRunning: Bool
        public let isBusy: Bool
        public let hasSavedState: Bool
        public let snapshots: [String]
        public let instanceCount: Int
        public let policy: MSLAPPolicy?

        public init(exists: Bool, targetExists: Bool, isRunning: Bool, isBusy: Bool,
                    hasSavedState: Bool, snapshots: [String], instanceCount: Int,
                    policy: MSLAPPolicy?) {
            self.exists = exists
            self.targetExists = targetExists
            self.isRunning = isRunning
            self.isBusy = isBusy
            self.hasSavedState = hasSavedState
            self.snapshots = snapshots
            self.instanceCount = instanceCount
            self.policy = policy
        }
    }

    /// Nil when the rename may go ahead.
    public static func renameBlocker(from old: String, to new: String,
                                     situation: Situation) -> Blocker? {
        if let shared = sharedBlocker(from: old, to: new, situation: situation) { return shared }
        // Saved memory blocks a RENAME and not a clone: the clone keeps the
        // original's name, and so its address, while the copy simply starts
        // cold. Only moving a name invalidates saved state.
        if situation.hasSavedState || !situation.snapshots.isEmpty {
            return .savedState(old, snapshots: situation.snapshots)
        }
        return nil
    }

    /// Nil when the clone may go ahead.
    public static func cloneBlocker(from source: String, to copy: String,
                                    situation: Situation) -> Blocker? {
        if let shared = sharedBlocker(from: source, to: copy, situation: situation) { return shared }
        // A clone is a new instance, so it counts against the ceiling.
        if situation.instanceCount >= InstanceRegistry.maxInstances {
            return .atCapacity(limit: InstanceRegistry.maxInstances)
        }
        return nil
    }

    private static func sharedBlocker(from old: String, to new: String,
                                      situation: Situation) -> Blocker? {
        guard situation.exists else { return .noSuchInstance(old) }
        guard old != new else { return .sameName }
        guard InstanceRegistry.isValidName(new) else { return .invalidName(new) }
        guard !situation.targetExists else { return .alreadyExists(new) }
        guard !situation.isBusy else { return .busy(old) }
        // Running blocks both: the source's disk is open, and cloning a
        // live ext4 image captures it mid-write - the same corruption two
        // instances sharing one image used to cause.
        guard !situation.isRunning else { return .running(old) }
        if let escaped = policyEscapes(from: old, to: new, policy: situation.policy).first {
            return .escapesPolicy(capability: escaped, from: old, to: new)
        }
        return nil
    }
}
