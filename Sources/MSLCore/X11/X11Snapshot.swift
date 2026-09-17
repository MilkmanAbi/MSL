import AppKit

/// Opt-in host-side bitmap dumping, built for the Layer-0 X11 conformance
/// test harness: a test program draws known content into a window, and
/// instead of screenshotting the actual macOS display (compositing noise,
/// window-manager chrome, timing flakiness) the harness can diff the
/// *exact* bytes `mslgd` rendered into that window's backing
/// `CGContext` (`X11CanvasView.bitmapContext`) against a reference PNG.
///
/// Off by default (an unset `MSL_X11_SNAPSHOT_DIR` short-circuits before
/// touching the filesystem); set it to a directory and `<dir>/<windowID>.png`
/// tracks that window's current content. The harness polls for the file
/// settling (unchanged for N ms) rather than the server signaling "done
/// painting" - there's no such signal in X11 itself, real clients don't
/// send one either.
///
/// COALESCED, and that is not an optimization - it is what makes this
/// usable against a real application at all. `notifyChanged()` fires once
/// per drawing request, and this used to synchronously `makeImage()` +
/// PNG-encode + write the WHOLE window on every one of them, on whatever
/// thread asked (the main thread, for the `PutImage` path). Confirmed live
/// 2026-09-06 with `gtk4-widget-factory`: a 1329x772 window plus GTK4's
/// animated spinner is a full-window PNG encode several times a second, and
/// `sample` showed the main thread 100% inside
/// `PNGWritePlugin::writeAll` -> `deflate` with every frame. The main
/// queue never got back to its run loop, so the server stopped servicing
/// input, stopped drawing, and never drained an autorelease pool - it
/// climbed to a **38.7 GB** physical footprint and the guest client
/// eventually died with "shell connection closed unexpectedly". None of
/// that is visible from the test pyramid, whose fixtures paint a handful
/// of times and exit.
///
/// So: `dump` only records that a window is dirty and (at most one
/// outstanding at a time) schedules a flush. The flush snapshots each dirty
/// context on the main thread - `makeImage()` is a cheap COW-style
/// reference to the bitmap, unlike encoding it - and hands the images to a
/// background queue to encode and write. A burst of 200 paints becomes one
/// encode, off the main thread.
enum X11Snapshot {
    static let directory: String? = {
        guard let dir = ProcessInfo.processInfo.environment["MSL_X11_SNAPSHOT_DIR"], !dir.isEmpty else { return nil }
        return dir
    }()

    /// How long to let paints accumulate before writing. Must stay well
    /// under `Scripts/x11-test.sh`'s settle loop (15 polls at 150ms, run
    /// only AFTER the guest test process has already exited, so the main
    /// queue is idle and the flush is not competing with anything).
    private static let coalesceInterval: DispatchTimeInterval = .milliseconds(100)

    private static let writeQueue = DispatchQueue(label: "msl.x11.snapshot.write", qos: .utility)
    private static let lock = NSLock()
    private static var dirty: [UInt32: CGContext] = [:]
    private static var flushScheduled = false

    static func dump(windowID: UInt32, context: CGContext) {
        guard directory != nil else { return }
        lock.lock()
        dirty[windowID] = context
        let scheduleNow = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard scheduleNow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval) { flush() }
    }

    /// Main thread: `bitmapContext` is drawn into from the connection
    /// threads as well, so this is no more (and no less) synchronized than
    /// the direct call it replaced - but it now happens once per burst
    /// rather than once per drawing request.
    private static func flush() {
        lock.lock()
        let work = dirty
        dirty.removeAll()
        flushScheduled = false
        lock.unlock()
        guard let directory, !work.isEmpty else { return }
        var images: [(UInt32, CGImage)] = []
        images.reserveCapacity(work.count)
        for (windowID, context) in work {
            if let image = context.makeImage() { images.append((windowID, image)) }
        }
        guard !images.isEmpty else { return }
        writeQueue.async {
            for (windowID, image) in images { write(image, windowID: windowID, directory: directory) }
        }
    }

    private static func write(_ image: CGImage, windowID: UInt32, directory: String) {
        // Explicit pool: `NSBitmapImageRep`/`Data` here are large (megabytes
        // per full-window frame) and autoreleased. Draining per write keeps
        // a burst from stacking them up the way the uncoalesced version did.
        autoreleasepool {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let path = (directory as NSString).appendingPathComponent("\(windowID).png")
            // Atomic write: the harness polls this exact path for size/mtime
            // settling, so a reader must never observe a half-written file.
            let tmpPath = path + ".tmp"
            do {
                try data.write(to: URL(fileURLWithPath: tmpPath))
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmpPath))
            } catch {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        }
    }
}
