import Foundation

/// Batch rename, the feature Finder never grew: take a pile of files and
/// rewrite their names by a rule - find & replace (plain or regex), a prefix
/// or suffix, sequential numbering - with a live before/after preview.
///
/// Pure name arithmetic, no filesystem: given the old names it computes the new
/// ones. `FilesModel` applies the result through the provider, and this is
/// tested on its own. The order of operations is fixed and documented because
/// "why did my rename do *that*" is the whole failure mode of a tool like this.
public enum PowerRename {
    /// Which part of the name a rule touches.
    public enum Target: String, CaseIterable, Sendable {
        case nameOnly   // the stem, leaving the extension alone (the default)
        case fullName   // the whole thing, extension included
        case extensionOnly

        public var label: String {
            switch self {
            case .nameOnly: return "Name only"
            case .fullName: return "Full name"
            case .extensionOnly: return "Extension only"
            }
        }
    }

    public enum NumberPosition: String, CaseIterable, Sendable {
        case suffix, prefix
        public var label: String { self == .suffix ? "After name" : "Before name" }
    }

    /// One case transform to finish with, or none.
    public enum LetterCase: String, CaseIterable, Sendable {
        case unchanged, lower, upper, title
        public var label: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .title: return "Title Case"
            }
        }
    }

    public struct Options: Equatable, Sendable {
        public var find = ""
        public var replacement = ""
        public var useRegex = false
        public var caseSensitive = false
        public var target: Target = .nameOnly

        public var prefix = ""
        public var suffix = ""

        public var numbering = false
        public var numberStart = 1
        public var numberIncrement = 1
        public var numberPadding = 2
        public var numberPosition: NumberPosition = .suffix
        public var numberSeparator = ""

        public var letterCase: LetterCase = .unchanged

        public init() {}

        /// Whether the options would change anything at all - so the UI can
        /// disable Apply on an empty rule rather than "renaming" to the same
        /// names.
        public var isNoOp: Bool {
            find.isEmpty && prefix.isEmpty && suffix.isEmpty
                && !numbering && letterCase == .unchanged
        }

        /// Nil unless `useRegex` and the pattern is invalid - the UI shows it
        /// instead of silently doing nothing.
        public var regexError: String? {
            guard useRegex, !find.isEmpty else { return nil }
            do { _ = try NSRegularExpression(pattern: find); return nil }
            catch { return "Invalid regular expression" }
        }
    }

    /// Splits a filename into the stem and its extension (no dot). A leading
    /// dot is part of the stem, not an extension - `.bashrc` is all name - so
    /// dotfiles rename sensibly.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The new name for `name`, the `index`-th file in the (sorted) selection.
    public static func rename(_ name: String, index: Int, options: Options) -> String {
        let (stem, ext) = split(name)

        // 1. Find & replace, on whichever part the target names.
        var newStem = stem
        var newExt = ext
        switch options.target {
        case .nameOnly: newStem = replace(stem, options)
        case .extensionOnly: newExt = replace(ext, options)
        case .fullName:
            let whole = replace(name, options)
            let s = split(whole); newStem = s.stem; newExt = s.ext
        }

        // 2. Affixes, on the stem.
        newStem = options.prefix + newStem + options.suffix

        // 3. Sequential number, on the stem.
        if options.numbering {
            let n = options.numberStart + index * options.numberIncrement
            let digits = String(format: "%0\(max(1, options.numberPadding))d", max(0, n))
            let token = options.numberSeparator + digits
            newStem = options.numberPosition == .suffix ? newStem + token : digits + options.numberSeparator + newStem
        }

        // 4. Letter case, last, so it applies to everything added above.
        newStem = applyCase(newStem, options.letterCase)
        if options.target == .extensionOnly || options.target == .fullName {
            newExt = applyCase(newExt, options.letterCase)
        }

        return newExt.isEmpty ? newStem : newStem + "." + newExt
    }

    private static func replace(_ text: String, _ options: Options) -> String {
        guard !options.find.isEmpty else { return text }
        if options.useRegex {
            var opts: NSRegularExpression.Options = []
            if !options.caseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: options.find, options: opts) else {
                return text  // invalid pattern: leave it be (the UI flags it)
            }
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range,
                                                  withTemplate: options.replacement)
        }
        return text.replacingOccurrences(
            of: options.find, with: options.replacement,
            options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    private static func applyCase(_ text: String, _ letterCase: LetterCase) -> String {
        switch letterCase {
        case .unchanged: return text
        case .lower: return text.lowercased()
        case .upper: return text.uppercased()
        case .title: return text.capitalized
        }
    }

    /// One row of the preview: what a file is called now, what it would be
    /// called, and whether that new name is a problem.
    public struct Preview: Identifiable, Equatable, Sendable {
        public let id: String       // the original path
        public let oldName: String
        public let newName: String
        public let problem: Problem?
        public var changed: Bool { oldName != newName }

        public enum Problem: Equatable, Sendable {
            case empty                 // rule produced an empty name
            case slash                 // a "/" would move it elsewhere
            case duplicate             // two files map to the same new name
            case collision             // new name already exists in the folder
        }
    }

    /// Builds the preview for a whole selection, in the given order. `existing`
    /// is the set of names already in the folder (to catch collisions with
    /// files that aren't being renamed).
    public static func preview(paths: [String], options: Options,
                               existing: Set<String> = []) -> [Preview] {
        var counts: [String: Int] = [:]
        let planned: [(path: String, old: String, new: String)] = paths.enumerated().map { index, path in
            let old = (path as NSString).lastPathComponent
            let new = options.isNoOp ? old : rename(old, index: index, options: options)
            counts[new, default: 0] += 1
            return (path, old, new)
        }
        // Names among the selection that survive unchanged mustn't count as a
        // collision against themselves.
        let renamedAway = Set(planned.filter { $0.old != $0.new }.map(\.old))
        return planned.map { item in
            let problem: Preview.Problem?
            if item.new.isEmpty { problem = .empty }
            else if item.new.contains("/") { problem = .slash }
            else if counts[item.new, default: 0] > 1 { problem = .duplicate }
            else if item.new != item.old, existing.contains(item.new), !renamedAway.contains(item.new) {
                problem = .collision
            } else { problem = nil }
            return Preview(id: item.path, oldName: item.old, newName: item.new, problem: problem)
        }
    }
}
