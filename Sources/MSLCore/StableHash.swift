import Foundation

/// A hash that means the same thing in every process.
///
/// Swift seeds `Hasher` randomly per launch, so `login.hashValue % n` picks a
/// *different* bucket every time the app starts. That is the correct default
/// for a `Dictionary` and exactly wrong for anything a person sees: a
/// contributor's colour would change on every open, which reads as a bug and
/// loses the one thing a per-person colour is for - recognising your own row
/// without reading it.
///
/// FNV-1a over the UTF-8 bytes: tiny, stable across launches and machines, and
/// with a good enough spread over a handful of buckets for names that share a
/// prefix. Not a cryptographic hash and not used as one.
public enum StableHash {
    public static func value(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// A bucket in `0..<count`, stably chosen by `string`.
    ///
    /// Returns 0 for a non-positive `count` rather than trapping on the
    /// modulo: a caller with an empty palette should get a boring colour, not
    /// a crash in an About window.
    public static func index(for string: String, modulo count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(value(string) % UInt64(count))
    }
}
