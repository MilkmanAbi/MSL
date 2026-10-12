// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import AppKit
import Foundation

/// The badge one instance wears, when its owner has picked something.
///
/// MSL draws an instance as its distro's symbol in its distro's colour, which
/// is right until you have four Debians. The sidebar then reads as four
/// identical rows, and the only way to tell `blog` from `blog-staging` is to
/// read the label every time. A logo you chose is faster than a label you
/// read, so the badge is clickable and this is what the click stores.
///
/// Every field is optional and nothing is written until something is chosen:
/// an instance with no entry here looks exactly as it always did, and the
/// file does not exist on a Mac where nobody has touched a logo.
public struct InstanceAppearance: Codable, Equatable, Sendable {
    /// An SF Symbol name, from `InstanceAppearance.factions`.
    public var symbol: String?
    /// `#RRGGBB`.
    public var tint: String?
    /// A file inside `logosDirectory`, not a path into the user's own
    /// folders: the picture has to survive the original being moved,
    /// renamed or deleted, and a stored path would leave a blank badge the
    /// first time it was.
    public var image: String?

    /// The same appearance with any imported picture dropped.
    ///
    /// `image` names a file in this Mac's logos directory. A shipment
    /// carries the manifest, not that file, so an appearance arriving on
    /// another Mac would otherwise point at a picture that is not there -
    /// and a broken image reads as a bug, where a plain badge reads as a
    /// choice.
    public var withoutImportedImage: InstanceAppearance {
        InstanceAppearance(symbol: symbol, tint: tint, image: nil)
    }

    public init(symbol: String? = nil, tint: String? = nil, image: String? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.image = image
    }

    public var isDefault: Bool { symbol == nil && tint == nil && image == nil }

    // MARK: - Factions

    /// The symbols the picker offers, in named groups.
    ///
    /// SF Symbols only, for the same reason `DistroBadge` uses them: shipping
    /// real logos would mean vendoring a dozen differently-licensed
    /// trademarks. These are deliberately characterful rather than literal -
    /// the point is that `blog` and `blog-staging` stop looking alike.
    public static let factions: [(name: String, symbols: [String])] = [
        ("Creatures", ["pawprint.fill", "hare.fill", "tortoise.fill", "ant.fill",
                       "ladybug.fill", "fish.fill", "bird.fill", "dog.fill",
                       "cat.fill", "lizard.fill", "teddybear.fill", "fossil.shell.fill"]),
        ("Banners", ["flag.fill", "shield.fill", "crown.fill", "seal.fill",
                     "rosette", "star.fill", "bolt.fill", "flame.fill",
                     "drop.fill", "leaf.fill", "snowflake", "sparkles"]),
        ("Work", ["hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill",
                  "cube.fill", "shippingbox.fill", "server.rack", "terminal.fill",
                  "chevron.left.forwardslash.chevron.right", "cpu.fill",
                  "externaldrive.fill", "folder.fill", "briefcase.fill"]),
        ("Places", ["house.fill", "building.2.fill", "globe", "map.fill",
                    "mountain.2.fill", "tree.fill", "moon.fill", "sun.max.fill",
                    "cloud.fill", "airplane", "car.fill", "sailboat.fill"]),
        ("Marks", ["circle.fill", "square.fill", "triangle.fill", "diamond.fill",
                   "hexagon.fill", "octagon.fill", "heart.fill", "suit.spade.fill",
                   "suit.club.fill", "suit.diamond.fill", "a.circle.fill",
                   "number.circle.fill"]),
    ]

    /// The colours the picker offers, as `#RRGGBB`. A fixed palette rather
    /// than a colour well: these are 26-point badges, and the ones that read
    /// at that size are worth choosing for the user.
    public static let palette: [String] = [
        "#E5484D", "#E8800C", "#E5B700", "#46A758", "#12A594", "#0090FF",
        "#3E63DD", "#8E4EC6", "#D6409F", "#E93D82", "#5A6169", "#1C2024",
    ]

    public static func isKnownSymbol(_ name: String) -> Bool {
        factions.contains { $0.symbols.contains(name) }
    }
}

/// Where the chosen badges are kept.
///
/// One file for all instances rather than one each: it is read on every
/// sidebar row draw, and twelve file reads per frame is a cost with no
/// upside.
public enum InstanceAppearanceStore {
    public static func url(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("appearance.json")
    }

    /// Copied-in pictures. Kept out of the JSON's own directory so a stray
    /// `*.json` sweep can never take them.
    public static func logosDirectory(appSupport: URL = MSLPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("logos", isDirectory: true)
    }

    public static func imageURL(_ file: String, appSupport: URL = MSLPaths.appSupport) -> URL {
        logosDirectory(appSupport: appSupport).appendingPathComponent(file)
    }

    public static func load(appSupport: URL = MSLPaths.appSupport) -> [String: InstanceAppearance] {
        guard let data = try? Data(contentsOf: url(appSupport: appSupport)),
              let decoded = try? JSONDecoder().decode([String: InstanceAppearance].self, from: data)
        else { return [:] }
        return decoded
    }

    public static func of(_ instance: String,
                         appSupport: URL = MSLPaths.appSupport) -> InstanceAppearance {
        load(appSupport: appSupport)[instance] ?? InstanceAppearance()
    }

    /// Writes one instance's choice. An appearance back at its default
    /// removes the entry rather than storing an empty one, and the last
    /// entry going takes the file with it - so a Mac where nobody has
    /// touched a logo has no appearance file at all.
    @discardableResult
    public static func set(_ appearance: InstanceAppearance, for instance: String,
                          appSupport: URL = MSLPaths.appSupport) -> Bool {
        // A managed fleet may want instances to look the same, so the
        // logo, colour and name badge are a capability like any other.
        guard MSLAPGate.allows("instance.appearance", instance: instance) else { return false }
        var all = load(appSupport: appSupport)
        // A picture being replaced or cleared leaves a file behind otherwise.
        if let previous = all[instance]?.image, previous != appearance.image {
            try? FileManager.default.removeItem(at: imageURL(previous, appSupport: appSupport))
        }
        if appearance.isDefault { all[instance] = nil } else { all[instance] = appearance }
        return write(all, appSupport: appSupport)
    }

    @discardableResult
    static func write(_ all: [String: InstanceAppearance],
                      appSupport: URL = MSLPaths.appSupport) -> Bool {
        let target = url(appSupport: appSupport)
        guard !all.isEmpty else {
            try? FileManager.default.removeItem(at: target)
            return true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return false }
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (try? data.write(to: target, options: .atomic)) != nil
    }

    /// Drops everything about `instance`, picture included.
    ///
    /// Called from instance removal: a new instance given a deleted one's
    /// name must not inherit its badge, the same rule
    /// `LinuxAppCatalog.forget` exists for.
    public static func forget(instance: String, appSupport: URL = MSLPaths.appSupport) {
        var all = load(appSupport: appSupport)
        guard let going = all.removeValue(forKey: instance) else { return }
        if let image = going.image {
            try? FileManager.default.removeItem(at: imageURL(image, appSupport: appSupport))
        }
        write(all, appSupport: appSupport)
    }

    // MARK: - Importing a picture

    public enum ImportError: LocalizedError {
        case unreadable
        case tooLarge(UInt64)

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't an image MSL can read."
            case .tooLarge(let bytes):
                return "That file is \(DiskStorage.format(bytes)) - pick one under 32 MB."
            }
        }
    }

    /// The largest file worth opening. A badge is 44 points at most, and a
    /// RAW photo or a multi-hundred-megabyte PSD is a mistake rather than a
    /// choice.
    static let maximumSourceBytes: UInt64 = 32 * 1024 * 1024

    /// Copies `source` in as `instance`'s logo, and returns the stored file
    /// name.
    ///
    /// Re-encoded to a 256-point PNG rather than copied byte for byte: the
    /// badge is drawn at 26 to 44 points, so a 12-megapixel photo costs
    /// memory on every row draw for detail nobody can see. 256 is twice the
    /// largest use at 2x.
    public static func importImage(from source: URL, for instance: String,
                                   appSupport: URL = MSLPaths.appSupport) throws -> String {
        let size = DiskStorage.allocatedSize(of: source.path)
        if size > maximumSourceBytes { throw ImportError.tooLarge(size) }
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0
        else { throw ImportError.unreadable }
        guard let png = squarePNG(image, side: 256) else { throw ImportError.unreadable }

        let directory = logosDirectory(appSupport: appSupport)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A fresh name every time, so a replacement can never be served from
        // a cache keyed on the old one.
        let file = "\(instance)-\(UUID().uuidString.prefix(8)).png"
        try png.write(to: directory.appendingPathComponent(file), options: .atomic)
        return file
    }

    /// Centre-cropped to a square, then scaled - so a wide picture keeps its
    /// middle instead of being squashed into the badge.
    static func squarePNG(_ image: NSImage, side: CGFloat) -> Data? {
        let source = image.size
        let crop = min(source.width, source.height)
        let origin = CGPoint(x: (source.width - crop) / 2, y: (source.height - crop) / 2)

        let output = NSImage(size: NSSize(width: side, height: side))
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: NSRect(origin: origin, size: NSSize(width: crop, height: crop)),
                   operation: .copy, fraction: 1)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
