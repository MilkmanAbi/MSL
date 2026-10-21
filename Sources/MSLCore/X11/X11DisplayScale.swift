import CoreGraphics
import Foundation

/// How many Mac points one X11 pixel takes on screen - the "Native Scaling"
/// experimental feature.
///
/// mslgd has always shown one X11 pixel as one Mac point. That follows the
/// Mac's own display scaling (a Linux app grows and shrinks with "Larger
/// Text" / "More Space" like everything else) and it stays sharp on Retina,
/// where each X pixel is exactly 2x2 physical pixels. But Linux toolkits are
/// drawn to a roomier standard than macOS: GNOME's body text is 11pt at
/// 96 dpi, 14.7 pixels, where the Mac's is 13 points, and its buttons are
/// 34 pixels tall against the Mac's 22 points. So a Linux app looked right
/// and read big.
///
/// With Native Scaling on, a Linux window is drawn at `nativeFactor` of
/// that: text lands close to the Mac's 13-point body size, and the screen
/// mslgd reports to Linux grows by the same factor, so apps lay out for the
/// room they really have. The factor is fixed for a process - read once,
/// when the app's host starts - so it applies to Linux apps opened after
/// turning it on, never to a window already on screen.
public enum X11DisplayScale {
    /// 13 / 14.7 rounds to 0.88 for text; widgets are further apart than
    /// that. 0.85 splits the difference and keeps text comfortably legible.
    public static let nativeFactor: CGFloat = 0.85

    /// Half a point per X pixel: on a Retina display that is **exactly one
    /// physical pixel**, which is the whole point of the mode.
    public static let retinaFactor: CGFloat = 0.5

    /// The density mslgd tells Linux the screen has.
    ///
    /// **This moves with the factor or not at all.** The screen mslgd
    /// reports grows as the factor shrinks - half a point per pixel means
    /// twice as many pixels across the same glass - so the density has to
    /// double with it, or the physical size implied by the two disagrees
    /// and apps size text for a screen that is not there.
    public static let nominalDPI: Double = 96
    public static let retinaDPI: Double = 192

    /// Which mode this process is in. Read once: an app lays out for the
    /// screen it was told about when it started.
    public enum Mode: Equatable, Sendable {
        /// One X pixel per Mac point, 96 dpi. What every app has been tested at.
        case onePixelPerPoint
        /// Smaller, at the same detail. Text lands near the Mac's own size.
        case native
        /// The same size at the Mac's real pixel density: four times the
        /// pixels, each one a physical pixel on Retina.
        case retina

        var factor: CGFloat {
            switch self {
            case .onePixelPerPoint: return 1
            case .native: return nativeFactor
            case .retina: return retinaFactor
            }
        }

        var dpi: Double {
            switch self {
            // **Native deliberately keeps 96.** It shrinks by drawing the
            // same pixels into fewer points; telling the app it had 113 dpi
            // would make it draw larger text in pixels and cancel most of
            // the shrink. Retina is the opposite - it is asking for more
            // pixels, so the density must say so.
            case .onePixelPerPoint, .native: return nominalDPI
            case .retina: return retinaDPI
            }
        }
    }

    /// Retina wins when both are on: they answer the same question, and
    /// this is the one that answers it at full detail.
    public static let mode: Mode = {
        let settings = MSLExperimentalSettingsStore.load()
        if settings.retinaRendering { return .retina }
        return settings.nativeScaling ? .native : .onePixelPerPoint
    }()

    /// Points per X11 pixel for this process.
    public static let factor: CGFloat = mode.factor

    /// Dots per inch for this process, for every place that reports a
    /// physical screen size.
    public static let dpi: Double = mode.dpi

    /// Millimetres for a span of X pixels, at this process's density.
    ///
    /// **Every physical-size answer goes through here.** mslgd reports the
    /// screen's size in three different replies - the connection setup,
    /// RandR's output info, and RandR's monitors - and they have to agree.
    /// They did not once before: a stray factor left RandR implying ~9 dpi
    /// against the setup's 96, and GTK3 clipped the last widget out of
    /// every window because Pango's font density and GTK's layout density
    /// disagreed. One function, so that cannot happen again.
    public static func millimetres(forPixels pixels: Int) -> Double {
        Double(pixels) * 25.4 / dpi
    }
}
