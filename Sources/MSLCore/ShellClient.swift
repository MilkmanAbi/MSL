// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A reusable one-shot "run this command in a guest instance, get its exit
/// code and output back" client, over the same control-socket + vsock
/// shell channel `msl` itself uses (see `DaemonProtocol`/`ShellProtocol`).
/// Not raw-mode/interactive - for programmatic callers (`MSLApp`,
/// `.desktop` entry scanning) that just need a command's result, not a
/// live terminal session.
///
/// `msl`'s own CLI has an independent, more elaborate copy of this same
/// wire-protocol logic (interactive raw-mode relay, SIGWINCH resize, a
/// dedicated user-facing error format - see `Sources/msl/main.swift`'s
/// `runShellSession`/`runOneShotCommand`) that predates this type. This
/// one exists so `MSLApp` doesn't need to reimplement the wire protocol a
/// third time; unifying the two is worth doing later but isn't done here,
/// to avoid touching the CLI's already-verified interactive path for a
/// GUI-app skeleton.
public final class ShellClient {
    public enum ShellClientError: Error, CustomStringConvertible {
        case daemonUnreachable
        case sessionFailed(String)
        case noDescriptorReceived

        public var description: String {
            switch self {
            case .daemonUnreachable: return "couldn't reach mslhd - is it running?"
            case .sessionFailed(let reason): return reason
            case .noDescriptorReceived: return "didn't receive session fd from mslhd"
            }
        }
    }

    public init() {}

    /// Runs `command` against `instance` as root (or `user`, if given) and
    /// returns its exit code plus everything it wrote to stdout/stderr.
    /// Blocks the calling thread until the command finishes - callers on
    /// the main actor (SwiftUI) must hop off it first (`Task.detached` or
    /// similar), same as any other synchronous, potentially slow I/O call.
    @discardableResult
    public func runOneShotCommand(
        instance: String, distro: GuestDistro, command: String, user: String = ""
    ) throws -> (exitCode: Int32, output: String) {
        let controlFD = try connectToDaemon()
        defer { close(controlFD) }

        let request = DaemonProtocol.ControlRequest.session(instance: instance, rows: 24, cols: 80, distro: distro)
        _ = request.encode().withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }

        var status: UInt8 = 0
        _ = withUnsafeMutablePointer(to: &status) { read(controlFD, $0, 1) }
        guard status == DaemonProtocol.statusOK else {
            var reason = [UInt8](repeating: 0, count: 256)
            let n = read(controlFD, &reason, 256)
            let message = n > 0 ? String(decoding: reason[0..<n], as: UTF8.self) : "unknown error"
            throw ShellClientError.sessionFailed(message)
        }

        guard let dataFD = try? FileDescriptorPassing.receive(from: controlFD) else {
            notifySessionEnded(instance: instance)
            throw ShellClientError.noDescriptorReceived
        }
        defer { close(dataFD) }

        writeFull(fd: dataFD, bytes: ShellProtocol.encodeExec(command: command, rows: 24, cols: 80, user: user))

        var exitCode: Int32 = 1
        var collected: [UInt8] = []
        while let frame = Self.readShellFrame(fd: dataFD) {
            switch frame.type {
            case .data: collected.append(contentsOf: frame.payload)
            case .exit: exitCode = Int32(frame.payload.first ?? 1)
            case .exec, .resize: break
            }
        }

        notifySessionEnded(instance: instance)
        return (exitCode, String(decoding: collected, as: UTF8.self))
    }

    // MARK: - Wire plumbing (mirrors msl's own client-side helpers)

    private func connectToDaemon() throws -> Int32 {
        let socketPath = DaemonProtocol.defaultSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShellClientError.daemonUnreachable }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                socketPath.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw ShellClientError.daemonUnreachable
        }
        return fd
    }

    /// Fire-and-forget - see `DaemonProtocol.ControlRequest.sessionEnded`'s
    /// doc comment for why this matters (drives auto-suspend once the last
    /// session for an instance closes) and why a failure here is a safe,
    /// tolerated failure mode.
    private func notifySessionEnded(instance: String) {
        guard let fd = try? connectToDaemon() else { return }
        defer { close(fd) }
        _ = DaemonProtocol.ControlRequest.sessionEnded(instance: instance).encode().withUnsafeBytes {
            write(fd, $0.baseAddress, $0.count)
        }
    }

    private func writeFull(fd: Int32, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { ptr in
            var sent = 0
            let base = ptr.baseAddress!
            while sent < ptr.count {
                let n = write(fd, base + sent, ptr.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private static func readFullOrNil(fd: Int32, count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            let base = ptr.baseAddress!
            while got < count {
                let n = read(fd, base + got, count - got)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? buf : nil
    }

    private static func readShellFrame(fd: Int32) -> (type: ShellProtocol.FrameType, payload: [UInt8])? {
        guard let header = readFullOrNil(fd: fd, count: 5) else { return nil }
        guard let type = ShellProtocol.FrameType(rawValue: header[0]) else { return nil }
        let len = (UInt32(header[1]) << 24) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 8) | UInt32(header[4])
        guard len > 0 else { return (type, []) }
        guard let payload = readFullOrNil(fd: fd, count: Int(len)) else { return nil }
        return (type, payload)
    }
}
