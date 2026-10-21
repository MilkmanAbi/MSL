// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// One way MSL can be found in a state it cannot get itself out of.
///
/// The same promise as `CrashScreen.StopCode`, which these are folded into so
/// there is exactly one table on screen and in the guide: **the number is
/// stable and is never reused for a different condition.** Rename the text
/// freely; never renumber.
///
/// Unlike the codes MSL raises about itself, every one of these carries a
/// `next`. That is not optimism - it is the entry condition. The observer only
/// raises a code for something it recognised from outside and can name a way
/// out of; anything it cannot explain is recorded in the log and left there,
/// because a crash screen that shrugs is worse than no crash screen.
public struct ObserverStopCode: Equatable, Sendable {
    public let number: UInt32
    public let name: String
    public let happened: String
    public let next: String
    /// Which part of MSL the code is *about* - which is rarely the part that
    /// reported it. Everything here is reported by `mslod` and almost none of
    /// it is about `mslod`, and a report that does not say so sends people
    /// looking in the wrong place.
    public let subsystem: String

    public init(number: UInt32, name: String, happened: String, next: String,
                subsystem: String) {
        self.number = number
        self.name = name
        self.happened = happened
        self.next = next
        self.subsystem = subsystem
    }

    /// `0x00000020`, the form that goes on screen and into a search box.
    public var printed: String { String(format: "0x%08X", number) }

    /// Which page of the guide explains it. One page for every stop code,
    /// with an anchor per code, so the crash screen can send somebody
    /// straight to the paragraph about the number they are looking at.
    public var wikiAnchor: String { name.lowercased().replacingOccurrences(of: "_", with: "-") }
}

extension ObserverStopCode {
    /// Everything the observer can raise. `0x20` upwards: `0x01`-`0x06` are
    /// the signals, `0x10`-`0x13` the conditions MSL detects in itself.
    public static let all: [ObserverStopCode] = [
        .serviceWillNotStayUp, .serviceStoppedAnswering,
        .serviceIsNotInstalled, .stateDirectoryUnusable,
    ]

    public static func code(named name: String) -> ObserverStopCode? {
        all.first { $0.name == name }
    }

    /// 0x20. `mslhd` keeps dying and coming back, and in between it never
    /// managed to answer anything. A single crash is not this - launchd
    /// brings the daemon back and MSL carries on, which is the system
    /// working. Four in five minutes with nothing served is the system
    /// failing to work, repeatedly, and it will not stop by itself.
    public static let serviceWillNotStayUp = Self(
        number: 0x20, name: "SERVICE_WILL_NOT_STAY_UP",
        happened: "MSL's background service has crashed and restarted several times in a "
                + "few minutes, and never managed to answer anything in between. Nothing "
                + "that needs it can work: not your instances, not the app, not the "
                + "command line.",
        next: "Quit MSL, then open it again - that reinstalls the service from the app. "
            + "If it keeps happening, the crash report named mslhd in Console's Crash "
            + "Reports says why, and the code above is worth quoting with it.",
        subsystem: "mslhd - MSL's background service")

    /// 0x21. The daemon is there, the socket accepts a connection, and
    /// nothing comes back. A full listen backlog answers a `connect` happily,
    /// so this is deliberately measured on a *reply*.
    public static let serviceStoppedAnswering = Self(
        number: 0x21, name: "SERVICE_STOPPED_ANSWERING",
        happened: "MSL's background service is running and accepting connections, but it "
                + "has stopped replying to them. Anything that asks it something now "
                + "waits forever instead of being told no.",
        next: "Restart the service: in Terminal, run "
            + "launchctl kickstart -k gui/$(id -u)/com.msl.mslhd - your instances keep "
            + "their disks, and anything that was running comes back. If it wedges "
            + "again, restart the Mac before using MSL for anything you care about.",
        subsystem: "mslhd - the control socket")

    /// 0x22. The installed daemon is gone, or is not executable. An upgrade
    /// replaces it in milliseconds and the installer boots it out on purpose,
    /// so this is only raised after it has stayed gone - this is the
    /// half-finished install, not the ordinary one.
    public static let serviceIsNotInstalled = Self(
        number: 0x22, name: "SERVICE_IS_NOT_INSTALLED",
        happened: "The program MSL runs everything through is missing from where MSL "
                + "installs it, so nothing can start. An install or an update most "
                + "likely stopped part-way.",
        next: "Open MSL once: the app reinstalls its own command-line programs every "
            + "time it launches. If MSL will not open either, install it again from "
            + "its package - your instances and their disks are untouched by that.",
        subsystem: "the installed programs in Application Support/MSL/bin")

    /// 0x23. The folder MSL keeps everything in cannot be written, or the
    /// file listing the instances cannot be read. Both look like instances
    /// vanishing, which is the single most alarming way for MSL to fail and
    /// the one most likely to be mistaken for data loss.
    public static let stateDirectoryUnusable = Self(
        number: 0x23, name: "STATE_DIRECTORY_UNUSABLE",
        happened: "MSL cannot use the folder it keeps your instances, accounts and "
                + "settings in. Instances may appear to have vanished; nothing has "
                + "been deleted, MSL simply cannot read or write the folder.",
        next: "Check that ~/Library/Application Support/MSL still belongs to you and "
            + "is readable and writable, and that the disk it is on is not full. "
            + "Do not delete anything in there - it is where your instances live.",
        subsystem: "Application Support/MSL - instances, accounts and settings")
}
