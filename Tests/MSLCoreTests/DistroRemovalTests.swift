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

    func testTheInstallationsFilesAreTheImageAndItsRepairBackup() {
        let root = URL(fileURLWithPath: "/tmp/msl-test-root")
        XCTAssertEqual(DistroInstallation.files(for: .debian, in: root).map(\.lastPathComponent),
                       ["rootfs-debian.img", "rootfs-debian.img.pre-repair"])
        XCTAssertEqual(DistroInstallation.files(for: .alpine, in: root).map(\.lastPathComponent),
                       ["rootfs.img", "rootfs.img.pre-repair"])
    }

    func testForgettingADefaultUserLeavesTheOthers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("msl-users-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let registry = DefaultUserRegistry(path: path)
        try registry.setDefaultUser("abi", for: .debian)
        try registry.setDefaultUser("abi2", for: .arch)
        try registry.forgetDefaultUser(for: .debian)
        XCTAssertNil(registry.defaultUser(for: .debian))
        XCTAssertEqual(registry.defaultUser(for: .arch), "abi2")
        try registry.forgetDefaultUser(for: .fedora)   // never set - harmless
    }
}
