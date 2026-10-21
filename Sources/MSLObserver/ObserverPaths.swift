// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Darwin
import Foundation

/// Everywhere the observer looks, and the one way to point it somewhere else.
///
/// **Nothing here is shared with MSLCore on purpose.** `MSLObserver` is a leaf
/// with no dependencies at all, because the observer has to keep working when
/// the thing it is watching does not - and a daemon that links the same
/// library as its subject can fall over for the same reason its subject did.
/// The handful of paths are spelled out again rather than imported; a test
/// (`ObserverPathParityTests`) fails if any of them stops matching
/// `MSLPaths`.
///
/// The environment overrides exist so the observer can be rehearsed against a
/// *fake* daemon - a restart loop driven on purpose, the real crash screen
/// coming up - without touching the real service or the real logs. Testing a
/// watchdog by actually breaking MSL is not a thing anybody should have to do.
public enum ObserverPaths {
    /// `getenv`, not `ProcessInfo.processInfo.environment`: a test sets these
    /// with `setenv` in its own process, and whether that shows up in
    /// Foundation's dictionary depends on when the dictionary was built.
    /// Reading the real environment leaves no room for that.
    static func override(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    /// Whether XCTest is in this process.
    ///
    /// **The observer deletes logs**, which is the one kind of code that must
    /// never run against a real home directory by accident. An override that
    /// every test file has to remember is an override some test file will
    /// forget, and the one that forgets is the one that deletes somebody's
    /// record of a crash they were in the middle of reading. So, as in
    /// `MSLPaths`, it is detected rather than injected.
    private static let underTest: URL? = {
        guard NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.processName == "xctest" else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-observer-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// `~/Library/Application Support/MSL` - MSL's state, which the observer
    /// reads and never writes to, bar its own incident report.
    public static var appSupport: URL {
        if let root = override("MSL_OBSERVER_ROOT") { return URL(fileURLWithPath: root) }
        if let underTest { return underTest.appendingPathComponent("state") }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MSL")
    }

    public static var logs: URL {
        if let logs = override("MSL_OBSERVER_LOGS") { return URL(fileURLWithPath: logs) }
        if let underTest { return underTest.appendingPathComponent("logs") }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MSL")
    }

    /// The control socket everything reaches `mslhd` on.
    public static var socket: URL {
        if let socket = override("MSL_OBSERVER_SOCKET") { return URL(fileURLWithPath: socket) }
        return appSupport.appendingPathComponent("mslhd.sock")
    }

    /// The installed daemon, which is what a user's MSL actually runs - not
    /// whatever is in a build directory.
    public static var daemonBinary: URL {
        appSupport.appendingPathComponent("bin/mslhd")
    }

    /// The process name the observer watches for. Overridable only so a
    /// rehearsal can point it at a stand-in.
    public static var daemonProcessName: String {
        override("MSL_OBSERVER_DAEMON") ?? "mslhd"
    }

    /// This session's record. Truncated per *boot*, never per observer
    /// start - see `ObserverSession`.
    public static var log: URL { logs.appendingPathComponent("observer.log") }

    /// What the observer has to remember between its own restarts: which boot
    /// this is, which incidents it has already shown, and how far it has read
    /// MSL's logs. Lives beside the log and dies with it.
    public static var sessionState: URL { logs.appendingPathComponent("observer-session.json") }

    /// The incident report. **Not a log** - it is the evidence behind a crash
    /// screen that may not have been read yet, so it outlives the log and is
    /// cleared when the screen shows it.
    public static var incident: URL { appSupport.appendingPathComponent("observer-incident.txt") }

    /// Where `CrashScreen` leaves its note, in the format the window reads.
    /// The observer writes this one and, just as importantly, *reads* it: a
    /// note that mslhd wrote seconds ago means mslhd has already explained
    /// itself and the observer must not talk over it.
    public static var crashNote: URL { appSupport.appendingPathComponent("last-crash.txt") }

    /// Where macOS leaves crash reports. The observer does not parse these
    /// for fun: the exception type in one is the only *real* error code in
    /// the whole business, and it is what goes in an incident's detail.
    public static var diagnosticReports: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
    }

    /// The process that can draw a window. A daemon cannot.
    public static var viewer: URL {
        if let viewer = override("MSL_OBSERVER_VIEWER") { return URL(fileURLWithPath: viewer) }
        return URL(fileURLWithPath: "/Applications/MSL.app/Contents/MacOS/MSLApp")
    }

    /// The real locations, ignoring every override and the test redirect.
    ///
    /// **For checking that the observer and MSL agree about where MSL is,
    /// and for nothing else.** Everything the observer actually does goes
    /// through the overridable paths above, so a rehearsal can point it at a
    /// stand-in - but a rehearsal must not be able to make
    /// `ObserverParityTests` pass by pointing both halves at the same made-up
    /// directory.
    public static var installedAppSupport: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MSL")
    }

    public static var installedLogs: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MSL")
    }

    /// MSL's own logs, mirrored into the observer's record so one file holds
    /// both what MSL said and what the observer saw from outside.
    public static var mirroredLogs: [URL] {
        [logs.appendingPathComponent("msl.log"), logs.appendingPathComponent("mslhd.log")]
    }
}
