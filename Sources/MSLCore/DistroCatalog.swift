import Foundation

/// The distros that can be downloaded, as a person reads them: "Debian 13",
/// "Arch Linux ARM rolling". Built from the published manifest, where each
/// release is only in the file name (`msl-debian-13-arm64.img.xz`) - the
/// manifest's own `version` is the image build date.
public enum DistroCatalog {
    public struct Entry: Equatable {
        public let distro: String
        public let name: String
        public let release: String
        public let downloadBytes: UInt64
    }

    static let names: [String: String] = [
        "alpine": "Alpine Linux", "debian": "Debian", "ubuntu": "Ubuntu", "kali": "Kali Linux",
        "arch": "Arch Linux ARM", "fedora": "Fedora", "rocky": "Rocky Linux", "alma": "AlmaLinux",
        "centos": "CentOS Stream", "oracle": "Oracle Linux", "opensuse": "openSUSE Leap", "nix": "Nix",
    ]

    /// In MSL's usual distro order, then any the manifest adds that this
    /// build doesn't know yet.
    public static func entries(from manifest: DistroInstaller.Manifest) -> [Entry] {
        let order = GuestDistro.allCases.map(\.rawValue)
        let keys = manifest.distros.keys.sorted {
            (order.firstIndex(of: $0) ?? Int.max, $0) < (order.firstIndex(of: $1) ?? Int.max, $1)
        }
        return keys.compactMap { key in
            guard let artifact = manifest.distros[key] else { return nil }
            return Entry(distro: key, name: names[key] ?? key,
                         release: release(fromURL: artifact.url, distro: key),
                         downloadBytes: artifact.size)
        }
    }

    /// `…/msl-centos-stream10-arm64.img.xz` for `centos` -> "10".
    static func release(fromURL url: String, distro: String) -> String {
        var token = (url as NSString).lastPathComponent
        let prefix = "msl-\(distro)-"
        guard token.hasPrefix(prefix), let arch = token.range(of: "-arm64") else { return "" }
        token = String(token[token.index(token.startIndex, offsetBy: prefix.count)..<arch.lowerBound])
        for word in ["stream", "leap"] where token.hasPrefix(word) {
            token = String(token.dropFirst(word.count))
        }
        // Nix is the package manager on top of another distro.
        if distro == "nix", let base = ["debian", "ubuntu", "alpine"].first(where: { token.hasPrefix($0) }) {
            return "on \(names[base] ?? base) \(token.dropFirst(base.count))"
        }
        return token
    }

    /// The manifest, or nil if it can't be had within `timeout` seconds - this
    /// is for a hint, and a hint must never hang a terminal.
    public static func fetch(from urlString: String, timeout: Int = 6) -> DistroInstaller.Manifest? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fsSL", "--max-time", String(timeout), urlString]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(DistroInstaller.Manifest.self, from: data)
    }
}
