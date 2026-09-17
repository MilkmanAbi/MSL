import XCTest
@testable import MSLCore

final class GuestDistroIdentityTests: XCTestCase {
    func testPublishedNamesAreUnchanged() {
        XCTAssertEqual(GuestDistro.allCases.map(\.rawValue),
                       ["alpine", "debian", "ubuntu", "kali", "arch", "fedora",
                        "rocky", "alma", "centos", "oracle", "opensuse", "nix"])
        for distro in GuestDistro.allCases {
            XCTAssertEqual(GuestDistro(rawValue: distro.rawValue), distro)
            XCTAssertFalse(distro.isCustom)
        }
        XCTAssertEqual(GuestDistro.alpine.diskImageFilename, "rootfs.img")
        XCTAssertEqual(GuestDistro.debian.diskImageFilename, "rootfs-debian.img")
    }

    func testCustomRoundTrip() throws {
        let custom = GuestDistro(rawValue: "custom:my-arch_2")
        XCTAssertEqual(custom, .custom("my-arch_2"))
        XCTAssertEqual(custom?.rawValue, "custom:my-arch_2")
        XCTAssertEqual(custom?.diskImageFilename, "custom-my-arch_2.img")
        XCTAssertNil(GuestDistro(rawValue: "custom:"))
        XCTAssertNil(GuestDistro(rawValue: "custom:../etc"))
        XCTAssertNil(GuestDistro(rawValue: "custom:has space"))
        XCTAssertNil(GuestDistro(rawValue: "slackware"))
        XCTAssertFalse(GuestDistro.allCases.contains { $0.isCustom })

        let encoded = try JSONEncoder().encode(["a": GuestDistro.custom("x"), "b": .debian])
        XCTAssertEqual(try JSONDecoder().decode([String: GuestDistro].self, from: encoded),
                       ["a": .custom("x"), "b": .debian])
    }

    func testPublishedBootFilesAreTheSharedKernel() {
        let support = URL(fileURLWithPath: "/tmp/support")
        let files = GuestDistro.fedora.bootFiles(appSupport: support)
        XCTAssertEqual(files.kernel.path, "/tmp/support/disk-Image")
        XCTAssertEqual(files.initramfs.path, "/tmp/support/disk-initramfs-virt")
        XCTAssertEqual(files.disk.path, "/tmp/support/rootfs-fedora.img")
        XCTAssertEqual(files.storageKey, "rootfs-fedora.img")
        XCTAssertNil(files.kernelCommandLine)
    }
}

final class InstanceRegistryLenienceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One value this build can't read used to empty the whole registry,
    /// and the next registration saved over every other instance.
    func testUnknownValueNeitherHidesNorLosesInstances() throws {
        let path = directory.appendingPathComponent("instances.json")
        try Data(#"{"default":"alpine","future":"distro-from-msl-9","mine":"custom:my-arch"}"#.utf8).write(to: path)
        let registry = InstanceRegistry(path: path)
        XCTAssertEqual(registry.entries(), ["default": .alpine, "mine": .custom("my-arch")])

        try registry.ensureRegistered("work", distro: .debian)
        let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))
        XCTAssertEqual(stored, ["default": "alpine", "future": "distro-from-msl-9",
                                "mine": "custom:my-arch", "work": "debian"])

        try registry.remove("mine")
        let afterRemove = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))
        XCTAssertEqual(afterRemove["future"], "distro-from-msl-9")
        XCTAssertNil(afterRemove["mine"])
    }

    func testUnreadableFileIsRefusedNotOverwritten() throws {
        let path = directory.appendingPathComponent("instances.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: path)
        let registry = InstanceRegistry(path: path)
        XCTAssertThrowsError(try registry.ensureRegistered("work", distro: .debian))
        XCTAssertEqual(try Data(contentsOf: path), garbage)
    }
}

final class CustomImageTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func bytes(_ count: Int, _ patches: [(Int, [UInt8])]) -> Data {
        var data = [UInt8](repeating: 0, count: count)
        for (offset, patch) in patches { data.replaceSubrange(offset..<offset + patch.count, with: patch) }
        return Data(data)
    }

    private var rawKernel: Data { bytes(0x400, [(0, Array("MZ".utf8)), (0x38, Array("ARMd".utf8))]) }
    private var ext4Disk: Data { bytes(4096, [(1080, [0x53, 0xEF])]) }

    private func makeImage(_ slug: String, files: [String: Data], metadata: String? = nil) throws -> URL {
        let folder = CustomImage.directory(appSupport: support).appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        if let metadata { try Data(metadata.utf8).write(to: folder.appendingPathComponent("image.json")) }
        return folder
    }

    func testKernelHeaders() throws {
        func problem(_ data: Data) throws -> String? {
            let url = support.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            return CustomImage.kernelProblem(at: url)
        }
        XCTAssertNil(try problem(rawKernel))
        XCTAssertTrue(try problem(bytes(0x400, [(0, [0x1F, 0x8B])]))?.contains("gzip") == true)
        XCTAssertTrue(try problem(bytes(0x400, [(0, Array("MZ".utf8)), (4, Array("zimg".utf8))]))?.contains("zboot") == true)
        XCTAssertTrue(try problem(bytes(0x400, [(0, [0x7F, 0x45, 0x4C, 0x46])]))?.contains("ELF") == true)
        XCTAssertTrue(try problem(bytes(0x400, [(0x202, Array("HdrS".utf8))]))?.contains("x86") == true)
        XCTAssertNotNil(try problem(bytes(0x400, [])))
        XCTAssertTrue(CustomImage.kernelProblem(at: support.appendingPathComponent("missing"))?.contains("No kernel") == true)
    }

    /// MSL's own shipped kernel must pass the check it tells users to meet.
    func testShippedKernelPasses() throws {
        let shipped = MSLPaths.appSupport.appendingPathComponent("disk-Image")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shipped.path), "no installed kernel on this machine")
        XCTAssertNil(CustomImage.kernelProblem(at: shipped))
    }

    func testDiskChecks() throws {
        let partitioned = bytes(4096, [(510, [0x55, 0xAA])])
        let url = support.appendingPathComponent("disk")
        try partitioned.write(to: url)
        XCTAssertEqual(CustomImage.diskCheck(at: url, hasCommandLine: false).problems.count, 1)
        let withCommandLine = CustomImage.diskCheck(at: url, hasCommandLine: true)
        XCTAssertTrue(withCommandLine.problems.isEmpty)
        XCTAssertEqual(withCommandLine.warnings.count, 1)
        try ext4Disk.write(to: url)
        XCTAssertTrue(CustomImage.diskCheck(at: url, hasCommandLine: false) == ([], []))
    }

    func testScanFindsValidatesAndSkipsKit() throws {
        try makeImage("good", files: ["kernel": rawKernel, "initrd.img": Data("x".utf8), "rootfs.img": ext4Disk],
                      metadata: #"{"name":"Good One","description":"Mine","kernelCommandLine":"  console=hvc0 root=/dev/nvme0n1p2 "}"#)
        try makeImage("broken", files: ["Image": bytes(0x400, [(0, [0x1F, 0x8B])])])
        try makeImage("has space", files: ["Image": rawKernel, "initramfs": Data("x".utf8), "rootfs.img": ext4Disk])
        try FileManager.default.createDirectory(
            at: CustomImage.directory(appSupport: support).appendingPathComponent(CustomImage.kitFolderName),
            withIntermediateDirectories: true)

        let images = CustomImage.scan(appSupport: support)
        // Sorted by display name: "broken", "Good One", "has space".
        XCTAssertEqual(images.map(\.slug), ["broken", "good", "has space"])

        let good = try XCTUnwrap(images.first { $0.slug == "good" })
        XCTAssertTrue(good.isUsable, "\(good.problems)")
        XCTAssertEqual(good.name, "Good One")
        XCTAssertEqual(good.summary, "Mine")
        XCTAssertEqual(good.files.kernel.lastPathComponent, "kernel")
        XCTAssertEqual(good.files.initramfs.lastPathComponent, "initrd.img")
        XCTAssertEqual(good.files.storageKey, "custom-good.img")
        XCTAssertEqual(good.files.kernelCommandLine, "console=hvc0 root=/dev/nvme0n1p2")
        // Same files by path - the scan reports /private/var where the temp
        // directory was named /var, which is the same folder.
        let resolved = GuestDistro.custom("good").bootFiles(appSupport: support)
        for (a, b) in [(resolved.kernel, good.files.kernel), (resolved.initramfs, good.files.initramfs), (resolved.disk, good.files.disk)] {
            XCTAssertEqual(a.resolvingSymlinksInPath().path, b.resolvingSymlinksInPath().path)
        }
        XCTAssertEqual(resolved.storageKey, good.files.storageKey)
        XCTAssertEqual(resolved.kernelCommandLine, good.files.kernelCommandLine)

        let broken = try XCTUnwrap(images.first { $0.slug == "broken" })
        XCTAssertFalse(broken.isUsable)
        XCTAssertEqual(broken.problems.count, 3) // gzip kernel, no initramfs, no disk

        XCTAssertFalse(try XCTUnwrap(images.first { $0.slug == "has space" }).isUsable)
    }

    func testStartFromDistroCopiesAndNeverDeletesOnRemoval() throws {
        try rawKernel.write(to: support.appendingPathComponent("disk-Image"))
        try Data("initramfs".utf8).write(to: support.appendingPathComponent("disk-initramfs-virt"))
        try ext4Disk.write(to: support.appendingPathComponent("rootfs-debian.img"))

        let image = try CustomImage.create(slug: "my-debian", from: .debian, name: "My Debian", appSupport: support)
        XCTAssertTrue(image.isUsable, "\(image.problems)")
        XCTAssertEqual(image.name, "My Debian")
        XCTAssertEqual(try Data(contentsOf: image.files.disk), ext4Disk)
        XCTAssertThrowsError(try CustomImage.create(slug: "my-debian", from: .debian, appSupport: support))
        XCTAssertThrowsError(try CustomImage.create(slug: "nope", from: .fedora, appSupport: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CustomImage.directory(appSupport: support).appendingPathComponent("nope").path))

        XCTAssertEqual(DistroInstallation.files(for: image.distro, in: support), [])
        XCTAssertTrue(DistroInstallation.isInstalled(image.distro, in: support))
        DistroInstallation.deleteFiles(for: image.distro, in: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.files.disk.path))
    }

    func testPrepareFolderWritesReadmeAndKit() throws {
        let kit = support.appendingPathComponent("kit-source")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("daemons"), withIntermediateDirectories: true)
        try Data("int main(){}".utf8).write(to: kit.appendingPathComponent("daemons/shellinit.c"))
        let folder = try CustomImage.prepareFolder(appSupport: support, kitSource: kit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(CustomImage.kitFolderName)/daemons/shellinit.c").path))
        XCTAssertTrue(CustomImage.scan(appSupport: support).isEmpty, "the kit folder is not an image")
    }
}
