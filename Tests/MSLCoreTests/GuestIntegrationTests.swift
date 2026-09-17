import XCTest
@testable import MSLCore

final class ExperimentalSettingsDefaultsTests: XCTestCase {
    func testIntegrationsStartOnAndMenuBarStartsOff() {
        let settings = MSLExperimentalSettings()
        XCTAssertTrue(settings.openLinksOnMac)
        XCTAssertTrue(settings.preferMSLFiles)
        XCTAssertFalse(settings.globalMenuBar)
    }

    /// A file written before these flags existed must not turn the on-by-
    /// default ones off.
    func testOldFileGetsShippedDefaults() throws {
        let old = #"{"linuxShortcuts":true,"macTextNavigation":false,"screenshotKeys":false}"#
        let settings = try JSONDecoder().decode(MSLExperimentalSettings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.linuxShortcuts)
        XCTAssertTrue(settings.openLinksOnMac)
        XCTAssertTrue(settings.preferMSLFiles)
        XCTAssertFalse(settings.globalMenuBar)
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
    /// shellinit's EXEC frame carries a 16-bit command length.
    func testInstallCommandFitsOneExecFrame() {
        let command = GuestIntegration.installCommand()
        XCTAssertLessThan(command.utf8.count, 60_000)
        XCTAssertTrue(command.contains(GuestIntegration.stamp))
        for file in GuestIntegration.files {
            XCTAssertTrue(command.contains(Data(file.contents.utf8).base64EncodedString()), file.path)
        }
    }

    func testLaunchCommandPutsKitFirstAndKeepsCommand() {
        let command = GuestIntegration.launchCommand("krita --nosplash", settings: MSLExperimentalSettings())
        XCTAssertTrue(command.hasPrefix("export DISPLAY=:1\n"))
        XCTAssertTrue(command.contains(#"export XDG_DATA_DIRS="$MSL_D/share:"#))
        XCTAssertTrue(command.contains(#"export XDG_CONFIG_DIRS="$MSL_D/config:"#))
        XCTAssertTrue(command.hasSuffix("\nkrita --nosplash"))
        XCTAssertFalse(command.contains("msl-session"))
    }

    /// Debian's gnome-chess lives in /usr/games, which a non-login shell's
    /// PATH lacks - launches from the Applications tab exited 127.
    func testAppsInGameAndFlatpakDirectoriesAreFound() {
        for command in [GuestIntegration.launchCommand("gnome-chess", settings: MSLExperimentalSettings()),
                        GuestIntegration.oneShotDisplayPrefix()] {
            XCTAssertTrue(command.contains(":/usr/games:"), command)
            XCTAssertTrue(command.contains("/var/lib/flatpak/exports/bin"), command)
        }
    }

    func testGlobalMenuWrapsCommandQuoted() {
        var settings = MSLExperimentalSettings()
        settings.globalMenuBar = true
        let command = GuestIntegration.launchCommand("echo 'it''s' && app", settings: settings)
        XCTAssertTrue(command.contains(#"exec "$MSL_D/bin/msl-session" sh -c 'echo '\''it'\'''\''s'\'' && app'"#))
    }

    func testHandlersAreHiddenFromTheAppScan() {
        for file in GuestIntegration.files where file.path.hasSuffix(".desktop") {
            XCTAssertTrue(file.contents.contains("NoDisplay=true"), file.path)
        }
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
        XCTAssertEqual(MSLVersion.display, "MSL-1.0.0")
    }
}
