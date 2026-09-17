import Foundation

/// The word a user types to confirm removing an instance.
///
/// Removing an instance deletes its saved sessions, snapshots, the Mac apps
/// made for it and its SSH entry, and none of that comes back - so a click
/// isn't enough. A typed word is the usual guard against a destructive action
/// done on autopilot, and a cat's is easier to remember than the instance's
/// own name.
public enum RemovalConfirmation {
    public static let word = "Meow"

    /// Case and surrounding whitespace don't matter; the word itself does.
    public static func matches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(word) == .orderedSame
    }
}
