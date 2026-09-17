// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// The handful of on-disk locations MSL's *host* side agrees on.
///
/// These used to be spelled out inline wherever they were needed (`mslhd`'s
/// `main.swift`, `DaemonProtocol.defaultSocketPath()`, `X11AppRouter`'s
/// shim directory). That was fine while every one of those lived inside
/// this repository and could be rebuilt together. Generated `.app` bundles
/// break that assumption: a bundle sitting in `~/Applications` has to find
/// `msl` months later, from a process this repository didn't launch, after
/// `.build/` has been wiped and rebuilt any number of times. So there is
/// now one stable, versionless install prefix that bundles can hard-code,
/// and `HostToolInstaller` keeps it populated.
public enum MSLPaths {
    public static var appSupport: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MSL")
    }

    /// Where the host-side executables (`msl`, `mslhd`, `mslgui`,
    /// `msl-applauncher`) are installed for everything outside this
    /// repository to find. Already holds the *guest*-side helpers
    /// (`x11tunnel`, `fileopsd`, `shellinit`), which is why this is the
    /// natural home for the host ones too.
    public static var binDirectory: URL { appSupport.appendingPathComponent("bin") }

    public static func tool(_ name: String) -> URL { binDirectory.appendingPathComponent(name) }

    /// Generated `.app` bundles, one subdirectory per instance.
    ///
    /// Per *instance*, not one flat directory: two instances can both have
    /// Krita installed, and `~/Applications/MSL/Krita.app` is a single path
    /// that only one of them could own. `~/Applications` (not
    /// `/Applications`) so no administrator authentication is ever needed
    /// to add or remove an app - and it is indexed by Spotlight and
    /// LaunchServices exactly the same way, verified directly.
    public static var generatedAppsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Applications/MSL")
    }

    public static func generatedAppsDirectory(instance: String) -> URL {
        generatedAppsDirectory.appendingPathComponent(instance)
    }

    /// Cached `.desktop` scan results and icons, per instance, so the app
    /// list can be shown without booting a VM to re-scan every time.
    public static func appCatalogDirectory(instance: String) -> URL {
        appSupport.appendingPathComponent("AppCatalog/\(instance)")
    }

    /// A generated bundle is `LSUIElement` and has no terminal, so a failed
    /// launch has nowhere at all to report itself - the user would
    /// double-click and get silence. Everything it does goes here instead,
    /// and the app surfaces the tail of it.
    public static var logsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MSL")
    }

    public static var launchAgentPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    public static let launchAgentLabel = "com.msl.mslhd"

    @discardableResult
    public static func ensureDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }
}
