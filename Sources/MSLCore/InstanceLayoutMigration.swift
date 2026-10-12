import Foundation

/// Moves a machine from "one disk per distro" to "one disk per instance".
///
/// Runs once, from the daemon, before anything boots. What it has to get
/// right is that nobody loses data and nobody inherits somebody else's:
///
/// 1. **Every existing instance keeps exactly what it had.** Its disk is a
///    clone of the shared image it was already booting - the same blocks, so
///    nothing is copied and nothing changes. From that moment the instances
///    diverge.
/// 2. **The old shared image is then deleted**, and this is the part that
///    matters. It has been booted, so it carries the accounts, machine-id and
///    SSH host keys of whoever used it. Keeping it as the base for *new*
///    instances would mean a "fresh" instance arrives with someone else's
///    users already in `/etc/passwd` - which is the exact problem this whole
///    change exists to remove. A distro whose base is gone is simply not
///    downloaded any more, and `msl install` fetches a pristine one.
/// 3. **Saved VM state is discarded for distros that had more than one
///    instance.** A hibernated guest's memory describes the disk as it was;
///    after two instances have been writing to one image, restoring that
///    memory onto either clone is the mismatch that corrupts a filesystem.
///    A distro with a single instance never had that problem and keeps its
///    state.
/// 4. Per-distro records - the remembered account, the storage policy - are
///    copied onto each instance that was using them, then dropped.
///
/// Only with every VM stopped. A clone taken while a guest is writing is a
/// clone of a half-written filesystem.
public enum InstanceLayoutMigration {
    /// Bumped if this ever has to run again for a different reason.
    static let version = 1

    static func markerURL(appSupport: URL) -> URL {
        appSupport.appendingPathComponent(".instance-disks-migrated")
    }

    public static func isDone(appSupport: URL = MSLPaths.appSupport) -> Bool {
        guard let text = try? String(contentsOf: markerURL(appSupport: appSupport), encoding: .utf8),
              let done = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return done >= version
    }

    public struct Result {
        public var migrated: [String] = []
        public var basesRemoved: [GuestDistro] = []
        public var statesDiscarded: [String] = []
        public var failures: [String] = []
    }

    /// `isRunning` tells it whether a given instance is live; migration is
    /// skipped entirely if any is, and tried again next time.
    @discardableResult
    public static func runIfNeeded(appSupport: URL = MSLPaths.appSupport,
                                   instances: [String: GuestDistro],
                                   isRunning: (String) -> Bool = { _ in false },
                                   log: ((String) -> Void)? = nil) -> Result {
        var result = Result()
        guard !isDone(appSupport: appSupport) else { return result }
        if let live = instances.keys.first(where: isRunning) {
            log?("not migrating disk layout yet - \(live) is running")
            return result
        }

        // Instances per distro, so a distro with several can have its saved
        // states dropped.
        var byDistro: [GuestDistro: [String]] = [:]
        for (name, distro) in instances { byDistro[distro, default: []].append(name) }

        for (distro, names) in byDistro {
            let base = distro.baseImageURL(appSupport: appSupport)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }

            // Give each instance its own clone first, and only count a distro
            // as migrated if every one of them succeeded - a base deleted
            // after a partial clone would lose a guest outright.
            var cloned: [String] = []
            for name in names.sorted() where !InstanceDisk.exists(instance: name, appSupport: appSupport) {
                do {
                    try InstanceDisk.ensure(instance: name, distro: distro, appSupport: appSupport)
                    cloned.append(name)
                    log?("\(name): now has its own copy of \(distro.rawValue)")
                } catch {
                    result.failures.append("\(name): \(error)")
                }
            }
            let allHaveDisks = names.allSatisfy {
                InstanceDisk.exists(instance: $0, appSupport: appSupport)
            }
            result.migrated += cloned
            guard allHaveDisks else {
                log?("keeping \(distro.rawValue)'s shared image - not every instance was cloned")
                continue
            }

            // Carry the per-distro records onto each instance.
            for name in names {
                let policy = DiskStorage.policy(forImageNamed: distro.diskImageFilename,
                                                path: base.path)
                DiskStorage.setPolicy(policy, forImageNamed: InstanceDisk.storageKey(instance: name))
            }
            DiskStorage.forgetImage(named: distro.diskImageFilename)

            // Saved state is only safe where one instance ever wrote the disk.
            if names.count > 1 {
                for name in names {
                    let state = appSupport.appendingPathComponent("vm-\(name).state")
                    if FileManager.default.fileExists(atPath: state.path) {
                        try? FileManager.default.removeItem(at: state)
                        result.statesDiscarded.append(name)
                        log?("\(name): discarded saved memory - \(names.count) instances had been sharing one disk")
                    }
                }
            }

            // And the tainted base goes.
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(atPath: base.path + ".pre-repair")
            result.basesRemoved.append(distro)
            log?("\(distro.rawValue): the shared image is gone; `msl install \(distro.rawValue)` fetches a clean one for new instances")
        }

        // Keyed to the directory being migrated, NOT `LinuxUserSetup.registry()`:
        // that one always points at the real Application Support, so a test
        // migrating a scratch directory rewrote the user's live
        // `default-users.json` - which is exactly what it did, once.
        try? DefaultUserRegistry(path: appSupport.appendingPathComponent("default-users.json"))
            .migrate(instances: instances)

        if result.failures.isEmpty {
            try? "\(version)\n".write(to: markerURL(appSupport: appSupport),
                                      atomically: true, encoding: .utf8)
        }
        return result
    }
}
