import XCTest
@testable import MSLCore

/// Work MSL does on the user's behalf must run as the user's own account.
/// Every GUI app used to run as root, because the shell protocol's default
/// user is empty and empty means root.
final class GuestUserTests: XCTestCase {
    private var registryURL: URL!

    override func setUpWithError() throws {
        registryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-users-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: registryURL)
    }

    func testEmptyUserMeansRoot() {
        XCTAssertTrue(GuestUser.isRoot(""))
        XCTAssertTrue(GuestUser.isRoot("root"))
        XCTAssertFalse(GuestUser.isRoot("abinaash"))
    }

    /// The registry is keyed by distro because instances of one distro share
    /// a disk, and so one /etc/passwd.
    func testAccountIsRememberedPerDistro() throws {
        let registry = DefaultUserRegistry(path: registryURL)
        try registry.setDefaultUser("abinaash", forInstance: "work")
        XCTAssertEqual(registry.defaultUser(forInstance: "work"), "abinaash")
        XCTAssertNil(registry.defaultUser(forInstance: "other"))
    }

    /// Before the first-run account exists there is nobody else to be, so
    /// root is the honest fallback rather than a failure. The lookup is
    /// injected: reading the real registry made this test pass or fail
    /// depending on which accounts this particular Mac happens to have.
    func testFallsBackToRootWithNoAccount() {
        XCTAssertTrue(GuestUser.isRoot(GuestUser.shellUser(forInstance: "box", lookup: { _ in nil })))
    }

    /// With an account, that is who user-facing work runs as.
    func testRunsAsTheAccountWhenThereIsOne() {
        XCTAssertEqual(GuestUser.shellUser(forInstance: "box", lookup: { _ in "abinaash" }), "abinaash")
        XCTAssertFalse(GuestUser.isRoot(GuestUser.shellUser(forInstance: "box", lookup: { _ in "abinaash" })))
    }
}

extension GuestUserTests {
    /// The account MSL should act as, read from a real `/etc/passwd`.
    ///
    /// This exists because relying on having *recorded* an account was not
    /// enough: an account made by hand, or a registry that lost its entry,
    /// left every app running as root - the exact thing v2 set out to fix.
    func testPicksTheHumanAccount() {
        let passwd = """
        root:x:0:0:root:/root:/bin/bash
        daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        systemd-network:x:998:998:systemd Network Management:/:/usr/sbin/nologin
        polkitd:x:990:990:User for polkitd:/:/usr/sbin/nologin
        abinaash:x:1001:1001::/home/abinaash:/bin/bash
        nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
        """
        XCTAssertEqual(GuestUser.pick(fromPasswd: passwd), "abinaash")
    }

    /// The first account created is the person's, even when later ones exist.
    func testLowestRealUidWins() {
        let passwd = """
        root:x:0:0:root:/root:/bin/bash
        second:x:1001:1001::/home/second:/bin/bash
        first:x:1000:1000::/home/first:/bin/bash
        """
        XCTAssertEqual(GuestUser.pick(fromPasswd: passwd), "first")
    }

    /// A guest with no human account at all still has to be usable - that is
    /// the one case where root is the right answer.
    func testNoHumanAccountMeansNone() {
        let passwd = """
        root:x:0:0:root:/root:/bin/bash
        bin:x:1:1:bin:/bin:/sbin/nologin
        nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
        """
        XCTAssertNil(GuestUser.pick(fromPasswd: passwd))
    }

    /// Older Red Hat systems start real accounts at 500.
    func testFallsBackToTheOlderUidFloor() {
        XCTAssertEqual(GuestUser.pick(fromPasswd: "root:x:0:0::/root:/bin/sh\nlegacy:x:500:500::/home/legacy:/bin/bash"),
                       "legacy")
    }

    /// Accounts that cannot log in are not people.
    func testServiceAccountsAreSkipped() {
        let passwd = """
        root:x:0:0::/root:/bin/bash
        snapd-range-524288-root:x:524288:524288::/nonexistent:/usr/bin/false
        _flatpak:x:1002:1002::/nonexistent:/usr/sbin/nologin
        real:x:1003:1003::/home/real:/bin/bash
        """
        XCTAssertEqual(GuestUser.pick(fromPasswd: passwd), "real")
    }

    /// CRLF, because everything from the guest arrives over a pty.
    func testHandlesCRLF() {
        XCTAssertEqual(GuestUser.pick(fromPasswd: "root:x:0:0::/root:/bin/sh\r\nabi:x:1000:1000::/home/abi:/bin/bash\r\n"),
                       "abi")
    }
}
