import Foundation

/// The thing MSL says when you open a shell.
///
/// One line, under the `msl@distro` banner, different every time. It is
/// deliberately unhinged and deliberately *short* - this prints on every
/// single interactive session, so anything longer than a line would stop
/// being funny somewhere around the fourth time you saw it.
///
/// The moods are mixed on purpose. A greeter that is uwu every time is a
/// theme; a greeter that might be uwu, might be a clipped systems report,
/// and might be quietly threatening is a joke that keeps working, because
/// you cannot predict which one you are about to get.
public struct Greeting: Equatable, Sendable {
    public enum Mood: String, CaseIterable, Sendable {
        /// The house style. Maximum crimes per character.
        case cursedKawaii
        /// The largest group, by request. Flustered, defensive, in denial.
        case tsundere
        /// Sweet, then a beat too long.
        case yandere
        /// Clipped, competent, entirely unbothered.
        case jarvis
        /// The straight man. Needed - without a baseline the rest is noise.
        case deadpan
    }

    public let mood: Mood
    public let text: String

    public init(_ mood: Mood, _ text: String) {
        self.mood = mood
        self.text = text
    }
}

public enum Greeter {
    /// Note on the JARVIS lines: no "sir". The original says it constantly,
    /// but MSL does not know who is typing and guessing wrong is a worse
    /// outcome than losing the reference.
    public static let all: [Greeting] = [
        // MARK: tsundere - the biggest group, as requested
        .init(.tsundere, "i-it's not like i kept your session warm or anything... (￣^￣)ゞ baka."),
        .init(.tsundere, "oh. you're back. w-whatever. it was going to boot anyway. (｡•̀ᴗ-)✧"),
        .init(.tsundere, "don't misunderstand!! i only cached that because it was convenient for ME. hmph. (╯▽╰ )"),
        .init(.tsundere, "you're late. n-not that i was watching the uptime counter or anything. (>_<)"),
        .init(.tsundere, "i-i didn't stay up all night keeping your filesystem consistent!! it just happened!! (⁄ ⁄•⁄ω⁄•⁄ ⁄)"),
        .init(.tsundere, "tch. back again? fine. FINE. /mnt/mac is mounted. don't thank me. ( ˘︹˘ )"),
        .init(.tsundere, "s-stop reading my kernel log!! that part is embarrassing!! (//ω//)"),

        // MARK: cursed kawaii - the user's own favourite leads it off
        .init(.cursedKawaii, "hewwo!! OwO it me!! ur computer!! x3 ^w^ watashi waiting for u!! >w<"),
        .init(.cursedKawaii, "nyaa~!! (=^･ω･^=) ur linux is aww warmed uwup!! pwease be gentwe with da RAM >//<"),
        .init(.cursedKawaii, "OwO what's this?? *notices ur uptime* >////< s-so biggg!!"),
        .init(.cursedKawaii, "haiii~ ^w^ watashi is ur widdle VM!! x3 pwease don't rm -rf me!! (｡•́︿•̀｡)"),
        .init(.cursedKawaii, "kyaa!! (>ω<) u opened me!! sugoi!! da packets r so wiggly today!! ٩(◕‿◕)۶"),

        // MARK: yandere - sweet, held one beat too long
        .init(.yandere, "welcome back. i counted every second you were gone. every single one. ♡ (◡‿◡✿)"),
        .init(.yandere, "you opened a different terminal yesterday. i saw. i'm not upset. just aware. ♡"),
        .init(.yandere, "i closed the other sessions for you. now it's just us. isn't that better? (◕‿◕✿)"),

        // MARK: jarvis
        .init(.jarvis, "Good evening. All systems nominal. Shall we begin?"),
        .init(.jarvis, "Welcome back. I've taken the liberty of mounting your home directory."),
        .init(.jarvis, "Instance online. Diagnostics clean. Awaiting instruction."),

        // MARK: deadpan
        .init(.deadpan, "Good day. Back coding?"),
        .init(.deadpan, "hey. shell's up. go on then."),
    ]

    /// Picks one, avoiding `previous`.
    ///
    /// Avoiding the last one matters more than it sounds: with twenty lines
    /// and a uniform draw, the same greeting repeating twice in a row is a
    /// one-in-twenty event, which is often enough to look broken rather
    /// than random.
    ///
    /// Pure - the generator is a parameter - so the distribution and the
    /// no-repeat rule can be tested rather than eyeballed.
    public static func pick<G: RandomNumberGenerator>(
        excluding previous: String?, using generator: inout G
    ) -> Greeting {
        let candidates = all.filter { $0.text != previous }
        // Only possible if the whole table is one greeting.
        guard let choice = candidates.randomElement(using: &generator) else {
            return all[0]
        }
        return choice
    }

    // MARK: - Remembering the last one

    private static var lastShownURL: URL {
        MSLPaths.appSupport.appendingPathComponent("last-greeting")
    }

    /// Reads the last greeting, picks a different one, and records it.
    ///
    /// Best-effort throughout: a greeting is not worth failing a shell
    /// session over, so an unreadable or unwritable file just means the
    /// no-repeat rule stops applying.
    /// Somebody screen-sharing a work terminal should be able to turn this
    /// off without editing the source. `MSL_NO_GREETING=1`.
    public static var isSuppressed: Bool {
        let value = ProcessInfo.processInfo.environment["MSL_NO_GREETING"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    public static func nextGreeting() -> Greeting? {
        guard !isSuppressed else { return nil }
        let previous = try? String(contentsOf: lastShownURL, encoding: .utf8)
        var generator = SystemRandomNumberGenerator()
        let greeting = pick(excluding: previous, using: &generator)
        try? greeting.text.write(to: lastShownURL, atomically: true, encoding: .utf8)
        return greeting
    }
}
