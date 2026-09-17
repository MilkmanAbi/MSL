import XCTest
@testable import MSLCore

/// `msl` forwards a command line into the guest, so it must stop looking
/// for its own options at the point the guest's command begins.
final class ArgumentSplitterTests: XCTestCase {

    private let commands: Set<String> = [
        "apps", "doctor", "gui", "gui-native", "help", "hibernate", "install",
        "install-tools", "instances", "list", "ls", "new", "power-test",
        "remove", "resume", "snapshot", "status", "storage", "suspend",
    ]

    private func split(_ argv: [String]) -> ArgumentSplitter.Options {
        ArgumentSplitter.split(argv, knownCommands: commands)
    }

    // MARK: - The bug

    /// `echo -d /tmp` is the guest's command. Previously `-d` was read as
    /// `--distro` and the whole invocation died with "unknown distro
    /// '/tmp'".
    func testGuestCommandKeepsItsOwnFlags() {
        let options = split(["work", "echo", "-d", "/tmp"])
        XCTAssertNil(options.distro)
        XCTAssertEqual(options.remainder, ["work", "echo", "-d", "/tmp"])
    }

    /// The quieter version of the same bug: the flag is silently removed
    /// from the guest's command *and* changes which user the session runs
    /// as, so `docker run` loses its `-u` and the shell becomes user
    /// "1000".
    func testGuestCommandKeepsUserFlag() {
        let options = split(["work", "docker", "run", "-u", "1000", "ubuntu"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["work", "docker", "run", "-u", "1000", "ubuntu"])
    }

    func testDashDashTailIsVerbatim() {
        let options = split(["--", "grep", "-u", "pattern", "file"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["--", "grep", "-u", "pattern", "file"])
    }

    // MARK: - Documented spellings that must keep working

    /// From the usage text: `msl <instance> -u msl`.
    func testOptionsAfterInstanceNameStillWork() {
        let options = split(["work", "-u", "msl"])
        XCTAssertEqual(options.user, "msl")
        XCTAssertEqual(options.remainder, ["work"])
    }

    func testOptionsAfterInstanceNameThenCommand() {
        let options = split(["work", "-u", "msl", "ls", "-la"])
        XCTAssertEqual(options.user, "msl")
        XCTAssertEqual(options.remainder, ["work", "ls", "-la"])
    }

    func testOptionsBeforeInstanceName() {
        let options = split(["-d", "fedora", "-u", "msl", "work", "ls"])
        XCTAssertEqual(options.distro, "fedora")
        XCTAssertEqual(options.user, "msl")
        XCTAssertEqual(options.remainder, ["work", "ls"])
    }

    /// From the usage text: `msl install <distro> [--manifest <url>]` -
    /// after the distro name, and `install` takes no guest command.
    func testManifestAfterDistroName() {
        let options = split(["install", "debian", "--manifest", "file:///tmp/m.json"])
        XCTAssertEqual(options.manifest, "file:///tmp/m.json")
        XCTAssertEqual(options.remainder, ["install", "debian"])
    }

    func testFixedAritySubcommandsAreUnaffected() {
        XCTAssertEqual(split(["storage", "work", "fixed", "64G"]).remainder,
                       ["storage", "work", "fixed", "64G"])
        XCTAssertEqual(split(["snapshot", "save", "work", "before-upgrade"]).remainder,
                       ["snapshot", "save", "work", "before-upgrade"])
        XCTAssertEqual(split(["doctor", "--fix"]).remainder, ["doctor", "--fix"])
    }

    /// `gui` takes an instance and then an app command line for the guest.
    func testGuiKeepsAppFlags() {
        let options = split(["gui", "work", "firefox", "-u", "profile"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["gui", "work", "firefox", "-u", "profile"])
    }

    func testGuiStillTakesItsOwnOptions() {
        let options = split(["gui", "work", "-u", "msl", "firefox"])
        XCTAssertEqual(options.user, "msl")
        XCTAssertEqual(options.remainder, ["gui", "work", "firefox"])
    }

    // MARK: - Edges

    func testEmptyAndBareName() {
        XCTAssertEqual(split([]).remainder, [])
        XCTAssertEqual(split(["work"]).remainder, ["work"])
    }

    /// A dangling option is left in place so the command's own usage error
    /// can complain about it, rather than vanishing.
    func testDanglingOptionIsPreserved() {
        let options = split(["work", "-u"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["work", "-u"])
    }

    /// An instance whose name matches a distro is ordinary here - the
    /// distro implication happens later, in `resolvedDistro`.
    func testDistroNamedInstance() {
        let options = split(["fedora", "uname", "-a"])
        XCTAssertNil(options.distro)
        XCTAssertEqual(options.remainder, ["fedora", "uname", "-a"])
    }
}
