import XCTest
@testable import MSLCore

/// These run against the real Mac, so they assert plausibility rather than
/// exact values - the point is that the Mach call is wired up correctly and
/// the units are bytes, which is exactly the class of mistake that would
/// otherwise show up as a controller that never grows a guest.
final class HostMemoryMonitorTests: XCTestCase {
    func testAvailableMemoryIsPlausible() {
        let physical = ProcessInfo.processInfo.physicalMemory
        let available = HostMemoryMonitor.availableBytes()

        XCTAssertGreaterThan(available, 0, "reported no available memory on a running Mac - wrong units or a failed call")
        XCTAssertLessThan(available, physical, "reported more available than the machine has")
        // A units slip (pages counted as bytes) would land absurdly low.
        XCTAssertGreaterThan(available, 16 * 1024 * 1024,
                             "suspiciously small - page counts probably weren't multiplied by the page size")
    }

    func testPressureIsReadable() {
        // Any of the three is a legitimate answer; the assertion is that the
        // sysctl exists and maps, since an unknown value silently becomes
        // .normal and would hide a typo in the name forever.
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        XCTAssertEqual(sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0), 0,
                       "the pressure sysctl this depends on is not present under that name")
        XCTAssertTrue([1, 2, 4].contains(level), "unexpected pressure level \(level)")
    }

    func testSampleIsInternallyConsistent() {
        let sample = HostMemoryMonitor.sample()
        XCTAssertEqual(sample.physical, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(sample.availableBytes, sample.physical)
    }
}
