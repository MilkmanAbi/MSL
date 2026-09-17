import XCTest
@testable import MSLCore

final class LinuxUserSetupTests: XCTestCase {
    // MARK: - Rules

    func testUsernameRules() {
        for good in ["abi", "_svc", "a-b_c9", "x", String(repeating: "a", count: 32)] {
            XCTAssertNil(LinuxUserSetup.problem(with: good), good)
        }
        XCTAssertEqual(LinuxUserSetup.problem(with: ""), .empty)
        XCTAssertEqual(LinuxUserSetup.problem(with: String(repeating: "a", count: 33)), .tooLong)
        XCTAssertEqual(LinuxUserSetup.problem(with: "Abi"), .badFirstCharacter)
        XCTAssertEqual(LinuxUserSetup.problem(with: "9lives"), .badFirstCharacter)
        XCTAssertEqual(LinuxUserSetup.problem(with: "-x"), .badFirstCharacter)
        XCTAssertEqual(LinuxUserSetup.problem(with: "a b"), .badCharacter(" "))
        XCTAssertEqual(LinuxUserSetup.problem(with: "abiS"), .badCharacter("S"))
        XCTAssertEqual(LinuxUserSetup.problem(with: "é"), .badFirstCharacter)
        XCTAssertEqual(LinuxUserSetup.problem(with: "../x"), .badFirstCharacter)
    }

    /// Existing system accounts - including the image's own `msl` - would
    /// turn "create my user" into "reset someone else's password".
    func testSystemNamesAreRefused() {
        for name in ["root", "msl", "nobody", "sudo", "wheel", "daemon"] {
            XCTAssertEqual(LinuxUserSetup.problem(with: name), .reserved, name)
        }
    }

    func testPasswordRules() {
        XCTAssertNotNil(LinuxUserSetup.passwordProblem("", confirmation: ""))
        XCTAssertNotNil(LinuxUserSetup.passwordProblem("one", confirmation: "two"))
        XCTAssertNotNil(LinuxUserSetup.passwordProblem("a\nb", confirmation: "a\nb"))
        XCTAssertNil(LinuxUserSetup.passwordProblem("correct horse: 'battery' $taple", confirmation: "correct horse: 'battery' $taple"))
    }

    // MARK: - The script

    /// The whole point of the change: sudo asks for a password.
    func testSudoNeedsAPassword() {
        let script = LinuxUserSetup.script(username: "abi", password: "pw")
        XCTAssertFalse(script.contains("NOPASSWD"))
        XCTAssertTrue(script.contains("ALL=(ALL:ALL) ALL"))
        XCTAssertTrue(script.contains("usermod -aG"), "joins the admin group")
        XCTAssertTrue(script.contains("visudo -cf"), "checks sudoers before it goes live")
        XCTAssertTrue(script.contains(#"rm -f "/etc/sudoers.d/$user""#), "drops the old passwordless file")
    }

    /// Runs the script through a strict POSIX shell's parser - Alpine's is
    /// busybox ash, and dash is the closest thing on a Mac.
    func testScriptIsValidPOSIXShell() throws {
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"
        let script = LinuxUserSetup.script(username: "abi", password: #"it's "$HOME" `id`; rm -rf / \ done"#)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n", "-c", script]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    /// A password full of shell syntax must reach chpasswd exactly as typed.
    func testPasswordReachesChpasswdVerbatim() throws {
        let password = #"it's "$HOME" `id`; $(whoami) \ & done"#
        let script = LinuxUserSetup.script(username: "abi", password: password)
        // Everything up to the credentials assignment, then print it.
        let prelude = script.components(separatedBy: "\n").prefix { !$0.hasPrefix("if id") }.joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", prelude + "\nprintf '%s' \"$credentials\""]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "abi:" + password)
    }

    // MARK: - Outcomes

    func testOutcomes() {
        XCTAssertEqual(LinuxUserSetup.outcome(exitCode: 0, output: "created abi", username: "abi"), .created(warning: nil))
        XCTAssertEqual(LinuxUserSetup.outcome(exitCode: 3, output: "", username: "abi"), .alreadyExists)
        if case .created(let warning) = LinuxUserSetup.outcome(exitCode: 4, output: "", username: "abi") {
            XCTAssertTrue(warning?.contains("sudo isn't installed") ?? false)
        } else { XCTFail("no sudo still means the account exists") }
        if case .created(let warning) = LinuxUserSetup.outcome(exitCode: 12, output: "couldn't add abi to the wheel group", username: "abi") {
            XCTAssertTrue(warning?.contains("wheel") ?? false)
        } else { XCTFail("a group failure happens after the account exists") }
        XCTAssertEqual(LinuxUserSetup.outcome(exitCode: 10, output: "x\ncouldn't create the account\n", username: "abi"),
                       .failed("couldn't create the account"))
    }
}
