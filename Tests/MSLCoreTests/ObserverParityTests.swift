import XCTest
@testable import MSLCore
import MSLObserver

/// `MSLObserver` is a leaf with no dependencies - not even on MSLCore -
/// because a watchdog built on the same library as its subject falls over for
/// the same reasons its subject does.
///
/// The price of that is a handful of things written down twice: the paths the
/// observer watches, MSL's version, and the stop codes. This file is what
/// makes that price safe to pay. If any of them drifts, these fail - which is
/// the only reason duplicating them is acceptable at all.
final class ObserverParityTests: XCTestCase {

    // MARK: - One stop-code table

    func testEveryObserverCodeIsInMSLsOwnTable() {
        for code in ObserverStopCode.all {
            guard let folded = CrashScreen.allStopCodes.first(where: { $0.number == code.number })
            else { return XCTFail("\(code.printed) is missing from allStopCodes") }
            XCTAssertEqual(folded.name, code.name)
            XCTAssertEqual(folded.happened, code.happened)
            XCTAssertEqual(folded.next, code.next)
            XCTAssertEqual(folded.subsystem, code.subsystem)
            // And findable by name, which is how the crash window looks one
            // up from the note on disk.
            XCTAssertEqual(CrashScreen.code(named: code.name)?.number, code.number)
        }
    }

    /// A number means one thing, for ever. Two tables merged into one is
    /// exactly where a number would quietly come to mean two.
    func testNoNumberIsUsedTwice() {
        let numbers = CrashScreen.allStopCodes.map(\.number)
        XCTAssertEqual(Set(numbers).count, numbers.count,
                       "a stop code number is a promise and is never reused")
        let names = CrashScreen.allStopCodes.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testTheObserversCodesDoNotCollideWithMSLsOwn() {
        let own = Set(CrashScreen.ownStopCodes.map(\.number))
        for code in ObserverStopCode.all {
            XCTAssertFalse(own.contains(code.number), code.printed)
        }
    }

    /// The conditions MSL raises about itself always name a way out, except
    /// the ones it did not see coming - which name none, deliberately.
    func testOnlyTheUnanticipatedCodesWithholdAdvice() {
        for code in CrashScreen.allStopCodes {
            if code.number < 0x10 {
                XCTAssertNil(code.next, "\(code.name) must not invent advice")
                XCTAssertNil(code.subsystem, "\(code.name) must not blame a subsystem")
            } else {
                XCTAssertNotNil(code.next, "\(code.name) must say what to do")
                XCTAssertNotNil(code.subsystem, "\(code.name) must say what it is about")
            }
        }
    }

    // MARK: - The same places

    func testTheObserverWatchesWhereMSLActuallyIs() {
        // Under XCTest both of these redirect to temporary directories, so
        // the comparison is of the *shape*, which is what can drift.
        XCTAssertEqual(ObserverPaths.socket.lastPathComponent,
                       URL(fileURLWithPath: DaemonProtocol.defaultSocketPath()).lastPathComponent)
        XCTAssertEqual(ObserverPaths.daemonBinary.lastPathComponent,
                       MSLPaths.tool("mslhd").lastPathComponent)
        XCTAssertEqual(ObserverPaths.daemonBinary.deletingLastPathComponent().lastPathComponent,
                       MSLPaths.binDirectory.lastPathComponent)
        XCTAssertEqual(ObserverPaths.crashNote.lastPathComponent,
                       CrashScreen.reportURL.lastPathComponent)
        XCTAssertEqual(ObserverAgent.binary.lastPathComponent, "mslod")
        XCTAssertEqual(ObserverAgent.binary.deletingLastPathComponent().lastPathComponent,
                       MSLPaths.binDirectory.lastPathComponent)
    }

    /// The real, installed locations - not the test ones, and not whatever a
    /// rehearsal pointed the observer at. The observer has to find MSL on
    /// somebody's actual Mac.
    func testTheRealLocationsAgree() {
        let home = NSHomeDirectory()
        func short(_ url: URL) -> String { url.path.replacingOccurrences(of: home, with: "~") }
        XCTAssertEqual(short(ObserverPaths.installedAppSupport),
                       "~/Library/Application Support/MSL")
        XCTAssertEqual(short(ObserverPaths.installedLogs), "~/Library/Logs/MSL")
        XCTAssertEqual(short(ObserverPaths.installedAppSupport
            .appendingPathComponent("bin/mslod")),
                       "~/Library/Application Support/MSL/bin/mslod")
        XCTAssertEqual(short(ObserverAgent.plistURL),
                       "~/Library/LaunchAgents/com.msl.observer.plist")
        // And MSL agrees about where it keeps things.
        XCTAssertEqual(MSLPaths.logsDirectory.path, ObserverPaths.installedLogs.path)
    }

    func testTheVersionsAgree() {
        XCTAssertEqual(ObserverVersion.marketing, MSLVersion.marketing,
                       "a crash report that names the wrong version is worse than none")
    }

    // MARK: - The agent

    /// The watchdog comes back from any exit at all, unlike mslhd - whose
    /// clean exit means it was asked to stop and should stay stopped.
    func testTheObserversJobAlwaysComesBack() {
        let plist = ObserverAgent.plist(binary: URL(fileURLWithPath: "/tmp/mslod"))
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        // Aqua, because the one thing it must be able to do is put a window
        // in front of somebody.
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertEqual(plist["Label"] as? String, "com.msl.observer")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/tmp/mslod"])
    }

    /// launchd's own record of the observer goes somewhere the observer
    /// truncates rather than deletes, because launchd holds it open.
    func testLaunchdsLogIsOneTheObserverOnlyTruncates() {
        XCTAssertEqual(ObserverAgent.launchdLog.lastPathComponent, "observer-launchd.log")
    }

    // MARK: - The guide the crash screen points at

    /// Every code the crash screen can deep-link to has a heading of its own
    /// in the guide.
    ///
    /// The screen's one piece of advice that always applies is "read this",
    /// and an address that lands on a page with no such paragraph is worse
    /// than one that lands nowhere - it looks like the answer is missing
    /// rather than like the link is wrong.
    func testEveryCodeWithAdviceHasItsOwnParagraph() throws {
        let article = try XCTUnwrap(HelpGuide.article("stop-codes"))
        let anchors = Set(article.document.sections.map(\.anchor))
        for code in CrashScreen.allStopCodes where code.next != nil {
            let anchor = code.name.lowercased().replacingOccurrences(of: "_", with: "-")
            XCTAssertTrue(anchors.contains(anchor),
                          "\(code.printed) \(code.name) has nowhere to link to; the article has \(anchors.sorted())")
            // And that is the anchor the screen actually builds.
            XCTAssertTrue(CrashScreen.wikiPage(for: code).hasSuffix("#" + anchor))
        }
    }

    /// An uncaught error has no paragraph of its own, so it goes to the top
    /// of the page rather than to a heading that does not exist.
    func testAnUnknownCodeLandsOnThePageItself() {
        XCTAssertEqual(CrashScreen.wikiPage(for: nil), CrashScreen.wikiStopCodes)
        XCTAssertFalse(CrashScreen.wikiStopCodes.contains("#"))
    }

    func testTheObserverHasAPageOfItsOwn() {
        XCTAssertNotNil(HelpGuide.article("observer"),
                        "a program that can interrupt somebody has to be explainable")
    }

    // MARK: - Shipping

    func testTheObserverIsInstalledWithEverythingElse() {
        XCTAssertTrue(HostToolInstaller.tools.contains("mslod"),
                      "an observer that is not installed is not an observer")
    }

    /// The uninstaller has to stop the observer **before** it takes MSL
    /// apart, or it watches the uninstall and puts a crash screen up in the
    /// middle of it.
    func testTheUninstallerKnowsAboutTheObserver() {
        XCTAssertTrue(Uninstaller.Locations.live.launchAgents.contains {
            $0.lastPathComponent == "com.msl.observer.plist"
        }, "\(Uninstaller.Locations.live.launchAgents)")
    }
}
