import Foundation

/// GLX - the extension every classic OpenGL app asks for before it draws
/// anything.
///
/// mslgd advertised no GLX at all, so `glxinfo`, `glxgears`, Blender and
/// most CAD simply refused to start ("GLX_ARB_create_context not
/// available"). Apps using EGL (Krita) were unaffected, which is why this
/// went unnoticed for so long.
///
/// **This server renders no GL itself.** Everything here is the *setup*
/// half of GLX: which framebuffer configurations exist, and the context
/// and drawable bookkeeping around them. The actual rendering happens
/// entirely in the guest, in Mesa, which then presents the finished frame
/// through ordinary core X11 (`PutImage`/`CopyArea`) - the `drisw` path.
/// That is deliberate and it is what makes the whole thing tractable:
///
/// - with plain Mesa, the guest renders on its CPU (llvmpipe) and we show
///   the result, which is what GL apps get today;
/// - with `GALLIUM_DRIVER=virpipe`, that same `drisw` path forwards the
///   drawing to `virgl_test_server` on the Mac and the frame comes back
///   rendered by the **real GPU** (see `Guest/virtual-gpu/`).
///
/// One GLX implementation, both. Indirect GLX (GL commands encoded into
/// the X stream, `GLXRender`) is *not* implemented and deliberately so:
/// it is a GL 1.4-era protocol nothing modern uses, and every client here
/// is local, so direct rendering always applies.
///
/// Sources: `glxproto.h` / `glxtokens.h` (xorgproto) for the wire format,
/// and Mesa's `src/glx` for what the client actually requires - which is
/// stricter than the spec in two places, both noted below.
enum GLXOpcode {
    static let render: UInt8 = 1
    static let renderLarge: UInt8 = 2
    static let createContext: UInt8 = 3
    static let destroyContext: UInt8 = 4
    static let makeCurrent: UInt8 = 5
    static let isDirect: UInt8 = 6
    static let queryVersion: UInt8 = 7
    static let waitGL: UInt8 = 8
    static let waitX: UInt8 = 9
    static let copyContext: UInt8 = 10
    static let swapBuffers: UInt8 = 11
    static let useXFont: UInt8 = 12
    static let createGLXPixmap: UInt8 = 13
    static let getVisualConfigs: UInt8 = 14
    static let destroyGLXPixmap: UInt8 = 15
    static let vendorPrivate: UInt8 = 16
    static let vendorPrivateWithReply: UInt8 = 17
    static let queryExtensionsString: UInt8 = 18
    static let queryServerString: UInt8 = 19
    static let clientInfo: UInt8 = 20
    static let getFBConfigs: UInt8 = 21
    static let createPixmap: UInt8 = 22
    static let destroyPixmap: UInt8 = 23
    static let createNewContext: UInt8 = 24
    static let queryContext: UInt8 = 25
    static let makeContextCurrent: UInt8 = 26
    static let createPbuffer: UInt8 = 27
    static let destroyPbuffer: UInt8 = 28
    static let getDrawableAttributes: UInt8 = 29
    static let changeDrawableAttributes: UInt8 = 30
    static let createWindow: UInt8 = 31
    static let destroyWindow: UInt8 = 32
    static let setClientInfoARB: UInt8 = 33
    static let createContextAttribsARB: UInt8 = 34
    static let setClientInfo2ARB: UInt8 = 35
}

/// Attribute tokens from `glxtokens.h`.
enum GLXToken {
    static let useGL: UInt32 = 1, bufferSize: UInt32 = 2, level: UInt32 = 3
    static let rgba: UInt32 = 4, doubleBuffer: UInt32 = 5, stereo: UInt32 = 6
    static let auxBuffers: UInt32 = 7
    static let redSize: UInt32 = 8, greenSize: UInt32 = 9, blueSize: UInt32 = 10, alphaSize: UInt32 = 11
    static let depthSize: UInt32 = 12, stencilSize: UInt32 = 13
    static let accumRed: UInt32 = 14, accumGreen: UInt32 = 15, accumBlue: UInt32 = 16, accumAlpha: UInt32 = 17
    static let configCaveat: UInt32 = 0x20
    static let xVisualType: UInt32 = 0x22
    static let transparentType: UInt32 = 0x23
    static let visualID: UInt32 = 0x800B
    static let screen: UInt32 = 0x800C
    static let none: UInt32 = 0x8000
    static let trueColor: UInt32 = 0x8002
    static let drawableType: UInt32 = 0x8010
    static let renderType: UInt32 = 0x8011
    static let xRenderable: UInt32 = 0x8012
    static let fbconfigID: UInt32 = 0x8013
    static let rgbaType: UInt32 = 0x8014
    static let maxPbufferWidth: UInt32 = 0x8016
    static let maxPbufferHeight: UInt32 = 0x8017
    static let maxPbufferPixels: UInt32 = 0x8018
    static let optimalPbufferWidth: UInt32 = 0x8019
    static let optimalPbufferHeight: UInt32 = 0x801A
    static let transparentIndexValue: UInt32 = 0x24
    static let transparentRedValue: UInt32 = 0x25, transparentGreenValue: UInt32 = 0x26
    static let transparentBlueValue: UInt32 = 0x27, transparentAlphaValue: UInt32 = 0x28
    static let swapMethodOML: UInt32 = 0x8060, swapUndefinedOML: UInt32 = 0x8063
    static let visualSelectGroupSGIX: UInt32 = 0x8028
    static let dontCare: UInt32 = 0xFFFF_FFFF
    static let bindToTextureRGB: UInt32 = 0x20D0, bindToTextureRGBA: UInt32 = 0x20D1
    static let bindToMipmapTexture: UInt32 = 0x20D2, bindToTextureTargets: UInt32 = 0x20D3
    static let yInverted: UInt32 = 0x20D4
    static let textureFormat: UInt32 = 0x20D5, textureTarget: UInt32 = 0x20D6
    static let width: UInt32 = 0x801D, height: UInt32 = 0x801E
    static let preservedContents: UInt32 = 0x801B, largestPbuffer: UInt32 = 0x801C
    static let eventMask: UInt32 = 0x801F
    static let pbufferWidth: UInt32 = 0x8041, pbufferHeight: UInt32 = 0x8040
    static let vendorNamesEXT: UInt32 = 0x20F6
    static let sampleBuffers: UInt32 = 100_000
    static let samples: UInt32 = 100_001
    static let windowBit: UInt32 = 0x01, pixmapBit: UInt32 = 0x02, pbufferBit: UInt32 = 0x04
    static let rgbaBit: UInt32 = 0x01
}

/// One framebuffer configuration. The set mslgd offers is deliberately
/// small and entirely conventional: Mesa intersects the server's configs
/// with the ones its own driver can provide, so exotic entries would only
/// be dropped, while a missing common one (8-bit RGBA, 24-bit depth,
/// 8-bit stencil, double buffered) makes ordinary apps fail to find any
/// visual at all.
struct X11GLXConfig {
    var fbconfigID: UInt32
    var visualID: UInt32
    /// The X visual's depth, which fixes the colour bits.
    var xDepth: Int
    var doubleBuffer: Bool
    var depthBits: Int
    var stencilBits: Int
    /// 0 or 8. The depth-24 visuals carry configs both with and without an
    /// alpha buffer, as on Xorg (GL alpha is off-screen state; it doesn't
    /// need a depth-32 window).
    var alphaBits: Int

    /// Colour bits the GLX config reports: RGB plus the alpha buffer.
    var rgbBits: Int { 24 + alphaBits }

    /// The first visual id handed to an extra GLX visual (0x21 and 0x22 are
    /// the default and ARGB visuals).
    static let firstExtraVisualID: UInt32 = 0x23

    /// Every config mslgd offers, **each with its own X visual**, in the
    /// order clients see them.
    ///
    /// One visual per config is not decoration. Mesa maps a visual back to
    /// its config by visual id (`glx_config_find_visual`) and takes the
    /// first match, so while all twelve configs shared two visuals, every
    /// app on the classic `glXChooseVisual` + `glXCreateContext` path (SDL
    /// 1.2, FLTK, Tk, older CAD toolkits) got the first config of that
    /// visual whatever it asked for: a single-buffered request came back
    /// double-buffered (black window for apps that only `glFlush`), a "no
    /// depth buffer" request got one anyway. Xorg gives each config a
    /// visual for exactly this reason; the set mirrors Xvfb's
    /// window-capable configs, which Mesa's swrast driver is known to match.
    ///
    /// The default and ARGB visuals keep the configs they always had
    /// (double-buffered, 24-bit depth, 8-bit stencil), so apps that already
    /// worked see no change.
    static func all(visualID: UInt32, argbVisualID: UInt32) -> [X11GLXConfig] {
        let depthStencil = [(24, 8), (24, 0), (16, 0), (0, 0)]
        var combos: [(xDepth: Int, alpha: Int, double: Bool, depth: Int, stencil: Int)] = []
        for alpha in [0, 8] {
            for double in [true, false] {
                for (depth, stencil) in depthStencil {
                    combos.append((24, alpha, double, depth, stencil))
                }
            }
        }
        for double in [true, false] {
            for (depth, stencil) in depthStencil {
                combos.append((32, 8, double, depth, stencil))
            }
        }
        var configs: [X11GLXConfig] = []
        var nextVisual = firstExtraVisualID
        var nextConfig: UInt32 = 0x60
        for combo in combos {
            let isDefault = combo.alpha == (combo.xDepth == 32 ? 8 : 0) && combo.double
                && combo.depth == 24 && combo.stencil == 8
            let visual: UInt32
            if isDefault {
                visual = combo.xDepth == 32 ? argbVisualID : visualID
            } else {
                visual = nextVisual
                nextVisual += 1
            }
            configs.append(X11GLXConfig(fbconfigID: nextConfig, visualID: visual, xDepth: combo.xDepth,
                                        doubleBuffer: combo.double, depthBits: combo.depth,
                                        stencilBits: combo.stencil, alphaBits: combo.alpha))
            nextConfig += 1
        }
        // The two defaults first, as before, so clients that take the first
        // sufficient config keep getting the one they always got.
        return configs.filter { $0.visualID == visualID } + configs.filter { $0.visualID == argbVisualID }
            + configs.filter { $0.visualID != visualID && $0.visualID != argbVisualID }
    }

    /// The extra visuals `all` hands out, per X depth, for the connection
    /// setup and RENDER's format table.
    static func extraVisuals(visualID: UInt32, argbVisualID: UInt32, depth: Int) -> [UInt32] {
        all(visualID: visualID, argbVisualID: argbVisualID)
            .filter { $0.xDepth == depth && $0.visualID != visualID && $0.visualID != argbVisualID }
            .map(\.visualID)
    }

    /// The 18 fixed properties `GetVisualConfigs` leads with, in the exact
    /// order Mesa's `__glXInitializeVisualConfigFromTags` reads them.
    /// Getting this order wrong does not error - it silently yields
    /// nonsense configs, which is far worse.
    var visualConfigProperties: [UInt32] {
        [
            visualID,
            4, // X visual class: TrueColor
            1, // rgba
            8, 8, 8, UInt32(alphaBits), // r, g, b, a
            0, 0, 0, 0, // accumulation buffer: none
            doubleBuffer ? 1 : 0,
            0, // stereo
            UInt32(rgbBits),
            UInt32(depthBits),
            UInt32(stencilBits),
            0, // aux buffers
            0, // level
        ]
    }

    /// The tagged (attribute, value) pairs, used by `GetFBConfigs` for
    /// everything and appended to `GetVisualConfigs`' fixed part.
    var taggedProperties: [(UInt32, UInt32)] {
        [
            (GLXToken.visualID, visualID),
            (GLXToken.fbconfigID, fbconfigID),
            // No GLX_SCREEN here: it is not a valid fbconfig attribute and
            // Mesa warns "unknown fbconfig attribute from server" for every
            // config. The client already knows the screen it asked about.
            (GLXToken.drawableType, GLXToken.windowBit | GLXToken.pixmapBit | GLXToken.pbufferBit),
            (GLXToken.renderType, GLXToken.rgbaBit),
            (GLXToken.xRenderable, 1),
            (GLXToken.xVisualType, GLXToken.trueColor),
            (GLXToken.configCaveat, GLXToken.none),
            (GLXToken.transparentType, GLXToken.none),
            (GLXToken.useGL, 1),
            (GLXToken.rgba, 1),
            (GLXToken.bufferSize, UInt32(rgbBits)),
            (GLXToken.level, 0),
            (GLXToken.doubleBuffer, doubleBuffer ? 1 : 0),
            (GLXToken.stereo, 0),
            (GLXToken.auxBuffers, 0),
            (GLXToken.redSize, 8), (GLXToken.greenSize, 8), (GLXToken.blueSize, 8),
            (GLXToken.alphaSize, UInt32(alphaBits)),
            (GLXToken.depthSize, UInt32(depthBits)),
            (GLXToken.stencilSize, UInt32(stencilBits)),
            (GLXToken.accumRed, 0), (GLXToken.accumGreen, 0),
            (GLXToken.accumBlue, 0), (GLXToken.accumAlpha, 0),
            (GLXToken.sampleBuffers, 0), (GLXToken.samples, 0),
            // Zero, as Xorg/Xvfb send, not a real limit. Mesa up to ~21
            // compares every fbconfig attribute against its own driver's
            // configs (`driConfigEqual`), and the driver reports 0 here -
            // so 4096 made *every* config fail to match and old GL clients
            // (anything in a core18/core20 snap, e.g. mari0) died with
            // "No matching fbConfigs or visuals found". Mesa does not check
            // these when creating a pbuffer, so nothing is lost.
            (GLXToken.maxPbufferWidth, 0),
            (GLXToken.maxPbufferHeight, 0),
            (GLXToken.maxPbufferPixels, 0),
            (GLXToken.optimalPbufferWidth, 0),
            (GLXToken.optimalPbufferHeight, 0),
            // The rest of what Xorg sends, so an old client's defaults can't
            // disagree with its driver: transparency unused, swap method
            // undefined, and "don't care" wherever the driver decides.
            (GLXToken.transparentIndexValue, 0),
            (GLXToken.transparentRedValue, GLXToken.dontCare),
            (GLXToken.transparentGreenValue, GLXToken.dontCare),
            (GLXToken.transparentBlueValue, GLXToken.dontCare),
            (GLXToken.transparentAlphaValue, GLXToken.dontCare),
            (GLXToken.swapMethodOML, GLXToken.swapUndefinedOML),
            // GLX_EXT_texture_from_pixmap, with the values Mesa's own
            // driver configs carry (driCreateConfigs: RGB and RGBA yes,
            // mipmaps no, 1D|2D|RECT) - old Mesa rejects a config whose
            // values differ, and compositors choose configs by these.
            (GLXToken.bindToTextureRGB, 1),
            (GLXToken.bindToTextureRGBA, 1),
            (GLXToken.bindToMipmapTexture, 0),
            (GLXToken.bindToTextureTargets, 0x7),
            (GLXToken.yInverted, GLXToken.dontCare),
            (GLXToken.visualSelectGroupSGIX, 0),
        ]
    }
}

/// GLX state for one connection: the contexts and drawables it made.
///
/// Contexts carry no GL state here (the guest owns that); what matters is
/// that the ids exist, that `IsDirect` answers what the client said when
/// it created the context, and that stale ids get the right error.
final class X11GLXState {
    struct Context {
        var isDirect: Bool
        var fbconfigID: UInt32
        var screen: UInt32
    }

    var contexts: [UInt32: Context] = [:]
    /// GLXWindow/GLXPixmap/GLXPbuffer ids -> the X drawable behind them.
    var drawables: [UInt32: UInt32] = [:]
    /// What each GLX drawable is and what it was created with, for
    /// `GetDrawableAttributes` / `glXQueryDrawable` (texture-from-pixmap
    /// reads its target and format back from here).
    struct DrawableInfo {
        var typeBit: UInt32
        var fbconfigID: UInt32
        var attributes: [UInt32: UInt32]
    }
    var drawableInfo: [UInt32: DrawableInfo] = [:]
    /// Handed out by `MakeCurrent`; only ever has to be non-zero and stable.
    var nextContextTag: UInt32 = 1
}
