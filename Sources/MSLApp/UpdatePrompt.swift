import AppKit
import MSLCore

/// Tells someone a new MSL exists - see `UpdateCheck` for the policy, and
/// `READMES/22-UPDATE-SYSTEM.md` for the whole system.
///
/// The policy in one line: a **patch** release is found but never announced,
/// a **minor** release is announced, and a **major** release is announced
/// with "read the repository first" as the first thing on offer. Every
/// release ships an `info.txt`, which is fetched and shown here, because
/// "what changed" is the thing that decides whether to bother.
@MainActor
enum UpdatePrompt {
    private static let stateKey = "update.state"

    static var currentVersion: UpdateCheck.Version {
        // `MSLVersion.marketing` as the fallback, not a number typed here:
        // an unreadable Info.plist used to make MSL believe it was 1.0.0 and
        // offer an "update" to the release it was already running. The two
        // are the same number by construction, so there is nothing to drift.
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return UpdateCheck.Version(text ?? "") ?? UpdateCheck.Version(MSLVersion.marketing)!
    }

    static func loadState() -> UpdateCheck.State {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(UpdateCheck.State.self, from: data) else { return .init() }
        return state
    }

    static func save(_ state: UpdateCheck.State) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    /// The quiet launch check: throttled, and silent unless the release is
    /// one worth interrupting someone for - which a patch release is not.
    static func checkAtLaunch() {
        guard ProcessInfo.processInfo.environment["MSL_NO_UPDATE_CHECK"] == nil else { return }
        Task {
            // Let the first window settle before any alert can appear.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let (decision, state) = await UpdateCheck.run(current: currentVersion, state: loadState())
            save(state)
            guard let decision, decision.announces else { return }
            await show(decision)
        }
    }

    /// "Check for Updates…": always checks, always answers, and ignores the
    /// silence, the skipped version and the "patches are not announced" rule
    /// - asking is asking, and a fix you came looking for is a fix you get.
    static func checkNow() {
        Task {
            var probe = loadState()
            probe.lastCheck = nil
            probe.backoffUntil = nil
            probe.skippedTag = nil
            probe.silenced = false
            let (decision, fetched) = await UpdateCheck.run(current: currentVersion, state: probe)
            // Keep the person's own choices; only the timing is updated.
            var kept = loadState()
            kept.lastCheck = fetched.lastCheck
            kept.backoffCount = fetched.backoffCount
            kept.backoffUntil = fetched.backoffUntil
            save(kept)
            switch decision?.kind {
            case .update?:
                await show(decision!)
            case .upToDate?:
                inform("MSL is up to date", """
                    You have MSL \(currentVersion), and it is the newest release. \
                    Every release is listed on the releases page.
                    """)
            default:
                inform("Couldn't check for updates",
                       "GitHub couldn't be reached. Check your connection and try again later.")
            }
        }
    }

    private static func show(_ decision: UpdateCheck.Decision) async {
        guard let release = decision.release else { return }
        let info = await UpdateCheck.fetchInfo(for: release.tag)
        present(release: release, bump: decision.bump ?? .patch, info: info)
    }

    /// What the alert's buttons can do. Named rather than counted, because
    /// the order changes with the kind of release and a button mapped by
    /// position alone is how "Later" becomes "Skip This Version".
    private enum Choice {
        case download, openRelease, openRepository, later, skip
    }

    private static func present(release: UpdateCheck.Release, bump: UpdateCheck.Bump, info: String?) {
        let alert = NSAlert()
        let version = release.version.description

        switch bump {
        case .major:
            alert.messageText = "MSL \(version) is a new major version"
            alert.informativeText = """
                You have MSL \(currentVersion). A major version is where MSL itself changes, so read \
                what changed on the repository before you take it. Your instances and settings are kept.
                """
        case .minor:
            alert.messageText = "MSL \(version) is available"
            alert.informativeText = """
                You have MSL \(currentVersion). This release adds to MSL. It can be downloaded to your \
                Downloads and offered to replace this copy; nothing is removed until it has the new one \
                and asks again. Your instances and settings are kept either way.
                """
        case .patch:
            alert.messageText = "MSL \(version) is available"
            alert.informativeText = """
                You have MSL \(currentVersion). This release is a fix - MSL doesn't raise these on its \
                own, so you are seeing it because you asked. Your instances and settings are kept.
                """
        }

        if let info {
            let trimmed = info.count > 900 ? String(info.prefix(900)) + "\n…" : info
            alert.informativeText += "\n\nWhat's in \(release.tag) (info.txt):\n\(trimmed)"
        } else {
            alert.informativeText += "\n\nThe release page has an info.txt worth reading before you update."
        }

        // For a minor or a patch, "Download and Update" comes first, because
        // it is what almost everyone wants and doing it by hand is four
        // steps. It is still only a *download* until a second alert asks
        // again - nothing is removed on this click (`UpdateRunner`).
        //
        // For a major release the repository comes first instead. That is the
        // whole difference a major version makes here: the recommended thing
        // to do is go and read, not go and install.
        let buttons: [(title: String, choice: Choice)] = bump.readTheRepositoryFirst
            ? [("Open the Repository", .openRepository),
               ("Download and Update…", .download),
               ("Later", .later),
               ("Skip This Version", .skip)]
            : [("Download and Update…", .download),
               ("Open the Release Page", .openRelease),
               ("Later", .later),
               ("Skip This Version", .skip)]
        for button in buttons { alert.addButton(withTitle: button.title) }

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Stop telling me about updates"
        alert.suppressionButton?.state = loadState().silenced ? .on : .off

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        var state = loadState()
        if alert.suppressionButton?.state == .on { state.silenced = true }

        // Saved before anything else happens: an update that quits the app
        // must not lose the suppression choice made in the same alert.
        save(state)

        // Mapped by index into the list that was actually built, and bounds
        // checked: a response that is not one of these buttons - a dismissed
        // alert, something new - must do nothing at all, never fall through
        // to "never tell me about this version again".
        let index = Int(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        guard buttons.indices.contains(index) else { return }
        switch buttons[index].choice {
        case .download:
            UpdateRunner.run(release)
        case .openRelease:
            NSWorkspace.shared.open(release.page)
        case .openRepository:
            NSWorkspace.shared.open(UpdateCheck.repositoryPage)
        case .later:
            break
        case .skip:
            state.skippedTag = release.tag
            save(state)
        }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if loadState().silenced {
            alert.informativeText += "\n\nUpdate notices are silenced; use Check for Updates… when you want one."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
