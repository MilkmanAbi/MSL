import Foundation

/// MSL's version, in one place.
///
/// `Scripts/build-app.sh` writes the same number into the app's
/// `Info.plist` (`CFBundleShortVersionString`); `MSLVersionTests` keeps the
/// two from drifting apart.
public enum MSLVersion {
    /// Plain semantic version, as `Info.plist` wants it.
    public static let marketing = "2.0.0"

    /// How MSL names a release: "MSL-2.0.0".
    public static var display: String { "MSL-\(marketing)" }

    /// True when `version` is at least `required`, for an MSLAP policy's
    /// `minimumMSLVersion`.
    ///
    /// Missing components count as zero, so "2.0" satisfies "2.0.0".
    /// Anything unparseable compares FALSE, which means MSL refuses to
    /// enforce a policy whose requirement it cannot read - the safe way
    /// round, because the alternative is enforcing the half it understood.
    public static func compare(_ version: String, isAtLeast required: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? -1 }
        let right = required.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? -1 }
        if left.contains(-1) || right.contains(-1) || left.isEmpty || right.isEmpty { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return true
    }
}
