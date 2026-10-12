import XCTest
@testable import MSLCore

final class DistroRemovalTests: XCTestCase {
    func testThePhraseNamesTheDistro() {
        XCTAssertEqual(DistroRemovalConfirmation.phrase(distroName: "Debian"), "Delete all my Debian instances")
    }

    func testTheExactPhraseConfirmsWhateverTheCaseOrSpacing() {
        XCTAssertTrue(DistroRemovalConfirmation.matches("Delete all my Debian instances", distroName: "Debian"))
        XCTAssertTrue(DistroRemovalConfirmation.matches("  delete ALL my debian instances\n", distroName: "Debian"))
    }

    func testAnythingElseDoesNot() {
        XCTAssertFalse(DistroRemovalConfirmation.matches("", distroName: "Debian"))
        XCTAssertFalse(DistroRemovalConfirmation.matches("Meow", distroName: "Debian"))
        XCTAssertFalse(DistroRemovalConfirmation.matches("Delete all my Ubuntu instances", distroName: "Debian"),
                       "the phrase for another distro must not delete this one")
        XCTAssertFalse(DistroRemovalConfirmation.matches("Delete all my Debian instance", distroName: "Debian"))
        XCTAssertFalse(DistroRemovalConfirmation.matches("Delete all Debian instances", distroName: "Debian"))
    }

    func testTheRequestRoundTripsOverTheWire() {
        for distro in GuestDistro.allCases {
            let line = String(decoding: DaemonProtocol.ControlRequest.removeDistro(distro: distro).encode(), as: UTF8.self)
            XCTAssertEqual(line, "REMOVE_DISTRO \(distro.rawValue)\n")
            guard case .removeDistro(let parsed)? = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("\(line) didn't parse back")
            }
            XCTAssertEqual(parsed, distro)
        }
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("REMOVE_DISTRO notadistro"))
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("REMOVE_DISTRO"))
    }

    /// Removing an instance frees its disk when it was the last one, unless
    /// the client asked to keep it - both have to survive the wire.
    func testInstanceRemovalCarriesKeepDisk() {
        for keep in [false, true] {
            let line = String(decoding: DaemonProtocol.ControlRequest.remove(instance: "box", keepDisk: keep).encode(), as: UTF8.self)
            XCTAssertEqual(line, keep ? "REMOVE box KEEP_DISK\n" : "REMOVE box\n")
            guard case .remove(let name, let parsedKeep)? = DaemonProtocol.ControlRequest.parse(line) else {
                return XCTFail("\(line) didn't parse back")
            }
            XCTAssertEqual(name, "box")
            XCTAssertEqual(parsedKeep, keep)
        }
        XCTAssertNil(DaemonProtocol.ControlRequest.parse("REMOVE box SOMETHING"))
    }

    func testDeletingAnInstallationNeverStartsAVM() {
        XCTAssertNil(DaemonProtocol.ControlRequest.removeDistro(distro: .debian).startsInstance)
    }

    /// The image, the repair backup, and the record of what was downloaded.
    ///
    /// The last one matters: `msl install` skips a base whose recorded
    /// checksum already matches, so a marker left behind by a removal would
    /// make the next install believe the download was still there and skip
    /// fetching it.
    func testTheInstallationsFilesAreTheImageItsBackupAndItsDownloadRecord() {
        let root = URL(fileURLWithPath: "/tmp/msl-test-root")
        XCTAssertEqual(DistroInstallation.files(for: .debian, in: root).map(\.lastPathComponent),
                       ["rootfs-debian.img", "rootfs-debian.img.pre-repair", ".rootfs-debian.img.installed"])
        XCTAssertEqual(DistroInstallation.files(for: .alpine, in: root).map(\.lastPathComponent),
                       ["rootfs.img", "rootfs.img.pre-repair", ".rootfs.img.installed"])
    }

    func testForgettingADefaultUserLeavesTheOthers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("msl-users-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let registry = DefaultUserRegistry(path: path)
        try registry.setDefaultUser("abi", forInstance: "work")
        try registry.setDefaultUser("abi2", forInstance: "play")
        try registry.forgetDefaultUser(forInstance: "work")
        XCTAssertNil(registry.defaultUser(forInstance: "work"))
        XCTAssertEqual(registry.defaultUser(forInstance: "play"), "abi2")
        try registry.forgetDefaultUser(forInstance: "ghost")   // never set - harmless
    }
}
