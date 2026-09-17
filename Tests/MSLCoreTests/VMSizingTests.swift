import Virtualization
import XCTest
@testable import MSLCore

/// Sizing policy, checked for hosts other than the one running the tests -
/// the interesting failure is on a *small* Mac, which this machine is not.
final class VMSizingTests: XCTestCase {

    private let gb: UInt64 = 1024 * 1024 * 1024
    private let vzMin = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    private let concurrent = UInt64(InstanceRegistry.maxConcurrentRunning)

    private func memory(hostGB: UInt64, requested: UInt64? = nil) -> UInt64 {
        VMConfiguration.memorySize(
            forHostMemory: hostGB * gb,
            // On a real machine the framework ceiling tracks physical RAM.
            frameworkMaximum: hostGB * gb,
            frameworkMinimum: vzMin,
            concurrentInstances: concurrent,
            requested: requested)
    }

    /// The rule that matters: the running cap's worth of instances must
    /// leave the host something. A flat 2 GB floor let four instances claim
    /// all 8 GB of an 8 GB Mac.
    func testConcurrentInstancesLeaveHeadroomOnEveryHostSize() {
        for hostGB: UInt64 in [8, 16, 24, 32, 64, 128] {
            let each = memory(hostGB: hostGB)
            let total = each * concurrent
            XCTAssertLessThan(total, hostGB * gb,
                              "\(hostGB) GB host: \(concurrent) x \(each / 1024 / 1024) MB exceeds the machine")
            XCTAssertLessThanOrEqual(total, (hostGB * gb) / 4 * 3,
                                     "\(hostGB) GB host: should leave macOS a quarter")
        }
    }

    func testSmallHostStillGetsSomethingBootable() {
        XCTAssertGreaterThanOrEqual(memory(hostGB: 8), gb, "must not fall under 1 GB")
        XCTAssertGreaterThanOrEqual(memory(hostGB: 4), gb)
    }

    func testLargeHostIsCappedForHibernationTime() {
        // Saving a guest writes its whole RAM inside a bounded deadline.
        XCTAssertEqual(memory(hostGB: 128), 8 * gb)
        XCTAssertEqual(memory(hostGB: 64), 8 * gb)
    }

    func testAlwaysAWholeMegabyte() {
        for hostGB: UInt64 in [4, 8, 12, 16, 24, 31, 48, 96, 128] {
            XCTAssertEqual(memory(hostGB: hostGB) % (1024 * 1024), 0, "\(hostGB) GB host")
        }
    }

    func testEnvironmentOverrideIsStillBounded() {
        XCTAssertEqual(memory(hostGB: 16, requested: 64 * gb), 8 * gb, "an absurd override is capped")
        XCTAssertGreaterThanOrEqual(memory(hostGB: 16, requested: 1), gb, "a tiny override is floored")
    }

    func testCPUCountStaysWithinFrameworkBounds() {
        let vzMax = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let vzMinCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        for cores in [1, 2, 4, 8, 10, 16, 24] {
            let value = VMConfiguration.cpuCount(
                forHostCores: cores, frameworkMaximum: vzMax, frameworkMinimum: vzMinCPU)
            XCTAssertGreaterThanOrEqual(value, vzMinCPU, "\(cores) cores")
            XCTAssertLessThanOrEqual(value, vzMax, "\(cores) cores")
            XCTAssertLessThanOrEqual(value, 8, "\(cores) cores: capped")
        }
    }

    /// The real machine's values must be valid too.
    func testRealDefaultsAreValid() {
        XCTAssertEqual(VMConfiguration.defaultMemorySize() % (1024 * 1024), 0)
        XCTAssertLessThanOrEqual(
            VMConfiguration.defaultMemorySize(),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        XCTAssertGreaterThanOrEqual(VMConfiguration.defaultCPUCount(), 1)
    }
}
