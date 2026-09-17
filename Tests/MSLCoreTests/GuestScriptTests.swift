import XCTest
@testable import MSLCore

/// Runs the shell that `DesktopEntryScanner` sends into the guest against a
/// fixture tree on the host.
///
/// The guest is the one part of the icon pipeline a unit test cannot reach,
/// and a broken script there fails silently - `find` and `grep` both exit
/// non-zero with no output when they match nothing, which is
/// indistinguishable from "this instance has no icons". Running the real
/// generated script locally at least proves the shell itself is correct.
final class GuestScriptTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-icons-\(UUID().uuidString)")
        let files = [
            "icons/hicolor/48x48/apps/gimp.png",
            "icons/hicolor/512x512/apps/gimp.png",
            "icons/hicolor/scalable/apps/gimp.svg",
            "icons/hicolor/48x48/apps/gimp-tool.png",     // must NOT match "gimp"
            "icons/hicolor/64x64/apps/org.kde.krita.png",  // dotted name
            "pixmaps/xterm.xpm",
            "icons/hicolor/48x48/apps/unrelated.png",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testIconCandidateScriptMatchesWholeBasenames() throws {
        let script = DesktopEntryScanner.iconCandidateScript(
            names: ["gimp", "org.kde.krita", "xterm"],
            roots: [root.appendingPathComponent("icons").path,
                    root.appendingPathComponent("pixmaps").path])
        let lines = try run(script).split(separator: "\n").map(String.init)

        XCTAssertTrue(lines.contains { $0.hasSuffix("/scalable/apps/gimp.svg") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("/512x512/apps/gimp.png") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("/org.kde.krita.png") }, "dotted icon names must match")
        XCTAssertTrue(lines.contains { $0.hasSuffix("/xterm.xpm") })
        // `/gimp.` must not match `gimp-tool.png`, or every app would drag
        // in its toolbar icons.
        XCTAssertFalse(lines.contains { $0.contains("gimp-tool") })
        XCTAssertFalse(lines.contains { $0.contains("unrelated") })
    }

    /// Icon names come out of guest files. They are sent base64-encoded
    /// precisely so a name like `$(reboot)` is data, never shell.
    func testHostileIconNameIsInert() throws {
        let marker = root.appendingPathComponent("PWNED").path
        let script = DesktopEntryScanner.iconCandidateScript(
            names: ["$(touch \(marker))", "`touch \(marker)`", "a;touch \(marker)", "gimp"],
            roots: [root.appendingPathComponent("icons").path])
        let output = try run(script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "name must not be executed")
        XCTAssertTrue(output.contains("gimp.svg"), "the legitimate name still resolves")
    }

    func testFetchFilesScriptRoundTripsBytesAndHonoursCap() throws {
        let small = root.appendingPathComponent("icons/hicolor/scalable/apps/gimp.svg")
        let big = root.appendingPathComponent("big.png")
        try Data(repeating: 0x41, count: 5000).write(to: big)

        let output = try run(DesktopEntryScanner.fetchFilesScript(
            paths: [small.path, big.path], maxBytes: 1000))
        let files = DesktopEntryScanner.parseFiles(output)

        XCTAssertEqual(files[small.path], Data("x".utf8))
        XCTAssertNil(files[big.path], "a file over the cap must not be transferred at all")
    }

    /// A path with a space is ordinary on Linux and must survive the
    /// `while read` loop intact.
    func testFetchFilesScriptHandlesSpacesInPaths() throws {
        let spaced = root.appendingPathComponent("my icons/some app.png")
        try FileManager.default.createDirectory(
            at: spaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: spaced)

        let output = try run(DesktopEntryScanner.fetchFilesScript(paths: [spaced.path], maxBytes: 10_000))
        XCTAssertEqual(DesktopEntryScanner.parseFiles(output)[spaced.path], Data("hello".utf8))
    }
}
