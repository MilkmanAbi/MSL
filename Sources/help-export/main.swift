// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Renders the in-app help guide as a static site for GitHub Pages.
//
// **It reads the same `HelpGuide` the app does**, through the same parser,
// so the published site cannot drift from what ships. There is no second
// copy of the text anywhere: add an article to the app and it appears
// here, and a broken `help:` link fails the app's own tests before it
// could ever reach the web.

import Foundation
import MSLCore

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "./site")

// MARK: - Escaping

/// Everything that reaches HTML goes through here first.
func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Inline Markdown the parser deliberately leaves alone: `code`, **bold**,
/// *italic*, and links - including the guide's own `help:` scheme, which
/// becomes a relative page link here.
func inline(_ text: String) -> String {
    var out = escape(text)

    // Links first: their label may contain the other markers.
    out = replacing(out, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { groups in
        let label = groups[0], target = groups[1]
        guard target.hasPrefix("help:") else {
            return "<a href=\"\(target)\" rel=\"noopener\">\(label)</a>"
        }
        let rest = String(target.dropFirst("help:".count))
        let parts = rest.split(separator: "#", maxSplits: 1)
        let page = String(parts[0])
        let anchor = parts.count > 1 ? "#" + String(parts[1]) : ""
        return "<a href=\"\(page).html\(anchor)\">\(label)</a>"
    }
    // `code` before the emphasis markers, so a backticked asterisk survives.
    out = replacing(out, pattern: "`([^`]+)`") { "<code>\($0[0])</code>" }
    out = replacing(out, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[0])</strong>" }
    out = replacing(out, pattern: #"(?<![*\w])\*([^*]+)\*(?!\w)"#) { "<em>\($0[0])</em>" }
    return out
}

func replacing(_ text: String, pattern: String,
               _ build: ([String]) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let full = NSRange(text.startIndex..., in: text)
    var result = ""
    var last = text.startIndex
    for match in regex.matches(in: text, range: full) {
        guard let range = Range(match.range, in: text) else { continue }
        result += text[last..<range.lowerBound]
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            groups.append(Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "")
        }
        result += build(groups)
        last = range.upperBound
    }
    result += text[last...]
    return result
}

// MARK: - Blocks

func render(_ block: HelpBlock) -> String {
    switch block {
    case .heading(let level, let text, let anchor):
        // One heading level down: the article title is the h1.
        let tag = "h\(min(level + 1, 6))"
        return "<\(tag) id=\"\(escape(anchor))\">\(inline(text))"
             + "<a class=\"anchor\" href=\"#\(escape(anchor))\" aria-label=\"Link to this section\">#</a></\(tag)>"
    case .paragraph(let text):
        return "<p>\(inline(text))</p>"
    case .bullets(let items):
        return "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
    case .steps(let items):
        return "<ol>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
    case .callout(let kind, let title, let text):
        let heading = title.map { "<p class=\"callout-title\">\(inline($0))</p>" } ?? ""
        let body = text.components(separatedBy: "\n\n")
            .map { "<p>\(inline($0))</p>" }.joined()
        return "<aside class=\"callout \(kind.rawValue)\">"
             + "<span class=\"callout-kind\">\(kind.rawValue)</span>\(heading)\(body)</aside>"
    case .code(let label, let text):
        let caption = label.map { "<figcaption>\(escape($0))</figcaption>" } ?? ""
        return "<figure class=\"code\">\(caption)<pre><code>\(escape(text))</code></pre></figure>"
    case .table(let header, let rows):
        var html = "<div class=\"table-wrap\"><table>"
        if !header.isEmpty {
            html += "<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>"
        }
        html += "<tbody>" + rows.map { row in
            "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }.joined() + "</tbody></table></div>"
        return html
    case .shortcuts(let list):
        return "<dl class=\"shortcuts\">" + list.map {
            "<dt><kbd>\(escape($0.keys))</kbd></dt><dd>\(inline($0.action))</dd>"
        }.joined() + "</dl>"
    case .features(let list):
        return "<div class=\"cards\">" + list.map { feature in
            "<div class=\"card tint-\(feature.tint.rawValue)\">"
            + "<h4>\(inline(feature.title))</h4><p>\(inline(feature.text))</p></div>"
        }.joined() + "</div>"
    case .divider:
        return "<hr>"
    }
}

// MARK: - Pages

let css = """
:root {
  --bg: #fdfcfb; --panel: #ffffff; --ink: #1c1917; --muted: #6b6560;
  --line: #e7e2dc; --accent: #c2410c; --accent-soft: #fff4ed;
  --code-bg: #f6f3f0;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #17151a; --panel: #1f1c23; --ink: #ece9e6; --muted: #a39d99;
    --line: #322d38; --accent: #fb923c; --accent-soft: #2a1f1a;
    --code-bg: #15131a;
  }
}
:root[data-theme="dark"] {
  --bg: #17151a; --panel: #1f1c23; --ink: #ece9e6; --muted: #a39d99;
  --line: #322d38; --accent: #fb923c; --accent-soft: #2a1f1a;
  --code-bg: #15131a;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  -webkit-text-size-adjust: 100%;
}
a { color: var(--accent); }
.layout { display: grid; grid-template-columns: 290px minmax(0, 1fr); gap: 0; }
.sidebar {
  border-right: 1px solid var(--line); padding: 28px 20px 64px;
  height: 100vh; position: sticky; top: 0; overflow-y: auto;
}
.sidebar .brand { font-weight: 700; font-size: 1.1rem; letter-spacing: -0.01em; }
.sidebar .count { color: var(--muted); font-size: .8rem; margin: 2px 0 20px; }
.sidebar h3 {
  font-size: .72rem; text-transform: uppercase; letter-spacing: .09em;
  color: var(--muted); margin: 22px 0 7px;
}
.sidebar a { display: block; padding: 4px 8px; margin-left: -8px; border-radius: 6px;
  color: var(--ink); text-decoration: none; font-size: .9rem; }
.sidebar a:hover { background: var(--accent-soft); }
.sidebar a.current { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
main { padding: 48px 40px 120px; max-width: 820px; }
.eyebrow { color: var(--accent); font-size: .74rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: .1em; }
h1 { font-size: 2.1rem; line-height: 1.15; letter-spacing: -0.02em; margin: 8px 0 10px; }
.summary { font-size: 1.12rem; color: var(--muted); margin: 0 0 36px; }
h2, h3, h4 { line-height: 1.25; letter-spacing: -0.01em; margin: 34px 0 10px; }
h2 { font-size: 1.4rem; } h3 { font-size: 1.12rem; } h4 { font-size: 1rem; }
.anchor { opacity: 0; margin-left: .4em; text-decoration: none; font-weight: 400; }
h2:hover .anchor, h3:hover .anchor, h4:hover .anchor { opacity: .45; }
code { background: var(--code-bg); padding: .12em .38em; border-radius: 5px;
  font: .88em ui-monospace, SFMono-Regular, Menlo, monospace; }
figure.code { margin: 18px 0; }
figure.code figcaption { font-size: .78rem; color: var(--muted); margin-bottom: 5px; }
pre { background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
  padding: 14px 16px; overflow-x: auto; }
pre code { background: none; padding: 0; font-size: .86rem; line-height: 1.55; }
.table-wrap { overflow-x: auto; margin: 18px 0; }
table { border-collapse: collapse; width: 100%; font-size: .93rem; }
th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--line);
  vertical-align: top; }
th { font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); }
.callout { border-left: 3px solid var(--accent); background: var(--accent-soft);
  padding: 14px 18px; border-radius: 0 10px 10px 0; margin: 20px 0; }
.callout p { margin: 6px 0; }
.callout-kind { font-size: .68rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: .1em; color: var(--accent); }
.callout-title { font-weight: 650; }
.callout.warning, .callout.danger { border-color: #dc2626; background: #fef2f2; }
.callout.important { border-color: #d97706; background: #fffbeb; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .callout.warning,
  :root:not([data-theme="light"]) .callout.danger { background: #2a1616; }
  :root:not([data-theme="light"]) .callout.important { background: #291f10; }
}
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 12px; margin: 20px 0; }
.card { border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px;
  background: var(--panel); }
.card h4 { margin: 0 0 5px; font-size: .95rem; }
.card p { margin: 0; font-size: .89rem; color: var(--muted); }
.shortcuts { display: grid; grid-template-columns: auto 1fr; gap: 7px 16px; margin: 18px 0; }
.shortcuts dt { margin: 0; } .shortcuts dd { margin: 0; }
kbd { background: var(--panel); border: 1px solid var(--line); border-bottom-width: 2px;
  border-radius: 6px; padding: .1em .45em; font: .84em ui-monospace, Menlo, monospace; }
.pager { display: flex; justify-content: space-between; gap: 16px; margin-top: 56px;
  padding-top: 22px; border-top: 1px solid var(--line); font-size: .92rem; }
.pager a { text-decoration: none; }
.pager .label { display: block; color: var(--muted); font-size: .76rem; }
.related { margin-top: 36px; font-size: .92rem; }
.related h3 { margin-bottom: 8px; }
hr { border: 0; border-top: 1px solid var(--line); margin: 28px 0; }
.menu-toggle { display: none; }
@media (max-width: 860px) {
  .layout { grid-template-columns: 1fr; }
  .sidebar { position: static; height: auto; border-right: 0;
    border-bottom: 1px solid var(--line); padding: 20px 16px 24px; }
  main { padding: 28px 16px 80px; }
  h1 { font-size: 1.7rem; }
}
"""

func sidebar(current: String?) -> String {
    var html = "<nav class=\"sidebar\"><div class=\"brand\"><a href=\"index.html\" "
             + "style=\"color:inherit;text-decoration:none;padding:0;margin:0\">MSL Guide</a></div>"
             + "<div class=\"count\">\(HelpGuide.articles.count) articles · "
             + "\(HelpGuide.chapters.count) chapters</div>"
    for chapter in HelpGuide.chapters {
        html += "<h3>\(escape(chapter.title))</h3>"
        for article in chapter.articles {
            let here = article.id == current ? " class=\"current\"" : ""
            html += "<a\(here) href=\"\(article.id).html\">\(escape(article.title))</a>"
        }
    }
    return html + "</nav>"
}

func page(title: String, description: String, current: String?, body: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(escape(title)) — MSL Guide</title>
    <meta name="description" content="\(escape(description))">
    <link rel="stylesheet" href="style.css">
    </head>
    <body>
    <div class="layout">
    \(sidebar(current: current))
    <main>\(body)</main>
    </div>
    </body>
    </html>
    """
}

// MARK: - Write

let fm = FileManager.default
try? fm.createDirectory(at: output, withIntermediateDirectories: true)
try css.write(to: output.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

// GitHub Pages serves a directory with no Jekyll processing when this is
// present. Without it, Pages tries to build the folder as a Jekyll site and
// anything starting with an underscore disappears.
try "".write(to: output.appendingPathComponent(".nojekyll"), atomically: true, encoding: .utf8)

for article in HelpGuide.articles {
    let chapter = HelpGuide.chapter(containing: article.id)
    var body = "<div class=\"eyebrow\">\(escape(chapter?.title ?? "MSL"))</div>"
    body += "<h1>\(escape(article.title))</h1>"
    body += "<p class=\"summary\">\(escape(article.summary))</p>"
    body += article.document.blocks.map(render).joined()

    let present = article.related.compactMap { HelpGuide.article($0) }
    if !present.isEmpty {
        body += "<div class=\"related\"><h3>See also</h3><ul>"
        body += present.map { "<li><a href=\"\($0.id).html\">\(escape($0.title))</a></li>" }.joined()
        body += "</ul></div>"
    }

    let around = HelpGuide.neighbours(of: article.id)
    body += "<nav class=\"pager\">"
    if let previous = around.previous {
        body += "<a href=\"\(previous.id).html\"><span class=\"label\">Previous</span>"
              + "\(escape(previous.title))</a>"
    } else { body += "<span></span>" }
    if let next = around.next {
        body += "<a href=\"\(next.id).html\" style=\"text-align:right\">"
              + "<span class=\"label\">Next</span>\(escape(next.title))</a>"
    } else { body += "<span></span>" }
    body += "</nav>"

    try page(title: article.title, description: article.summary,
             current: article.id, body: body)
        .write(to: output.appendingPathComponent("\(article.id).html"),
               atomically: true, encoding: .utf8)
}

// The front page.
var home = "<div class=\"eyebrow\">MSL</div><h1>The MSL Guide</h1>"
home += "<p class=\"summary\">Real Linux on your Mac. "
      + "\(HelpGuide.articles.count) articles, \(HelpGuide.chapters.count) chapters — "
      + "the same guide that ships inside the app.</p>"
for chapter in HelpGuide.chapters {
    home += "<h2 id=\"\(escape(chapter.id))\">\(escape(chapter.title))</h2>"
    home += "<p>\(escape(chapter.blurb))</p><ul>"
    for article in chapter.articles {
        home += "<li><a href=\"\(article.id).html\">\(escape(article.title))</a> — "
              + "\(escape(article.summary))</li>"
    }
    home += "</ul>"
}
try page(title: "The MSL Guide", description: "Real Linux on your Mac.",
         current: nil, body: home)
    .write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

print("wrote \(HelpGuide.articles.count + 1) pages to \(output.path)")
