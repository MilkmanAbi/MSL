import Foundation

/// Paint-pipeline counters, printed every 2 s when `MSL_X11_PERF=1`:
/// frames drawn, time spent in `draw(_:)`, damage notifications, and how
/// long a block waits for the main thread (everything - drawing requests,
/// input, compositing - funnels through it, so its lag is the frame budget
/// actually left). Off by default: one cached env lookup per call.
enum X11Perf {
    static let enabled = ProcessInfo.processInfo.environment["MSL_X11_PERF"] == "1"
    private static let lock = NSLock()
    private static var frames = 0, drawNanos: UInt64 = 0, maxDrawNanos: UInt64 = 0
    private static var notifies = 0, lagMaxMS = 0.0, lagSumMS = 0.0, lagSamples = 0
    private static var started = false

    static func frame(nanos: UInt64) {
        guard enabled else { return }
        lock.lock(); frames += 1; drawNanos += nanos; maxDrawNanos = max(maxDrawNanos, nanos); lock.unlock()
        startIfNeeded()
    }

    static func notified() {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        notifies += 1
        if pendingInput != 0 {
            let ms = Double(now - pendingInput) / 1e6
            latSum += ms; latMax = max(latMax, ms); latCount += 1
            pendingInput = 0
        }
        lock.unlock()
    }

    /// An input event just went to a client: the next damage notification
    /// closes the input -> guest -> requests -> paint loop.
    static func inputSent() {
        guard enabled else { return }
        lock.lock(); if pendingInput == 0 { pendingInput = DispatchTime.now().uptimeNanoseconds }; inputs += 1; lock.unlock()
    }
    /// A raw pointer event arrived from AppKit (before coalescing).
    static func pointerSeen() {
        guard enabled else { return }
        lock.lock(); seen += 1; lock.unlock()
    }
    private static var seen = 0
    private static var pendingInput: UInt64 = 0, latSum = 0.0, latMax = 0.0, latCount = 0, inputs = 0

    private static func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        Thread {
            var lastReport = Date()
            while true {
                let posted = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1e6
                    lock.lock(); lagMaxMS = max(lagMaxMS, ms); lagSumMS += ms; lagSamples += 1; lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.05)
                if Date().timeIntervalSince(lastReport) >= 2 {
                    lastReport = Date()
                    lock.lock()
                    let line = String(format: "[perf] fps=%.1f draw.avg=%.2fms draw.max=%.2fms notifies/s=%.0f mainLag.avg=%.1fms mainLag.max=%.1fms seen/s=%.0f inputs/s=%.0f input->paint.avg=%.1fms max=%.1fms",
                                      Double(frames) / 2, frames > 0 ? Double(drawNanos) / Double(frames) / 1e6 : 0,
                                      Double(maxDrawNanos) / 1e6, Double(notifies) / 2,
                                      lagSamples > 0 ? lagSumMS / Double(lagSamples) : 0, lagMaxMS,
                                      Double(seen) / 2, Double(inputs) / 2, latCount > 0 ? latSum / Double(latCount) : 0, latMax)
                    seen = 0; inputs = 0; latSum = 0; latMax = 0; latCount = 0
                    frames = 0; drawNanos = 0; maxDrawNanos = 0; notifies = 0; lagMaxMS = 0; lagSumMS = 0; lagSamples = 0
                    lock.unlock()
                    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
                }
            }
        }.start()
    }
}
