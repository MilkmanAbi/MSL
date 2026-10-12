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
        XCTAssertEqual(V("v1.0.0")?.numbers, [1, 0, 0])
        XCTAssertEqual(V("2.1")?.major, 2)
        XCTAssertNil(V("latest"))
        XCTAssertLessThan(V("1.9.9")!, V("2.0.0")!)
        XCTAssertLessThan(V("2.0.0-rc1")!, V("2.0.0")!)
        XCTAssertEqual(V("1.0")!, V("1.0.0")!)
        XCTAssertLessThan(V("1.2.10")!, V("1.10.0")!)
        XCTAssertLessThan(V("2.0.0")!, V("2.0.1")!)
    }

    // MARK: Tag grammar

    func testEveryMarkerParses() {
        let cases: [(String, UpdateCheck.Marker.Kind, String?)] = [
            ("v2.1.0", .plain, nil),
            ("v2.1.0-DNUO-2.0", .doNotUpdateOlder, "2.0"),
            ("v2.1.0-UBP-2.0", .unsafePatch, "2.0"),
            ("v2.1.0-UBPDN-2.0", .unsafePatchNewOnly, "2.0"),
            ("v2.1.0-FP-2.0", .featurePatch, "2.0"),
            ("v2.1.0-FBDN-2.0", .featurePatchNewOnly, "2.0"),
            ("v2.1.0-ubp-2.0", .unsafePatch, "2.0"),      // case insensitive
            ("v2.1.0-UBP", .unsafePatch, nil),            // no floor = everyone
        ]
        for (tag, kind, minimum) in cases {
            guard let release = UpdateCheck.parse(tag: tag) else { return XCTFail("did not parse \(tag)") }
            XCTAssertEqual(release.marker.kind, kind, tag)
            XCTAssertEqual(release.marker.minimum, minimum.flatMap(V.init), tag)
            XCTAssertTrue(release.isStable, "\(tag) is a real release, not a pre-release")
            XCTAssertEqual(release.version, V("2.1.0"), tag)
            XCTAssertEqual(release.tag, tag, "the tag is kept verbatim - it is the download URL")
        }
    }

    /// A marker suffix must not be mistaken for a pre-release: that would sort
    /// `v2.1.0-UBP-2.0` *below* `v2.1.0` and hide every marked release.
    func testMarkedReleasesOutrankTheirPlainVersion() {
        let marked = UpdateCheck.parse(tag: "v2.1.0-UBP-2.0")!
        XCTAssertEqual(marked.version, V("2.1.0")!)
        XCTAssertFalse(marked.version < V("2.1.0")!)
    }

    func testPreReleasesAndNonsenseAreNeverOffered() {
        for tag in ["v2.5.0-rc1", "v2.5.0-beta", "v2.5.0-nightly", "v2.5.0-DNUO"] {
            let release = UpdateCheck.parse(tag: tag)
            XCTAssertNotNil(release, "\(tag) should still parse so it can be reported")
            XCTAssertFalse(release!.isStable, "\(tag) must never be offered")
            XCTAssertFalse(release!.isEligible(for: V("2.0.0")!), tag)
        }
        XCTAssertNil(UpdateCheck.parse(tag: "latest"))
        XCTAssertNil(UpdateCheck.parse(tag: ""))
    }

    /// The feed is newest-first by date, not by version - a live OIS bug.
    func testHighestVersionWinsNotTheFirstEntry() {
        let feed = """
        <feed><id>tag:github.com,2008:https://github.com/MilkmanAbi/MSL/releases</id>
        <entry><id>tag:github.com,2008:Repository/1/v2.0.9</id></entry>
        <entry><id>tag:github.com,2008:Repository/1/v3.0.0-rc1</id></entry>
        <entry><id>tag:github.com,2008:Repository/1/v2.2.0</id></entry>
        </feed>
        """
        XCTAssertEqual(UpdateCheck.tags(inAtom: feed), ["v2.0.9", "v3.0.0-rc1", "v2.2.0"])
        let decision = decide("2.0.0", UpdateCheck.tags(inAtom: feed))
        XCTAssertEqual(decision.release?.tag, "v2.2.0")
    }

    func testJSONFallbackTakesBothShapes() {
        XCTAssertEqual(UpdateCheck.tags(inJSON: Data(#"{"tag_name":"v1.0.0"}"#.utf8)), ["v1.0.0"])
        XCTAssertEqual(UpdateCheck.tags(inJSON: Data(#"[{"tag_name":"v2.0.0"},{"tag_name":"v2.1.0"}]"#.utf8)),
                       ["v2.0.0", "v2.1.0"])
        XCTAssertEqual(UpdateCheck.tags(inJSON: Data("not json".utf8)), [])
    }

    // MARK: The decision table

    /// The headline rule: a mini release is an update, not something to sit on.
    func testAnyNewerStableReleaseIsOffered() {
        for tag in ["v2.1.0", "v2.0.1", "v3.0.0"] {
            let decision = decide("2.0.0", [tag])
            XCTAssertEqual(decision.kind, .update, tag)
            XCTAssertEqual(decision.release?.tag, tag)
            XCTAssertFalse(decision.urgent, tag)
        }
        XCTAssertEqual(decide("2.0.0", ["v2.0.0", "v1.9.0"]).kind, .upToDate)
    }

    func testMinimumVersionWallsOffOlderInstalls() {
        for marker in ["DNUO", "UBP", "UBPDN", "FP", "FBDN"] {
            let tag = "v2.5.0-\(marker)-2.1"
            XCTAssertEqual(decide("2.1.0", [tag]).release?.tag, tag, "2.1 is at the floor: \(marker)")
            XCTAssertEqual(decide("2.4.0", [tag]).release?.tag, tag, "above the floor: \(marker)")
            XCTAssertNil(decide("2.0.0", [tag]).release?.tag.contains("v2.5.0") == true && decide("2.0.0", [tag]).kind == .update
                         ? "offered" : nil, "below the floor must not be offered: \(marker)")
        }
    }

    /// The whole difference between UBP and UBPDN (and FP and FBDN).
    func testBelowTheFloorOnlyTheNonDNMarkersSpeakUp() {
        let ubp = decide("2.0.0", ["v2.5.0-UBP-2.1"])
        XCTAssertEqual(ubp.kind, .advisory, "an unreachable safety fix is still worth saying once")
        XCTAssertTrue(ubp.urgent)
        XCTAssertEqual(ubp.release?.tag, "v2.5.0-UBP-2.1")

        XCTAssertEqual(decide("2.0.0", ["v2.5.0-UBPDN-2.1"]).kind, .upToDate, "DN: say nothing")
        XCTAssertEqual(decide("2.0.0", ["v2.5.0-DNUO-2.1"]).kind, .upToDate, "DN: say nothing")

        let fp = decide("2.0.0", ["v2.5.0-FP-2.1"])
        XCTAssertEqual(fp.kind, .upToDate, "a feature they cannot take is not a prompt")
        XCTAssertEqual(fp.alsoAvailable.map(\.tag), ["v2.5.0-FP-2.1"], "but it is mentionable")
        XCTAssertTrue(decide("2.0.0", ["v2.5.0-FBDN-2.1"]).alsoAvailable.isEmpty, "DN: not even mentioned")
    }

    func testUnsafePatchIsUrgentEvenAsAPatchBump() {
        let decision = decide("2.0.0", ["v2.0.1-UBP-2.0"])
        XCTAssertEqual(decision.kind, .update)
        XCTAssertTrue(decision.urgent)
    }

    /// Jumping 2.0 -> 2.3 carries 2.1's safety fix with it.
    func testUrgencyCarriesThroughTheWholeJump() {
        let decision = decide("2.0.0", ["v2.1.0-UBP-2.0", "v2.2.0", "v2.3.0"])
        XCTAssertEqual(decision.release?.tag, "v2.3.0", "still offers the newest")
        XCTAssertTrue(decision.urgent, "because the jump includes the unsafe-behaviour patch")
    }

    func testSilenceAndSkipAreObeyedExceptByUnsafePatches() {
        XCTAssertEqual(decide("2.0.0", ["v2.1.0"], silenced: true).kind, .suppressed)
        XCTAssertEqual(decide("2.0.0", ["v2.1.0"], skipped: "v2.1.0").kind, .suppressed)
        // A later release than the skipped one is still offered.
        XCTAssertEqual(decide("2.0.0", ["v2.1.0", "v2.2.0"], skipped: "v2.1.0").kind, .update)

        for suppression in [("silenced", true), ("skipped", false)] {
            let decision = decide("2.0.0", ["v2.1.0-UBP-2.0"],
                                  skipped: suppression.1 ? nil : "v2.1.0-UBP-2.0", silenced: suppression.1)
            XCTAssertEqual(decision.kind, .update, "unsafe patches ignore \(suppression.0)")
            XCTAssertTrue(decision.urgent)
        }
        XCTAssertEqual(decide("2.0.0", ["v2.5.0-UBP-2.1"], silenced: true).kind, .upToDate,
                       "silence does suppress the advisory - there is nothing to act on")
    }

    /// Two tags can carry the same version when a release is reissued with a
    /// marker. Whichever the feed lists first, the answer must not change.
    func testSameVersionTwiceIsResolvedDeterministically() {
        let tags = ["v2.1.0", "v2.1.0-UBP-2.0"]
        let forward = decide("2.0.0", tags), backward = decide("2.0.0", tags.reversed())
        XCTAssertEqual(forward.release?.tag, backward.release?.tag)
        XCTAssertEqual(forward.release?.tag, "v2.1.0-UBP-2.0", "the safety patch is the one to point at")
        XCTAssertTrue(forward.urgent)
        // And skipping one form skips the version, not just that spelling.
        XCTAssertEqual(decide("2.0.0", ["v2.1.0", "v2.1.0-FP-2.0"], skipped: "v2.1.0").kind, .suppressed)
    }

    func testAlsoAvailableNeverIncludesWhatWasOffered() {
        let decision = decide("2.0.0", ["v2.1.0", "v2.9.0-FP-2.5"])
        XCTAssertEqual(decision.release?.tag, "v2.1.0")
        XCTAssertEqual(decision.alsoAvailable.map(\.tag), ["v2.9.0-FP-2.5"])
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
        state.skippedTag = "v2.1.0-FP-2.0"
        state.lastCheck = Date(timeIntervalSince1970: 1)
        let back = try JSONDecoder().decode(UpdateCheck.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
    }

    func testInfoURLPerRelease() {
        XCTAssertEqual(UpdateCheck.infoURL(for: "v2.1.0-UBP-2.0")?.absoluteString,
                       "https://github.com/MilkmanAbi/MSL/releases/download/v2.1.0-UBP-2.0/info.txt")
    }
}

// MARK: - Stress

extension UpdateCheckTests {
    /// Thousands of random release sets against random installed versions,
    /// checking the rules that must hold no matter what is published. A real
    /// tag list is messy - reissued tags, pre-releases, markers pointing at
    /// versions that never shipped - and the cost of getting this wrong is
    /// recommending an update that bricks someone's install.
    func testDecisionInvariantsUnderRandomReleaseSets() {
        var generator = SystemRandomNumberGenerator()
        let markers = ["", "-DNUO-", "-UBP-", "-UBPDN-", "-FP-", "-FBDN-"]
        for iteration in 0..<3_000 {
            let current = V("\(Int.random(in: 1...4)).\(Int.random(in: 0...4)).\(Int.random(in: 0...4))")!
            var tags: [String] = []
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                let version = "\(Int.random(in: 1...5)).\(Int.random(in: 0...5)).\(Int.random(in: 0...5))"
                switch markers.randomElement(using: &generator)! {
                case "":
                    tags.append(Bool.random() ? "v\(version)" : "v\(version)-rc\(Int.random(in: 1...3))")
                case let marker:
                    tags.append("v\(version)\(marker)\(Int.random(in: 1...5)).\(Int.random(in: 0...5))")
                }
            }
            let releases = UpdateCheck.releases(from: tags)
            let skipped = Bool.random(using: &generator) ? tags.randomElement(using: &generator) : nil
            let silenced = Bool.random(using: &generator)
            let decision = UpdateCheck.decide(current: current, releases: releases,
                                              skipped: skipped, silenced: silenced)
            let context = "iteration \(iteration): current=\(current) tags=\(tags) skipped=\(skipped ?? "-") silenced=\(silenced)"

            if let offered = decision.release, decision.kind == .update {
                XCTAssertTrue(offered.isStable, "offered a pre-release. \(context)")
                XCTAssertTrue(offered.version > current, "offered something not newer. \(context)")
                if let minimum = offered.minimum {
                    XCTAssertTrue(current >= minimum, "offered a release below its minimum. \(context)")
                }
                let best = releases.filter { $0.isEligible(for: current) }.map(\.version).max()
                XCTAssertEqual(offered.version, best, "offered something other than the newest eligible. \(context)")
            }

            if decision.kind == .advisory {
                XCTAssertTrue(decision.urgent, "only unsafe-behaviour patches get an advisory. \(context)")
                XCTAssertTrue(decision.release?.marker.kind == .unsafePatch, "advisory from a DN marker. \(context)")
                XCTAssertFalse(silenced, "advisory while silenced. \(context)")
                XCTAssertTrue(releases.filter { $0.isEligible(for: current) }.isEmpty,
                              "advisory although something was installable. \(context)")
            }

            // No DN-marked release below its minimum may surface anywhere.
            for release in [decision.release].compactMap({ $0 }) + decision.alsoAvailable {
                if let minimum = release.minimum, current < minimum {
                    XCTAssertTrue(release.marker.mentionsBelowMinimum,
                                  "a DN release surfaced to an older install. \(context)")
                }
            }
            for mentioned in decision.alsoAvailable {
                XCTAssertFalse(mentioned.isEligible(for: current), "mentioned something installable. \(context)")
                XCTAssertTrue(mentioned.version > current, "mentioned something not newer. \(context)")
            }

            // An installable unsafe-behaviour patch always wins through.
            let urgentEligible = releases.contains { $0.isEligible(for: current) && $0.marker.isUrgent }
            if urgentEligible {
                XCTAssertEqual(decision.kind, .update, "an unsafe patch was suppressed. \(context)")
                XCTAssertTrue(decision.urgent, "an installable unsafe patch was not urgent. \(context)")
            }
            if decision.kind == .suppressed {
                XCTAssertFalse(decision.urgent, "urgent decisions are never suppressed. \(context)")
            }

            // Order in the feed must not change the answer.
            let shuffled = UpdateCheck.decide(current: current, releases: releases.shuffled(using: &generator),
                                              skipped: skipped, silenced: silenced)
            XCTAssertEqual(shuffled.kind, decision.kind, "feed order changed the outcome. \(context)")
            XCTAssertEqual(shuffled.release?.tag, decision.release?.tag, "feed order changed the offer. \(context)")
        }
    }

    /// The upgrade path someone actually walks, release by release.
    func testWalkingAReleaseHistoryEndsUpOnTheNewest() {
        let published = ["v2.0.0", "v2.0.1-UBP-2.0", "v2.1.0", "v2.2.0-FP-2.1",
                         "v2.3.0-DNUO-2.2", "v2.4.0-UBPDN-2.3", "v3.0.0-rc1"]
        var current = V("1.9.0")!
        var offers: [String] = []
        for _ in 0..<10 {
            let decision = UpdateCheck.decide(current: current, releases: UpdateCheck.releases(from: published))
            guard decision.kind == .update, let release = decision.release else { break }
            offers.append(release.tag)
            current = release.version
        }
        // 1.9 may only take 2.1.0 (2.2's floor is 2.1), and each step opens the next floor.
        // v2.0.1-UBP-2.0 is never offered: by the time the floor is cleared it is already older.
        XCTAssertEqual(offers, ["v2.1.0", "v2.2.0-FP-2.1", "v2.3.0-DNUO-2.2", "v2.4.0-UBPDN-2.3"],
                       "each step takes the newest it is allowed, then the floors open up one by one")
        XCTAssertEqual(current, V("2.4.0")!)
        XCTAssertEqual(UpdateCheck.decide(current: current, releases: UpdateCheck.releases(from: published)).kind,
                       .upToDate, "and then it stops - the only thing left is a pre-release")
    }
}
