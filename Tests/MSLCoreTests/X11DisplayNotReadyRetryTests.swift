import XCTest
@testable import MSLCore

/// NEW-1 — the first app launched after a cold VM boot sometimes dies
/// instantly with "cannot open display :1".
///
/// "x11tunnel ready" proves the guest can reach the tunnel; it proves
/// nothing about the host serving yet. Measured 2026-09-23: one failure in
/// three cold boots, so a race, and always the first app.
final class X11DisplayNotReadyRetryTests: XCTestCase {
    /// Each toolkit words it differently, and the retry has to recognise
    /// all of them or it fixes the bug for GTK only.
    func testEveryToolkitsWordingIsRecognised() {
        let samples = [
            "(mousepad:5054): Gtk-WARNING **: cannot open display: :1",          // GTK
            "xterm: Xt error: Can't open display: :1",                           // Xt / Athena
            "qt.qpa.xcb: could not connect to display :1",                       // Qt
            "Error: Failed to open display",                                     // misc
        ]
        for sample in samples {
            XCTAssertTrue(LinuxAppLauncher.looksLikeDisplayNotReady(sample), sample)
        }
    }

    /// Deliberately narrow. A retry that fires for a real failure turns one
    /// crash into two, and doubles anything the app did before dying.
    func testARealFailureIsNotRetried() {
        let samples = [
            "bash: krita: command not found",
            "Segmentation fault",
            "Gtk-WARNING **: Theme parsing error: gtk.css:12: not a number",
            "error while loading shared libraries: libfoo.so.1",
            "",
        ]
        for sample in samples {
            XCTAssertFalse(LinuxAppLauncher.looksLikeDisplayNotReady(sample), sample)
        }
    }

    /// Case-insensitive, because the toolkits do not agree on that either.
    func testMatchingIgnoresCase() {
        XCTAssertTrue(LinuxAppLauncher.looksLikeDisplayNotReady("CANNOT OPEN DISPLAY"))
        XCTAssertTrue(LinuxAppLauncher.looksLikeDisplayNotReady("Xt error: Can't Open Display: :1"))
    }
}
