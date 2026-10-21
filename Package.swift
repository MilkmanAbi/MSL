// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MSL",
    platforms: [.macOS(.v14)],
    // SwiftTerm is the terminal emulator behind MSLApp's built-in terminal
    // (see `TerminalTab`). It's the only external dependency in this
    // package - everything else here is written from scratch on purpose,
    // but a correct VT100/xterm emulator is a large, well-solved problem
    // with nothing MSL-specific about it.
    products: [
        .library(name: "MSLCore", targets: ["MSLCore"]),
        .library(name: "MSLObserver", targets: ["MSLObserver"]),
        .library(name: "PublicMSL", targets: ["PublicMSL"]),
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "mslhd", targets: ["mslhd"]),
        .executable(name: "bootstrap-guest", targets: ["bootstrap-guest"]),
        .executable(name: "extract-guest-modules", targets: ["extract-guest-modules"]),
        .executable(name: "build-shellinit", targets: ["build-shellinit"]),
        .executable(name: "msl-usbd", targets: ["msl-usbd"]),
        .executable(name: "provision-disk-image", targets: ["provision-disk-image"]),
        .executable(name: "bootstrap-distro", targets: ["bootstrap-distro"]),
        .executable(name: "MSLApp", targets: ["MSLApp"]),
        .executable(name: "MSLPeripherals", targets: ["MSLPeripherals"]),
        .executable(name: "mslgui", targets: ["mslgui"]),
        .executable(name: "msl-applauncher", targets: ["msl-applauncher"]),
        .executable(name: "mslod", targets: ["mslod"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        // MSL's observer, and the one target in this package with no
        // dependencies at all - not even MSLCore.
        //
        // That is the point of it. The observer has to keep working when the
        // thing it watches does not, and a watchdog linked against the same
        // library as its subject falls over for the same reasons its subject
        // does: MSLCore carries a `Bundle.module` resource bundle that
        // fatalErrors off the machine that built it, and links IOKit,
        // IOUSBHost and NetFS. So this is Foundation and the system, and the
        // few paths it shares with MSLCore are spelled out again, with
        // `ObserverParityTests` failing if any of them drifts.
        //
        // MSLCore depends on *it*, not the other way round, so there is one
        // stop-code table rather than two.
        .target(name: "MSLObserver"),
        .executableTarget(name: "mslod", dependencies: ["MSLObserver"]),
        .target(
            name: "MSLCore",
            dependencies: ["MSLObserver"],
            // The melon, a second time. `LinuxAppBundle` builds app bundles
            // from both the GUI and the CLI and falls back to this when a
            // Linux app ships no icon of its own, so MSLCore needs its own
            // copy - a symlink to MSLApp's is copied into the bundle *as a
            // symlink*, with a relative target that no longer resolves from
            // where it lands, and dangles. `AssetParityTests` fails if the
            // two copies ever drift apart.
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("NetFS"),
            ]
        ),
        .testTarget(name: "MSLCoreTests", dependencies: ["MSLCore", "MSLObserver"]),
        .testTarget(name: "MSLObserverTests", dependencies: ["MSLObserver"]),
        .testTarget(name: "PublicMSLTests", dependencies: ["PublicMSL", "MSLCore"]),
        // Renders the app's own views offscreen, so a card that crashes or
        // lays out to nothing is caught by `swift test` rather than by
        // someone opening the panel after it ships.
        .testTarget(name: "MSLAppTests", dependencies: ["MSLApp", "MSLCore"]),
        .executableTarget(name: "msl", dependencies: ["MSLCore", "PublicMSL"]),
        .executableTarget(name: "mslhd", dependencies: ["MSLCore", "PublicMSL"]),
        .executableTarget(name: "bootstrap-guest", dependencies: ["MSLCore"]),
        // Renders the in-app guide as a static site. Reads the same
        // `HelpGuide` the app does, so the published site cannot drift.
        .executableTarget(name: "help-export", dependencies: ["MSLCore"]),
        .executableTarget(name: "extract-guest-modules", dependencies: ["MSLCore"]),
        .executableTarget(name: "build-shellinit", dependencies: ["MSLCore"]),
        .executableTarget(name: "msl-usbd", dependencies: ["MSLCore"], exclude: ["README.md"]),
        // Reaching an instance from outside this Mac. Its own module rather
        // than more of MSLCore: it is the one part of MSL that deliberately
        // opens a machine to the internet, and that deserves a boundary
        // somebody can read in one sitting.
        .target(name: "PublicMSL", dependencies: ["MSLCore"]),
        .executableTarget(name: "provision-disk-image", dependencies: ["MSLCore"]),
        .executableTarget(name: "bootstrap-distro", dependencies: ["MSLCore"]),
        // A SwiftUI `App`/`@main` target builds fine as a plain SPM
        // executable (no Xcode project needed, consistent with every other
        // tool here) - it just isn't wrapped in a real .app bundle
        // (icon, proper Info.plist metadata, Dock name) yet. That's a
        // packaging step, separate from the Swift code itself - see
        // README for the same codesign+entitlements pattern every other
        // tool in this package already uses (`Resources/MSLApp/
        // MSLApp.entitlements`).
        .executableTarget(
            name: "MSLApp",
            dependencies: ["MSLCore", "MSLObserver", "PublicMSL",
                           .product(name: "SwiftTerm", package: "SwiftTerm")],
            // `.process`, not `.copy`: it flattens the files into the
            // bundle root, so `Bundle.module.url(forResource:)` finds them
            // by bare name with no `subdirectory:`. A `.copy("Resources")`
            // would keep the folder and every lookup here would return nil
            // at *runtime* - a blank About panel with no build error, which
            // is a miserable thing to debug.
            resources: [
                .process("Resources/App_Logo.png"),
                .process("Resources/Abi_Logo-Light.png"),
                .process("Resources/Abi_Logo-Dark.png"),
                .process("Resources/Mascot.png"),
                .process("Resources/Welcome_Banner.jpg"),
                .process("Resources/Crash_Screen.png"),
                .process("Resources/License.md"),
            ]
        ),
        // One process per Linux application - see `X11AppRouter`. macOS
        // gives one Dock tile per process, so this is what lets each app
        // appear as itself rather than all of them sharing `mslhd`'s.
        .executableTarget(name: "mslgui", dependencies: ["MSLCore"]),
        .executableTarget(name: "msl-applauncher", dependencies: ["MSLCore"]),
        // MSL Peripherals: the small app that lends the Mac's camera and
        // microphone to a Linux instance. Separate from MSLApp because
        // macOS grants those to an *application*, with a bundle and a usage
        // description - never to `mslhd`, which is a bare daemon and should
        // not be able to hold a camera even in principle.
        .executableTarget(name: "MSLPeripherals", dependencies: ["MSLCore"]),
    ]
)
