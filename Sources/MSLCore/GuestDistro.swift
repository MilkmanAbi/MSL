// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Which Linux a persistent-disk instance runs: one of MSL's own published
/// distros, or a custom image someone built themselves.
///
/// Every published distro shares the *same* kernel/initramfs (`disk-Image`/
/// `disk-initramfs-virt`, built once from Alpine's `linux-lts` package by
/// `Linux-Side/image-build/build-kernel.sh`) - the kernel doesn't care what
/// userspace is on the disk it mounts, the same way a single shared kernel
/// boots any distro under WSL2 on Windows. Only the disk image itself
/// differs, and only the boot-time mechanism used to get `shellinit` running
/// differs (OpenRC vs systemd - see `initSystem`).
///
/// A custom image (`.custom`) brings all three files itself, from its own
/// folder under `Custom Images` - see `CustomImage`.
///
/// Images are built by `Linux-Side/image-build/` (`distros.sh` names each
/// distro's base container image). `allCases` is the published distros in
/// the order the app lists them; custom images are listed separately.
///
/// **The string form is what gets stored** - in `instances.json`, daemon
/// protocol lines, generated app bundles and `default-users.json`. Published
/// distros keep their plain names; a custom image is `custom:<folder>`, which
/// can never collide with a future published name.
public enum GuestDistro: Hashable, Sendable {
    case alpine
    case debian
    case ubuntu
    /// Kali Linux, the Debian-based security distribution - a real arm64
    /// port with official container images.
    case kali
    /// Real Arch Linux has no ARM port at all - this is "Arch Linux ARM"
    /// (archlinuxarm.org), the community ARM continuation every ARM host
    /// (this project included) actually means by "Arch" on this
    /// architecture.
    case arch
    case fedora
    /// Rocky Linux, AlmaLinux, CentOS Stream and Oracle Linux: the Enterprise
    /// Linux family. Red Hat Enterprise Linux itself isn't offered - it
    /// needs a subscription, and the freely redistributable UBI image lacks
    /// packages MSL requires (e2fsprogs).
    case rocky
    case alma
    case centos
    case oracle
    /// openSUSE Leap, SUSE's community release.
    case opensuse
    /// **Not genuine NixOS** - a real NixOS rootfs is built by Nix's own
    /// evaluation model (`nixos-generators`/`nixos-rebuild`, driven by a
    /// system configuration expression), not by exporting a Docker
    /// container's filesystem the way every other distro here is - that
    /// tooling doesn't fit this project's "export a base image" pipeline at
    /// all. This is the Nix *package manager*, daemon-mode installed on top
    /// of the same Debian base as `.debian`, which is itself a completely
    /// standard, widely-used way to get Nix (the official installer
    /// explicitly supports non-NixOS Linux) - real value (`nix-shell`,
    /// `nix profile install`, reproducible dev environments), just not "boot
    /// into NixOS's own module system."
    case nix
    /// A user's own image: the folder `Custom Images/<slug>` with its own
    /// kernel, initramfs and disk. See `CustomImage`.
    case custom(String)

    public static let customPrefix = "custom:"

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The custom image's folder name, or nil for a published distro.
    public var customSlug: String? {
        if case .custom(let slug) = self { return slug }
        return nil
    }

    public enum InitSystem {
        /// Alpine's default init - `shellinit` is wired in via
        /// `/etc/local.d/shellinit.start` + `rc-update add local default`
        /// (see `Linux-Side/provision/provision-msl.sh`).
        case openrc
        /// Every other distro's default init - `shellinit` is wired in via
        /// a plain unit file symlinked into `multi-user.target.wants`
        /// directly (bypassing `systemctl enable`, which wants a live
        /// D-Bus connection to a running systemd instance that doesn't
        /// exist during offline provisioning).
        case systemd
    }

    /// Custom images report systemd: nothing on the Mac side depends on the
    /// answer for them, and `provision-msl.sh` detects the real one inside.
    public var initSystem: InitSystem {
        switch self {
        case .alpine: return .openrc
        default: return .systemd
        }
    }

    /// The official arm64 container image a distro's disk is built from.
    /// Mirrors `Linux-Side/image-build/distros.sh`, which is what the image
    /// build actually reads - keep the two in step. Every entry was checked
    /// on 2026-09-14 to publish a `linux/arm64` manifest and to carry every
    /// package in `packages.sh`'s required tier. Empty for a custom image,
    /// which MSL did not build.
    ///
    /// Arch uses `menci/archlinuxarm`: there is no official arm64 Arch
    /// image (`archlinux` publishes no arm64 manifest), and the other
    /// community image, `lopsided/archlinux`, ships no `/etc/os-release`.
    public var dockerImage: String {
        switch self {
        case .alpine: return "alpine:3.24"
        case .debian: return "debian:13-slim"
        case .ubuntu: return "ubuntu:26.04"
        case .kali: return "kalilinux/kali-rolling:latest"
        case .arch: return "menci/archlinuxarm:latest"
        case .fedora: return "fedora:44"
        case .rocky: return "rockylinux/rockylinux:10"
        case .alma: return "almalinux:10"
        case .centos: return "quay.io/centos/centos:stream10"
        case .oracle: return "oraclelinux:10"
        case .opensuse: return "opensuse/leap:16.0"
        // Debian, not a NixOS image - see the `.nix` case doc comment.
        case .nix: return "debian:13-slim"
        case .custom: return ""
        }
    }

    /// The name this distro's disk is known by: the file under
    /// `~/Library/Application Support/MSL/` for a published distro, and the
    /// key for storage policies, usage samples and pending resizes for
    /// every distro. Alpine keeps the original unsuffixed name - it was the
    /// only distro once, and existing instances, storage policies and docs
    /// all name it that way.
    ///
    /// A custom image's disk lives in its own folder, so this is only its
    /// key (`custom-<slug>.img`) - never join it to Application Support to
    /// find the file; use `bootFiles(appSupport:)`.
    public var diskImageFilename: String {
        switch self {
        case .alpine: return "rootfs.img"
        case .custom(let slug): return "custom-\(slug).img"
        default: return "rootfs-\(rawValue).img"
        }
    }

    /// The distro's downloaded image - the **base** every instance of it is
    /// cloned from.
    ///
    /// Never booted. `msl install` writes it, `InstanceDisk.ensure` clones
    /// it, and nothing else touches it; that is what keeps it pristine, so
    /// that a new instance really is a new installation rather than a copy
    /// of whatever the last one did. See `InstanceDisk`.
    public func baseImageURL(appSupport: URL = MSLPaths.appSupport) -> URL {
        switch self {
        case .custom(let slug):
            return CustomImage.bootFiles(slug: slug, appSupport: appSupport).disk
        default:
            return appSupport.appendingPathComponent(diskImageFilename)
        }
    }

    /// Whether this distro's base has been downloaded, so a new instance of
    /// it can be made without fetching anything.
    ///
    /// Not the same question as "can this instance start?" - that one is
    /// about the instance's own disk (`InstanceDisk.exists`). They came
    /// apart when instances stopped sharing one image.
    public func baseIsInstalled(appSupport: URL = MSLPaths.appSupport) -> Bool {
        FileManager.default.fileExists(atPath: baseImageURL(appSupport: appSupport).path)
    }

    /// The three files `instance` boots from, and how to boot them.
    ///
    /// **The disk is the instance's own, never the base.** A path that
    /// booted the base would write to it, and every instance made afterwards
    /// would inherit those writes - which is the whole thing this layout
    /// exists to stop. The kernel and initramfs are shared and read-only, so
    /// they stay where they are.
    public func bootFiles(instance: String, appSupport: URL = MSLPaths.appSupport) -> GuestBootFiles {
        let disk = InstanceDisk.url(instance: instance, appSupport: appSupport)
        let key = InstanceDisk.storageKey(instance: instance)
        switch self {
        case .custom(let slug):
            // A custom image brings its own kernel, initramfs and command
            // line; only the disk becomes per-instance.
            var files = CustomImage.bootFiles(slug: slug, appSupport: appSupport)
            files.disk = disk
            files.storageKey = key
            return files
        default:
            // An instance's own kernel wins over the shared one. Only a
            // shipment puts one there, and when it does it is the kernel
            // that filesystem was built against - a different MSL build
            // ships a different kernel, so restoring against whatever this
            // Mac happens to have is not the machine that was shipped.
            if InstanceDisk.hasOwnKernel(instance: instance, appSupport: appSupport) {
                return GuestBootFiles(
                    kernel: InstanceDisk.kernelURL(instance: instance, appSupport: appSupport),
                    initramfs: InstanceDisk.initramfsURL(instance: instance, appSupport: appSupport),
                    disk: disk,
                    storageKey: key,
                    kernelCommandLine: nil)
            }
            return GuestBootFiles(
                kernel: appSupport.appendingPathComponent("disk-Image"),
                initramfs: appSupport.appendingPathComponent("disk-initramfs-virt"),
                disk: disk,
                storageKey: key,
                kernelCommandLine: nil)
        }
    }
}

/// Where a distro's kernel, initramfs and disk are, and anything about
/// booting them that differs from MSL's defaults.
public struct GuestBootFiles: Equatable, Sendable {
    public var kernel: URL
    public var initramfs: URL
    public var disk: URL
    /// The disk's name for `DiskStorage`, which is not always the file's
    /// own name: two custom images both holding a `rootfs.img` must not
    /// share a storage policy with each other or with Alpine.
    public var storageKey: String
    /// Replaces MSL's kernel command line when set (a custom image's
    /// `image.json`).
    public var kernelCommandLine: String?

    public init(kernel: URL, initramfs: URL, disk: URL, storageKey: String, kernelCommandLine: String?) {
        self.kernel = kernel
        self.initramfs = initramfs
        self.disk = disk
        self.storageKey = storageKey
        self.kernelCommandLine = kernelCommandLine
    }

    /// Which of the three files an instance needs are not on this Mac.
    ///
    /// The kernel and initramfs are **shared by every non-custom distro**
    /// and arrive with whichever distro was downloaded first - so an
    /// instance can have a perfectly good disk of its own and still have
    /// nothing to boot. A shipment is exactly that case: it carries the
    /// filesystem and nothing else, so installing one onto a Mac that has
    /// never downloaded a distro produces an instance that looks complete
    /// and fails at start with a raw `VZErrorDomain` dump about a kernel
    /// file (2026-10-02).
    public var missing: [URL] {
        [kernel, initramfs, disk].filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What to tell someone, when something is missing.
    public func missingDescription(distro: GuestDistro) -> String? {
        let absent = missing
        guard !absent.isEmpty else { return nil }
        let needsImage = absent.contains(kernel) || absent.contains(initramfs)
        if absent.contains(disk), !needsImage {
            return "its disk is missing - the instance's filesystem isn't on this Mac any more"
        }
        let what = absent.contains(disk) ? "its disk and the Linux kernel are" : "the Linux kernel is"
        let image = distro.isCustom ? "alpine" : distro.rawValue
        // Joined rather than a multiline literal with `\` continuations:
        // those keep the leading indentation of every continued line, which
        // put long runs of spaces in the middle of the sentence.
        return [
            "\(what) missing.",
            "MSL's kernel is shared by every distro and arrives with the first one you download,",
            "and this Mac hasn't downloaded one yet.",
            "Run `msl install \(image)` and it will start.",
        ].joined(separator: " ")
    }
}

extension GuestDistro: CaseIterable {
    /// The published distros, in the order the app lists them. Custom
    /// images come from `CustomImage.scan()`.
    public static let allCases: [GuestDistro] = [
        .alpine, .debian, .ubuntu, .kali, .arch, .fedora,
        .rocky, .alma, .centos, .oracle, .opensuse, .nix,
    ]
}

extension GuestDistro: RawRepresentable {
    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.customPrefix) {
            let slug = String(rawValue.dropFirst(Self.customPrefix.count))
            guard CustomImage.isValidSlug(slug) else { return nil }
            self = .custom(slug)
            return
        }
        guard let published = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = published
    }

    public var rawValue: String {
        switch self {
        case .alpine: return "alpine"
        case .debian: return "debian"
        case .ubuntu: return "ubuntu"
        case .kali: return "kali"
        case .arch: return "arch"
        case .fedora: return "fedora"
        case .rocky: return "rocky"
        case .alma: return "alma"
        case .centos: return "centos"
        case .oracle: return "oracle"
        case .opensuse: return "opensuse"
        case .nix: return "nix"
        case .custom(let slug): return Self.customPrefix + slug
        }
    }
}

extension GuestDistro: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = GuestDistro(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown distro '\(raw)'"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
