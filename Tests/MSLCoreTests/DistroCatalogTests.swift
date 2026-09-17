import XCTest
@testable import MSLCore

final class DistroCatalogTests: XCTestCase {
    private func artifact(_ file: String, size: UInt64 = 1) -> DistroInstaller.Artifact {
        .init(version: "2026-09-14", url: "https://example.com/msl-images/\(file)", sha256: "x", size: size)
    }

    func testReleasesComeFromTheFileNames() {
        let cases: [(String, String, String)] = [
            ("debian", "msl-debian-13-arm64.img.xz", "13"),
            ("alpine", "msl-alpine-3.24-arm64.img.xz", "3.24"),
            ("arch", "msl-arch-rolling-arm64.img.xz", "rolling"),
            ("centos", "msl-centos-stream10-arm64.img.xz", "10"),
            ("opensuse", "msl-opensuse-leap16.0-arm64.img.xz", "16.0"),
            ("nix", "msl-nix-debian13-arm64.img.xz", "on Debian 13"),
            ("ubuntu", "msl-ubuntu-26.04-arm64.img.xz", "26.04"),
        ]
        for (distro, file, release) in cases {
            XCTAssertEqual(DistroCatalog.release(fromURL: "https://x/\(file)", distro: distro), release, file)
        }
    }

    func testEntriesFollowMSLsDistroOrder() {
        let manifest = DistroInstaller.Manifest(
            kernel: artifact("k"), initramfs: artifact("i"),
            distros: ["ubuntu": artifact("msl-ubuntu-26.04-arm64.img.xz"),
                      "alpine": artifact("msl-alpine-3.24-arm64.img.xz", size: 62_229_588),
                      "debian": artifact("msl-debian-13-arm64.img.xz")])
        let entries = DistroCatalog.entries(from: manifest)
        XCTAssertEqual(entries.map(\.distro), ["alpine", "debian", "ubuntu"])
        XCTAssertEqual(entries[0], DistroCatalog.Entry(distro: "alpine", name: "Alpine Linux", release: "3.24", downloadBytes: 62_229_588))
    }
}
