import AppKit
import Foundation

// Verbatim transcription of the PATCHED handleTerminationSignal + respond()
// cleanup from SystemResilienceMonitor.swift, driven through every ordering.
// Usage: probe9 <nested|lostrace|double|alreadysaved|sleeponly>
let scenario = CommandLine.arguments.dropFirst().first ?? "nested"
let start = Date()
func log(_ s: String) { print(String(format: "[%.2fs] ", Date().timeIntervalSince(start)) + "mslhd[power]: " + s); fflush(stdout) }

enum Response { case pauseOnly, pauseAndSave
    var label: String { self == .pauseOnly ? "suspending" : "hibernating" } }

let actionLock = NSLock()
var actionInFlight = false
var terminating = false
var exitWhenResponseFinishes = false

var guestsFrozen = false, guestsSaved = false
var instanceRunning = true

func respond(_ response: Response, reason: String) {
    actionLock.lock()
    if actionInFlight { actionLock.unlock(); log("\(reason): another power response is already running - not starting a second"); return }
    actionInFlight = true
    actionLock.unlock()
    defer {
        actionLock.lock()
        actionInFlight = false
        let shouldExit = exitWhenResponseFinishes
        actionLock.unlock()
        if shouldExit {
            log("\(reason): finished - exiting for the termination signal that arrived while it was running")
            verdict(); exit(0)
        }
    }
    guard instanceRunning else { log("\(reason): no running instances"); return }
    log("\(reason): \(response.label) 1 instance(s)")
    if response == .pauseAndSave {
        // waitForGUIHostsToExit: the pump, the one re-entrancy window
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            let tickEnds = Date().addingTimeInterval(0.25)
            RunLoop.current.run(mode: .default, before: tickEnds)
            let r = tickEnds.timeIntervalSinceNow; if r > 0 { Thread.sleep(forTimeInterval: r) }
        }
    }
    Thread.sleep(forTimeInterval: 0.3); guestsFrozen = true; log("\(reason): froze every instance")
    guard response == .pauseAndSave else { return }
    Thread.sleep(forTimeInterval: 0.4); guestsSaved = true; instanceRunning = false; log("\(reason): saved every instance")
}

func handleTerminationSignal(name: String) {
    actionLock.lock()
    if terminating { actionLock.unlock(); log("received \(name) while already shutting down - ignoring"); return }
    terminating = true
    let inFlight = actionInFlight
    if inFlight { exitWhenResponseFinishes = true }
    actionLock.unlock()
    log("received \(name)")
    if inFlight {
        log("\(name): a power response is already running - letting it finish and exiting when it does, rather than killing it mid-flight")
        return
    }
    respond(.pauseAndSave, reason: name)
    verdict(); exit(0)
}

func verdict() {
    // A `.pauseOnly` (sleep/lid close) is *supposed* to leave the guests
    // frozen and unsaved - this process survives sleep, so there is nothing
    // to persist. Only a pauseAndSave has to have saved.
    let mustSave = (scenario != "sleeponly")
    let ok = guestsFrozen && (guestsSaved || !mustSave)
    print("──> VERDICT [\(scenario)]: frozen=\(guestsFrozen) saved=\(guestsSaved) "
        + "(save required: \(mustSave))  \(ok ? "PASS" : "FAIL")")
    fflush(stdout)
}

signal(SIGTERM, SIG_IGN)
let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
src.setEventHandler { handleTerminationSignal(name: "SIGTERM") }
src.resume()

switch scenario {
case "nested":       // IOKit shutdown in flight, SIGTERM during the GUI pump
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        Thread { Thread.sleep(forTimeInterval: 0.8); log("launchd sends SIGTERM"); kill(getpid(), SIGTERM) }.start()
        respond(.pauseAndSave, reason: "shutdown"); verdict(); exit(0) }
case "sleeponly":    // lid close (pauseOnly) in flight, then SIGTERM
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        Thread { Thread.sleep(forTimeInterval: 0.1); log("launchd sends SIGTERM"); kill(getpid(), SIGTERM) }.start()
        respond(.pauseOnly, reason: "sleep")
        Thread.sleep(forTimeInterval: 0.5); verdict(); exit(0) }
case "alreadysaved": // a full shutdown response completed, THEN SIGTERM
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        respond(.pauseAndSave, reason: "shutdown")
        log("(response complete; now the late SIGTERM)")
        kill(getpid(), SIGTERM) }
case "double":       // two SIGTERMs during one in-flight response
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        Thread { Thread.sleep(forTimeInterval: 0.6); kill(getpid(), SIGTERM)
                 Thread.sleep(forTimeInterval: 0.3); log("launchd sends a SECOND SIGTERM"); kill(getpid(), SIGTERM) }.start()
        respond(.pauseAndSave, reason: "shutdown"); verdict(); exit(0) }
case "concurrent":   // respond() off-main (the `msl power-test` path):
                     // handler and response run genuinely in parallel
    Thread { log("respond() starting on the DaemonServer thread")
             respond(.pauseAndSave, reason: "power-test shutdown")
             log("(off-main response returned)")
             Thread.sleep(forTimeInterval: 0.5); verdict(); exit(0) }.start()
    Thread { Thread.sleep(forTimeInterval: 0.8); log("launchd sends SIGTERM"); kill(getpid(), SIGTERM) }.start()
case "lostrace":     // SIGTERM lands in the instant the response finishes
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        Thread { Thread.sleep(forTimeInterval: 3.03); log("launchd sends SIGTERM (right at completion)"); kill(getpid(), SIGTERM) }.start()
        respond(.pauseAndSave, reason: "shutdown")
        log("(response returned; handler may or may not have won the race)")
        Thread.sleep(forTimeInterval: 1.0); verdict(); exit(0) }
case "restarted":    // a pauseAndSave completed, an instance was STARTED
                     // AGAIN, then SIGTERM. The stale-history flag skipped
                     // the save here; the state-based check must not.
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        respond(.pauseAndSave, reason: "power-test shutdown")
        log("(power-test done) --- user starts an instance again ---")
        instanceRunning = true; guestsFrozen = false; guestsSaved = false
        kill(getpid(), SIGTERM) }
default: print("unknown scenario"); exit(2)
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.run()
