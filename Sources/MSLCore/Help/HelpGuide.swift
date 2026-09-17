import Foundation

/// The whole guide, in reading order, and the one search index over it.
public enum HelpGuide {
    public static let chapters: [HelpChapter] = [
        .welcome, .gettingStarted, .mainWindow, .applications, .terminal, .overview,
        .tools, .sandbox, .files, .power, .troubleshooting, .commandLine, .reference,
    ]

    public static let articles: [HelpArticle] = chapters.flatMap(\.articles)

    /// Built once, on first search - not at launch.
    public static let index = HelpSearchIndex(chapters: chapters)

    // First one wins rather than trapping on a duplicate id: `HelpGuideTests`
    // is what catches duplicates, and a help window is no reason to crash.
    private static let byID: [String: HelpArticle] =
        Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func article(_ id: String) -> HelpArticle? { byID[id] }

    public static func chapter(containing articleID: String) -> HelpChapter? {
        chapters.first { chapter in chapter.articles.contains { $0.id == articleID } }
    }

    /// The articles either side of `articleID`, across chapter boundaries.
    public static func neighbours(of articleID: String) -> (previous: HelpArticle?, next: HelpArticle?) {
        guard let position = articles.firstIndex(where: { $0.id == articleID }) else { return (nil, nil) }
        return (position > 0 ? articles[position - 1] : nil,
                position + 1 < articles.count ? articles[position + 1] : nil)
    }

    public static var wordCount: Int { articles.reduce(0) { $0 + $1.document.wordCount } }
}
