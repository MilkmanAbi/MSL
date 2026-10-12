// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// How to connect, per platform, in the words that actually work.
///
/// Every line here was arrived at by failing first. They look obvious
/// written down and none of them were obvious at the time - which is
/// exactly why they belong in the app rather than in somebody's memory.
public enum ConnectionTips {

    public enum Platform: String, CaseIterable, Sendable, Identifiable {
        case macOS, linux, windows, freeBSD
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .macOS:   return "macOS"
            case .linux:   return "Linux"
            case .windows: return "Windows"
            case .freeBSD: return "FreeBSD"
            }
        }
    }

    /// The whole thing somebody can paste into a message.
    public static func instructions(for platform: Platform, instance: String,
                                    endpoint: PublicEndpoint) -> String {
        let file = RecipientKey.filename(instance: instance)
        let target = "\(endpoint.user)@\(endpoint.host)"

        switch platform {
        case .windows:
            return """
            1. Save the key file into your Downloads folder.

            2. In PowerShell, lock the file down so only you can read it:

               $key = "$HOME\\Downloads\\\(file)"
               icacls $key /inheritance:r
               icacls $key /grant:r "$($env:USERNAME):R"

            3. Connect:

               ssh -i $key -o IdentitiesOnly=yes -p \(endpoint.port) \(target)

            If step 2 is skipped, ssh refuses the key and says the
            permissions are too open - Downloads often grants access to
            other accounts, and it will name the one to remove.

            Write "$($env:USERNAME)" exactly like that, brackets included.
            Without them PowerShell reads $env:USERNAME:R as one name and
            icacls fails, leaving a file nobody can read - including you.
            """

        case .macOS, .linux, .freeBSD:
            let home = platform == .macOS ? "~/Downloads" : "~"
            return """
            1. Save the key file as \(home)/\(file)

            2. Lock it down - ssh refuses a key others can read:

               chmod 600 \(home)/\(file)

            3. Connect:

               ssh -i \(home)/\(file) -o IdentitiesOnly=yes -p \(endpoint.port) \(target)

            Tired of the long line? Put this in ~/.ssh/config and then it is
            just: ssh \(shortName(instance))

               Host \(shortName(instance))
                 HostName \(endpoint.host)
                 Port \(endpoint.port)
                 User \(endpoint.user)
                 IdentityFile \(home)/\(file)
                 IdentitiesOnly yes
            """
        }
    }

    /// Why `IdentitiesOnly` is in every one of these.
    public static let identitiesOnlyNote = """
    IdentitiesOnly=yes matters more than it looks. Without it ssh offers \
    every key your agent is holding before the one you named, and the \
    server can hang up before reaching it - reporting a key failure about \
    a key it never tried.
    """

    static func shortName(_ instance: String) -> String {
        let safe = instance.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "msl-" + String(safe)
    }
}
