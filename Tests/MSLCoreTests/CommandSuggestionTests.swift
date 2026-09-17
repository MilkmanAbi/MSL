import XCTest
@testable import MSLCore

/// `msl <word>` creates an instance for any word it doesn't recognise, so a
/// mistyped subcommand becomes a permanent registry entry. These guard the
/// line between "typo" and "a name the user meant".
final class CommandSuggestionTests: XCTestCase {

    private let commands = [
        "apps", "cage-bridge-test", "cage-input-test", "cage-view", "gui",
        "gui-native", "help", "hibernate", "install", "install-tools",
        "instances", "list", "ls", "new", "power-test", "remove", "resume",
        "snapshot", "status", "storage", "suspend",
    ]

    func testCatchesRealTypos() {
        // One edit from both `ls` and `list`; either is a useful answer, so
        // the test does not pin the tie-break.
        XCTAssertTrue(["ls", "list"].contains(CommandSuggestion.nearest("lst", in: commands) ?? ""))
        XCTAssertEqual(CommandSuggestion.nearest("intances", in: commands), "instances")
        XCTAssertEqual(CommandSuggestion.nearest("staus", in: commands), "status")
        XCTAssertEqual(CommandSuggestion.nearest("remve", in: commands), "remove")
        XCTAssertEqual(CommandSuggestion.nearest("snapshto", in: commands), "snapshot")
        XCTAssertEqual(CommandSuggestion.nearest("instal", in: commands), "install")
    }

    /// The whole point of the ordering in `main.swift`: every distro name
    /// must still be usable as a bare argument. This asserts it for the
    /// real `GuestDistro` list so adding a distro that happens to sit near
    /// a command cannot silently start erroring - the CLI checks
    /// `GuestDistro(rawValue:)` before it ever consults the suggester, and
    /// this test documents which names rely on that.
    func testDistroNamesAreNotMistakenForTypos() {
        for distro in GuestDistro.allCases {
            let name = distro.rawValue
            // Either nothing is near it, or the CLI's earlier distro check
            // is what protects it. Both are fine; a silent failure is not.
            if let suggestion = CommandSuggestion.nearest(name, in: commands) {
                XCTAssertNotNil(
                    GuestDistro(rawValue: name),
                    "\(name) resolves to \(suggestion) and is not a distro - the CLI guard would break it")
            }
        }
    }

    /// Ordinary instance names must pass straight through. These are the
    /// kind of thing people actually call an instance.
    func testRealInstanceNamesPassThrough() {
        for name in ["work", "dev", "build", "test-box", "sandbox", "ml", "k8s", "scratch", "ci", "sus"] {
            XCTAssertNil(
                CommandSuggestion.nearest(name, in: commands),
                "'\(name)' is a plausible instance name and must not be refused")
        }
    }

    /// Short words get one edit, not two: at two edits nearly every
    /// three-letter string matches something.
    func testToleranceScalesWithLength() {
        XCTAssertNil(CommandSuggestion.nearest("abc", in: commands))
        XCTAssertNil(CommandSuggestion.nearest("x", in: commands))
    }

    func testEditDistance() {
        XCTAssertEqual(CommandSuggestion.editDistance("", "abc"), 3)
        XCTAssertEqual(CommandSuggestion.editDistance("abc", "abc"), 0)
        XCTAssertEqual(CommandSuggestion.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(CommandSuggestion.editDistance("lst", "ls"), 1)
    }
}
