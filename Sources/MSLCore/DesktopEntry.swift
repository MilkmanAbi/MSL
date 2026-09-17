import Foundation

/// Where a `.desktop` entry came from. Shown in the UI, because once
/// Flatpak and Snap directories are scanned the same application
/// legitimately appears more than once with an identical `Name=` and the
/// user has to be able to tell the copies apart.
public enum AppSource: String, Codable, Hashable, Sendable {
    case system
    case user
    case flatpak
    case snap

    public var label: String {
        switch self {
        case .system: return "System"
        case .user: return "User"
        case .flatpak: return "Flatpak"
        case .snap: return "Snap"
        }
    }

    /// Classified by path prefix - there is no key in the file that says
    /// this, and the exporting directory is the only reliable signal.
    public static func classify(path: String) -> AppSource {
        if path.contains("/flatpak/") { return .flatpak }
        if path.hasPrefix("/var/lib/snapd/") || path.hasPrefix("/snap/") { return .snap }
        if path.hasPrefix("/root/") || path.hasPrefix("/home/") { return .user }
        return .system
    }
}

/// A parsed `.desktop` file, per the freedesktop.org Desktop Entry
/// Specification v1.5.
///
/// The parser aims to survive real-world files rather than only
/// well-formed ones: CRLF endings, a UTF-8 BOM, Latin-1 bytes in a file
/// that claims UTF-8, `Key [locale] = value` with stray spaces, duplicate
/// keys, duplicate groups, missing `[Desktop Entry]`, unterminated quotes
/// in `Exec`, and `Icon=` values that are absolute paths rather than theme
/// names all appear in the wild and none of them should lose the entry.
public struct DesktopEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let genericName: String?
    public let comment: String?
    /// Raw `Icon=` value: either a bare theme name ("krita") or an
    /// absolute path (Snap ships `/snap/foo/current/meta/gui/icon.png`).
    public let icon: String?
    public let exec: String
    public let tryExec: String?
    public let terminal: Bool
    public let categories: [String]
    public let keywords: [String]
    public let source: AppSource
    /// `Exec=` tokenized into arguments with field codes resolved. Empty
    /// only if `Exec=` was unusable.
    public let argv: [String]

    /// `argv` as a single shell-safe command line.
    ///
    /// Every argument is single-quoted, because this string is
    /// interpolated into a command sent through `ShellClient`: a path
    /// containing a space would otherwise split into two arguments, and a
    /// `.desktop` file containing `;` or a backtick in `Exec=` would run
    /// whatever followed it in the guest. `.desktop` files are ordinary
    /// files inside the guest, so they are exactly as trustworthy as
    /// whatever put them there.
    public var launchCommand: String {
        argv.map(DesktopEntry.shellQuote).joined(separator: " ")
    }

    /// Wraps `argument` in single quotes, ending and reopening the quoted
    /// run around any embedded single quote (`'\''`) - the only way to
    /// make a POSIX shell treat a string as fully literal.
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Parses `.desktop` files. Separated from the scanning that fetches them
/// so it can be tested against pathological input without a guest.
public enum DesktopEntryParser {

    // MARK: - Public entry points

    /// Parses one file's text. Returns `nil` when the entry should not be
    /// shown at all (wrong `Type`, `NoDisplay`, `Hidden`, or no usable
    /// `Name`/`Exec`).
    public static func parse(text: String, path: String) -> DesktopEntry? {
        let group = parseGroups(text)["Desktop Entry"] ?? [:]
        guard !group.isEmpty else { return nil }

        func value(_ key: String) -> String? { localized(group, key) }
        func unlocalized(_ key: String) -> String? {
            group[key]?.first(where: { $0.locale == nil })?.value ?? group[key]?.first?.value
        }

        // `Type` is required to be `Application`, but a missing `Type` is
        // common enough in hand-written files that treating it as absent
        // rather than disqualifying is the friendlier reading.
        if let type = unlocalized("Type"), !type.isEmpty, type != "Application" { return nil }

        // `NoDisplay` means "installed but not shown in menus"; `Hidden`
        // means the spec's "deleted, as if it were not installed at all".
        // Both are honoured.
        if isTrue(unlocalized("NoDisplay")) || isTrue(unlocalized("Hidden")) { return nil }

        // `OnlyShowIn`/`NotShowIn` are deliberately NOT honoured. They gate
        // on `XDG_CURRENT_DESKTOP`, and MSL is not GNOME, KDE or any other
        // value they name - obeying them would hide every "GNOME only" app
        // even though it runs perfectly well under mslgd.

        guard let rawName = value("Name")?.trimmingCharacters(in: .whitespaces), !rawName.isEmpty,
              let rawExec = unlocalized("Exec")?.trimmingCharacters(in: .whitespaces), !rawExec.isEmpty
        else { return nil }

        let icon = unlocalized("Icon").map { $0.trimmingCharacters(in: .whitespaces) }
        let argv = execArgv(rawExec, name: rawName, path: path, icon: icon)
        guard !argv.isEmpty else { return nil }

        return DesktopEntry(
            path: path,
            name: rawName,
            genericName: value("GenericName").flatMap { $0.isEmpty ? nil : $0 },
            comment: value("Comment").flatMap { $0.isEmpty ? nil : $0 },
            icon: (icon?.isEmpty ?? true) ? nil : icon,
            exec: rawExec,
            tryExec: unlocalized("TryExec").flatMap { $0.isEmpty ? nil : $0 },
            terminal: isTrue(unlocalized("Terminal")),
            categories: splitList(unlocalized("Categories") ?? ""),
            keywords: splitList(value("Keywords") ?? ""),
            source: AppSource.classify(path: path),
            argv: argv)
    }

    /// Splits the marker-delimited stream produced by `DesktopEntryScanner`
    /// back into individual files and parses each.
    public static func parseStream(_ output: String) -> [DesktopEntry] {
        var entries: [DesktopEntry] = []
        var currentPath: String?
        var body = ""

        func flush() {
            defer { body = "" }
            guard let path = currentPath, let entry = parse(text: body, path: path) else { return }
            entries.append(entry)
        }

        // The scan comes back through a PTY, which turns every "\n" into
        // "\r\n". Unnormalized, that CRLF grapheme never matched the split,
        // the whole stream was one line, no marker matched, and every scan
        // reported "Found 0 applications". See `normalize`.
        for rawLine in normalize(output).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(marker), line.hasSuffix("===") {
                flush()
                currentPath = String(line.dropFirst(marker.count).dropLast(3))
                continue
            }
            guard currentPath != nil else { continue }
            body += line + "\n"
        }
        flush()
        return entries
    }

    static let marker = "===MSL_DESKTOP_ENTRY:"

    // MARK: - File structure

    struct Entry: Hashable {
        let locale: String?
        let value: String
    }

    /// group name -> key -> [(locale, value)], in file order.
    ///
    /// Duplicate keys and duplicate groups are both forbidden by the spec
    /// and both occur; first-wins is applied per (key, locale) pair, and a
    /// repeated group merges into the first rather than replacing it.
    static func parseGroups(_ text: String) -> [String: [String: [Entry]]] {
        var groups: [String: [String: [Entry]]] = [:]
        var current: String?

        for rawLine in normalize(text).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // A BOM survives on the first line if the file had one.
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                // Tolerates a missing `]` rather than dropping the group.
                let inner = trimmed.dropFirst()
                current = String(inner.hasSuffix("]") ? inner.dropLast() : inner)
                if groups[current!] == nil { groups[current!] = [:] }
                continue
            }

            guard let group = current, let equals = trimmed.firstIndex(of: "=") else { continue }
            let rawKey = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: equals)...])
            guard !rawKey.isEmpty else { continue }

            let (key, locale) = splitLocale(rawKey)
            let entry = Entry(locale: locale, value: unescape(trimLeadingSpaces(rawValue)))
            var keys = groups[group] ?? [:]
            var list = keys[key] ?? []
            guard !list.contains(where: { $0.locale == locale }) else { continue }
            list.append(entry)
            keys[key] = list
            groups[group] = keys
        }
        return groups
    }

    /// CRLF and lone-CR endings both appear; both become LF so the line
    /// split below is the only place that has to care.
    ///
    /// The check is over unicode *scalars* on purpose. Swift treats CRLF as
    /// a single grapheme cluster, so `text.contains("\r")` - comparing
    /// against the lone-CR Character - is `false` for a CRLF file, and
    /// `split(separator: "\n")` does not match the CRLF grapheme either.
    /// Together those turned an entire CRLF `.desktop` file into one
    /// unparseable line.
    static func normalize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\r" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// The spec says space around `=` is ignored. Only *leading* space is
    /// stripped from the value: a trailing space can be meaningful (and
    /// where it isn't, callers trim their own fields).
    private static func trimLeadingSpaces(_ value: String) -> String {
        String(value.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// `Name[de_DE.UTF-8@euro]` -> ("Name", "de_DE.UTF-8@euro").
    /// Stray spaces before the bracket (`Name [de]`) are tolerated.
    static func splitLocale(_ rawKey: String) -> (key: String, locale: String?) {
        guard rawKey.hasSuffix("]"), let open = rawKey.firstIndex(of: "[") else {
            return (rawKey, nil)
        }
        let key = String(rawKey[rawKey.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let locale = String(rawKey[rawKey.index(after: open)..<rawKey.index(before: rawKey.endIndex)])
        return (key.isEmpty ? rawKey : key, locale.isEmpty ? nil : locale)
    }

    /// `\s \n \t \r \\` per the spec. A backslash before anything else is
    /// left alone: Windows-style paths and stray backslashes in `Comment=`
    /// are far more common in practice than a typo'd escape, and mangling
    /// them is worse than passing them through.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let next = iterator.next() else { result.append("\\"); break }
            switch next {
            case "s": result.append(" ")
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            default: result.append("\\"); result.append(next)
            }
        }
        return result
    }

    /// Semicolon-separated list value, honouring `\;` as a literal
    /// semicolon and dropping the optional trailing separator.
    static func splitList(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append(character == ";" ? ";" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ";" {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { items.append(current) }
        return items.filter { !$0.isEmpty }
    }

    private static func isTrue(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    // MARK: - Locale selection

    /// Picks the best translation of `key` for the user's preferred
    /// languages, in the spec's documented order:
    /// `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`, `lang@MODIFIER`, `lang`,
    /// then the unlocalized value.
    static func localized(_ group: [String: [Entry]], _ key: String, locales: [String]? = nil) -> String? {
        guard let entries = group[key], !entries.isEmpty else { return nil }
        let unlocalized = entries.first(where: { $0.locale == nil })?.value

        for candidate in locales ?? preferredLocales() {
            if let match = entries.first(where: { $0.locale.map { normalizeLocale($0) } == candidate }) {
                return match.value
            }
        }
        return unlocalized ?? entries.first?.value
    }

    /// Candidate locale strings from most to least specific, derived from
    /// the user's language preferences. `en-US` arrives hyphenated from
    /// `Locale`; `.desktop` files use `en_US`.
    static func preferredLocales() -> [String] {
        var candidates: [String] = []
        for identifier in Locale.preferredLanguages {
            let normalized = normalizeLocale(identifier)
            let modifier = normalized.split(separator: "@").last.map(String.init)
            let base = String(normalized.split(separator: "@")[0])
            let language = String(base.split(separator: "_")[0])
            let hasCountry = base.contains("_")

            if hasCountry, modifier != nil { candidates.append(normalized) }
            if hasCountry { candidates.append(base) }
            if let modifier { candidates.append("\(language)@\(modifier)") }
            candidates.append(language)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// `en-US.UTF-8` -> `en_US`: hyphens become underscores and the
    /// encoding is dropped, because `.desktop` locale suffixes are matched
    /// without it.
    static func normalizeLocale(_ identifier: String) -> String {
        var value = identifier.replacingOccurrences(of: "-", with: "_")
        if let dot = value.firstIndex(of: ".") {
            // Keep any @modifier that followed the encoding.
            let tail = value[dot...]
            let modifier = tail.firstIndex(of: "@").map { String(tail[$0...]) } ?? ""
            value = String(value[value.startIndex..<dot]) + modifier
        }
        return value
    }

    // MARK: - Exec

    /// Turns an `Exec=` value into an argument vector.
    ///
    /// `Exec` is not a shell command line - the spec gives it its own
    /// quoting rules - so it is tokenized rather than split on spaces:
    /// `Exec="/opt/My App/bin/foo" %U` is one argument and a field code,
    /// not four fragments.
    static func execArgv(_ exec: String, name: String, path: String, icon: String?) -> [String] {
        var argv: [String] = []
        for token in tokenize(exec) {
            guard let resolved = resolveFieldCodes(token, name: name, path: path) else { continue }
            argv.append(resolved)
        }
        return argv
    }

    /// Splits on unquoted whitespace, honouring double quotes and the
    /// backslash escapes the spec defines inside them (`\"`, `` \` ``,
    /// `\$`, `\\`). Single quotes are *not* quoting characters in `Exec`,
    /// but they are reserved, so a lone one is kept literally rather than
    /// swallowing the rest of the line. An unterminated quote yields the
    /// rest of the value as one argument instead of dropping it.
    static func tokenize(_ exec: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var inQuotes = false
        var iterator = exec.makeIterator()

        func end() {
            if started { tokens.append(current) }
            current = ""
            started = false
        }

        while let character = iterator.next() {
            if inQuotes {
                if character == "\\" {
                    if let next = iterator.next() {
                        // Only these four are escapable inside quotes; any
                        // other backslash is literal.
                        if next == "\"" || next == "`" || next == "$" || next == "\\" {
                            current.append(next)
                        } else {
                            current.append("\\")
                            current.append(next)
                        }
                    } else {
                        current.append("\\")
                    }
                } else if character == "\"" {
                    inQuotes = false
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                started = true
            case " ", "\t", "\n":
                end()
            default:
                started = true
                current.append(character)
            }
        }
        end()
        return tokens
    }

    /// Applies the field codes in one already-tokenized argument.
    ///
    /// Returns `nil` when the whole argument should disappear: MSL launches
    /// applications with no document, so `%f`/`%F`/`%u`/`%U` have nothing
    /// to expand to, and an option that exists only to introduce one
    /// (`--file=%f`) has to go with it rather than being passed an empty
    /// string. `%c` and `%k` are substituted, since their values are known.
    /// The deprecated codes are dropped, as the spec directs.
    static func resolveFieldCodes(_ token: String, name: String, path: String) -> String? {
        guard token.contains("%") else { return token }

        var result = ""
        var sawFileCode = false
        var iterator = token.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else { result.append(character); continue }
            guard let code = iterator.next() else { break }
            switch code {
            case "%": result.append("%")
            case "c": result.append(name)
            case "k": result.append(path)
            case "f", "F", "u", "U": sawFileCode = true
            // `%i` expands to `--icon <name>`, which MSL has no use for,
            // and the deprecated codes are removed outright.
            case "i", "d", "D", "n", "N", "v", "m": break
            // An unknown code is not a code; keep it as typed.
            default: result.append("%"); result.append(code)
            }
        }

        if result.isEmpty { return nil }
        // `--file=` style leftovers: the argument existed only to carry the
        // document that is no longer there.
        if sawFileCode, result.hasSuffix("=") || result.hasSuffix(":") { return nil }
        return result
    }
}
