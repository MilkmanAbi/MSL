import Foundation

/// Finds MSL's bundled artwork, without ever trapping.
///
/// SwiftPM's generated `Bundle.module` is not usable in a shipped build. It
/// looks in exactly two places - `Bundle.main.bundleURL/MSL_<Target>.bundle`
/// and an **absolute path into this machine's `.build` directory** baked in
/// at compile time - and calls `fatalError` when it finds neither. On the
/// machine that compiled it that second path exists, so everything looks
/// fine; on any other machine, or after a `rm -rf .build`, the first use of
/// `Bundle.module` kills the process. Verified by hiding the build bundle
/// and launching `dist/MSL.app`: it died on launch.
///
/// So this searches, by hand, the places a resource can actually be, and
/// returns `nil` instead of trapping when it is genuinely absent - a missing
/// image should leave a gap in the About window, not take the app down.
public enum MSLAsset {
    /// Ordered by how much we trust the location, most-shipped first.
    public static func url(_ name: String, extension fileExtension: String) -> URL? {
        let file = "\(name).\(fileExtension)"
        var candidates: [URL] = []

        // 1. A real app bundle's Contents/Resources - what `build-app.sh`
        //    populates, and the only location that survives being copied to
        //    another Mac.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(file))
        }

        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            // 2. A helper tool living in Contents/MacOS, reaching sideways
            //    into Contents/Resources.
            candidates.append(executable.deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(file))
            // 3. Straight beside the binary - how an installed CLI tool
            //    carries its own copy.
            candidates.append(executable.appendingPathComponent(file))
            // 4. The SwiftPM resource bundles, as they sit in `.build`
            //    during development and under `swift test`.
            for target in ["MSL_MSLApp.bundle", "MSL_MSLCore.bundle"] {
                candidates.append(contentsOf: insideBundle(executable.appendingPathComponent(target), file))
            }
        }

        // 5. Same bundles, but beside the *app* rather than the executable,
        //    which is where `Bundle.module` itself would have looked.
        for target in ["MSL_MSLApp.bundle", "MSL_MSLCore.bundle"] {
            candidates.append(contentsOf: insideBundle(Bundle.main.bundleURL.appendingPathComponent(target), file))
        }

        // 6. Relative to whatever bundle this code was actually loaded from,
        //    which is not `Bundle.main` whenever MSLCore is hosted by
        //    something else. Under `swift test` that host is the xctest
        //    runner, so every candidate above looks beside a binary in
        //    Xcode's toolchain and finds nothing.
        let own = Bundle(for: BundleToken.self)
        if let resources = own.resourceURL {
            candidates.append(resources.appendingPathComponent(file))
            // The Xcode build system nests the resource bundle *inside* the
            // test bundle's own Resources, rather than beside it.
            for target in ["MSL_MSLCore.bundle", "MSL_MSLApp.bundle"] {
                candidates.append(contentsOf: insideBundle(resources.appendingPathComponent(target), file))
            }
        }
        let alongside = own.bundleURL.deletingLastPathComponent()
        for target in ["MSL_MSLCore.bundle", "MSL_MSLApp.bundle"] {
            candidates.append(contentsOf: insideBundle(alongside.appendingPathComponent(target), file))
        }

        // 7. The installed MSL.app, for code running outside any bundle: the
        //    per-app Dock hosts are bare copies of `mslgui` in
        //    ~/Library/Caches/MSL/AppShims, where none of the above exists -
        //    so their placeholder icon was nil and the Dock showed macOS's
        //    generic "exec" file icon instead.
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            candidates.append(URL(fileURLWithPath: root)
                .appendingPathComponent("MSL.app/Contents/Resources").appendingPathComponent(file))
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Both shapes a resource bundle comes in. SwiftPM's own build put
    /// resources flat at the top of `MSL_MSLCore.bundle`; the Xcode build
    /// system that SwiftPM switched to (seen on macOS 27, 2026-09-21) writes
    /// a real macOS bundle with `Contents/Resources` inside. Looking for only
    /// one of them means the melon silently disappears, which is exactly the
    /// failure this whole file exists to prevent.
    private static func insideBundle(_ bundle: URL, _ file: String) -> [URL] {
        [bundle.appendingPathComponent(file),
         bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(file)]
    }
}

/// Only exists so `Bundle(for:)` can name the bundle MSLCore was loaded
/// from. It needs to be a class - `Bundle(for:)` takes an `AnyClass`.
private final class BundleToken {
}
