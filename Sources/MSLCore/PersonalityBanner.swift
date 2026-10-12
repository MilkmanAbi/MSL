import Foundation

/// What MSL prints at the top of a shell, given the two switches.
///
/// One renderer so that `msl`'s banner, `msl greeter`'s example and the
/// app's preview cannot drift apart - the preview is only worth having if
/// it is the same code that runs in the shell.
///
/// The four cases:
///
/// | the cat | the greeting | what prints              |
/// |---------|--------------|--------------------------|
/// | on      | on           | the cat, the line under  |
/// | off     | on           | the line on its own      |
/// | on      | off          | just the cat             |
/// | off     | off          | nothing                  |
///
/// The cat sits **above** the line rather than holding it in a cowsay
/// bubble. A bubble puts the text above the cat and pushes her down the
/// screen, and at the top of every shell what you want is her first and the
/// line tucked under her. `Kitty.say` still exists for `msl kitty "words"`,
/// which is the place a speech bubble actually belongs.
///
/// The greeting is passed in rather than drawn here, so tests are
/// deterministic and so that nothing in this file touches the stored "not
/// the same twice" state - a test that called `Greeter.nextGreeting()`
/// would be writing the real one.
public enum PersonalityBanner {

    /// `nil` when there is nothing to print, which is both switches off.
    ///
    /// - Parameter columns: the terminal's width, or zero when there is no
    ///   terminal to ask. A terminal too narrow for the cat falls back to
    ///   the bare greeting rather than letting her wrap, because a wrapped
    ///   cat is not a cat - but **zero means unknown, not narrow**.
    ///   `ioctl(TIOCGWINSZ)` fails on a pipe and leaves the width at zero,
    ///   and reading that as a nought-column terminal silently dropped her
    ///   from everything that was not a tty.
    public static func render(settings: PersonalitySettings,
                              greeting: String?,
                              columns: Int = 80) -> String? {
        let greeting = settings.greeters ? greeting : nil
        guard settings.kitty else { return greeting }
        // A cat folded in half by the terminal is not a cat. Below her own
        // width, the line on its own is the better answer - but only when
        // the width is actually known.
        guard columns <= 0 || columns >= Kitty.artColumns else { return greeting }

        guard let greeting else { return Kitty.art }
        return Kitty.art + "\n" + greeting
    }
}
