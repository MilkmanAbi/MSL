import AppKit
import MSLCore
import SwiftUI

// One executable, two applications. `MSL.app` and `MSL Files.app` carry the
// same binary; which app it becomes is decided by the bundle it was launched
// from (see `MSLFilesIdentity`). Keeps MSL Files in this codebase, sharing
// every model and view, while it installs and runs as an app of its own.
// A launch that exists only to put the crash screen up, spawned by whatever
// fell over. Handled before anything else: this process is standing in for
// one that is already dying, and should not start a second copy of MSL.
if CrashScreenPresenter.isCrashLaunch {
    let application = NSApplication.shared
    let delegate = CrashScreenDelegate()
    application.delegate = delegate
    application.run()
    exit(0)
}

// Catch the unrecoverable ones, and show the screen rather than vanishing.
// The handler re-raises afterwards, so macOS still writes its crash report -
// which is the thing that actually gets a crash like this fixed.
CrashScreen.install(for: .app, viewer: Bundle.main.executablePath)

if MSLFilesIdentity.isRunningAsFilesApp {
    MSLFilesApp.main()
} else {
    MSLApp.main()
}

// Femboy supremacy
