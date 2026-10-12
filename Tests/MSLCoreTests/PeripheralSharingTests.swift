import XCTest
@testable import MSLCore

/// Who is allowed to see the Mac's camera, and who decides.
final class PeripheralSharingTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-peripherals-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    func testNothingIsSharedByDefault() {
        let state = PeripheralSharing()
        XCTAssertFalse(state.isAnythingShared)
        for device in PeripheralSharing.Device.allCases {
            XCTAssertFalse(state.isShared(device, with: "Milk"))
        }
    }

    /// Sharing is per instance and per device: allowing a camera for one
    /// instance must not hand it to another.
    func testSharingIsPerInstanceAndPerDevice() {
        var state = PeripheralSharing()
        state.setShared(true, device: .camera, with: "Milk")
        XCTAssertTrue(state.isShared(.camera, with: "Milk"))
        XCTAssertFalse(state.isShared(.camera, with: "Other"))
        XCTAssertFalse(state.isShared(.microphone, with: "Milk"))
    }

    func testTurningOffRemovesIt() {
        var state = PeripheralSharing(camera: ["Milk"], microphone: ["Milk"])
        state.setShared(false, device: .camera, with: "Milk")
        XCTAssertFalse(state.isShared(.camera, with: "Milk"))
        XCTAssertTrue(state.isShared(.microphone, with: "Milk"))
    }

    /// The file is how `mslhd` and the helper agree while sharing is on.
    func testRoundTripsThroughTheFile() {
        var state = PeripheralSharing()
        state.setShared(true, device: .microphone, with: "Milk")
        XCTAssertTrue(PeripheralSharingStore.save(state, to: file))
        XCTAssertEqual(PeripheralSharingStore.load(from: file), state)
    }

    /// A camera that was on yesterday is not consent for today. Clearing is
    /// what the helper does as it quits, so a stale file can never leave the
    /// daemon believing a device is still allowed.
    func testClearingLeavesNothingShared() {
        var state = PeripheralSharing()
        state.setShared(true, device: .camera, with: "Milk")
        PeripheralSharingStore.save(state, to: file)
        PeripheralSharingStore.clear(to: file)
        XCTAssertFalse(PeripheralSharingStore.load(from: file).isAnythingShared)
    }

    /// A missing or damaged file means "nothing is shared", never "assume
    /// yes" - the safe direction for a privacy switch.
    func testUnreadableFileSharesNothing() {
        XCTAssertFalse(PeripheralSharingStore.load(from: file).isAnythingShared)
        try? "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(PeripheralSharingStore.load(from: file).isAnythingShared)
    }

    /// Both devices explain themselves before macOS's own prompt appears.
    func testEveryDeviceExplainsItself() {
        for device in PeripheralSharing.Device.allCases {
            XCTAssertFalse(device.label.isEmpty)
            XCTAssertTrue(device.explanation.contains("macOS will ask"))
        }
    }
}
