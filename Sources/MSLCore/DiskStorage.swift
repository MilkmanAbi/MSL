// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How much disk an instance may use, and whether that space is reserved on
/// the Mac up front or taken only as it is actually needed.
///
/// Every MSL disk image has always been a **sparse** file: created by
/// `truncate`ing an empty file to its size, so the Mac only ever gives it
/// blocks that are written. What was fixed was the *ceiling* - 4 GB, set
/// once by `bootstrap-guest`, with no way to raise it. That ceiling is not
/// theoretical: the Alpine image reached 3.94 GB of 4.00 GB, at which point
/// a package install truncated a shared library mid-write and corrupted the
/// filesystem. Being able to move the ceiling is the point of this file.
public enum StorageMode: String, Codable, CaseIterable {
    /// The image may grow up to `size` as the guest needs it, and takes only
    /// what it has actually written from the Mac's disk until then.
    case dynamic
    /// The image is exactly `size`, and that space is reserved on the Mac
    /// immediately. Nothing else on the Mac can take it, so the guest can
    /// never be surprised by the host running out.
    case fixed
}

public struct StoragePolicy: Codable, Equatable {
    public var mode: StorageMode
    /// Fixed: the exact size. Dynamic: the ceiling it may grow to.
    public var size: UInt64
    /// Dynamic only: grow automatically when the guest starts running out.
    public var autoGrow: Bool

    public init(mode: StorageMode = .dynamic, size: UInt64 = StoragePolicy.defaultSize, autoGrow: Bool = true) {
        self.mode = mode
        self.size = size
        self.autoGrow = autoGrow
    }

    /// 15 GB: what a new instance starts with, and what the Storage slider
    /// shows - the two used to disagree (slider 64 GB, disk 16 GB).
    public static let defaultSize: UInt64 = 15 * 1024 * 1024 * 1024
    public static let minimumSize: UInt64 = 4 * 1024 * 1024 * 1024
    public static let maximumSize: UInt64 = 2048 * 1024 * 1024 * 1024

    /// Grow when the guest filesystem is at least this full.
    public static let growThreshold = 0.85
    /// How much to add each time. Enough to be worth a reboot, small enough
    /// that a runaway log file can't quietly eat the disk.
    public static let growStep: UInt64 = 8 * 1024 * 1024 * 1024
}

/// Reads and changes the size of MSL's disk images, and remembers the policy
/// for each one.
///
/// Keyed by **image filename, not instance name**: a distro's image is
/// shared by every instance of that distro (see `InstanceRegistry`), so
/// "how big is work's disk" and "how big is personal's disk" are the same
/// question whenever both are Debian.
public enum DiskStorage {
    /// Bytes as something a person reads.
    /// Parses a human-written size ("32G", "512MB", "1.5T", or a plain
    /// byte count).
    ///
    /// Validates *before* converting to `UInt64`, because that conversion
    /// traps rather than returning nil: `msl storage default fixed -5G`
    /// crashed with "Double value cannot be converted to UInt64 because the
    /// result would be less than UInt64.min", and `nanG` crashed the same
    /// way on "infinite or NaN". The range check in the caller ran after
    /// this, so it never got the chance to reject them politely.
    public static func parseSize(_ text: String) -> UInt64? {
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !upper.isEmpty else { return nil }
        // Swift's `Double` accepts hexadecimal-float syntax, so "0x10"
        // parses as 16 and "0x40G" as 64 GB. Nobody writes a disk size that
        // way, and silently accepting it is more confusing than refusing.
        guard !upper.contains("X") else { return nil }

        // Longest suffix first, so "GB" is not read as "B"-less "G".
        let multipliers: [(String, UInt64)] = [
            ("TB", 1 << 40), ("T", 1 << 40),
            ("GB", 1 << 30), ("G", 1 << 30),
            ("MB", 1 << 20), ("M", 1 << 20),
        ]
        for (suffix, multiplier) in multipliers where upper.hasSuffix(suffix) {
            guard let value = Double(upper.dropLast(suffix.count)) else { return nil }
            return scale(value, by: multiplier)
        }
        // No suffix: parse as an integer first so a byte count above 2^53
        // keeps its exact value instead of being rounded through `Double`.
        if let exact = UInt64(upper) { return exact }
        guard let value = Double(upper) else { return nil }
        return scale(value, by: 1)
    }

    private static func scale(_ value: Double, by multiplier: UInt64) -> UInt64? {
        guard value.isFinite, value >= 0 else { return nil }
        let product = value * Double(multiplier)
        // 2^64 exactly - `Double(UInt64.max)` rounds up to it, so anything
        // at or above is out of range.
        guard product.isFinite, product >= 0, product < 18_446_744_073_709_551_616.0 else { return nil }
        return UInt64(product)
    }

    public static func format(_ bytes: UInt64) -> String {
        // Binary, like every size MSL parses (`32G` is 32 GiB) and the
        // slider's GB. `.file` is decimal, so a 16 GiB disk read "17.18 GB"
        // next to a slider that said 16.
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Measuring

    /// The size the guest sees - the file's logical length.
    public static func capacity(of path: String) -> UInt64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 else { return 0 }
        return size
    }

    /// What the image actually costs on the Mac right now.
    ///
    /// `st_blocks`, not `st_size`: for a sparse file those differ by exactly
    /// the amount that has never been written, which is the whole point of
    /// dynamic mode and the number a user actually wants to see.
    public static func allocatedSize(of path: String) -> UInt64 {
        var status = stat()
        guard stat(path, &status) == 0 else { return 0 }
        return UInt64(status.st_blocks) * 512
    }

    public static func isSparse(_ path: String) -> Bool {
        allocatedSize(of: path) < capacity(of: path)
    }

    /// Free space on the volume holding the image - the real limit on how
    /// far a dynamic image can grow, whatever its ceiling says.
    public static func hostFreeSpace(forImageAt path: String) -> UInt64 {
        let directory = (path as NSString).deletingLastPathComponent
        guard let values = try? URL(fileURLWithPath: directory)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return UInt64(max(0, available))
    }

    // MARK: - Changing size

    public enum StorageError: Error, CustomStringConvertible {
        case noImage(String)
        case wouldShrink(current: UInt64, requested: UInt64)
        case notEnoughHostSpace(needed: UInt64, available: UInt64)
        case resizeFailed(String)

        public var description: String {
            switch self {
            case .noImage(let path):
                return "there's no disk image at \(path) yet"
            case .wouldShrink(let current, let requested):
                return "can't shrink a disk from \(DiskStorage.format(current)) to \(DiskStorage.format(requested)) - the filesystem inside it would have to be shrunk first, and anything past the new end would be lost"
            case .notEnoughHostSpace(let needed, let available):
                return "reserving \(DiskStorage.format(needed)) needs more free space than the \(DiskStorage.format(available)) your Mac has left"
            case .resizeFailed(let reason):
                return reason
            }
        }
    }

    /// Raises the image's capacity to `size`.
    ///
    /// Growing only. Shrinking a raw image means shrinking the ext4
    /// filesystem inside it first, offline, and then truncating to exactly
    /// the right place - if any of that is wrong by one block the guest
    /// loses data. Refused rather than half-implemented.
    ///
    /// **The VM must be stopped.** `VZDiskImageStorageDeviceAttachment`
    /// reads the file's length when the attachment is created, so a running
    /// guest would keep using the old capacity regardless; and the guest's
    /// filesystem still has to be told about the new space separately (see
    /// `markFilesystemResizePending`).
    /// How far a reservation has got - `fillHoles` is the slow part, and a
    /// bare spinner for the minute a 64 GB disk takes looked like a hang.
    public struct ReservationProgress: Equatable {
        public let written: UInt64
        public let total: UInt64
        public let started: Date

        public init(written: UInt64, total: UInt64, started: Date) {
            self.written = written
            self.total = total
            self.started = started
        }

        public var fraction: Double { total == 0 ? 1 : min(1, Double(written) / Double(total)) }

        /// Seconds left at the pace so far; nil until there's a pace to go on.
        public func secondsRemaining(now: Date = Date()) -> Double? {
            let elapsed = now.timeIntervalSince(started)
            guard written > 0, elapsed >= 1 else { return nil }
            return Double(total - min(written, total)) / (Double(written) / elapsed)
        }

        /// "12.0 GB of 64.0 GB - about 40s left"
        public var description: String {
            var text = "\(DiskStorage.format(written)) of \(DiskStorage.format(total))"
            if let left = secondsRemaining() {
                let seconds = Int(left.rounded(.up))
                text += seconds >= 90 ? " - about \((seconds + 59) / 60) min left" : " - about \(max(seconds, 1))s left"
            }
            return text
        }
    }

    public static func setCapacity(
        of path: String, to size: UInt64, reserveSpace: Bool,
        progress: ((ReservationProgress) -> Void)? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw StorageError.noImage(path) }
        let current = capacity(of: path)
        guard size >= current else { throw StorageError.wouldShrink(current: current, requested: size) }

        if reserveSpace {
            // Only what is not already allocated has to come from free
            // space; an image that is already mostly written needs very
            // little more to become fully reserved.
            let allocated = allocatedSize(of: path)
            let extra = size > allocated ? size - allocated : 0
            let free = hostFreeSpace(forImageAt: path)
            guard extra <= free else { throw StorageError.notEnoughHostSpace(needed: extra, available: free) }
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        // Reserve *before* extending: `F_PREALLOCATE` can only claim space
        // past the end of the file, so the blocks have to be taken first and
        // the file grown into them.
        if reserveSpace {
            preallocate(fd: handle.fileDescriptor, to: size)
        }
        // Extends the file without writing anything; the new range reads as
        // zeroes and costs nothing until the guest writes to it.
        try handle.truncate(atOffset: size)

        // Anything still sparse *inside* the file is out of reach of
        // `F_PREALLOCATE` - which is the normal case when an existing
        // dynamic image is switched to fixed, since its holes are in the
        // middle rather than past the end. Those have to be written to be
        // reserved, and without this "fixed" silently did nothing at all to
        // such an image.
        if reserveSpace {
            try fillHoles(fd: handle.fileDescriptor, upTo: off_t(size), progress: progress)
        }
    }

    /// Reserves real blocks so the space cannot be taken by anything else on
    /// the Mac.
    ///
    /// `fst_length` is the number of bytes to allocate **beyond the current
    /// end of the file** - that is what `F_PEOFPOSMODE` means. Passing the
    /// file's total size instead reserves a second copy of everything
    /// already there: a 4 GB image asked to become a 4 GB fixed disk ended
    /// up occupying 8.5 GB, which is the opposite of what "fixed" is for.
    /// Only the shortfall gets requested.
    ///
    /// Allowed to fail - a volume may refuse, or be too fragmented - and a
    /// failure is not fatal: the file still gets its full length from the
    /// `truncate` that follows, it is just sparse rather than reserved.
    /// A weaker guarantee, not a broken disk, so it is reported rather than
    /// thrown.
    @discardableResult
    private static func preallocate(fd: Int32, to size: UInt64) -> Bool {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        let currentLength = UInt64(status.st_size)
        guard size > currentLength else { return true }
        let shortfall = off_t(size - currentLength)

        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: shortfall,
            fst_bytesalloc: 0)
        if fcntl(fd, F_PREALLOCATE, &store) != -1 { return true }
        // Retry without demanding one contiguous run.
        store.fst_flags = UInt32(F_ALLOCATECONTIG)
        return fcntl(fd, F_PREALLOCATE, &store) != -1
    }

    /// Writes zeroes over every unallocated range in the file, so the space
    /// is really the guest's and cannot be taken by anything else.
    ///
    /// Only the holes: `SEEK_HOLE`/`SEEK_DATA` walk the file's allocation
    /// map, so an image that is already mostly written costs almost nothing
    /// here, while a freshly-created 64 GB one genuinely writes 64 GB. That
    /// is the honest cost of reserving space, and the reason `fixed` is
    /// offered as a choice rather than being the default.
    ///
    /// Existing data is never touched - a hole reads as zeroes already, so
    /// writing zeroes into one changes nothing the guest can observe.
    private static func fillHoles(fd: Int32, upTo end: off_t, progress: ((ReservationProgress) -> Void)?) throws {
        let chunkSize = 8 * 1024 * 1024
        let zeroes = [UInt8](repeating: 0, count: chunkSize)
        // Zeroes don't need to sit in the page cache on their way to disk;
        // tens of GB of them there just squeezes everything else on the Mac.
        fcntl(fd, F_NOCACHE, 1)
        defer { fcntl(fd, F_NOCACHE, 0) }

        let total = holeBytes(fd: fd, upTo: end)
        let started = Date()
        var reserved: UInt64 = 0
        var lastReport = Date.distantPast
        if total > 0 { progress?(ReservationProgress(written: 0, total: total, started: started)) }

        var offset: off_t = 0
        while offset < end {
            let holeStart = lseek(fd, offset, SEEK_HOLE)
            // No hole at or after `offset`: the rest is allocated.
            guard holeStart >= 0, holeStart < end else { break }
            var dataStart = lseek(fd, holeStart, SEEK_DATA)
            // No data after the hole means the hole runs to the end.
            if dataStart < 0 { dataStart = end }
            let holeEnd = min(dataStart, end)
            guard holeEnd > holeStart else {
                offset = holeStart + off_t(chunkSize)
                continue
            }

            var position = holeStart
            try zeroes.withUnsafeBytes { buffer in
                while position < holeEnd {
                    let count = Int(min(off_t(chunkSize), holeEnd - position))
                    let written = pwrite(fd, buffer.baseAddress, count, position)
                    guard written > 0 else {
                        throw StorageError.resizeFailed(
                            "couldn't reserve space at offset \(position) - \(String(cString: strerror(errno)))")
                    }
                    position += off_t(written)
                    reserved += UInt64(written)
                    if let progress, Date().timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = Date()
                        progress(ReservationProgress(written: min(reserved, total), total: total, started: started))
                    }
                }
            }
            offset = holeEnd
        }
        // Make sure the allocation is on disk, not just promised.
        fcntl(fd, F_FULLFSYNC)
        if total > 0 { progress?(ReservationProgress(written: total, total: total, started: started)) }
    }

    /// Bytes of unallocated space before `end` - what `fillHoles` will write.
    /// Walks the allocation map only, so it is quick even for a huge file.
    static func holeBytes(fd: Int32, upTo end: off_t) -> UInt64 {
        var total: UInt64 = 0
        var offset: off_t = 0
        while offset < end {
            let holeStart = lseek(fd, offset, SEEK_HOLE)
            guard holeStart >= 0, holeStart < end else { break }
            var dataStart = lseek(fd, holeStart, SEEK_DATA)
            if dataStart < 0 { dataStart = end }
            let holeEnd = min(dataStart, end)
            if holeEnd > holeStart { total += UInt64(holeEnd - holeStart) }
            offset = max(holeEnd, holeStart + 1)
        }
        return total
    }

    /// Creates a new image of `size`, sparse or reserved per `policy`.
    public static func createImage(at path: String, policy: StoragePolicy) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        try setCapacity(of: path, to: policy.size, reserveSpace: policy.mode == .fixed)
    }

    // MARK: - Policy storage

    /// Policies live next to the images they describe, keyed by image
    /// filename.
    private static var policyFile: URL {
        MSLPaths.appSupport.appendingPathComponent("storage.json")
    }

    private static func loadPolicies() -> [String: StoragePolicy] {
        guard let data = try? Data(contentsOf: policyFile),
              let policies = try? JSONDecoder().decode([String: StoragePolicy].self, from: data) else { return [:] }
        return policies
    }

    /// The policy for an image. An image that predates this feature reports
    /// its real state rather than a default: whatever size it already is,
    /// and dynamic if it is actually sparse on disk.
    public static func policy(forImageNamed name: String, path: String? = nil) -> StoragePolicy {
        if let stored = loadPolicies()[name] { return stored }
        guard let path, FileManager.default.fileExists(atPath: path) else { return StoragePolicy() }
        let current = capacity(of: path)
        return StoragePolicy(
            mode: isSparse(path) ? .dynamic : .fixed,
            size: max(current, StoragePolicy.minimumSize),
            autoGrow: false)
    }

    /// Only a policy someone actually saved - nil where `policy(forImageNamed:)`
    /// would fall back to describing the image as it is.
    public static func storedPolicy(forImageNamed name: String) -> StoragePolicy? {
        loadPolicies()[name]
    }

    public static func setPolicy(_ policy: StoragePolicy, forImageNamed name: String) {
        var policies = loadPolicies()
        policies[name] = policy
        MSLPaths.ensureDirectory(MSLPaths.appSupport)
        guard let data = try? JSONEncoder().encode(policies) else { return }
        try? data.write(to: policyFile, options: .atomic)
    }

    /// Forgets everything recorded about an image - policy, usage sample and
    /// any pending resize - when the image itself is deleted. Left behind, a
    /// reinstalled distro would inherit a policy (a fixed 64 GB size, say)
    /// nobody chose for it.
    public static func forgetImage(named name: String) {
        var policies = loadPolicies()
        if policies.removeValue(forKey: name) != nil, let data = try? JSONEncoder().encode(policies) {
            try? data.write(to: policyFile, options: .atomic)
        }
        if let data = try? Data(contentsOf: usageFile),
           var all = try? JSONDecoder().decode([String: Usage].self, from: data),
           all.removeValue(forKey: name) != nil,
           let updated = try? JSONEncoder().encode(all) {
            try? updated.write(to: usageFile, options: .atomic)
        }
        clearPendingFilesystemResize(forImageNamed: name)
    }

    // MARK: - Telling the guest about new space

    /// Growing the image file gives the guest a bigger *disk*; its
    /// filesystem still ends where it used to. `resize2fs` on the root device
    /// fixes that, but it can only run once the guest is up - so a resize leaves a
    /// marker here and the daemon acts on it after the next start.
    private static func resizeMarker(forImageNamed name: String) -> URL {
        MSLPaths.appSupport.appendingPathComponent(".resize-pending-\(name)")
    }

    public static func markFilesystemResizePending(forImageNamed name: String) {
        MSLPaths.ensureDirectory(MSLPaths.appSupport)
        FileManager.default.createFile(atPath: resizeMarker(forImageNamed: name).path, contents: nil)
    }

    public static func filesystemResizeIsPending(forImageNamed name: String) -> Bool {
        FileManager.default.fileExists(atPath: resizeMarker(forImageNamed: name).path)
    }

    public static func clearPendingFilesystemResize(forImageNamed name: String) {
        try? FileManager.default.removeItem(at: resizeMarker(forImageNamed: name))
    }

    /// The command that grows the guest's filesystem to fill its disk.
    ///
    /// The root filesystem is the raw block device with no partition table,
    /// so there is no partition to extend first. `resize2fs` on a mounted
    /// ext4 does an online resize, and is a no-op when the filesystem
    /// already fills the device, so running it once more than necessary is
    /// harmless.
    ///
    /// The device is read from `/proc/mounts` rather than named: it was
    /// `/dev/vda` under virtio-blk and is `/dev/nvme0n1` since the NVMe
    /// switch, and a guest may show root as `/dev/root` (a kernel alias for
    /// the `root=` device), in which case the command line has the real name.
    public static let filesystemResizeCommand = """
    if command -v resize2fs >/dev/null 2>&1; then
        dev=$(awk '$2 == "/" && $1 ~ "^/dev/" { d = $1 } END { print d }' /proc/mounts)
        if [ -z "$dev" ] || [ "$dev" = /dev/root ]; then
            dev=$(tr ' ' '\\n' < /proc/cmdline | sed -n 's/^root=//p' | tail -n 1)
        fi
        resize2fs "${dev:-/dev/nvme0n1}" 2>&1 || echo "msl: resize2fs failed"
    else
        echo "msl: resize2fs isn't installed in this guest - install e2fsprogs to use the extra space"
    fi
    """

    /// Reads how full the guest's root filesystem is, as a fraction.
    public static let usageCommand = "df -k / | awk 'NR==2 {print $2, $3}'"

    /// Parses `usageCommand`'s output into (total, used) bytes.
    public static func parseUsage(_ output: String) -> (total: UInt64, used: UInt64)? {
        let fields = output.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt64($0) }
        guard fields.count >= 2 else { return nil }
        return (fields[0] * 1024, fields[1] * 1024)
    }

    // MARK: - Remembering how full the guest was

    private static var usageFile: URL {
        MSLPaths.appSupport.appendingPathComponent("storage-usage.json")
    }

    public struct Usage: Codable, Equatable {
        public var total: UInt64
        public var used: UInt64
        public var sampled: Date
        public var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    public static func usage(forImageNamed name: String) -> Usage? {
        guard let data = try? Data(contentsOf: usageFile),
              let all = try? JSONDecoder().decode([String: Usage].self, from: data) else { return nil }
        return all[name]
    }

    public static func recordUsage(_ usage: Usage, forImageNamed name: String) {
        var all = (try? Data(contentsOf: usageFile))
            .flatMap { try? JSONDecoder().decode([String: Usage].self, from: $0) } ?? [:]
        all[name] = usage
        MSLPaths.ensureDirectory(MSLPaths.appSupport)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: usageFile, options: .atomic)
    }

    // MARK: - The decision made at boot

    public struct BootPreparation {
        public var grewTo: UInt64?
        public var needsFilesystemResize: Bool
        public var note: String?
    }

    /// Applies the storage policy just before a VM is built - the only
    /// moment the image can safely change size, because that is when nothing
    /// has it open and the attachment hasn't read its length yet.
    ///
    /// Dynamic mode grows here, using the fullness recorded the last time
    /// the guest ran. It has to work from a remembered sample rather than a
    /// live one: the guest isn't running yet, and once it is, its disk size
    /// is already fixed for that boot.
    @discardableResult
    public static func prepareForBoot(imagePath: String, imageName: String) -> BootPreparation {
        var result = BootPreparation(grewTo: nil, needsFilesystemResize: filesystemResizeIsPending(forImageNamed: imageName), note: nil)
        guard FileManager.default.fileExists(atPath: imagePath) else { return result }

        let policy = policy(forImageNamed: imageName, path: imagePath)
        let current = capacity(of: imagePath)
        var target = current

        switch policy.mode {
        case .fixed:
            // The reservation is re-applied on every boot: a fixed disk that
            // silently became sparse (restored from a backup, copied
            // between volumes) is not what the user asked for.
            target = max(current, policy.size)
        case .dynamic:
            guard policy.autoGrow, let usage = usage(forImageNamed: imageName) else { break }
            guard usage.fraction >= StoragePolicy.growThreshold else { break }
            guard current < policy.size else {
                result.note = "\(imageName) is \(Int(usage.fraction * 100))% full and already at its \(DiskStorage.format(policy.size)) limit"
                break
            }
            target = min(current + StoragePolicy.growStep, policy.size)
        }

        guard target > current || (policy.mode == .fixed && isSparse(imagePath)) else { return result }
        do {
            try setCapacity(of: imagePath, to: max(target, current), reserveSpace: policy.mode == .fixed)
            if target > current {
                markFilesystemResizePending(forImageNamed: imageName)
                result.grewTo = target
                result.needsFilesystemResize = true
            }
        } catch {
            result.note = "\(error)"
        }
        return result
    }
}
