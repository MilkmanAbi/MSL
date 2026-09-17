import XCTest
@testable import MSLCore

final class CommandLineLinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("msl-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func executable(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testMissing() {
        XCTAssertEqual(CommandLineLink.status(at: directory.appendingPathComponent("msl").path), .missing)
    }

    func testReady() throws {
        let target = try executable("real-msl")
        let link = directory.appendingPathComponent("msl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(CommandLineLink.status(at: link.path), .ready(target: target.path))
    }

    /// Exactly what the relocated package left behind: a link into an app
    /// that was never installed.
    func testBrokenLinkIsNotReady() throws {
        let link = directory.appendingPathComponent("msl")
        let gone = directory.appendingPathComponent("Applications/MSL.app/Contents/MacOS/msl").path
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: gone)
        XCTAssertEqual(CommandLineLink.status(at: link.path), .broken(target: gone))
    }

    func testSomethingElseInTheWayIsLeftAlone() throws {
        let file = directory.appendingPathComponent("msl")
        try "not a program".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandLineLink.status(at: file.path), .occupied)
    }

    func testInstallCommandQuotesPathsWithSpaces() {
        let command = CommandLineLink.installCommand(
            target: "/Users/me/Library/Application Support/MSL/bin/msl", at: "/usr/local/bin/msl")
        XCTAssertEqual(command,
                       "mkdir -p '/usr/local/bin' && ln -sfn '/Users/me/Library/Application Support/MSL/bin/msl' '/usr/local/bin/msl'")
    }
}
