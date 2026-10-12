// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Clearing a terminal so that nothing is left behind.
///
/// There is one correct order and it is not the obvious one.
///
/// `ESC[2J` erases the screen. In Terminal.app it *also pushes what was on
/// screen into the scrollback*, so erasing and then homing - the spelling
/// almost everyone reaches for - leaves the old contents and a screenful of
/// blank rows sitting above whatever is printed next. Scroll up after it
/// and the mess is all still there.
///
/// `ESC[3J` is what discards the scrollback, and it has to come **last**.
/// ncurses sends it first, from the `E3` capability, and that order is
/// wrong here for exactly the same reason: clearing the scrollback and then
/// clearing the screen simply puts the last screenful straight back.
///
/// Measured against Terminal.app's own `history`, with ⌘K - its built-in
/// Clear Scrollback - as the reference:
///
/// ```
/// Cmd+K                     lines=25    numbers left=0
/// ESC[3J ESC[H ESC[2J       lines=49    numbers left=4   <- ncurses order
/// ESC[H ESC[2J ESC[3J       lines=25    numbers left=0   <- this one
/// ESC c (full reset)        lines=303   numbers left=0
/// ```
///
/// A terminal whose `ESC[2J` does not touch the scrollback is unaffected by
/// the order, and one whose `ESC[2J` does needs exactly this - so putting
/// `ESC[3J` last is right everywhere.
public enum TerminalClear {
    /// Home, erase the screen, discard the scrollback. Equivalent to ⌘K.
    public static let full = "\u{1B}[H\u{1B}[2J\u{1B}[3J"

    /// The same bytes written for a shell's `printf`.
    ///
    /// `\033` rather than `\e`: dash and busybox `printf` do not know `\e`,
    /// and the guest file this ends up in is sourced by whatever shell the
    /// person happens to use.
    public static let shellEscapes = #"\033[H\033[2J\033[3J"#
}
