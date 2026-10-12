import XCTest
@testable import MSLCore

final class AppGraphicsModeTests: XCTestCase {
    func testModeOverridesTheGlobalSwitch() {
        XCTAssertTrue(AppGraphicsMode.gpu.usesGPU(globalSwitch: false, rendererInstalled: true))
        XCTAssertFalse(AppGraphicsMode.cpu.usesGPU(globalSwitch: true, rendererInstalled: true))
        XCTAssertTrue(AppGraphicsMode.automatic.usesGPU(globalSwitch: true, rendererInstalled: true))
        XCTAssertFalse(AppGraphicsMode.automatic.usesGPU(globalSwitch: false, rendererInstalled: true))
    }

    /// virpipe with nothing listening breaks every GL app, so no renderer
    /// means no GPU whatever was chosen.
    func testNoRendererMeansNoGPU() {
        for mode in AppGraphicsMode.allCases {
            XCTAssertFalse(mode.usesGPU(globalSwitch: true, rendererInstalled: false), mode.rawValue)
        }
    }

    func testCPUModePinsLlvmpipe() {
        let command = GuestIntegration.launchCommand("glxgears", instance: "test-no-overrides", settings: MSLExperimentalSettings(), graphics: .cpu)
        XCTAssertTrue(command.contains("export GALLIUM_DRIVER=llvmpipe"))
        XCTAssertFalse(command.contains("GALLIUM_DRIVER=virpipe"))
    }

    func testKeyIgnoresSurroundingWhitespace() {
        XCTAssertEqual(AppGraphicsStore.key(instance: "Milk", command: " blender "),
                       AppGraphicsStore.key(instance: "Milk", command: "blender"))
        XCTAssertNotEqual(AppGraphicsStore.key(instance: "Milk", command: "blender"),
                          AppGraphicsStore.key(instance: "Oat", command: "blender"))
    }
}

extension AppGraphicsModeTests {
    /// Snaps have a private /tmp and can never reach the vtest socket; told
    /// to use virpipe they abort (mari0 did).
    func testSnapAppsNeverGetTheGPUPath() {
        let lines = GuestIntegration.gpuLines(for: "'mari0'")
        XCTAssertTrue(lines.hasPrefix("case \"$(command -v 'mari0' 2>/dev/null)\" in"))
        XCTAssertTrue(lines.contains("/snap/*|"), "snaps are the first arm of the sandbox case")
        XCTAssertEqual(GuestIntegration.programName(in: "env FOO=1 'blender' --flag"), "blender")
    }
}

final class GLXConfigCompatibilityTests: XCTestCase {
    /// Old Mesa (core18/core20 snaps) matches every attribute against its
    /// driver, which reports 0 pbuffer limits; anything else matched no
    /// config at all ("No matching fbConfigs or visuals found").
    func testPbufferLimitsAreZeroLikeXorg() {
        let config = X11GLXConfig.all(visualID: 0x21, argbVisualID: 0x22)[0]
        let tags = Dictionary(config.taggedProperties, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tags[GLXToken.maxPbufferWidth], 0)
        XCTAssertEqual(tags[GLXToken.maxPbufferHeight], 0)
        XCTAssertEqual(tags[GLXToken.maxPbufferPixels], 0)
        XCTAssertEqual(tags[GLXToken.swapMethodOML], GLXToken.swapUndefinedOML)
        XCTAssertEqual(tags[GLXToken.transparentRedValue], GLXToken.dontCare)
    }
}

extension GLXConfigCompatibilityTests {
    /// Mesa maps a visual back to its config by id and takes the first
    /// match, so every config needs a visual of its own.
    func testEveryConfigHasItsOwnVisual() {
        let configs = X11GLXConfig.all(visualID: 0x21, argbVisualID: 0x22)
        XCTAssertEqual(configs.count, 24)
        XCTAssertEqual(Set(configs.map(\.visualID)).count, configs.count)
        XCTAssertEqual(configs.first?.visualID, 0x21, "the default config still comes first")
        XCTAssertTrue(configs.first!.doubleBuffer && configs.first!.depthBits == 24 && configs.first!.stencilBits == 8)
        XCTAssertTrue(configs.contains { !$0.doubleBuffer && $0.depthBits == 0 && $0.xDepth == 24 && $0.alphaBits == 0 })
        XCTAssertTrue(configs.contains { $0.xDepth == 24 && $0.alphaBits == 8 })
        XCTAssertFalse(configs.contains { $0.xDepth == 32 && $0.alphaBits == 0 })
    }

    /// The setup's length field must still add up with the extra visuals.
    func testConnectionSetupLengthAddsUp() {
        let bytes = X11ConnectionSetup.buildSuccessResponse(.init(
            littleEndian: true, resourceIdBase: 0x200000, resourceIdMask: 0x1FFFFF,
            rootWindowID: 0x3FFFFF, colormapID: 0x3FFFFE, visualID: 0x21, argbVisualID: 0x22,
            extraVisuals24: X11GLXConfig.extraVisuals(visualID: 0x21, argbVisualID: 0x22, depth: 24),
            extraVisuals32: X11GLXConfig.extraVisuals(visualID: 0x21, argbVisualID: 0x22, depth: 32),
            screenWidthPixels: 1920, screenHeightPixels: 1080))
        let declared = Int(bytes[6]) | Int(bytes[7]) << 8
        XCTAssertEqual(bytes.count, 8 + declared * 4)
    }
}

extension AppGraphicsModeTests {
    /// A Flatpak's launcher is an ordinary /usr/bin/flatpak, so the `/snap/*`
    /// test could never catch it - but the app it runs is just as sandboxed
    /// and just as unable to see /tmp/.virgl_test.
    func testFlatpakAppsNeverGetTheGPUPath() {
        XCTAssertEqual(GuestIntegration.gpuLines(for: "flatpak run org.gnome.Calculator"), "",
                       "a flatpak launch must carry no virpipe setup at all")
        XCTAssertEqual(GuestIntegration.gpuLines(for: "/usr/bin/flatpak run org.gnome.Calculator"), "")
        // Exported flatpak wrappers are caught by path too.
        let wrapper = GuestIntegration.gpuLines(for: "org.gnome.Calculator")
        XCTAssertTrue(wrapper.contains("/var/lib/flatpak/*"))
        XCTAssertTrue(wrapper.contains("/snap/*"), "snaps still excluded")
    }
}
