// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// The distro table `msl distros`, `msl list online` and the "nothing is
/// installed yet" message all print.
///
/// One renderer rather than three: the version that greeted an empty Mac and
/// the version a user asks for are the same information, and the first one
/// written had already drifted into being the only one that showed download
/// sizes.
public enum DistroListing {
    public struct Row: Equatable, Sendable {
        public let distro: String
        /// "Debian 13", or just the distro name when the catalog is out of
        /// reach.
        public let title: String
        /// Nil when the catalog couldn't be read.
        public let downloadBytes: UInt64?
        /// Whether the base image is already on this Mac.
        public let isInstalled: Bool
        /// How many instances exist of it.
        public let instances: Int

        public init(distro: String, title: String, downloadBytes: UInt64?,
                    isInstalled: Bool, instances: Int) {
            self.distro = distro
            self.title = title
            self.downloadBytes = downloadBytes
            self.isInstalled = isInstalled
            self.instances = instances
        }
    }

    /// Every distro MSL can install, with what this Mac already has.
    ///
    /// `catalog` nil means the manifest couldn't be fetched - the names are
    /// still worth printing, so the rows come back without sizes or releases
    /// rather than not at all.
    public static func rows(catalog: DistroInstaller.Manifest?,
                            instanceCounts: [String: Int],
                            isInstalled: (GuestDistro) -> Bool) -> [Row] {
        let entries = catalog.map { DistroCatalog.entries(from: $0) } ?? []
        let byName = Dictionary(entries.map { ($0.distro, $0) }, uniquingKeysWith: { a, _ in a })
        // The catalog's order when there is one (it is the published order),
        // otherwise MSL's own.
        let names = entries.isEmpty
            ? GuestDistro.allCases.filter { !$0.isCustom }.map(\.rawValue)
            : entries.map(\.distro)
        return names.map { name in
            let entry = byName[name]
            let distro = GuestDistro(rawValue: name)
            return Row(distro: name,
                       title: entry.map { "\($0.name) \($0.release)" } ?? name.capitalized,
                       downloadBytes: entry?.downloadBytes,
                       isInstalled: distro.map(isInstalled) ?? false,
                       instances: instanceCounts[name] ?? 0)
        }
    }

    /// The rows as an aligned table. An installed distro is marked, so the
    /// eye can find what is already here without reading every line - but the
    /// marker column only exists when something is installed, since a column
    /// of nothing but blanks on a fresh Mac just indents the table.
    public static func table(_ rows: [Row]) -> String {
        guard !rows.isEmpty else { return "" }
        let nameWidth = rows.map(\.distro.count).max() ?? 8
        let titleWidth = rows.map(\.title.count).max() ?? 20
        let marked = rows.contains(where: \.isInstalled)
        var out = ""
        for row in rows {
            let marker = marked ? (row.isInstalled ? "ok  " : "    ") : ""
            var line = "  \(marker)"
            line += row.distro.padding(toLength: nameWidth + 2, withPad: " ", startingAt: 0)
            line += row.title.padding(toLength: titleWidth + 2, withPad: " ", startingAt: 0)
            if row.isInstalled {
                line += row.instances == 1
                    ? "installed, 1 instance"
                    : (row.instances == 0 ? "installed" : "installed, \(row.instances) instances")
            } else if let bytes = row.downloadBytes {
                line += "\(DiskStorage.format(bytes)) download"
            }
            out += line.replacingOccurrences(of: " +$", with: "", options: .regularExpression) + "\n"
        }
        return out
    }
}
