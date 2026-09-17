import XCTest
@testable import MSLCore

final class ResourcePolicyTests: XCTestCase {
    let gb: UInt64 = 1024 * 1024 * 1024
    let mb: UInt64 = 1024 * 1024

    /// Framework bounds for a *hypothetical* host.
    ///
    /// Measured on a real Mac: `maximumAllowedMemorySize` is not some large
    /// abstract ceiling, it is exactly the machine's physical memory
    /// (16384 MB on a 16 GB Mac), while `minimumAllowedMemorySize` is 4 MB.
    /// Tests that let the real machine's bounds leak in were really just
    /// asserting things about this laptop, which is the one host the policy
    /// does not need help with.
    func bounds(forHost host: UInt64) -> (minimum: UInt64, maximum: UInt64) {
        (4 * mb, host)
    }

    // MARK: - Advice

    /// The headline rule the user asked for, checked on machines this one
    /// is not: three fifths of 8 GB is 4915 MB, of 64 GB is 39321 MB.
    func testWarnsAboveThreeFifthsOfHostMemory() {
        for hostGB in [8, 16, 36, 64, 192] as [UInt64] {
            let host = hostGB * gb
            let limits = bounds(forHost: host)
            let threshold = MemoryAdvisor.cautionThresholdMegabytes(hostMemory: host)
            XCTAssertEqual(threshold, (host / 5 * 3) / mb, "\(hostGB) GB host")

            XCTAssertEqual(MemoryAdvisor.advise(megabytes: threshold, hostMemory: host,
                                                frameworkMinimum: limits.minimum,
                                                frameworkMaximum: limits.maximum).severity, .fine,
                           "exactly at the threshold should not warn (\(hostGB) GB)")
            let over = MemoryAdvisor.advise(megabytes: threshold + 1, hostMemory: host,
                                            frameworkMinimum: limits.minimum,
                                            frameworkMaximum: limits.maximum)
            XCTAssertEqual(over.severity, .caution, "one MB over should warn (\(hostGB) GB)")
            XCTAssertNotNil(over.message)
            XCTAssertTrue(over.message!.contains("paging"), "the warning should say why: \(over.message!)")
        }
    }

    /// A caution is not a refusal - the user may well mean it.
    func testCautionStillAllowsStarting() {
        let limits = bounds(forHost: 16 * gb)
        let advice = MemoryAdvisor.advise(megabytes: 14 * 1024, hostMemory: 16 * gb,
                                          frameworkMinimum: limits.minimum, frameworkMaximum: limits.maximum)
        XCTAssertEqual(advice.severity, .caution)
        XCTAssertTrue(advice.allowsStart)
    }

    /// Asking for more than the machine has is refused, not merely warned
    /// about - and refused *here*, because the framework's own maximum is
    /// far above the host's RAM and would let this through to fail at start.
    func testMoreThanTheHostHasIsBlocked() {
        let advice = MemoryAdvisor.advise(megabytes: 32 * 1024, hostMemory: 16 * gb,
                                          frameworkMinimum: 128 * mb, frameworkMaximum: 128 * gb)
        XCTAssertEqual(advice.severity, .blocking)
        XCTAssertFalse(advice.allowsStart)
    }

    func testFrameworkBoundsAreEnforcedInBothDirections() {
        XCTAssertEqual(
            MemoryAdvisor.advise(megabytes: 8, hostMemory: 16 * gb,
                                 frameworkMinimum: 128 * mb, frameworkMaximum: 128 * gb).severity,
            .blocking, "below the framework minimum")
        XCTAssertEqual(
            MemoryAdvisor.advise(megabytes: 300 * 1024, hostMemory: 512 * gb,
                                 frameworkMinimum: 128 * mb, frameworkMaximum: 128 * gb).severity,
            .blocking, "above the framework maximum")
    }

    /// Dynamic mode is judged on its ceiling: that is what the VM boots
    /// with and therefore what the Mac actually has to find.
    func testDynamicRangeIsJudgedOnItsCeiling() {
        let host = 16 * gb
        let limits = bounds(forHost: host)
        let generous = MemoryMode.dynamic(floorMegabytes: 1024, ceilingMegabytes: 14 * 1024)
        XCTAssertEqual(MemoryAdvisor.advise(mode: generous, hostMemory: host,
                                            frameworkMinimum: limits.minimum,
                                            frameworkMaximum: limits.maximum).severity, .caution)

        let modest = MemoryMode.dynamic(floorMegabytes: 1024, ceilingMegabytes: 4096)
        XCTAssertEqual(MemoryAdvisor.advise(mode: modest, hostMemory: host,
                                            frameworkMinimum: limits.minimum,
                                            frameworkMaximum: limits.maximum).severity, .fine)
    }

    func testInvertedRangeIsRejected() {
        let inverted = MemoryMode.dynamic(floorMegabytes: 8192, ceilingMegabytes: 2048)
        let limits = bounds(forHost: 32 * gb)
        XCTAssertEqual(MemoryAdvisor.advise(mode: inverted, hostMemory: 32 * gb,
                                            frameworkMinimum: limits.minimum,
                                            frameworkMaximum: limits.maximum).severity, .blocking)
    }

    /// The default range must not itself trip the warning it exists under.
    func testDefaultDynamicRangeIsNeverAlarming() {
        for hostGB in [8, 16, 36, 64, 192] as [UInt64] {
            let host = hostGB * gb
            let limits = bounds(forHost: host)
            let advice = MemoryAdvisor.advise(mode: MemoryAdvisor.defaultDynamicRange(hostMemory: host),
                                              hostMemory: host,
                                              frameworkMinimum: limits.minimum,
                                              frameworkMaximum: limits.maximum)
            XCTAssertEqual(advice.severity, .fine, "default range warns on a \(hostGB) GB Mac")
        }
    }

    // MARK: - Mode

    /// The load-bearing fact of the whole feature: dynamic mode has to boot
    /// at its ceiling, because the balloon can only ever take memory away.
    func testDynamicModeConfiguresTheCeiling() {
        let mode = MemoryMode.dynamic(floorMegabytes: 1024, ceilingMegabytes: 6144)
        XCTAssertEqual(mode.configuredBytes, 6144 * mb)
        XCTAssertTrue(mode.isDynamic)

        let manual = MemoryMode.manual(megabytes: 2048)
        XCTAssertEqual(manual.configuredBytes, 2048 * mb)
        XCTAssertFalse(manual.isDynamic)
    }

    /// An instance nobody has configured must behave exactly as it did
    /// before any of this existed.
    func testInheritedPolicyMatchesTheOldDefaults() {
        let policy = ResourcePolicy.inherited
        XCTAssertEqual(policy.resolvedCPUCount(), VMConfiguration.defaultCPUCount())
        XCTAssertEqual(policy.resolvedMemory().configuredBytes,
                       (VMConfiguration.defaultMemorySize() / mb) * mb)
    }

    // MARK: - Storage

    func testPolicyRoundTripsThroughDisk() {
        let instance = "resource-policy-test-\(UUID().uuidString)"
        defer { ResourcePolicyStore.forget(instance: instance) }

        XCTAssertEqual(ResourcePolicyStore.load(instance: instance), .inherited,
                       "an unconfigured instance must read back as inherited, not as zeroes")

        let policy = ResourcePolicy(cpuCount: 6,
                                    memory: .dynamic(floorMegabytes: 1024, ceilingMegabytes: 5120))
        XCTAssertTrue(ResourcePolicyStore.save(policy, instance: instance))
        XCTAssertEqual(ResourcePolicyStore.load(instance: instance), policy)

        ResourcePolicyStore.forget(instance: instance)
        XCTAssertEqual(ResourcePolicyStore.load(instance: instance), .inherited)
    }

    func testManualModeRoundTrips() {
        let instance = "resource-policy-manual-\(UUID().uuidString)"
        defer { ResourcePolicyStore.forget(instance: instance) }
        let policy = ResourcePolicy(cpuCount: nil, memory: .manual(megabytes: 3072))
        XCTAssertTrue(ResourcePolicyStore.save(policy, instance: instance))
        let loaded = ResourcePolicyStore.load(instance: instance)
        XCTAssertEqual(loaded, policy)
        XCTAssertNil(loaded.cpuCount, "nil must survive as nil, not become a number")
        XCTAssertEqual(loaded.resolvedCPUCount(), VMConfiguration.defaultCPUCount())
    }
}
