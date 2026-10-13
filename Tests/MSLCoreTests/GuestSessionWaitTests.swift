import XCTest
@testable import MSLCore

/// The wait that sets up a user session inside a guest.
///
/// It runs before **every** guest command, so anything it waits for in vain
/// is paid by every app launch. It once waited for `/run/user/$uid/bus` while
/// deciding the outcome from `/run/user/$uid`, and on Fedora those never
/// agree: the directory is there and that socket never appears, so each
/// command sat for the full five seconds and then succeeded anyway.
/// Measured: 5.25s per command on Fedora against 0.12s on Alpine.
final class GuestSessionWaitTests: XCTestCase {

    private var script: String { GuestIntegration.userSessionCommand(user: "abi") }

    /// **The regression.** Waiting on the session bus socket is what cost the
    /// five seconds, and nothing needed it - MSL supplies the session bus.
    func testItDoesNotWaitForASessionBusSocket() {
        XCTAssertFalse(script.contains("/bus\" ]"),
                       "waiting for /run/user/$uid/bus costs five seconds on Fedora and buys nothing")
        XCTAssertFalse(script.contains("-S \"/run/user/$msl_uid/bus\""))
    }

    /// What it waits for and what it reports must be the same thing, or the
    /// wait can never end on a guest that is already fine.
    func testItWaitsForTheSameThingItJudgesOn() {
        XCTAssertTrue(script.contains("! -d \"/run/user/$msl_uid\""),
                      "the loop should wait for the runtime directory")
        XCTAssertTrue(script.contains("if [ -d \"/run/user/$msl_uid\" ]; then echo \"MSL-SESSION-OK\""))
    }

    /// A guest that already has its runtime directory must not wait at all.
    func testThereIsNoWaitWhenTheDirectoryIsAlreadyThere() {
        guard let loop = script.range(of: "while [ $msl_i") else {
            return XCTFail("no wait loop at all")
        }
        let before = script[..<loop.lowerBound]
        XCTAssertTrue(before.contains("if [ ! -d \"/run/user/$msl_uid\" ]; then"),
                      "the loop must sit inside a check that the directory is missing")
    }

    /// The wait is still there for the case it was written for: a first start
    /// where logind has not made the directory yet.
    func testTheWaitStillExistsForAFirstStart() {
        XCTAssertTrue(script.contains("loginctl enable-linger"))
        XCTAssertTrue(script.contains("sleep 0.2"))
    }

    /// A guest with no logind says so immediately rather than waiting.
    func testAGuestWithoutLogindExitsAtOnce() {
        XCTAssertTrue(script.contains("command -v loginctl >/dev/null 2>&1 || { echo \"MSL-SESSION-NONE\"; exit 0; }"))
    }

    // MARK: - The menu bridge wait

    private var launch: String {
        GuestIntegration.launchCommand("true", instance: "x",
                                       settings: MSLExperimentalSettings())
    }

    /// **The one that made app launches slow, and inconsistently so.**
    /// The bridge exits immediately when another already owns the name -
    /// "leaving it to that one" - and then neither the ready file nor the
    /// ownership check ever comes true, so the wait ran its full 30 x 0.1s
    /// for a process that was already dead. Measured on Alpine: 3.42s per
    /// launch against Fedora's 0.19s, 3.24s of it here.
    func testTheMenuBridgeWaitEndsWhenTheBridgeDoes() {
        XCTAssertTrue(launch.contains("kill -0 \"$msl_menu_started\" 2>/dev/null || break"),
                      "the wait must stop once the bridge process is gone")
    }

    /// It still waits for a bridge that is genuinely coming up.
    func testTheMenuBridgeIsStillWaitedForWhileItLives() {
        XCTAssertTrue(launch.contains("[ -e \"$msl_menu_ready\" ] && break"))
        XCTAssertTrue(launch.contains("msl_menu_owned && break"))
    }

    /// The pid waited on must be the bridge just started, not whatever a
    /// stale pid file happens to hold.
    func testTheWaitWatchesTheBridgeItStarted() {
        XCTAssertTrue(launch.contains("msl_menu_started=$!"))
    }

    // MARK: - A session bus that has died

    /// **A socket file outlives the daemon that made it.** `-S` says only
    /// that the path is a socket, not that anything is listening - so an
    /// instance whose bus died left the address file behind, and every
    /// launch afterwards adopted an address answering "Connection refused".
    /// Observed on Alpine: portals, snap and the menu bridge all failing
    /// quietly, the bridge respawned and dying on every app launch.
    func testADeadSessionBusAddressIsNotAdopted() {
        XCTAssertTrue(launch.contains("msl_bus_answers \"$msl_bus\""),
                      "the cached bus address must be proved live before use")
        XCTAssertFalse(launch.contains("[ -S \"$msl_sock\" ] && export DBUS_SESSION_BUS_ADDRESS"),
                       "a socket file existing is not a bus answering")
    }

    /// And the stale file is cleared, so the next step starts a fresh daemon
    /// rather than meeting the same corpse again.
    func testAStaleBusAddressIsThrownAway() {
        XCTAssertTrue(launch.contains("rm -f \"$msl_bus_file\""))
    }

    /// The probe must not become a new dependency: a guest with neither
    /// client behaves as it always did.
    func testAGuestWithNoDBusClientStillWorks() {
        XCTAssertTrue(launch.contains("command -v gdbus"))
        XCTAssertTrue(launch.contains("command -v dbus-send"))
        XCTAssertTrue(launch.contains("return 0"),
                      "with no client to ask, trust the socket as before")
    }

    // MARK: - Dollars and systemd

    /// **There is no spelling of a dollar that works on every systemd.**
    /// Measured on two guests with the same command: systemd 262 (Arch)
    /// parses `$HOME/...` greedily and refuses it - "Invalid environment
    /// variable name evaluates to an empty string" - while systemd 257
    /// (Alma) passes `$$HOME` straight through, so the shell reads `$$` as
    /// its own pid and runs `5132HOME/...`. Escaping for one breaks the
    /// other, which is what happened: Arch was fixed and Alma broke
    /// identically a week later.
    ///
    /// So a command with a dollar in it skips the systemd scope and is run
    /// directly, where one shell does the expanding and the answer does not
    /// depend on anybody's systemd version.
    func testACommandWithADollarNeverReachesSystemd() {
        let script = GuestIntegration.launchCommand("$HOME/bin/thing", instance: "x",
                                                    settings: MSLExperimentalSettings())
        XCTAssertFalse(script.contains("systemd-run"),
                       "a dollar must not be handed to systemd at all")
        XCTAssertTrue(script.hasSuffix("$HOME/bin/thing"),
                      "it still runs, directly, where the shell expands it")
    }

    /// An ordinary command keeps the scope - that is what it is for, so
    /// snap's cgroup check passes.
    func testACommandWithoutADollarStillGetsTheScope() {
        let script = GuestIntegration.launchCommand("krita", instance: "x",
                                                    settings: MSLExperimentalSettings())
        XCTAssertTrue(script.contains("systemd-run --user --scope"))
        XCTAssertTrue(script.contains("sh -c 'krita'"))
    }

    /// Which is why MSL's own tile has no dollar in it: it resolves on the
    /// PATH every launch exports, so it keeps the scope on every distro.
    func testMSLsOwnCommandIsDollarFree() {
        let command = LinuxApp.mslFiles().command
        XCTAssertFalse(command.contains("$"), "MSL's own command must not need expanding")
        XCTAssertEqual(command, "msl-open dir")
        let script = GuestIntegration.launchCommand(command, instance: "x",
                                                    settings: MSLExperimentalSettings())
        XCTAssertTrue(script.contains("systemd-run --user --scope"))
    }

    // MARK: - Turning the menu bar off

    /// **Off has to undo, not merely stop adding.** The bridge owns
    /// `com.canonical.AppMenu.Registrar` for as long as it runs and outlives
    /// the app that started it, so switching the menu bar off left the
    /// registrar owned and a toolkit looking for one still found it. Qt
    /// decides whether to keep its own menu bar on exactly that question.
    func testTurningTheMenuBarOffStopsARunningBridge() {
        var off = MSLExperimentalSettings()
        off.globalMenuBar = false
        let script = GuestIntegration.launchCommand("krita", instance: "x", settings: off)
        XCTAssertTrue(script.contains("msl_menubridge.py"),
                      "off must still know how to find a bridge, in order to stop it")
        XCTAssertTrue(script.contains("kill \"$msl_menu_pid\""))
        XCTAssertFalse(script.contains("appmenu-gtk-module"),
                       "and must not load the module that hides an app's own menus")
    }

    /// On still starts one.
    func testTurningItOnStartsTheBridge() {
        var on = MSLExperimentalSettings()
        on.globalMenuBar = true
        let script = GuestIntegration.launchCommand("krita", instance: "x", settings: on)
        XCTAssertTrue(script.contains("--ready-file"), "on must start the bridge")
    }

    /// The pid file outlives its process, so the number may belong to
    /// something else by the time this runs.
    func testItChecksWhatItIsAboutToKill() {
        var off = MSLExperimentalSettings()
        off.globalMenuBar = false
        let script = GuestIntegration.launchCommand("krita", instance: "x", settings: off)
        XCTAssertTrue(script.contains("/proc/$msl_menu_pid/cmdline"),
                      "a stale pid must not take an unrelated process with it")
    }
}
