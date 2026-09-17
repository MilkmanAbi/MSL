import Foundation
import MSLCore

/// `msl --help`: grouped, aligned and wrapped to the terminal.
///
/// The old text was one hand-indented string that had drifted into three
/// different indents, with debug-only verbs in the middle of everyday ones.
/// Each entry is data now, so the layout is computed and can't drift again.
enum CLIHelp {
    static var sections: [CLIReference.Section] { CLIReference.sections }

    static func terminalWidth(_ fd: Int32) -> Int {
        var size = winsize()
        if ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col >= 40 { return Int(size.ws_col) }
        return 100
    }

    /// Breaks `text` into lines of at most `width` characters, at spaces.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// The whole help text. Commands wider than the column get their summary
    /// on the next line rather than pushing every other row out of line.
    static func render(width: Int, styled: Bool) -> String {
        let bold = styled ? "\u{1B}[1m" : ""
        let dim = styled ? "\u{1B}[2m" : ""
        let reset = styled ? "\u{1B}[0m" : ""
        let indent = 2
        let column = min(36, max(24, width / 2 - 10))
        let summaryWidth = max(30, width - indent - column - 2)

        var out = "\(bold)MSL\(reset) - Mac Subsystem for Linux \(dim)\(MSLVersion.marketing)\(reset)\n\n"
        out += "\(bold)Usage\(reset)\n  msl [instance] [command...]\n"
        for section in sections {
            out += "\n\(bold)\(section.title)\(reset)\n"
            for entry in section.entries {
                let summary = wrap(entry.summary, width: summaryWidth)
                let pad = String(repeating: " ", count: indent)
                let hang = String(repeating: " ", count: indent + column + 2)
                if entry.command.count <= column {
                    let gap = String(repeating: " ", count: column - entry.command.count + 2)
                    out += pad + entry.command + gap + (summary.first ?? "") + "\n"
                    for line in summary.dropFirst() { out += hang + line + "\n" }
                } else {
                    out += pad + entry.command + "\n"
                    for line in summary { out += hang + line + "\n" }
                }
            }
        }
        out += "\n\(dim)Full guide: MSL Help in the MSL app (Help menu).\(reset)\n"
        return out
    }
}
