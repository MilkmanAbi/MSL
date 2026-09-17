import Foundation

/// Finds `.desktop` files inside a running instance and pulls their icons
/// back out of it.
///
/// Everything here is one-shot commands over `ShellClient`, and the guest
/// side is written for busybox as much as for coreutils - Alpine is the
/// default distro, so no `--long-options`, no GNU-only `find` predicates.
public enum DesktopEntryScanner {

    /// Directories holding `.desktop` files, per the XDG Desktop Entry
    /// Specification plus the two packaging systems that export outside it.
    ///
    /// `$HOME` is globbed (`/root` and `/home/*`) rather than hardcoded to
    /// `/root`: Flatpak **user** installs live under a real home, and an
    /// instance whose default user is not root would otherwise show none of
    /// them. Snap and system Flatpak both export to fixed system paths.
    ///
    /// AppImage needs no entry of its own - `appimaged` exports into
    /// `~/.local/share/applications`, which is already covered.
    static let applicationDirectories = [
        "/usr/share/applications",
        "/usr/local/share/applications",
        "/var/lib/flatpak/exports/share/applications",
        "/var/lib/snapd/desktop/applications",
    ]
    static let homeApplicationSubpaths = [
        ".local/share/applications",
        ".local/share/flatpak/exports/share/applications",
    ]

    /// Where icon *themes* live. `Icon=` is usually a bare name, not a
    /// path, so it has to be resolved against these.
    static let iconDirectories = [
        "/usr/share/icons",
        "/usr/local/share/icons",
        "/usr/share/pixmaps",
        "/usr/local/share/pixmaps",
        "/var/lib/flatpak/exports/share/icons",
        "/var/lib/snapd/desktop/icons",
        "/usr/share/app-install/icons",
    ]
    static let homeIconSubpaths = [
        ".local/share/icons",
        ".icons",
        ".local/share/flatpak/exports/share/icons",
    ]

    /// Shell that expands the home globs and leaves the full directory list
    /// in `$MSL_DIRS`. Missing directories are dropped here so `find`
    /// doesn't spend its time complaining about them.
    private static func directoryScript(fixed: [String], homeSubpaths: [String]) -> String {
        """
        MSL_DIRS=""
        for d in \(fixed.joined(separator: " ")); do
            [ -d "$d" ] && MSL_DIRS="$MSL_DIRS $d"
        done
        for h in /root /home/*; do
            [ -d "$h" ] || continue
            for s in \(homeSubpaths.joined(separator: " ")); do
                [ -d "$h/$s" ] && MSL_DIRS="$MSL_DIRS $h/$s"
            done
        done
        """
    }

    // MARK: - Scanning

    /// Reads every `.desktop` file in `instance` and parses it. Blocking.
    public static func scan(instance: String, distro: GuestDistro) throws -> [DesktopEntry] {
        let script = """
        \(directoryScript(fixed: applicationDirectories, homeSubpaths: homeApplicationSubpaths))
        [ -n "$MSL_DIRS" ] || exit 0
        find $MSL_DIRS -name '*.desktop' -type f 2>/dev/null | while read -r f; do
            echo "\(DesktopEntryParser.marker)$f==="
            cat "$f" 2>/dev/null
            echo ""
        done
        """
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: script)
        return DesktopEntryParser.parseStream(output)
    }

    // MARK: - Icons

    /// One icon file found in the guest, before any of its bytes are
    /// fetched.
    public struct IconCandidate: Hashable {
        public let path: String
        /// The icon name it matched - the `Icon=` value, not the filename.
        public let name: String

        public init(path: String, name: String) {
            self.path = path
            self.name = name
        }

        public var isVector: Bool { path.hasSuffix(".svg") }
        public var isPixmap: Bool { path.hasSuffix(".xpm") }

        /// Pixel dimension parsed from the theme directory (`.../48x48/...`
        /// or `.../256/...`). `nil` for `scalable` and for flat
        /// directories like `/usr/share/pixmaps`.
        public var declaredSize: Int? {
            for component in path.split(separator: "/") {
                if let x = component.firstIndex(of: "x"),
                   let width = Int(component[component.startIndex..<x]),
                   Int(component[component.index(after: x)...]) != nil {
                    return width
                }
                if let value = Int(component), value >= 8, value <= 1024 { return value }
            }
            return nil
        }

        /// Ranked so the best icon for a Retina Dock tile sorts first.
        ///
        /// Tiers, not one blended number: an SVG has no pixel size and a
        /// file in `/usr/share/pixmaps` has no declared size either, so any
        /// scheme that falls back to *file size* ends up comparing
        /// kilobytes against pixels and ranks a 2 KB vector below every
        /// bitmap. Since macOS rasterises SVG natively at whatever
        /// resolution is asked for, a vector is unconditionally the best
        /// thing to have.
        public var rank: (Int, Int) {
            if isVector { return (3, 0) }
            if let size = declaredSize { return (2, size) }
            if isPixmap { return (0, 0) }   // XPM: macOS cannot even draw it
            return (1, 0)                    // flat directory, unknown size
        }
    }

    /// The guest-side script `listIconCandidates` runs. Extracted so it can
    /// be executed against a fixture tree on the host - the guest is the
    /// one part of this pipeline that cannot be exercised from a test.
    static func iconCandidateScript(names: Set<String>, roots: [String]? = nil) -> String {
        // `/name.` anchors the match to a whole basename, so `gimp` cannot
        // match `gimp-tool.png`.
        let patterns = names.map { "/\($0)." }.joined(separator: "\n")
        let encoded = Data(patterns.utf8).base64EncodedString()
        let directories = roots.map { roots in
            "MSL_DIRS=\"\(roots.joined(separator: " "))\""
        } ?? directoryScript(fixed: iconDirectories, homeSubpaths: homeIconSubpaths)
        return """
        \(directories)
        [ -n "$MSL_DIRS" ] || exit 0
        MSL_PAT=$(mktemp) || exit 0
        printf '%s' '\(encoded)' | base64 -d > "$MSL_PAT" 2>/dev/null
        find $MSL_DIRS \\( -name '*.png' -o -name '*.svg' -o -name '*.xpm' \\) -type f 2>/dev/null \\
            | grep -F -f "$MSL_PAT" 2>/dev/null
        rm -f "$MSL_PAT"
        """
    }

    /// The guest-side script `fetchFiles` runs. Extracted for the same
    /// reason as `iconCandidateScript`.
    static func fetchFilesScript(paths: [String], maxBytes: Int) -> String {
        // The trailing newline matters. `read` returns false when it hits
        // EOF without a delimiter, so a list whose last line is
        // unterminated silently loses that entry - and with a single icon
        // to fetch, that is every entry, which looks exactly like "this
        // instance has no icons". The `|| [ -n "$f" ]` below is the belt to
        // this braces.
        let encoded = Data((paths.joined(separator: "\n") + "\n").utf8).base64EncodedString()
        return """
        MSL_LIST=$(mktemp) || exit 0
        printf '%s' '\(encoded)' | base64 -d > "$MSL_LIST" 2>/dev/null
        while IFS= read -r f || [ -n "$f" ]; do
            [ -f "$f" ] || continue
            bytes=$(wc -c < "$f" 2>/dev/null || echo 0)
            [ "$bytes" -le \(maxBytes) ] || continue
            echo "===MSL_FILE:$f==="
            # Redirected rather than `base64 "$f"`: coreutils and busybox
            # both accept a filename, BSD's does not, and reading stdin is
            # the one spelling every implementation agrees on. Nothing in
            # the guest depends on which one is installed.
            base64 < "$f" 2>/dev/null
            echo "===MSL_FILE_END==="
        done < "$MSL_LIST"
        rm -f "$MSL_LIST"
        """
    }

    /// Lists every icon file whose basename matches one of `names`, in one
    /// round trip, returning paths only.
    ///
    /// The name list is sent base64-encoded and matched with `grep -F -f`.
    /// That is deliberate on both counts: it keeps `Icon=` values - which
    /// come out of guest files and can contain anything - away from the
    /// shell entirely, and it replaces a per-name pass over the theme tree
    /// with a single one. A full icon theme is tens of thousands of files,
    /// and the previous shape (one `grep` plus a `wc -c` subshell per name,
    /// per candidate) is what made scanning slow enough to notice.
    public static func listIconCandidates(
        names: Set<String>, instance: String, distro: GuestDistro
    ) throws -> [IconCandidate] {
        let themeNames = names.filter { !$0.hasPrefix("/") && !$0.isEmpty }
        guard !themeNames.isEmpty else { return [] }

        // `/name.` anchors the match to a whole basename, so `gimp` cannot
        // match `gimp-tool.png`.
        let script = iconCandidateScript(names: themeNames)
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: script)

        var candidates: [IconCandidate] = []
        // CRLF from the PTY - see `DesktopEntryParser.parseStream`.
        for line in DesktopEntryParser.normalize(output).split(separator: "\n") {
            let path = String(line).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            guard let file = path.split(separator: "/").last,
                  let dot = file.lastIndex(of: ".") else { continue }
            let base = String(file[file.startIndex..<dot])
            guard themeNames.contains(base) else { continue }
            candidates.append(IconCandidate(path: path, name: base))
        }
        return candidates
    }

    /// The best candidate per icon name, by `IconCandidate.rank`.
    public static func bestIcons(among candidates: [IconCandidate]) -> [String: IconCandidate] {
        var best: [String: IconCandidate] = [:]
        for candidate in candidates {
            guard let existing = best[candidate.name] else { best[candidate.name] = candidate; continue }
            if candidate.rank > existing.rank { best[candidate.name] = candidate }
        }
        return best
    }

    /// Fetches the bytes of specific files by absolute path.
    ///
    /// Paths are sent base64-encoded for the same reason the names were:
    /// they come from the guest's own filesystem and never touch the
    /// shell's word splitting. `maxBytes` is enforced guest-side so an
    /// oversized file costs nothing rather than being transferred and then
    /// discarded.
    public static func fetchFiles(
        paths: [String], instance: String, distro: GuestDistro, maxBytes: Int
    ) throws -> [String: Data] {
        guard !paths.isEmpty else { return [:] }
        let script = fetchFilesScript(paths: paths, maxBytes: maxBytes)
        let (_, output) = try ShellClient().runOneShotCommand(
            instance: instance, distro: distro, command: script)
        return parseFiles(output)
    }

    /// Splits the `fetchFiles` stream back into path -> bytes.
    static func parseFiles(_ output: String) -> [String: Data] {
        var result: [String: Data] = [:]
        var currentPath: String?
        var encoded = ""

        func flush() {
            defer { encoded = ""; currentPath = nil }
            guard let path = currentPath,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  !data.isEmpty else { return }
            result[path] = data
        }

        // CRLF from the PTY - see `DesktopEntryParser.parseStream`.
        for rawLine in DesktopEntryParser.normalize(output).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===MSL_FILE:"), line.hasSuffix("===") {
                flush()
                currentPath = String(line.dropFirst("===MSL_FILE:".count).dropLast(3))
                continue
            }
            if line == "===MSL_FILE_END===" { flush(); continue }
            guard currentPath != nil else { continue }
            encoded += line
        }
        flush()
        return result
    }
}
