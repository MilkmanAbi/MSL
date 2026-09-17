import XCTest
@testable import MSLCore

/// The balloon's own pages must not read as the guest's demand.
///
/// On Virtualization.framework the balloon negotiates DEFLATE_ON_OOM, so the
/// guest's `MemTotal` stays put while the balloon inflates and the pages it
/// takes lower `MemAvailable`. Read naively, every reclaim looked like demand
/// rising, and an idle guest was reclaimed, raised and reclaimed again every
/// 20 seconds (measured 2026-09-14: `nr_balloon_pages` 393216 on a guest the
/// host thought was using 1.7 GiB). These tests close that loop in
/// simulation: the guest's figures are recomputed from the target the
/// controller last chose, the way the real guest's are.
final class BalloonSelfFeedbackTests: XCTestCase {
    private let mib: UInt64 = 1024 * 1024
    private var bounds: BalloonBounds { BalloonBounds(floor: 1024 * mib, ceiling: 4096 * mib) }

    /// A guest really using `usedMiB`, reporting as Linux does with
    /// DEFLATE_ON_OOM: MemTotal fixed, the balloon's pages counted as used.
    /// `reportsBalloon` is whether its memd sends `nr_balloon_pages`.
    private func guest(target: UInt64, usedMiB: UInt64, reportsBalloon: Bool, at now: Date) -> GuestMemorySample {
        let memTotal = bounds.ceiling - 94 * mib            // what the kernel keeps back, measured
        let balloon = bounds.ceiling - target
        let used = usedMiB * mib
        let available = memTotal > used + balloon ? memTotal - used - balloon : 0
        return GuestMemorySample(
            totalKB: memTotal / 1024, availableKB: available / 1024, freeKB: available / 1024,
            fileCacheKB: 70 * 1024, anonymousKB: (usedMiB / 2) * 1024,
            balloonKB: reportsBalloon ? balloon / 1024 : nil,
            stallPercentAvg10: 0, capturedAt: now)
    }

    private func run(usedMiB: UInt64, reportsBalloon: Bool, steps: Int = 60)
        -> (targets: [UInt64], reasons: [BalloonDecision.Reason]) {
        var controller = BalloonController()
        controller.reset(to: bounds.ceiling)
        var target = bounds.ceiling
        var now = Date(timeIntervalSince1970: 1_000_000)
        var targets: [UInt64] = []
        var reasons: [BalloonDecision.Reason] = []
        for _ in 0..<steps {
            let sample = guest(target: target, usedMiB: usedMiB, reportsBalloon: reportsBalloon, at: now)
            if let decision = controller.step(guest: sample, host: nil, bounds: bounds, now: now) {
                target = decision.target
                targets.append(target)
                reasons.append(decision.reason)
            }
            now = now.addingTimeInterval(10)
        }
        return (targets, reasons)
    }

    func testAnIdleGuestSettlesInsteadOfFlapping() {
        let (targets, reasons) = run(usedMiB: 150, reportsBalloon: true)
        XCTAssertFalse(reasons.contains(.protectingGuest), "the balloon's own pages triggered a rescue: \(reasons)")
        XCTAssertFalse(reasons.contains(.guestDemandRose), "the balloon's own pages read as rising demand: \(reasons)")
        for (earlier, later) in zip(targets, targets.dropFirst()) {
            XCTAssertLessThan(later, earlier, "the target went back up: \(targets.map { $0 / (1024 * 1024) })")
        }
        XCTAssertLessThan(targets.last ?? bounds.ceiling, 2048 * mib, "an idle 150 MiB guest should give most of 4 GiB back")
        XCTAssertGreaterThanOrEqual(targets.last ?? 0, bounds.floor)
    }

    func testTheOldReadingReallyDidFlap() {
        // The same guest with the balloon figure withheld is the bug as it was
        // measured: it must go back up at least once. If this ever stops
        // flapping, the simulation no longer models the real guest.
        let (targets, _) = run(usedMiB: 150, reportsBalloon: false)
        let wentBackUp = zip(targets, targets.dropFirst()).contains { $1 > $0 }
        XCTAssertTrue(wentBackUp, "expected the uncorrected controller to flap: \(targets.map { $0 / (1024 * 1024) })")
    }

    func testABusyGuestIsNeverSqueezedBelowWhatItUses() {
        let used: UInt64 = 3000
        let (targets, _) = run(usedMiB: used, reportsBalloon: true)
        for target in targets {
            XCTAssertGreaterThan(target, used * mib + BalloonTuning().oomSafetyMargin,
                                 "squeezed a guest using \(used) MiB to \(target / mib) MiB")
        }
    }

    func testNoBalloonFigureMeansNoDiscount() {
        let sample = guest(target: 2560 * mib, usedMiB: 150, reportsBalloon: false, at: Date())
        XCTAssertEqual(sample.discountingBalloon(), sample)
    }

    func testTheDiscountRecoversWhatTheGuestReallyUses() {
        let sample = guest(target: 2560 * mib, usedMiB: 150, reportsBalloon: true, at: Date())
        XCTAssertEqual(sample.discountingBalloon().inUseBytes / mib, 150)
    }

    func testTheDiscountNeverRaisesAvailabilityPastMemTotal() {
        let sample = GuestMemorySample(totalKB: 1_000_000, availableKB: 900_000, freeKB: 900_000,
                                       fileCacheKB: 0, anonymousKB: 0, balloonKB: 500_000,
                                       stallPercentAvg10: 0, capturedAt: Date())
        XCTAssertEqual(sample.discountingBalloon().availableKB, 1_000_000)
    }
}
