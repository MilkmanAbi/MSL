import XCTest
@testable import MSLCore

final class InstanceSetupTests: XCTestCase {
    private let gigabyte: UInt64 = 1 << 30

    func testParsesEveryOptionAndLeavesTheRest() throws {
        let (options, remaining) = try InstanceSetupOptions.parse(
            ["work", "--cpus", "4", "--memory", "6G", "--disk", "128G", "--distro", "debian"])
        XCTAssertEqual(options.cpus, 4)
        XCTAssertEqual(options.memory, .manual(megabytes: 6 * 1024))
        XCTAssertEqual(options.disk, StoragePolicy(mode: .dynamic, size: 128 * gigabyte, autoGrow: true))
        XCTAssertEqual(remaining, ["work", "--distro", "debian"])
    }

    func testEqualsFormAndMemoryRangeAndFixedDisk() throws {
        let (options, remaining) = try InstanceSetupOptions.parse(["--cpus=2", "--memory=2G-8G", "--disk-fixed=64G"])
        XCTAssertEqual(options.cpus, 2)
        XCTAssertEqual(options.memory, .dynamic(floorMegabytes: 2048, ceilingMegabytes: 8192))
        XCTAssertEqual(options.disk, StoragePolicy(mode: .fixed, size: 64 * gigabyte, autoGrow: false))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMegabyteMemory() throws {
        let (options, _) = try InstanceSetupOptions.parse(["--memory", "1536M"])
        XCTAssertEqual(options.memory, .manual(megabytes: 1536))
    }

    func testNoOptionsIsEmpty() throws {
        let (options, remaining) = try InstanceSetupOptions.parse(["debian"])
        XCTAssertTrue(options.isEmpty)
        XCTAssertEqual(remaining, ["debian"])
    }

    func testBadValuesAreRefusedWithAHint() {
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--cpus", "zero"]))
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--cpus", "0"]))
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--memory", "lots"]))
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--memory", "2G-4G-8G"]))
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--disk", "-5G"]))
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--disk"])) { error in
            XCTAssertEqual(error as? InstanceSetupOptions.ParseError, .missingValue("--disk"))
        }
        // An option where a value should be is a missing value, not a value.
        XCTAssertThrowsError(try InstanceSetupOptions.parse(["--cpus", "--memory", "4G"]))
    }

    func testValidateRefusesTooManyCPUs() {
        XCTAssertThrowsError(try InstanceSetup.validate(InstanceSetupOptions(cpus: 64), maximumCPUs: 10))
        XCTAssertNoThrow(try InstanceSetup.validate(InstanceSetupOptions(cpus: 10), maximumCPUs: 10))
    }

    func testValidateRefusesMemoryTheMacDoesNotHaveAndWarnsNearTheTop() throws {
        let host: UInt64 = 16 * gigabyte
        XCTAssertThrowsError(try InstanceSetup.validate(InstanceSetupOptions(memory: .manual(megabytes: 32 * 1024)), hostMemory: host))
        XCTAssertThrowsError(try InstanceSetup.validate(
            InstanceSetupOptions(memory: .dynamic(floorMegabytes: 8192, ceilingMegabytes: 2048)), hostMemory: host))
        let warnings = try InstanceSetup.validate(InstanceSetupOptions(memory: .manual(megabytes: 12 * 1024)), hostMemory: host)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(try InstanceSetup.validate(InstanceSetupOptions(memory: .manual(megabytes: 4096)), hostMemory: host).isEmpty)
    }

    func testValidateRefusesDiskOutsideTheLimits() {
        XCTAssertThrowsError(try InstanceSetup.validate(
            InstanceSetupOptions(disk: StoragePolicy(mode: .dynamic, size: gigabyte, autoGrow: true))))
        XCTAssertNoThrow(try InstanceSetup.validate(
            InstanceSetupOptions(disk: StoragePolicy(mode: .dynamic, size: 64 * gigabyte, autoGrow: true))))
    }

    func testDescriptions() {
        XCTAssertEqual(InstanceSetup.describe(MemoryMode.manual(megabytes: 4096)), "4G fixed")
        XCTAssertEqual(InstanceSetup.describe(MemoryMode.manual(megabytes: 1536)), "1536M fixed")
        XCTAssertEqual(InstanceSetup.describe(MemoryMode.dynamic(floorMegabytes: 1024, ceilingMegabytes: 8192)), "1G-8G dynamic")
    }
}
