import AppKit
import MSLCore
import SwiftUI

/// Carrying out an update the person has agreed to.
///
/// `UpdatePrompt` decides and asks; this does. Kept separate because the
/// asking is an `NSAlert` and the doing needs a progress bar, a cancel, and
/// three different ways to stop safely.
///
/// It downloads and verifies, and then points at the file. Installing is the
/// package's job: it closes the instances and replaces MSL in place, the same
/// as any other install.
@MainActor
enum UpdateRunner {

    /// Downloads `release`, then offers to replace this copy of MSL.
    static func run(_ release: UpdateCheck.Release) {
        let version = release.version.description
        let cancellation = DistroInstaller.InstallCancellation()
        let window = ProgressWindow(title: "Updating MSL",
                                    status: "Looking for MSL \(version)…") {
            cancellation.cancel()
        }
        window.show()

        Task.detached(priority: .userInitiated) {
            let result = Result {
                try UpdateDownload.fetch(release, transfer: { progress in
                    Task { @MainActor in window.update(transfer: progress) }
                }, cancellation: cancellation, log: { line in
                    Task { @MainActor in window.update(status: line) }
                })
            }
            await MainActor.run {
                window.close()
                switch result {
                case .success(let fetched): offerToReveal(release, fetched: fetched)
                case .failure(let error): reportDownloadFailure(error, release: release)
                }
            }
        }
    }

    // MARK: - After the download

    private static func reportDownloadFailure(_ error: Error, release: UpdateCheck.Release) {
        if let failure = error as? UpdateDownload.Failure, failure == .cancelled { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MSL \(release.version) wasn't downloaded"
        alert.informativeText = """
            \(error.localizedDescription)

            Nothing on this Mac was changed. You can download \(release.tag) by hand from its \
            release page instead.
            """
        alert.addButton(withTitle: "Open the Release Page")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.page)
        }
    }

    /// The package is downloaded and verified. MSL's job ends here: the
    /// installer package itself closes the running instances and replaces
    /// MSL, which is what it has always done for an ordinary install.
    ///
    /// MSL used to try to do that part itself - quitting both apps,
    /// hibernating every instance and running the uninstaller from a script
    /// in Terminal. All of it was work the package already does, with more
    /// ways to go wrong and a window in which someone had no MSL at all.
    private static func offerToReveal(_ release: UpdateCheck.Release,
                                      fetched: UpdateDownload.Fetched) {
        let alert = NSAlert()
        alert.messageText = "MSL \(release.version) is in your Downloads"
        let how = fetched.verification == .checksum
            ? "It matches the checksum the release publishes."
            : "It says it is MSL \(release.version), and it is a real MSL installer."
        alert.informativeText = """
            \(fetched.url.path)

            \(how)

            Open it when you're ready. It saves and closes your instances, replaces MSL, and \
            leaves your Linux exactly where it is - every instance, image and setting.
            """
        alert.addButton(withTitle: "Show Me the File")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([fetched.url])
        }
    }
}

/// A small window around `InstallProgressView`.
///
/// The real view, not a second one built for this: the distro download's bar
/// already learned that `ProgressView(value:)` cannot be rendered offscreen
/// and that a rate that appears and disappears reads as jitter, and a
/// parallel copy here would relearn both.
@MainActor
final class ProgressWindow {
    private let window: NSWindow
    private let model = Model()
    private let onCancel: (() -> Void)?

    final class Model: ObservableObject {
        @Published var status = ""
        @Published var transfer: DistroInstaller.TransferProgress?
    }

    private struct Body: View {
        @ObservedObject var model: Model
        var onCancel: (() -> Void)?
        var body: some View {
            InstallProgressView(status: model.status, transfer: model.transfer, onCancel: onCancel)
                .padding(Design.Spacing.large)
                .frame(width: 460)
        }
    }

    init(title: String, status: String, onCancel: (() -> Void)?) {
        self.onCancel = onCancel
        model.status = status
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Body(model: model, onCancel: onCancel))
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(status: String) {
        model.status = status
        model.transfer = nil
    }

    func update(transfer: DistroInstaller.TransferProgress) {
        model.transfer = transfer
    }

    func close() { window.orderOut(nil) }
}
