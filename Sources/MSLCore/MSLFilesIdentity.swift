import Foundation

/// MSL Files' identity as its own application.
///
/// MSL Files ships as a separate app beside MSL - its own Dock tile, its own
/// entry in Launchpad and Spotlight - but it is built from the same code and
/// the same executable: `MSL Files.app` carries a copy of the MSL binary under
/// this bundle identifier, and the binary decides which app to be from the
/// bundle it was launched in. Kept in MSLCore because mslhd needs to address it
/// too (a Linux app asking to show a folder opens MSL Files directly).
public enum MSLFilesIdentity {
    public static let bundleIdentifier = "com.msl.files"
    /// `msl-files://files?instance=<name>&path=<guest path>[&select=1]`.
    public static let urlScheme = "msl-files"
    /// The pre-split scheme, still claimed by MSL.app. An installation that
    /// predates MSL Files being its own app only understands this one.
    public static let legacyScheme = "msl"

    /// Whether the running process is MSL Files rather than MSL.
    /// `MSL_RUN_AS_FILES=1` does the same for an unbundled development run.
    public static var isRunningAsFilesApp: Bool {
        Bundle.main.bundleIdentifier == bundleIdentifier
            || ProcessInfo.processInfo.environment["MSL_RUN_AS_FILES"] == "1"
    }

    /// A reveal link for a guest path, in the given scheme.
    /// Opens MSL Files as a **file picker** for a parked request.
    ///
    /// Only the token travels: what to show (mode, starting folder,
    /// suggested name) is asked for over the daemon socket, so a URL cannot
    /// be forged into showing something the guest never requested.
    public static func pickURL(scheme: String = urlScheme, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pick"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    public static func revealURL(scheme: String = urlScheme, instance: String,
                                 guestPath: String, select: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "files"
        components.queryItems = [
            URLQueryItem(name: "instance", value: instance),
            URLQueryItem(name: "path", value: guestPath),
        ] + (select ? [URLQueryItem(name: "select", value: "1")] : [])
        return components.url
    }
}
