import Foundation

/// MSL's version, in one place.
///
/// `Scripts/build-app.sh` writes the same number into the app's
/// `Info.plist` (`CFBundleShortVersionString`); `MSLVersionTests` keeps the
/// two from drifting apart.
public enum MSLVersion {
    /// Plain semantic version, as `Info.plist` wants it.
    public static let marketing = "1.0.0"

    /// How MSL names a release: "MSL-1.0.0".
    public static var display: String { "MSL-\(marketing)" }
}
