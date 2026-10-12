import Foundation

/// Each instance's own disk, cloned from the distro's downloaded base.
///
/// **Why this exists.** MSL used to give every instance of one distro the
/// same `rootfs-<distro>.img`. Two instances of Debian were two names for one
/// machine: the same accounts, the same files, the same everything - and
/// running both at once corrupted the image, so the daemon had to refuse it.
/// Making a second instance of a distro you already had was close to
/// pointless (reported 2026-10-01).
///
/// Now the downloaded image is a **base** that is never booted, and each
/// instance boots a clone of it. A clone is `clonefile(2)` on APFS: a 20 GB
/// image (3.1 GB of real blocks) clones in about two milliseconds and costs
/// nothing until the two copies diverge - measured on this machine. So a new
/// instance is a whole separate installation, with its own accounts, its own
/// disk size and its own filesystem, for free.
///
/// `clonefile`, never `cp -c` or `FileManager.copyItem`: those quietly fall
/// back to a *real* copy when they cannot clone, which here would mean
/// silently writing twenty gigabytes. `clonefile` fails instead, and a
/// failure is worth reporting - see `ImageBackup`, which makes the same
/// choice for the same reason.
public enum InstanceDisk {
    /// Where every instance's disk lives, under Application Support.
    ///
    /// A directory rather than a flat `disk-<name>.img`, so an instance can
    /// never be named something that collides with MSL's own files
    /// (`disk-Image`, `disk-initramfs-virt`).
    public static func directory(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("disks")
    }

    public static func url(instance: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        directory(appSupport: appSupport).appendingPathComponent("\(instance).img")
    }

    /// The key this instance's disk has in `storage.json`.
    ///
    /// Contains a slash on purpose: it can never collide with the old
    /// per-distro keys (`rootfs-debian.img`), so both can sit in one file
    /// while a machine is being migrated.
    public static func storageKey(instance: String) -> String {
        "disks/\(instance).img"
    }

    /// The instance a `storage.json` key belongs to, or nil for one of the
    /// old per-distro keys (`rootfs-debian.img`).
    ///
    /// The inverse of `storageKey`, and the reason that key contains a
    /// slash: a policy scoped to one instance has to be able to recognise
    /// its own disk, and the legacy keys genuinely belong to no single
    /// instance - several of them shared one image - so `nil` is the right
    /// answer there rather than a guess.
    public static func instanceName(forStorageKey key: String) -> String? {
        guard key.hasPrefix("disks/"), key.hasSuffix(".img") else { return nil }
        let name = String(key.dropFirst("disks/".count).dropLast(".img".count))
        return name.isEmpty ? nil : name
    }

    public static func exists(instance: String, appSupport: URL = MSLPaths.appSupport) -> Bool {
        FileManager.default.fileExists(atPath: url(instance: instance, appSupport: appSupport).path)
    }

    public enum DiskError: Error, CustomStringConvertible {
        case baseMissing(GuestDistro)
        case cannotClone(GuestDistro, errno: Int32)

        public var description: String {
            switch self {
            case .baseMissing(let distro):
                return "\(distro.rawValue) isn't downloaded yet - run `msl install \(distro.rawValue)` first."
            case .cannotClone(_, let code) where code == EXDEV:
                return "the disk image can't be cloned across volumes, and a full copy could be enormous"
            case .cannotClone(_, let code) where code == ENOTSUP:
                return "this volume doesn't support instant clones (it isn't APFS), and a full copy could be enormous"
            case .cannotClone(let distro, let code):
                return "couldn't clone \(distro.rawValue)'s disk image (\(String(cString: strerror(code))))"
            }
        }
    }

    /// Gives `instance` its own disk if it hasn't got one yet.
    ///
    /// Called on the boot path, so it is also what migrates a machine from
    /// the old shared layout: an instance whose disk is missing gets a clone
    /// of the base, which for an upgraded machine is the very image it was
    /// already using - identical content, nothing to copy, and from that
    /// moment the instances no longer share.
    ///
    /// Cloned to a temporary name and then renamed, so a clone interrupted
    /// half way never leaves something that looks like a usable disk.
    @discardableResult
    public static func ensure(instance: String, distro: GuestDistro,
                              appSupport: URL = MSLPaths.appSupport) throws -> URL {
        let destination = url(instance: instance, appSupport: appSupport)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        // **A protected instance's disk is not a plain file, and this must
        // not make one.** Found on the first live boot from a container:
        // `msl protect` removes the plaintext disk, then the next start
        // came through here, saw nothing at `disks/<name>.img`, and cloned
        // a FRESH copy of the base beside the container. The guest booted
        // correctly - `VMManager.diskImagePath` prefers the container - but
        // a 1.3 GB plaintext disk had appeared next to the encrypted one,
        // which is most of what protecting it was meant to prevent, and it
        // would then have blocked `msl unprotect`.
        if case .valid(let identity) = InstanceIdentityStore.verdict(
            for: instance, appSupport: appSupport),
           InstanceVault.exists(serial: identity.serial) {
            return destination
        }

        let base = distro.baseImageURL(appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw DiskError.baseMissing(distro)
        }
        try FileManager.default.createDirectory(at: directory(appSupport: appSupport),
                                                withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(instance).img.cloning-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: staging)
        guard clonefile(base.path, staging.path, 0) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw DiskError.cannotClone(distro, errno: code)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// Deletes one instance's disk. The base is left alone, so the next
    /// instance of that distro costs no download.
    public static func remove(instance: String, appSupport: URL = MSLPaths.appSupport) {
        try? FileManager.default.removeItem(at: url(instance: instance, appSupport: appSupport))
        // And any kernel it brought with it (a shipment's), or the next
        // instance to reuse the name would boot somebody else's.
        try? FileManager.default.removeItem(at: kernelURL(instance: instance, appSupport: appSupport))
        try? FileManager.default.removeItem(at: initramfsURL(instance: instance, appSupport: appSupport))
        DiskStorage.forgetImage(named: storageKey(instance: instance))
    }

    /// Every instance disk on the machine, by instance name.
    ///
    /// Used by `doctor` to spot a disk whose instance is gone.
    public static func all(appSupport: URL = MSLPaths.appSupport) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory(appSupport: appSupport).path)) ?? []
        return names.filter { $0.hasSuffix(".img") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(4)) }
            .sorted()
    }

    // MARK: - Boot files an instance carries itself

    /// A kernel this instance brings with it, rather than the shared one.
    ///
    /// MSL's kernel and initramfs are normally shared by every non-custom
    /// distro and arrive with the first distro downloaded. A **shipment**
    /// cannot rely on that: the Mac receiving it may have downloaded nothing
    /// at all, and even if it has, a different MSL build ships a different
    /// kernel - a shipment made on 6.18.54 restored against some future
    /// kernel is not the machine it was. So a shipment carries its own, and
    /// it lands here, beside the disk that was built for it.
    public static func kernelURL(instance: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        directory(appSupport: appSupport).appendingPathComponent("\(instance)-Image")
    }

    public static func initramfsURL(instance: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        directory(appSupport: appSupport).appendingPathComponent("\(instance)-initramfs")
    }

    /// Whether `instance` has a kernel of its own. Both files or neither:
    /// half a pair would boot a kernel against the wrong modules.
    public static func hasOwnKernel(instance: String, appSupport: URL = MSLPaths.appSupport) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: kernelURL(instance: instance, appSupport: appSupport).path)
            && fm.fileExists(atPath: initramfsURL(instance: instance, appSupport: appSupport).path)
    }
}
