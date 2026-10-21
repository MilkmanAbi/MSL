// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Darwin
import Foundation

/// The launchd job that keeps the observer running.
///
/// Its own job, deliberately never started by `mslhd`: a watchdog in the
/// process tree of the thing it watches goes down with it, and one started by
/// it would be absent in exactly the case that matters - a daemon so broken
/// it never got far enough to launch anything.
public enum ObserverAgent {
    public static let label = "com.msl.observer"

    public static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    public static var binary: URL { ObserverPaths.appSupport.appendingPathComponent("bin/mslod") }

    /// launchd's own record of the observer: where its stderr goes if it
    /// falls over. Truncated per boot with everything else of the
    /// observer's - never deleted, because launchd holds it open.
    public static var launchdLog: URL {
        ObserverPaths.logs.appendingPathComponent("observer-launchd.log")
    }

    public static func plist(binary: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [binary.path],
            "RunAtLoad": true,
            // **Plain `true`, unlike mslhd's `SuccessfulExit: false`.**
            // A clean exit from `mslhd` means it was asked to stop and should
            // stay stopped. There is no such thing for the observer: nothing
            // ever asks it to stop, so any exit at all is one it should come
            // back from. Turning it off is done by booting the job out.
            "KeepAlive": true,
            // Aqua, because the one thing it must be able to do is put a
            // window in front of somebody.
            "LimitLoadToSessionType": "Aqua",
            // It is a watcher, not work. Background tells macOS it can be
            // throttled freely - which is the honest description and keeps
            // it off the critical path of anything the person is doing.
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "ThrottleInterval": 30,
            "StandardOutPath": launchdLog.path,
            "StandardErrorPath": launchdLog.path,
        ]
    }

    public static func isLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    public static func isRunning() -> Bool {
        ObserverProbe.pid(named: "mslod", in: ObserverProbe.processes()) != nil
    }

    /// Writes the job and starts it. Returns false only when there is no
    /// `mslod` to run, which is a build or install problem rather than
    /// something to retry.
    ///
    /// Skips the bootout/bootstrap cycle when the file on disk is already
    /// right **and** the job is actually loaded - a plist on disk is not a
    /// job in launchd, and treating the two as the same is what once left
    /// `mslhd` down however many times the app was opened.
    @discardableResult
    public static func install() -> Bool {
        let tool = binary
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return false }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: ObserverPaths.logs, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist(binary: tool), format: .xml, options: 0) else { return false }
        let existing = try? Data(contentsOf: plistURL)
        if existing == data, isLoaded() { return true }
        if existing != data {
            guard (try? data.write(to: plistURL, options: .atomic)) != nil else { return false }
        }
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])
        launchctl(["bootstrap", domain, plistURL.path])
        return true
    }

    /// Stops the observer and removes its job.
    ///
    /// **Called first by the uninstaller**, before `mslhd` is stopped and
    /// before any binary is removed - otherwise the observer would watch MSL
    /// being taken apart and put a crash screen up in the middle of it.
    public static func remove() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
