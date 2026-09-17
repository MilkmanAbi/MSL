import SwiftUI

/// The repository's contributor list, shared by the About window's
/// Contributors pane and the main window's sidebar strip.
///
/// Lives in its own file because two unrelated views need it: leaving it
/// inside `AboutView.swift` and reaching across for it is how a UI file
/// quietly becomes a model file.

struct Contributor: Identifiable, Decodable {
    let id: Int
    let login: String
    let avatarURL: String
    let profileURL: String
    let contributions: Int

    enum CodingKeys: String, CodingKey {
        case id, login, contributions
        case avatarURL = "avatar_url"
        case profileURL = "html_url"
    }
}

/// The parts of a GitHub profile worth putting on a card.
///
/// A separate request per person (`/users/<login>`), because the contributors
/// endpoint returns only the commit count and the avatar - the name someone
/// actually goes by is not in it.
struct ContributorProfile: Decodable {
    let name: String?
    let bio: String?
    let location: String?
}

/// Fetches the repository's contributors from GitHub at open time.
///
/// Three outcomes, kept distinct on purpose. Rendering a failure as an
/// empty list would read as "nobody has contributed", which is a lie about
/// the project rather than a fact about the network.
@MainActor
final class ContributorsLoader: ObservableObject {
    enum State {
        case loading
        case loaded([Contributor])
        /// Reached GitHub, but the repository has no commits yet.
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// Filled in after the list appears, keyed by login. The cards render
    /// the moment the list arrives and gain their details a beat later -
    /// holding the whole pane back for a second round of requests would be
    /// a worse trade than a card that grows.
    @Published private(set) var profiles: [String: ContributorProfile] = [:]

    /// Unauthenticated GitHub allows 60 requests an hour from one machine,
    /// and each profile costs one. A cap keeps a busy repository from
    /// spending that budget - and being rate-limited out of the *list*
    /// itself on the next open - for a line of flavour text.
    private static let profileLookupLimit = 20

    func load() async {
        state = .loading
        let url = URL(string: "https://api.github.com/repos/MilkmanAbi/MSL/contributors")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                let people = try JSONDecoder().decode([Contributor].self, from: data)
                state = people.isEmpty ? .empty : .loaded(people)
                if !people.isEmpty { await loadProfiles(for: people) }
            // A repository with no commits answers 204, and one GitHub
            // cannot see at all answers 404 - neither is an error worth
            // alarming anyone about.
            case 204, 404:
                state = .empty
            case 403:
                state = .failed("GitHub is rate-limiting this machine. Try again in a bit.")
            default:
                state = .failed("GitHub answered \(code).")
            }
        } catch {
            state = .failed("Couldn't reach GitHub. (\(error.localizedDescription))")
        }
    }

    /// Fetches each person's profile, concurrently and best-effort.
    ///
    /// Nothing here can fail the pane: a profile that does not load just
    /// leaves a card with the name and commit count it already had. That is
    /// deliberate - being rate-limited should cost you the flavour text, not
    /// the list of people.
    private func loadProfiles(for people: [Contributor]) async {
        let logins = people.prefix(Self.profileLookupLimit).map(\.login)

        let fetched = await withTaskGroup(of: (String, ContributorProfile?).self) { group -> [String: ContributorProfile] in
            for login in logins {
                group.addTask { (login, await Self.profile(for: login)) }
            }
            var found: [String: ContributorProfile] = [:]
            for await (login, profile) in group {
                if let profile { found[login] = profile }
            }
            return found
        }
        profiles = fetched
    }

    private static func profile(for login: String) async -> ContributorProfile? {
        // `addingPercentEncoding` rather than trusting the login: GitHub
        // logins are alphanumeric-and-hyphen today, but a URL built by
        // pasting a remote string together is a habit worth not having.
        guard let escaped = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/users/\(escaped)") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ContributorProfile.self, from: data)
    }
}
