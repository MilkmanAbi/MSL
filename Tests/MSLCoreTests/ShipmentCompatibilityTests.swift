import XCTest
@testable import MSLCore

/// What has to stay true for a `.mslship` made today to open years from
/// now, and for one made years from now to open today.
///
/// These are not hypothetical. A shipment is the one MSL artefact meant to
/// outlive the version that wrote it - somebody hands you an environment,
/// and it should still be an environment after both machines have moved on.
final class ShipmentCompatibilityTests: XCTestCase {
    /// A manifest exactly as a v2 MSL writes it, decoded by this build.
    func testAV2ManifestStillDecodes() throws {
        let json = """
        {"shipment":2,"created":"2026-01-01T00:00:00Z","mslVersion":"2.0.0",
         "source":{"instance":"Ubuntu","distro":"ubuntu","custom":false},
         "disk":{"file":"rootfs.img.z","compression":"xz","sha256":"abc","uncompressedSize":1}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Shipment.Manifest.self, from: json)
        XCTAssertEqual(manifest.source.instance, "Ubuntu")
    }

    /// The same, plus fields a FUTURE MSL might add.
    func testAFutureManifestWithExtraFieldsStillDecodes() throws {
        let json = """
        {"shipment":2,"created":"2026-01-01T00:00:00Z","mslVersion":"9.9.9",
         "source":{"instance":"Ubuntu","distro":"ubuntu","custom":false},
         "disk":{"file":"rootfs.img.z","compression":"xz","sha256":"abc","uncompressedSize":1},
         "somethingNobodyHasInventedYet":{"a":1},"anotherThing":"hello"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(Shipment.Manifest.self, from: json))
    }

    /// And a settings blob whose shape has drifted.
    func testDriftedSettingsDoNotKillTheWholeManifest() throws {
        let json = """
        {"shipment":2,"created":"2026-01-01T00:00:00Z","mslVersion":"9.9.9",
         "source":{"instance":"Ubuntu","distro":"ubuntu","custom":false},
         "disk":{"file":"rootfs.img.z","compression":"xz","sha256":"abc","uncompressedSize":1},
         "resources":{"somethingElseEntirely":true}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(Shipment.Manifest.self, from: json),
                         "a settings blob MSL no longer understands must not make the file unreadable")
    }
}

/// The promises a shipment makes about its own future.
final class ShipmentVersioningTests: XCTestCase {

    private func manifest(shipment: Int, minimumReader: Int?) -> Data {
        var fields = """
        "shipment":\(shipment),"created":"2026-01-01T00:00:00Z","mslVersion":"x",
        "source":{"instance":"U","distro":"ubuntu","custom":false},
        "disk":{"file":"d","compression":"xz","sha256":"a","uncompressedSize":1}
        """
        if let minimumReader { fields += ",\"minimumReader\":\(minimumReader)" }
        return "{\(fields)}".data(using: .utf8)!
    }

    private func decode(_ data: Data) throws -> Shipment.Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Shipment.Manifest.self, from: data)
    }

    func testANewerButAdditiveShipmentIsReadable() throws {
        // The point of minimumReader. A future MSL that only adds fields
        // says so, and this one opens the file, losing only what it has
        // never heard of. Refusing would have been pure caution.
        let future = try decode(manifest(shipment: 9, minimumReader: 2))
        XCTAssertEqual(future.minimumReader, 2)
        XCTAssertTrue((future.minimumReader ?? future.shipment) <= Shipment.formatVersion,
                      "an additive future shipment must still be readable")
    }

    func testAGenuinelyBreakingShipmentIsRefused() throws {
        let breaking = try decode(manifest(shipment: 9, minimumReader: 9))
        XCTAssertFalse((breaking.minimumReader ?? breaking.shipment) <= Shipment.formatVersion,
                       "a file that needs a newer reader must be refused, not half-unpacked")
    }

    func testAFileWithNoMinimumReaderFallsBackToItsFormat() throws {
        // Every shipment written before this field existed.
        let old = try decode(manifest(shipment: 2, minimumReader: nil))
        XCTAssertNil(old.minimumReader)
        XCTAssertEqual(old.minimumReader ?? old.shipment, 2)
    }

    func testEveryFieldAddedSinceV2IsOptional() throws {
        // The rule that keeps old shipments readable: a manifest carrying
        // only what v2 wrote must still decode. If this fails, something
        // non-optional was added and every existing .mslship just became
        // unopenable.
        let v2 = try decode(manifest(shipment: 2, minimumReader: nil))
        XCTAssertNil(v2.id)
        XCTAssertNil(v2.parent)
        XCTAssertNil(v2.host)
        XCTAssertNil(v2.appearance)
    }
}

/// Provenance: what a shipment can tell you about where it came from.
final class ShipmentProvenanceTests: XCTestCase {

    func testLineageRoundTrips() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ship-lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        XCTAssertNil(ShipmentLineage.parent(of: "Fresh", appSupport: support))
        ShipmentLineage.record(shipmentID: "abc-123", instance: "Fresh", appSupport: support)
        XCTAssertEqual(ShipmentLineage.parent(of: "Fresh", appSupport: support), "abc-123")
        ShipmentLineage.forget(instance: "Fresh", appSupport: support)
        XCTAssertNil(ShipmentLineage.parent(of: "Fresh", appSupport: support))
    }

    func testAnInstanceWithNoHistoryRecordsNothing() {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ship-lineage-\(UUID().uuidString)")
        // An instance that was never installed from a shipment has no
        // parent, and recording an empty one must not invent a file.
        ShipmentLineage.record(shipmentID: nil, instance: "Fresh", appSupport: support)
        ShipmentLineage.record(shipmentID: "", instance: "Fresh", appSupport: support)
        XCTAssertNil(ShipmentLineage.parent(of: "Fresh", appSupport: support))
    }

    func testTheHostArchitectureIsReal() {
        // Recorded so somebody knows before unpacking fifteen gigabytes
        // that an arm64 filesystem is not going to boot on anything else.
        let arch = Shipment.hostArchitecture()
        XCTAssertFalse(arch.isEmpty)
        XCTAssertNotEqual(arch, "unknown")
    }
}

/// An appearance that travels without breaking.
final class ShipmentAppearanceTests: XCTestCase {
    func testAnImportedPictureDoesNotTravel() {
        // `image` names a file in this Mac's logos directory, which a
        // shipment does not carry. Sent as-is it would point at nothing on
        // the other Mac - and a broken image reads as a bug, where a plain
        // badge reads as a choice.
        let withPicture = InstanceAppearance(symbol: "sailboat", tint: "blue", image: "logo.png")
        let travelling = withPicture.withoutImportedImage
        XCTAssertNil(travelling.image)
        XCTAssertEqual(travelling.symbol, "sailboat")
        XCTAssertEqual(travelling.tint, "blue")
    }
}
