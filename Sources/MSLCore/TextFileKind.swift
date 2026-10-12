import Foundation

/// Whether a file is one MSL Files should offer to edit in place.
///
/// Editing a Linux config from the Mac without copying it anywhere is the
/// sort of thing MSL Files exists for: `~/.bashrc`, `/etc/fstab`, a unit
/// file, a `.desktop` entry. Offering that on a 700 MB disk image, or on
/// something with NUL bytes in it, is not.
///
/// The judgement is deliberately in two halves. The name is enough to offer
/// the menu item without reading anything; the bytes decide whether the
/// editor will actually open, because plenty of config files have no
/// extension at all.
public enum TextFileKind {
    /// Bigger than this and it is not a config file any more. A text editor
    /// that loads a gigabyte into a `String` is its own bug report.
    public static let editableByteLimit = 4 * 1024 * 1024

    /// Extensions worth offering `Edit as Text` for. Lowercased, no dot.
    static let textExtensions: Set<String> = [
        "conf", "config", "cfg", "ini", "toml", "yaml", "yml", "json", "xml",
        "txt", "text", "md", "markdown", "log", "list", "rules", "env",
        "sh", "bash", "zsh", "fish", "profile", "rc", "service", "socket",
        "timer", "mount", "target", "desktop", "policy", "repo", "sources",
        "py", "rb", "pl", "lua", "c", "h", "cpp", "hpp", "swift", "go", "rs",
        "js", "ts", "css", "html", "sql", "patch", "diff", "gitignore",
    ]

    /// Files with no extension that are text by convention.
    static let textNames: Set<String> = [
        "fstab", "hosts", "hostname", "passwd", "group", "shadow", "resolv.conf",
        "crontab", "sudoers", "environment", "makefile", "dockerfile", "readme",
        "license", "changelog", "authorized_keys", "known_hosts", "config",
    ]

    /// Worth offering the editor for, judged by name alone.
    ///
    /// Dotfiles count: `.bashrc`, `.profile`, `.gitconfig` are exactly what
    /// someone opens MSL Files to fix.
    public static func looksEditable(name: String) -> Bool {
        let lower = name.lowercased()
        if textNames.contains(lower) { return true }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, textExtensions.contains(ext) { return true }
        // `.bashrc` has no extension by NSString's reckoning once the leading
        // dot is the only separator, so judge the stem too.
        if lower.hasPrefix(".") {
            let stem = String(lower.dropFirst())
            if textNames.contains(stem) { return true }
            let stemExtension = (stem as NSString).pathExtension
            if stemExtension.isEmpty { return true }
            return textExtensions.contains(stemExtension)
        }
        return ext.isEmpty && !lower.contains(" ")
    }

    /// How many leading bytes are enough to guess text from binary. `file(1)`
    /// and `grep` look at far less; 4 KB covers a shebang, an XML prolog, and
    /// any BOM with room to spare.
    public static let sniffByteCount = 4096

    /// Whether a *sample* of a file's leading bytes reads as text - the
    /// content half of the judgement, for the Linux files that carry no
    /// extension and aren't in `textNames`: a build script called `deploy`, a
    /// generated config, a `.envrc`. A shebang is a hard yes; a NUL is a hard
    /// no; otherwise it's the ratio of printable bytes, which sorts UTF-8
    /// prose and code from packed binaries reliably at this sample size.
    ///
    /// Deliberately lenient about encoding, unlike `isEditable`: this only
    /// decides whether to *offer* the editor and a preview. `isEditable`
    /// still has the final say on whether the whole file actually opens, and
    /// `refusal` explains it if not.
    public static func looksTextual(sample: Data) -> Bool {
        guard !sample.isEmpty else { return true } // an empty file is editable
        if sample.contains(0) { return false }
        if sample.starts(with: [0x23, 0x21]) { return true } // "#!"
        // A high proportion of printable/whitespace bytes is what separates a
        // text file from a binary one. Control bytes other than tab, newline,
        // carriage return and form feed are the tell.
        let printable = sample.reduce(0) { count, byte in
            (byte >= 0x20 && byte < 0x7F) || byte >= 0x80
                || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
                ? count + 1 : count
        }
        return Double(printable) / Double(sample.count) >= 0.90
    }

    /// Whether these bytes can actually be shown in an editor: valid UTF-8,
    /// no NUL. A NUL byte is the oldest and most reliable "this is binary"
    /// signal there is, and it is what `grep` and `file` both start with.
    public static func isEditable(_ data: Data) -> Bool {
        guard data.count <= editableByteLimit else { return false }
        guard !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// Why the editor refused, in words for the user.
    public static func refusal(for data: Data) -> String? {
        if data.count > editableByteLimit {
            return "This file is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .memory)), too big to edit here. Open it in Linux instead."
        }
        if data.contains(0) { return "This looks like a binary file, not text." }
        if String(data: data, encoding: .utf8) == nil { return "This file isn't UTF-8 text, so editing it here could damage it." }
        return nil
    }
}
