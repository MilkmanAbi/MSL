import AppKit
import MSLCore

/// Tells someone a new MSL exists - see `UpdateCheck` for which releases
/// reach which installs, and `READMES/22-UPDATE-SYSTEM.md` for the whole
/// system.
///
/// It never installs anything: "Get MSL x" opens that release's page, and the
/// install stays the person's own step. Every release ships an `info.txt`,
/// which is fetched and shown in the alert, because "what changed" is the
/// thing that decides whether to bother.
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

    /// The quiet launch check: throttled, and silent unless there is
    /// something this install can actually be offered.
    static func checkAtLaunch() {
        guard ProcessInfo.processInfo.environment["MSL_NO_UPDATE_CHECK"] == nil else { return }
        Task {
            // Let the first window settle before any alert can appear.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let (decision, state) = await UpdateCheck.run(current: currentVersion, state: loadState())
            save(state)
            guard let decision, decision.shouldPrompt else { return }
            await show(decision)
        }
    }

    /// "Check for Updates…": always checks, always answers, and ignores both
    /// the silence and the skipped version - asking is asking.
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
            case .update?, .advisory?:
                await show(decision!)
            case .upToDate?, .suppressed?:
                inform("MSL is up to date", """
                    You have MSL \(currentVersion), and nothing newer applies to it. \
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
        present(decision, release: release, info: info)
    }

    private static func present(_ decision: UpdateCheck.Decision, release: UpdateCheck.Release, info: String?) {
        let alert = NSAlert()
        let version = release.version.description

        if decision.kind == .advisory {
            // Nothing to install: this release needs a newer MSL than this one.
            alert.messageText = "MSL \(version) fixes unsafe behaviour - but needs a newer MSL"
            alert.informativeText = """
                You have MSL \(currentVersion). This fix applies to MSL \
                \(release.minimum.map(\.description) ?? version) and newer, so it cannot be installed here. \
                Updating to a current MSL first is the way to get it.
                """
        } else if decision.urgent {
            alert.messageText = "Important: MSL \(version) patches unsafe behaviour"
            alert.informativeText = """
                You have MSL \(currentVersion). This release fixes behaviour that can harm your \
                instances or your data, so it is worth taking now. Your instances and settings are kept.
                """
        } else {
            alert.messageText = "MSL \(version) is available"
            alert.informativeText = """
                You have MSL \(currentVersion). MSL can download it to your Downloads and offer \
                to replace this copy; nothing is removed until it has the new one and asks again. \
                Your instances and settings are kept either way.
                """
        }

        if let info {
            let trimmed = info.count > 900 ? String(info.prefix(900)) + "\n…" : info
            alert.informativeText += "\n\nWhat's in \(release.tag) (info.txt):\n\(trimmed)"
        } else {
            alert.informativeText += "\n\nThe release page has an info.txt worth reading before you update."
        }
        if !decision.alsoAvailable.isEmpty {
            let list = decision.alsoAvailable.prefix(3).map { "\($0.version) (\($0.marker.label))" }.joined(separator: ", ")
            alert.informativeText += "\n\nAlso released, but for newer MSL than yours: \(list)."
        }

        // "Download and Update" first, because it is what almost everyone
        // wants and because doing it by hand is four steps. It is still only
        // a *download* until a second alert asks again - nothing is removed
        // on this click (`UpdateRunner`).
        if decision.kind == .advisory {
            alert.addButton(withTitle: "See the Releases")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Download and Update…")
            alert.addButton(withTitle: "Open the Release Page")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
        }

        // The silence switch. An unsafe-behaviour patch deliberately ignores
        // it later, and the wording says so rather than surprising anyone.
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Stop telling me about updates (except unsafe-behaviour patches)"
        alert.suppressionButton?.state = loadState().silenced ? .on : .off

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        var state = loadState()
        if alert.suppressionButton?.state == .on { state.silenced = true }

        // Saved before anything else happens: an update that quits the app
        // must not lose the suppression choice made in the same alert.
        save(state)
        if decision.kind == .advisory {
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
            return
        }
        switch response {
        case .alertFirstButtonReturn:
            UpdateRunner.run(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.page)
        case .alertThirdButtonReturn:
            break   // Later.
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            // Skip This Version. Matched explicitly rather than by `default`:
            // `default` would have treated *any* other response - a dismissed
            // alert, a future button - as "never tell me about this version
            // again", which is the one outcome nobody would have chosen.
            state.skippedTag = release.tag
            save(state)
        default:
            break
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
