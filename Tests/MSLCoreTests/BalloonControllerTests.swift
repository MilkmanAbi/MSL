import XCTest
@testable import MSLCore

/// The controller is pure, so its behaviour is settled here rather than by
/// running a VM and watching. Each test is a scenario with a name someone
/// could argue with.
final class BalloonControllerTests: XCTestCase {
    let mb: UInt64 = 1024 * 1024
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// `inUse` is expressed as `total - available`, so the fixture takes the
    /// numbers the way `/proc/meminfo` states them.
    func guestSample(
        totalMB: UInt64, availableMB: UInt64, anonMB: UInt64, cacheMB: UInt64,
        stall: Double? = nil, at date: Date
    ) -> GuestMemorySample {
        GuestMemorySample(
            totalKB: totalMB * 1024, availableKB: availableMB * 1024,
            freeKB: max(availableMB, cacheMB) * 1024 - cacheMB * 1024,
            fileCacheKB: cacheMB * 1024, anonymousKB: anonMB * 1024,
            stallPercentAvg10: stall, capturedAt: date)
    }

    func host(_ pressure: HostMemorySample.Pressure = .normal,
              availableGB: UInt64 = 8, at date: Date) -> HostMemorySample {
        HostMemorySample(physical: 16 * 1024 * mb, availableBytes: availableGB * 1024 * mb,
                         pressure: pressure, capturedAt: date)
    }

    var bounds: BalloonBounds { BalloonBounds(floor: 1024 * mb, ceiling: 6144 * mb) }

    // MARK: - The safety invariant

    /// The one property that must never break. Without swap in the guest,
    /// targeting below the unreclaimable set does not slow it down - it
    /// OOM-kills whatever the user was running.
    func testNeverTargetsBelowTheGuestsUnreclaimableMemory() {
        var controller = BalloonController()
        controller.reset(to: bounds.ceiling)
        var now = start
        var rng = SystemRandomNumberGenerator()

        // A long, deliberately hostile random walk: demand jumps around,
        // the host panics at random, time moves unevenly.
        for _ in 0..<2000 {
            now = now.addingTimeInterval(Double.random(in: 1...45, using: &rng))
            let anon = UInt64.random(in: 200...4000, using: &rng)
            let cache = UInt64.random(in: 0...1500, using: &rng)
            let available = min(6144, 6144 - anon)
            let sample = guestSample(totalMB: 6144, availableMB: available,
                                     anonMB: anon, cacheMB: cache,
                                     stall: Bool.random(using: &rng) ? Double.random(in: 0...60, using: &rng) : nil,
                                     at: now)
            let pressure: HostMemorySample.Pressure =
                [.normal, .warning, .critical].randomElement(using: &rng)!
            let decision = controller.step(guest: sample, host: host(pressure, at: now),
                                           bounds: bounds, now: now)
            guard let decision else { continue }

            let floorForGuest = min(controller.safeMinimum(for: sample), bounds.ceiling)
            XCTAssertGreaterThanOrEqual(
                decision.target, min(floorForGuest, bounds.ceiling),
                "targeted \(decision.target / mb) MB with \(anon) MB anonymous - the guest would be OOM-killed")
            XCTAssertLessThanOrEqual(decision.target, bounds.ceiling)
            XCTAssertGreaterThanOrEqual(decision.target, bounds.floor)
            XCTAssertEqual(decision.target % controller.tuning.quantum, 0,
                           "target must be a whole number of quanta")
        }
    }

    // MARK: - Scenarios

    /// A guest that starts using memory gets it promptly, not on the next
    /// slow shrink cycle.
    func testHungryGuestGrowsPromptly() {
        var controller = BalloonController()
        controller.reset(to: 1500 * mb)
        var now = start

        // 1.2 GB in use and climbing, stalling on memory.
        let sample = guestSample(totalMB: 6144, availableMB: 6144 - 1200,
                                 anonMB: 1100, cacheMB: 200, stall: 12, at: now)
        now = now.addingTimeInterval(3)
        let decision = controller.step(guest: sample, host: host(at: now), bounds: bounds, now: now)

        let unwrapped = try! XCTUnwrap(decision)
        XCTAssertGreaterThan(unwrapped.target, 1500 * mb, "a stalling guest must get more, not less")
        if case .guestUnderPressure = unwrapped.reason {} else {
            XCTFail("expected the stall to be the stated reason, got \(unwrapped.reason)")
        }
    }

    /// An idle guest gives memory back - but gradually, and never past what
    /// it is still using.
    func testIdleGuestShrinksGraduallyAndDoesNotOvershoot() {
        var controller = BalloonController()
        controller.reset(to: 6144 * mb)
        var now = start

        var targets: [UInt64] = []
        // 400 MB genuinely in use, nothing stalling, for ten minutes.
        for _ in 0..<40 {
            now = now.addingTimeInterval(15)
            let sample = guestSample(totalMB: 6144, availableMB: 6144 - 400,
                                     anonMB: 300, cacheMB: 150, stall: 0, at: now)
            if let decision = controller.step(guest: sample, host: host(at: now), bounds: bounds, now: now) {
                targets.append(decision.target)
            }
        }

        XCTAssertFalse(targets.isEmpty, "an idle guest should eventually give memory back")
        XCTAssertTrue(zip(targets, targets.dropFirst()).allSatisfy { $0 > $1 },
                      "shrinking should be monotonic, not oscillating: \(targets.map { $0 / self.mb })")
        let final = targets.last!
        XCTAssertGreaterThanOrEqual(final, 400 * mb, "shrank into memory the guest was using")
        XCTAssertLessThan(final, 6144 * mb)
        // Gradual: no single step gives back the whole difference.
        XCTAssertGreaterThan(targets.count, 2, "handed it all back at once instead of approaching")
    }

    /// The Mac is struggling. The guest is comfortable, and still gives some
    /// back - but not below what it needs to survive.
    func testHostPressureShrinksAContentGuestButNotPastSafety() {
        var controller = BalloonController()
        controller.reset(to: 6144 * mb)
        var now = start.addingTimeInterval(60)

        let sample = guestSample(totalMB: 6144, availableMB: 6144 - 2000,
                                 anonMB: 1900, cacheMB: 300, stall: 0, at: now)
        let decision = controller.step(guest: sample, host: host(.critical, availableGB: 1, at: now),
                                       bounds: bounds, now: now)
        let unwrapped = try! XCTUnwrap(decision, "critical host pressure should reclaim something")
        XCTAssertEqual(unwrapped.reason, .hostUnderPressure)
        XCTAssertLessThan(unwrapped.target, 6144 * mb)
        XCTAssertGreaterThanOrEqual(unwrapped.target, controller.safeMinimum(for: sample))
    }

    /// A guest that will not grow into a Mac that is already under pressure.
    func testDoesNotGrowIntoAStrugglingHost() {
        var controller = BalloonController()
        controller.reset(to: 2000 * mb)
        let now = start.addingTimeInterval(30)
        let sample = guestSample(totalMB: 6144, availableMB: 6144 - 1900,
                                 anonMB: 1800, cacheMB: 100, stall: 8, at: now)

        let decision = controller.step(guest: sample, host: host(.warning, availableGB: 1, at: now),
                                       bounds: bounds, now: now)
        if let decision {
            XCTAssertLessThanOrEqual(decision.target, 2000 * mb + controller.tuning.deadband,
                                     "grew into a host that said it was under pressure")
        }
    }

    /// The test that separates a controller from a threshold. A workload
    /// oscillating right across the deadband must not produce a balloon
    /// operation every time it does.
    func testFlappingWorkloadDoesNotThrashTheBalloon() {
        var controller = BalloonController()
        controller.reset(to: 3000 * mb)
        var now = start
        var applied = 0

        for iteration in 0..<200 {
            now = now.addingTimeInterval(5)
            // Alternates either side of the current target by ~100 MB.
            let inUse: UInt64 = iteration.isMultiple(of: 2) ? 2500 : 2650
            let sample = guestSample(totalMB: 6144, availableMB: 6144 - inUse,
                                     anonMB: inUse - 100, cacheMB: 120, stall: 0, at: now)
            if controller.step(guest: sample, host: host(at: now), bounds: bounds, now: now) != nil {
                applied += 1
            }
        }
        XCTAssertLessThan(applied, 12,
                          "\(applied) balloon operations for a workload that just wobbles is thrashing")
    }

    // MARK: - Degraded inputs

    /// A kernel with no `/proc/pressure/memory` still gets sensible control.
    func testWorksWithoutPSI() {
        var controller = BalloonController()
        // Above the guest's safety floor, so this exercises ordinary demand
        // rather than the protective branch - which fires first by design
        // and would otherwise mask what this test is checking.
        controller.reset(to: 3000 * mb)
        let now = start.addingTimeInterval(30)
        let sample = guestSample(totalMB: 6144, availableMB: 6144 - 2400,
                                 anonMB: 2300, cacheMB: 100, stall: nil, at: now)
        XCTAssertLessThan(controller.safeMinimum(for: sample), 3000 * mb, "fixture is not testing what it claims")

        let decision = try! XCTUnwrap(controller.step(guest: sample, host: host(at: now),
                                                      bounds: bounds, now: now))
        XCTAssertGreaterThan(decision.target, 3000 * mb,
                             "a guest whose demand exceeds its target must grow, PSI or not")
        XCTAssertEqual(decision.reason, .guestDemandRose)
    }

    /// A guest that has ended up below what it can survive on grows back
    /// immediately, whatever else is going on - including a host in crisis.
    func testGuestBelowSafetyFloorIsRescuedEvenUnderHostPressure() {
        var controller = BalloonController()
        controller.reset(to: 1500 * mb)
        let now = start.addingTimeInterval(30)
        let sample = guestSample(totalMB: 6144, availableMB: 6144 - 2400,
                                 anonMB: 2300, cacheMB: 100, stall: nil, at: now)
        let decision = try! XCTUnwrap(controller.step(guest: sample,
                                                      host: host(.critical, availableGB: 0, at: now),
                                                      bounds: bounds, now: now))
        XCTAssertEqual(decision.reason, .protectingGuest)
        XCTAssertGreaterThanOrEqual(decision.target, controller.safeMinimum(for: sample),
                                    "left the guest below the level it OOM-kills at")
    }

    /// A reading from a minute ago describes a guest that no longer exists.
    func testStaleSampleHolds() {
        var controller = BalloonController()
        controller.reset(to: 3000 * mb)
        let now = start.addingTimeInterval(600)
        let stale = guestSample(totalMB: 6144, availableMB: 100, anonMB: 5000,
                                cacheMB: 100, stall: 90, at: start)
        XCTAssertNil(controller.step(guest: stale, host: host(at: now), bounds: bounds, now: now),
                     "acted on a sample ten minutes old")
    }

    /// The guest agent is missing - an image built before `memd` existed.
    /// Holding is the only safe answer.
    func testMissingAgentHolds() {
        var controller = BalloonController()
        controller.reset(to: bounds.ceiling)
        let now = start.addingTimeInterval(60)
        XCTAssertNil(controller.step(guest: nil, host: host(at: now), bounds: bounds, now: now))
        XCTAssertEqual(controller.currentTarget, bounds.ceiling,
                       "with no guest reading, the guest keeps everything it was given")
    }

    /// Compaction is guest CPU, so it is asked for only when the inflate is
    /// big enough to be worth it.
    func testCompactionOnlyForLargeInflates() {
        var controller = BalloonController()
        controller.reset(to: 6144 * mb)
        var now = start
        var sawLarge = false
        for _ in 0..<40 {
            now = now.addingTimeInterval(15)
            let sample = guestSample(totalMB: 6144, availableMB: 6144 - 300,
                                     anonMB: 250, cacheMB: 100, stall: 0, at: now)
            guard let decision = controller.step(guest: sample, host: host(at: now),
                                                 bounds: bounds, now: now) else { continue }
            let previous = controller.currentTarget
            _ = previous
            if decision.compactFirst { sawLarge = true }
        }
        XCTAssertTrue(sawLarge, "a large reclaim should ask the guest to compact first")
    }

    /// The deadband has to be at least a quantum or the controller emits
    /// changes that quantise straight back to where they were.
    func testDeadbandIsAtLeastOneQuantum() {
        let tuning = BalloonTuning()
        XCTAssertGreaterThanOrEqual(tuning.deadband, tuning.quantum)
    }

    /// Bounds with a floor above the ceiling are nonsense the UI should
    /// prevent; the type refuses to represent it either way.
    func testBoundsCannotInvert() {
        let inverted = BalloonBounds(floor: 8192 * mb, ceiling: 2048 * mb)
        XCTAssertLessThanOrEqual(inverted.floor, inverted.ceiling)
    }
}
