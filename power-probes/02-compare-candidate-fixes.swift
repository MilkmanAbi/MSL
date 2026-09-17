import AppKit
import Foundation
// Two candidate fixes, in the confirmed-vulnerable shape from probe7.
//   FIX A (pump-wait): handler waits for actionInFlight to clear, then exits.
//   FIX B (defer-exit): handler records "exit when the response finishes"
//                       and RETURNS, letting the nested outer frame proceed.
let mode = CommandLine.arguments.dropFirst().first ?? "A"
let start = Date()
func stamp(_ s: String) { print(String(format: "[%.2fs] ", Date().timeIntervalSince(start)) + s); fflush(stdout) }

let lock = NSLock()
var actionInFlight = false
var exitWhenResponseFinishes = false
var terminating = false
var pausedAndSaved = false

signal(SIGTERM, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
src.setEventHandler {
    lock.lock()
    if terminating { lock.unlock(); return }
    terminating = true
    let inFlight = actionInFlight
    if inFlight && mode == "B" { exitWhenResponseFinishes = true }
    lock.unlock()
    stamp(">>> SIGTERM handler entered (nested), actionInFlight=\(inFlight)")

    if mode == "A" {
        stamp("    FIX A: pump-waiting up to 5s for the response to clear...")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock(); let done = !actionInFlight; lock.unlock()
            if done { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        lock.lock(); let still = actionInFlight; lock.unlock()
        stamp("    FIX A result: after waiting, actionInFlight=\(still), pausedAndSaved=\(pausedAndSaved)")
        stamp("    FIX A would now exit(0). Work completed? \(pausedAndSaved)")
        exit(pausedAndSaved ? 0 : 3)
    } else {
        stamp("    FIX B: recorded exit-when-done, RETURNING so the response can proceed")
    }
}
src.resume()

func runResponse() {
    stamp("respond() entered from a run-loop callout")
    lock.lock(); actionInFlight = true; lock.unlock()
    Thread { Thread.sleep(forTimeInterval: 1.0); stamp("launchd sends SIGTERM"); kill(getpid(), SIGTERM) }.start()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let tickEnds = Date().addingTimeInterval(0.25)
        RunLoop.current.run(mode: .default, before: tickEnds)
        let r = tickEnds.timeIntervalSinceNow; if r > 0 { Thread.sleep(forTimeInterval: r) }
    }
    stamp("GUI grace over -> pausing + saving")
    Thread.sleep(forTimeInterval: 0.5)          // stands in for pause + save
    pausedAndSaved = true
    stamp("PAUSE + SAVE COMPLETED")
    lock.lock(); actionInFlight = false; let shouldExit = exitWhenResponseFinishes; lock.unlock()
    if shouldExit { stamp("respond() cleanup: termination was requested - exiting now"); exit(0) }
    stamp("respond() finished normally"); exit(0)
}
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in runResponse() }
let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.run()
