import Foundation

// The help guide's content model, and the small markup it is written in.
//
// The guide is compiled into the app as Swift string literals rather than
// shipped as resource files. A resource has to be kept in step across
// `Package.swift`, `Assets/`, `sync-assets.sh` and `build-app.sh`, and
// missing one produces a blank Help window in the shipped app with no build
// error - exactly the failure `MSLAsset` exists because of. A string literal
// cannot fail to ship.
//
// Everything here is UI-free so it can be tested: `MSLCoreTests` is the only
// test target, and the app only draws what this produces.

/// A colour, named rather than drawn - MSLCore has no business importing
/// SwiftUI. The app maps each one to a real colour.
public enum HelpTint: String, CaseIterable, Sendable {
    case melon, rind, watermelon, blue, indigo, purple, pink, orange, mango, green, teal, red, gray
}

/// The boxed asides. `aside` is the guide being a person for a moment.
public enum HelpCalloutKind: String, CaseIterable, Sendable {
    case tip, note, important, warning, danger, aside
}

public struct HelpShortcut: Equatable, Sendable {
    public let keys: String
    public let action: String
}

/// One tile in a grid of features: "here are the five things on this tab".
public struct HelpFeature: Equatable, Sendable {
    public let symbol: String
    public let tint: HelpTint
    public let title: String
    public let text: String
}

public enum HelpBlock: Equatable, Sendable {
    case heading(level: Int, text: String, anchor: String)
    case paragraph(String)
    case bullets([String])
    case steps([String])
    /// `text` can hold several paragraphs, separated by a blank line.
    case callout(kind: HelpCalloutKind, title: String?, text: String)
    case code(label: String?, text: String)
    case table(header: [String], rows: [[String]])
    case shortcuts([HelpShortcut])
    case features([HelpFeature])
    case divider
}

/// A stretch of an article that search can land on: the top of the article,
/// or any heading and what follows it up to the next one.
public struct HelpSection: Equatable, Sendable {
    /// Empty for the top of the article.
    public let anchor: String
    public let title: String?
    /// 0 for the top of the article, otherwise the heading level.
    public let level: Int
    /// Plain text, for search - markup stripped.
    public let text: String
    public let blocks: Range<Int>
}

public struct HelpDocument: Equatable, Sendable {
    public let blocks: [HelpBlock]
    public let sections: [HelpSection]

    /// Headings only, for an "on this page" list.
    public var outline: [HelpSection] { sections.filter { $0.level > 0 } }

    public var wordCount: Int {
        sections.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

public struct HelpArticle: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// One sentence, shown under the title and in lists.
    public let summary: String
    /// Words someone might search for that the text itself doesn't use.
    public let keywords: [String]
    /// Other article ids, shown as "Related" at the end.
    public let related: [String]
    public let source: String
    public let document: HelpDocument

    public init(id: String, title: String, symbol: String, summary: String,
                keywords: [String] = [], related: [String] = [], body: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.keywords = keywords
        self.related = related
        self.source = body
        self.document = HelpMarkup.parse(body)
    }

    /// At an unhurried 200 words a minute, never zero.
    public var readingMinutes: Int {
        max(1, Int((Double(document.wordCount) / 200).rounded(.up)))
    }
}

public struct HelpChapter: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let tint: HelpTint
    public let blurb: String
    public let articles: [HelpArticle]

    public init(id: String, title: String, symbol: String, tint: HelpTint, blurb: String, articles: [HelpArticle]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.blurb = blurb
        self.articles = articles
    }
}

/// `help:article-id` or `help:article-id#anchor` - how articles link to each
/// other from inside ordinary Markdown links.
public struct HelpLink: Equatable, Sendable {
    public static let scheme = "help"

    public let article: String
    public let anchor: String?

    public init(article: String, anchor: String? = nil) {
        self.article = article
        self.anchor = (anchor?.isEmpty ?? true) ? nil : anchor
    }

    /// Reads the string form rather than `URL`'s components: `help:x#y` is
    /// not a hierarchical URL, and `URL.path` is empty for it.
    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    public init?(string: String) {
        let prefix = HelpLink.scheme + ":"
        guard string.hasPrefix(prefix) else { return nil }
        let rest = string.dropFirst(prefix.count)
        let parts = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        self.init(article: String(first), anchor: parts.count > 1 ? String(parts[1]) : nil)
    }

    public var url: URL {
        URL(string: HelpLink.scheme + ":" + article + (anchor.map { "#" + $0 } ?? ""))!
    }

    /// Every `help:` link in a piece of markup, in order.
    public static func links(in source: String) -> [HelpLink] {
        guard let pattern = try? NSRegularExpression(pattern: #"\]\((help:[^)\s]+)\)"#) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).flatMap { HelpLink(string: String(source[$0])) }
        }
    }
}

// MARK: - Markup

/// A deliberately small block syntax, close enough to Markdown to write
/// without thinking. Inline formatting (bold, `code`, links) is left in the
/// text for the app's `AttributedString(markdown:)` to draw.
///
///     ## Heading                  ### Smaller heading    ## Heading {#anchor}
///     - bullet                    1. numbered step
///     > [!TIP] Optional title     > more of the callout
///     ```label                    (code, verbatim)       ```
///     | table | header |          |---|---|              | a | b |
///     @keys ⌘N | New Instance     (a keyboard shortcut row)
///     @card symbol tint | Title | Text                  (a feature tile)
///     ---                         (a divider)
///
/// Lines that are none of those are joined into paragraphs.
public enum HelpMarkup {
    public static func parse(_ source: String) -> HelpDocument {
        var parser = Parser(lines: source.components(separatedBy: "\n"))
        let blocks = parser.run()
        return HelpDocument(blocks: blocks, sections: sections(for: blocks))
    }

    /// Markup reduced to the words a reader sees.
    public static func plainText(_ inline: String) -> String {
        var text = inline
        if let link = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#) {
            text = link.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        return text
    }

    public static func slug(_ text: String) -> String {
        let folded = plainText(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    /// The plain text a block contributes to search.
    static func plainText(of block: HelpBlock) -> String {
        switch block {
        case .heading(_, let text, _): return plainText(text)
        case .paragraph(let text): return plainText(text)
        case .bullets(let items), .steps(let items): return items.map(plainText).joined(separator: "\n")
        case .callout(_, let title, let text): return [title, text].compactMap { $0 }.map(plainText).joined(separator: "\n")
        case .code(_, let text): return text
        case .table(let header, let rows): return ([header] + rows).map { $0.map(plainText).joined(separator: " ") }.joined(separator: "\n")
        case .shortcuts(let items): return items.map { "\($0.keys) \(plainText($0.action))" }.joined(separator: "\n")
        case .features(let items): return items.map { "\(plainText($0.title)) \(plainText($0.text))" }.joined(separator: "\n")
        case .divider: return ""
        }
    }

    static func sections(for blocks: [HelpBlock]) -> [HelpSection] {
        var sections: [HelpSection] = []
        var start = 0
        var anchor = ""
        var title: String?
        var level = 0

        func close(at end: Int) {
            // An article that opens with a heading has no text above it;
            // an empty top section would only be a search result with
            // nothing in it.
            guard end > start || level > 0 else { return }
            // The heading itself is left out: search indexes it on its own,
            // and repeating it makes every snippet start with it twice.
            let text = blocks[start..<end]
                .filter { if case .heading = $0 { return false } else { return true } }
                .map(plainText(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
            sections.append(HelpSection(anchor: anchor, title: title, level: level, text: text, blocks: start..<end))
        }

        for (index, block) in blocks.enumerated() {
            if case .heading(let headingLevel, let text, let headingAnchor) = block {
                close(at: index)
                start = index
                anchor = headingAnchor
                title = plainText(text)
                level = headingLevel
            }
        }
        close(at: blocks.count)
        return sections
    }

    private struct Parser {
        let lines: [String]
        var index = 0
        var blocks: [HelpBlock] = []
        var paragraph: [String] = []
        var usedAnchors: Set<String> = []

        init(lines: [String]) {
            self.lines = lines.map { line in
                var trimmed = line
                while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
                return trimmed
            }
        }

        mutating func run() -> [HelpBlock] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    flushParagraph()
                    index += 1
                } else if trimmed.hasPrefix("```") {
                    flushParagraph()
                    readCode(label: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                } else if trimmed == "---" {
                    flushParagraph()
                    blocks.append(.divider)
                    index += 1
                } else if let (level, text) = heading(trimmed) {
                    flushParagraph()
                    readHeading(level: level, text: text)
                    index += 1
                } else if trimmed.hasPrefix(">") {
                    flushParagraph()
                    readCallout()
                } else if Parser.bulletText(trimmed) != nil {
                    flushParagraph()
                    blocks.append(.bullets(readList(Parser.bulletText)))
                } else if Parser.stepText(trimmed) != nil {
                    flushParagraph()
                    blocks.append(.steps(readList(Parser.stepText)))
                } else if trimmed.hasPrefix("|") {
                    flushParagraph()
                    readTable()
                } else if trimmed.hasPrefix("@keys ") {
                    flushParagraph()
                    readShortcuts()
                } else if trimmed.hasPrefix("@card ") {
                    flushParagraph()
                    readFeatures()
                } else {
                    paragraph.append(trimmed)
                    index += 1
                }
            }
            flushParagraph()
            return blocks
        }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        func heading(_ line: String) -> (Int, String)? {
            for (marker, level) in [("### ", 3), ("## ", 2), ("# ", 2)] where line.hasPrefix(marker) {
                return (level, String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }

        mutating func readHeading(level: Int, text: String) {
            var title = text
            var anchor: String?
            // `## Title {#anchor}` pins an anchor that survives rewording.
            if title.hasSuffix("}"), let open = title.range(of: "{#", options: .backwards) {
                anchor = String(title[open.upperBound..<title.index(before: title.endIndex)])
                title = String(title[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let base = anchor ?? HelpMarkup.slug(title)
            var unique = base.isEmpty ? "section" : base
            var counter = 2
            while usedAnchors.contains(unique) {
                unique = "\(base)-\(counter)"
                counter += 1
            }
            usedAnchors.insert(unique)
            blocks.append(.heading(level: level, text: title, anchor: unique))
        }

        mutating func readCode(label: String) {
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.append(lines[index])
                index += 1
            }
            index += 1 // the closing fence, if there was one
            blocks.append(.code(label: label.isEmpty ? nil : label, text: body.joined(separator: "\n")))
        }

        mutating func readCallout() {
            var body: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                body.append(content)
                index += 1
            }

            var kind = HelpCalloutKind.note
            var title: String?
            if let first = body.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
                let name = first[first.index(first.startIndex, offsetBy: 2)..<close].lowercased()
                if let parsed = HelpCalloutKind(rawValue: name) {
                    kind = parsed
                    let rest = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    title = rest.isEmpty ? nil : rest
                    body.removeFirst()
                }
            }

            // Blank `>` lines separate paragraphs; a `- ` line is a bullet of
            // its own, drawn as one; everything else joins.
            var paragraphs: [String] = []
            var current: [String] = []
            for line in body {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                    current = []
                } else if let bullet = Parser.bulletText(trimmed) {
                    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                    current = ["• " + bullet]
                } else {
                    current.append(trimmed)
                }
            }
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            blocks.append(.callout(kind: kind, title: title, text: paragraphs.joined(separator: "\n\n")))
        }

        static func bulletText(_ line: String) -> String? {
            for marker in ["- ", "* "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
            return nil
        }

        static func stepText(_ line: String) -> String? {
            guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
                  line[..<dot].allSatisfy(\.isNumber),
                  line[line.index(after: dot)...].hasPrefix(" ") else { return nil }
            return String(line[line.index(dot, offsetBy: 2)...])
        }

        /// Items, with indented lines under an item joined onto it.
        mutating func readList(_ itemText: (String) -> String?) -> [String] {
            var items: [String] = []
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let text = itemText(trimmed), !line.hasPrefix("  ") {
                    items.append(text)
                } else if !trimmed.isEmpty, line.hasPrefix("  "), !items.isEmpty {
                    items[items.count - 1] += " " + trimmed
                } else {
                    break
                }
                index += 1
            }
            return items
        }

        mutating func readTable() {
            var rows: [[String]] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { break }
                rows.append(Parser.cells(trimmed))
                index += 1
            }
            if rows.count >= 2, rows[1].allSatisfy(Parser.isSeparator) {
                blocks.append(.table(header: rows[0], rows: Array(rows.dropFirst(2))))
            } else {
                blocks.append(.table(header: [], rows: rows))
            }
        }

        static func cells(_ line: String) -> [String] {
            // `\|` is a literal bar inside a cell.
            let placeholder = "\u{0}"
            var body = line.replacingOccurrences(of: "\\|", with: placeholder)
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.components(separatedBy: "|").map {
                $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
            }
        }

        static func isSeparator(_ cell: String) -> Bool {
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }

        mutating func readShortcuts() {
            var items: [HelpShortcut] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@keys ") else { break }
                let parts = trimmed.dropFirst(6).split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    items.append(HelpShortcut(keys: parts[0].trimmingCharacters(in: .whitespaces),
                                              action: parts[1].trimmingCharacters(in: .whitespaces)))
                }
                index += 1
            }
            blocks.append(.shortcuts(items))
        }

        mutating func readFeatures() {
            var items: [HelpFeature] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@card ") else { break }
                let parts = trimmed.dropFirst(6).split(separator: "|", maxSplits: 2)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let head = parts.first?.split(separator: " ").map(String.init) ?? []
                if parts.count == 3, head.count == 2 {
                    items.append(HelpFeature(symbol: head[0], tint: HelpTint(rawValue: head[1]) ?? .gray,
                                             title: parts[1], text: parts[2]))
                }
                index += 1
            }
            blocks.append(.features(items))
        }
    }
}

// MARK: - Emoji

/// MSL's own voice uses kaomoji, never emoji - the guide included. Kaomoji
/// are full of non-ASCII symbols, so "non-ASCII" is the wrong test; this
/// looks at the emoji properties themselves.
public enum EmojiCheck {
    public static func emoji(in text: String) -> [Character] {
        text.filter(isEmoji)
    }

    public static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        // An explicit emoji presentation selector turns a text symbol into
        // an emoji, whatever the base character is.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true }
        return scalars.contains { scalar in
            // Digits, `#` and `*` carry the emoji property for keycap
            // sequences; on their own they are text.
            scalar.properties.isEmojiPresentation
                || (0x1F000...0x1FAFF).contains(scalar.value)
        }
    }
}
