import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Learns which guest application is behind a freshly accepted connection,
/// before any X11 byte is interpreted.
///
/// mslgd gives every Linux app its own macOS process so it can have its own
/// Dock tile, icon and name (see `X11AppRouter`), which means the identity
/// has to be known at ROUTING time - before a window exists, before the
/// handshake, before anything.
///
/// It cannot be read out of the X11 stream. That was tried first: read
/// ahead until the client sets `WM_CLASS`, then route. It deadlocks, and
/// obviously so in hindsight - X11's connection setup is a request/RESPONSE
/// handshake, so the client sends its setup and then waits. Nothing further
/// arrives until the server answers, and answering means already being the
/// server for that connection. Observed exactly that: `galculator` running
/// in the guest, its socket connected, and not one byte of trace on the
/// host.
///
/// So the guest says who it is instead - it knows for free, since the peer
/// of its unix socket is a real local process (`SO_PEERCRED` -> pid ->
/// `/proc/<pid>/cmdline`). `x11tunnel --announce` sends one small frame
/// ahead of the relay:
///
///     'M' 'S' 'L' 'A'  <uint8 length>  <length bytes of name>
///
/// X11's own first byte is `'B'` or `'l'`, never `'M'`, so a single byte
/// distinguishes an announcement from a client that sends none - and any
/// byte read while finding that out is handed back for replay.
enum X11AppIdentity {
    struct Announcement {
        let appName: String?
        /// Bytes read while looking for the frame that turned out to be
        /// X11 data - must be replayed into the real connection handler.
        let consumed: [UInt8]
    }

    private static let magic: [UInt8] = [0x4D, 0x53, 0x4C, 0x41] // "MSLA"
    /// The global menu bridge's announcement (`GuestIntegration`), and the
    /// prefix a host receives with a menu connection instead of X11 bytes.
    static let menuMagic: [UInt8] = [0x4D, 0x53, 0x4C, 0x4D] // "MSLM"

    static func read(fd: Int32) -> Announcement {
        guard let first = readExactly(1, from: fd) else { return Announcement(appName: nil, consumed: []) }
        guard first[0] == magic[0] else { return Announcement(appName: nil, consumed: first) }
        guard let restOfMagic = readExactly(3, from: fd) else {
            return Announcement(appName: nil, consumed: first)
        }
        // "MSLM": the guest's menu bridge, named like an X11 client so it
        // routes to the same app host. Its `consumed` is the magic itself -
        // the only way the router's handoff can tell the host what it got.
        let isMenuBridge = Array(restOfMagic) == Array(menuMagic[1...])
        guard isMenuBridge || Array(restOfMagic) == Array(magic[1...]) else {
            return Announcement(appName: nil, consumed: first + restOfMagic)
        }
        if isMenuBridge {
            guard let lengthByte = readExactly(1, from: fd), lengthByte[0] > 0,
                  let nameBytes = readExactly(Int(lengthByte[0]), from: fd)
            else { return Announcement(appName: nil, consumed: []) }
            return Announcement(appName: displayName(from: String(decoding: nameBytes, as: UTF8.self)),
                                consumed: menuMagic)
        }
        guard let lengthByte = readExactly(1, from: fd), lengthByte[0] > 0,
              let nameBytes = readExactly(Int(lengthByte[0]), from: fd)
        else {
            // The frame started but did not finish; there is nothing
            // sensible left to replay, and the connection is unusable.
            return Announcement(appName: nil, consumed: [])
        }
        return Announcement(appName: displayName(from: String(decoding: nameBytes, as: UTF8.self)), consumed: [])
    }

    /// The guest reports an executable name ("galculator", "gnome-chess").
    /// macOS shows this as the application's name, where lowercase reads as
    /// a command rather than an app - so capitalize the first letter, and
    /// leave anything already capitalized alone ("GIMP" must not become
    /// "Gimp").
    static func displayName(from raw: String) -> String? {
        guard let cleaned = sanitized(raw), let firstCharacter = cleaned.first else { return nil }
        guard firstCharacter.isLowercase else { return cleaned }
        return firstCharacter.uppercased() + cleaned.dropFirst()
    }

    /// The name becomes a FILENAME - the per-app host binary is a copy of
    /// the shared one named after the app, because an unbundled executable's
    /// Dock tile is labelled with its filename (verified: the same binary
    /// copied to `.../Krita` shows as "Krita" in the Dock, and in
    /// `NSRunningApplication.localizedName()`). So a guest-controlled string
    /// reaches the filesystem here, and `../../` in it must not be able to
    /// write outside the shim directory.
    static func sanitized(_ name: String) -> String? {
        let allowed = name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" || $0 == "."
        }
        var cleaned = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() } // no dotfiles, no "..", no "."
        cleaned = String(cleaned.prefix(64))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let ok = buffer.withUnsafeMutableBytes { ptr -> Bool in
            let base = ptr.baseAddress!
            while got < count {
                let n = Darwin.read(fd, base + got, count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? buffer : nil
    }
}
