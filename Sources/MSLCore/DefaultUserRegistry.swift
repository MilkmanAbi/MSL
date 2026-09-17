import Foundation

/// Remembers each distro's WSL-style "default login user" - the account
/// created interactively the first time that distro is actually launched
/// (see `msl`'s first-run setup wizard in `Sources/msl/main.swift`). Keyed
/// by `GuestDistro`, not by MSL instance name: every instance of the same
/// distro shares one disk image (see `InstanceRegistry`'s caveat on this),
/// so they necessarily share one guest user database too - there's no such
/// thing as a per-instance default user here, only a per-distro one.
public final class DefaultUserRegistry {
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    private func loadEntries() -> [String: String] {
        guard let data = try? Data(contentsOf: path),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }

    private func save(_ entries: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entries).write(to: path)
    }

    /// `nil` means no user has ever been set up for this distro yet - the
    /// caller should run the first-run wizard rather than falling back to
    /// root silently.
    public func defaultUser(for distro: GuestDistro) -> String? {
        loadEntries()[distro.rawValue]
    }

    public func setDefaultUser(_ username: String, for distro: GuestDistro) throws {
        var entries = loadEntries()
        entries[distro.rawValue] = username
        try save(entries)
    }

    /// For when the distro's disk is deleted: the account lived on it, and a
    /// reinstall must ask for a new one rather than log in as a user who no
    /// longer exists.
    public func forgetDefaultUser(for distro: GuestDistro) throws {
        var entries = loadEntries()
        guard entries.removeValue(forKey: distro.rawValue) != nil else { return }
        try save(entries)
    }
}
