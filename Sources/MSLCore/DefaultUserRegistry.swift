import Foundation

/// Remembers each **instance's** WSL-style "default login user" - the account
/// created interactively the first time that instance is launched (see
/// `msl`'s first-run setup wizard in `Sources/msl/main.swift`).
///
/// Keyed by instance since instances stopped sharing a disk
/// (`InstanceDisk`). It used to be keyed by distro, which was right while
/// every instance of a distro was one machine with one `/etc/passwd` - and
/// became actively harmful the moment they were not: a new instance is a
/// clone of the pristine base and has none of the accounts another instance
/// created, so logging it in as a remembered name would fail with the silent
/// exit 127 that looks like a broken session.
///
/// `migrate(instances:)` carries the old per-distro entries over the first
/// time, then removes them, so no new instance can inherit one by accident.
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

    /// `nil` means no user has ever been set up for this instance yet - the
    /// caller should run the first-run wizard rather than falling back to
    /// root silently.
    public func defaultUser(forInstance instance: String) -> String? {
        loadEntries()[instance]
    }

    public func setDefaultUser(_ username: String, forInstance instance: String) throws {
        var entries = loadEntries()
        entries[instance] = username
        try save(entries)
    }

    /// For when the instance's disk is deleted: the account lived on it, and
    /// a fresh one must ask rather than log in as a user who no longer
    /// exists.
    public func forgetDefaultUser(forInstance instance: String) throws {
        var entries = loadEntries()
        guard entries.removeValue(forKey: instance) != nil else { return }
        try save(entries)
    }

    /// Moves old per-distro entries onto the instances that were using them.
    ///
    /// Run once, by `InstanceLayoutMigration`. Each instance inherits its
    /// distro's remembered account - which is correct, because until now
    /// they all shared the disk that account lives on. The distro keys are
    /// then dropped: leaving them would let a *new* instance inherit an
    /// account its own fresh disk has never had.
    public func migrate(instances: [String: GuestDistro]) throws {
        var entries = loadEntries()
        let distroKeys = Set(GuestDistro.allCases.map(\.rawValue))
        guard entries.keys.contains(where: { distroKeys.contains($0) }) else { return }
        for (instance, distro) in instances where entries[instance] == nil {
            if let inherited = entries[distro.rawValue] { entries[instance] = inherited }
        }
        for key in distroKeys { entries.removeValue(forKey: key) }
        try save(entries)
    }
}
