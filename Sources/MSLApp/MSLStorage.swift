import Foundation
import MSLCore

/// What the MSL dashboard shows: where MSL keeps its files on this Mac, how big
/// the Linux disks have grown, and how much room is left to grow them. All of
/// it is read host-side from the storage layout MSLCore already defines
/// (`MSLPaths`, `GuestDistro.diskImageFilename`, `DiskStorage`), so it needs no
/// running VM and no new daemon traffic - the dashboard is a real view of the
/// project's footprint, not a guess.
struct MSLStorageInfo: Sendable {
    /// One shared disk image. Instances of a distro share it (see AGENTS.md),
    /// so the unit here is the image/distro, with the instances that use it
    /// listed - reporting a per-instance size would triple-count the bytes.
    struct DiskImage: Identifiable, Sendable {
        let id: String            // the distro's display name
        let filename: String
        let path: String
        let allocated: UInt64     // what it actually occupies on disk now
        let capacity: UInt64      // how big the Linux disk can grow
        let isSparse: Bool
        let instances: [String]   // instances backed by this image
        let exists: Bool

        var usedFraction: Double {
            guard capacity > 0 else { return 0 }
            return min(1, Double(allocated) / Double(capacity))
        }
    }

    /// A place worth jumping to, for the dashboard's shortcut row.
    struct Location: Identifiable, Sendable {
        let id: String
        let name: String
        let detail: String
        let symbol: String
        let path: String
        let exists: Bool
    }

    var images: [DiskImage]
    var locations: [Location]
    var hostFreeBytes: Int64?
    var totalAllocated: UInt64

    /// One instance's Linux disk, for the status bar. A WebDAV mount reports
    /// no capacity (hence the old "Zero KB available"), so this reads the
    /// image on the Mac instead: what it uses now, how big it can grow, and
    /// whether it grows on demand (a sparse image) or was preallocated.
    struct GuestDisk: Sendable {
        let used: UInt64
        let capacity: UInt64
        let isDynamic: Bool
        var free: UInt64 { capacity > used ? capacity - used : 0 }

        var summary: String {
            let u = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)
            let f = ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
            return isDynamic ? "\(u) used · \(f) free · Dynamic" : "\(u) used · \(f) free"
        }
    }

    static func guestDisk(for instance: Instance) async -> GuestDisk? {
        await Task.detached(priority: .utility) { () -> GuestDisk? in
            let path = instance.distro.bootFiles(instance: instance.name).disk.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return GuestDisk(used: DiskStorage.allocatedSize(of: path),
                             capacity: DiskStorage.capacity(of: path),
                             isDynamic: DiskStorage.isSparse(path))
        }.value
    }

    /// Gathers everything off the main actor - the size lookups `stat` real
    /// files. Instances come from the app's live list so the dashboard follows
    /// what's actually installed.
    static func gather(instances: [Instance]) async -> MSLStorageInfo {
        await Task.detached(priority: .utility) { () -> MSLStorageInfo in
            let appSupport = MSLPaths.appSupport

            // One row per instance now, not one per distro: each instance has
            // its own disk (`InstanceDisk`). They are APFS clones of the
            // distro's downloaded image, so two instances of one distro that
            // have written little share nearly every block - the sizes below
            // are what each *would* free, not what they add up to.
            var images: [DiskImage] = []
            var total: UInt64 = 0
            for instance in instances where instance.isInstalled {
                let path = instance.distro.bootFiles(instance: instance.name).disk.path
                let exists = FileManager.default.fileExists(atPath: path)
                let allocated = exists ? DiskStorage.allocatedSize(of: path) : 0
                let capacity = exists ? DiskStorage.capacity(of: path) : 0
                total += allocated
                images.append(DiskImage(
                    id: "\(instance.name) (\(instance.distro.displayName))",
                    filename: (path as NSString).lastPathComponent,
                    path: path, allocated: allocated, capacity: capacity,
                    isSparse: exists && DiskStorage.isSparse(path),
                    instances: [instance.name], exists: exists))
            }
            images.sort { $0.allocated > $1.allocated }

            // Disk Images lands on the largest image itself (selected in its
            // folder), so it isn't just a second link to Program Files.
            let imagesTarget = images.first(where: \.exists)?.path ?? appSupport.path
            let locations: [Location] = [
                Location(id: "programs", name: "MSL Program Files",
                         detail: "The app's tools, settings and catalogs",
                         symbol: "shippingbox", path: appSupport.path,
                         exists: FileManager.default.fileExists(atPath: appSupport.path)),
                Location(id: "images", name: "Disk Images",
                         detail: "The Linux root filesystems live here",
                         symbol: "internaldrive", path: imagesTarget,
                         exists: FileManager.default.fileExists(atPath: imagesTarget)),
                Location(id: "custom", name: "Custom Images",
                         detail: "Images you built yourself",
                         symbol: "hammer",
                         path: appSupport.appendingPathComponent("Custom Images").path,
                         exists: FileManager.default.fileExists(
                            atPath: appSupport.appendingPathComponent("Custom Images").path)),
                Location(id: "apps", name: "Generated Apps",
                         detail: "The Mac app bundles MSL makes for Linux apps",
                         symbol: "app.badge", path: MSLPaths.generatedAppsDirectory.path,
                         exists: FileManager.default.fileExists(
                            atPath: MSLPaths.generatedAppsDirectory.path)),
            ]

            let free = (try? appSupport.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage

            return MSLStorageInfo(images: images, locations: locations,
                                  hostFreeBytes: free, totalAllocated: total)
        }.value
    }
}
