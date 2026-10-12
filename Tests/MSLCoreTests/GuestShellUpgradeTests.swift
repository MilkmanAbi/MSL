import XCTest
@testable import MSLCore

/// Bringing a guest's `shellinit` up to date from MSL, with no image rebuild.
final class GuestShellUpgradeTests: XCTestCase {

    private let sample = Data("int main(void) { return 0; }".utf8)

    func testNothingToInstallWithoutSource() {
        XCTAssertNil(GuestShellUpgrade.installCommand(source: nil))
        XCTAssertNil(GuestShellUpgrade.installCommand(source: Data()))
    }

    func testVersionIsStableAndChangesWithTheSource() {
        XCTAssertEqual(GuestShellUpgrade.version(of: sample), GuestShellUpgrade.version(of: sample))
        XCTAssertNotEqual(GuestShellUpgrade.version(of: sample),
                          GuestShellUpgrade.version(of: Data("something else".utf8)))
    }

    /// The stamp is what makes this a no-op after the first time, on every
    /// subsequent start of every instance.
    func testStampDecidesWhetherItIsCurrent() {
        let version = GuestShellUpgrade.version(of: sample)
        XCTAssertTrue(GuestShellUpgrade.isCurrent(stamp: version, source: sample))
        XCTAssertTrue(GuestShellUpgrade.isCurrent(stamp: "\(version)\n", source: sample))
        XCTAssertFalse(GuestShellUpgrade.isCurrent(stamp: "something-else", source: sample))
        XCTAssertFalse(GuestShellUpgrade.isCurrent(stamp: nil, source: sample))
    }

    /// Every way this can fail has to leave the guest with the `shellinit` it
    /// already had. A host that cannot upgrade a guest must still be able to
    /// talk to it.
    func testEveryFailurePathLeavesTheOldBinaryAlone() throws {
        let command = try XCTUnwrap(GuestShellUpgrade.installCommand(source: sample))
        // Skips entirely when the stamp matches.
        XCTAssertTrue(command.contains(GuestShellUpgrade.stampPath))
        XCTAssertTrue(command.contains("exit 0"))
        // Does nothing without a compiler.
        XCTAssertTrue(command.contains("command -v cc"))
        // Compiles to a temporary path and only then replaces the real one.
        let build = try XCTUnwrap(command.range(of: "-o /tmp/shellinit-msl"))
        let install = try XCTUnwrap(command.range(of: "cp /tmp/shellinit-msl /usr/local/bin/shellinit"))
        XCTAssertLessThan(build.lowerBound, install.lowerBound,
                          "it must compile before it replaces anything")
        // And the stamp is written last, so a failure is retried next start.
        let stamp = try XCTUnwrap(command.range(of: "> '\(GuestShellUpgrade.stampPath)'"))
        XCTAssertLessThan(install.lowerBound, stamp.lowerBound)
    }

    /// musl folds forkpty into libc and glibc does not, so both spellings
    /// are tried before giving up.
    func testItTriesWithAndWithoutLibutil() throws {
        let command = try XCTUnwrap(GuestShellUpgrade.installCommand(source: sample))
        XCTAssertTrue(command.contains("-lutil"))
        XCTAssertEqual(command.components(separatedBy: "cc -O2").count - 1, 2,
                       "one attempt with -lutil, one without")
    }

    /// There is deliberately no in-place restart: the listener owns the
    /// vsock port, so a replacement cannot bind until it is gone, and every
    /// connection in that window is reset. The upgrade lands at the next
    /// start instead.
    func testItDoesNotRestartTheListener() throws {
        let command = try XCTUnwrap(GuestShellUpgrade.installCommand(source: sample))
        XCTAssertFalse(command.contains("kill"))
        XCTAssertFalse(command.contains("setsid"))
    }

    /// The real thing MSL ships, so a packaging change that drops the source
    /// is caught here rather than by a guest that silently never upgrades.
    func testTheShippedSourceIsFound() throws {
        guard let source = GuestShellUpgrade.source() else {
            throw XCTSkip("no MSL.app with a GuestKit on this machine")
        }
        XCTAssertGreaterThan(source.count, 10_000)
        let text = String(decoding: source, as: UTF8.self)
        XCTAssertTrue(text.contains("FRAME_SESSION"), "the shipped source must be the detachable one")
    }
}
