import Foundation

/// The words people type when they don't know MSL's vocabulary yet.
///
/// `msl` treats an unrecognised word as an instance name, which is what makes
/// `msl work` open a shell without ceremony. `CommandSuggestion` catches the
/// *typos*, but not the confident guesses: `start`, `stop`, `delete` and `run`
/// are nowhere near any real command by edit distance, so they sailed straight
/// through and became instances. `msl start Milk` registered an instance
/// called "start" and tried to run `Milk` inside it.
///
/// Guessing is not a mistake to be corrected, though. Every word here has an
/// obvious intended meaning in MSL's own model, so they are translated and
/// run, with one line on stderr saying what MSL actually did. Being told
/// "`stop` means `hibernate` here" once is how someone learns the tool;
/// an error and a nonzero exit is how they stop using it.
public enum CommandAliases {
    /// The word MSL runs instead. An empty target means "drop the word and
    /// treat the rest as it stands" - nothing needs it now that `run` is a
    /// command of its own, but the rule stays because it is the right answer
    /// for any future word that means "no keyword at all".
    public static let table: [String: String] = [
        "start": "resume", "boot": "resume", "up": "resume", "launch": "resume",
        "unpause": "resume", "wake": "resume",
        "stop": "hibernate", "shutdown": "hibernate", "halt": "hibernate",
        "down": "hibernate", "poweroff": "hibernate",
        "pause": "suspend", "freeze": "suspend",
        "delete": "remove", "destroy": "remove", "rm": "remove",
        "create": "new", "add": "new",
        // Not `images`, which is *custom* images. Someone typing `msl
        // distros` wants the list of Linux distributions - which is what
        // `msl distros` now prints.
        "distributions": "distros", "distro": "distros",
        "ps": "instances", "vms": "instances",
        // `run` is a real command now (`msl run <instance>`), so the words
        // that mean the same thing point at it rather than being dropped.
        // Dropping them was how `msl run` on its own - no instance named -
        // sailed through to the instance-name fallthrough and registered an
        // instance called "run".
        "exec": "run", "shell": "run", "enter": "run", "attach": "run",
        "open": "run",
    ]

    /// What to print when a translation happens. Only for the ones where the
    /// meaning genuinely differs from what the word implies elsewhere:
    /// nobody needs telling that `delete` means `remove`, but `stop` keeping
    /// the instance's memory is worth a sentence.
    public static func note(for word: String, target: String) -> String? {
        switch target {
        case "hibernate":
            return "msl: `\(word)` here means `msl hibernate` - the instance stops with its state saved, so it comes back where you left it."
        case "suspend":
            return "msl: `\(word)` here means `msl suspend` - paused in memory, not stopped."
        default:
            return nil
        }
    }

    public struct Resolution: Equatable, Sendable {
        public var arguments: [String]
        public var note: String?
    }

    /// Rewrites the leading word if it is a guess, and leaves everything else
    /// exactly as it came in.
    ///
    /// `isTaken` protects a real name: someone with an instance called `run`
    /// must keep being able to type `msl run`. The registry is consulted
    /// rather than assumed, because "nobody would call an instance that" is
    /// how a working setup gets broken by an update.
    public static func resolve(_ arguments: [String],
                               isTaken: (String) -> Bool = { _ in false }) -> Resolution {
        guard let word = arguments.first,
              !word.hasPrefix("-"),
              let target = table[word.lowercased()],
              !isTaken(word)
        else { return Resolution(arguments: arguments, note: nil) }

        let rest = Array(arguments.dropFirst())
        // Dropping the word has to leave something behind: `msl run` alone
        // would otherwise become plain `msl`, which opens a different
        // instance than the one they were about to name.
        if target.isEmpty {
            guard !rest.isEmpty else { return Resolution(arguments: arguments, note: nil) }
            return Resolution(arguments: rest, note: nil)
        }
        return Resolution(arguments: [target] + rest, note: note(for: word, target: target))
    }
}
