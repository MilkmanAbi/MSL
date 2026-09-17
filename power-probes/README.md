# Power re-entrancy probes

Standalone `swiftc` probes, **not** XCTest — they need a real
`NSApplication` run loop and a process-directed signal, neither of which
survives being run inside a test harness. Nothing in `Package.swift`
references this directory.

```sh
cd power-probes
swiftc -o p1 01-demonstrate-vulnerability.swift && ./p1
swiftc -o p2 02-compare-candidate-fixes.swift && ./p2 A; ./p2 B
swiftc -o p3 03-verify-patched-logic.swift
for s in nested sleeponly double concurrent lostrace restarted; do ./p3 $s; done
```

## What they established

`SystemResilienceMonitor.waitForGUIHostsToExit` pumps the run loop, and that
pump is the only re-entrancy window in the power path — every other wait
(`quiesced.wait`, both `runBounded` calls) blocks the main thread outright,
so nothing can be delivered during them.

Whether a `SIGTERM` can run *nested inside an unfinished response* depends
entirely on how `respond` was entered, which is not obvious from the code:

| Entered from | Mechanism | Nested SIGTERM? |
|---|---|---|
| `NSWorkspace.willPowerOffNotification` (logout) | main-queue callout | **No** — a serial queue is not re-entrant, so it is deferred until the response returns |
| IOKit `CFRunLoopSource` (Apple-menu Shut Down / Restart, lid close) | run-loop source callout | **Yes** |

`01` demonstrates the second row. Before the fix, the nested handler hit
`respond`'s "already running" guard, logged, and then called `exit(0)`
anyway — killing the process during the GUI grace, before a single guest had
been frozen, let alone saved. That is the Apple-menu shutdown case.

`02` compares two fixes. Waiting in the handler for the response to finish
**deadlocks**: the in-flight response is below the handler on the same
thread, so it cannot progress until the handler returns. Measured, not
assumed — it burns the full timeout and then exits having saved nothing.
The fix that works records "exit when the response finishes" and returns.

`03` transcribes the patched `handleTerminationSignal` and `respond` cleanup
verbatim and drives six orderings; all six pass.

The `restarted` scenario is there because a first attempt at this fix cached
"a pauseAndSave already completed" and let a later SIGTERM exit on it. That
is a statement about *history*, and it goes stale: a `.pauseAndSave` can
complete while the daemon keeps running (`msl power-test shutdown`, a
low-battery hibernate), and an instance started afterwards would then be
killed without being saved. The check has to be about present state, which
is what `respond`'s own "no running instances" return already does.

Two probe artifacts worth knowing about, because both produce a confidently
wrong answer:

- `raise(SIGTERM)` is thread-directed (`pthread_kill(pthread_self())`) and is
  simply lost here. launchd sends a process-directed signal — use
  `kill(getpid(), SIGTERM)`.
- A probe with no input sources makes `RunLoop.run(mode:before:)` return
  instantly, so the pump degenerates into `Thread.sleep` and nothing is ever
  delivered. Verify the call actually blocks for the tick.
