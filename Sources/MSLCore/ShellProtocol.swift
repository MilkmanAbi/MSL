// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi
//
// Part of MSL. Everything in MSL is MIT-licensed except mslgd, its X11
// server, which is GPL-3.0 - see LICENSE-MIT and README.md's "Licence"
// section.

import Foundation

/// Wire protocol for the interactive shell channel (host `msl` <-> guest
/// `shellinit`), used once `mslhd` has handed the raw vsock fd off to the
/// client (see `DaemonServer.handleSession`) - from that point on it's a
/// direct connection with no daemon involvement. See `Guest/init/
/// shellinit.c`'s doc comment for the authoritative spec; this is the
/// host-side encode half (decode/frame-reading lives in `Sources/msl/
/// main.swift`, the sole consumer, mirroring how `FileOpsProtocol`/
/// `FileOpsClient` split pure marshaling from actual I/O).
///
/// Frame format: `[u8 type][u32 BE length][payload]`.
///   EXEC   0x01  host->guest, sent first, exactly once.
///          payload: rows u16 BE, cols u16 BE, userlen u16 BE, user bytes,
///          cmdlen u16 BE, cmd bytes (userlen == 0 means "root"; cmdlen == 0
///          means "interactive login shell", not a one-shot command). An
///          unknown user gets a single EXIT frame (status 127) with no pty
///          ever created - see `Guest/init/shellinit.c`.
///   DATA   0x02  both directions - raw bytes to/from the pty
///   RESIZE 0x03  host->guest only - rows u16 BE, cols u16 BE
///   EXIT   0x04  guest->host only, sent last, exactly once - payload: one
///          byte, the child's exit status (0-255; a signal-killed child is
///          reported as 128+signal, matching bash's own $? convention)
public enum ShellProtocol {
    public enum FrameType: UInt8 {
        case exec = 0x01
        case data = 0x02
        case resize = 0x03
        case exit = 0x04
    }

    public enum ShellProtocolError: Error, CustomStringConvertible {
        case connectionClosed
        case malformedFrame

        public var description: String {
            switch self {
            case .connectionClosed: return "shell connection closed unexpectedly"
            case .malformedFrame: return "shellinit sent a malformed frame"
            }
        }
    }

    /// `user` empty means "root" (the guest's own default when `userlen`
    /// is 0 - see the wire format above), matching every session before
    /// `msl -u`/`--user` existed.
    public static func encodeExec(command: String, rows: UInt16, cols: UInt16, user: String = "") -> [UInt8] {
        let userBytes = Array(user.utf8)
        let cmdBytes = Array(command.utf8)
        var payload: [UInt8] = []
        appendU16BE(rows, &payload)
        appendU16BE(cols, &payload)
        appendU16BE(UInt16(min(userBytes.count, Int(UInt16.max))), &payload)
        payload.append(contentsOf: userBytes)
        appendU16BE(UInt16(min(cmdBytes.count, Int(UInt16.max))), &payload)
        payload.append(contentsOf: cmdBytes)
        return encodeFrame(type: .exec, payload: payload)
    }

    public static func encodeData<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        encodeFrame(type: .data, payload: Array(bytes))
    }

    public static func encodeResize(rows: UInt16, cols: UInt16) -> [UInt8] {
        var payload: [UInt8] = []
        appendU16BE(rows, &payload)
        appendU16BE(cols, &payload)
        return encodeFrame(type: .resize, payload: payload)
    }

    private static func appendU16BE(_ v: UInt16, _ buf: inout [UInt8]) {
        buf.append(UInt8(v >> 8))
        buf.append(UInt8(v & 0xFF))
    }

    private static func encodeFrame(type: FrameType, payload: [UInt8]) -> [UInt8] {
        let len = UInt32(payload.count)
        var frame: [UInt8] = [
            type.rawValue,
            UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
        ]
        frame.append(contentsOf: payload)
        return frame
    }
}
