import Foundation

/// The parts of MSL that exist purely because they are nice: the greeting
/// line under the shell banner, and the cat.
///
/// Both are on by default and both can be switched off, from the app or from
/// the command line, because they print on *every* session and not everyone
/// wants a personality in their terminal at 3am. The setting lives in a file
/// rather than in `UserDefaults` so the app and `msl` genuinely share it:
/// `msl` is not the app, and a defaults domain would leave them disagreeing.
public struct PersonalitySettings: Codable, Equatable, Sendable {
    /// The one-line greeting under `msl@distro`.
    public var greeters: Bool
    /// The cat, in every shell. When the greeting is on too she says it;
    /// when it is off she just turns up.
    public var kitty: Bool

    public init(greeters: Bool = true, kitty: Bool = true) {
        self.greeters = greeters
        self.kitty = kitty
    }

    public static let `default` = PersonalitySettings()
}

public enum PersonalitySettingsStore {
    public static var file: URL {
        MSLPaths.appSupport.appendingPathComponent("personality.json")
    }

    /// Never throws: a missing or damaged file means the defaults, because a
    /// greeting is not worth failing a shell over.
    public static func load(from url: URL = file) -> PersonalitySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PersonalitySettings.self, from: data)
        else { return .default }
        return settings
    }

    @discardableResult
    public static func save(_ settings: PersonalitySettings, to url: URL = file) -> Bool {
        MSLPaths.ensureDirectory(url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// The cat, and how to make it say things.
///
/// `cowsay` with a cat and no cow. `msl kitty` prints it; `msl kitty "text"`
/// gives it a speech bubble; and when both switches are on she is what says
/// the greeting at the top of every shell - see `PersonalityBanner`.
public enum Kitty {
    public static let art = #"""
                  ＿＿
    　　 　　　🌸＞　　フ
    　　　 　　| 　_　 _l
    　  　  　／` ミ＿xノ 
    　　 　 /　　　 　 |
    　　　 /　 ヽ　　 ﾉ
    　 　 │　　|　|　|
    　／￣|　　 |　|　|
    　| (￣ヽ＿_ヽ_)__)
    　＼二つ
    """#

    /// Splits `text` into bubble words.
    ///
    /// Spaces, except inside a kaomoji. `( ˘︹˘ )` and `(⁄ ⁄•⁄ω⁄•⁄ ⁄)` contain
    /// spaces and are the *point* of the greetings - breaking one across two
    /// lines turns a face into punctuation - so a parenthesised run is held
    /// together as one word. Unbalanced brackets cannot run away: the run
    /// ends at the next space if no closing bracket arrives.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "（" { depth += 1 }
            if character == ")" || character == "）" { depth = max(0, depth - 1) }
            if (character == " " || character.isNewline), depth == 0 {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Wraps `text` at `width` *columns*, breaking at spaces, and never
    /// producing an empty bubble.
    ///
    /// Columns, not characters: see `DisplayWidth`. A greeting full of
    /// full-width kaomoji measures up to three columns wider than its
    /// grapheme count, which is a bubble whose right edge does not line up.
    static func wrap(_ text: String, width: Int = 38) -> [String] {
        let words = words(in: text)
        guard !words.isEmpty else { return [""] }
        var lines: [String] = []
        var line = ""
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            if !line.isEmpty, DisplayWidth.columns(of: candidate) > width {
                lines.append(line)
                line = word
            } else {
                line = candidate
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// A speech bubble above the cat, cowsay-style.
    public static func say(_ text: String, width: Int = 38) -> String {
        let lines = wrap(text, width: width)
        // Columns, so the border lines up under full-width characters.
        let columns = lines.map { DisplayWidth.columns(of: $0) }.max() ?? 0
        var bubble = [" " + String(repeating: "_", count: columns + 2)]
        if lines.count == 1 {
            bubble.append("< \(DisplayWidth.padded(lines[0], to: columns)) >")
        } else {
            for (index, line) in lines.enumerated() {
                let padded = DisplayWidth.padded(line, to: columns)
                switch index {
                case 0: bubble.append("/ \(padded) \\")
                case lines.count - 1: bubble.append("\\ \(padded) /")
                default: bubble.append("| \(padded) |")
                }
            }
        }
        bubble.append(" " + String(repeating: "-", count: columns + 2))
        bubble.append("        \\")
        bubble.append("         \\")
        return bubble.joined(separator: "\n") + "\n" + art
    }

    /// The widest line of the cat herself, in columns - what a terminal has
    /// to be able to show before any of this is worth printing.
    public static var artColumns: Int {
        art.split(separator: "\n").map { DisplayWidth.columns(of: $0) }.max() ?? 0
    }
}
