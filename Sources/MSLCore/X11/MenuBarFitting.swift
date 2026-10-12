import AppKit
import Foundation

/// How many of a Linux application's menus fit in the Mac's menu bar, and
/// what to do with the rest.
///
/// A GTK or Qt application can easily have a dozen top-level menus, and on a
/// MacBook the menu bar has a notch in the middle of it: run past the
/// available space and macOS quietly drops the ones that do not fit, or the
/// titles crowd into the notch and the bar looks broken. Neither tells the
/// person that there are menus they cannot reach.
///
/// So MSL decides for itself: as many menus as genuinely fit, then a final
/// `>>>` menu holding everything else. Nothing is ever unreachable, and the
/// bar never runs into the notch.
public enum MenuBarFitting {
    /// The title of the menu that holds whatever did not fit.
    public static let overflowTitle = "\u{22EF}"   // ⋯

    /// Padding macOS puts around each menu bar title. Measured rather than
    /// guessed at: a title is drawn with about 10 points either side.
    static let titlePadding: CGFloat = 20

    /// How much room the menus actually have.
    ///
    /// On a Mac with a notch, `auxiliaryTopLeftArea` is exactly the usable
    /// strip to its left, which is all the menu bar gets. On a Mac without
    /// one it is the whole screen, and the right-hand half is reserved for
    /// status items, which is why only part of the width is offered.
    public static func availableWidth(for screen: NSScreen?) -> CGFloat {
        // A way to see the overflow without owning a Mac whose notch bites
        // at exactly the right width: most applications have few enough
        // menus to fit any real screen, so the only way this is ever looked
        // at is by making the bar narrow on purpose.
        if let forced = ProcessInfo.processInfo.environment["MSL_MENU_BAR_WIDTH"],
           let width = Double(forced), width > 0 {
            return CGFloat(width)
        }
        guard let screen else { return 600 }
        if let leftOfNotch = screen.auxiliaryTopLeftArea {
            return leftOfNotch.width
        }
        // No notch: leave the right-hand side for the clock, the battery and
        // everything else the person has put up there.
        return screen.frame.width * 0.55
    }

    /// Width one title occupies in the menu bar.
    public static func width(ofTitle title: String,
                             font: NSFont = .menuBarFont(ofSize: 0)) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width + titlePadding
    }

    /// Splits `titles` into the ones that fit and the ones that do not.
    ///
    /// `reserved` is everything already in the bar before the application's
    /// own menus: the Apple menu, the app menu, and MSL's own items.
    ///
    /// Two rules that matter more than the arithmetic:
    /// - If everything fits, there is no overflow menu at all. A `>>>` with
    ///   nothing behind it is worse than no `>>>`.
    /// - At least one menu is always kept, even on an absurdly narrow
    ///   screen, so the bar never becomes only an overflow.
    public static func split(titles: [String], available: CGFloat, reserved: CGFloat = 0,
                             width: (String) -> CGFloat = { width(ofTitle: $0) }) -> (visible: [String], overflow: [String]) {
        guard !titles.isEmpty else { return ([], []) }
        let budget = available - reserved
        let total = titles.reduce(0) { $0 + width($1) }
        if total <= budget { return (titles, []) }

        // Room has to be kept for the overflow menu itself, or adding it
        // would push the bar over the edge it was being kept away from.
        let overflowWidth = width(overflowTitle)
        var used: CGFloat = overflowWidth
        var visible: [String] = []
        for title in titles {
            let next = used + width(title)
            if next > budget, !visible.isEmpty { break }
            used = next
            visible.append(title)
        }
        return (visible, Array(titles.dropFirst(visible.count)))
    }
}
