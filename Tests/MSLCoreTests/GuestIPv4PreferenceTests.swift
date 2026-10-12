import XCTest
@testable import MSLCore

/// Preferring IPv4 in guests.
///
/// The Mac's shared network advertises an IPv6 router that does not route.
/// Guests accept it, and every lookup returning a AAAA record then waits
/// for a timeout before trying IPv4. Measured in a stock Ubuntu instance:
/// `ping6` to the address DNS had just handed back lost 100% of packets
/// while the IPv4 address for the same host answered at once, and
/// `apt-get update` hung long enough to look like a dead machine.
final class GuestIPv4PreferenceTests: XCTestCase {

    func testItSetsTheGlibcPrecedenceLine() {
        // The exact line glibc ships commented out for this situation.
        XCTAssertTrue(GuestDNS.preferIPv4Script.contains("precedence ::ffff:0:0/96  100"))
    }

    func testItTellsAptSeparately() {
        // apt resolves on its own and ignores gai.conf, so the precedence
        // line alone would leave the slowest thing on the machine slow.
        XCTAssertTrue(GuestDNS.preferIPv4Script.contains("Acquire::ForceIPv4"))
    }

    func testItDoesNotDisableIPv6() {
        // Preference, not amputation: a network that gains real IPv6 later
        // needs nothing undone, and anything v6-only still works.
        for forbidden in ["disable_ipv6", "ip -6 route del", "net.ipv6.conf"] {
            XCTAssertFalse(GuestDNS.preferIPv4Script.contains(forbidden),
                           "IPv6 should be deprioritised, never turned off")
        }
    }

    func testItIsSafeToRunOnEveryStart() {
        // It runs on each start and on every network change, so it has to
        // be idempotent - no stacking lines, no rewriting a file it has
        // already written.
        XCTAssertTrue(GuestDNS.preferIPv4Script.contains("grep -qs"))
        XCTAssertTrue(GuestDNS.preferIPv4Script.contains("[ ! -f /etc/apt/apt.conf.d/99msl-ipv4 ]"))
    }

    func testItSurvivesADistroWithoutApt() {
        // Alpine, Fedora, anything else: the apt half is guarded.
        XCTAssertTrue(GuestDNS.preferIPv4Script.contains("[ -d /etc/apt/apt.conf.d ]"))
    }

    func testWhatItAddsIsMarked() {
        // Appended to a file the user may also have edited, so what MSL put
        // there has to be identifiable.
        XCTAssertTrue(GuestDNS.ipv4Marker.hasPrefix("#"))
        XCTAssertTrue(GuestDNS.ipv4Marker.contains("MSL"))
    }
}
