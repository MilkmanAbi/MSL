import Foundation
import Virtualization

/// Runs the memory balloon for one instance.
///
/// The division of labour is deliberate: `BalloonController` decides, this
/// drives. Everything with a clock, a socket or a VM in it lives here, and
/// everything with a judgement in it lives there - which is what lets the
/// judgement be tested without a guest.
///
/// **Cost when nothing is happening.** The whole point of dynamic mode is
/// to be invisible, so the cadence backs off on its own: a poll is one
/// vsock round trip and a read of two small `/proc` files, and after a few
/// cycles in which nothing needed changing the interval widens from 10
/// seconds to a minute. It narrows again the moment anything moves, and the
/// host's own memory-pressure notification interrupts the wait outright
/// rather than being discovered up to a minute late.
public final class BalloonGovernor {
    /// What the governor is doing, for the UI to show.
    public struct State: Equatable, Sendable {
        public enum Availability: Equatable, Sendable {
            case active
            /// The guest has no `memd` - an image built before it existed.
            /// The instance keeps its full ceiling.
            case guestAgentMissing
            case notStarted

            public var wireName: String {
                switch self {
                case .active: return "active"
                case .guestAgentMissing: return "agent-missing"
                case .notStarted: return "not-started"
                }
            }

            public init?(wireName: String) {
                switch wireName {
                case "active": self = .active
                case "agent-missing": self = .guestAgentMissing
                case "not-started": self = .notStarted
                default: return nil
                }
            }
        }
        public var availability: Availability = .notStarted

        public var target: UInt64?
        public var guestTotalBytes: UInt64?
        public var guestInUseBytes: UInt64?
        public var stallPercent: Double?
        public var guestHasSwap = false
        public var lastReason: BalloonDecision.Reason?
        public var lastChange: Date?
        public var adjustments = 0

        public init() {}

        /// Encodes to one `key=value` line for the daemon's text protocol.
        ///
        /// Absent fields are omitted rather than sent as zero: a guest that
        /// has not answered yet has *no* figures, which is a different thing
        /// from having none free, and the UI needs to tell those apart.
        ///
        /// `reason` is emitted last and is the only value containing spaces,
        /// so the decoder can take everything after `reason=` verbatim. That
        /// is a real constraint, not a convention - see `fromWireLine`.
        public var wireLine: String {
            var fields = ["availability=\(availability.wireName)", "adjustments=\(adjustments)"]
            if let target { fields.append("target=\(target)") }
            if let guestTotalBytes { fields.append("total=\(guestTotalBytes)") }
            if let guestInUseBytes { fields.append("inuse=\(guestInUseBytes)") }
            if let stallPercent { fields.append("stall=\(stallPercent)") }
            if guestHasSwap { fields.append("swap=1") }
            if let lastReason { fields.append("reason=\(BalloonGovernor.describe(lastReason))") }
            return fields.joined(separator: " ")
        }

        /// The inverse. Unknown keys are ignored so an older client talking
        /// to a newer daemon degrades instead of failing.
        ///
        /// Returns the decoded state and, separately, the reason *text* -
        /// which cannot round-trip into a `BalloonDecision.Reason` because
        /// it is prose meant for a person, and inventing a case for it would
        /// be pretending otherwise.
        public static func fromWireLine(_ line: String) -> (state: State, reasonText: String?) {
            var state = State()
            var reasonText: String?
            var body = line
            if let range = body.range(of: "reason=") {
                reasonText = String(body[range.upperBound...])
                body = String(body[..<range.lowerBound])
            }
            for field in body.split(separator: " ") {
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "availability": state.availability = Availability(wireName: value) ?? .notStarted
                case "target":       state.target = UInt64(value)
                case "total":        state.guestTotalBytes = UInt64(value)
                case "inuse":        state.guestInUseBytes = UInt64(value)
                case "stall":        state.stallPercent = Double(value)
                case "swap":         state.guestHasSwap = value == "1"
                case "adjustments":  state.adjustments = Int(value) ?? 0
                default:             break
                }
            }
            return (state, reasonText)
        }
    }

    private unowned let manager: VMManager
    private let bounds: BalloonBounds
    private var controller = BalloonController()
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var stateStorage = State()
    private let stateLock = NSLock()
    /// Consecutive polls that changed nothing, used to widen the interval.
    private var quietPolls = 0
    private var running = false

    /// Cadence. Fast enough that a guest under pressure waits seconds, slow
    /// enough that an idle instance is not a background CPU cost.
    private static let activeInterval: TimeInterval = 10
    private static let idleInterval: TimeInterval = 60
    private static let quietPollsBeforeBackingOff = 6

    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return stateStorage
    }

    init(manager: VMManager, bounds: BalloonBounds) {
        self.manager = manager
        self.bounds = bounds
        self.queue = DispatchQueue(label: "com.msl.balloon.\(manager.configuration.name)")
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true

            // Seed from the device rather than from the ceiling we think it
            // has. The framework sets the target to `configuration.memorySize`
            // on every fresh VM object, but a restored snapshot is not a
            // fresh guest, and trusting our own arithmetic here is how the
            // controller ends up steering from a position that never existed.
            manager.balloonTargetOnQueueAsync { [self] deviceTarget in
                queue.async { [self] in
                    controller.reset(to: deviceTarget ?? bounds.ceiling)
                    mutateState { $0.target = deviceTarget ?? bounds.ceiling }
                    scheduleTimer(after: 2)
                    watchHostPressure()
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel(); timer = nil
            pressureSource?.cancel(); pressureSource = nil
            mutateState { $0.availability = .notStarted }
        }
    }

    // MARK: - Loop

    private func scheduleTimer(after delay: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    /// The Mac telling us it is short of memory is worth acting on
    /// immediately - waiting out the rest of a 60-second idle interval is
    /// exactly the wrong behaviour at the one moment the guest's memory is
    /// most worth reclaiming.
    private func watchHostPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.quietPolls = 0
            self.scheduleTimer(after: 0)
        }
        pressureSource = source
        source.resume()
    }

    private func poll() {
        guard running else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.pollOnce()
        }
    }

    private func pollOnce() async {
        let client = MemoryClient(manager: manager)
        var guestSample: GuestMemorySample?
        var agentMissing = false
        do {
            guestSample = try await client.sample()
        } catch MemoryClient.MemoryClientError.unavailable {
            agentMissing = true
        } catch {
            // A transient failure (the guest is busy, mid-resume) is not the
            // same as an image with no agent: hold, and try again next tick.
            guestSample = nil
        }

        let hostSample = HostMemoryMonitor.sample()
        let now = Date()

        let decision: BalloonDecision? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard running else { continuation.resume(returning: nil); return }
                mutateState { state in
                    state.availability = agentMissing ? .guestAgentMissing : .active
                    state.guestTotalBytes = guestSample.map { $0.totalKB * 1024 }
                    // What the guest uses, not the balloon's pages - the raw
                    // figure showed the Resources card a guest "using" every
                    // byte the balloon had just taken from it.
                    state.guestInUseBytes = guestSample?.discountingBalloon().inUseBytes
                }
                mutateState {
                    $0.stallPercent = guestSample?.stallPercentAvg10
                    $0.guestHasSwap = (guestSample?.swapTotalKB ?? 0) > 0
                }
                continuation.resume(returning: controller.step(
                    guest: guestSample, host: hostSample, bounds: bounds, now: now))
            }
        }

        if let decision {
            // Compaction first, when asked for: the framework recommends it
            // so the pages being reclaimed are contiguous enough to actually
            // go back. It costs guest CPU, hence only before large reclaims.
            if decision.compactFirst { await client.compact() }

            let applied: Bool = await withCheckedContinuation { continuation in
                manager.setBalloonTarget(decision.target) { continuation.resume(returning: $0) }
            }
            queue.async { [self] in
                if applied {
                    mutateState {
                        $0.target = decision.target
                        $0.lastReason = decision.reason
                        $0.lastChange = now
                        $0.adjustments += 1
                    }
                    ActivityLog.shared.record(
                        .lifecycle, instance: manager.configuration.name,
                        "Memory \(Self.describe(decision.reason)) → \(decision.target / (1024 * 1024)) MB")
                }
                quietPolls = 0
                reschedule()
            }
        } else {
            queue.async { [self] in
                quietPolls += 1
                reschedule()
            }
        }
    }

    private func reschedule() {
        guard running else { return }
        let interval = quietPolls >= Self.quietPollsBeforeBackingOff
            ? Self.idleInterval : Self.activeInterval
        scheduleTimer(after: interval)
    }

    private func mutateState(_ change: (inout State) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        change(&stateStorage)
    }

    public static func describe(_ reason: BalloonDecision.Reason) -> String {
        switch reason {
        case .guestUnderPressure(let stall): return "raised (guest stalling \(String(format: "%.1f", stall))%)"
        case .guestDemandRose: return "raised"
        case .guestIdle: return "reclaimed (guest idle)"
        case .hostUnderPressure: return "reclaimed (Mac under pressure)"
        case .protectingGuest: return "raised (guest below its safe minimum)"
        }
    }
}
