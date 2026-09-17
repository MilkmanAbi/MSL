import Foundation

/// Catches subcommand typos before they turn into instances.
///
/// `msl <word>` treats anything it doesn't recognise as an instance name,
/// which is what makes `msl work` open a shell in `work` without any
/// ceremony. The cost is that a mistyped or guessed subcommand is
/// indistinguishable from a new instance name: typing `msl list` - a
/// reasonable guess, since the real command is `msl instances` - created and
/// permanently registered an instance called "list", complete with its own
/// machine identity file. Registration happens when the VM manager is
/// built, which is well before any boot succeeds, so the entry survives even
/// though that guest never ran.
public enum CommandSuggestion {

    /// The nearest command to `input`, or `nil` if nothing is close enough
    /// to be worth second-guessing the user over.
    ///
    /// Deliberately conservative: this turns a working invocation into an
    /// error, so it must not fire on a name someone actually meant. The
    /// tolerance scales with length (a 3-character word gets one edit, not
    /// two, because at two edits almost everything short matches
    /// something), and a word that is already a legitimate name is filtered
    /// out by the caller before this is ever consulted.
    public static func nearest(_ input: String, in commands: [String]) -> String? {
        let candidate = input.lowercased()
        guard candidate.count >= 2 else { return nil }
        let tolerance = candidate.count <= 3 ? 1 : 2

        var best: (command: String, distance: Int)?
        for command in commands {
            // Flags aren't things anyone typos into an instance name.
            guard !command.hasPrefix("-") else { continue }
            let distance = editDistance(candidate, command.lowercased())
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (command, distance) }
        }
        return best?.command
    }

    /// Levenshtein distance, two rows rather than a full matrix.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let first = Array(a), second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)

        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }
}
