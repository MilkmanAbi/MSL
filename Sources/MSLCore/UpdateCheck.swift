import Foundation

/// "Is there a newer MSL, and is it one *this* copy should be told about?"
///
/// Releases are git tags on `MilkmanAbi/MSL`, and a tag can carry a marker
/// saying who the release is for. The full grammar, the decision table and
/// the publishing checklist live in `READMES/22-UPDATE-SYSTEM.md`; the short
/// version is
///
///     v<major>.<minor>.<patch>[-<MARKER>[-<minimum>]]
///
/// | marker  | means                                    | below the minimum      |
/// |---------|------------------------------------------|------------------------|
/// | (none)  | ordinary release                         | -                      |
/// | DNUO    | do not update older installs             | never mentioned        |
/// | UBP     | unsafe-behaviour patch, offer at once    | mentioned, can't take  |
/// | UBPDN   | unsafe-behaviour patch, newer installs   | never mentioned        |
/// | FP      | feature patch                            | mentioned, can't take  |
/// | FBDN    | feature patch, newer installs only       | never mentioned        |
///
/// `minimum` is the oldest MSL the release may be recommended to, so
/// `v2.4.0-UBP-2.1` is an urgent patch for anyone on 2.1 or newer and is
/// merely mentioned to anyone older (it cannot help them - it patches
/// something 2.1 introduced).
///
/// The mechanics are OneInstallSystem's (github.com/MilkmanAbi/OneInstallSystem),
/// which already learned these the hard way:
/// - **the releases.atom feed, not the API**: no rate limit, no auth; the
///   REST API (60/hour anonymous) is only the fallback;
/// - **every tag, highest version wins**: the feed is newest-first by *date*,
///   so a 1.0.9 patch published after 2.0.0 comes first, and taking the first
///   entry was a live OIS bug;
/// - **a 24-hour TTL and a persisted backoff** (1h, doubling, capped at 24h)
///   after an HTTP error, so a launch-heavy app never hammers GitHub.
///
/// **This file only ever decides.** It never downloads and never removes
/// anything - `UpdateDownload` fetches and verifies the package a decision
/// chose, and `UpdateHandoff` replaces the installed copy, in that order and
/// only after an explicit click. Keeping the policy free of the plumbing is
/// what lets `decide` be a pure function the tests can cover exhaustively.
public enum UpdateCheck {
    public static let repository = "MilkmanAbi/MSL"
    public static let ttl: TimeInterval = 86_400

    // MARK: - Versions

    /// A dotted version with an optional pre-release suffix: `v2.1.0-rc1`.
    /// Marker suffixes are *not* pre-release suffixes - see `Release`.
    public struct Version: Comparable, Equatable, Sendable, CustomStringConvertible {
        public let numbers: [Int]
        public let prerelease: String

        public init?(_ text: String) {
            var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.first == "v" || body.first == "V" { body.removeFirst() }
            let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let core = parts.first, !core.isEmpty else { return nil }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            self.numbers = numbers.map { $0! }
            self.prerelease = parts.count > 1 ? String(parts[1]) : ""
        }

        init(numbers: [Int], prerelease: String = "") {
            self.numbers = numbers
            self.prerelease = prerelease
        }

        public var major: Int { numbers.first ?? 0 }
        public var minor: Int { numbers.count > 1 ? numbers[1] : 0 }
        public var isStable: Bool { prerelease.isEmpty }
        public var description: String {
            numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-\(prerelease)")
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.numbers.count, rhs.numbers.count)
            for index in 0..<count {
                let a = index < lhs.numbers.count ? lhs.numbers[index] : 0
                let b = index < rhs.numbers.count ? rhs.numbers[index] : 0
                if a != b { return a < b }
            }
            // 2.0.0-rc1 comes before 2.0.0.
            if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
            return lhs.prerelease < rhs.prerelease
        }

        public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    }

    // MARK: - Tag markers

    public struct Marker: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case plain = ""
            /// Do Not Update Older: only for installs at or above the minimum.
            case doNotUpdateOlder = "DNUO"
            /// Unsafe Behaviour Patch: offered at once, even for a patch bump.
            case unsafePatch = "UBP"
            /// Unsafe Behaviour Patch, newer installs only.
            case unsafePatchNewOnly = "UBPDN"
            /// Feature Patch.
            case featurePatch = "FP"
            /// Feature Patch, newer installs only.
            case featurePatchNewOnly = "FBDN"
        }

        public var kind: Kind
        /// Oldest MSL this release may be recommended to. `nil` = everyone.
        public var minimum: Version?

        public init(kind: Kind, minimum: Version? = nil) {
            self.kind = kind
            self.minimum = minimum
        }

        public static let plain = Marker(kind: .plain)

        /// Worth interrupting someone for, whatever the version bump is, and
        /// the one thing that outranks "skip this version" and "silence".
        public var isUrgent: Bool { kind == .unsafePatch || kind == .unsafePatchNewOnly }

        /// Whether an install *below* the minimum may be told this release
        /// exists (it still cannot be offered it). The DN kinds say no, which
        /// is the whole difference between UBP and UBPDN, FP and FBDN.
        public var mentionsBelowMinimum: Bool { kind == .unsafePatch || kind == .featurePatch }

        /// `UBP-2.1` -> the marker. `nil` when the suffix is not a marker at
        /// all (`rc1`, `beta2`), which makes the tag a pre-release.
        public init?(suffix: String) {
            let bits = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = bits.first, let kind = Kind(rawValue: String(name).uppercased()), kind != .plain else { return nil }
            var minimum: Version?
            if bits.count > 1 {
                guard let parsed = Version(String(bits[1])), parsed.isStable else { return nil }
                minimum = parsed
            }
            // "Do not update older" than nothing in particular is meaningless;
            // a DNUO tag without a minimum is a typo, not a release rule.
            if kind == .doNotUpdateOlder, minimum == nil { return nil }
            self.init(kind: kind, minimum: minimum)
        }

        public var label: String {
            switch kind {
            case .plain: return "release"
            case .doNotUpdateOlder: return "release (newer installs only)"
            case .unsafePatch, .unsafePatchNewOnly: return "unsafe-behaviour patch"
            case .featurePatch, .featurePatchNewOnly: return "feature patch"
            }
        }
    }

    // MARK: - Releases

    public struct Release: Equatable, Sendable {
        public let tag: String
        public let version: Version
        public let marker: Marker

        public init(tag: String, version: Version, marker: Marker = .plain) {
            self.tag = tag
            self.version = version
            self.marker = marker
        }

        public var isStable: Bool { version.isStable }
        public var minimum: Version? { marker.minimum }

        /// Newer than `current`, stable, and not walled off by a minimum.
        public func isEligible(for current: Version) -> Bool {
            guard isStable, version > current else { return false }
            guard let minimum else { return true }
            return current >= minimum
        }

        public var page: URL {
            URL(string: "https://github.com/\(UpdateCheck.repository)/releases/tag/\(tag)") ?? UpdateCheck.releasesPage
        }
    }

    /// One tag. Pre-releases parse too (with `isStable == false`) so they can
    /// be reported and then ignored, rather than silently vanishing.
    public static func parse(tag raw: String) -> Release? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = tag
        guard !body.isEmpty else { return nil }
        if body.first == "v" || body.first == "V" { body.removeFirst() }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, let version = Version(String(core)), version.isStable else { return nil }
        guard parts.count > 1, !parts[1].isEmpty else {
            return Release(tag: tag, version: version)
        }
        let suffix = String(parts[1])
        if let marker = Marker(suffix: suffix) {
            return Release(tag: tag, version: version, marker: marker)
        }
        // Not a marker: an ordinary pre-release tag, never offered.
        return Release(tag: tag, version: Version(numbers: version.numbers, prerelease: suffix))
    }

    /// Tags out of a GitHub releases.atom feed:
    /// `<id>tag:github.com,2008:Repository/NNN/TAG</id>`.
    public static func tags(inAtom feed: String) -> [String] {
        var tags: [String] = []
        var rest = feed[...]
        while let open = rest.range(of: "<id>"), let close = rest.range(of: "</id>", range: open.upperBound..<rest.endIndex) {
            let id = rest[open.upperBound..<close.lowerBound]
            if id.contains("Repository/"), let slash = id.lastIndex(of: "/") {
                let tag = String(id[id.index(after: slash)...])
                if !tag.isEmpty { tags.append(tag) }
            }
            rest = rest[close.upperBound...]
        }
        return tags
    }

    /// `tag_name`s out of the REST API - either `releases` (an array) or
    /// `releases/latest` (one object).
    public static func tags(inJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let one = root as? [String: Any], let tag = one["tag_name"] as? String { return [tag] }
        guard let many = root as? [[String: Any]] else { return [] }
        return many.compactMap { $0["tag_name"] as? String }
    }

    public static func releases(from tags: [String]) -> [Release] {
        var seen = Set<String>()
        return tags.compactMap(parse(tag:)).filter { seen.insert($0.tag).inserted }
    }

    // MARK: - The decision

    public struct Decision: Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// Offer `release`.
            case update
            /// A release exists that this install is too old for, and whose
            /// marker allows saying so. Nothing to install.
            case advisory
            /// There is an update, but the person silenced updates or skipped
            /// this version, and it is not urgent.
            case suppressed
            case upToDate
            /// The check could not be made (offline, GitHub said no).
            case unknown
        }

        public var kind: Kind
        public var release: Release?
        /// An unsafe-behaviour patch is in the offer: interrupt, and ignore
        /// "skip this version" and "silence updates".
        public var urgent: Bool
        /// Newer releases this install cannot take but may be told about
        /// (UBP/FP below their minimum) - never the DN kinds.
        public var alsoAvailable: [Release]

        public init(kind: Kind, release: Release? = nil, urgent: Bool = false, alsoAvailable: [Release] = []) {
            self.kind = kind
            self.release = release
            self.urgent = urgent
            self.alsoAvailable = alsoAvailable
        }

        public var shouldPrompt: Bool { kind == .update || kind == .advisory }
    }

    /// The whole policy, as one pure function - every rule in the table above
    /// is decided here and nowhere else, so the tests cover the real thing.
    public static func decide(current: Version, releases: [Release],
                              skipped: String? = nil, silenced: Bool = false) -> Decision {
        let candidates = releases.filter { $0.isStable && $0.version > current }
        let eligible = candidates.filter { $0.isEligible(for: current) }
        // Out of reach, but allowed to be mentioned.
        let mentionable = candidates
            .filter { !$0.isEligible(for: current) && $0.marker.mentionsBelowMinimum }
            .sorted { isOutranked($1, $0) }

        guard let offer = eligible.max(by: isOutranked) else {
            // Nothing installable. An unsafe-behaviour patch that says it may
            // be mentioned still gets said out loud once, because "you are too
            // old for the safety fix" is worth knowing.
            if let advisory = mentionable.first(where: { $0.marker.isUrgent }), !silenced {
                return Decision(kind: .advisory, release: advisory, urgent: true,
                                alsoAvailable: Array(mentionable.dropFirst()))
            }
            return Decision(kind: .upToDate, alsoAvailable: mentionable)
        }

        // Every eligible release up to and including the offer ships in the
        // same jump, so one unsafe-behaviour patch anywhere in that range
        // makes the whole update urgent.
        let urgent = eligible.contains { $0.marker.isUrgent }
        if !urgent {
            if silenced { return Decision(kind: .suppressed, release: offer, alsoAvailable: mentionable) }
            // Matched by version, not by tag: "Skip This Version" means the
            // version, and a re-tagged release (`v2.1.0` reissued as
            // `v2.1.0-FP-2.0`) is the same version, not a new offer.
            if let skipped, let version = Version(skipped), version == offer.version {
                return Decision(kind: .suppressed, release: offer, alsoAvailable: mentionable)
            }
        }
        return Decision(kind: .update, release: offer, urgent: urgent, alsoAvailable: mentionable)
    }

    /// A total order over releases, so the offer never depends on the order
    /// the feed happened to list them in. Two tags can carry the *same*
    /// version - a release reissued with a marker - and picking "the newest"
    /// alone left that tie to the feed (caught by the randomised test, and it
    /// changed which info.txt the person was pointed at). Ties go to the
    /// unsafe-behaviour patch first, then to the tag that sorts highest.
    static func isOutranked(_ lhs: Release, _ rhs: Release) -> Bool {
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        if lhs.marker.isUrgent != rhs.marker.isUrgent { return !lhs.marker.isUrgent }
        return lhs.tag < rhs.tag
    }

    // MARK: - Throttle (OIS's check_due / backoff)

    public struct State: Codable, Equatable, Sendable {
        public var lastCheck: Date?
        public var backoffCount = 0
        public var backoffUntil: Date?
        public var skippedTag: String?
        /// The "Stop telling me about updates" checkbox. Unsafe-behaviour
        /// patches still come through - that is what makes them UBP.
        public var silenced = false

        public init() {}
    }

    public static func isDue(_ state: State, now: Date = Date()) -> Bool {
        if let until = state.backoffUntil, now < until { return false }
        guard let last = state.lastCheck else { return true }
        return now.timeIntervalSince(last) >= ttl
    }

    /// 1h, 2h, 4h ... capped at 24h - after an HTTP error only; plain
    /// "offline" isn't the server's fault and just waits for the TTL.
    public static func backedOff(_ state: State, now: Date = Date()) -> State {
        var next = state
        let seconds = min(3_600 * pow(2, Double(state.backoffCount)), 86_400)
        next.backoffCount += 1
        next.backoffUntil = now.addingTimeInterval(seconds)
        return next
    }

    // MARK: - Fetching

    public enum FetchError: Error { case http(Int), transport }

    /// Where the feed lives. `MSL_UPDATE_FEED_URL` points it at a local file
    /// or mock server for testing, the way OIS_GITHUB_BASE does.
    static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["MSL_UPDATE_FEED_URL"],
           let url = URL(string: override) { return url }
        return URL(string: "https://github.com/\(repository)/releases.atom")!
    }

    static var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases")!
    }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases/latest")!
    }

    /// Every release ships an `info.txt` asset - what changed, and anything
    /// the person has to do by hand. `MSL_UPDATE_INFO_URL` (with `{tag}`)
    /// redirects it for testing.
    public static func infoURL(for tag: String) -> URL? {
        if let template = ProcessInfo.processInfo.environment["MSL_UPDATE_INFO_URL"] {
            return URL(string: template.replacingOccurrences(of: "{tag}", with: tag))
        }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/info.txt")
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("MSL-update-check", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.transport
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        return data
    }

    /// The feed first, the API if the feed gave nothing usable.
    public static func fetchReleases() async throws -> [Release] {
        var feedError: Error?
        do {
            let feed = String(decoding: try await fetch(feedURL), as: UTF8.self)
            let parsed = releases(from: tags(inAtom: feed))
            if !parsed.isEmpty { return parsed }
        } catch {
            feedError = error
        }
        // A test feed has no API to fall back to.
        if ProcessInfo.processInfo.environment["MSL_UPDATE_FEED_URL"] != nil {
            if let feedError { throw feedError }
            return []
        }
        return releases(from: tags(inJSON: try await fetch(apiURL)))
    }

    /// The release's `info.txt`, trimmed. `nil` when it has none.
    public static func fetchInfo(for tag: String) async -> String? {
        guard let url = infoURL(for: tag), let data = try? await fetch(url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// One throttled check. Returns the new state to persist alongside the
    /// decision; a `nil` decision means the check wasn't due yet.
    public static func run(current: Version, state: State, now: Date = Date()) async -> (Decision?, State) {
        guard isDue(state, now: now) else { return (nil, state) }
        var next = state
        next.lastCheck = now
        do {
            let found = try await fetchReleases()
            guard !found.isEmpty else { return (Decision(kind: .unknown), next) }
            next.backoffCount = 0
            next.backoffUntil = nil
            return (decide(current: current, releases: found,
                           skipped: state.skippedTag, silenced: state.silenced), next)
        } catch FetchError.http {
            return (Decision(kind: .unknown), backedOff(next, now: now))
        } catch {
            return (Decision(kind: .unknown), next)
        }
    }
}
