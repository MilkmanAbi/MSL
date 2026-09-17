// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

public enum GuestImageToolsError: Error, CustomStringConvertible {
    case missingTarball(String)
    case extractionFailed(String)

    public var description: String {
        switch self {
        case .missingTarball(let path): return "netboot tarball not found at \(path)"
        case .extractionFailed(let what): return "failed to extract \(what)"
        }
    }
}

public enum GuestImageTools {
    /// Extracts a single member from a .tar.gz using the system `tar` -
    /// simplest reliable way to pull files out of Alpine's netboot tarball
    /// without pulling in a compression library dependency.
    public static func extractMember(from tarball: URL, member: String, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzOf", tarball.path, member]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw GuestImageToolsError.extractionFailed(member)
        }
        try data.write(to: destination)
    }

    /// Alpine's aarch64 `vmlinuz-virt` is a zboot-wrapped EFI PE binary
    /// (magic "MZ...zimg", an embedded gzip stream, then a small EFI stub
    /// a real UEFI firmware would decompress and jump to at boot).
    /// `VZLinuxBootLoader` is not a UEFI firmware - it wants the raw,
    /// already-decompressed ARM64 Linux `Image` directly (recognizable by
    /// the "ARM\x64" magic at offset 56). Passing it the zboot wrapper
    /// as-is produces no build-time error and fails at `vm.start()` with
    /// an opaque "Internal Virtualization error" - confirmed by inspecting
    /// the downloaded file directly (`file` reports "PE32+ executable (EFI
    /// application) Aarch64", not a Linux boot Image). This finds the
    /// embedded gzip stream and decompresses it to get the real Image.
    public static func extractZbootImage(from wrappedKernel: URL, to destination: URL) throws {
        let wrapped = try Data(contentsOf: wrappedKernel)
        let gzipMagic: [UInt8] = [0x1f, 0x8b, 0x08]
        guard let magicRange = wrapped.firstRange(of: gzipMagic) else {
            throw GuestImageToolsError.extractionFailed("no embedded gzip stream found in \(wrappedKernel.lastPathComponent)")
        }

        let compressedPayload = Data(wrapped[magicRange.lowerBound...])
        let tmpGz = destination.appendingPathExtension("gz")
        try compressedPayload.write(to: tmpGz)
        defer { try? FileManager.default.removeItem(at: tmpGz) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", tmpGz.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        let decompressed = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // gunzip exits 2 (not 0) for "trailing garbage ignored" when there's
        // data after the gzip stream ends (the rest of the PE/zboot
        // wrapper) - expected here, not a real failure.
        guard process.terminationStatus == 0 || process.terminationStatus == 2, !decompressed.isEmpty else {
            throw GuestImageToolsError.extractionFailed("gunzip failed decompressing \(wrappedKernel.lastPathComponent) (exit \(process.terminationStatus))")
        }
        try decompressed.write(to: destination)
    }

    /// Ensures the raw ARM64 `Image` and `initramfs-virt` are extracted
    /// into `appSupport`, pulling them from the netboot tarball (and
    /// decompressing the zboot wrapper) if not already cached there.
    public static func ensureKernelAndInitrd(netbootTarball: URL, appSupport: URL) throws -> (kernel: URL, initrd: URL) {
        let wrappedKernelURL = appSupport.appendingPathComponent("vmlinuz-virt")
        let kernelURL = appSupport.appendingPathComponent("Image")
        let initrdURL = appSupport.appendingPathComponent("initramfs-virt")

        guard FileManager.default.fileExists(atPath: netbootTarball.path) else {
            throw GuestImageToolsError.missingTarball(netbootTarball.path)
        }

        if !FileManager.default.fileExists(atPath: wrappedKernelURL.path) {
            try extractMember(from: netbootTarball, member: "boot/vmlinuz-virt", to: wrappedKernelURL)
        }
        if !FileManager.default.fileExists(atPath: kernelURL.path) {
            try extractZbootImage(from: wrappedKernelURL, to: kernelURL)
        }
        if !FileManager.default.fileExists(atPath: initrdURL.path) {
            try extractMember(from: netbootTarball, member: "boot/initramfs-virt", to: initrdURL)
        }
        return (kernelURL, initrdURL)
    }
}
