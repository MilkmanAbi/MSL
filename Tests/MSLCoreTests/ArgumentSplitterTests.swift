import XCTest
@testable import MSLCore

/// `msl` forwards a command line into the guest, so it must stop looking
/// for its own options at the point the guest's command begins.
final class ArgumentSplitterTests: XCTestCase {

    private let commands: Set<String> = [
        "apps", "doctor", "gui", "gui-native", "help", "hibernate", "install",
        "install-tools", "instances", "list", "ls", "new", "power-test",
        "remove", "resume", "run", "snapshot", "status", "storage", "suspend",
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

    // MARK: - `msl run <instance> [command...]`

    /// `run` has to be a verbatim-tail command, like `gui`. Listed as an
    /// ordinary fixed-arity one its options would be scanned anywhere
    /// inside it, and the guest's `docker run -u 1000` would lose its `-u`
    /// to `msl` - the same bug this whole file exists for.
    func testRunKeepsTheGuestsFlags() {
        let options = split(["run", "work", "docker", "run", "-u", "1000", "ubuntu"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder,
                       ["run", "work", "docker", "run", "-u", "1000", "ubuntu"])
    }

    /// An option between the instance name and the guest's command is still
    /// `msl`'s - that is the documented `msl <instance> -u root` form.
    func testRunTakesOptionsAfterTheInstanceName() {
        let options = split(["run", "work", "-u", "root"])
        XCTAssertEqual(options.user, "root")
        XCTAssertEqual(options.remainder, ["run", "work"])
    }

    func testRunTakesOptionsAfterTheNameThenHandsOver() {
        let options = split(["run", "work", "-u", "root", "echo", "-u", "me"])
        XCTAssertEqual(options.user, "root")
        XCTAssertEqual(options.remainder, ["run", "work", "echo", "-u", "me"])
    }

    /// `msl run` on its own survives the splitter intact, so the dispatch
    /// can resolve it to the last-used instance.
    func testBareRunSurvives() {
        let options = split(["run"])
        XCTAssertEqual(options.remainder, ["run"])
    }

    /// `msl run -u root work` and `msl run work -u root` are the same
    /// request. People coming from WSL put flags first, and the old CLI
    /// accepted it - `run` was a bare word then, so `-u root` was consumed
    /// before the alias dropped it. Making `run` a command word took two
    /// name slots and broke the form; this is the test that caught it.
    func testRunTakesOptionsBeforeTheInstanceName() {
        let options = split(["run", "-u", "root", "work"])
        XCTAssertEqual(options.user, "root")
        XCTAssertEqual(options.remainder, ["run", "work"])
    }

    func testRunTakesOptionsBeforeTheNameAndStillHandsTheTailOver() {
        let options = split(["run", "-d", "debian", "work", "echo", "-u", "me"])
        XCTAssertEqual(options.distro, "debian")
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["run", "work", "echo", "-u", "me"])
    }

    /// The same rule for `gui`, which has always taken an instance name.
    func testGuiTakesOptionsBeforeTheInstanceName() {
        let options = split(["gui", "-u", "root", "work", "xterm"])
        XCTAssertEqual(options.user, "root")
        XCTAssertEqual(options.remainder, ["gui", "work", "xterm"])
    }

    /// A bare instance name is not a command word, so nothing is consumed
    /// "before the name" - `token` already is the name.
    func testBareNameIsUnaffected() {
        let options = split(["work", "echo", "-u", "me"])
        XCTAssertNil(options.user)
        XCTAssertEqual(options.remainder, ["work", "echo", "-u", "me"])
    }

    func testOptionsBeforeRun() {
        let options = split(["-u", "root", "run", "work"])
        XCTAssertEqual(options.user, "root")
        XCTAssertEqual(options.remainder, ["run", "work"])
    }

    /// The splitter and the dispatch read the same list, or a command lands
    /// on the wrong side of this file's whole point.
    func testVerbatimTailComesFromCLICommands() {
        XCTAssertEqual(ArgumentSplitter.verbatimTail, CLICommands.verbatimTail)
        XCTAssertTrue(CLICommands.verbatimTail.contains("run"))
        XCTAssertFalse(CLICommands.fixed.contains("run"))
    }
}
