import Foundation

/// "Is there a newer MSL, and is it worth interrupting someone over?"
///
/// Releases are git tags on `MilkmanAbi/MSL`, and a tag is **plain semantic
/// versioning** and nothing else:
///
///     v<major>.<minor>.<patch>
///
/// What the three numbers mean is the whole policy, and it is the one every
/// developer already knows:
///
/// | bump              | example         | what MSL does                          |
/// |-------------------|-----------------|----------------------------------------|
/// | patch             | 2.0.0 -> 2.0.1  | nothing unasked; shown when you look   |
/// | minor             | 2.0.0 -> 2.1.0  | tells you it is there                  |
/// | major             | 2.0.0 -> 3.0.0  | tells you, and to read the repo first   |
///
/// A patch release is a fix. Nobody needs to be interrupted by a fix, and an
/// app that puts a window up for every third-number change teaches people to
/// dismiss its windows. It is still *found* - "Check for Updates…" and
/// `msl update` are asking, and asking is always answered in full.
///
/// A major release is where MSL itself changes. It is offered, but the thing
/// to do first is read what changed, so that is what the notice leads with.
///
/// Anything after a hyphen - `v3.0.0-rc1`, `v3.0.0-beta2` - is a pre-release:
/// parsed so it can be recognised, never offered.
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
/// chose, and the package itself replaces the installed copy, in that order
/// and only after an explicit click. Keeping the policy free of the plumbing
/// is what lets `decide` be a pure function the tests can cover exhaustively.
public enum UpdateCheck {
    public static let repository = "MilkmanAbi/MSL"
    public static let ttl: TimeInterval = 86_400

    /// The repository itself - what a major release says to read first.
    public static var repositoryPage: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    // MARK: - Versions

    /// `major.minor.patch`, with an optional pre-release suffix.
    ///
    /// A missing third number is zero, so a `v2.1` tag is 2.1.0 and compares
    /// as one. More than three numbers is not a semantic version and is
    /// refused rather than guessed at.
    ///
    /// **A bare number is refused too, and that one matters.** Tags arrive
    /// from a parsed feed, and a feed entry that is not a release can leave
    /// behind something like `1374003283` - GitHub's internal repository id.
    /// Read as a version that is 1.37 billion point zero point zero, which
    /// outranks every real release and would be offered to everybody. A
    /// version has a dot in it; a number on its own is not one.
    public struct Version: Comparable, Equatable, Sendable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int
        /// Whatever followed the first hyphen. Empty for a real release.
        public let prerelease: String

        public init?(_ text: String) {
            var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.first == "v" || body.first == "V" { body.removeFirst() }
            let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let core = parts.first, !core.isEmpty else { return nil }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (2...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            let padded = numbers.map { $0! } + Array(repeating: 0, count: 3 - numbers.count)
            self.init(major: padded[0], minor: padded[1], patch: padded[2],
                      prerelease: parts.count > 1 ? String(parts[1]) : "")
        }

        public init(major: Int, minor: Int, patch: Int, prerelease: String = "") {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        public var isStable: Bool { prerelease.isEmpty }

        /// Always three numbers, whatever the tag was spelled like - the
        /// installer package carries this exact string, and `UpdateDownload`
        /// refuses a package whose version does not match it.
        public var description: String {
            "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)")
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            // 3.0.0-rc1 comes before 3.0.0.
            if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
            return lhs.prerelease < rhs.prerelease
        }
    }

    // MARK: - What kind of release it is

    /// Which of the three numbers moved - and so how much of someone's
    /// attention the release has a right to.
    public enum Bump: String, Sendable, CaseIterable {
        case patch, minor, major

        /// Whether MSL says so without being asked. A fix does not earn a
        /// window; the other two do.
        public var isWorthInterrupting: Bool { self != .patch }

        /// Whether to read the repository before taking it. Only a major
        /// release changes MSL itself.
        public var readTheRepositoryFirst: Bool { self == .major }

        public var label: String {
            switch self {
            case .patch: return "a fix"
            case .minor: return "new features"
            case .major: return "a new major version"
            }
        }

        /// The jump from one version to another.
        public init(from current: Version, to next: Version) {
            if next.major != current.major { self = .major }
            else if next.minor != current.minor { self = .minor }
            else { self = .patch }
        }
    }

    // MARK: - Releases

    public struct Release: Equatable, Sendable {
        public let tag: String
        public let version: Version

        public init(tag: String, version: Version) {
            self.tag = tag
            self.version = version
        }

        public var isStable: Bool { version.isStable }

        public var page: URL {
            URL(string: "https://github.com/\(UpdateCheck.repository)/releases/tag/\(tag)") ?? UpdateCheck.releasesPage
        }
    }

    /// One tag. Pre-releases parse too (with `isStable == false`) so they can
    /// be reported and then ignored, rather than silently vanishing.
    public static func parse(tag raw: String) -> Release? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, let version = Version(tag) else { return nil }
        return Release(tag: tag, version: version)
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
            /// There is a newer MSL. Whether to *say so* unasked is
            /// `announces`; whether it exists at all is this.
            case update
            case upToDate
            /// The check could not be made (offline, GitHub said no).
            case unknown
        }

        public var kind: Kind
        public var release: Release?
        /// Which number moved. `nil` unless there is a release.
        public var bump: Bump?
        /// Whether MSL should raise this on its own: a minor or major
        /// release that has not been skipped or silenced.
        public var announces: Bool

        public init(kind: Kind, release: Release? = nil, bump: Bump? = nil, announces: Bool = false) {
            self.kind = kind
            self.release = release
            self.bump = bump
            self.announces = announces
        }
    }

    /// The whole policy, as one pure function.
    ///
    /// `skipped` and `silenced` are the person's own choices and only ever
    /// quiet the unasked notice - they never hide a release from someone who
    /// came looking, which is why `kind` and `announces` are separate.
    public static func decide(current: Version, releases: [Release],
                              skipped: String? = nil, silenced: Bool = false) -> Decision {
        let newer = releases.filter { $0.isStable && $0.version > current }
        guard let offer = newer.max(by: isOutranked) else { return Decision(kind: .upToDate) }
        let bump = Bump(from: current, to: offer.version)

        var announces = bump.isWorthInterrupting && !silenced
        // Matched by version, not by tag: "Skip This Version" means the
        // version, and a re-tagged release is the same version, not a new
        // offer.
        if let skipped, let version = Version(skipped), version == offer.version { announces = false }

        return Decision(kind: .update, release: offer, bump: bump, announces: announces)
    }

    /// A total order over releases, so the offer never depends on the order
    /// the feed happened to list them in. Two tags can carry the *same*
    /// version - a release reissued - and picking "the newest" by version
    /// alone left that tie to the feed (caught by the randomised test, and it
    /// changed which info.txt the person was pointed at).
    static func isOutranked(_ lhs: Release, _ rhs: Release) -> Bool {
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        return lhs.tag < rhs.tag
    }

    // MARK: - Throttle (OIS's check_due / backoff)

    public struct State: Codable, Equatable, Sendable {
        public var lastCheck: Date?
        public var backoffCount = 0
        public var backoffUntil: Date?
        /// The version someone chose to skip, as its tag.
        public var skippedTag: String?
        /// The "Stop telling me about updates" checkbox. Asking directly
        /// still answers - this only silences the unasked notice.
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

    /// Every release ships an `info.txt` asset - a short description of what
    /// changed, and anything the person has to do by hand.
    /// `MSL_UPDATE_INFO_URL` (with `{tag}`) redirects it for testing.
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
