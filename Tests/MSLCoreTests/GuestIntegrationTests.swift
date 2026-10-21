import XCTest
@testable import MSLCore

final class ExperimentalSettingsDefaultsTests: XCTestCase {
    /// The menu bar joined the on-by-default integrations in v2. What made
    /// it risky before - a dozen menus running into a MacBook's notch - is
    /// handled by `MenuBarFitting` now.
    func testIntegrationsStartOn() {
        let settings = MSLExperimentalSettings()
        XCTAssertTrue(settings.openLinksOnMac)
        XCTAssertTrue(settings.preferMSLFiles)
        XCTAssertTrue(settings.globalMenuBar)
    }

    /// A file written before these flags existed must not turn the on-by-
    /// default ones off.
    func testOldFileGetsShippedDefaults() throws {
        let old = #"{"linuxShortcuts":true,"macTextNavigation":false,"screenshotKeys":false}"#
        let settings = try JSONDecoder().decode(MSLExperimentalSettings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.linuxShortcuts)
        XCTAssertTrue(settings.openLinksOnMac)
        XCTAssertTrue(settings.preferMSLFiles)
        XCTAssertTrue(settings.globalMenuBar, "an old file gets v2's defaults, menu bar included")
    }

    func testRoundTripKeepsTurnedOffIntegrations() throws {
        var settings = MSLExperimentalSettings()
        settings.openLinksOnMac = false
        settings.preferMSLFiles = false
        settings.globalMenuBar = true
        let decoded = try JSONDecoder().decode(MSLExperimentalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}

final class HostOpenPlanTests: XCTestCase {
    private let on = MSLExperimentalSettings()

    func testParsesRequestLine() {
        let line = Data(#"{"v":1,"kind":"url","targets":["https://example.com"],"cwd":"/home/me"}"#.utf8)
        XCTAssertEqual(HostOpenRequest.parse(line),
                       HostOpenRequest(kind: .url, targets: ["https://example.com"], cwd: "/home/me"))
        XCTAssertNil(HostOpenRequest.parse(Data(#"{"kind":"run","targets":["x"]}"#.utf8)))
        XCTAssertNil(HostOpenRequest.parse(Data(#"{"kind":"url","targets":[]}"#.utf8)))
        XCTAssertEqual(HostOpenRequest.parse(Data(#"{"kind":"dir","targets":["a"],"cwd":"rel"}"#.utf8))?.cwd, "/")
    }

    func testWebLinksOpenOnTheMac() {
        let plan = HostOpenPlan.make(for: HostOpenRequest(kind: .url, targets: ["https://example.com/a?b=1"]), settings: on)
        XCTAssertEqual(plan, .openWebURL(URL(string: "https://example.com/a?b=1")!))
    }

    func testTurnedOffLinksAreDeclined() {
        var off = on
        off.openLinksOnMac = false
        guard case .decline = HostOpenPlan.make(for: HostOpenRequest(kind: .url, targets: ["https://example.com"]), settings: off) else {
            return XCTFail("expected decline")
        }
    }

    /// The guest must not be able to make the Mac open arbitrary schemes.
    func testOnlyWebAndMailSchemesAreAccepted() {
        for target in ["file:///etc/passwd", "x-apple.systempreferences:com.apple.Keyboard", "javascript:alert(1)",
                       "ssh://host", "http:nohost", "not a url at all"] {
            guard case .decline = HostOpenPlan.make(for: HostOpenRequest(kind: .url, targets: [target]), settings: on) else {
                return XCTFail("\(target) should be declined")
            }
        }
    }

    func testMailtoWithAttachments() {
        let link = "mailto:a@example.com,b@example.com?subject=Hi%20there&body=See%20attached&cc=c@example.com&attach=file:///home/me/report%201.pdf&attachment=/tmp/x.txt"
        guard case .composeMail(let draft) = HostOpenPlan.make(for: HostOpenRequest(kind: .url, targets: [link]), settings: on) else {
            return XCTFail("expected a mail draft")
        }
        XCTAssertEqual(draft.to, ["a@example.com", "b@example.com"])
        XCTAssertEqual(draft.cc, ["c@example.com"])
        XCTAssertEqual(draft.subject, "Hi there")
        XCTAssertEqual(draft.body, "See attached")
        XCTAssertEqual(draft.attachments, ["file:///home/me/report 1.pdf", "/tmp/x.txt"])
        let kept = URLComponents(url: try! XCTUnwrap(draft.linkWithoutAttachments), resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? []
        XCTAssertEqual(kept, ["subject", "body", "cc"])
        XCTAssertEqual(HostOpenPlan.guestPath(from: draft.attachments[0], cwd: "/"), "/home/me/report 1.pdf")
    }

    func testFoldersGoToMSLFiles() {
        XCTAssertEqual(HostOpenPlan.make(for: HostOpenRequest(kind: .dir, targets: ["file:///home/me/My%20Stuff/"]), settings: on),
                       .showInFiles(guestPath: "/home/me/My Stuff", select: false))
        XCTAssertEqual(HostOpenPlan.make(for: HostOpenRequest(kind: .show, targets: ["notes.txt"], cwd: "/home/me/docs"), settings: on),
                       .showInFiles(guestPath: "/home/me/docs/notes.txt", select: true))
        var off = on
        off.preferMSLFiles = false
        guard case .decline = HostOpenPlan.make(for: HostOpenRequest(kind: .dir, targets: ["/home"]), settings: off) else {
            return XCTFail("expected decline")
        }
    }

    func testGuestPathNormalisation() {
        XCTAssertEqual(HostOpenPlan.guestPath(from: "/a/./b/../c/", cwd: "/"), "/a/c")
        XCTAssertEqual(HostOpenPlan.guestPath(from: "../../../..", cwd: "/home/me"), "/")
        XCTAssertEqual(HostOpenPlan.guestPath(from: "file://localhost/srv/x", cwd: "/"), "/srv/x")
        XCTAssertNil(HostOpenPlan.guestPath(from: "sftp://server/home", cwd: "/"))
        XCTAssertNil(HostOpenPlan.guestPath(from: "file://otherhost/x", cwd: "/"))
    }
}

final class GuestIntegrationTests: XCTestCase {
    /// The shim exists twice - as the string the kit ships and as the file
    /// the image build compiles - so this asserts neither can drift from the
    /// other. Editing only the `.c` would otherwise leave every running
    /// instance on the old shim with nothing to say so.
    func testGTKPickerSourceMatchesCheckedInFile() throws {
        let checkedIn = URL(fileURLWithPath: #filePath)   // Tests/MSLCoreTests/…
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Guest/init/msl-gtkpicker.c")
        let onDisk = try String(contentsOf: checkedIn, encoding: .utf8)
        XCTAssertEqual(GuestIntegration.gtkPickerSource, onDisk,
                       "regenerate Sources/MSLCore/GuestGTKPicker.swift from \(checkedIn.path)")
    }

    /// The portal must answer OpenURI, not only FileChooser.
    ///
    /// Every sandboxed app asks the portal to open a link rather than running
    /// a handler itself, so while this was missing the portal replied
    /// `UnknownMethod` and links from Flatpaks and snaps went nowhere.
    /// Exporting `GTK_USE_PORTAL=1` widened that to GTK3's
    /// `gtk_show_uri_on_window` - most of "click a link in a Linux app" -
    /// which is why the two must ship together.
    func testPortalServesOpenURI() {
        let portal = GuestIntegration.portalPython
        XCTAssertTrue(portal.contains("org.freedesktop.portal.OpenURI"))
        for method in ["OpenURI", "OpenFile", "OpenDirectory"] {
            XCTAssertTrue(portal.contains("<method name=\"\(method)\">"), method)
        }
        XCTAssertTrue(portal.contains("handle_openuri"))
        // It has to reach the Mac the same way the rest of MSL does, and
        // `msl-open` needs its kind argument or it prints usage and exits.
        XCTAssertTrue(portal.contains("\"msl-open\""))
        XCTAssertTrue(portal.contains("[opener, kind, uri]"))
    }

    /// **A cancel must still carry `uris`.** GTK's own portal client reads
    /// it *before* it looks at the response code, with a
    /// `g_variant_lookup(..., "^a&s", &uris)` that leaves the pointer
    /// uninitialised when the key is absent - and then walks it. Sending an
    /// empty `a{sv}` for a cancel segfaulted GTK inside the D-Bus callback
    /// and took the whole app down; cancelling Firefox's Save As crashed
    /// Firefox every time (gdb: SIGSEGV in libgtk-3 under libgio's signal
    /// dispatch, 2026-09-30).
    func testPortalAlwaysSendsURIsEvenOnCancel() {
        let portal = GuestIntegration.portalPython
        XCTAssertTrue(portal.contains(#"if "uris" not in results:"#))
        XCTAssertTrue(portal.contains(#"results["uris"] = GLib.Variant("as", [])"#))
        // The guard has to come after every branch that sets `results`, so
        // the cancel and the fell-through cases are covered too.
        guard let fallback = portal.range(of: #"if "uris" not in results:"#),
              let cancel = portal.range(of: "1 = the person cancelled"),
              let emit = portal.range(of: #"GLib.Variant("(ua{sv})", (response, results))"#)
        else { return XCTFail("the portal's response path changed shape") }
        XCTAssertTrue(cancel.lowerBound < fallback.lowerBound, "the guard must run after the cancel branch")
        XCTAssertTrue(fallback.lowerBound < emit.lowerBound, "the guard must run before the signal")
    }

    /// Off means off for every lever, not just the ones added first.
    func testFilePortalLinesOffUnsetsEverything() {
        let off = GuestIntegration.filePortalLines(enabled: false)
        XCTAssertTrue(off.contains("unset GTK_USE_PORTAL MSL_GTK_PICKER"))
        XCTAssertTrue(off.contains("msl-firefox-portal\" off"))
        XCTAssertFalse(off.contains("LD_PRELOAD"))
        XCTAssertFalse(off.contains("xdgdesktopportal"))
    }

    /// Each toolkit's lever is present, and the two that depend on something
    /// being installed are guarded on it rather than set unconditionally.
    func testFilePortalLinesOnCoversEveryToolkit() {
        let on = GuestIntegration.filePortalLines(enabled: true)
        XCTAssertTrue(on.contains("export GTK_USE_PORTAL=1"))
        XCTAssertTrue(on.contains("msl-firefox-portal\" on"))
        // Qt: only when the platform theme plugin is really readable.
        XCTAssertTrue(on.contains("QT_QPA_PLATFORMTHEME=xdgdesktopportal"))
        XCTAssertTrue(on.contains("libqxdgdesktopportal.so"))
        // GTK3's older dialog: only when the kit managed to build the shim.
        XCTAssertTrue(on.contains("msl-gtkpicker.so"))
        XCTAssertTrue(on.contains("MSL_GTK_PICKER=1"))
        // Appended to LD_PRELOAD, never replacing it - msl-eglsize.so is
        // already there and Krita repaints wrongly without it.
        XCTAssertTrue(on.contains(#"${LD_PRELOAD:+:$LD_PRELOAD}"#))
    }

    /// shellinit's EXEC frame carries a 16-bit command length.
    func testInstallCommandFitsOneExecFrame() {
        let command = GuestIntegration.installCommand()
        // 60000 is the margin, not the ceiling: the real limit is the EXEC
        // frame's 16-bit length (65535) for the command *and* its shell
        // scaffolding. The message carries the number so a failure says how
        // far over it went rather than just that it did. Gzipping the files
        // (see `GuestIntegration.gzipped`) is what bought the current
        // headroom - roughly 21 KB used at the time of writing.
        XCTAssertLessThan(command.utf8.count, 60_000,
                          "the kit is \(command.utf8.count) bytes; it travels in one EXEC frame")
        XCTAssertTrue(command.contains(GuestIntegration.stamp))
        // The shim is source, so the kit has somewhere to put it and a
        // compiler step that expects it there.
        XCTAssertTrue(command.contains(#""$MSL_D/lib""#))
        XCTAssertTrue(command.contains("msl-gtkpicker.c"))
        // The FileManager1 service must reach the directory the session bus
        // actually scans, not just the kit's own share dir - see the comment
        // in `installCommand`. Without this, "show in folder" finds nobody.
        XCTAssertTrue(command.contains(#"$HOME/.local/share/dbus-1/services"#))
        XCTAssertTrue(command.contains("org.freedesktop.FileManager1.service"))
        for file in GuestIntegration.files {
            XCTAssertTrue(command.contains(GuestIntegration.gzipped(file.contents).base64EncodedString()),
                          file.path)
        }
    }

    /// The stamp has to cover what the installer *does*, not only what it
    /// writes. While it hashed `files` alone, adding an install step left the
    /// stamp unchanged, so every guest that already had the kit skipped the
    /// whole block and the new step silently never ran.
    func testStampCoversTheInstallSteps() {
        XCTAssertTrue(GuestIntegration.installCommand().contains(GuestIntegration.postInstallSteps))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(GuestIntegration.postInstallSteps.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        // A stamp computed without the steps would differ from the real one.
        XCTAssertNotEqual(String(hash, radix: 16), GuestIntegration.stamp)
    }

    // MARK: - A shell must not kill the menu bridge

    /// `session-env.sh` is sourced by /etc/profile.d on every login shell.
    /// With the menu bar ON it must not contain the teardown, or opening a
    /// terminal takes the menus away from every app already running.
    func testSessionEnvDoesNotStopTheBridgeWhenMenusAreOn() {
        var on = MSLExperimentalSettings()
        on.globalMenuBar = true
        let script = GuestIntegration.sessionEnvFileCommand(settings: on)
        XCTAssertFalse(script.contains("msl_menubridge.py*) kill"),
                       "a login shell must never kill a running bridge")
        XCTAssertFalse(script.contains("--ready-file"),
                       "and a shell has no business starting one either")
    }

    /// Switching the menu bar off still has to reach shells, so a bridge
    /// left running from when it was on is torn down.
    func testSessionEnvStopsTheBridgeWhenMenusAreOff() {
        var off = MSLExperimentalSettings()
        off.globalMenuBar = false
        let script = GuestIntegration.sessionEnvFileCommand(settings: off)
        XCTAssertTrue(script.contains("msl-menubridge.pid"))
        XCTAssertFalse(script.contains("--ready-file"))
    }

    // MARK: - Qt's portal theme, for apps it breaks

    /// The launcher consults the list the bridge writes, and the name it
    /// looks up is the binary - not the whole command line.
    func testLaunchCommandChecksThePortalThemeWedgeList() {
        let command = GuestIntegration.launchCommand("krita --nosplash",
                                                     instance: "test-no-overrides",
                                                     settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("qt-portal-theme-wedges"))
        XCTAssertTrue(command.contains("grep -qx -- 'krita'"))
        XCTAssertTrue(command.contains("unset QT_QPA_PLATFORMTHEME"))
    }

    /// `/proc/<pid>/comm` is capped at 15 characters, so the name looked up
    /// has to be capped the same way or a long-named app is recorded on
    /// every launch and matched on none.
    func testWedgeNameIsCappedLikeProcComm() {
        let command = GuestIntegration.launchCommand("qtcreator-with-a-long-name",
                                                     instance: "test-no-overrides",
                                                     settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("grep -qx -- 'qtcreator-with-'"), "must compare the first 15 characters")
    }

    /// `/proc/<pid>/comm` is what the bridge records, so an interpreted app
    /// has to be looked up under the interpreter: that is the process whose
    /// D-Bus connection is the one that wedged.
    func testWedgeNameIsTheBinaryNotTheScript() {
        XCTAssertEqual(GuestIntegration.commandBinaryName("python3 /opt/app/run.py"), "python3")
        XCTAssertEqual(GuestIntegration.commandBinaryName("/usr/bin/krita"), "krita")
    }

    /// Custom launch commands carry both of these, and neither is the
    /// program being run.
    func testWedgeNameStepsOverEnvAndAssignments() {
        XCTAssertEqual(GuestIntegration.commandBinaryName("env QT_SCALE_FACTOR=1 krita"), "krita")
        XCTAssertEqual(GuestIntegration.commandBinaryName("GDK_BACKEND=x11 gedit notes.txt"), "gedit")
        XCTAssertNil(GuestIntegration.commandBinaryName(""))
    }

    /// Nothing is hardcoded: with no list on the guest the check is still
    /// emitted, finds nothing and leaves the theme alone, so an app that
    /// has never misbehaved keeps MSL Files as its picker.
    func testNoAppIsSkippedByName() {
        for app in ["krita", "gimp", "chromium", "python3"] {
            let command = GuestIntegration.launchCommand(app, instance: "test-no-overrides",
                                                         settings: MSLExperimentalSettings())
            XCTAssertFalse(command.contains("unset QT_QPA_PLATFORMTHEME\nexport"),
                           "\(app) must only lose the theme through the learned list")
            XCTAssertTrue(command.contains("[ -r \"$msl_wedges\" ]"))
        }
    }

    func testLaunchCommandPutsKitFirstAndKeepsCommand() {
        // Menus off, so this tests the kit's own ordering rather than the
        // menu bridge's own lines.
        var plain = MSLExperimentalSettings()
        plain.globalMenuBar = false
        let command = GuestIntegration.launchCommand("krita --nosplash", instance: "test-no-overrides", settings: plain)
        XCTAssertTrue(command.hasPrefix("export DISPLAY=:1\n"))
        XCTAssertTrue(command.contains(#"export XDG_DATA_DIRS="$MSL_D/share:"#))
        XCTAssertTrue(command.contains(#"export XDG_CONFIG_DIRS="$MSL_D/config:"#))
        XCTAssertTrue(command.hasSuffix("\nkrita --nosplash"))
        // Off does not *start* a bridge. It still names one, because
        // turning the feature off has to stop a bridge left running from
        // when it was on - see `testTurningTheMenuBarOffStopsARunningBridge`.
        XCTAssertFalse(command.contains("--ready-file"), "off must not start a bridge")
        XCTAssertFalse(command.contains("appmenu-gtk-module"))
    }

    /// And with the menu bar on, which is now the default, the bridge is
    /// brought up before the app - beside it, never as its parent.
    func testMenuBarOnStartsTheBridgeBesideTheApp() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("msl_menubridge.py"))
        XCTAssertTrue(command.hasSuffix("\nkrita"))
    }

    /// The module that hides an app's own menu bar is never loaded on
    /// spec: GIMP has no menus anywhere if it is, because GIMP exports
    /// none. It is loaded only for a program the bridge has already
    /// recorded as exporting.
    func testTheMenuModuleIsOnlyLoadedForAKnownExporter() {
        let command = GuestIntegration.launchCommand("mousepad", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains(#"grep -qxF "mousepad" "$MSL_D/state/menu-exporters""#), command)
        XCTAssertTrue(command.contains("appmenu-gtk-module"))

        // Nothing MSL can attribute to a process name, so nothing is
        // hidden - the app keeps its own menu bar as well.
        for unattributable in ["flatpak run org.gnome.Calculator", "GDK_BACKEND=x11 gedit"] {
            let other = GuestIntegration.launchCommand(unattributable, instance: "test-no-overrides", settings: MSLExperimentalSettings())
            XCTAssertTrue(other.contains(#"[ -n "" ]"#), unattributable)
        }
    }

    /// The wrapper this replaced `exec`ed the app, so everything after it -
    /// including the transient user scope snaps need - was unreachable.
    /// Turning the menu bar on must not cost a snap its cgroup again.
    func testMenuBarLeavesTheUserScopeReachable() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        let bridge = command.range(of: "msl_menubridge.py")!
        let scope = command.range(of: "systemd-run --user --scope")!
        XCTAssertTrue(bridge.lowerBound < scope.lowerBound)
        XCTAssertTrue(command.contains(#"GTK_MODULES="${GTK_MODULES-}""#))
    }

    /// Debian's gnome-chess lives in /usr/games, which a non-login shell's
    /// PATH lacks - launches from the Applications tab exited 127.
    func testAppsInGameAndFlatpakDirectoriesAreFound() {
        for command in [GuestIntegration.launchCommand("gnome-chess", instance: "test-no-overrides", settings: MSLExperimentalSettings()),
                        GuestIntegration.oneShotDisplayPrefix()] {
            XCTAssertTrue(command.contains(":/usr/games:"), command)
            XCTAssertTrue(command.contains("/var/lib/flatpak/exports/bin"), command)
        }
    }

    /// A command with quotes in it still reaches the app intact, through
    /// the user scope that now runs it.
    func testGlobalMenuKeepsTheCommandQuoted() {
        var settings = MSLExperimentalSettings()
        settings.globalMenuBar = true
        let command = GuestIntegration.launchCommand("echo 'it''s' && app", instance: "test-no-overrides", settings: settings)
        XCTAssertTrue(command.contains(GuestIntegration.shellQuotedForTesting("echo 'it''s' && app")))
    }

    /// MSL's own entries never show up as Linux apps to launch, or the scan
    /// would offer MSL's plumbing back to the person - and, for MSL Files,
    /// generate a bundle shadowing the real Mac app.
    ///
    /// Two ways to be excluded, because they are not the same thing:
    /// `NoDisplay` hides an entry from the Linux menu too, which is right for
    /// a pure handler. MSL Files is a real file manager on the Linux side and
    /// belongs in that menu, so it is marked `X-MSL-Internal` instead.
    func testHandlersAreHiddenFromTheAppScan() {
        for file in GuestIntegration.files where file.path.hasSuffix(".desktop") {
            let hidden = file.contents.contains("NoDisplay=true")
                || file.contents.contains("X-MSL-Internal=true")
            XCTAssertTrue(hidden, file.path)
            XCTAssertNil(DesktopEntryParser.parse(text: file.contents, path: file.path), file.path)
        }
    }

    /// MSL Files is an app on the Linux side, not only a folder handler.
    func testMSLFilesIsALinuxApplication() {
        let entry = GuestIntegration.filesDesktop
        XCTAssertFalse(entry.contains("NoDisplay=true"))
        XCTAssertTrue(entry.contains("Icon=msl-files"))
        XCTAssertTrue(entry.contains("Categories=") && entry.contains("FileManager"))
        // The icon it names has to be one the kit actually installs.
        XCTAssertTrue(GuestIntegration.files.contains {
            $0.path == "share/icons/hicolor/scalable/apps/msl-files.svg"
        })
        // Launched from the menu there is no %u, so `dir` with no target has
        // to mean something - the Linux home.
        XCTAssertTrue(GuestIntegration.mslOpenPython.contains("expanduser(\"~\")"))
    }

    /// xdg-mime's `desktop_file_to_binary` takes the first word of `Exec`
    /// literally: a quoted path never resolves, and it then skips the
    /// handler and falls back to the distro default (found live - Qt and
    /// `xdg-open` still opened Chromium while gio already used MSL's).
    func testExecLinesAreUnquotedForXdgMime() {
        let execs = GuestIntegration.files.filter { $0.path.hasSuffix(".desktop") }
            .flatMap { $0.contents.split(separator: "\n").filter { $0.hasPrefix("Exec=") } }
        XCTAssertEqual(Set(execs), ["Exec=@MSLDIR@/bin/msl-open url %u", "Exec=@MSLDIR@/bin/msl-open dir %u"])
    }

    /// The handlers are Python and shell carried in Swift strings, where a
    /// typo is invisible until a guest runs them.
    func testScriptsAreSyntacticallyValid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msl-kit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in GuestIntegration.files {
            let url = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.replacingOccurrences(of: "@MSLDIR@", with: directory.path).write(to: url, atomically: true, encoding: .utf8)
            let checker: [String]
            if file.path.hasSuffix(".py") {
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { continue }
                checker = ["/usr/bin/python3", "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", url.path]
            } else if file.contents.hasPrefix("#!/bin/sh") {
                checker = ["/bin/sh", "-n", url.path]
            } else {
                continue
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: checker[0])
            process.arguments = Array(checker.dropFirst())
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "\(file.path): \(message)")
        }
    }
}

final class GlobalMenuTests: XCTestCase {
    func testMenuBridgeAnnouncementRoutesByName() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let frame: [UInt8] = Array("MSLM".utf8) + [5] + Array("krita".utf8)
        _ = frame.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        let announced = X11AppIdentity.read(fd: fds[0])
        XCTAssertEqual(announced.appName, "Krita")
        XCTAssertEqual(announced.consumed, X11AppIdentity.menuMagic)
    }

    func testX11AnnouncementIsUnchanged() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let frame: [UInt8] = Array("MSLA".utf8) + [4] + Array("gimp".utf8)
        _ = frame.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        let announced = X11AppIdentity.read(fd: fds[0])
        XCTAssertEqual(announced.appName, "Gimp")
        XCTAssertEqual(announced.consumed, [])
    }

    func testMenuItemParsing() throws {
        let json = #"""
        {"id":0,"label":"","children":[
          {"id":1,"label":"_File","submenu":true,"children":[
            {"id":2,"label":"_Open…","enabled":true},
            {"id":3,"type":"separator"},
            {"id":4,"label":"Show __hidden","toggle":"checkmark","state":1},
            {"id":5,"label":"Gone","visible":false}
          ]},
          {"id":6,"label":"_Edit","children":[]}
        ]}
        """#
        let root = try XCTUnwrap(X11GlobalMenuItem(json: try JSONSerialization.jsonObject(with: Data(json.utf8))))
        XCTAssertEqual(root.topLevelSignature, ["1:File", "6:Edit"])
        let file = try XCTUnwrap(root.find(1))
        XCTAssertTrue(file.hasSubmenu)
        XCTAssertEqual(file.children.map(\.label), ["Open…", "", "Show _hidden", "Gone"])
        XCTAssertTrue(file.children[1].isSeparator)
        XCTAssertEqual(file.children[2].toggle, .checkmark)
        XCTAssertTrue(file.children[2].isOn)
        XCTAssertFalse(file.children[3].visible)
        XCTAssertFalse(try XCTUnwrap(root.find(6)).hasSubmenu)
    }
}

final class MSLVersionTests: XCTestCase {
    func testBuildScriptShipsTheSameVersion() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/build-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("<key>CFBundleShortVersionString</key><string>\(MSLVersion.marketing)</string>"))
        XCTAssertEqual(MSLVersion.display, "MSL-2.0.0")
    }
}

extension GuestIntegrationTests {
    /// Every launched app gets a session bus, not just the ones using the
    /// menu bridge. A Flatpak GTK4 app (Amberol) died without one:
    /// "Unable to acquire session bus", because `dbus-launch --autolaunch`
    /// needs an X11 session manager MSL does not run.
    func testEveryLaunchGetsASessionBus() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("DBUS_SESSION_BUS_ADDRESS"))
        XCTAssertTrue(command.contains("dbus-daemon --session --fork --print-address"))
        XCTAssertTrue(command.contains("XDG_RUNTIME_DIR"), "portals and sockets live there")
    }

    /// One bus per boot, shared: two apps that cannot see the same bus
    /// cannot do single-instance, portals or the menu bridge.
    func testTheBusAddressIsRemembered() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("msl-dbus-"))
        XCTAssertTrue(command.contains("[ -S \"$msl_sock\" ]"), "a stale address must not be reused")
    }

    /// The whole thing still has to be a valid shell script.
    func testLaunchCommandParsesAsShell() throws {
        var settings = MSLExperimentalSettings()
        settings.globalMenuBar = true
        for command in [GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings()),
                        GuestIntegration.launchCommand("'/opt/My App/run' --flag", instance: "test-no-overrides", settings: settings)] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("msl-launch-\(UUID().uuidString).sh")
            try command.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", url.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "not valid shell: \(text)")
        }
    }
}

extension GuestIntegrationTests {
    /// The bug: `/tmp/x11tunnel-1-5003.pid` is owned by root inside the
    /// shipped images (the build left it there), so launching an app as
    /// the user failed with "Permission denied" before any window existed.
    func testTunnelFilesArePerUser() {
        let command = GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        XCTAssertTrue(command.contains("msl-x11tunnel-$(id -u"), "the pidfile has to carry the uid")
        XCTAssertFalse(command.contains(">/tmp/x11tunnel-native.log"), "never write the shared root-owned log")
        XCTAssertTrue(command.contains("rm -f /tmp/x11tunnel-1-5003.pid"), "clean the old ones when allowed")
        XCTAssertTrue(command.contains("--announce"))
    }

    /// A tunnel someone else started (a `-u root` session) is still a good
    /// tunnel; starting a second one would fail on the bound socket.
    func testLivenessDoesNotDependOnOwningThePidfile() {
        let command = GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        XCTAssertTrue(command.contains("*/x11tunnel)"),
                      "liveness matches the binary behind /proc/<pid>/exe")
    }

    func testTunnelCommandParsesAsShell() throws {
        for command in [GuestIntegration.tunnelStartCommand(display: 0, port: 5002, announce: false),
                        GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("msl-tunnel-\(UUID().uuidString).sh")
            try command.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", url.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "not valid shell: \(text)")
        }
    }
}

extension GuestIntegrationTests {
    /// The liveness probe must not match the script that contains it.
    ///
    /// It did: the start command's own text has `x11tunnel 1 5003` in it
    /// (that is what it runs), so `pgrep -f` found "a tunnel", skipped
    /// starting one, and every app launched afterwards failed with "Failed
    /// to open display". The probe now matches on `/proc/<pid>/exe`.
    func testLivenessProbeCannotMatchItself() {
        let command = GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        // The word still appears in a comment explaining the history; what
        // must not appear is a call.
        XCTAssertFalse(command.contains("pgrep -f \""), "pgrep -f matched this very script")
        XCTAssertTrue(command.contains("readlink \"$msl_p/exe\""))
        XCTAssertTrue(command.contains("tr '\\0' ' '"), "cmdline is NUL-separated")
    }

    /// Proves the probe against a fake `/proc`: one entry that is the
    /// tunnel, one that is a shell whose command line merely mentions it.
    func testProbeAgainstAFakeProc() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-proc-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        // 101: a shell running the start script - its command line contains
        // "x11tunnel 1 5003", which is exactly what used to fool pgrep.
        let shell = root.appendingPathComponent("101")
        try fm.createDirectory(at: shell, withIntermediateDirectories: true)
        try "/bin/sh\u{0}-c\u{0}exec /usr/local/bin/x11tunnel 1 5003 --announce\u{0}"
            .write(to: shell.appendingPathComponent("cmdline"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: shell.appendingPathComponent("exe").path,
                                  withDestinationPath: "/bin/sh")

        // The probe, with /proc swapped for the fixture.
        let probe = """
        found=0
        for msl_p in \(root.path)/[0-9]*; do
            msl_exe=$(readlink "$msl_p/exe" 2>/dev/null) || continue
            case "$msl_exe" in */x11tunnel) ;; *) continue ;; esac
            msl_args=$(tr '\\0' ' ' < "$msl_p/cmdline" 2>/dev/null)
            case "$msl_args" in *" 1 5003 "*) found=1 ;; esac
        done
        echo $found
        """
        XCTAssertEqual(try runShell(probe), "0", "a shell that merely mentions the tunnel is not a tunnel")

        // 202: the real thing.
        let tunnel = root.appendingPathComponent("202")
        try fm.createDirectory(at: tunnel, withIntermediateDirectories: true)
        try "/usr/local/bin/x11tunnel\u{0}1\u{0}5003\u{0}--announce\u{0}"
            .write(to: tunnel.appendingPathComponent("cmdline"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: tunnel.appendingPathComponent("exe").path,
                                  withDestinationPath: "/usr/local/bin/x11tunnel")
        XCTAssertEqual(try runShell(probe), "1", "the real tunnel has to be found")
    }

    private func runShell(_ script: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-probe-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension GuestIntegrationTests {
    /// A generated guest script must never contain a NUL byte.
    ///
    /// `tr '\\0' ' '` written in a plain Swift multiline literal is
    /// `tr '<NUL>' ' '`: the escape is Swift's, not the shell's. The
    /// cleanup command carried that NUL, so the script it produced did
    /// nothing at all - while still reporting that it had run.
    func testGeneratedScriptsHaveNoNulBytes() {
        for (name, script) in [("cleanup", GuestIntegration.tunnelCleanupCommand(display: 1, port: 5003)),
                               ("start", GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)),
                               ("launch", GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings()))] {
            XCTAssertFalse(script.unicodeScalars.contains("\u{0}"), "\(name) contains a NUL byte")
            XCTAssertTrue(script.contains("tr '\\0' ' '") || !script.contains("cmdline"),
                          "\(name) must ask tr for a literal backslash-zero")
        }
    }

    /// And the cleanup has to actually remove the thing that blocks the
    /// bind: a root-owned socket in a sticky directory.
    ///
    /// It used to stop short on finding any tunnel process for the display,
    /// which is exactly the state that needs clearing - a live tunnel
    /// listening on an inode the socket path no longer names. Cleanup only
    /// runs after a start has already failed, so a surviving process there
    /// is the obstacle, and it goes first.
    func testCleanupRemovesTheStaleSocket() {
        let cleanup = GuestIntegration.tunnelCleanupCommand(display: 1, port: 5003)
        XCTAssertTrue(cleanup.contains("rm -f /tmp/.X11-unix/X1"))
        XCTAssertTrue(cleanup.contains("kill $msl_kill"), "a tunnel holding the display has to go too")
        XCTAssertFalse(cleanup.contains("MSL-TUNNEL-RUNNING"))
    }
}

extension GuestIntegrationTests {
    /// "x11tunnel ready" then "Failed to open display" - the check believed
    /// a pid. A second tunnel (started by another MSL path) unlinks the
    /// socket before binding its own; when that one dies, the first is
    /// still running with nothing listening on the path clients use.
    func testReadinessRequiresTheSocketNotJustAProcess() {
        let command = GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        XCTAssertTrue(command.contains("msl_tunnel_socket=/tmp/.X11-unix/X1"))
        XCTAssertTrue(command.contains("[ -S \"$msl_tunnel_socket\" ] || return 1"),
                      "no socket means not usable, whatever /proc says")
        XCTAssertTrue(command.contains("kill $msl_orphans"), "an orphan with no socket has to go")
        XCTAssertTrue(command.contains("did not create $msl_tunnel_socket"),
                      "the failure has to say what was actually missing")
    }

    /// Waiting in short steps rather than one flat second: a slow guest
    /// used to be called a failure, a fast one wasted the wait.
    func testStartWaitsForTheSocketToAppear() {
        let command = GuestIntegration.tunnelStartCommand(display: 1, port: 5003, announce: true)
        XCTAssertTrue(command.contains("msl_tries"))
        XCTAssertFalse(command.contains("sleep 1\n"), "the flat one-second wait is gone")
    }
}

extension GuestIntegrationTests {
    /// Snap checks the launching process's cgroup and refuses anything
    /// outside a user slice ("/system.slice/shellinit.service is not a snap
    /// cgroup"), and portals want /run/user/<uid>. Both come from a real
    /// logind session.
    func testUserSessionIsPreparedForSnapAndPortals() {
        let command = GuestIntegration.userSessionCommand(user: "abinaash")
        XCTAssertTrue(command.contains("loginctl enable-linger \"$msl_user\""))
        XCTAssertTrue(command.contains("msl_user='abinaash'"))
        // It waits for the runtime directory, not for a session bus socket
        // inside it: Fedora makes the directory and never that socket, so
        // waiting for one cost five seconds per guest command and bought
        // nothing. See `GuestSessionWaitTests`.
        XCTAssertTrue(command.contains("/run/user/$msl_uid"))
        XCTAssertFalse(command.contains("-S \"/run/user/$msl_uid/bus\""))
        XCTAssertTrue(command.contains("MSL-SESSION-NONE"), "a guest without logind must not fail")
    }

    func testAppsRunInsideTheUserSlice() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("systemd-run --user --scope --quiet -- env"))
        XCTAssertTrue(command.contains("sh -c 'krita'"))
        // A scope starts from the user manager's environment: anything the
        // app needs has to be handed over by name.
        for variable in ["DISPLAY", "GSK_RENDERER", "XDG_RUNTIME_DIR",
                         "DBUS_SESSION_BUS_ADDRESS", "XDG_DATA_DIRS"] {
            XCTAssertTrue(command.contains("\(variable)=\"$"), "\(variable) is not passed into the scope")
        }
        XCTAssertTrue(command.contains("[ -S \"${XDG_RUNTIME_DIR-}/bus\" ]"),
                      "only when there really is a user session")
        XCTAssertTrue(command.contains("GSK_RENDERER=cairo"))
        XCTAssertTrue(command.hasSuffix("krita"), "and the plain command stays as the fallback")
    }

    /// Krita's window repainted only its top 480 rows: Mesa's software EGL
    /// freezes a surface's height when the surface is made, and Qt makes it
    /// at 640x480 before layout. `msl-eglsize.so` makes Mesa re-read it. It
    /// has to be preloaded only when the image carries it, never pushed in
    /// twice, and - like everything else - handed into the app's scope by
    /// name, or the scope starts without it and the fix silently vanishes.
    func testTheEGLSizeShimIsPreloadedAndReachesTheScope() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("[ -r /usr/local/lib/msl-eglsize.so ]"),
                      "only when the image actually has the shim")
        XCTAssertTrue(command.contains(#"export LD_PRELOAD="/usr/local/lib/msl-eglsize.so${LD_PRELOAD:+:$LD_PRELOAD}""#),
                      "added in front of, not instead of, anything already preloaded")
        XCTAssertTrue(command.contains("*:/usr/local/lib/msl-eglsize.so:*) ;;"),
                      "never added twice")
        XCTAssertTrue(command.contains(#"LD_PRELOAD="${LD_PRELOAD-}""#),
                      "LD_PRELOAD is not passed into the scope")
    }

    func testSessionBusPrefersLogind() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("unix:path=/run/user/$(id -u)/bus"))
    }
}

extension GuestIntegrationTests {
    /// Every GTK4 app waits out D-Bus's 25-second timeout when a session bus
    /// exists and no Settings portal answers. GNOME Chess: 25.9s from MSL,
    /// 0.8s from a shell, and the bus was the only difference.
    func testTheSettingsPortalIsStarted() {
        let command = GuestIntegration.launchCommand("krita", instance: "test-no-overrides", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.contains("msl_portal.py"))
        XCTAssertTrue(command.contains("MSL_COLOR_SCHEME="), "the Mac's appearance goes across")
        XCTAssertTrue(command.contains("msl-portal-$(id -u"), "one per user, like the tunnel")
    }

    /// It has to be valid shell, and free of NUL bytes, like everything else
    /// MSL sends a guest.
    func testPortalStarterIsValidShell() throws {
        let script = GuestIntegration.portalLines(colorScheme: 1)
        XCTAssertFalse(script.unicodeScalars.contains("\u{0}"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-portal-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", url.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "not valid shell: \(text)")
    }

    /// The portal itself must be valid Python - it runs in the guest where
    /// nothing would report a syntax error back.
    /// The sign-in detector, run for real against URLs it will actually meet.
    ///
    /// Precision is the whole risk here: being wrong sends someone's ordinary
    /// link to a browser inside Linux instead of their own. So this asserts
    /// the negatives as hard as the positives.
    func testSignInDetectionIsNarrow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("msl_open.py")
        try GuestIntegration.mslOpenPython
            .replacingOccurrences(of: "@MSLDIR@", with: directory.path)
            .write(to: script, atomically: true, encoding: .utf8)

        let mustStayInLinux = [
            // Loopback redirect: the Linux app is listening there, the Mac is not.
            "https://accounts.google.com/o/oauth2/auth?client_id=a&response_type=code&redirect_uri=http://127.0.0.1:53682/",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=a&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A8400%2F",
            // A private scheme belongs to a Linux app; macOS would find the
            // wrong app or none.
            "https://discord.com/oauth2/authorize?client_id=1&response_type=code&redirect_uri=discord%3A%2F%2Fauth",
            // PKCE without a response type is still an authorisation request.
            "https://id.example.com/authorize?client_id=x&code_challenge=abc",
        ]
        let mustGoToTheMac = [
            "https://example.com/",
            "https://news.ycombinator.com/item?id=1",
            "https://en.wikipedia.org/wiki/OAuth",
            // Mentions the words but carries none of the parameters.
            "https://www.google.com/search?q=oauth+client_id+redirect_uri",
            // A redirect back to an ordinary web address is just a web flow.
            "https://shop.example.com/login?redirect_uri=https%3A%2F%2Fshop.example.com%2Fcart",
            // Not a web link at all.
            "mailto:someone@example.com",
        ]

        let harness = """
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location("mslopen", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for url in sys.argv[2:]:
            print("%s %s" % (module.looks_like_sign_in(url), url))
        """
        let harnessURL = directory.appendingPathComponent("harness.py")
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", harnessURL.path, script.path]
            + mustStayInLinux + mustGoToTheMac
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)

        let verdicts = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(verdicts.count, mustStayInLinux.count + mustGoToTheMac.count, text)
        for (index, line) in verdicts.enumerated() {
            let expected = index < mustStayInLinux.count
            XCTAssertTrue(line.hasPrefix(expected ? "True " : "False "),
                          "wrong verdict: \(line)")
        }
    }

    /// Both halves of the gate, so a guest with no browser is left alone.
    func testSignInMarkerAndBrowserAreBothRequired() {
        let script = GuestIntegration.mslOpenPython
        XCTAssertTrue(script.contains("SIGNIN_MARKER"))
        XCTAssertTrue(script.contains("os.path.exists(SIGNIN_MARKER)"))
        XCTAssertTrue(script.contains("guest_browser() is not None"))
        // The browser is run directly: going through xdg-open would come
        // back to MSL, which is this system's http handler.
        XCTAssertTrue(script.contains("os.execv(browser, [browser, url])"))

        XCTAssertTrue(GuestIntegration.signInBrowserLines(enabled: true).contains(".signin-browser"))
        XCTAssertTrue(GuestIntegration.signInBrowserLines(enabled: false).hasPrefix("rm -f"))
    }

    func testPortalIsValidPython() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-portal-\(UUID().uuidString).py")
        try GuestIntegration.portalPython.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "py_compile", url.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "not valid Python: \(text)")
    }
}

/// The kit is gzipped before base64 so it fits one EXEC frame. A guest that
/// cannot decompress it gets no integration kit at all, silently, so the
/// bytes are checked against what `gzip -cd` actually requires.
final class GuestKitCompressionTests: XCTestCase {
    func testProducesARealGzipStreamThatRoundTrips() throws {
        let text = "#!/usr/bin/env python3\nprint('hello')\n" + String(repeating: "x = 1\n", count: 200)
        let gz = GuestIntegration.gzipped(text)
        XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08], "gzip magic and deflate method")
        XCTAssertLessThan(gz.count, Data(text.utf8).count, "compression should actually shrink it")

        // The guest runs `gzip -cd`; nothing less proves the stream is valid.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("kit.gz")
        try gz.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-cd", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -cd must accept it")
        XCTAssertEqual(String(data: out, encoding: .utf8), text, "and round-trip exactly")
    }

    /// The CRC is what `gzip` checks; a wrong one decompresses and then
    /// fails, which is the worst shape of bug here.
    func testEveryShippedFileRoundTripsThroughGzip() throws {
        for file in GuestIntegration.files {
            let gz = GuestIntegration.gzipped(file.contents)
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("f.gz")
            try gz.write(to: path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-cd", path.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, file.path)
            XCTAssertEqual(String(data: out, encoding: .utf8), file.contents, file.path)
        }
    }
}

/// The kit ships Python and shell scripts as Swift string literals, which
/// the compiler never looks inside. A syntax error in one is invisible until
/// a guest runs it and nothing happens - and their output goes to /dev/null,
/// so it does not even fail loudly. These parse them the way the guest will.
final class GuestKitScriptSyntaxTests: XCTestCase {
    private func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let errors = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errors, as: UTF8.self))
    }

    private func write(_ contents: String, extension ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEveryPythonScriptInTheKitParses() throws {
        for file in GuestIntegration.files where file.path.hasSuffix(".py")
            || file.contents.hasPrefix("#!/usr/bin/env python3") {
            let url = try write(file.contents, extension: "py")
            defer { try? FileManager.default.removeItem(at: url) }
            let (status, errors) = try run("/usr/bin/python3", ["-m", "py_compile", url.path])
            XCTAssertEqual(status, 0, "\(file.path): \(errors)")
        }
    }

    func testEveryShellScriptInTheKitParses() throws {
        for file in GuestIntegration.files where file.contents.hasPrefix("#!/bin/sh") {
            let url = try write(file.contents, extension: "sh")
            defer { try? FileManager.default.removeItem(at: url) }
            let (status, errors) = try run("/bin/sh", ["-n", url.path])
            XCTAssertEqual(status, 0, "\(file.path): \(errors)")
        }
    }

    /// The picker is the guest's entry point for apps that do not speak
    /// D-Bus, so its contract is pinned: the exit codes a caller branches on.
    func testFilePickerDocumentsItsExitCodes() {
        let script = GuestIntegration.files.first { $0.path.hasSuffix("msl-file-picker") }?.contents
        let picker = try? XCTUnwrap(script)
        XCTAssertNotNil(picker)
        XCTAssertTrue(picker?.contains("0 picked") == true)
        XCTAssertTrue(picker?.contains("1 cancelled") == true)
        XCTAssertTrue(picker?.contains("2 unavailable") == true)
    }
}

// MARK: - A shell and an app must get the same session

/// The bug these lock down: a Linux app started from the Applications tab
/// worked, and the same app typed at a prompt inside the guest did not —
/// "Failed to connect to the bus", "Missing X server or $DISPLAY" (reported
/// 2026-10-01). The shell was given `DISPLAY` and nothing else, and on a
/// guest whose account is not root it was not even given that.
final class GuestSessionParityTests: XCTestCase {
    private var settings: MSLExperimentalSettings { MSLExperimentalSettings() }

    /// Everything an application is given, a shell is given too.
    func testShellEnvironmentCarriesEverythingAnAppGets() {
        let app = GuestIntegration.launchCommand("someapp", instance: "test-no-overrides", settings: settings)
        let shell = GuestIntegration.sessionEnvFileCommand(settings: settings)
        for needed in ["DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
                       "GSK_RENDERER", "QT_QUICK_BACKEND", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS"] {
            XCTAssertTrue(app.contains(needed), "the app path lost \(needed)")
            XCTAssertTrue(shell.contains(needed),
                          "a shell would not get \(needed) - this is the bug that broke chromium at a prompt")
        }
    }

    /// The profile stub must be written somewhere only root can write, which
    /// is exactly why it is a separate command from the per-user file.
    func testProfileStubTargetsSystemPathsAndSourcesThePerUserFile() {
        let stub = GuestIntegration.sessionProfileCommand()
        XCTAssertTrue(stub.contains("/etc/profile.d/00-msl-session.sh"))
        XCTAssertTrue(stub.contains("zshenv"), "zsh does not read /etc/profile on Debian or Arch")
        XCTAssertTrue(stub.contains("session-env.sh"), "the stub must source the per-user file")
        // $HOME, not a fixed path: one guest can have several accounts.
        XCTAssertTrue(stub.contains("$HOME"))
    }

    /// The per-user file must be written under $HOME, never into /etc - that
    /// write runs as the user and would silently do nothing.
    func testPerUserEnvFileIsWrittenUnderHome() {
        let command = GuestIntegration.sessionEnvFileCommand(settings: settings)
        XCTAssertTrue(command.contains("$HOME/"))
        XCTAssertFalse(command.contains("> /etc/"),
                       "writing to /etc as the user is what failed silently before")
    }

    /// A one-shot `msl <instance> <app>` goes through the same file.
    func testOneShotPrefixSourcesTheSessionFile() {
        let prefix = GuestIntegration.oneShotDisplayPrefix()
        XCTAssertTrue(prefix.contains("session-env.sh"))
        // ...and still works before that file exists.
        XCTAssertTrue(prefix.contains("export DISPLAY="))
    }

    /// Settings must reach the shell, or turning the picker off on the Mac
    /// would leave it on in every terminal.
    func testExperimentalSettingsReachTheShell() {
        var on = MSLExperimentalSettings(); on.preferMSLFiles = true
        var off = MSLExperimentalSettings(); off.preferMSLFiles = false
        XCTAssertNotEqual(GuestIntegration.sessionEnvFileCommand(settings: on),
                          GuestIntegration.sessionEnvFileCommand(settings: off),
                          "the shell's environment ignores the experimental settings")
    }

    /// The heredoc that writes the file must not be expanded while writing.
    func testSessionFileIsWrittenThroughAQuotedHeredoc() {
        let command = GuestIntegration.sessionEnvFileCommand(settings: settings)
        XCTAssertTrue(command.contains("<<'MSL_SESSION_ENV_EOF'"),
                      "an unquoted heredoc would expand $HOME and $PATH as it wrote them")
    }
}
