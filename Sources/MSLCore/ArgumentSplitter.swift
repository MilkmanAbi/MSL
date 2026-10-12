// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Separates `msl`'s own options from the command it forwards into the
/// guest.
///
/// The original pre-parse searched the whole argument list for `--distro`,
/// `-u` and `--manifest`, which meant `msl` stole flags belonging to the
/// guest's command: `msl work echo -d /tmp` failed with "unknown distro
/// '/tmp'" instead of running `echo -d /tmp`, and `msl work docker run -u
/// 1000 img` silently dropped `-u 1000` from the docker invocation and ran
/// the session as user "1000". `ssh` has the same shape and solves it by
/// not looking for options past the first non-option argument.
///
/// The wrinkle is that this CLI documents options *after* the name -
/// `msl <instance> -u msl` and `msl install <distro> --manifest <url>` are
/// both in the usage text - so "stop at the first non-option" cannot be
/// applied from the very front. The rule is therefore per-command:
///
/// - Options are always consumed from the front, before any name.
/// - A command with a **verbatim tail** (`--`, `run`, `gui`, `gui-native`,
///   or a bare instance name) consumes options while they sit either side
///   of its instance name - `msl run -u root work` and `msl run work -u
///   root` are the same request - and from the first non-option token
///   after that, every argument belongs to the guest untouched.
/// - Any other subcommand takes fixed arguments and no guest command, so
///   options are recognised anywhere within it.
public enum ArgumentSplitter {

    public struct Options: Equatable {
        public var distro: String?
        public var user: String?
        public var manifest: String?
        /// Where `--shipment` should write, and the note to put in it.
        public var output: String?
        public var note: String?
        /// `msl <instance> --shipment` - a bare flag, not a `--flag value`
        /// pair, which is why the scanners below check for booleans first.
        public var shipment = false
        /// The subcommand or instance name and its arguments, with this
        /// CLI's own options removed.
        public var remainder: [String]

        public init(distro: String? = nil, user: String? = nil,
                    manifest: String? = nil, output: String? = nil, note: String? = nil,
                    shipment: Bool = false, remainder: [String] = []) {
            self.distro = distro
            self.user = user
            self.manifest = manifest
            self.output = output
            self.note = note
            self.shipment = shipment
            self.remainder = remainder
        }
    }

    /// Commands whose trailing arguments are a command line for the guest
    /// rather than arguments for `msl`.
    ///
    /// Defined in `CLICommands` so the dispatch in `main.swift` and this
    /// parser cannot disagree about which commands have a guest tail. Being
    /// on the wrong list is not a cosmetic mistake: a verbatim-tail command
    /// listed as fixed-arity has its guest's flags eaten (see the tests
    /// above this file's `split`).
    static var verbatimTail: Set<String> { CLICommands.verbatimTail }

    /// How many tokens a verbatim-tail command takes before the tail
    /// starts: `--` is followed immediately by the command, while `gui`
    /// and `run` take an instance name first.
    private static func namesConsumed(by command: String) -> Int {
        command == "--" ? 1 : 2
    }

    public static func split(_ argv: [String], knownCommands: Set<String>) -> Options {
        var options = Options()
        var index = 0

        // 1. Options before any name.
        index = consumeOptions(argv, from: index, into: &options, stopAtNonOption: true)
        guard index < argv.count else { return options }

        let token = argv[index]

        // 2. `--` hands everything after it to the guest as-is.
        if token == "--" {
            options.remainder = Array(argv[index...])
            return options
        }

        // 3. A fixed-arity subcommand: no guest command, so an option
        //    anywhere in it is unambiguously ours.
        if knownCommands.contains(token), !verbatimTail.contains(token) {
            var rest = Array(argv[index...])
            rest = consumeOptionsAnywhere(rest, into: &options)
            options.remainder = rest
            return options
        }

        // 4. A verbatim-tail command, or a bare instance name. Keep its
        //    name(s), then options only while they lead.
        let isCommand = verbatimTail.contains(token)
        var remainder = [token]
        var cursor = index + 1

        // Options may sit *between* the command word and the name:
        // `msl run -u root work` is the same request as `msl run work -u
        // root`, and people who come from WSL put flags first. Only for a
        // real command word - for a bare instance name, `token` is already
        // the name and anything after it belongs to the guest.
        if isCommand, namesConsumed(by: token) > 1 {
            cursor = consumeOptions(argv, from: cursor, into: &options, stopAtNonOption: true)
            if cursor < argv.count {
                remainder.append(argv[cursor])
                cursor += 1
            }
        }

        // Then options again, after the name, which is the documented
        // `msl <instance> -u root` form.
        cursor = consumeOptions(argv, from: cursor, into: &options, stopAtNonOption: true)
        remainder.append(contentsOf: argv[cursor...])
        options.remainder = remainder
        return options
    }

    // MARK: - Option scanning

    private static func optionKey(_ argument: String) -> WritableKeyPath<Options, String?>? {
        switch argument {
        case "--distro", "-d": return \.distro
        case "--user", "-u": return \.user
        case "--manifest": return \.manifest
        case "--output", "-o": return \.output
        case "--note": return \.note
        default: return nil
        }
    }

    /// Options that are a flag on their own, with no value after them.
    private static func booleanKey(_ argument: String) -> WritableKeyPath<Options, Bool>? {
        argument == "--shipment" ? \.shipment : nil
    }

    /// Consumes `--flag value` pairs starting at `from`, stopping at the
    /// first argument that is not one of ours.
    private static func consumeOptions(
        _ argv: [String], from start: Int, into options: inout Options, stopAtNonOption: Bool
    ) -> Int {
        var index = start
        while index < argv.count {
            if let flag = booleanKey(argv[index]) {
                options[keyPath: flag] = true
                index += 1
                continue
            }
            guard let key = optionKey(argv[index]) else { break }
            // A trailing option with no value is left in place so the
            // command's own usage error can report it, rather than being
            // silently swallowed here.
            guard index + 1 < argv.count else { break }
            options[keyPath: key] = argv[index + 1]
            index += 2
        }
        return index
    }

    /// Removes `--flag value` pairs from anywhere in `arguments`.
    private static func consumeOptionsAnywhere(
        _ arguments: [String], into options: inout Options
    ) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if let flag = booleanKey(arguments[index]) {
                options[keyPath: flag] = true
                index += 1
                continue
            }
            if let key = optionKey(arguments[index]), index + 1 < arguments.count {
                options[keyPath: key] = arguments[index + 1]
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }
}
