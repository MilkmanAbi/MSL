// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Tracks which named MSL instances exist and which `GuestDistro` each one
/// is, persisted as a small JSON file. Capped at `maxInstances` - not
/// tied to disk space or a hardware limit, just a sanity ceiling; raised
/// from 2 to 8 alongside Fedora/Nix landing (six distros now exist, and
/// the WSL-like "install a few and switch between them" workflow needs
/// room for more than two at once).
///
/// Instances are created implicitly: requesting a name that doesn't exist
/// yet registers it (with whichever distro was requested, defaulting to
/// `.alpine`), as long as the cap isn't already hit. There's no separate
/// "create instance" step yet - `msl work --distro debian` and `msl
/// personal` just become the two instances the first time each is used -
/// remove one with `msl remove <name>` to free a slot.
///
/// **Caveat that's on the caller, not enforced here:** the disk image
/// backing a distro (`GuestDistro.diskImageFilename`) is per-*distro*, not
/// per-*instance* - two differently-named instances of the *same* distro
/// (e.g. `msl work --distro debian` and `msl personal --distro debian`)
/// share one underlying `rootfs-debian.img`. Running two such instances
/// *concurrently* is a real corruption risk (confirmed painfully once this
/// session, on an unrelated path - see README's "MSL shell and CLI"
/// section), the same way two processes writing the same raw disk file at
/// once always is. Fine sequentially; never simultaneously. Instances of
/// *different* distros never share a file and have no such restriction.
public final class InstanceRegistry {
    public static let maxInstances = 8
    public static let defaultInstanceName = "default"

    /// How many instances may hold host RAM at once. Unlike `maxInstances`
    /// (a sanity ceiling on how many may *exist*), this one is a real
    /// resource limit: every running or *paused* VM keeps its whole guest
    /// RAM allocation resident on the host, so four 2 GB guests is 8 GB
    /// gone whether or not any of them is doing anything.
    ///
    /// Enforced in `DaemonServer`, deliberately not in the UI: a limit the
    /// app draws but the daemon doesn't apply is not a limit at all - a
    /// plain `msl <name>` from a terminal would sail straight past it.
    public static let maxConcurrentRunning = 4

    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    public enum RegistryError: Error, CustomStringConvertible {
        case atCapacity(existing: [String], limit: Int)
        public var description: String {
            switch self {
            case .atCapacity(let existing, let limit):
                return "already at the \(limit)-instance limit (\(existing.joined(separator: ", "))) - remove one before adding another"
            }
        }
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self {
            case .unreadable(let path):
                return "\(path) exists but isn't a registry MSL can read - fix or move it aside rather than let MSL overwrite it"
            }
        }
    }

    /// The registry as stored: instance name to distro *string*.
    ///
    /// Kept as strings, never decoded straight to `GuestDistro`: one value
    /// this build doesn't recognise - a custom image from a newer MSL, a
    /// hand edit - used to fail the whole decode, which read as an empty
    /// registry, and the next registration then saved over every other
    /// instance. Unknown values are now skipped when reading and written
    /// back untouched.
    ///
    /// Throws only when the file exists and is not a registry at all, so a
    /// write can refuse rather than replace it.
    private func loadRaw() throws -> [String: String] {
        guard let data = try? Data(contentsOf: path) else { return [:] }
        if let entries = try? JSONDecoder().decode([String: String].self, from: data) {
            return entries
        }
        // Migration path: the registry used to just be a `[String]` of
        // names with no distro info - every instance from that era was
        // necessarily Alpine (the only distro that existed yet).
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return Dictionary(uniqueKeysWithValues: names.map { ($0, GuestDistro.alpine.rawValue) })
        }
        throw LoadError.unreadable(path.path)
    }

    private func loadEntries() -> [String: GuestDistro] {
        ((try? loadRaw()) ?? [:]).compactMapValues(GuestDistro.init(rawValue:))
    }

    private func save(_ entries: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic: the CLI and the daemon both read and write this file. A plain
        // write truncates it first, so a reader in that instant decoded an
        // empty registry - `msl list` showed no instances at all mid-test
        // (2026-09-14) - and a reader that then saved would have made the
        // loss permanent.
        try JSONEncoder().encode(entries).write(to: path, options: .atomic)
    }

    public func list() -> [String] {
        Array(loadEntries().keys).sorted()
    }

    /// The distro a registered instance was created with. `nil` if `name`
    /// isn't registered.
    public func distro(for name: String) -> GuestDistro? {
        loadEntries()[name]
    }

    /// Every registered instance with its distro, in one read.
    public func entries() -> [String: GuestDistro] {
        loadEntries()
    }

    /// Whether `name` could ever be a valid instance name. Instance names
    /// become directory and file components (`InstanceRegistry`'s JSON
    /// keys, snapshot filenames, generated `.app` bundle paths), and until
    /// now nothing checked them - which is how the three junk entries
    /// `--`, `start` and `--shutdown` got registered by CLI flags being
    /// read as instance names.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Returns the existing entry for `name` if present (its originally
    /// requested `distro` is ignored in that case - distro is fixed at
    /// creation), otherwise registers it with `distro` (throwing if that
    /// would exceed `maxInstances`).
    @discardableResult
    public func ensureRegistered(_ name: String, distro: GuestDistro = .alpine) throws -> String {
        var entries = try loadRaw()
        if entries[name] != nil { return name }
        guard entries.count < Self.maxInstances else {
            throw RegistryError.atCapacity(existing: Array(entries.keys), limit: Self.maxInstances)
        }
        entries[name] = distro.rawValue
        try save(entries)
        return name
    }

    public func remove(_ name: String) throws {
        var entries = try loadRaw()
        guard entries.removeValue(forKey: name) != nil else { return }
        try save(entries)
    }

    /// A plain sibling file, not a field on the JSON registry itself -
    /// written far more often (once per session start) than `instances.
    /// json` is, and keeping it separate means a torn/concurrent write to
    /// one can never corrupt the other. Backs the WSL-like ergonomic where
    /// plain `msl` (no instance named) picks up whichever instance was used
    /// last, once more than one is installed, instead of always landing on
    /// a fixed default.
    private var lastUsedPath: URL {
        path.deletingLastPathComponent().appendingPathComponent("last-used")
    }

    /// Records `name` as the most recently used instance. Best-effort - a
    /// failed write here shouldn't ever fail the session it's recording.
    public func recordLastUsed(_ name: String) {
        try? FileManager.default.createDirectory(
            at: lastUsedPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? name.write(to: lastUsedPath, atomically: true, encoding: .utf8)
    }

    /// The most recently used instance name, if any has ever been recorded.
    /// Callers should still confirm it's still registered (`distro(for:)`)
    /// before trusting it - it isn't cleared when that instance is later
    /// `remove`d.
    public func lastUsed() -> String? {
        guard let value = try? String(contentsOf: lastUsedPath, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
