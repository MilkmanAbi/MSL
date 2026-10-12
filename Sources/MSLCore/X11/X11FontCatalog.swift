import Foundation

/// The core font names `ListFonts` answers with.
///
/// Every core font here is drawn with the same one real font
/// (`X11FakeFont`), and `OpenFont` accepts any name. But `ListFonts`
/// answered "no fonts" for every pattern, and old toolkits ask before they
/// open: Xlib's `XCreateFontSet` (Xaw's international mode - xcalc sends 51
/// `ListFonts` per launch) resolves one font per charset of the locale and
/// reports each empty answer as a missing charset; Tk without Xft and
/// xfontsel enumerate families this way. The list is the classic X.Org
/// core set (x.org/guide/fonts): aliases plus XLFDs for misc-fixed and the
/// Adobe/B&H families, over the ISO 8859 charsets and ISO 10646.
enum X11FontCatalog {
    static let names: [String] = {
        var out = ["fixed", "variable", "cursor", "5x7", "5x8", "6x9", "6x10", "6x12", "6x13", "6x13bold",
                   "7x13", "7x13bold", "7x14", "8x13", "8x13bold", "8x16", "9x15", "9x15bold", "10x20", "12x24",
                   "nil2"]
        let encodings = ["iso8859-1", "iso8859-2", "iso8859-3", "iso8859-4", "iso8859-5", "iso8859-7",
                         "iso8859-9", "iso8859-10", "iso8859-13", "iso8859-14", "iso8859-15", "iso10646-1",
                         "koi8-r"]
        let families: [(foundry: String, family: String, spacing: String, slants: [String])] = [
            ("misc", "fixed", "c", ["r"]),
            ("adobe", "courier", "m", ["r", "o"]),
            ("adobe", "helvetica", "p", ["r", "o"]),
            ("adobe", "times", "p", ["r", "i"]),
            ("adobe", "new century schoolbook", "p", ["r", "i"]),
            ("b&h", "lucida", "p", ["r", "i"]),
            ("b&h", "lucidatypewriter", "m", ["r"]),
        ]
        let pixelSizes = [8, 10, 12, 13, 14, 15, 17, 18, 20, 24]
        for f in families {
            for weight in ["medium", "bold"] {
                for slant in f.slants {
                    for px in pixelSizes {
                        let avg = px * 6 // tenths of a pixel; about 0.6 em
                        for enc in encodings {
                            out.append("-\(f.foundry)-\(f.family)-\(weight)-\(slant)-normal--\(px)-\(px * 10)-75-75-\(f.spacing)-\(avg)-\(enc)")
                        }
                    }
                }
            }
        }
        for px in pixelSizes {
            out.append("-adobe-symbol-medium-r-normal--\(px)-\(px * 10)-75-75-p-\(px * 6)-adobe-fontspecific")
        }
        out.append("-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1")
        out.append("-misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso8859-1")
        return out
    }()

    /// Names matching an XLFD pattern (`*` any run, `?` one character,
    /// case-insensitive, as the core protocol defines), at most `max`.
    static func matching(_ pattern: String, max: Int) -> [String] {
        let p = Array(pattern.lowercased().utf8)
        var out: [String] = []
        for name in names where out.count < max {
            if matches(p, Array(name.lowercased().utf8)) { out.append(name) }
        }
        return out
    }

    /// Iterative glob match with single-star backtracking: linear-ish, no
    /// recursion, so a hostile pattern of 255 stars costs nothing.
    static func matches(_ p: [UInt8], _ s: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*"), any = UInt8(ascii: "?")
        var pi = 0, si = 0, starAt = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == any || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == star {
                starAt = pi; mark = si; pi += 1
            } else if starAt >= 0 {
                pi = starAt + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == star { pi += 1 }
        return pi == p.count
    }
}
