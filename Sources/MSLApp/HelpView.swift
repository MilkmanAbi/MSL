import AppKit
import MSLCore
import SwiftUI

// MARK: - Navigation

/// Where the Help window is, where it has been, and what it's searching for.
///
/// Shared rather than owned by the window, so the Help menu can open the guide
/// at a particular article: `openWindow` only brings the window up, and this is
/// how it knows where to land.
@MainActor
final class HelpNavigator: ObservableObject {
    static let shared = HelpNavigator()

    /// Asking to scroll to the same place twice must still scroll, so each
    /// request carries a fresh token.
    struct ScrollRequest: Equatable {
        var anchor: String?
        var token = 0
    }

    @Published private(set) var articleID = HelpGuide.articles.first?.id ?? ""
    @Published private(set) var scroll = ScrollRequest()
    @Published private(set) var highlights: [String] = []
    @Published private(set) var results: [HelpSearchResult] = []
    @Published private(set) var selectedResult: String?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []

    @Published var search = "" {
        didSet { runSearch() }
    }

    var article: HelpArticle? { HelpGuide.article(articleID) }
    var chapter: HelpChapter? { HelpGuide.chapter(containing: articleID) }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    func open(_ id: String, anchor: String? = nil, highlights: [String] = []) {
        guard HelpGuide.article(id) != nil else { return }
        if id != articleID {
            backStack.append(articleID)
            forwardStack.removeAll()
        }
        articleID = id
        self.highlights = highlights
        scroll = ScrollRequest(anchor: anchor, token: scroll.token + 1)
    }

    /// A link to something that doesn't exist does nothing, rather than
    /// escaping to the browser - `HelpGuideTests` keeps there from being any.
    /// Qualified: SwiftUI has a `HelpLink` view of its own.
    func open(_ link: MSLCore.HelpLink) {
        open(link.article, anchor: link.anchor, highlights: highlights)
    }

    func open(_ result: HelpSearchResult) {
        selectedResult = result.id
        open(result.articleID, anchor: result.anchor.isEmpty ? nil : result.anchor, highlights: result.highlightTerms)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(articleID)
        land(on: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(articleID)
        land(on: next)
    }

    private func land(on id: String) {
        articleID = id
        highlights = []
        scroll = ScrollRequest(anchor: nil, token: scroll.token + 1)
    }

    private func runSearch() {
        guard isSearching else {
            results = []
            highlights = []
            selectedResult = nil
            return
        }
        results = HelpGuide.index.search(search)
    }
}

/// Lets `FilesCommands`' ⌘F act in the Help window too.
struct HelpSearchAvailableKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var helpSearchAvailable: Bool? {
        get { self[HelpSearchAvailableKey.self] }
        set { self[HelpSearchAvailableKey.self] = newValue }
    }
}

extension HelpTint {
    var color: Color {
        switch self {
        case .melon: return Color(red: 0.93, green: 0.50, blue: 0.36)
        case .rind: return Melon.deep
        case .watermelon: return Color(red: 0.89, green: 0.33, blue: 0.43)
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .mango: return Color(red: 0.92, green: 0.62, blue: 0.12)
        case .green: return .green
        case .teal: return .teal
        case .red: return .red
        case .gray: return .gray
        }
    }
}

// MARK: - Window

/// MSL's user guide: a sidebar of chapters, forgiving search down to the
/// section, and articles drawn from `HelpGuide`.
struct HelpView: View {
    @ObservedObject private var nav = HelpNavigator.shared

    var body: some View {
        NavigationSplitView {
            HelpSidebar(nav: nav)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            if let article = nav.article, let chapter = nav.chapter {
                HelpArticleView(article: article, chapter: chapter, nav: nav)
                    // A fresh view per article, so the scroll position
                    // belongs to the article rather than carrying over.
                    .id(article.id)
            }
        }
        .searchable(text: $nav.search, placement: .sidebar, prompt: "Search the guide")
        .onSubmit(of: .search) {
            if let first = nav.results.first { nav.open(first) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { nav.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(nav.backStack.isEmpty)
                    .help("Back")
                Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(nav.forwardStack.isEmpty)
                    .help("Forward")
            }
        }
        .navigationTitle(nav.article?.title ?? "MSL Help")
        .focusedSceneValue(\.helpSearchAvailable, true)
        .environment(\.openURL, OpenURLAction { url in
            if let link = MSLCore.HelpLink(url: url) {
                nav.open(link)
                return .handled
            }
            return .systemAction
        })
        .frame(minWidth: 780, minHeight: 520)
    }
}

// MARK: - Sidebar

private struct HelpSidebar: View {
    @ObservedObject var nav: HelpNavigator

    var body: some View {
        Group {
            if nav.isSearching { results } else { contents }
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(HelpGuide.articles.count) articles · \(HelpGuide.chapters.count) chapters")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Design.Spacing.small)
                // Opaque, or the list scrolls visibly underneath it.
                .background(.bar)
        }
    }

    private var contents: some View {
        List(selection: Binding<String?>(
            get: { nav.articleID },
            set: { if let id = $0 { nav.open(id) } })
        ) {
            ForEach(HelpGuide.chapters) { chapter in
                Section {
                    ForEach(chapter.articles) { article in
                        Label {
                            Text(article.title).lineLimit(1)
                        } icon: {
                            Image(systemName: article.symbol)
                                .foregroundStyle(chapter.tint.color)
                        }
                        .tag(article.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: chapter.symbol)
                            .foregroundStyle(chapter.tint.color)
                        Text(chapter.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var results: some View {
        if nav.results.isEmpty {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing in the guide matches “\(nav.search)”. Try one of these:")
            } actions: {
                VStack(spacing: Design.Spacing.tight) {
                    ForEach(["memory", "snapshot", "repair disk", "shortcuts", "ssh"], id: \.self) { word in
                        Button(word) { nav.search = word }
                            .buttonStyle(.link)
                    }
                }
            }
        } else {
            List(selection: Binding<String?>(
                get: { nav.selectedResult },
                set: { id in
                    if let result = nav.results.first(where: { $0.id == id }) { nav.open(result) }
                })
            ) {
                Section("\(nav.results.count) result\(nav.results.count == 1 ? "" : "s")") {
                    ForEach(nav.results) { result in
                        HelpResultRow(result: result).tag(result.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct HelpResultRow: View {
    let result: HelpSearchResult

    private var tint: Color { HelpGuide.chapter(containing: result.articleID)?.tint.color ?? .accentColor }
    private var symbol: String { HelpGuide.article(result.articleID)?.symbol ?? "doc.text" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(result.articleTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            if let section = result.sectionTitle {
                Text("› \(section)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
            Text(HelpText.styled(result.snippet, highlights: result.highlightTerms, markdown: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Article

private struct HelpArticleView: View {
    let article: HelpArticle
    let chapter: HelpChapter
    @ObservedObject var nav: HelpNavigator

    private var tint: Color { chapter.tint.color }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero.id("top")

                    VStack(alignment: .leading, spacing: Design.Spacing.medium + 2) {
                        if article.document.outline.count >= 2 { onThisPage(proxy) }

                        ForEach(Array(article.document.blocks.enumerated()), id: \.offset) { _, block in
                            HelpBlockView(block: block, tint: tint, highlights: nav.highlights)
                        }

                        related
                        footer
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, Design.Spacing.section + 4)
                    .padding(.vertical, Design.Spacing.large)
                }
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scroll(proxy, to: nav.scroll.anchor) }
            .onChange(of: nav.scroll) { _, request in scroll(proxy, to: request.anchor) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to anchor: String?) {
        // After layout, or the target may not exist yet on a fresh article.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor ?? "top", anchor: .top)
            }
        }
    }

    // MARK: Pieces

    private var position: (Int, Int) {
        let index = HelpGuide.articles.firstIndex { $0.id == article.id } ?? 0
        return (index + 1, HelpGuide.articles.count)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: article.symbol)
                .font(.system(size: 130, weight: .regular))
                .foregroundStyle(tint.opacity(0.13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, Design.Spacing.large)
                .padding(.top, Design.Spacing.medium)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Label(chapter.title.uppercased(), systemImage: chapter.symbol)
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Text(article.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(article.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Design.Spacing.small) {
                    Label("\(article.readingMinutes) min read", systemImage: "clock")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(position.0) of \(position.1)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(Design.Spacing.section - 4)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.22)))
        .padding(.horizontal, Design.Spacing.large)
        .padding(.top, Design.Spacing.large)
    }

    private func onThisPage(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("On this page")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(article.document.outline, id: \.anchor) { section in
                Button {
                    scroll(proxy, to: section.anchor)
                } label: {
                    HStack(spacing: Design.Spacing.small) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tint.opacity(section.level == 2 ? 0.9 : 0.45))
                            .frame(width: 2, height: 13)
                        Text(section.title ?? "")
                            .font(section.level == 2 ? .callout : .caption)
                            .foregroundStyle(section.level == 2 ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, section.level == 3 ? 14 : 0)
            }
        }
        .padding(Design.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }

    @ViewBuilder private var related: some View {
        let articles = article.related.compactMap(HelpGuide.article)
        if !articles.isEmpty {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Related").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Design.Spacing.small + 2)],
                          spacing: Design.Spacing.small + 2) {
                    ForEach(articles) { other in
                        let otherTint = HelpGuide.chapter(containing: other.id)?.tint.color ?? tint
                        Button {
                            nav.open(other.id)
                        } label: {
                            HStack(alignment: .top, spacing: Design.Spacing.small + 2) {
                                Image(systemName: other.symbol)
                                    .foregroundStyle(otherTint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.title).font(.callout.weight(.semibold))
                                    Text(other.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Design.Spacing.small + 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(otherTint.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(otherTint.opacity(0.2)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, Design.Spacing.medium)
        }
    }

    private var footer: some View {
        let neighbours = HelpGuide.neighbours(of: article.id)
        return VStack(spacing: Design.Spacing.medium) {
            Divider()
            HStack(alignment: .top) {
                if let previous = neighbours.previous {
                    neighbourButton(previous, label: "Previous", alignment: .leading)
                }
                Spacer(minLength: Design.Spacing.large)
                if let next = neighbours.next {
                    neighbourButton(next, label: "Next", alignment: .trailing)
                }
            }
        }
        .padding(.top, Design.Spacing.large)
    }

    private func neighbourButton(_ other: HelpArticle, label: String, alignment: HorizontalAlignment) -> some View {
        Button {
            nav.open(other.id)
        } label: {
            VStack(alignment: alignment, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(alignment == .leading ? "‹ \(other.title)" : "\(other.title) ›")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Blocks

private struct HelpBlockView: View {
    let block: HelpBlock
    let tint: Color
    let highlights: [String]

    var body: some View {
        switch block {
        case .heading(let level, let text, let anchor):
            heading(level: level, text: text).id(anchor)
        case .paragraph(let text):
            Text(styled(text))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").font(.body.weight(.heavy)).foregroundStyle(tint)
                        Text(styled(items[index])).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(tint))
                        Text(styled(items[index])).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .callout(let kind, let title, let text):
            HelpCalloutView(kind: kind, title: title, text: text, highlights: highlights)
        case .code(let label, let text):
            HelpCodeView(label: label, text: text)
        case .table(let header, let rows):
            HelpTableView(header: header, rows: rows, tint: tint, highlights: highlights)
        case .shortcuts(let items):
            HelpShortcutsView(items: items, highlights: highlights)
        case .features(let items):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(items.indices, id: \.self) { index in
                    HelpFeatureTile(feature: items[index], highlights: highlights)
                }
            }
        case .divider:
            Divider().padding(.vertical, Design.Spacing.small)
        }
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        if level == 2 {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4, height: 22)
                Text(styled(text)).font(.title2.weight(.bold))
            }
            .padding(.top, Design.Spacing.medium + 4)
        } else {
            Text(styled(text))
                .font(.title3.weight(.semibold))
                .padding(.top, Design.Spacing.small)
        }
    }

    private func styled(_ text: String) -> AttributedString {
        HelpText.styled(text, highlights: highlights)
    }
}

/// Inline Markdown, plus search highlighting.
enum HelpText {
    static func styled(_ text: String, highlights: [String], markdown: Bool = true) -> AttributedString {
        var styled = markdown
            ? (try? AttributedString(markdown: text,
                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
            : AttributedString(text)
        for term in highlights where term.count >= 2 {
            var start = styled.startIndex
            while start < styled.endIndex,
                  let range = styled[start...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                // Word starts only: "ram" lights up "RAM", not "framework".
                let startsWord = range.lowerBound == styled.startIndex || {
                    let before = styled.characters[styled.characters.index(before: range.lowerBound)]
                    return !before.isLetter && !before.isNumber
                }()
                if startsWord { styled[range].backgroundColor = Color.yellow.opacity(0.42) }
                start = range.upperBound
            }
        }
        return styled
    }
}

private struct HelpCalloutView: View {
    let kind: HelpCalloutKind
    let title: String?
    let text: String
    let highlights: [String]

    private var style: (color: Color, symbol: String, label: String) {
        switch kind {
        case .tip: return (.green, "lightbulb.fill", "Tip")
        case .note: return (.blue, "info.circle.fill", "Note")
        case .important: return (.purple, "exclamationmark.circle.fill", "Important")
        case .warning: return (.orange, "exclamationmark.triangle.fill", "Warning")
        case .danger: return (.red, "xmark.octagon.fill", "Danger")
        case .aside: return (Color(red: 0.93, green: 0.45, blue: 0.56), "sparkles", "Aside")
        }
    }

    var body: some View {
        let style = style
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.title3)
                .foregroundStyle(style.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(style.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(style.color)
                if let title {
                    Text(HelpText.styled(title, highlights: highlights))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                let paragraphs = text.components(separatedBy: "\n\n")
                ForEach(paragraphs.indices, id: \.self) { index in
                    let paragraph = paragraphs[index]
                    // Bullets hang, so wrapped lines line up with the text.
                    if paragraph.hasPrefix("• ") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").font(.callout.weight(.heavy)).foregroundStyle(style.color)
                            Text(HelpText.styled(String(paragraph.dropFirst(2)), highlights: highlights))
                                .font(.callout)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(HelpText.styled(paragraph, highlights: highlights))
                            .font(.callout)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.color.opacity(0.09)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(style.color)
                .frame(width: 4)
                .padding(.vertical, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.color.opacity(0.24)))
    }
}

private struct HelpCodeView: View {
    let label: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct HelpTableView: View {
    let header: [String]
    let rows: [[String]]
    let tint: Color
    let highlights: [String]

    private var width: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// Wider columns for wordier content, so a short "Key" column doesn't
    /// take half the table from a long "What it does" one.
    private var weights: [CGFloat] {
        (0..<width).map { column in
            let cells = ([header] + rows).compactMap { column < $0.count ? $0[column] : nil }
            let average = cells.isEmpty ? 1 : cells.map { HelpMarkup.plainText($0).count }.reduce(0, +) / cells.count
            return CGFloat(min(max(average, 6), 55))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !header.isEmpty {
                row(header, isHeader: true)
                    .background(tint.opacity(0.13))
            }
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 || !header.isEmpty { Divider() }
                row(rows[index], isHeader: false)
                    .background(index % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        WeightedColumns(weights: weights, spacing: 12) {
            ForEach(0..<width, id: \.self) { column in
                Text(HelpText.styled(column < cells.count ? cells[column] : "", highlights: highlights))
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Lays its children out as columns whose widths follow `weights`, each
/// wrapping within its share - which `Grid` won't do: it sizes each column to
/// its widest cell's ideal width, so long text runs off the side instead.
private struct WeightedColumns: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat

    private func widths(for total: CGFloat, count: Int) -> [CGFloat] {
        let shares = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = max(shares.reduce(0, +), 1)
        let available = max(0, total - spacing * CGFloat(max(count - 1, 0)))
        return shares.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let columns = widths(for: total, count: subviews.count)
        let height = zip(subviews, columns)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

private struct HelpShortcutsView: View {
    let items: [HelpShortcut]
    let highlights: [String]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 { Divider() }
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        ForEach(Array(Self.caps(items[index].keys).enumerated()), id: \.offset) { _, cap in
                            KeyCap(label: cap)
                        }
                    }
                    .frame(width: 118, alignment: .leading)
                    Text(HelpText.styled(items[index].action, highlights: highlights))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// "⇧⌘N" is three keys; "Space" is one.
    static func caps(_ keys: String) -> [String] {
        var caps: [String] = []
        var word = ""
        // Symbols are one key each; a run of letters is one key too - either
        // a single letter ("N") or a named key ("Space").
        for character in keys where character != " " {
            if character.isLetter {
                word.append(character)
            } else {
                if !word.isEmpty { caps.append(word); word = "" }
                caps.append(String(character))
            }
        }
        if !word.isEmpty { caps.append(word) }
        return caps
    }
}

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .frame(minWidth: 16)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.22), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.16)))
    }
}

private struct HelpFeatureTile: View {
    let feature: HelpFeature
    let highlights: [String]

    var body: some View {
        let color = feature.tint.color
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feature.symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(HelpText.styled(feature.title, highlights: highlights))
                    .font(.callout.weight(.semibold))
                Text(HelpText.styled(feature.text, highlights: highlights))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.2)))
    }
}
