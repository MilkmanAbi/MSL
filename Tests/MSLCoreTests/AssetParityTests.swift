import XCTest
@testable import MSLCore

/// The melon exists twice on disk - once for MSLApp, once for MSLCore - and
/// the only reason is that SwiftPM copies a symlinked resource into the
/// bundle as a symlink, whose relative target does not resolve from where it
/// lands. Two files that have to be updated together are one file that
/// silently won't be, so this is the thing that notices.
final class AssetParityTests: XCTestCase {
    /// Walks up from this test's own path rather than trusting the working
    /// directory, which `swift test` does not promise.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)            // .../Tests/MSLCoreTests/AssetParityTests.swift
            .deletingLastPathComponent()           // .../Tests/MSLCoreTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
    }

    /// `Assets/` is the source of truth; everything else is a copy of it.
    func testShippedArtworkMatchesAssets() throws {
        let copies: [(asset: String, shipped: [String])] = [
            ("App_Logo.png", ["Sources/MSLApp/Resources/App_Logo.png",
                              "Sources/MSLCore/Resources/App_Logo.png"]),
            ("Mascot.png", ["Sources/MSLApp/Resources/Mascot.png"]),
            ("Abi_Logo-Light.png", ["Sources/MSLApp/Resources/Abi_Logo-Light.png"]),
            ("Abi_Logo-Dark.png", ["Sources/MSLApp/Resources/Abi_Logo-Dark.png"]),
            ("License.md", ["Sources/MSLApp/Resources/License.md"]),
        ]

        for (asset, shipped) in copies {
            let source = repositoryRoot.appendingPathComponent("Assets/\(asset)")
            let original = try Data(contentsOf: source)
            for path in shipped {
                let url = repositoryRoot.appendingPathComponent(path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(path)")
                XCTAssertEqual(try Data(contentsOf: url), original,
                               "\(path) has drifted from Assets/\(asset) - run Scripts/sync-assets.sh")
            }
        }
    }

    /// The melon has to be reachable through `MSLAsset` at runtime - the
    /// part a symlink broke silently, and the part `Bundle.module` would
    /// have crashed on rather than reported.
    func testMelonIsReachableFromMSLCoreBundle() throws {
        let url = try XCTUnwrap(MSLAsset.url("App_Logo", extension: "png"),
                                "MSLAsset could not find App_Logo.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "App_Logo.png is in the bundle but does not resolve (a dangling symlink?)")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 1000)
    }

    /// The fallback has to survive the whole path, not just load: a Linux app
    /// with no icon of its own gets this run through `iconutil`, and an
    /// `.icns` that fails to generate leaves the bundle with the blank
    /// generic tile the fallback exists to avoid.
    func testMelonFallbackProducesAValidICNS() throws {
        let melon = try XCTUnwrap(LinuxAppBundle.melonIcon, "melon fallback icon did not load")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-melon-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertTrue(LinuxAppBundle.writeICNS(melon, to: destination))

        let data = try Data(contentsOf: destination)
        XCTAssertGreaterThan(data.count, 1000)
        // "icns" magic, so this is a real icon file and not an empty one
        // iconutil happened to exit 0 on.
        XCTAssertEqual(Array(data.prefix(4)), Array("icns".utf8))
    }
}
