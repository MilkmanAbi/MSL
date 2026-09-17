import XCTest
@testable import MSLCore

final class TerminalLaunchTests: XCTestCase {
    /// What the shell actually splits `command` into - printed one word per
    /// line by the shell itself, so this checks real parsing, not a guess.
    private func words(of command: String, shell: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "printf '%s\\n' \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testThePathThroughApplicationSupportStaysOneWord() throws {
        let tool = "/Users/someone/Library/Application Support/MSL/bin/msl"
        let command = TerminalLaunch.shellCommand(tool: tool, instance: "default")
        for shell in ["/bin/zsh", "/bin/sh"] {
            XCTAssertEqual(try words(of: command, shell: shell), [tool, "default"], shell)
        }
    }

    func testAwkwardCharactersSurviveBothLayers() throws {
        let tool = #"/tmp/it's "quoted" \ $HOME `x`/msl"#
        let command = TerminalLaunch.shellCommand(tool: tool, instance: "my box")
        XCTAssertEqual(try words(of: command, shell: "/bin/zsh"), [tool, "my box"])
    }

    func testTheAppleScriptCompilesAndCarriesTheQuotedCommand() throws {
        let tool = "/Users/someone/Library/Application Support/MSL/bin/msl"
        let script = TerminalLaunch.appleScript(tool: tool, instance: "default")
        XCTAssertTrue(script.contains(#"do script "'/Users/someone/Library/Application Support/MSL/bin/msl' 'default'""#))

        // osacompile parses the script without running it - no Terminal
        // window opens.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("msl-terminal-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: out) }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compile.arguments = ["-o", out.path, "-e", script]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
    }
}
