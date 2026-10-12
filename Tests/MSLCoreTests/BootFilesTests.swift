import XCTest
@testable import MSLCore

/// What an instance needs to boot, and what it is told when it hasn't got it.
///
/// The gap this closes: an instance can have a perfectly good disk of its own
/// and still have nothing to boot with, because the kernel and initramfs are
/// shared by every distro and arrive with the first one downloaded. A
/// shipment carries the filesystem and nothing else, so one installed onto a
/// Mac that had never downloaded a distro produced a complete-looking
/// instance that failed at start with a four-deep `VZErrorDomain` dump about
/// a kernel file (2026-10-02).
final class BootFilesTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-boot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func files(_ distro: GuestDistro = .alpine, instance: String = "work") -> GuestBootFiles {
        distro.bootFiles(instance: instance, appSupport: support)
    }

    func testAFreshMacIsMissingEverything() {
        XCTAssertEqual(files().missing.count, 3)
    }

    /// The shipment case exactly: the disk is there, the kernel is not.
    func testADiskWithoutAKernelIsNotBootable() throws {
        let boot = files()
        try write(boot.disk)
        XCTAssertEqual(boot.missing, [boot.kernel, boot.initramfs])

        let reason = try XCTUnwrap(boot.missingDescription(distro: .alpine))
        XCTAssertTrue(reason.contains("kernel"), reason)
        XCTAssertTrue(reason.contains("msl install alpine"), reason)
        // It must not say the disk is missing, because it isn't - that sent
        // someone looking for a corrupt shipment.
        XCTAssertFalse(reason.contains("its disk is missing"), reason)
    }

    func testEverythingPresentIsBootable() throws {
        let boot = files()
        try write(boot.disk)
        try write(boot.kernel)
        try write(boot.initramfs)
        XCTAssertEqual(boot.missing, [])
        XCTAssertNil(boot.missingDescription(distro: .alpine))
    }

    /// A kernel but no disk is the other way round, and says so.
    func testAKernelWithoutADiskSaysTheDiskIsGone() throws {
        let boot = files()
        try write(boot.kernel)
        try write(boot.initramfs)
        XCTAssertEqual(boot.missing, [boot.disk])
        let reason = try XCTUnwrap(boot.missingDescription(distro: .alpine))
        XCTAssertTrue(reason.contains("disk"), reason)
        XCTAssertFalse(reason.contains("kernel"), reason)
    }

    /// The kernel is shared, so downloading *any* distro makes every
    /// instance of every distro bootable. That is why the message names the
    /// instance's own distro rather than claiming only that one will do.
    func testTheKernelIsSharedAcrossDistros() throws {
        let alpine = GuestDistro.alpine.bootFiles(instance: "a", appSupport: support)
        let fedora = GuestDistro.fedora.bootFiles(instance: "b", appSupport: support)
        XCTAssertEqual(alpine.kernel, fedora.kernel)
        XCTAssertEqual(alpine.initramfs, fedora.initramfs)
        XCTAssertNotEqual(alpine.disk, fedora.disk)
    }

    func testShipmentReportsAMissingImage() throws {
        let boot = files(instance: "shipped")
        try write(boot.disk)
        XCTAssertNotNil(Shipment.missingDistroImage(for: "shipped", distro: .alpine,
                                                    appSupport: support))
        try write(boot.kernel)
        try write(boot.initramfs)
        XCTAssertNil(Shipment.missingDistroImage(for: "shipped", distro: .alpine,
                                                 appSupport: support))
    }

    // MARK: - A kernel the instance carries itself

    /// What makes a shipment standalone. The shared kernel arrives with the
    /// first distro downloaded, so a Mac that has downloaded nothing has
    /// none - and even one that has may be on a different MSL build with a
    /// different kernel, which is not the machine that was shipped.
    func testAnInstanceKernelWinsOverTheSharedOne() throws {
        let shared = support.appendingPathComponent("disk-Image")
        try write(shared)
        try write(support.appendingPathComponent("disk-initramfs-virt"))
        XCTAssertEqual(files().kernel, shared, "with no kernel of its own, the shared one")

        try write(InstanceDisk.kernelURL(instance: "work", appSupport: support))
        try write(InstanceDisk.initramfsURL(instance: "work", appSupport: support))
        XCTAssertEqual(files().kernel,
                       InstanceDisk.kernelURL(instance: "work", appSupport: support))
        XCTAssertEqual(files().initramfs,
                       InstanceDisk.initramfsURL(instance: "work", appSupport: support))
    }

    /// Both or neither. Half a pair would boot a kernel against the wrong
    /// modules, which is worse than falling back to the shared one.
    func testHalfAPairIsNotAKernel() throws {
        try write(InstanceDisk.kernelURL(instance: "work", appSupport: support))
        XCTAssertFalse(InstanceDisk.hasOwnKernel(instance: "work", appSupport: support))
        try write(InstanceDisk.initramfsURL(instance: "work", appSupport: support))
        XCTAssertTrue(InstanceDisk.hasOwnKernel(instance: "work", appSupport: support))
    }

    /// A shipped instance is bootable with no distro downloaded at all -
    /// which is the whole point.
    func testAShippedKernelMakesTheInstanceBootableAlone() throws {
        let boot = files()
        try write(boot.disk)
        XCTAssertNotNil(files().missingDescription(distro: .alpine))
        try write(InstanceDisk.kernelURL(instance: "work", appSupport: support))
        try write(InstanceDisk.initramfsURL(instance: "work", appSupport: support))
        XCTAssertNil(files().missingDescription(distro: .alpine),
                     "a shipment carries its own kernel, so it needs nothing else")
    }

    /// Removing an instance takes its kernel too, or the next instance to
    /// reuse the name boots somebody else's.
    func testRemovingAnInstanceTakesItsKernel() throws {
        try write(InstanceDisk.url(instance: "work", appSupport: support))
        try write(InstanceDisk.kernelURL(instance: "work", appSupport: support))
        try write(InstanceDisk.initramfsURL(instance: "work", appSupport: support))
        InstanceDisk.remove(instance: "work", appSupport: support)
        XCTAssertFalse(InstanceDisk.hasOwnKernel(instance: "work", appSupport: support))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceDisk.url(instance: "work", appSupport: support).path))
    }

    /// Two instances never share a kernel file.
    func testKernelsAreKeyedPerInstance() {
        XCTAssertNotEqual(InstanceDisk.kernelURL(instance: "a", appSupport: support),
                          InstanceDisk.kernelURL(instance: "b", appSupport: support))
    }

    /// Format 2 carries the kernel; format 1 did not, so it still needs a
    /// distro present and `install` still says so.
    func testShipmentFormatIsTwo() {
        XCTAssertEqual(Shipment.formatVersion, 2)
    }
}
