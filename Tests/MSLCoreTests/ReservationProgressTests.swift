import XCTest
@testable import MSLCore

final class ReservationProgressTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testFractionAndTimeLeft() {
        let started = Date(timeIntervalSinceNow: -10)
        let progress = DiskStorage.ReservationProgress(written: 16 * gib, total: 64 * gib, started: started)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        // 16 GB in 10 s leaves 48 GB, about 30 s.
        XCTAssertEqual(progress.secondsRemaining()!, 30, accuracy: 1)
    }

    func testNoEstimateBeforeThereIsAPace() {
        let progress = DiskStorage.ReservationProgress(written: 0, total: 64 * gib, started: Date())
        XCTAssertNil(progress.secondsRemaining())
    }

    /// The progress reported walks the file's holes and ends at exactly 100%,
    /// with the whole file really allocated afterwards.
    func testReservingReportsProgressUpToTheWholeDisk() throws {
        let path = NSTemporaryDirectory() + "msl-reserve-\(UUID().uuidString).img"
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: nil)
        let size: UInt64 = 64 << 20
        try DiskStorage.setCapacity(of: path, to: size, reserveSpace: false)

        var updates: [DiskStorage.ReservationProgress] = []
        try DiskStorage.setCapacity(of: path, to: size, reserveSpace: true) { updates.append($0) }
        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates.last?.fraction, 1)
        XCTAssertFalse(DiskStorage.isSparse(path))
    }
}
