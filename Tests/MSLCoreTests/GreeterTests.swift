import XCTest
@testable import MSLCore

final class GreeterTests: XCTestCase {
    /// Deterministic, so the no-repeat rule is tested rather than hoped at.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    func testThereAreTwenty() {
        XCTAssertEqual(Greeter.all.count, 20)
    }

    func testEveryMoodIsRepresented() {
        let moods = Set(Greeter.all.map(\.mood))
        for mood in Greeting.Mood.allCases {
            XCTAssertTrue(moods.contains(mood), "no \(mood) greetings")
        }
    }

    /// The user asked for "a lot of tsundere", so that is a property of the
    /// table and not an accident of whatever got written last.
    func testTsundereIsTheLargestGroup() {
        let counts = Dictionary(grouping: Greeter.all, by: \.mood).mapValues(\.count)
        let tsundere = counts[.tsundere] ?? 0
        for (mood, count) in counts where mood != .tsundere {
            XCTAssertGreaterThan(tsundere, count, "\(mood) has \(count), tsundere only \(tsundere)")
        }
    }

    func testNoneAreEmptyOrPaddedByAccident() {
        for greeting in Greeter.all {
            XCTAssertFalse(greeting.text.isEmpty)
            XCTAssertEqual(greeting.text, greeting.text.trimmingCharacters(in: .whitespaces),
                           "stray whitespace in: \(greeting.text)")
            // One line. This prints on every interactive session.
            XCTAssertFalse(greeting.text.contains("\n"), "multi-line greeting: \(greeting.text)")
        }
    }

    /// The user's own favourite, kept verbatim.
    func testTheHouseFavouriteIsPresent() {
        XCTAssertTrue(Greeter.all.contains {
            $0.text == "hewwo!! OwO it me!! ur computer!! x3 ^w^ watashi waiting for u!! >w<"
        })
    }

    /// Two identical greetings in a row read as a bug rather than as chance.
    func testNeverRepeatsTheExcludedGreeting() {
        var generator = SeededGenerator(state: 0x5eed)
        for greeting in Greeter.all {
            for _ in 0..<50 {
                XCTAssertNotEqual(Greeter.pick(excluding: greeting.text, using: &generator).text,
                                  greeting.text)
            }
        }
    }

    /// No previous greeting - a fresh install - must still work.
    func testPickWithNoPreviousWorks() {
        var generator = SeededGenerator(state: 99)
        let greeting = Greeter.pick(excluding: nil, using: &generator)
        XCTAssertTrue(Greeter.all.contains(greeting))
    }

    /// A stale file naming a greeting that no longer exists must not wedge
    /// the picker into always returning the same thing.
    func testUnknownPreviousIsHarmless() {
        var generator = SeededGenerator(state: 7)
        var seen = Set<String>()
        for _ in 0..<200 {
            seen.insert(Greeter.pick(excluding: "a greeting from a past version", using: &generator).text)
        }
        XCTAssertEqual(seen.count, 20, "an unknown previous should exclude nothing")
    }

    /// Over many draws every greeting should show up - a picker that can
    /// only ever reach half the table is the failure worth catching.
    func testEveryGreetingIsReachable() {
        var generator = SeededGenerator(state: 0xC0FFEE)
        var seen = Set<String>()
        var previous: String?
        for _ in 0..<2000 {
            let greeting = Greeter.pick(excluding: previous, using: &generator)
            seen.insert(greeting.text)
            previous = greeting.text
        }
        XCTAssertEqual(seen.count, Greeter.all.count)
    }
}

extension GreeterTests {
    /// The off-switch, for anyone who would rather not explain a tsundere
    /// computer during a screen share.
    func testSuppressionEnvVar() {
        let saved = getenv("MSL_NO_GREETING").map { String(cString: $0) }
        defer {
            if let saved { setenv("MSL_NO_GREETING", saved, 1) } else { unsetenv("MSL_NO_GREETING") }
        }

        unsetenv("MSL_NO_GREETING")
        XCTAssertFalse(Greeter.isSuppressed)
        XCTAssertNotNil(Greeter.nextGreeting())

        setenv("MSL_NO_GREETING", "1", 1)
        XCTAssertTrue(Greeter.isSuppressed)
        XCTAssertNil(Greeter.nextGreeting(), "suppressed but still greeted")

        setenv("MSL_NO_GREETING", "0", 1)
        XCTAssertFalse(Greeter.isSuppressed, "only 1/true should suppress")
    }
}
