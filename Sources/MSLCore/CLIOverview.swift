// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// What plain `msl` prints.
///
/// It used to open a shell on the instance you used last. That is a fine
/// thing to want and `msl run` still does it, but it made the one word
/// everybody types first the only word that told them nothing: no version,
/// no list of what they had, no hint that there were other commands. Every
/// tool of this shape - `git`, `docker`, `wsl` - answers its own name with
/// an orientation, and MSL's CLI had grown a long way behind its app.
///
/// Deliberately reads nothing but the instance registry: no daemon
/// connection, no catalog fetch, no image on disk is touched. Typing `msl`
/// must never be the thing that starts a service or costs a network
/// round-trip.
public enum CLIOverview {
    /// One instance, as plain data - name and distro, from the registry.
    /// Live state is left to `msl list`, which is allowed to wake the
    /// daemon up.
    public struct InstanceLine: Equatable, Sendable {
        public let name: String
        public let distro: String
        public let isLastUsed: Bool

        public init(name: String, distro: String, isLastUsed: Bool) {
            self.name = name
            self.distro = distro
            self.isLastUsed = isLastUsed
        }
    }

    static let everyday: [(String, String)] = [
        ("msl run <instance>", "Open a shell"),
        ("msl run <instance> <command>", "Run one command and come back, like ssh"),
        ("msl list", "Your instances, and which are running"),
        ("msl distros", "Every distro you can install, and what you have"),
        ("msl install <distro>", "Download a distro and set up an instance"),
        ("msl files", "Browse your instances from the Mac"),
    ]

    /// `styled` adds bold and dim; off when stdout isn't a terminal, so a
    /// pipe gets plain text.
    public static func render(instances: [InstanceLine],
                              version: String = MSLVersion.marketing,
                              styled: Bool,
                              emptyHint: String? = nil) -> String {
        let bold = styled ? "\u{1B}[1m" : ""
        let dim = styled ? "\u{1B}[2m" : ""
        let reset = styled ? "\u{1B}[0m" : ""

        var out = "\(bold)MSL\(reset) - Mac Subsystem for Linux \(dim)\(version)\(reset)\n"

        if instances.isEmpty {
            out += "\nNo instances yet. One command sets up a whole Linux:\n\n"
            out += "    \(bold)msl install debian\(reset)\n"
            if let emptyHint { out += "\n\(emptyHint)" }
        } else {
            out += "\n\(bold)Your instances\(reset)\n"
            let width = instances.map(\.name.count).max() ?? 8
            for line in instances {
                let name = line.name.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                let note = line.isLastUsed ? "  \(dim)- `msl run` opens this one\(reset)" : ""
                out += "  \(name)\(line.distro)\(note)\n"
            }
        }

        out += "\n\(bold)Everyday\(reset)\n"
        let column = everyday.map(\.0.count).max() ?? 30
        for (command, summary) in everyday {
            out += "  " + command.padding(toLength: column + 2, withPad: " ", startingAt: 0) + summary + "\n"
        }
        out += "\n  " + "msl help".padding(toLength: column + 2, withPad: " ", startingAt: 0)
            + "Every command, with its options\n"
        return out
    }
}
