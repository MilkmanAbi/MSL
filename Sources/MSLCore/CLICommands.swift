// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Every word `msl` recognises as a command, in one place.
///
/// This list used to live in `Sources/msl/main.swift`, where only the CLI
/// could see it. Two things outside the CLI need it now:
///
/// - **`ArgumentSplitter`**, to know whether a token is a subcommand (whose
///   options belong to `msl`) or an instance name (whose trailing arguments
///   belong to the guest).
/// - **Creation**, so an instance can't be given a name that a command
///   already owns. An instance called `run` can still be *used* - the
///   registry outranks the verb, see `CommandAliases.resolve` - but it can
///   never be addressed as plain `msl run` again, so MSL declines to make
///   one in the first place rather than letting someone paint themselves
///   into that corner.
public enum CLICommands {
    /// Subcommands that take a fixed set of arguments: every option in one
    /// is unambiguously `msl`'s own.
    public static let fixed: Set<String> = [
        "apps", "cage-bridge-test", "cage-input-test", "cage-view",
        "config", "distros", "dns", "doctor", "files", "fix-home",
        "forward", "greeter", "help", "identity", "protect",
        "hibernate", "images", "install", "install-tools", "instances",
        "keyboard", "kitty", "list", "lock", "ls", "new", "power-test",
        "clone", "remove", "remove-distro", "rename", "resources", "resume", "shipment",
        "snapshot", "ssh", "status", "storage", "suspend", "unforward", "uninstall", "unprotect", "vault",
        "public", "update", "usb", "version", "vpn",
    ]

    /// Subcommands whose trailing arguments are a command line for the
    /// guest, to be passed through untouched.
    ///
    /// `run` belongs here, not in `fixed`. As a fixed command its options
    /// would be scanned anywhere inside it, so `msl run work docker run -u
    /// 1000 img` would lose the container's `-u` - exactly the bug
    /// `ArgumentSplitter`'s own notes describe.
    public static let verbatimTail: Set<String> = ["--", "gui", "gui-native", "run"]

    /// Every command, for dispatch and for "did you mean".
    public static var all: Set<String> { fixed.union(verbatimTail).subtracting(["--"]) }

    /// Sorted, for a suggestion list that reads the same every time.
    public static var sorted: [String] { all.sorted() }

    /// Words MSL will not create an instance with.
    ///
    /// The commands, plus a few words that would make the resulting instance
    /// confusing to talk about. Two deliberate omissions:
    ///
    /// - **Distro names.** `msl fedora` naming a Fedora instance "fedora" is
    ///   a documented ergonomic, and the whole of a fresh install's
    ///   instructions.
    /// - **`default`.** It is `InstanceRegistry.defaultInstanceName` - the
    ///   instance a first-ever run lands on - so reserving it refused the
    ///   one name MSL itself picks.
    public static var reserved: Set<String> {
        all.union(["msl", "mslhd", "all", "none"])
    }

    /// Whether `name` can be used for a **new** instance.
    ///
    /// Separate from `InstanceRegistry.isValidName`, which answers whether a
    /// name is *usable at all* and must keep saying yes to every instance
    /// that already exists. Tightening that would make an instance someone
    /// created last year unloadable; this one only ever runs before a name
    /// is taken.
    public static func isAvailableName(_ name: String) -> Bool {
        InstanceRegistry.isValidName(name) && !reserved.contains(name.lowercased())
    }

    /// Why `name` was refused, for the message shown to whoever typed it.
    public static func nameRefusal(_ name: String) -> String? {
        // A mistyped flag is not an attempt to name an instance, and saying
        // so as if it were sends the reader looking in the wrong place.
        if name.hasPrefix("-") {
            return "unknown option '\(name)' - msl help lists them"
        }
        if !InstanceRegistry.isValidName(name) {
            return "“\(name)” can't be an instance name - use up to 32 letters, digits, - and _"
        }
        if reserved.contains(name.lowercased()) {
            return "“\(name)” is an msl command, so an instance can't be called that"
        }
        // Names MSL uses for its own files alongside per-instance ones, so
        // an instance can never collide with them - see
        // `InstanceIdentityStore.reservedNames`.
        if InstanceIdentityStore.reservedNames.contains(name.lowercased()) {
            return "“\(name)” is a name MSL uses for its own records, so an instance can't be called that"
        }
        return nil
    }
}
