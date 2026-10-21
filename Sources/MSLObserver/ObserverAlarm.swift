// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import CoreFoundation
import Darwin
import Foundation

/// Putting the crash screen up from a process that cannot draw one.
///
/// The order matters and is the whole of this file: **the evidence is written
/// before anything is shown.** A window that fails to appear must still leave
/// behind a report somebody can read, because the case where nothing can draw
/// - MSL.app missing, a half-finished install - is exactly the case the
/// observer exists for.
public enum ObserverAlarm {
    /// What `CrashScreen` records this as. The same `component\tcode\tdetail`
    /// line MSL writes for itself, so the existing crash window reads one
    /// format and knows nothing about the observer.
    public static let component = "mslod"

    public enum Shown: Equatable, Sendable {
        case window(pid: pid_t)
        case notice
        case nothing(String)
    }

    @discardableResult
    public static func raise(_ code: ObserverStopCode, detail: String,
                             session: ObserverSession) -> Shown {
        session.writeIncident(code: code, detail: detail)
        writeCrashNote(code: code, detail: detail)

        // The viewer, by path, with no LaunchServices in the way: `open`
        // would need the app registered, and an install that went wrong is
        // precisely when it is not.
        let viewer = ObserverPaths.viewer.path
        if FileManager.default.isExecutableFile(atPath: viewer) {
            var pid: pid_t = 0
            let spawned = viewer.withCString { viewerC -> Int32 in
                "--crash-screen".withCString { flagC -> Int32 in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: viewerC),
                        UnsafeMutablePointer(mutating: flagC), nil,
                    ]
                    return posix_spawn(&pid, viewerC, nil, nil, &argv, environ)
                }
            }
            if spawned == 0 { return .window(pid: pid) }
            session.write("could not spawn the crash screen (\(spawned)) - falling back to a notice")
        } else {
            session.write("\(viewer) is not there to draw a crash screen - falling back to a notice")
        }

        // Last resort. `DisplayNotice` rather than `DisplayAlert`: it posts
        // the notice and returns, where the alert blocks until somebody
        // dismisses it - and a watchdog that stops watching because it is
        // holding a dialog open has stopped being a watchdog.
        let posted = CFUserNotificationDisplayNotice(
            0, CFOptionFlags(kCFUserNotificationStopAlertLevel), nil, nil, nil,
            "MSL has stopped working" as CFString,
            """
            \(code.printed) \(code.name)

            \(code.happened)

            \(code.next)

            \(ObserverWiki.page(for: code))
            """ as CFString,
            "OK" as CFString)
        return posted == 0 ? .notice : .nothing("CFUserNotification returned \(posted)")
    }

    /// The note the crash window reads: component, code name, detail, one
    /// line, tab-separated.
    ///
    /// Tabs and newlines are stripped from the detail rather than escaped,
    /// because the reader splits on tabs and takes one line - a detail
    /// carrying either would silently lose everything after it.
    static func writeCrashNote(code: ObserverStopCode, detail: String) {
        let flat = detail.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "\(component)\t\(code.name)\t\(flat)\n"
        try? FileManager.default.createDirectory(at: ObserverPaths.appSupport,
                                                 withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: ObserverPaths.crashNote, options: .atomic)
    }
}
