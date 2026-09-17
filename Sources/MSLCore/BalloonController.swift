import Foundation

// MARK: - Samples

/// One reading of the guest's memory, as `memd` reports it.
///
/// Fields are the ones `/proc/meminfo` actually names, in kilobytes, because
/// translating them at the edge is where units get lost.
public struct GuestMemorySample: Equatable, Sendable {
    public let totalKB: UInt64
    /// The kernel's own estimate of what can still be allocated without
    /// swapping. Already includes reclaimable page cache.
    public let availableKB: UInt64
    public let freeKB: UInt64
    /// `Active(file)` + `Inactive(file)` - page cache. Reclaimable, but not
    /// free: taking all of it away is what turns a responsive guest into one
    /// that reads everything from disk twice.
    public let fileCacheKB: UInt64
    /// `Active(anon)` + `Inactive(anon)` - live heap. **Not** reclaimable:
    /// MSL's guests are built without swap (nothing in the provisioning
    /// path creates any), so an anonymous page has nowhere to go. Squeeze
    /// below this and the guest does not slow down, it OOM-kills.
    public let anonymousKB: UInt64
    /// PSI: percentage of the last 10 seconds in which at least one task
    /// stalled on memory. `nil` when the guest kernel has no
    /// `/proc/pressure/memory` - the controller is correct without it and
    /// merely slower to notice.
    public let stallPercentAvg10: Double?
    /// Reported so the no-swap assumption above can be checked rather than
    /// believed. Expected to be zero; if a user has added swap, the host can
    /// say so instead of quietly reasoning about a guest that no longer
    /// matches its own safety argument.
    public let swapTotalKB: UInt64
    /// Memory the balloon currently holds inside the guest, from
    /// `/proc/vmstat`'s `nr_balloon_pages`. `nil` from a `memd` that predates
    /// it - see `discountingBalloon()`.
    public let balloonKB: UInt64?
    public let capturedAt: Date

    public init(totalKB: UInt64, availableKB: UInt64, freeKB: UInt64,
                fileCacheKB: UInt64, anonymousKB: UInt64,
                swapTotalKB: UInt64 = 0,
                balloonKB: UInt64? = nil,
                stallPercentAvg10: Double?, capturedAt: Date) {
        self.swapTotalKB = swapTotalKB
        self.balloonKB = balloonKB
        self.totalKB = totalKB
        self.availableKB = availableKB
        self.freeKB = freeKB
        self.fileCacheKB = fileCacheKB
        self.anonymousKB = anonymousKB
        self.stallPercentAvg10 = stallPercentAvg10
        self.capturedAt = capturedAt
    }

    /// Memory the guest is using that cannot simply be handed back.
    ///
    /// `total - available` rather than `total - free`: the kernel's
    /// `MemAvailable` is the one number that already accounts for which
    /// caches and slabs it could actually reclaim under pressure.
    public var inUseBytes: UInt64 {
        (totalKB &- min(availableKB, totalKB)) * 1024
    }

    public var fileCacheBytes: UInt64 { fileCacheKB * 1024 }
    public var anonymousBytes: UInt64 { anonymousKB * 1024 }

    /// This sample with the balloon's own pages counted as available again.
    ///
    /// Linux only takes ballooned pages out of `MemTotal` when the device lacks
    /// `VIRTIO_BALLOON_F_DEFLATE_ON_OOM`. Virtualization.framework's balloon
    /// leaves `MemTotal` alone, so every page the balloon holds lowers
    /// `MemAvailable` and reads as the guest *using* it. The controller then
    /// saw its own reclaim as rising demand, gave the memory back, saw demand
    /// fall, reclaimed again - raise, reclaim, raise every 20 seconds, with
    /// "guest below its safe minimum" rescues in between (2026-09-14: an idle
    /// Debian guest using ~270 MB reported 1.69 GB "in use" at a 2.5 GB target).
    ///
    /// Measured, not inferred: the guest reports exactly how much the balloon
    /// holds (`nr_balloon_pages`), confirmed on a real guest to match the
    /// drop in `MemAvailable` with `MemTotal` unchanged and the device's
    /// DEFLATE_ON_OOM feature bit set. Inferring it from `MemTotal - target`
    /// was tried first and rejected: it can't tell a ballooned guest from a
    /// busy one, and getting that wrong squeezes a busy guest into the OOM
    /// killer. With no figure from the guest, nothing is discounted - exactly
    /// the behaviour before this existed.
    ///
    /// A kernel that *does* take ballooned pages out of `MemTotal` also
    /// reports them here; discounting them there would count them twice, so
    /// the discount never raises availability beyond `MemTotal`.
    public func discountingBalloon() -> GuestMemorySample {
        guard let balloonKB, balloonKB > 0 else { return self }
        return GuestMemorySample(
            totalKB: totalKB,
            availableKB: min(totalKB, availableKB + balloonKB),
            freeKB: min(totalKB, freeKB + balloonKB),
            fileCacheKB: fileCacheKB,
            anonymousKB: anonymousKB,
            swapTotalKB: swapTotalKB,
            balloonKB: 0,
            stallPercentAvg10: stallPercentAvg10,
            capturedAt: capturedAt)
    }
}

/// What the Mac itself has left. Advisory only.
///
/// macOS's "free memory" is close to meaningless with the compressor in
/// play, so this steers the controller rather than commanding it: the
/// pressure *level*, which the kernel publishes deliberately, is trusted;
/// the byte counts are used only to decide whether growing is polite.
public struct HostMemorySample: Equatable, Sendable {
    public enum Pressure: Int, Comparable, Sendable {
        case normal = 0, warning = 1, critical = 2
        public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
    }

    public let physical: UInt64
    /// Free + purgeable + inactive, as `host_statistics64` reports it.
    public let availableBytes: UInt64
    public let pressure: Pressure
    public let capturedAt: Date

    public init(physical: UInt64, availableBytes: UInt64, pressure: Pressure, capturedAt: Date) {
        self.physical = physical
        self.availableBytes = availableBytes
        self.pressure = pressure
        self.capturedAt = capturedAt
    }
}

// MARK: - Tuning

/// Every constant the controller uses, in one place and injectable.
///
/// Named rather than inline so the scenario tests can state which knob they
/// are exercising, and so a future change is a change to a number here
/// instead of an archaeological dig through the arithmetic.
public struct BalloonTuning: Equatable, Sendable {
    /// Granularity of a change. The framework requires whole megabytes; this
    /// is deliberately coarser so the guest is not re-ballooned over noise.
    public var quantum: UInt64 = 16 * 1024 * 1024
    /// Ignore any adjustment smaller than this. Must be >= `quantum`, or the
    /// controller emits changes that quantise back to where they started and
    /// does so forever.
    public var deadband: UInt64 = 64 * 1024 * 1024
    /// Free space kept above what the guest is using, so an allocation does
    /// not have to wait for a balloon round-trip.
    public var minimumHeadroom: UInt64 = 192 * 1024 * 1024
    /// Headroom also scales with the guest's own size: a 6 GB workload wants
    /// more slack than a 600 MB one.
    public var headroomFraction: Double = 0.25
    /// Page cache worth protecting even when the guest is otherwise idle.
    public var minimumCacheReserve: UInt64 = 128 * 1024 * 1024
    /// Never leave the guest less than this above its unreclaimable pages.
    /// Without swap this is the difference between slow and OOM-killed.
    public var oomSafetyMargin: UInt64 = 128 * 1024 * 1024
    /// Stall percentage above which the guest is treated as actively hurting.
    public var stallActionThreshold: Double = 1.0
    /// A sample older than this is not acted on.
    public var maximumSampleAge: TimeInterval = 15
    /// Growing is urgent; shrinking is not. These are the minimum intervals
    /// between two applied changes in each direction.
    public var minimumGrowInterval: TimeInterval = 2
    public var minimumShrinkInterval: TimeInterval = 30
    /// Fraction of the gap closed per shrink step, so the guest is
    /// approached rather than yanked.
    public var shrinkStepFraction: Double = 0.5
    /// Weight of the newest sample in the demand average used for shrinking.
    /// Low, so a momentarily quiet guest does not lose its memory.
    public var demandSmoothing: Double = 0.25
    /// Host memory left alone when deciding whether the guest may grow.
    public var hostReserve: UInt64 = 2 * 1024 * 1024 * 1024
    /// Compaction costs guest CPU, so it is only worth asking for before a
    /// substantial inflate.
    public var compactionThreshold: UInt64 = 256 * 1024 * 1024

    public init() {}
}

/// The range the balloon may move in, in bytes.
public struct BalloonBounds: Equatable, Sendable {
    /// Never target below this - the user's chosen minimum.
    public let floor: UInt64
    /// `VZVirtualMachineConfiguration.memorySize`. The framework rejects any
    /// target above it; there is no way to give a running guest more.
    public let ceiling: UInt64

    public init(floor: UInt64, ceiling: UInt64) {
        self.ceiling = ceiling
        self.floor = min(floor, ceiling)
    }
}

// MARK: - Decision

public struct BalloonDecision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case guestUnderPressure(stallPercent: Double)
        case guestDemandRose
        case guestIdle
        case hostUnderPressure
        /// The guest is below its own safety floor - only ever grows.
        case protectingGuest
    }

    public let target: UInt64
    public let reason: Reason
    /// Ask the guest to compact first. Only set for large inflates: the
    /// framework recommends it for balloon effectiveness, but it is real
    /// guest CPU and this system is supposed to be cheap.
    public let compactFirst: Bool
}

// MARK: - Controller

/// Decides how much memory the guest should have.
///
/// Deliberately pure: no clock, no I/O, no Virtualization types. Every
/// input is a parameter and the only mutable state is the demand average,
/// which means the interesting behaviour - does it thrash? does it shrink a
/// busy guest? does it starve one when the agent goes away? - is settled by
/// tests rather than by watching a VM and hoping.
///
/// The shape of the policy, in one paragraph: work out what the guest
/// actually needs (unreclaimable pages, plus a slice of page cache worth
/// keeping, plus headroom), raise that if the guest reports it is stalling,
/// cap it by what the host can spare, clamp it into the user's range, and
/// then apply it *asymmetrically* - grow at once, shrink slowly and only
/// part of the way. Growing late is a stall; shrinking late costs nothing.
public struct BalloonController: Sendable {
    public var tuning: BalloonTuning
    /// Smoothed demand, used only for shrink decisions.
    private var smoothedDemand: Double?
    private var lastAppliedAt: Date?
    private var lastTarget: UInt64?

    public init(tuning: BalloonTuning = BalloonTuning()) {
        self.tuning = tuning
    }

    /// The current target, as far as this controller knows.
    public var currentTarget: UInt64? { lastTarget }

    /// The guest's hard requirement: what it would OOM below.
    ///
    /// Anonymous pages have nowhere to go without swap, so they are the real
    /// floor; `inUse` is used when it is larger, since it also covers kernel
    /// allocations that are not anonymous but are equally unreclaimable.
    public func safeMinimum(for guest: GuestMemorySample) -> UInt64 {
        max(guest.anonymousBytes, guest.inUseBytes) + tuning.oomSafetyMargin
    }

    /// What the guest would ideally have right now, before any smoothing,
    /// host capping or clamping.
    public func idealTarget(for guest: GuestMemorySample) -> UInt64 {
        let inUse = guest.inUseBytes

        // A slice of page cache worth keeping. `MemAvailable` counts cache as
        // available, so without this the controller would happily shrink a
        // guest until every cached page was gone - which does not show up as
        // memory pressure, it shows up as everything reading from disk again.
        let cacheReserve = min(guest.fileCacheBytes,
                               max(tuning.minimumCacheReserve, inUse / 4))

        let headroom = max(tuning.minimumHeadroom,
                           UInt64(Double(inUse) * tuning.headroomFraction))

        var ideal = inUse + cacheReserve + headroom

        // The guest says it is stalling on memory. Believe it over the
        // arithmetic: PSI measures actual time lost, which is the thing we
        // are trying to prevent, whereas everything above is an estimate of
        // what might prevent it.
        if let stall = guest.stallPercentAvg10, stall > tuning.stallActionThreshold {
            let severity = min(stall / 100.0, 1.0)
            ideal += max(tuning.minimumHeadroom, UInt64(Double(inUse) * severity))
        }
        return ideal
    }

    /// One control step. Returns `nil` to hold - which is always the safe
    /// answer, and is what happens on a stale sample, a small change, or a
    /// rate limit.
    public mutating func step(
        guest: GuestMemorySample?,
        host: HostMemorySample?,
        bounds: BalloonBounds,
        now: Date
    ) -> BalloonDecision? {
        // No agent, or a reading too old to trust. Hold at whatever we last
        // asked for. Guessing here is how a guest gets OOM-killed by its own
        // memory manager, and there is no swap to soften it.
        guard let guest, now.timeIntervalSince(guest.capturedAt) <= tuning.maximumSampleAge else {
            return nil
        }

        let current = lastTarget ?? bounds.ceiling
        // What the guest itself uses, not counting the balloon's own pages -
        // see `discountingBalloon`. Every judgement below is made on this.
        let sample = guest.discountingBalloon()
        let safeMinimum = clamp(safeMinimum(for: sample), bounds)

        // The guest is already below what it can survive on - this can happen
        // after a host-pressure shrink that the workload then grew into.
        // Nothing else in this function may override this.
        if current < safeMinimum {
            return apply(target: safeMinimum, from: current, reason: .protectingGuest, now: now, force: true)
        }

        let ideal = idealTarget(for: sample)
        smoothedDemand = smoothedDemand.map {
            $0 * (1 - tuning.demandSmoothing) + Double(ideal) * tuning.demandSmoothing
        } ?? Double(ideal)

        // --- Growing.
        if ideal > current + tuning.deadband {
            guard allowed(direction: .grow, now: now) else { return nil }
            var target = clamp(ideal, bounds)

            // Only take from the host what it can spare. The pressure level
            // is trusted; the byte figure is treated as a hint.
            if let host {
                if host.pressure >= .warning {
                    target = current            // hold, do not grow into a struggling Mac
                } else {
                    let spare = host.availableBytes > tuning.hostReserve
                        ? host.availableBytes - tuning.hostReserve : 0
                    target = min(target, current + spare)
                }
            }
            target = max(target, safeMinimum)
            guard target > current + tuning.deadband else { return nil }

            let reason: BalloonDecision.Reason
            if let stall = guest.stallPercentAvg10, stall > tuning.stallActionThreshold {
                reason = .guestUnderPressure(stallPercent: stall)
            } else {
                reason = .guestDemandRose
            }
            return apply(target: target, from: current, reason: reason, now: now)
        }

        // --- Host is struggling. Shrink even though the guest is content,
        // but never past what the guest needs to stay alive.
        if let host, host.pressure >= .critical, current > safeMinimum + tuning.deadband {
            guard allowed(direction: .shrink, now: now) else { return nil }
            let step = UInt64(Double(current - safeMinimum) * tuning.shrinkStepFraction)
            let target = clamp(max(current - step, safeMinimum), bounds)
            guard current > target + tuning.deadband else { return nil }
            return apply(target: target, from: current, reason: .hostUnderPressure, now: now)
        }

        // --- Shrinking, off the smoothed figure so a momentary lull does not
        // cost the guest its memory, and only part of the way each time.
        let demand = UInt64(smoothedDemand ?? Double(ideal))
        if demand + tuning.deadband < current {
            guard allowed(direction: .shrink, now: now) else { return nil }
            let gap = current - max(demand, safeMinimum)
            let step = UInt64(Double(gap) * tuning.shrinkStepFraction)
            let target = clamp(max(current - step, max(demand, safeMinimum)), bounds)
            guard current > target + tuning.deadband else { return nil }
            return apply(target: target, from: current, reason: .guestIdle, now: now)
        }

        return nil
    }

    /// Seed the controller with the target the device actually has, which
    /// the framework sets to `configuration.memorySize` on every fresh VM.
    public mutating func reset(to target: UInt64) {
        lastTarget = target
        smoothedDemand = nil
        lastAppliedAt = nil
    }

    // MARK: - Internals

    private enum Direction { case grow, shrink }

    private func allowed(direction: Direction, now: Date) -> Bool {
        guard let last = lastAppliedAt else { return true }
        let minimum = direction == .grow ? tuning.minimumGrowInterval : tuning.minimumShrinkInterval
        return now.timeIntervalSince(last) >= minimum
    }

    private func clamp(_ value: UInt64, _ bounds: BalloonBounds) -> UInt64 {
        min(max(value, bounds.floor), bounds.ceiling)
    }

    /// Quantise and record. Grows round up and shrinks round down, so
    /// rounding always errs in the guest's favour.
    private mutating func apply(
        target: UInt64, from current: UInt64,
        reason: BalloonDecision.Reason, now: Date, force: Bool = false
    ) -> BalloonDecision? {
        let quantum = max(tuning.quantum, 1024 * 1024)
        let growing = target > current
        let quantised = growing
            ? ((target + quantum - 1) / quantum) * quantum
            : (target / quantum) * quantum

        guard force || quantised != current else { return nil }
        lastTarget = quantised
        lastAppliedAt = now
        return BalloonDecision(
            target: quantised,
            reason: reason,
            compactFirst: !growing && current - quantised >= tuning.compactionThreshold)
    }
}
