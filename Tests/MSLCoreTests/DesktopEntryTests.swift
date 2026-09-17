import XCTest
@testable import MSLCore

/// Parser tests for `.desktop` files, aimed squarely at the malformed ones:
/// CRLF, a BOM, spaces around `=`, duplicate keys, locale suffixes, escape
/// sequences, quoted `Exec` arguments and field codes.
final class DesktopEntryTests: XCTestCase {

    private let nasty = """
\u{FEFF}# a comment\r
\r
[Desktop Entry]\r
  Version = 1.0\r
Type=Application\r
Name  =  GIMP\r
Name[fr]=Le GIMP\r
Name[de_DE]=GIMP DE\r
Comment=Create images\\sand edit\\nphotos\r
Exec="/opt/My Apps/gimp bin/gimp" --with="a \\"quoted\\" thing" %U --file=%f -n\r
Icon=gimp\r
Categories=Graphics;2DGraphics;RasterGraphics;\r
Keywords=photo;image\\;editor;\r
Terminal=false\r
Name=DUPLICATE SHOULD BE IGNORED\r

[Desktop Action Edit]
Name=Should not be read
Exec=/bin/false
"""

    func testParsesPathologicalFile() throws {
        let entry = try XCTUnwrap(
            DesktopEntryParser.parse(text: nasty, path: "/usr/share/applications/gimp.desktop"))
        // The unlocalized Name wins for an en-US host, and the duplicate
        // `Name=` later in the file must not overwrite it.
        XCTAssertEqual(entry.name, "GIMP")
        XCTAssertEqual(entry.comment, "Create images and edit\nphotos")
        XCTAssertEqual(entry.icon, "gimp")
        // Quoted path containing spaces stays one argument.
        XCTAssertEqual(entry.argv.first, "/opt/My Apps/gimp bin/gimp")
        XCTAssertEqual(entry.argv[1], "--with=a \"quoted\" thing")
        // `%U` and `--file=%f` both disappear; a plain flag survives.
        XCTAssertEqual(entry.argv.last, "-n")
        XCTAssertEqual(entry.argv.count, 3)
        XCTAssertEqual(entry.categories, ["Graphics", "2DGraphics", "RasterGraphics"])
        XCTAssertEqual(entry.keywords, ["photo", "image;editor"])
        XCTAssertEqual(entry.source, .system)
        // A `[Desktop Action]` group must not leak into the entry.
        XCTAssertFalse(entry.argv.contains("/bin/false"))
    }

    private func parse(_ body: String) -> DesktopEntry? {
        DesktopEntryParser.parse(
            text: "[Desktop Entry]\nType=Application\nName=X\nExec=/bin/x\n" + body,
            path: "/usr/share/applications/x.desktop")
    }

    func testExclusions() {
        XCTAssertNil(parse("NoDisplay=true"))
        XCTAssertNil(parse("Hidden=true"))
        // Deliberately NOT excluded: MSL is not any XDG desktop, and
        // honouring these would hide apps that run fine under mslgd.
        XCTAssertNotNil(parse("OnlyShowIn=GNOME;"))
        XCTAssertNotNil(parse("NotShowIn=KDE;"))
        XCTAssertNil(DesktopEntryParser.parse(
            text: "[Desktop Entry]\nType=Link\nName=X\nURL=http://x\n", path: "/a/b.desktop"))
        XCTAssertNil(DesktopEntryParser.parse(
            text: "[Desktop Entry]\nName=X\n", path: "/a/b.desktop"), "no Exec")
        XCTAssertNotNil(DesktopEntryParser.parse(
            text: "[Desktop Entry]\nName=X\nExec=/bin/x\n", path: "/a/b.desktop"), "missing Type is tolerated")
    }

    func testUnterminatedQuoteKeepsTheEntry() throws {
        let entry = try XCTUnwrap(DesktopEntryParser.parse(
            text: "[Desktop Entry]\nName=Y\nExec=\"/bin/broken arg\nIcon=y\n", path: "/a/y.desktop"))
        XCTAssertEqual(entry.argv.first, "/bin/broken arg")
    }

    func testLocaleSelection() {
        let groups = DesktopEntryParser.parseGroups(
            "[Desktop Entry]\nName=Base\nName[fr]=French\nName[fr_CA]=Quebec\nName[de]=German\n")
        let entry = groups["Desktop Entry"]!
        XCTAssertEqual(DesktopEntryParser.localized(entry, "Name", locales: ["fr_CA", "fr"]), "Quebec")
        XCTAssertEqual(DesktopEntryParser.localized(entry, "Name", locales: ["fr"]), "French")
        XCTAssertEqual(DesktopEntryParser.localized(entry, "Name", locales: ["es"]), "Base")
    }

    func testLocaleNormalisation() {
        XCTAssertEqual(DesktopEntryParser.normalizeLocale("en-US"), "en_US")
        XCTAssertEqual(DesktopEntryParser.normalizeLocale("de_DE.UTF-8"), "de_DE")
        XCTAssertEqual(DesktopEntryParser.normalizeLocale("sr_RS.UTF-8@latin"), "sr_RS@latin")
    }

    func testSourceClassification() {
        XCTAssertEqual(AppSource.classify(path: "/var/lib/flatpak/exports/share/applications/a.desktop"), .flatpak)
        XCTAssertEqual(AppSource.classify(path: "/home/ab/.local/share/flatpak/exports/share/applications/a.desktop"), .flatpak)
        XCTAssertEqual(AppSource.classify(path: "/var/lib/snapd/desktop/applications/firefox_firefox.desktop"), .snap)
        XCTAssertEqual(AppSource.classify(path: "/home/ab/.local/share/applications/a.desktop"), .user)
        XCTAssertEqual(AppSource.classify(path: "/usr/share/applications/a.desktop"), .system)
    }

    /// `Exec=` comes out of a file inside the guest and is interpolated
    /// into a shell command, so an injected `;` must end up quoted rather
    /// than running.
    func testExecIsShellQuoted() throws {
        let entry = try XCTUnwrap(DesktopEntryParser.parse(
            text: "[Desktop Entry]\nName=Evil\nExec=/bin/sh -c foo; touch /tmp/pwned\n",
            path: "/a/e.desktop"))
        XCTAssertFalse(entry.launchCommand.contains("; touch"))
        XCTAssertTrue(entry.launchCommand.contains("';'") || entry.launchCommand.contains("'foo;'"))
    }

    func testIconRanking() {
        let paths = [
            "/usr/share/icons/hicolor/48x48/apps/gimp.png",
            "/usr/share/pixmaps/gimp.xpm",
            "/usr/share/icons/hicolor/512x512/apps/gimp.png",
            "/usr/share/icons/hicolor/scalable/apps/gimp.svg",
        ]
        let candidates = paths.map { DesktopEntryScanner.IconCandidate(path: $0, name: "gimp") }
        // A vector beats every bitmap: macOS rasterises it at any size.
        XCTAssertEqual(DesktopEntryScanner.bestIcons(among: candidates)["gimp"]?.path, paths[3])
        let raster = candidates.filter { !$0.isVector }
        XCTAssertEqual(DesktopEntryScanner.bestIcons(among: raster)["gimp"]?.path, paths[2])
        // XPM loses to anything, because macOS cannot draw it at all.
        XCTAssertEqual(
            DesktopEntryScanner.bestIcons(among: [candidates[0], candidates[1]])["gimp"]?.path, paths[0])
        XCTAssertEqual(candidates[0].declaredSize, 48)
        XCTAssertEqual(candidates[2].declaredSize, 512)
        XCTAssertNil(candidates[3].declaredSize)
    }

    func testFetchedFileStreamParsing() {
        let payload = Data("hello".utf8).base64EncodedString()
        let output = """
        ===MSL_FILE:/usr/share/icons/a.png===
        \(payload)
        ===MSL_FILE_END===
        """
        XCTAssertEqual(
            DesktopEntryScanner.parseFiles(output)["/usr/share/icons/a.png"], Data("hello".utf8))
    }

    func testFetchedFileStreamWithCRLFLineEndings() {
        let payload = Data("hello".utf8).base64EncodedString()
        let output = ["===MSL_FILE:/usr/share/icons/a.png===", payload, "===MSL_FILE_END==="]
            .joined(separator: "\r\n")
        XCTAssertEqual(
            DesktopEntryScanner.parseFiles(output)["/usr/share/icons/a.png"], Data("hello".utf8))
    }

    /// The scan's output arrives through a PTY with CRLF line endings.
    /// Unnormalized, the whole stream was one line and every scan found
    /// zero applications.
    func testScanStreamWithCRLFLineEndings() {
        let output = [
            "===MSL_DESKTOP_ENTRY:/usr/share/applications/a.desktop===",
            "[Desktop Entry]", "Type=Application", "Name=Alpha", "Exec=alpha %F", "",
            "===MSL_DESKTOP_ENTRY:/usr/share/applications/b.desktop===",
            "[Desktop Entry]", "Type=Application", "Name=Beta", "Exec=beta", "",
        ].joined(separator: "\r\n")
        let entries = DesktopEntryParser.parseStream(output)
        XCTAssertEqual(entries.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(entries.map(\.path), [
            "/usr/share/applications/a.desktop", "/usr/share/applications/b.desktop",
        ])
    }
}
