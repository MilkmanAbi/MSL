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

    /// Points per X11 pixel for this process.
    public static let factor: CGFloat =
        MSLExperimentalSettingsStore.load().nativeScaling ? nativeFactor : 1
}
