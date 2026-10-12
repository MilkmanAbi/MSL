import XCTest
@testable import MSLCore

/// Settings from a shipment land on one instance, never on the Mac.
final class InstanceExperimentsTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    func testOnlyDifferencesAreStored() {
        var local = MSLExperimentalSettings()
        local.globalMenuBar = true
        var shipped = local
        shipped.globalMenuBar = false

        let outcomes = InstanceExperiments.apply(shipped, to: "box", appWide: local,
                                                 canUseGPU: true, appSupport: support)
        let stored = InstanceExperiments.overrides(instance: "box", appSupport: support)
        XCTAssertEqual(Array(stored.keys), ["globalMenuBar"],
                       "a full snapshot would pin settings the sender never touched")
        XCTAssertTrue(outcomes.contains(.applied("globalMenuBar")))
    }

    func testEffectiveSettingsLayerTheOverrideOverTheAppWideValue() {
        var local = MSLExperimentalSettings()
        local.globalMenuBar = true
        var shipped = local
        shipped.globalMenuBar = false
        InstanceExperiments.apply(shipped, to: "box", appWide: local, appSupport: support)

        XCTAssertFalse(InstanceExperiments.effective(for: "box", appWide: local, appSupport: support).globalMenuBar)
        // Another instance is untouched - this is the whole point.
        XCTAssertTrue(InstanceExperiments.effective(for: "other", appWide: local, appSupport: support).globalMenuBar)
    }

    func testSettingsThisMacCannotHonourAreSkippedWithAReason() {
        var local = MSLExperimentalSettings(); local.gpuAcceleration = false
        var shipped = local; shipped.gpuAcceleration = true

        let outcomes = InstanceExperiments.apply(shipped, to: "box", appWide: local,
                                                 canUseGPU: false, appSupport: support)
        guard case .skipped(let key, _)? = outcomes.first(where: {
            if case .skipped = $0 { return true } else { return false }
        }) else { return XCTFail("expected a skip, got \(outcomes)") }
        XCTAssertEqual(key, "gpuAcceleration")
        XCTAssertTrue(InstanceExperiments.overrides(instance: "box", appSupport: support).isEmpty)
    }

    /// Migration bookkeeping must not travel, or the receiving Mac thinks
    /// this instance has already been migrated.
    func testDefaultsGenerationNeverTravels() {
        var local = MSLExperimentalSettings(); local.defaultsGeneration = 1
        var shipped = local; shipped.defaultsGeneration = 99
        InstanceExperiments.apply(shipped, to: "box", appWide: local, appSupport: support)
        XCTAssertNil(InstanceExperiments.overrides(instance: "box", appSupport: support)["defaultsGeneration"])
    }
}

final class ShipmentManifestTests: XCTestCase {
    func testRefusesAShipmentFromANewerMSL() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-ship-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manifest = folder.appendingPathComponent("msl.json")
        try Data("""
        {"shipment": 99, "created": "2026-10-01T00:00:00Z", "mslVersion": "9.0",
         "source": {"instance": "x", "distro": "debian", "custom": false},
         "disk": {"file": "rootfs.img.z", "compression": "xz", "sha256": "", "uncompressedSize": 0}}
        """.utf8).write(to: manifest)
        let archive = folder.appendingPathComponent("x.mslship")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-0", "-j", "-q", archive.path, manifest.path]
        try zip.run(); zip.waitUntilExit()

        XCTAssertThrowsError(try Shipment.info(at: archive)) { error in
            guard case Shipment.ShipmentError.tooNew = error else {
                return XCTFail("expected .tooNew, got \(error)")
            }
        }
    }

    func testAFileThatIsNotAShipmentIsRejected() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-shipment-\(UUID().uuidString).mslship")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try Shipment.info(at: file))
    }
}
