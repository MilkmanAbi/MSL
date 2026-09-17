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
/// Instances of a distro share one disk image, so removing instances one by
/// one never frees the disk - and finding `rootfs-<distro>.img` in
/// `~/Library/Application Support` by hand is exactly the headache this saves.
public enum DistroInstallation {
    /// The disk image and the backup a repair leaves beside it - the files
    /// removal deletes. None for a custom image: those files are the user's,
    /// in a folder they made, and MSL never deletes them (`CustomImage`).
    public static func files(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> [URL] {
        guard !distro.isCustom else { return [] }
        let image = distro.bootFiles(appSupport: appSupport).disk
        return [image, URL(fileURLWithPath: image.path + ".pre-repair")]
    }

    /// Bytes those files actually take on the Mac - sparse images use far less
    /// than their nominal size.
    public static func allocatedBytes(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> UInt64 {
        files(for: distro, in: appSupport)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + DiskStorage.allocatedSize(of: $1.path) }
    }

    public static func isInstalled(_ distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> Bool {
        FileManager.default.fileExists(atPath: distro.bootFiles(appSupport: appSupport).disk.path)
    }

    /// Deletes the files and every record kept about the image: its storage
    /// policy, usage sample, pending resize, and the distro's remembered
    /// default user (that account lived on the disk being deleted). Returns
    /// the bytes freed. The caller removes the instances first - see
    /// `DaemonServer.handleRemoveDistro`.
    @discardableResult
    public static func deleteFiles(for distro: GuestDistro, in appSupport: URL = MSLPaths.appSupport) -> UInt64 {
        let freed = allocatedBytes(for: distro, in: appSupport)
        for url in files(for: distro, in: appSupport) {
            try? FileManager.default.removeItem(at: url)
        }
        DiskStorage.forgetImage(named: distro.diskImageFilename)
        // A custom image's disk isn't deleted, so the account on it still
        // exists - forgetting it would have MSL ask to create it again.
        if !distro.isCustom { try? LinuxUserSetup.registry().forgetDefaultUser(for: distro) }
        return freed
    }
}
