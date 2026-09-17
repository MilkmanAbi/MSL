import AppKit
import Foundation

/// A Linux image someone built themselves: a folder under
/// `~/Library/Application Support/MSL/Custom Images/` holding a kernel, an
/// initramfs and a disk, which MSL boots exactly like one of its own
/// distros (`GuestDistro.custom`).
///
/// ```
/// Custom Images/
///   README.md              written by MSL - how to make one
///   _MSL Guest Kit/        written by MSL - provision-msl.sh + daemon sources
///   my-arch/               one image; the folder name is its id
///     Image                raw arm64 kernel (not a compressed vmlinuz)
///     initramfs            must be able to mount ext4 on NVMe
///     rootfs.img           raw ext4 filesystem, no partition table
///     image.json           optional: name, description, kernelCommandLine
/// ```
///
/// MSL never deletes anything in these folders. Removing a custom image
/// from MSL removes its instances and MSL's records about it; the files are
/// the user's.
///
/// What MSL cannot check from the Mac is whether the image carries MSL's
/// guest daemons (`shellinit` above all). Without them the VM boots and MSL
/// cannot talk to it - no terminal, no apps. The README and the guest kit
/// exist for exactly that, and "Start from an installed distro" sidesteps
/// it: the copy already has them.
public struct CustomImage: Equatable, Identifiable, Sendable {
    public let slug: String
    public let folder: URL
    /// From `image.json`, else the folder name.
    public let name: String
    public let summary: String?
    public let files: GuestBootFiles
    /// Anything that stops the image booting. An image with problems is
    /// listed, with its problems, but can't be used to create an instance.
    public let problems: [String]
    /// Worth knowing, but the image can still be tried.
    public let warnings: [String]

    public var id: String { slug }
    public var distro: GuestDistro { .custom(slug) }
    public var isUsable: Bool { problems.isEmpty }

    public static let folderName = "Custom Images"
    public static let kitFolderName = "_MSL Guest Kit"
    public static let metadataFileName = "image.json"

    /// Accepted names for each file, first match wins. `image.json` can
    /// name them explicitly instead.
    static let kernelNames = ["Image", "kernel", "Image.bin"]
    static let initramfsNames = ["initramfs", "initrd", "initramfs.img", "initrd.img", "initramfs.cpio.gz"]
    static let diskNames = ["rootfs.img", "disk.img", "rootfs.ext4"]

    public static func directory(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Folder names become ids in `instances.json`, protocol lines and
    /// storage keys, so they are held to what every one of those accepts.
    public static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 40, let first = slug.first, first.isLetter || first.isNumber else { return false }
        return slug.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    // MARK: - image.json

    struct Metadata: Decodable {
        var name: String?
        var description: String?
        var kernel: String?
        var initramfs: String?
        var disk: String?
        var kernelCommandLine: String?
    }

    static func metadata(in folder: URL) -> (Metadata?, String?) {
        let url = folder.appendingPathComponent(metadataFileName)
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        do {
            return (try JSONDecoder().decode(Metadata.self, from: data), nil)
        } catch {
            return (nil, "\(metadataFileName) isn't valid JSON (\(error.localizedDescription)) - it's being ignored")
        }
    }

    // MARK: - Resolving

    /// The files `slug` boots from. Cheap - no validation - because the
    /// daemon resolves this every time it builds an instance's VM.
    public static func bootFiles(slug: String, appSupport: URL = MSLPaths.appSupport) -> GuestBootFiles {
        let folder = directory(appSupport: appSupport).appendingPathComponent(slug, isDirectory: true)
        return bootFiles(folder: folder, slug: slug, metadata: metadata(in: folder).0)
    }

    static func bootFiles(folder: URL, slug: String, metadata: Metadata?) -> GuestBootFiles {
        func pick(_ explicit: String?, _ candidates: [String]) -> URL {
            if let explicit, !explicit.isEmpty, !explicit.contains("/") {
                return folder.appendingPathComponent(explicit)
            }
            let found = candidates.first { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            return folder.appendingPathComponent(found ?? candidates[0])
        }
        let commandLine = metadata?.kernelCommandLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GuestBootFiles(
            kernel: pick(metadata?.kernel, kernelNames),
            initramfs: pick(metadata?.initramfs, initramfsNames),
            disk: pick(metadata?.disk, diskNames),
            storageKey: GuestDistro.custom(slug).diskImageFilename,
            kernelCommandLine: commandLine?.isEmpty == false ? commandLine : nil)
    }

    // MARK: - Scanning

    /// Every image folder, validated, sorted by name. Folders starting with
    /// `_` or `.` are MSL's own or hidden and are skipped.
    public static func scan(appSupport: URL = MSLPaths.appSupport) -> [CustomImage] {
        let root = directory(appSupport: appSupport)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix("_") }
            .map { inspect(folder: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One image, by id - nil when its folder is gone.
    public static func find(slug: String, appSupport: URL = MSLPaths.appSupport) -> CustomImage? {
        let folder = directory(appSupport: appSupport).appendingPathComponent(slug, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return inspect(folder: folder)
    }

    static func inspect(folder: URL) -> CustomImage {
        let slug = folder.lastPathComponent
        let (meta, metaWarning) = metadata(in: folder)
        let files = bootFiles(folder: folder, slug: slug, metadata: meta)
        var problems: [String] = []
        var warnings: [String] = metaWarning.map { [$0] } ?? []

        if !isValidSlug(slug) {
            problems.append("Rename the folder using only letters, digits, - and _ (it becomes the image's id).")
        }
        if let problem = kernelProblem(at: files.kernel) { problems.append(problem) }
        if !FileManager.default.fileExists(atPath: files.initramfs.path) {
            problems.append("No initramfs - add a file named \(initramfsNames[0]).")
        }
        let disk = diskCheck(at: files.disk, hasCommandLine: files.kernelCommandLine != nil)
        problems += disk.problems
        warnings += disk.warnings

        let name = meta?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = meta?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomImage(
            slug: slug, folder: folder,
            name: name?.isEmpty == false ? name! : slug,
            summary: summary?.isEmpty == false ? summary : nil,
            files: files, problems: problems, warnings: warnings)
    }

    // MARK: - Validation

    static func readPrefix(_ url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)).map { Array($0) }
    }

    /// Why this file can't be booted by Virtualization's Linux boot loader,
    /// or nil if it looks like a raw arm64 kernel `Image`.
    ///
    /// The arm64 boot protocol puts `ARM\x64` at offset 0x38 of every raw
    /// `Image` (MSL's own `disk-Image` included). What people usually have
    /// instead is a distro's `vmlinuz`: gzip, or an EFI "zboot" PE file whose
    /// header says `zimg` - both need unwrapping first, which is why
    /// `build-kernel.sh` exists at all.
    public static func kernelProblem(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "No kernel - add the raw arm64 kernel as a file named \(kernelNames[0])."
        }
        guard let bytes = readPrefix(url, count: 0x210), bytes.count >= 0x40 else {
            return "\(url.lastPathComponent) is too small to be a kernel."
        }
        if Array(bytes[0x38..<0x3C]) == Array("ARMd".utf8) { return nil }
        if bytes[0] == 0x1F, bytes[1] == 0x8B {
            return "\(url.lastPathComponent) is gzip-compressed (a vmlinuz). Decompress it to the raw Image: gunzip -c vmlinuz > Image."
        }
        if bytes[0] == 0x28, bytes[1] == 0xB5, bytes[2] == 0x2F, bytes[3] == 0xFD {
            return "\(url.lastPathComponent) is zstd-compressed. Decompress it to the raw Image: zstd -d vmlinuz -o Image."
        }
        if Array(bytes[0..<2]) == Array("MZ".utf8), Array(bytes[4..<8]) == Array("zimg".utf8) {
            return "\(url.lastPathComponent) is an EFI zboot vmlinuz - a compressed kernel wrapped for EFI. MSL needs the raw arm64 Image inside it; the README in Custom Images shows how to extract it."
        }
        if Array(bytes[0..<4]) == [0x7F, 0x45, 0x4C, 0x46] {
            return "\(url.lastPathComponent) is an ELF vmlinux. MSL needs the arm64 Image (arch/arm64/boot/Image) built alongside it."
        }
        if bytes.count >= 0x206, Array(bytes[0x202..<0x206]) == Array("HdrS".utf8) {
            return "\(url.lastPathComponent) is an x86 kernel. Macs with Apple silicon boot arm64 Linux only."
        }
        return "\(url.lastPathComponent) doesn't look like an arm64 Linux kernel Image."
    }

    /// The disk must be something the kernel can mount as `root=/dev/nvme0n1`
    /// with `rootfstype=ext4` - a bare ext4 filesystem - unless the image
    /// supplies its own command line.
    static func diskCheck(at url: URL, hasCommandLine: Bool) -> (problems: [String], warnings: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (["No disk - add the root filesystem as a file named \(diskNames[0])."], [])
        }
        guard let bytes = readPrefix(url, count: 1082), bytes.count == 1082 else {
            return (["\(url.lastPathComponent) is too small to be a disk."], [])
        }
        let isExt = bytes[1080] == 0x53 && bytes[1081] == 0xEF
        let isPartitioned = (bytes[510] == 0x55 && bytes[511] == 0xAA) || Array(bytes[512..<520]) == Array("EFI PART".utf8)
        if isExt { return ([], []) }
        if hasCommandLine {
            return ([], ["\(url.lastPathComponent) isn't a bare ext2/3/4 filesystem - booting with the kernelCommandLine from \(metadataFileName)."])
        }
        if isPartitioned {
            return (["\(url.lastPathComponent) has a partition table. MSL boots a bare ext4 filesystem - extract the root partition, or set kernelCommandLine in \(metadataFileName) (for example root=/dev/nvme0n1p2)."], [])
        }
        return (["\(url.lastPathComponent) isn't an ext4 filesystem. MSL boots a raw ext4 image - or set kernelCommandLine in \(metadataFileName) for anything else."], [])
    }

    // MARK: - The folder

    /// Creates `Custom Images` with its README and guest kit, refreshing
    /// both, and returns the folder. `kitSource` is the bundled
    /// `GuestKit` resources directory, when there is one.
    @discardableResult
    public static func prepareFolder(appSupport: URL = MSLPaths.appSupport, kitSource: URL? = bundledKit()) throws -> URL {
        let root = directory(appSupport: appSupport)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if let kitSource, FileManager.default.fileExists(atPath: kitSource.path) {
            let kit = root.appendingPathComponent(kitFolderName, isDirectory: true)
            try? FileManager.default.removeItem(at: kit)
            try FileManager.default.copyItem(at: kitSource, to: kit)
        }
        return root
    }

    /// The guest kit `build-app.sh` ships in MSL.app (`Resources/GuestKit`):
    /// this process's own bundle when it is the app, else the installed app,
    /// which is where the `msl` CLI finds it.
    public static func bundledKit() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.msl.app") {
            candidates.append(app.appendingPathComponent("Contents/Resources"))
        }
        return candidates.map { $0.appendingPathComponent("GuestKit", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("daemons").path) }
    }

    public enum CreateError: Error, CustomStringConvertible {
        case invalidName(String)
        case exists(String)
        case notInstalled(GuestDistro)

        public var description: String {
            switch self {
            case .invalidName(let name): return "“\(name)” can't be an image id - use letters, digits, - and _"
            case .exists(let name): return "there's already a custom image called \(name)"
            case .notInstalled(let distro): return "\(distro.rawValue) isn't installed, so there's nothing to copy"
            }
        }
    }

    /// Starts a custom image from an installed distro: its kernel,
    /// initramfs and disk copied into a new folder. On APFS the copies are
    /// clones, so this is instant and takes no space until either side
    /// changes. The result already has MSL's guest daemons, which is the
    /// part a from-scratch image most often gets wrong.
    @discardableResult
    public static func create(slug: String, from distro: GuestDistro, name: String? = nil,
                              appSupport: URL = MSLPaths.appSupport) throws -> CustomImage {
        guard isValidSlug(slug) else { throw CreateError.invalidName(slug) }
        let source = distro.bootFiles(appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: source.disk.path) else { throw CreateError.notInstalled(distro) }
        let root = directory(appSupport: appSupport)
        let folder = root.appendingPathComponent(slug, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw CreateError.exists(slug) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source.kernel, to: folder.appendingPathComponent(kernelNames[0]))
            try FileManager.default.copyItem(at: source.initramfs, to: folder.appendingPathComponent(initramfsNames[0]))
            try FileManager.default.copyItem(at: source.disk, to: folder.appendingPathComponent(diskNames[0]))
            var metadata: [String: String] = ["description": "Started from \(distro.rawValue)"]
            if let name, !name.isEmpty { metadata["name"] = name }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: folder.appendingPathComponent(metadataFileName))
        } catch {
            // Half a folder would list as a broken image forever.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return inspect(folder: folder)
    }

    static let readme = #"""
    # Custom Images

    Every folder here is a Linux image MSL can run. Put three files in a folder,
    and it appears under **Custom images** when you create a new instance in MSL.

    ```
    Custom Images/
      my-image/            the folder name is the image's id: letters, digits, - and _
        Image              the kernel: a raw arm64 kernel Image
        initramfs          an initramfs that can mount ext4 on an NVMe disk
        rootfs.img         the root filesystem: a raw ext4 image, no partition table
        image.json         optional - see below
    ```

    MSL never deletes anything in this folder. Removing a custom image in MSL
    removes its instances; the files stay yours.

    ## The quickest way: start from a distro

    In MSL, **New Instance ▸ Custom images ▸ Start from a distro** copies an
    installed distro here as a new image. On APFS the copy is instant and takes no
    extra space until you change something. Boot it, install what you want, and it
    stays that way - it's your image now. Everything MSL needs is already inside.

    ## Building one from scratch

    **1. The kernel** must be the raw arm64 `Image`, not a compressed `vmlinuz`.

    - `vmlinuz` that is gzip: `gunzip -c vmlinuz > Image`
    - an EFI "zboot" `vmlinuz` (most current distros): the compressed kernel starts
      at the offset stored in the header. Extract it with the kernel's own
      `scripts/extract-vmlinux`, or build the kernel and take
      `arch/arm64/boot/Image`.
    - It needs virtio (network, console, vsock, balloon, filesystem sharing), NVMe
      and ext4. Distro kernels generally have all of these as modules.

    MSL checks the kernel header and tells you if it's the wrong kind.

    **2. The initramfs** has to find and mount the root filesystem, so it needs the
    `nvme` and `ext4` modules (or a kernel with them built in). A distro's own
    initramfs usually works; Alpine's `mkinitfs -F "base ext4 nvme virtio"` makes
    a small one.

    **3. The root filesystem** is a raw ext4 image. From a container or a Linux
    machine: `mkfs.ext4 -d <rootfs-directory> rootfs.img 4G`. MSL grows it when you
    need more room.

    **4. MSL's guest daemons.** This is the step people miss. MSL talks to Linux
    through small programs inside the image - `shellinit` above all. Without them
    the image boots but MSL can't reach it: no terminal, no apps, no files.
    `_MSL Guest Kit` holds everything: run

    ```sh
    sh "_MSL Guest Kit/provision/provision-msl.sh" --no-firstboot
    ```

    as root inside the image's filesystem before packing it - in a container
    (`docker run --platform linux/arm64 ...`) or a chroot. It detects the distro,
    init system and package manager, installs what MSL needs, and builds the
    daemons from `_MSL Guest Kit/daemons`.

    ## image.json

    All optional:

    ```json
    {
      "name": "My Arch",
      "description": "Arch with my dotfiles",
      "kernel": "Image",
      "initramfs": "initramfs",
      "disk": "rootfs.img",
      "kernelCommandLine": "console=hvc0 root=/dev/nvme0n1 rootfstype=ext4 rw"
    }
    ```

    `kernelCommandLine` replaces MSL's. Leave it out unless your image needs
    something different - a partitioned disk (`root=/dev/nvme0n1p2`), another
    filesystem, extra kernel options.

    ## Good to know

    - Instances of the same image share its disk, so only one runs at a time.
    - Only arm64 Linux runs on Apple silicon.
    - Found a problem? MSL lists each image with what's wrong with it, if anything.
    """#
}
