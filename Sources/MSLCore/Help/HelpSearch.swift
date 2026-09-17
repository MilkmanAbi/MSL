import Foundation

/// One place in the guide that matches a search.
public struct HelpSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { articleID + "#" + anchor }
    public let articleID: String
    /// Empty for the top of the article.
    public let anchor: String
    public let articleTitle: String
    public let sectionTitle: String?
    public let chapterTitle: String
    public let snippet: String
    public let score: Double
    /// Words to highlight: the query's own, plus any synonyms that matched,
    /// so a search for "ram" lights up "memory" where that is what matched.
    public let highlightTerms: [String]
}

/// Full-text search over the guide, down to the section.
///
/// Sections rather than articles, so "where do I change the RAM" lands on
/// the heading that answers it instead of the top of a long article.
///
/// Matching runs in widening passes, and a wider pass only runs when the
/// narrower one found nothing: every word must match exactly or as a
/// prefix; then words that matched nothing may match with a typo; then any
/// word may match. Fuzzy matching on every keystroke, over a guide this
/// size, would be slower and would confidently surface the wrong article.
public final class HelpSearchIndex: @unchecked Sendable {
    struct Entry {
        let articleID: String
        let anchor: String
        let articleTitle: String
        let sectionTitle: String?
        let chapterTitle: String
        let text: String
        /// The first section of an article carries the article's own title
        /// and keywords at full weight; later sections carry them lightly.
        let isLead: Bool
        let order: Int
        let headingFolded: String
        let titleFolded: String
        let textFolded: String
    }

    enum Field { case title, heading, keywords, body }

    struct Posting {
        let entry: Int
        let field: Field
        let count: Int
    }

    private(set) var entries: [Entry] = []
    private var postings: [String: [Posting]] = [:]
    private var vocabulary: [String] = []

    public init(chapters: [HelpChapter]) {
        var order = 0
        for chapter in chapters {
            for article in chapter.articles {
                for (position, section) in article.document.sections.enumerated() {
                    let entry = Entry(
                        articleID: article.id, anchor: section.anchor, articleTitle: article.title,
                        sectionTitle: section.title, chapterTitle: chapter.title,
                        text: section.text.isEmpty ? article.summary : section.text,
                        isLead: position == 0, order: order,
                        headingFolded: HelpSearchIndex.fold(section.title ?? ""),
                        titleFolded: HelpSearchIndex.fold(article.title),
                        textFolded: HelpSearchIndex.fold(section.text))
                    let number = entries.count
                    entries.append(entry)
                    order += 1

                    add(article.title, field: .title, entry: number)
                    add(article.keywords.joined(separator: " "), field: .keywords, entry: number)
                    if let title = section.title { add(title, field: .heading, entry: number) }
                    add(section.text, field: .body, entry: number)
                    // The summary belongs to the top of the article.
                    if position == 0 { add(article.summary, field: .body, entry: number) }
                }
            }
        }
        vocabulary = postings.keys.sorted()
    }

    private func add(_ text: String, field: Field, entry: Int) {
        var counts: [String: Int] = [:]
        for token in HelpSearchIndex.tokens(text) { counts[token, default: 0] += 1 }
        for (token, count) in counts {
            postings[token, default: []].append(Posting(entry: entry, field: field, count: count))
        }
    }

    // MARK: - Searching

    public func search(_ query: String, limit: Int = 60) -> [HelpSearchResult] {
        let terms = HelpSearchIndex.queryTerms(query)
        guard !terms.isEmpty else { return [] }

        var matches = score(terms, fuzzy: false, requireAll: true)
        if matches.isEmpty { matches = score(terms, fuzzy: true, requireAll: true) }
        if matches.isEmpty { matches = score(terms, fuzzy: true, requireAll: false) }

        // A phrase that appears as written is worth more than its words
        // appearing separately.
        let phrase = HelpSearchIndex.fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if phrase.contains(" ") {
            for (entry, match) in matches {
                let e = entries[entry]
                var bonus = 0.0
                if e.headingFolded.contains(phrase) { bonus += 12 }
                if e.isLead, e.titleFolded.contains(phrase) { bonus += 12 }
                if e.textFolded.contains(phrase) { bonus += 4 }
                matches[entry] = (match.score + bonus, match.highlights)
            }
        }

        let ranked = matches.sorted { lhs, rhs in
            lhs.value.score != rhs.value.score
                ? lhs.value.score > rhs.value.score
                : entries[lhs.key].order < entries[rhs.key].order
        }

        // At most three places per article, so one long article can't bury
        // everything else.
        var perArticle: [String: Int] = [:]
        var results: [HelpSearchResult] = []
        for (entryIndex, match) in ranked {
            let entry = entries[entryIndex]
            guard perArticle[entry.articleID, default: 0] < 3 else { continue }
            perArticle[entry.articleID, default: 0] += 1
            let highlights = HelpSearchIndex.orderedUnique(match.highlights)
            results.append(HelpSearchResult(
                articleID: entry.articleID, anchor: entry.anchor, articleTitle: entry.articleTitle,
                sectionTitle: entry.sectionTitle, chapterTitle: entry.chapterTitle,
                snippet: HelpSearchIndex.snippet(from: entry.text, highlighting: highlights),
                score: match.score, highlightTerms: highlights))
            if results.count == limit { break }
        }
        return results
    }

    private struct Variant {
        let token: String
        let weight: Double
        /// The word as a reader would recognise it, for highlighting.
        let display: String
    }

    private func score(_ terms: [String], fuzzy: Bool, requireAll: Bool) -> [Int: (score: Double, highlights: [String])] {
        var totals: [Int: (score: Double, highlights: [String])] = [:]
        var matchedTerms: [Int: Int] = [:]

        for term in terms {
            var variants = [Variant(token: HelpSearchIndex.stem(term), weight: 1, display: term)]
            for synonym in HelpSearchIndex.synonyms[term] ?? [] {
                for token in HelpSearchIndex.tokens(synonym) {
                    variants.append(Variant(token: token, weight: 0.6, display: synonym))
                }
            }

            // The best-scoring form counts towards the score; every form that
            // matched is highlighted, so "sudo poweroff" lights up "poweroff"
            // even where its synonym "shut down" scored higher.
            var best: [Int: Double] = [:]
            var seen: [Int: [String]] = [:]
            for variant in variants {
                for (vocabToken, quality) in candidates(for: variant.token, fuzzy: fuzzy) {
                    for posting in postings[vocabToken] ?? [] {
                        let entry = entries[posting.entry]
                        let tf = 1 + Double(min(posting.count - 1, 4)) * 0.15
                        let value = HelpSearchIndex.weight(posting.field, lead: entry.isLead) * quality * variant.weight * tf
                        best[posting.entry] = max(best[posting.entry] ?? 0, value)
                        seen[posting.entry, default: []].append(variant.display)
                    }
                }
            }

            for (entry, score) in best {
                totals[entry, default: (0, [])].score += score
                totals[entry, default: (0, [])].highlights += seen[entry] ?? []
                matchedTerms[entry, default: 0] += 1
            }
        }

        guard requireAll else {
            return totals.mapValues { ($0.score * 0.5, $0.highlights) }
        }
        return totals.filter { matchedTerms[$0.key] == terms.count }
    }

    /// Vocabulary words a query token can stand for, with how good a match
    /// each one is.
    private func candidates(for token: String, fuzzy: Bool) -> [(String, Double)] {
        var found: [(String, Double)] = []
        if postings[token] != nil { found.append((token, 1)) }

        // Prefixes: `vocabulary` is sorted, so they are one contiguous run.
        if token.count >= 2 {
            var low = 0
            var high = vocabulary.count
            while low < high {
                let mid = (low + high) / 2
                if vocabulary[mid] < token { low = mid + 1 } else { high = mid }
            }
            var position = low
            while position < vocabulary.count, vocabulary[position].hasPrefix(token) {
                if vocabulary[position] != token {
                    // A short prefix of a long word is weaker evidence.
                    let ratio = Double(token.count) / Double(vocabulary[position].count)
                    found.append((vocabulary[position], 0.5 + 0.3 * ratio))
                }
                position += 1
            }
        }

        if fuzzy, found.isEmpty, token.count >= 5 {
            let allowed = token.count >= 8 ? 2 : 1
            for word in vocabulary where abs(word.count - token.count) <= allowed {
                if HelpSearchIndex.editDistance(token, word, limit: allowed) != nil {
                    found.append((word, 0.45))
                }
            }
        }
        return found
    }

    static func weight(_ field: Field, lead: Bool) -> Double {
        switch field {
        case .title: return lead ? 10 : 2.5
        case .heading: return 8
        case .keywords: return lead ? 7 : 1.5
        case .body: return 1
        }
    }

    // MARK: - Text

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Folded, split on anything that isn't a letter or digit, stemmed.
    /// Modifier-key symbols are kept as words of their own so "⌘N" can be
    /// searched for.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in fold(text) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(stem(current)); current = "" }
                if "⌘⇧⌥⌃".contains(character) { tokens.append(String(character)) }
            }
        }
        if !current.isEmpty { tokens.append(stem(current)) }
        return tokens
    }

    /// Just enough stemming that "snapshots", "suspended" and "running"
    /// find "snapshot", "suspend" and "run". Prefix matching covers most of
    /// the rest, so this stays conservative.
    static func stem(_ word: String) -> String {
        guard word.count > 4, word.allSatisfy({ $0.isLetter }) else { return word }
        var stem = word
        if stem.hasSuffix("ing"), stem.count >= 6 {
            stem.removeLast(3)
        } else if stem.hasSuffix("ies") {
            stem.removeLast(3)
            stem.append("y")
        } else if stem.hasSuffix("ed"), stem.count >= 6 {
            stem.removeLast(2)
        } else if stem.hasSuffix("es"), ["sh", "ch", "ss", "x"].contains(where: { stem.dropLast(2).hasSuffix($0) }) {
            stem.removeLast(2)
        } else if stem.hasSuffix("s"), !stem.hasSuffix("ss"), !stem.hasSuffix("us"), !stem.hasSuffix("is") {
            stem.removeLast()
        }
        // "runn" -> "run", "stopp" -> "stop".
        if let last = stem.last, stem.count >= 4, stem.dropLast().last == last, !"aeioulsz".contains(last) {
            stem.removeLast()
        }
        // "restore" and "restoring" must meet somewhere, and "restoring"
        // has already lost its "e" - so every form drops it.
        if stem.count > 4, stem.hasSuffix("e") {
            stem.removeLast()
        }
        return stem
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "of", "and", "or", "is", "are", "in", "on", "at", "for", "with",
        "how", "do", "does", "can", "i", "my", "me", "it", "its", "what", "why", "when", "where",
        "you", "your", "be", "this", "that", "from", "into", "there",
    ]

    /// Unstemmed so synonyms can be looked up by the word as typed; stop
    /// words dropped unless they are all there is.
    static func queryTerms(_ query: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in fold(query) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { words.append(current); current = "" }
                if "⌘⇧⌥⌃".contains(character) { words.append(String(character)) }
            }
        }
        if !current.isEmpty { words.append(current) }
        let meaningful = words.filter { !stopWords.contains($0) }
        return orderedUnique(meaningful.isEmpty ? words : meaningful)
    }

    /// What people type, mapped to the words the guide actually uses.
    static let synonyms: [String: [String]] = [
        "ram": ["memory"], "mem": ["memory"], "memory": ["ram", "balloon"],
        "cpu": ["processor", "vcpu"], "cpus": ["processor", "vcpu"], "cores": ["processor", "vcpu"],
        "core": ["processor", "vcpu"],
        "vm": ["instance", "virtual machine"], "vms": ["instance"], "machine": ["instance"],
        "container": ["instance"], "box": ["instance"],
        "distro": ["distribution"], "os": ["distribution"], "linux": ["distribution", "guest"],
        "delete": ["remove", "trash"], "uninstall": ["remove"], "erase": ["remove"], "destroy": ["remove"],
        "fsck": ["filesystem", "check disk", "repair"], "e2fsck": ["filesystem", "repair"],
        "corrupt": ["repair", "filesystem"], "corrupted": ["repair", "filesystem"],
        "corruption": ["repair", "filesystem"], "broken": ["repair", "troubleshooting"],
        "fix": ["repair", "troubleshooting"], "boot": ["start"], "launch": ["open", "start"],
        "wifi": ["network"], "internet": ["network"], "offline": ["network"], "online": ["network"],
        "firewall": ["sandbox", "network"], "isolate": ["sandbox"], "isolation": ["sandbox"],
        "lockdown": ["sandbox", "seal"], "privacy": ["sandbox"], "security": ["sandbox"],
        "freeze": ["suspend"], "pause": ["suspend"], "sleep": ["suspend", "power"],
        "resume": ["start", "suspend"], "wake": ["power", "resume"], "lid": ["power", "sleep"],
        "backup": ["snapshot"], "backups": ["snapshot"], "checkpoint": ["snapshot"], "rollback": ["snapshot", "restore"],
        "undo": ["restore", "snapshot"],
        "dock": ["pin"], "tile": ["dock"], "spotlight": ["applications folder"],
        "shortcut": ["keyboard", "keys"], "shortcuts": ["keyboard", "keys"], "hotkey": ["keyboard", "shortcut"],
        "hotkeys": ["keyboard", "shortcut"], "keybinding": ["keyboard", "shortcut"],
        "finder": ["files"], "folder": ["files"], "copy": ["files", "drag"], "transfer": ["files", "drag"],
        "share": ["mnt", "home folder"], "shared": ["mnt", "home folder"],
        "space": ["storage", "disk"], "full": ["storage", "disk"], "size": ["storage", "disk"],
        "gb": ["storage", "disk"], "resize": ["storage", "disk"], "grow": ["storage", "disk"],
        "slow": ["memory", "performance"], "lag": ["performance", "memory"], "beachball": ["memory", "paging"],
        "crash": ["troubleshooting"], "error": ["troubleshooting"], "problem": ["troubleshooting"],
        "log": ["logs"], "debug": ["logs", "troubleshooting"],
        "wireshark": ["traffic monitor"], "packets": ["traffic monitor"], "monitor": ["traffic"],
        "password": ["user", "first start"], "username": ["user"], "login": ["user"], "sudo": ["root", "user"],
        "clock": ["time"], "time": ["clock"], "date": ["clock"],
        "gui": ["applications", "mslgd"], "app": ["applications"], "apps": ["applications"],
        "program": ["applications"], "window": ["applications", "mslgd"], "windows": ["applications", "mslgd"],
        "x11": ["mslgd"], "xorg": ["mslgd"], "xquartz": ["mslgd"], "display": ["mslgd", "graphics"],
        "shell": ["terminal"], "console": ["terminal"], "bash": ["terminal", "shell"], "zsh": ["terminal", "shell"],
        "cli": ["command line", "msl"], "command": ["command line", "terminal"],
        "daemon": ["mslhd", "background service"], "service": ["mslhd"], "mslhd": ["background service"],
        "download": ["install"], "setup": ["install", "first start"], "new": ["create"],
        "keyboard": ["shortcut", "input"], "mouse": ["input"],
        "hibernation": ["hibernate"], "shutdown": ["shut down"], "poweroff": ["shut down"],
        "restart": ["shut down", "start"], "reboot": ["shut down", "start"],
        "package": ["package manager"], "apt": ["package manager"], "apk": ["package manager"],
        "pacman": ["package manager"], "dnf": ["package manager"],
        "flatpak": ["source"], "snap": ["snapshot", "source"],
        "kaomoji": ["greeter"], "cat": ["kitty", "mascot"], "kitty": ["mascot"], "melon": ["logo"],
    ]

    // MARK: - Snippets

    /// The sentence around the first match, trimmed to a readable length.
    static func snippet(from text: String, highlighting terms: [String], radius: Int = 110) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        var hit: Range<String.Index>?
        for term in terms {
            if let range = wordStartRange(of: term, in: flat),
               hit == nil || range.lowerBound < hit!.lowerBound {
                hit = range
            }
        }
        guard let hit else { return trim(flat, to: radius * 2) }

        let enders: Set<Character> = [".", "!", "?"]
        var start = hit.lowerBound
        var steps = 0
        while start > flat.startIndex, steps < radius {
            let previous = flat.index(before: start)
            if enders.contains(flat[previous]) { break }
            start = previous
            steps += 1
        }
        var end = hit.upperBound
        steps = 0
        while end < flat.endIndex, steps < radius {
            let character = flat[end]
            end = flat.index(after: end)
            if enders.contains(character) { break }
            steps += 1
        }
        // A sentence that followed a quotation starts with its closing mark.
        var result = String(flat[start..<end])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'’").union(.whitespaces))
        if start > flat.startIndex, !enders.contains(flat[flat.index(before: start)]) { result = "…" + result }
        if end < flat.endIndex, let last = result.last, !enders.contains(last) { result += "…" }
        return result
    }

    /// The first place `term` starts a word - so "ram" finds "RAM", not the
    /// middle of "framework".
    public static func wordStartRange(of term: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex { return range }
            let before = text[text.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func trim(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Helpers

    static func orderedUnique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    /// Edit distance counting a swapped pair of neighbouring letters as one
    /// edit (optimal string alignment) - "memroy" is one slip, not two - or
    /// nil when it exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return nil }
        guard !a.isEmpty, !b.isEmpty else {
            let distance = max(a.count, b.count)
            return distance <= limit ? distance : nil
        }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        let distance = d[a.count][b.count]
        return distance <= limit ? distance : nil
    }
}
