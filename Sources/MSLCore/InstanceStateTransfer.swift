// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Moves or copies everything MSL remembers about one instance.
///
/// **Why this is one declared list and not code spread over fifteen
/// stores.** Renaming and cloning both have to touch every place an
/// instance's name appears, and the failure mode for missing one is
/// specific and nasty: the state does not vanish, it stays attached to a
/// name nobody uses - until somebody makes a new instance with that name
/// and inherits a stranger's app list, disk policy or camera permission.
/// MSL has had that bug before, from the other direction, which is why
/// `DaemonServer.removeInstanceState` carries a comment per store
/// explaining what came back to haunt it.
///
/// So the stores are enumerated once, here, with the shape of each one
/// written down, and rename and clone are both expressed as a walk over
/// this list. Adding a per-instance store without adding it here is caught
/// by `InstanceStateTransferTests`, which writes a value into every entry,
/// renames, and insists that nothing of the old name survives anywhere
/// under Application Support.
public enum InstanceStateTransfer {

    /// How a store holds an instance's name.
    ///
    /// Rewriting the JSON generically, rather than decoding each store into
    /// its own type, is deliberate: a decode would need every one of these
    /// files to be readable by this build, and one unknown field in any of
    /// them would silently drop the rest of that file's contents. The whole
    /// point of this operation is to lose nothing.
    public enum Shape: Sendable {
        /// The instance's name is in the filename; the whole file is its
        /// own. `experiments-<name>.json`, `sandbox/<name>.json`.
        case ownFile(name: (String) -> String)
        /// A dictionary at the top level, keyed by the bare instance name.
        case dictionaryKey
        /// A dictionary keyed by the instance name, a separator and
        /// something else - `<name>\u{1F}/usr/bin/gimp`.
        case dictionaryKeyPrefix(separator: String)
        /// A dictionary whose keys wrap the name: `disks/<name>.img`.
        case dictionaryKeyWrapped(prefix: String, suffix: String)
        /// Arrays of instance names living under named fields of one
        /// object: `{"locked": [...]}`, `{"camera": [...]}`.
        case nameArrays(fields: [String])
        /// A top-level ARRAY of objects, each naming its instance in one
        /// field: `[{"instance": "work", "hostPort": 8080, ...}]`.
        ///
        /// `forwards.json` is shaped this way because a forward is not
        /// keyed by anything an instance owns - one instance can have
        /// several - so there is no dictionary key to rewrite.
        case objectArray(field: String)
    }

    public struct Entry: Sendable {
        /// For diagnostics and for the test that reports what it missed.
        public let label: String
        /// Relative to Application Support.
        public let path: String
        public let shape: Shape
        /// Whether `forget` clears this one.
        ///
        /// False for the three things another caller already owns: the
        /// registry entry (`registry.remove`), and the disk and the kernel
        /// it may have brought (`InstanceDisk.remove`, which `msl remove
        /// --keep-disk` deliberately skips). Clearing those here would
        /// make `--keep-disk` a lie.
        public let clearedOnRemoval: Bool
        /// Whether a rename or clone carries this over at all.
        ///
        /// False means "clear it at both names and let it be rebuilt" -
        /// right for anything that CACHES something askable about the
        /// guest, where a stale copy is worse than none. See the SSH
        /// record, where a copy would have pointed a clone at the
        /// original instance.
        public let transferred: Bool
        /// Whether a CLONE copies it. A rename still moves it.
        public let copied: Bool

        init(_ label: String, _ path: String, _ shape: Shape,
             clearedOnRemoval: Bool = true,
             transferred: Bool = true, copied: Bool = true) {
            self.label = label
            self.path = path
            self.shape = shape
            self.clearedOnRemoval = clearedOnRemoval
            self.transferred = transferred
            self.copied = copied
        }
    }

    /// Every place an instance's name is recorded.
    ///
    /// Mirrors `DaemonServer.removeInstanceState` plus the stores that
    /// predate it. The ones deliberately NOT here:
    ///
    /// - `last-used`, a convenience pointer rather than state. Rename
    ///   rewrites it separately because a stale value is harmless but an
    ///   outright wrong one sends plain `msl` to the wrong instance.
    /// - The app catalogue and the generated `.app` bundles. Those are
    ///   rebuilt from the guest and a bundle's launch command embeds the
    ///   instance name, so they are DISCARDED and rescanned rather than
    ///   rewritten - see `LinuxAppCatalog.forget`.
    /// - Saved VM state (`vm-<name>.state`). It cannot survive a rename at
    ///   all; see `InstanceRename.blockers`.
    public static let inventory: [Entry] = [
        .init("registry", "instances.json", .dictionaryKey, clearedOnRemoval: false),
        .init("disk policy", "storage.json",
              .dictionaryKeyWrapped(prefix: "disks/", suffix: ".img")),
        .init("appearance", "appearance.json", .dictionaryKey),
        .init("locks", "locks.json", .nameArrays(fields: ["locked"])),
        .init("peripherals", "peripherals.json",
              .nameArrays(fields: ["camera", "microphone"])),
        .init("per-app graphics", "app-graphics.json",
              .dictionaryKeyPrefix(separator: "\u{1F}")),
        .init("launch commands", "app-commands.json",
              .dictionaryKeyPrefix(separator: "\u{1F}")),
        .init("resources", "resources", .ownFile(name: { "\($0).json" })),
        .init("sandbox gates", "sandbox", .ownFile(name: { "\($0).json" })),
        // **Deliberately NOT transferred - only cleared.** The record holds
        // the instance's IP address and its `~/.ssh/config` alias, and
        // `DaemonServer`'s address resolver trusts it BEFORE asking the
        // guest (`RecordStore.load(...)?.host ?? hostname -I`). So a copied
        // record is actively dangerous: a clone would have inherited the
        // original's address, and a forward, an `ssh -L` or a publish of
        // the clone would all have reached the ORIGINAL instance. A rename
        // is just as wrong - the new name means a new MAC and so a new
        // lease, while the moved record still named the old address.
        //
        // Clearing both ends is right because the record is a cache of
        // something askable: `msl ssh <instance>` rebuilds it, and
        // `SSHSetup.forget` also removes the stale config block.
        .init("SSH record", "ssh", .ownFile(name: { "\($0).json" }),
              transferred: false),
        .init("instance disk", "disks", .ownFile(name: { "\($0).img" }),
              clearedOnRemoval: false),
        .init("shipped kernel", "disks", .ownFile(name: { "\($0).Image" }),
              clearedOnRemoval: false),
        .init("shipped initramfs", "disks", .ownFile(name: { "\($0).initramfs" }),
              clearedOnRemoval: false),
        .init("experiments", ".", .ownFile(name: { "experiments-\($0).json" })),
        .init("apps to reopen", ".", .ownFile(name: { "reopen-\($0).json" })),
        // Moved on a rename (the instance is the same machine under
        // another name) but NOT copied: a clone starts cold, and
        // `VZGenericPlatformConfiguration.machineIdentifier` is documented
        // as having to match the saved state it restores - two instances
        // sharing one is a confusion with no upside.
        .init("machine identifier", ".", .ownFile(name: { "vm-\($0).machineid" }),
              copied: false),
        .init("default user", "default-users.json", .dictionaryKey),
        .init("port forwards", "forwards.json", .objectArray(field: "instance")),
        // **Moved on a rename, never copied to a clone.** A rename is the
        // same instance under another name, so its identity moves and is
        // re-signed under the new name (`origin` stays the name at birth,
        // which is what stops a rename escaping a scope). A clone is
        // ISSUED an identity deriving from its parent's - handing it a
        // copy would make the copy indistinguishable from the original,
        // which is the entire thing this exists to prevent.
        .init("identity", "identity", .ownFile(name: { "\($0).json" }),
              copied: false),
    ]

    // MARK: - The two operations

    public enum Mode: Sendable {
        /// Rename: the old name keeps nothing.
        case move
        /// Clone: both names end up with their own copy.
        case copy
    }

    /// Applies `mode` to every entry. Returns the labels it actually
    /// touched, for the line the CLI prints.
    ///
    /// Best-effort per entry on purpose. A store that does not exist for
    /// this instance is the normal case - most instances have never had a
    /// per-app graphics override - and treating a missing file as a failure
    /// would make renaming a plain instance impossible.
    @discardableResult
    public static func apply(_ mode: Mode, from old: String, to new: String,
                             appSupport: URL = MSLPaths.appSupport) throws -> [String] {
        var touched: [String] = []
        for entry in inventory {
            let directory = entry.path == "." ? appSupport
                : appSupport.appendingPathComponent(entry.path)
            // Not carried over at all: cleared at the old name (and at the
            // new one, in case something stale is sitting there) and left
            // to be rebuilt.
            if !entry.transferred || (mode == .copy && !entry.copied) {
                if case .ownFile(let name) = entry.shape {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(name(new)))
                    if mode == .move {
                        try? FileManager.default.removeItem(
                            at: directory.appendingPathComponent(name(old)))
                    }
                } else {
                    _ = try? remove(directory, shape: entry.shape, name: new)
                    if mode == .move { _ = try? remove(directory, shape: entry.shape, name: old) }
                }
                continue
            }
            switch entry.shape {
            case .ownFile(let name):
                let source = directory.appendingPathComponent(name(old))
                let destination = directory.appendingPathComponent(name(new))
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                // The destination is cleared first: a half-finished earlier
                // attempt, or a name whose files were kept by
                // `msl remove --keep-disk`, would otherwise make this fail
                // for a reason nobody could act on.
                try? FileManager.default.removeItem(at: destination)
                switch mode {
                case .move:
                    try FileManager.default.moveItem(at: source, to: destination)
                case .copy:
                    // `clonefile` for the disk, so cloning a 20 GB image
                    // costs milliseconds and no space until the two
                    // diverge - the same reason `InstanceDisk.ensure` uses
                    // it, and the same refusal to fall back to a real copy
                    // that would silently write twenty gigabytes.
                    if clonefile(source.path, destination.path, 0) != 0 {
                        let code = errno
                        // Small files are worth copying properly; only the
                        // disk is big enough for a fallback to be a
                        // problem, and `InstanceDisk.DiskError` already
                        // says so for that case.
                        guard entry.label != "instance disk" else {
                            throw TransferError.cannotClone(entry.label, errno: code)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                }
                touched.append(entry.label)

            case .dictionaryKey, .dictionaryKeyPrefix, .dictionaryKeyWrapped,
                 .nameArrays, .objectArray:
                if try rewrite(directory, shape: entry.shape, mode: mode, old: old, new: new) {
                    touched.append(entry.label)
                }
            }
        }
        return touched
    }

    /// Clears every trace of an instance that no other caller owns.
    ///
    /// **This closes a leak that was live.** `DaemonServer.removeInstanceState`
    /// forgets eight stores by hand, each with a comment about the bug that
    /// put it there - an instance's app list, badge or CPU choice outliving
    /// it and being inherited by the next instance to reuse the name. Five
    /// more were never added: the instance lock, its camera and microphone
    /// permissions, its per-app graphics modes, its sandbox gates, and its
    /// **custom launch commands**.
    ///
    /// The last is the one that matters. `apps.customCommand` exists
    /// because a launch override runs an arbitrary command inside the
    /// guest, and `AppCustomCommandStore.set` is gated for exactly that
    /// reason - but a command left behind by a deleted instance needed
    /// nobody to write it, so a new instance of the same name would run it
    /// with the gate never consulted. Forgetting by inventory means the
    /// next store somebody adds is covered without anybody remembering to
    /// come back here.
    public static func forget(instance: String,
                              appSupport: URL = MSLPaths.appSupport) {
        for entry in inventory where entry.clearedOnRemoval {
            let directory = entry.path == "." ? appSupport
                : appSupport.appendingPathComponent(entry.path)
            switch entry.shape {
            case .ownFile(let name):
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name(instance)))
            default:
                // Removing a key is "rewrite it to nothing", which the
                // generic rewriter already does for every shape.
                _ = try? remove(directory, shape: entry.shape, name: instance)
            }
        }
    }

    public enum TransferError: Error, CustomStringConvertible {
        case cannotClone(String, errno: Int32)
        public var description: String {
            switch self {
            case .cannotClone(let what, let code) where code == ENOTSUP:
                return "this volume can't make instant copies (it isn't APFS), and copying \(what) in full could be enormous"
            case .cannotClone(let what, let code):
                return "couldn't copy \(what) (\(String(cString: strerror(code))))"
            }
        }
    }

    /// Drops `name` from one shared file. Returns whether anything changed.
    static func remove(_ url: URL, shape: Shape, name: String) throws -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else { return false }

        if case .objectArray(let field) = shape {
            guard let rows = root as? [[String: Any]] else { return false }
            let kept = rows.filter { $0[field] as? String != name }
            guard kept.count != rows.count else { return false }
            try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
                .write(to: url, options: .atomic)
            return true
        }
        guard var object = root as? [String: Any] else { return false }

        var changed = false
        switch shape {
        case .ownFile, .objectArray:
            return false
        case .nameArrays(let fields):
            for field in fields {
                guard let names = object[field] as? [String], names.contains(name) else { continue }
                object[field] = names.filter { $0 != name }
                changed = true
            }
        case .dictionaryKey:
            changed = object.removeValue(forKey: name) != nil
        case .dictionaryKeyWrapped(let prefix, let suffix):
            changed = object.removeValue(forKey: prefix + name + suffix) != nil
        case .dictionaryKeyPrefix(let separator):
            for key in object.keys where key.hasPrefix(name + separator) {
                object.removeValue(forKey: key)
                changed = true
            }
        }
        guard changed else { return false }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try encoded.write(to: url, options: .atomic)
        return true
    }

    // MARK: - Generic JSON rewriting

    /// Rewrites one shared file in place. Returns whether anything changed.
    static func rewrite(_ url: URL, shape: Shape, mode: Mode,
                        old: String, new: String) throws -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else { return false }

        // The one shape whose file is an array rather than an object, so it
        // is handled before the cast the rest of them need.
        if case .objectArray(let field) = shape {
            guard var rows = root as? [[String: Any]] else { return false }
            var changed = false
            var copies: [[String: Any]] = []
            for index in rows.indices where rows[index][field] as? String == old {
                switch mode {
                case .move: rows[index][field] = new
                case .copy:
                    var duplicate = rows[index]
                    duplicate[field] = new
                    copies.append(duplicate)
                }
                changed = true
            }
            guard changed else { return false }
            try JSONSerialization.data(withJSONObject: rows + copies, options: [.sortedKeys])
                .write(to: url, options: .atomic)
            return true
        }
        guard var object = root as? [String: Any] else { return false }

        var changed = false
        switch shape {
        case .ownFile, .objectArray:
            return false

        case .nameArrays(let fields):
            for field in fields {
                guard let names = object[field] as? [String], names.contains(old) else { continue }
                var updated = names
                if mode == .move { updated.removeAll { $0 == old } }
                if !updated.contains(new) { updated.append(new) }
                object[field] = updated
                changed = true
            }

        case .dictionaryKey:
            guard let value = object[old] else { return false }
            if mode == .move { object.removeValue(forKey: old) }
            object[new] = value
            changed = true

        case .dictionaryKeyWrapped(let prefix, let suffix):
            let oldKey = prefix + old + suffix
            guard let value = object[oldKey] else { return false }
            if mode == .move { object.removeValue(forKey: oldKey) }
            object[prefix + new + suffix] = value
            changed = true

        case .dictionaryKeyPrefix(let separator):
            // Every key beginning `<name><separator>`, and only a WHOLE
            // first segment: an instance called `work` must not drag
            // `workshop`'s per-app overrides along with it.
            for (key, value) in object where key.hasPrefix(old + separator) {
                if mode == .move { object.removeValue(forKey: key) }
                object[new + key.dropFirst(old.count)] = value
                changed = true
            }
        }

        guard changed else { return false }
        // Atomic, and sorted so a hand-read of the file after a rename
        // looks like the file before it. The CLI and the daemon both read
        // these, and a torn write here is how `msl list` once showed no
        // instances at all.
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try encoded.write(to: url, options: .atomic)
        return true
    }
}
