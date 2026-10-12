import Foundation

/// The phrase a user types to delete a whole distro installation.
///
/// Heavier than removing one instance (`RemovalConfirmation`'s "Meow"): this
/// deletes every instance of the distro *and* the disk they all share, so the
/// confirmation says exactly that, in the user's own words.
public enum DistroRemovalConfirmation {
    public static func phrase(distroName: String) -> String {
        "Delete all my \(distroName) instances"
    }

    /// Case and surrounding whitespace don't matter; the words do.
    public static func matches(_ typed: String, distroName: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(phrase(distroName: distroName)) == .orderedSame
    }
}

/// Everything on the Mac that belongs to one installed distro, rather than to
/// one instance of it.
///
/// Since instances stopped sharing one image (`InstanceDisk`), this is the
/// *base* - the downloaded image new instances are cloned from - plus every
/// instance disk made from it. Removing one instance leaves the base, so the
/// next instance of that distro costs no download; removing the distro takes
/// the lot.
public enum DistroInstallation {
    /// The disk image and the backup a repair leaves beside it - the files
    /// removal deletes. None for a custom image: those files are the user's,
    /// in a folder they made, and MSL never deletes them (`CustomImage`).
    public static func files(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> [URL] {
        guard !distro.isCustom else { return [] }
        let image = distro.baseImageURL(appSupport: appSupport)
        // The marker too: left behind, the next `msl install` would believe
        // the download was still here and skip it.
        return [image, URL(fileURLWithPath: image.path + ".pre-repair"),
                DistroInstaller.installedMarkerURL(for: image)]
    }

    /// Bytes those files actually take on the Mac - sparse images use far less
    /// than their nominal size.
    public static func allocatedBytes(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> UInt64 {
        files(for: distro, in: appSupport)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + DiskStorage.allocatedSize(of: $1.path) }
    }

    /// Whether a new instance of this distro can be made without downloading.
    ///
    /// Deliberately about the **base**, not about any instance: an instance
    /// that has its own disk still starts fine after the base is deleted, and
    /// a distro with a base but no instances is installed all the same.
    public static func isInstalled(_ distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> Bool {
        distro.baseIsInstalled(appSupport: appSupport)
    }

    /// Deletes the files and every record kept about the image: its storage
    /// policy, usage sample, pending resize, and the distro's remembered
    /// default user (that account lived on the disk being deleted). Returns
    /// the bytes freed.
    ///
    /// `instanceDisks` are the instances that were using this distro, whose
    /// own disks go with it. Passed in rather than looked up, because the
    /// caller removes the instances from the registry first - by the time
    /// this runs there is nothing left to ask (see
    /// `DaemonServer.handleRemoveDistro`).
    @discardableResult
    public static func deleteFiles(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport,
                                   instanceDisks: [String] = []) -> UInt64 {
        let freed = allocatedBytes(for: distro, in: appSupport)
            + instanceDisks.reduce(0) { total, instance in
                total + DiskStorage.allocatedSize(
                    of: InstanceDisk.url(instance: instance, appSupport: appSupport).path)
            }
        for url in files(for: distro, in: appSupport) {
            try? FileManager.default.removeItem(at: url)
        }
        DiskStorage.forgetImage(named: distro.diskImageFilename)
        for instance in instanceDisks { InstanceDisk.remove(instance: instance, appSupport: appSupport) }
        // A custom image's disk isn't deleted, so the accounts on it still
        // exist - forgetting them would have MSL ask to create them again.
        if !distro.isCustom {
            for instance in instanceDisks {
                try? LinuxUserSetup.registry().forgetDefaultUser(forInstance: instance)
            }
        }
        return freed
    }
}
