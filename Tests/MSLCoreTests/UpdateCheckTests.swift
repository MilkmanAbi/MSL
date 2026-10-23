import XCTest
@testable import MSLCore

final class UpdateCheckTests: XCTestCase {
    typealias V = UpdateCheck.Version
    typealias Decision = UpdateCheck.Decision

    private func decide(_ current: String, _ tags: [String],
                        skipped: String? = nil, silenced: Bool = false) -> Decision {
        UpdateCheck.decide(current: V(current)!, releases: UpdateCheck.releases(from: tags),
                           skipped: skipped, silenced: silenced)
    }

    // MARK: Versions

    func testVersionParsingAndOrder() {
        XCTAssertEqual(V("v1.0.0").map { [$0.major, $0.minor, $0.patch] }, [1, 0, 0])
        XCTAssertEqual(V("2.1")?.minor, 1)
        XCTAssertEqual(V("2.1")?.patch, 0, "a missing number is zero")
        XCTAssertNil(V("latest"))
        XCTAssertNil(V(""))
        XCTAssertNil(V("2.0.0.1"), "four numbers is not a semantic version")
        XCTAssertNil(V("2.x.0"))
        // GitHub's own repository id can fall out of a feed entry that is not
        // a release. Read as a version it beats everything ever published.
        XCTAssertNil(V("1374003283"), "a bare number is not a version")
        XCTAssertNil(V("2"))
        XCTAssertLessThan(V("1.9.9")!, V("2.0.0")!)
        XCTAssertLessThan(V("2.0.0-rc1")!, V("2.0.0")!)
        XCTAssertEqual(V("1.0")!, V("1.0.0")!)
        XCTAssertLessThan(V("1.2.10")!, V("1.10.0")!, "ten is not two")
        XCTAssertLessThan(V("2.0.0")!, V("2.0.1")!)
    }

    /// The installer package carries this string and `UpdateDownload` refuses
    /// one that doesn't match, so `v2.1` must still describe itself as 2.1.0.
    func testDescriptionIsAlwaysThreeNumbers() {
        XCTAssertEqual(V("v2.1")!.description, "2.1.0")
        XCTAssertEqual(V("v3.0.0-rc1")!.description, "3.0.0-rc1")
    }

    // MARK: Tags

    func testPlainTagsParse() {
        XCTAssertEqual(UpdateCheck.parse(tag: "v2.1.0")?.version, V("2.1.0")!)
        XCTAssertEqual(UpdateCheck.parse(tag: "2.1.0")?.tag, "2.1.0", "the v is optional")
        XCTAssertNil(UpdateCheck.parse(tag: "nightly"))
    }

    func testAnythingAfterAHyphenIsAPrerelease() {
        for tag in ["v2.5.0-rc1", "v2.5.0-beta", "v2.5.0-nightly", "v2.5.0-DNUO-2.0", "v2.5.0-UBP"] {
            let release = UpdateCheck.parse(tag: tag)
            XCTAssertNotNil(release, tag)
            XCTAssertFalse(release?.isStable ?? true, "\(tag) is a pre-release")
        }
        // And so none of them is ever offered - including the marker tags the
        // old update system used to understand. Simplifying the policy must
        // not make an old tag mean something new.
        XCTAssertEqual(decide("2.0.0", ["v2.5.0-UBP-2.1", "v3.0.0-rc1"]).kind, .upToDate)
    }

    // MARK: The policy

    func testBumpClassification() {
        let cases: [(String, String, UpdateCheck.Bump)] = [
            ("2.0.0", "2.0.1", .patch),
            ("2.0.0", "2.0.9", .patch),
            ("2.1.3", "2.1.4", .patch),
            ("2.0.0", "2.1.0", .minor),
            ("2.0.5", "2.1.0", .minor),
            ("2.0.0", "2.9.9", .minor),
            ("2.0.0", "3.0.0", .major),
            ("2.9.9", "3.0.1", .major),
            ("1.0.0", "3.4.5", .major),
        ]
        for (current, next, expected) in cases {
            XCTAssertEqual(UpdateCheck.Bump(from: V(current)!, to: V(next)!), expected,
                           "\(current) -> \(next)")
        }
    }

    /// The whole point of the simplification: a patch is found, but never
    /// raised on its own.
    func testPatchIsFoundButNotAnnounced() {
        let decision = decide("2.0.0", ["v2.0.1"])
        XCTAssertEqual(decision.kind, .update, "it is still an update")
        XCTAssertEqual(decision.bump, .patch)
        XCTAssertFalse(decision.announces, "a fix does not interrupt anyone")
        XCTAssertEqual(decision.release?.tag, "v2.0.1")
    }

    func testMinorIsAnnounced() {
        let decision = decide("2.0.0", ["v2.1.0"])
        XCTAssertEqual(decision.kind, .update)
        XCTAssertEqual(decision.bump, .minor)
        XCTAssertTrue(decision.announces)
        XCTAssertFalse(decision.bump!.readTheRepositoryFirst)
    }

    func testMajorIsAnnouncedAndPointsAtTheRepository() {
        let decision = decide("2.0.0", ["v3.0.0"])
        XCTAssertEqual(decision.bump, .major)
        XCTAssertTrue(decision.announces)
        XCTAssertTrue(decision.bump!.readTheRepositoryFirst)
        XCTAssertEqual(UpdateCheck.repositoryPage.absoluteString, "https://github.com/MilkmanAbi/MSL")
    }

    func testUpToDateAndOlderReleases() {
        XCTAssertEqual(decide("2.1.0", ["v2.1.0", "v2.0.0", "v1.0.0"]).kind, .upToDate)
        XCTAssertEqual(decide("2.1.0", []).kind, .upToDate)
        XCTAssertEqual(decide("3.0.0", ["v2.9.9"]).kind, .upToDate, "never offered a downgrade")
        XCTAssertNil(decide("2.1.0", ["v2.1.0"]).release)
        XCTAssertNil(decide("2.1.0", ["v2.1.0"]).bump)
    }

    func testHighestVersionWinsWhateverTheFeedOrder() {
        // The live OIS bug: the feed is newest-first by date, so a 1.0.9
        // patch published after 2.0.0 comes first in it.
        let decision = decide("1.0.0", ["v1.0.9", "v2.0.0", "v1.0.5"])
        XCTAssertEqual(decision.release?.tag, "v2.0.0")
        XCTAssertEqual(decision.bump, .major)
    }

    /// A release reissued under a second tag is one version, and which of the
    /// two tags gets reported must not depend on feed order - the person is
    /// pointed at that tag's info.txt.
    func testSameVersionTwoTagsIsDecidedNotLeftToTheFeed() {
        let forward = decide("2.0.0", ["v2.1.0", "v2.1"])
        let backward = decide("2.0.0", ["v2.1", "v2.1.0"])
        XCTAssertEqual(forward.release?.tag, backward.release?.tag)
    }

    // MARK: Someone's own choices

    func testSilenceQuietsTheNoticeButNotTheRelease() {
        let decision = decide("2.0.0", ["v2.1.0"], silenced: true)
        XCTAssertEqual(decision.kind, .update, "the release still exists when asked about")
        XCTAssertEqual(decision.release?.tag, "v2.1.0")
        XCTAssertFalse(decision.announces)
    }

    func testSkipIsByVersionNotByTag() {
        XCTAssertFalse(decide("2.0.0", ["v2.1.0"], skipped: "v2.1.0").announces)
        XCTAssertFalse(decide("2.0.0", ["v2.1.0"], skipped: "2.1").announces,
                       "the same version, spelled differently")
        XCTAssertTrue(decide("2.0.0", ["v2.2.0"], skipped: "v2.1.0").announces,
                      "skipping one version is not skipping the next")
        XCTAssertFalse(decide("2.0.0", ["v3.0.0"], skipped: "v3.0.0").announces,
                       "a skip holds for a major version too - it was asked for")
    }

    func testNonsenseSkipIsIgnored() {
        XCTAssertTrue(decide("2.0.0", ["v2.1.0"], skipped: "latest").announces)
        XCTAssertTrue(decide("2.0.0", ["v2.1.0"], skipped: "").announces)
    }

    // MARK: Feeds

    func testAtomFeedParsing() {
        // The shape of the real thing, feed-level <id> and all.
        let feed = """
        <feed><id>tag:github.com,2008:https://github.com/MilkmanAbi/MSL/releases</id>
        <entry><id>tag:github.com,2008:Repository/1374003283/v2.1.0</id></entry>
        <entry><id>tag:github.com,2008:Repository/1374003283/v2.0.0</id></entry>
        <entry><id>tag:github.com,2008:Repository/1374003283/v3.0.0-rc1</id></entry></feed>
        """
        XCTAssertEqual(UpdateCheck.tags(inAtom: feed), ["v2.1.0", "v2.0.0", "v3.0.0-rc1"])
        let decision = decide("2.0.0", UpdateCheck.tags(inAtom: feed))
        XCTAssertEqual(decision.release?.tag, "v2.1.0", "the rc is read and not offered")

        // And if a feed ever did leave the repository id behind as a "tag",
        // it must not become version 1.37 billion.
        let strayID = "<feed><id>tag:github.com,2008:Repository/1374003283</id>"
            + "<entry><id>tag:github.com,2008:Repository/1374003283/v2.1.0</id></entry></feed>"
        XCTAssertEqual(UpdateCheck.tags(inAtom: strayID), ["1374003283", "v2.1.0"])
        XCTAssertEqual(decide("2.0.0", UpdateCheck.tags(inAtom: strayID)).release?.tag, "v2.1.0")
    }

    func testJSONFeedParsing() throws {
        let many = Data(#"[{"tag_name":"v2.1.0"},{"tag_name":"v2.0.0"}]"#.utf8)
        XCTAssertEqual(UpdateCheck.tags(inJSON: many), ["v2.1.0", "v2.0.0"])
        let one = Data(#"{"tag_name":"v2.2.0"}"#.utf8)
        XCTAssertEqual(UpdateCheck.tags(inJSON: one), ["v2.2.0"])
        XCTAssertEqual(UpdateCheck.tags(inJSON: Data("not json".utf8)), [])
    }

    func testDuplicateTagsCollapse() {
        XCTAssertEqual(UpdateCheck.releases(from: ["v2.1.0", "v2.1.0"]).count, 1)
    }

    // MARK: Throttle

    func testThrottleAndBackoff() {
        let now = Date()
        var state = UpdateCheck.State()
        XCTAssertTrue(UpdateCheck.isDue(state, now: now))
        state.lastCheck = now.addingTimeInterval(-3_600)
        XCTAssertFalse(UpdateCheck.isDue(state, now: now))
        state.lastCheck = now.addingTimeInterval(-90_000)
        XCTAssertTrue(UpdateCheck.isDue(state, now: now))

        var backed = UpdateCheck.backedOff(UpdateCheck.State(), now: now)
        XCTAssertEqual(backed.backoffUntil?.timeIntervalSince(now), 3_600)
        XCTAssertFalse(UpdateCheck.isDue(backed, now: now))
        for _ in 0..<10 { backed = UpdateCheck.backedOff(backed, now: now) }
        XCTAssertEqual(backed.backoffUntil?.timeIntervalSince(now), 86_400, "capped at a day")
    }

    func testStateSurvivesEncoding() throws {
        var state = UpdateCheck.State()
        state.silenced = true
        state.skippedTag = "v2.1.0"
        state.lastCheck = Date(timeIntervalSince1970: 1)
        let back = try JSONDecoder().decode(UpdateCheck.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
    }

    /// State written by the old marker-based updater has to decode, or the
    /// first launch after updating silently forgets someone's choices.
    func testStateFromTheOldUpdaterStillDecodes() throws {
        let old = Data(#"{"silenced":true,"backoffCount":2,"skippedTag":"v2.1.0-FP-2.0"}"#.utf8)
        let state = try JSONDecoder().decode(UpdateCheck.State.self, from: old)
        XCTAssertTrue(state.silenced)
        XCTAssertEqual(state.backoffCount, 2)
        // The skip was recorded against a tag that is now a pre-release, so
        // it simply no longer matches anything - it does not crash and does
        // not hide a real release.
        XCTAssertTrue(decide("2.0.0", ["v2.1.0"], skipped: state.skippedTag).announces)
    }

    func testInfoURLPerRelease() {
        XCTAssertEqual(UpdateCheck.infoURL(for: "v2.1.0")?.absoluteString,
                       "https://github.com/MilkmanAbi/MSL/releases/download/v2.1.0/info.txt")
    }

    func testReleasePages() {
        let release = UpdateCheck.parse(tag: "v2.1.0")!
        XCTAssertEqual(release.page.absoluteString,
                       "https://github.com/MilkmanAbi/MSL/releases/tag/v2.1.0")
        XCTAssertEqual(UpdateCheck.releasesPage.absoluteString,
                       "https://github.com/MilkmanAbi/MSL/releases/latest")
    }
}

// MARK: - Stress

extension UpdateCheckTests {
    /// Thousands of random release sets against random installed versions,
    /// checking the rules that must hold no matter what is published. A real
    /// tag list is messy - reissued tags, pre-releases, versions that never
    /// shipped - and the cost of getting this wrong is recommending an update
    /// to someone who should not be offered one.
    func testDecisionInvariantsUnderRandomReleaseSets() {
        var generator = SystemRandomNumberGenerator()
        let suffixes = ["", "", "", "-rc1", "-beta2", "-UBP-2.0"]
        // Junk a feed can hand us, which must never be offered.
        let junk = ["latest", "1374003283", "nightly", "v2.0.0.1"]

        for iteration in 0..<3_000 {
            let current = V("\(Int.random(in: 1...3, using: &generator)).\(Int.random(in: 0...4, using: &generator)).\(Int.random(in: 0...4, using: &generator))")!
            var tags: [String] = []
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                let major = Int.random(in: 1...4, using: &generator)
                let minor = Int.random(in: 0...5, using: &generator)
                let patch = Int.random(in: 0...5, using: &generator)
                tags.append("v\(major).\(minor).\(patch)\(suffixes.randomElement(using: &generator)!)")
            }
            if Bool.random(using: &generator) { tags.append(junk.randomElement(using: &generator)!) }
            let releases = UpdateCheck.releases(from: tags)
            let skipped = Bool.random(using: &generator) ? tags.randomElement(using: &generator) : nil
            let silenced = Bool.random(using: &generator)
            let decision = UpdateCheck.decide(current: current, releases: releases,
                                              skipped: skipped, silenced: silenced)
            let context = "iteration \(iteration): \(current) against \(tags), skipped \(skipped ?? "-"), silenced \(silenced)"

            // 1. Never a downgrade, never a sideways move, never a pre-release.
            if let offered = decision.release {
                XCTAssertGreaterThan(offered.version, current, "offered something not newer. \(context)")
                XCTAssertTrue(offered.isStable, "offered a pre-release. \(context)")
                XCTAssertEqual(decision.kind, .update, context)
            } else {
                XCTAssertEqual(decision.kind, .upToDate, context)
                XCTAssertNil(decision.bump, context)
                XCTAssertFalse(decision.announces, context)
            }

            // 2. If any stable release is newer, one is offered - a release
            //    is never lost, whatever the person silenced.
            let newest = releases.filter { $0.isStable && $0.version > current }.map(\.version).max()
            XCTAssertEqual(decision.release?.version, newest, "the offer is the highest. \(context)")

            // 3. The bump matches the offer.
            if let offered = decision.release {
                XCTAssertEqual(decision.bump, UpdateCheck.Bump(from: current, to: offered.version), context)
            }

            // 4. A patch is never announced; silence and a skip never add a
            //    notice; nothing is announced without a release.
            if decision.bump == .patch { XCTAssertFalse(decision.announces, "a patch was announced. \(context)") }
            if silenced { XCTAssertFalse(decision.announces, "silenced but announced. \(context)") }
            if decision.announces {
                XCTAssertNotNil(decision.release, context)
                XCTAssertTrue(decision.bump?.isWorthInterrupting ?? false, context)
            }

            // 5. The decision does not depend on the order the feed listed
            //    them in.
            let shuffled = UpdateCheck.decide(current: current, releases: releases.shuffled(using: &generator),
                                              skipped: skipped, silenced: silenced)
            XCTAssertEqual(shuffled, decision, "feed order changed the answer. \(context)")
        }
    }
}
