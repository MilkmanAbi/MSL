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
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "mslhd", targets: ["mslhd"]),
        .executable(name: "bootstrap-guest", targets: ["bootstrap-guest"]),
        .executable(name: "extract-guest-modules", targets: ["extract-guest-modules"]),
        .executable(name: "build-shellinit", targets: ["build-shellinit"]),
        .executable(name: "msl-usbd", targets: ["msl-usbd"]),
        .executable(name: "provision-disk-image", targets: ["provision-disk-image"]),
        .executable(name: "bootstrap-distro", targets: ["bootstrap-distro"]),
        .executable(name: "MSLApp", targets: ["MSLApp"]),
        .executable(name: "mslgui", targets: ["mslgui"]),
        .executable(name: "msl-applauncher", targets: ["msl-applauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "MSLCore",
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
        .testTarget(name: "MSLCoreTests", dependencies: ["MSLCore"]),
        .executableTarget(name: "msl", dependencies: ["MSLCore"]),
        .executableTarget(name: "mslhd", dependencies: ["MSLCore"]),
        .executableTarget(name: "bootstrap-guest", dependencies: ["MSLCore"]),
        .executableTarget(name: "extract-guest-modules", dependencies: ["MSLCore"]),
        .executableTarget(name: "build-shellinit", dependencies: ["MSLCore"]),
        .executableTarget(name: "msl-usbd", dependencies: ["MSLCore"], exclude: ["README.md"]),
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
            dependencies: ["MSLCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
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
                .process("Resources/License.md"),
            ]
        ),
        // One process per Linux application - see `X11AppRouter`. macOS
        // gives one Dock tile per process, so this is what lets each app
        // appear as itself rather than all of them sharing `mslhd`'s.
        .executableTarget(name: "mslgui", dependencies: ["MSLCore"]),
        .executableTarget(name: "msl-applauncher", dependencies: ["MSLCore"]),
    ]
)
