import XCTest
@testable import MSLCore

/// The host -> guest path mapping behind "Open Folder in MSL".
///
/// Worth unit-testing rather than clicking through: the failure mode is a
/// shell that opens at the wrong directory (or at a different user's files),
/// which looks like it worked.
final class GuestPathMappingTests: XCTestCase {
    private let home = "/Users/abinaash"
    private let mounts = [GuestMount(instance: "default", mountPath: "/Volumes/MSL-default")]

    private func map(_ path: String) -> GuestPathMapping {
        GuestPathMapper.map(hostPath: path, guestMounts: mounts, homeDirectory: home)
    }

    // MARK: - The guest's own filesystem

    func testPathInsideAGuestMountBecomesAGuestAbsolutePath() {
        XCTAssertEqual(map("/Volumes/MSL-default/etc/apk/repositories"),
                       .guestFilesystem(instance: "default", guestPath: "/etc/apk/repositories"))
    }

    func testGuestMountRootItselfMapsToSlash() {
        XCTAssertEqual(map("/Volumes/MSL-default"),
                       .guestFilesystem(instance: "default", guestPath: "/"))
    }

    func testTheRightInstanceIsChosenWhenSeveralAreRunning() {
        let many = [GuestMount(instance: "default", mountPath: "/Volumes/MSL-default"),
                    GuestMount(instance: "work", mountPath: "/Volumes/MSL-work")]
        XCTAssertEqual(
            GuestPathMapper.map(hostPath: "/Volumes/MSL-work/srv", guestMounts: many,
                                homeDirectory: home),
            .guestFilesystem(instance: "work", guestPath: "/srv"))
    }

    // MARK: - The Mac home share

    func testPathUnderHomeGoesThroughTheMacShare() {
        XCTAssertEqual(map("/Users/abinaash/Desktop/MSL-Project"),
                       .macHomeShare(guestPath: "/mnt/mac/Desktop/MSL-Project"))
    }

    func testHomeItselfIsTheShareRoot() {
        XCTAssertEqual(map("/Users/abinaash"), .macHomeShare(guestPath: "/mnt/mac"))
    }

    /// The one that matters most. A `hasPrefix` check calls this a match and
    /// hands the guest a path inside somebody else's home directory.
    func testASiblingHomeDirectoryIsNotInsideHome() {
        XCTAssertEqual(map("/Users/abinaash-other/notes.txt"), .unreachable)
    }

    /// Same boundary bug, on the guest mount.
    func testASiblingOfAGuestMountIsNotInsideIt() {
        XCTAssertEqual(map("/Volumes/MSL-default-backup/etc"), .unreachable)
    }

    // MARK: - Not reachable at all

    func testSystemPathsAreUnreachable() {
        XCTAssertEqual(map("/usr/local/bin"), .unreachable)
        XCTAssertEqual(map("/Applications/Safari.app"), .unreachable)
        XCTAssertEqual(map("/"), .unreachable)
    }

    func testAnotherVolumeIsUnreachable() {
        XCTAssertEqual(map("/Volumes/Backup/photos"), .unreachable)
    }

    // MARK: - Formatting differences must not change the answer

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(map("/Users/abinaash/Desktop/"),
                       .macHomeShare(guestPath: "/mnt/mac/Desktop"))
    }

    func testRelativeTraversalIsResolvedBeforeMatching() {
        // Resolves back inside home - and, more importantly, a path that
        // climbs *out* must not stay matched.
        XCTAssertEqual(map("/Users/abinaash/Desktop/../Documents"),
                       .macHomeShare(guestPath: "/mnt/mac/Documents"))
        XCTAssertEqual(map("/Users/abinaash/../root-lookalike"), .unreachable)
    }

    func testTrailingSlashOnTheMountItselfIsIgnored() {
        XCTAssertEqual(
            GuestPathMapper.map(hostPath: "/Volumes/MSL-default/srv",
                                guestMounts: [GuestMount(instance: "default",
                                                         mountPath: "/Volumes/MSL-default/")],
                                homeDirectory: home),
            .guestFilesystem(instance: "default", guestPath: "/srv"))
    }

    // MARK: - Names that would break the shell command

    func testSpacesSurviveIntoAQuotedCommand() {
        let command = GuestPathMapper.interactiveShellCommand(in: "/mnt/mac/My Projects")
        XCTAssertTrue(command.hasPrefix("cd '/mnt/mac/My Projects' &&"), command)
    }

    /// A single quote in a folder name is the classic way a hand-built
    /// command line turns into two commands.
    func testSingleQuoteInAPathIsNeutralised() {
        let command = GuestPathMapper.interactiveShellCommand(in: "/mnt/mac/Ann's Files")
        XCTAssertTrue(command.contains("'/mnt/mac/Ann'\\''s Files'"), command)
        // Nothing escapes the quoting to become shell syntax of its own.
        XCTAssertFalse(command.contains("; rm"))
    }

    func testInteractiveNotLoginShell() {
        // `-l` would re-source the profile, which can `cd` and undo the
        // only thing this command does.
        let command = GuestPathMapper.interactiveShellCommand(in: "/srv")
        XCTAssertTrue(command.contains("-i"), command)
        XCTAssertFalse(command.contains(" -l"), command)
    }

    func testFallsBackToShWhenBashIsMissing() {
        // Alpine, the default distro, ships no bash.
        let command = GuestPathMapper.interactiveShellCommand(in: "/srv")
        XCTAssertTrue(command.contains("/bin/bash"), command)
        XCTAssertTrue(command.contains("/bin/sh"), command)
    }
}
