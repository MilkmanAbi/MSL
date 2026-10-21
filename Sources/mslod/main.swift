// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
import MSLObserver

// MSL's observer: the one part of MSL that is not MSL.
//
// It watches the service, the app and every per-application host from
// outside, writes down what it sees for as long as this Mac has been on, and
// puts the crash screen up when MSL is in a state it cannot get itself out
// of. Nothing in MSL depends on it, and it depends on nothing in MSL: it
// links `MSLObserver` and the system, and not `MSLCore`, because a watchdog
// built on the same library as its subject falls over for the same reasons
// its subject does.
//
// There are deliberately **no signal handlers and no crash screen of its
// own**. If this process dies, its LaunchAgent brings it straight back and
// the only cost is a line in `observer-launchd.log`; a watchdog that
// interrupts somebody to complain about itself has misunderstood its job.

let session = ObserverSession()

// `--once` so the loop can be driven a single tick at a time from a
// rehearsal, against a stand-in daemon and a throwaway log directory (see
// `ObserverPaths`). Nothing else takes arguments: a daemon with options is a
// daemon with configurations nobody tested.
if CommandLine.arguments.contains("--once") {
    ObserverLoop(session: session).tick()
    session.saveState(force: true)
    exit(0)
}

ObserverLoop(session: session).run()
