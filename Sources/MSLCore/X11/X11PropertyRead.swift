import Foundation

/// The arithmetic behind `GetProperty`, on its own so it can be tested.
///
/// X11 property reads are a two-step conversation whenever the client does
/// not already know the size: ask with `long-length = 0` and read
/// `bytes-after` to learn it, then ask again for that much. mslgd answered
/// the first step with "no data, and nothing follows" - `bytes-after` was
/// hardcoded to 0 - so every such read came back empty. Pasting into a
/// Linux app was the symptom that finally exposed it, but it affected any
/// property whose size the client had to be told.
struct X11PropertyRead: Equatable {
    /// Byte range of the stored value to return.
    let range: Range<Int>
    /// How much of the value is left after this reply, which is what tells
    /// a client to come back for the rest.
    let bytesAfter: Int
    /// The X protocol only deletes when the client has read to the end:
    /// deleting after the sizing read would throw the data away before the
    /// read that wanted it.
    let deletes: Bool

    /// - Parameters:
    ///   - total: the property's size in bytes
    ///   - longOffset: the request's `long-offset`, in 4-byte units
    ///   - longLength: the request's `long-length`, in 4-byte units
    ///   - delete: the request's delete flag
    init(total: Int, longOffset: UInt32, longLength: UInt32, delete: Bool) {
        let offset = min(Int(longOffset) * 4, total)
        let length = min(total - offset, Int(longLength) * 4)
        range = offset..<(offset + length)
        bytesAfter = total - (offset + length)
        deletes = delete && bytesAfter == 0
    }
}
