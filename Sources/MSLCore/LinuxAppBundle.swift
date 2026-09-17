import AppKit
import Foundation

/// Turns a Linux `.desktop` entry into a real macOS application bundle in
/// `~/Applications/MSL/<instance>/`.
///
/// This is what "show Linux apps in the Applications folder, with the
/// option to add them to Launchpad or pin them to the Dock" actually
/// requires. Three things were verified directly before this was written,
/// rather than assumed:
///
/// - A hand-built, **ad-hoc-signed** bundle in `~/Applications` is indexed
///   by Spotlight and registered with LaunchServices with no `lsregister`
///   call of any kind. `open <path>` and `open -a <name>` both work.
/// - **Launchpad no longer exists** on this macOS (26.x) - there is no
///   `Launchpad.app` to add anything to. Its replacement is the
///   Applications view in Spotlight, which is fed by exactly that
///   LaunchServices registration. So generating the bundle *is* "adding it
///   to Launchpad"; there is nothing further to do.
/// - Pinning to the Dock is still `com.apple.dock`'s `persistent-apps`
///   array plus a Dock restart; there is no public API. See
///   `DockPinner`.
public enum LinuxAppBundle {
    public struct Descriptor {
        public let instance: String
        public let distro: GuestDistro
        /// The `.desktop` `Name=` - what the user sees.
        public let displayName: String
        /// The `.desktop` `Exec=`, field codes already stripped.
        public let command: String
        /// Icon pixels pulled out of the guest, if any were found.
        public let icon: NSImage?

        public init(instance: String, distro: GuestDistro, displayName: String, command: String, icon: NSImage?) {
            self.instance = instance
            self.distro = distro
            self.displayName = displayName
            self.command = command
            self.icon = icon
        }
    }

    public enum BundleError: Error, CustomStringConvertible {
        case noLauncherBinary(String)
        case signingFailed(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .noLauncherBinary(let path): return "the app launcher isn't installed at \(path) - open MSL once to install it"
            case .signingFailed(let reason): return "couldn't sign the generated app: \(reason)"
            case .writeFailed(let reason): return "couldn't write the generated app: \(reason)"
            }
        }
    }

    /// Where `descriptor`'s bundle lives, whether or not it exists yet.
    public static func bundleURL(for descriptor: Descriptor) -> URL {
        MSLPaths.generatedAppsDirectory(instance: descriptor.instance)
            .appendingPathComponent(fileSafeName(descriptor.displayName) + ".app")
    }

    public static func exists(_ descriptor: Descriptor) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL(for: descriptor).path)
    }

    /// Writes (or rewrites) the bundle and returns its URL.
    @discardableResult
    public static func generate(_ descriptor: Descriptor) throws -> URL {
        let launcher = MSLPaths.tool("msl-applauncher")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw BundleError.noLauncherBinary(launcher.path)
        }

        let bundle = bundleURL(for: descriptor)

        // Build into a sibling directory and swap it in, so a failure
        // halfway through never leaves a half-written bundle that
        // LaunchServices has already noticed.
        let staging = bundle.deletingLastPathComponent()
            .appendingPathComponent(".\(bundle.lastPathComponent).staging")
        try? FileManager.default.removeItem(at: staging)

        let stagedMacOS = staging.appendingPathComponent("Contents/MacOS")
        let stagedResources = staging.appendingPathComponent("Contents/Resources")

        do {
            for directory in [stagedMacOS, stagedResources] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            // The executable's filename is what macOS shows in some
            // contexts before the bundle's own name is consulted, so name
            // it after the app rather than leaving it "msl-applauncher".
            let executableName = fileSafeName(descriptor.displayName)
            try FileManager.default.copyItem(at: launcher, to: stagedMacOS.appendingPathComponent(executableName))

            // The app's own artwork first - a GIMP tile should be GIMP's
            // icon, which is the whole point of giving each Linux app its
            // own process. Only when the app ships nothing usable does MSL
            // put its own melon there: "an MSL app" is a truer thing for the
            // Dock to say than the blank generic page macOS falls back to.
            let iconDestination = stagedResources.appendingPathComponent("icon.icns")
            var hasIcon = false
            if let icon = descriptor.icon, writeICNS(icon, to: iconDestination) {
                hasIcon = true
            } else if let melon = melonIcon, writeICNS(melon, to: iconDestination) {
                hasIcon = true
            }

            let plist = infoPlist(for: descriptor, executableName: executableName, hasIcon: hasIcon)
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: staging.appendingPathComponent("Contents/Info.plist"))

            // Signing has to happen on the finished bundle: the signature
            // covers the Info.plist and resources, not just the Mach-O.
            if let error = HostToolInstaller.adhocSign(staging, deep: true) {
                throw BundleError.signingFailed(error)
            }

            try? FileManager.default.removeItem(at: bundle)
            try FileManager.default.moveItem(at: staging, to: bundle)
        } catch let error as BundleError {
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BundleError.writeFailed("\(error)")
        }

        return bundle
    }

    public static func remove(_ descriptor: Descriptor) throws {
        let bundle = bundleURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: bundle.path) else { return }
        try FileManager.default.removeItem(at: bundle)
    }

    /// Deletes every generated bundle for `instance` - called when the
    /// instance itself is removed, so no bundle is left pointing at
    /// something that no longer exists.
    public static func removeAll(instance: String) throws {
        let directory = MSLPaths.generatedAppsDirectory(instance: instance)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Every generated bundle for `instance`, by app name.
    public static func installedApps(instance: String) -> Set<String> {
        let directory = MSLPaths.generatedAppsDirectory(instance: instance)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) })
    }

    // MARK: - Keeping bundles current

    /// Brings every generated bundle's launcher up to date with the installed
    /// `msl-applauncher`, returning how many were refreshed.
    ///
    /// A bundle embeds a *copy* of the launcher from the day it was made, and
    /// nothing replaced it afterwards - so no launcher fix ever reached an app
    /// the user had already added. Found 2026-09-14 while fixing a hang in the
    /// launcher: every re-test kept running the old copy inside the bundle.
    /// MSL calls this at every launch, after installing its tools.
    ///
    /// Only bundles MSL made (they carry `MSLInstance`) are touched; the old
    /// executable is removed rather than overwritten, so a running app keeps
    /// its image; and a bundle already matching byte-for-byte is left alone,
    /// signature included.
    @discardableResult
    public static func refreshLaunchers(
        in root: URL = MSLPaths.generatedAppsDirectory,
        launcher: URL = MSLPaths.tool("msl-applauncher"),
        sign: (URL) -> String? = { HostToolInstaller.adhocSign($0, deep: true) }
    ) -> Int {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: launcher.path),
              let instances = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return 0 }

        var refreshed = 0
        for instanceDirectory in instances {
            guard let bundles = try? fileManager.contentsOfDirectory(at: instanceDirectory, includingPropertiesForKeys: nil) else { continue }
            for bundle in bundles where bundle.pathExtension == "app" {
                let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      plist["MSLInstance"] != nil,
                      let executableName = plist["CFBundleExecutable"] as? String
                else { continue }
                let executable = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
                if fileManager.contentsEqual(atPath: executable.path, andPath: launcher.path) { continue }
                do {
                    try? fileManager.removeItem(at: executable)
                    try fileManager.copyItem(at: launcher, to: executable)
                } catch {
                    continue
                }
                if sign(bundle) == nil { refreshed += 1 }
            }
        }
        return refreshed
    }

    // MARK: - Info.plist

    private static func infoPlist(for descriptor: Descriptor, executableName: String, hasIcon: Bool) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleName": descriptor.displayName,
            "CFBundleDisplayName": descriptor.displayName,
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier(for: descriptor),
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "13.0",
            // Without this the launcher - which stays alive for the whole
            // life of the Linux app, because it *is* the session that keeps
            // the VM awake - would show its own Dock tile alongside the
            // per-app tile the X11 side already creates. Two tiles for one
            // app is worse than none.
            "LSUIElement": true,
            // What this bundle is for, read back by `msl-applauncher` from
            // its own bundle at launch. Namespaced so they can never
            // collide with a system key.
            "MSLInstance": descriptor.instance,
            "MSLDistro": descriptor.distro.rawValue,
            "MSLExec": descriptor.command,
            "MSLAppName": descriptor.displayName,
        ]
        if hasIcon { plist["CFBundleIconFile"] = "icon" }
        return plist
    }

    private static func bundleIdentifier(for descriptor: Descriptor) -> String {
        let slug = descriptor.displayName.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return "com.msl.linuxapp.\(descriptor.instance).\(String(slug))"
    }

    /// A name safe to use as a filename. `.desktop` `Name=` values are free
    /// text and routinely contain `/` (which would silently create a
    /// directory level) - and the generated name becomes a path under the
    /// user's home, so this is a boundary worth guarding, not cosmetic.
    public static func fileSafeName(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character == "/" || character == ":" || character == "\0" ? "-" : character
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = trimmed.drop(while: { $0 == "." })
        return withoutLeadingDots.isEmpty ? "Linux App" : String(withoutLeadingDots.prefix(60))
    }

    // MARK: - Icon

    /// MSL's own logo, for an app that brought none.
    ///
    /// Loaded once and held: bundle lookup plus a PNG decode per app is
    /// wasted work when every fallback wants the same image. `nil` if the
    /// resource is missing, which just restores the old behaviour of leaving
    /// `CFBundleIconFile` unset rather than failing the install - `MSLAsset`
    /// returns nil where `Bundle.module` would have trapped.
    static let melonIcon: NSImage? = {
        guard let url = MSLAsset.url("App_Logo", extension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Writes `image` as an `.icns`, via `iconutil` on a temporary iconset.
    ///
    /// `iconutil` rather than emitting the ICNS chunk table directly: it is
    /// a system tool, it was already proven end-to-end on a probe bundle
    /// before any of this was written, and a second hand-rolled binary
    /// format is not worth owning to save one subprocess.
    ///
    /// Returns `false` on any failure - an app with no icon is fine (macOS
    /// draws the generic one), an app that failed to generate is not.
    @discardableResult
    static func writeICNS(_ image: NSImage, to url: URL) -> Bool {
        let iconset = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-\(UUID().uuidString).iconset")
        guard MSLPaths.ensureDirectory(iconset) else { return false }
        defer { try? FileManager.default.removeItem(at: iconset) }

        // The set `iconutil` accepts; anything missing is simply not
        // offered at that size, so a small source icon still produces a
        // valid file rather than an upscaled blurry one.
        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        // A vector source can fill every slot: macOS rasterises SVG through
        // `_NSSVGImageRep`, so asking for 1024pt gives real detail rather
        // than an upscale. It has to be special-cased because such a rep
        // reports `pixelsWide == 0` - there are no pixels until something
        // asks - which the bitmap path below would read as "tiny source"
        // and clamp to 128, quietly discarding the sharpest art available.
        let sourcePixels = isVector(image) ? 1024 : maxPixelDimension(of: image)
        var wroteAny = false
        for variant in variants where variant.pixels <= max(sourcePixels, 128) {
            guard let data = pngData(from: image, pixels: variant.pixels) else { continue }
            guard (try? data.write(to: iconset.appendingPathComponent(variant.name + ".png"))) != nil else { continue }
            wroteAny = true
        }
        guard wroteAny else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether `image` is backed by a resolution-independent
    /// representation, in which case it can be drawn at any size.
    private static func isVector(_ image: NSImage) -> Bool {
        image.representations.contains { rep in
            (rep.pixelsWide == 0 && rep.pixelsHigh == 0)
                || String(describing: type(of: rep)).contains("SVG")
                || rep is NSPDFImageRep
        }
    }

    private static func maxPixelDimension(of image: NSImage) -> Int {
        image.representations.reduce(0) { max($0, max($1.pixelsWide, $1.pixelsHigh)) }
    }

    /// Rescales into a square canvas, letterboxing rather than stretching -
    /// Linux app icons are not all square, and a stretched icon reads as
    /// broken immediately.
    private static func pngData(from image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high

        let source = image.size
        let scale = min(CGFloat(pixels) / max(source.width, 1), CGFloat(pixels) / max(source.height, 1))
        let drawn = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2)
        image.draw(in: NSRect(origin: origin, size: drawn),
                   from: .zero, operation: .sourceOver, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
