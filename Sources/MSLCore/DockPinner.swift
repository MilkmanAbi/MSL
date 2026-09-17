import Foundation

/// Adds and removes items in the user's Dock.
///
/// There is no public API for this. The Dock's persistent items live in
/// `com.apple.dock`'s `persistent-apps` array, and the Dock only re-reads
/// them when it restarts - so the shape of this is: read the array, change
/// it, write it back, restart the Dock. That is a user-visible restart (the
/// Dock blinks), so nothing here happens without the user asking for it.
///
/// Written through `CFPreferences` rather than the `defaults` tool.
/// `defaults` can *append* a plist fragment (`-array-add`) but cannot
/// replace one key of a domain - `defaults import` takes a whole domain,
/// and there is no per-key form, so removing a single tile that way
/// silently failed. Going through CFPreferences also means the entries are
/// built as real dictionaries instead of hand-written XML, which removes
/// the need to escape app names that contain `&` or a quote.
public enum DockPinner {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    /// Whether a bundle at `url` is already pinned.
    public static func isPinned(_ url: URL) -> Bool {
        pinnedPaths().contains(standardized(url))
    }

    public static func pinnedPaths() -> Set<String> {
        Set(entries().compactMap(path(of:)))
    }

    /// Drops CoreFoundation's cached copy of the Dock's preferences.
    ///
    /// `CFPreferences` caches per process and per domain. Without this, a
    /// long-lived process that pinned something would keep reading the
    /// pre-change value back, and the UI's "Pin"/"Unpin" label would stay
    /// wrong until the app was relaunched.
    public static func invalidateCache() {
        CFPreferencesAppSynchronize(domain)
    }

    @discardableResult
    public static func pin(_ url: URL) -> Bool {
        apply(url, pinned: true)
    }

    @discardableResult
    public static func unpin(_ url: URL) -> Bool {
        apply(url, pinned: false)
    }

    /// Brings the Dock to the requested state for `url`.
    ///
    /// **Exactly one Dock restart per call.** There is no API to add a tile
    /// without restarting the Dock, and on current macOS the Dock also
    /// draws the desktop - so every restart visibly blinks the Dock *and*
    /// the wallpaper. An earlier version verified its write and retried up
    /// to three times, which meant up to three restarts for one click and
    /// looked like the machine glitching. One user-initiated action gets
    /// one restart, and a write that doesn't take is reported, not retried.
    private static func apply(_ url: URL, pinned: Bool) -> Bool {
        let target = standardized(url)
        let current = entries()
        let isPresent = current.contains { path(of: $0) == target }
        // Already in the requested state: nothing to write, and - more to
        // the point - no reason to restart the Dock.
        if isPresent == pinned { return true }

        var updated = current
        if pinned {
            updated.append(entry(for: url))
        } else {
            updated.removeAll { path(of: $0) == target }
        }
        return write(updated)
    }

    /// One `persistent-apps` entry.
    ///
    /// `file-label` matters: the Dock writes one for every tile it manages
    /// itself, and a tile without one can come back unlabelled (or be
    /// dropped) the next time the Dock rewrites its own preferences.
    private static func entry(for url: URL) -> [String: Any] {
        [
            "tile-data": [
                "file-data": [
                    "_CFURLString": url.standardizedFileURL.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": url.deletingPathExtension().lastPathComponent,
                "dock-extra": false,
            ],
            "tile-type": "file-tile",
        ]
    }

    // MARK: - Reading and writing the array

    private static func entries() -> [[String: Any]] {
        invalidateCache()
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    private static func write(_ entries: [[String: Any]]) -> Bool {
        CFPreferencesSetAppValue(key, entries as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        restartDock()
        // Brief settle so that a read immediately after this call sees the
        // change - the UI re-reads to update a button label the moment
        // this returns.
        Thread.sleep(forTimeInterval: 0.4)
        invalidateCache()
        return true
    }

    /// The bundle path an entry points at, if it points at one.
    private static func path(of entry: [String: Any]) -> String? {
        guard let tile = entry["tile-data"] as? [String: Any],
              let fileData = tile["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String else { return nil }
        // The Dock stores these as `file:///...` URLs, with a trailing
        // slash for a bundle; normalise before comparing.
        return standardized(URL(string: string) ?? URL(fileURLWithPath: string))
    }

    private static func standardized(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Restarts the Dock so it picks up the changed array. launchd brings
    /// it straight back.
    ///
    /// `SIGKILL`, not the default `SIGTERM`: a Dock asked politely to quit
    /// syncs its own preferences on the way out, and that write can land
    /// *after* ours and restore the array we just changed. That was the
    /// actual cause of a pin appearing to succeed while changing nothing -
    /// not a timing problem to be slept around. Killed outright, it has no
    /// opportunity to write anything back. The Dock keeps no unsaved state
    /// that matters; this is how it is restarted everywhere.
    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-KILL", "Dock"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
