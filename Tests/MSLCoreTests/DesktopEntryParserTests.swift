import XCTest
@testable import MSLCore

/// `.desktop` files as the packaging systems actually write them, rather
/// than as the specification describes them.
final class DesktopEntryParserTests: XCTestCase {
}

extension DesktopEntryParserTests {
    /// A real Flatpak export, markers and all. Before this, `@@u` and the
    /// closing `@@` were passed to `flatpak run` as arguments and every
    /// file-forwarding app refused to start.
    func testFlatpakFileForwardingMarkersAreDropped() {
        let entry = DesktopEntryParser.parse(text: """
        [Desktop Entry]
        Type=Application
        Name=Bottles
        Icon=com.usebottles.bottles
        Exec=/usr/bin/flatpak run --branch=stable --arch=aarch64 --command=bottles --file-forwarding com.usebottles.bottles @@u %U @@
        X-Flatpak=com.usebottles.bottles
        """, path: "/var/lib/flatpak/exports/share/applications/com.usebottles.bottles.desktop")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.argv, ["/usr/bin/flatpak", "run", "--branch=stable", "--arch=aarch64",
                                     "--command=bottles", "--file-forwarding", "com.usebottles.bottles"])
        XCTAssertEqual(entry?.source, .flatpak)
        XCTAssertFalse(entry?.launchCommand.contains("@@") ?? true)
    }

    /// The other marker spellings, and a real argument that only looks like
    /// one.
    func testOnlyRealMarkersAreDropped() {
        XCTAssertTrue(DesktopEntryParser.isFlatpakForwardingMarker("@@"))
        XCTAssertTrue(DesktopEntryParser.isFlatpakForwardingMarker("@@u"))
        XCTAssertTrue(DesktopEntryParser.isFlatpakForwardingMarker("@@f"))
        XCTAssertFalse(DesktopEntryParser.isFlatpakForwardingMarker("@@home"))
        XCTAssertFalse(DesktopEntryParser.isFlatpakForwardingMarker("@"))
        XCTAssertFalse(DesktopEntryParser.isFlatpakForwardingMarker("user@@host"))
    }

    /// Snap exports go through `env` with a BAMF hint, and the binary lives
    /// in `/snap/bin`, which only a login shell has on its PATH.
    func testSnapEntry() {
        let entry = DesktopEntryParser.parse(text: """
        [Desktop Entry]
        Type=Application
        Name=Signal
        Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/signal-desktop_signal-desktop.desktop /snap/bin/signal-desktop %U
        Icon=/snap/signal-desktop/current/meta/gui/icon.png
        """, path: "/var/lib/snapd/desktop/applications/signal-desktop_signal-desktop.desktop")
        XCTAssertEqual(entry?.source, .snap)
        XCTAssertEqual(entry?.argv.last, "/snap/bin/signal-desktop")
        XCTAssertEqual(entry?.icon, "/snap/signal-desktop/current/meta/gui/icon.png")
    }
}

extension DesktopEntryParserTests {
    /// Every system app appeared twice in the list: the same file arrived
    /// once from the fixed directory list and once through `XDG_DATA_DIRS`,
    /// whose entries end in a slash - two path strings, one file.
    func testPathsAreNormalisedSoOneFileIsOneApp() {
        let stream = """
        ===MSL_DESKTOP_ENTRY:/usr/share/applications/xterm.desktop===
        [Desktop Entry]
        Type=Application
        Name=XTerm
        Exec=xterm
        ===MSL_DESKTOP_ENTRY:/usr/share//applications/xterm.desktop===
        [Desktop Entry]
        Type=Application
        Name=XTerm
        Exec=xterm
        """
        let entries = DesktopEntryParser.parseStream(stream)
        XCTAssertEqual(entries.count, 2, "the parser itself keeps both - deduplication is the catalog's job")
        XCTAssertEqual(Set(entries.map(\.path)).count, 1, "but they must be the same path")
        XCTAssertEqual(entries[0].path, "/usr/share/applications/xterm.desktop")
    }

    func testNormalisation() {
        XCTAssertEqual(DesktopEntryParser.normalizePath("/usr//share///applications/a.desktop"),
                       "/usr/share/applications/a.desktop")
        XCTAssertEqual(DesktopEntryParser.normalizePath("/usr/share/applications/"),
                       "/usr/share/applications")
        XCTAssertEqual(DesktopEntryParser.normalizePath("/"), "/")
    }
}
