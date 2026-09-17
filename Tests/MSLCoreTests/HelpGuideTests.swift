import XCTest
@testable import MSLCore

/// What the real guide says: every link lands, nothing is malformed, no emoji,
/// and search finds the right article for the words people actually type.
final class HelpGuideTests: XCTestCase {
    // MARK: - Structure

    func testIDsAreUnique() {
        let articleIDs = HelpGuide.articles.map(\.id)
        XCTAssertEqual(articleIDs.count, Set(articleIDs).count, "duplicate article ids: \(duplicates(articleIDs))")
        let chapterIDs = HelpGuide.chapters.map(\.id)
        XCTAssertEqual(chapterIDs.count, Set(chapterIDs).count)
    }

    func testEveryChapterHasArticles() {
        for chapter in HelpGuide.chapters {
            XCTAssertFalse(chapter.articles.isEmpty, chapter.id)
            XCTAssertFalse(chapter.blurb.isEmpty, chapter.id)
        }
    }

    func testEveryArticleIsComplete() {
        for article in HelpGuide.articles {
            XCTAssertFalse(article.title.isEmpty, article.id)
            XCTAssertTrue(article.summary.hasSuffix("."), "\(article.id): the summary is a sentence")
            XCTAssertGreaterThanOrEqual(article.keywords.count, 3, "\(article.id) needs search keywords")
            XCTAssertFalse(article.document.blocks.isEmpty, article.id)
            XCTAssertFalse(article.symbol.isEmpty, article.id)
        }
    }

    // MARK: - Links

    func testEveryHelpLinkLandsOnARealPlace() {
        for article in HelpGuide.articles {
            for link in HelpLink.links(in: article.source) {
                guard let target = HelpGuide.article(link.article) else {
                    XCTFail("\(article.id) links to missing article '\(link.article)'")
                    continue
                }
                if let anchor = link.anchor {
                    XCTAssertTrue(target.document.sections.contains { $0.anchor == anchor },
                                  "\(article.id) links to missing anchor '\(link.article)#\(anchor)'")
                }
            }
        }
    }

    func testRelatedArticlesExist() {
        for article in HelpGuide.articles {
            for id in article.related {
                XCTAssertNotNil(HelpGuide.article(id), "\(article.id) relates to missing '\(id)'")
                XCTAssertNotEqual(id, article.id, "\(article.id) relates to itself")
            }
        }
    }

    func testNeighboursWalkTheWholeGuide() {
        var seen = [HelpGuide.articles.first!.id]
        while let next = HelpGuide.neighbours(of: seen.last!).next { seen.append(next.id) }
        XCTAssertEqual(seen, HelpGuide.articles.map(\.id))
        XCTAssertNil(HelpGuide.neighbours(of: HelpGuide.articles[0].id).previous)
    }

    // MARK: - Markup

    /// A callout with a misspelt kind would render its `[!TIPP]` literally.
    func testNoUnknownCalloutKinds() {
        for article in HelpGuide.articles {
            for case .callout(_, _, let text) in article.document.blocks {
                XCTAssertFalse(text.hasPrefix("[!"), "\(article.id): unknown callout kind in '\(text.prefix(30))'")
            }
        }
    }

    func testFeatureCardsUseKnownTints() {
        for article in HelpGuide.articles {
            for line in article.source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@card ") else { continue }
                let head = trimmed.dropFirst(6).split(separator: "|").first?.split(separator: " ") ?? []
                XCTAssertEqual(head.count, 2, "\(article.id): '\(trimmed)'")
                if head.count == 2 {
                    XCTAssertNotNil(HelpTint(rawValue: String(head[1])), "\(article.id): unknown tint '\(head[1])'")
                }
                XCTAssertEqual(trimmed.split(separator: "|").count, 3, "\(article.id): '\(trimmed)'")
            }
        }
    }

    func testTablesAreRectangular() {
        for article in HelpGuide.articles {
            for case .table(let header, let rows) in article.document.blocks {
                let width = header.isEmpty ? rows.first?.count ?? 0 : header.count
                for row in rows {
                    XCTAssertEqual(row.count, width, "\(article.id): \(row)")
                }
            }
        }
    }

    func testShortcutLinesAllParsed() {
        for article in HelpGuide.articles {
            let written = article.source.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@keys ") }.count
            var parsed = 0
            for case .shortcuts(let items) in article.document.blocks { parsed += items.count }
            XCTAssertEqual(parsed, written, "\(article.id): an @keys line is missing its '|'")
        }
    }

    func testNoFenceLeftOpen() {
        for article in HelpGuide.articles {
            let fences = article.source.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
            XCTAssertEqual(fences % 2, 0, "\(article.id) has an unclosed code block")
        }
    }

    // MARK: - Voice

    /// MSL speaks kaomoji, never emoji.
    func testNoEmojiAnywhere() {
        for chapter in HelpGuide.chapters {
            XCTAssertEqual(EmojiCheck.emoji(in: chapter.title + chapter.blurb), [], chapter.id)
        }
        for article in HelpGuide.articles {
            let text = [article.title, article.summary, article.source] + article.keywords
            XCTAssertEqual(EmojiCheck.emoji(in: text.joined(separator: " ")), [], article.id)
        }
    }

    func testTheGuideIsInDepth() {
        XCTAssertGreaterThanOrEqual(HelpGuide.articles.count, 60)
        XCTAssertGreaterThan(HelpGuide.wordCount, 15_000)
    }

    // MARK: - Search

    /// Queries people actually type, and where they should land. "In the top
    /// three" rather than "first", so reasonable reordering doesn't fail it.
    func testSearchFindsTheRightArticle() {
        let expectations: [(String, [String])] = [
            ("ram", ["memory", "memory-dynamic", "trouble-memory"]),
            ("more memory", ["memory", "memory-dynamic", "trouble-memory"]),
            ("fsck", ["disk-check", "disk-repair", "trouble-filesystem", "check-at-start"]),
            ("repair disk", ["disk-repair", "disk-check", "trouble-filesystem"]),
            ("delete instance", ["removing-instances"]),
            ("wifi", ["sandbox-gates", "sandbox"]),
            ("pin dock", ["pin-to-dock"]),
            ("password", ["first-start", "linux-users"]),
            ("sudo", ["linux-users", "first-start"]),
            ("wireshark", ["traffic-monitor"]),
            ("snapshot", ["snapshots"]),
            ("xquartz", ["how-it-works", "linux-windows"]),
            ("clock wrong", ["trouble-clock", "guest-utilities"]),
            ("vscode", ["ssh", "trouble-ssh"]),
            ("hibernate", ["stopping-instances"]),
            ("disk full", ["trouble-disk", "storage", "reclaim-space"]),
            ("mnt", ["home-share"]),
            ("shortcuts", ["shortcuts"]),
            ("kernel panic", ["trouble-wont-start", "trouble-filesystem"]),
            ("e2fsprogs", ["disk-check"]),
            ("flatpak", ["app-sources"]),
            ("copy paste", ["linux-windows", "files-moving", "trouble-apps"]),
            ("sleep", ["power-events", "idle"]),
            ("cpu", ["processors"]),
            ("remove", ["removing-instances"]),
            ("msl doctor", ["logs-and-doctor"]),
            ("snapshto", ["snapshots"]),
            ("memroy", ["memory", "memory-dynamic", "trouble-memory"]),
            ("forgot password", ["linux-users"]),
            ("sudo password", ["linux-users", "first-start"]),
        ]
        for (query, acceptable) in expectations {
            let top = Array(HelpGuide.index.search(query).prefix(3)).map(\.articleID)
            XCTAssertTrue(top.contains { acceptable.contains($0) }, "'\(query)' -> \(top), wanted one of \(acceptable)")
        }
    }

    func testSearchIsQuickEnoughToRunPerKeystroke() {
        _ = HelpGuide.index.search("warm")
        let queries = ["m", "me", "mem", "memo", "memor", "memory", "memory d", "memory dy", "memory dynamic",
                       "s", "sn", "sna", "snap", "snaps", "snapshot", "disk", "disk repair", "zzqq"]
        let start = Date()
        for query in queries { _ = HelpGuide.index.search(query) }
        let perQuery = Date().timeIntervalSince(start) / Double(queries.count)
        XCTAssertLessThan(perQuery, 0.05, "search took \(perQuery)s per keystroke")
    }

    private func duplicates(_ items: [String]) -> [String] {
        Dictionary(grouping: items, by: { $0 }).filter { $0.value.count > 1 }.map(\.key)
    }
}
