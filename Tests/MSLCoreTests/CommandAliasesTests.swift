import XCTest
@testable import MSLCore

final class CommandAliasesTests: XCTestCase {
    /// The bug this exists for: `msl start Milk` registered an instance
    /// called "start" and ran `Milk` as a command inside it.
    func testStartBecomesResume() {
        let resolved = CommandAliases.resolve(["start", "Milk"])
        XCTAssertEqual(resolved.arguments, ["resume", "Milk"])
        XCTAssertNil(resolved.note, "resume means what it says")
    }

    func testStopExplainsItself() {
        let resolved = CommandAliases.resolve(["stop", "Milk"])
        XCTAssertEqual(resolved.arguments, ["hibernate", "Milk"])
        XCTAssertEqual(resolved.note?.contains("state saved"), true)
    }

    /// `run` is a real command now, so it is left exactly alone - including
    /// on its own, where dropping it used to leave plain `msl` and register
    /// an instance called "run".
    func testRunIsACommandNotAnAlias() {
        XCTAssertEqual(CommandAliases.resolve(["run", "Milk", "ls", "-la"]).arguments,
                       ["run", "Milk", "ls", "-la"])
        XCTAssertEqual(CommandAliases.resolve(["run"]).arguments, ["run"])
    }

    /// The words that mean the same thing point at it.
    func testRunSynonyms() {
        for word in ["exec", "shell", "enter", "attach", "open"] {
            XCTAssertEqual(CommandAliases.resolve([word, "Milk"]).arguments, ["run", "Milk"],
                           "\(word) should mean run")
        }
    }

    /// An instance really called `run` keeps working: nothing rewrites it,
    /// and `main.swift`'s `run` case prefers a registered instance of that
    /// name over the last-used one.
    func testExistingInstanceWins() {
        let resolved = CommandAliases.resolve(["run", "ls"], isTaken: { $0 == "run" })
        XCTAssertEqual(resolved.arguments, ["run", "ls"])
    }

    /// `msl distros` is the list of Linux distributions, not `msl images`,
    /// which is *custom* images.
    func testDistroWordsMeanDistros() {
        XCTAssertEqual(CommandAliases.resolve(["distributions"]).arguments, ["distros"])
        XCTAssertEqual(CommandAliases.resolve(["distro"]).arguments, ["distros"])
    }

    func testFlagsAndRealCommandsAreUntouched() {
        XCTAssertEqual(CommandAliases.resolve(["--help"]).arguments, ["--help"])
        XCTAssertEqual(CommandAliases.resolve(["instances"]).arguments, ["instances"])
        XCTAssertEqual(CommandAliases.resolve([]).arguments, [])
    }

    /// Every alias must name a command that exists, or it turns one confusing
    /// failure into another.
    ///
    /// Checked against `CLICommands` - the list `main.swift` actually
    /// dispatches on - rather than a set written out here, which went stale
    /// the moment `run` and `distros` became real commands.
    func testEveryTargetIsRealOrEmpty() {
        for (word, target) in CommandAliases.table where !target.isEmpty {
            XCTAssertTrue(CLICommands.all.contains(target), "\(word) points at '\(target)'")
        }
    }
}
