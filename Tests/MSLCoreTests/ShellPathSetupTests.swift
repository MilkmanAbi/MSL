import XCTest
@testable import MSLCore

final class ShellPathSetupTests: XCTestCase {
    private var home: URL!
    private var appSupport: URL { home.appendingPathComponent("Library/Application Support/MSL") }

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("msl-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func testInstallsIntoZshAndBashOnceAndKeepsUserLines() throws {
        try "export PATH=\"/opt/homebrew/bin:$PATH\"".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let first = ShellPathSetup.install(home: home, appSupport: appSupport)
        XCTAssertEqual(Set(first.map(\.lastPathComponent)), [".zprofile", ".zshrc", ".bash_profile"])
        XCTAssertTrue(read(".zprofile").hasPrefix("export PATH=\"/opt/homebrew/bin:$PATH\"\n\n# >>> MSL >>>"))
        XCTAssertTrue(read(".bash_profile").contains(#"export PATH="$HOME/Library/Application Support/MSL/cli:$PATH""#))
        // Every later launch: nothing to do.
        XCTAssertTrue(ShellPathSetup.install(home: home, appSupport: appSupport).isEmpty)
        XCTAssertEqual(read(".zprofile").components(separatedBy: ShellPathSetup.beginMarker).count, 2)
        XCTAssertTrue(ShellPathSetup.isInstalled(home: home, appSupport: appSupport))
        let link = appSupport.appendingPathComponent("cli/msl").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "../bin/msl")
    }

    /// Creating .bash_profile next to .profile would stop bash reading .profile.
    func testUsesTheBashFileBashAlreadyReads() throws {
        try "# mine\n".write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        ShellPathSetup.install(home: home, appSupport: appSupport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
        XCTAssertTrue(read(".profile").contains(ShellPathSetup.beginMarker))
        XCTAssertTrue(ShellPathSetup.refreshOpenTerminalsScript(home: home).contains("source ~/.profile"))
    }

    /// The block works in a real shell, and sourcing it twice doesn't grow PATH.
    func testTheBlockPutsMslOnPathInZshAndBash() throws {
        let tool = appSupport.appendingPathComponent("bin/msl")
        try "#!/bin/sh\necho hello-from-msl\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        ShellPathSetup.install(home: home, appSupport: appSupport)
        for (shell, file) in [("/bin/zsh", ".zprofile"), ("/bin/bash", ".bash_profile")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", "source \"$HOME/\(file)\"; source \"$HOME/\(file)\"; msl; echo \"$PATH\" | tr ':' '\\n' | grep -c 'MSL/cli'"]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(output, "hello-from-msl\n1\n", shell)
        }
    }

    func testUninstallRemovesOnlyMslLines() throws {
        try "alias ll='ls -l'\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        ShellPathSetup.install(home: home, appSupport: appSupport)
        let edited = ShellPathSetup.uninstall(home: home, appSupport: appSupport)
        XCTAssertEqual(edited.count, 3)
        XCTAssertFalse(read(".zshrc").contains("MSL"))
        XCTAssertTrue(read(".zshrc").hasPrefix("alias ll='ls -l'\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("cli").path))
        // .zprofile and .bash_profile held only MSL's block, so they go.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
    }
}
