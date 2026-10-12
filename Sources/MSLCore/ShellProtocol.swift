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
        /// Guest to host, once, before any `data`: "this session is
        /// detachable - here is its id and the vsock port to reattach on".
        /// Its **absence** is how a host detects an older `shellinit`, so
        /// no version number is needed anywhere.
        case session = 0x05
        /// Host to guest, on a session's own port: reattach, with the
        /// terminal size which may have changed while detached.
        case attach = 0x06
        case detach = 0x07
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
    /// `sessionID`, when given, is appended as a trailing field.
    ///
    /// Safe against every `shellinit` already shipped: its `EXEC` parsing
    /// walks `rows, cols, userlen, user, cmdlen, cmd` and stops, so bytes
    /// after the command are simply ignored. A guest that *does* understand
    /// it answers with a `session` frame; one that doesn't answers with
    /// nothing, and the host keeps the old behaviour. That is the whole
    /// negotiation - no version field, no fallback on error.
    public static func encodeExec(command: String, rows: UInt16, cols: UInt16,
                                  user: String = "", sessionID: String = "") -> [UInt8] {
        let userBytes = Array(user.utf8)
        let commandBytes = Array(command.utf8)
        let idBytes = Array(sessionID.utf8)
        var payload: [UInt8] = []
        appendU16BE(rows, &payload)
        appendU16BE(cols, &payload)
        appendU16BE(UInt16(userBytes.count), &payload)
        payload.append(contentsOf: userBytes)
        appendU16BE(UInt16(commandBytes.count), &payload)
        payload.append(contentsOf: commandBytes)
        if !idBytes.isEmpty {
            appendU16BE(UInt16(idBytes.count), &payload)
            payload.append(contentsOf: idBytes)
        }
        return encodeFrame(type: .exec, payload: payload)
    }

    /// Reattach, carrying the terminal size so a full-screen app redraws
    /// into the right shape before the scrollback is replayed.
    public static func encodeAttach(rows: UInt16, cols: UInt16) -> [UInt8] {
        var payload: [UInt8] = []
        appendU16BE(rows, &payload)
        appendU16BE(cols, &payload)
        return encodeFrame(type: .attach, payload: payload)
    }

    /// A session id: hex, which is all `shellinit` accepts in the name.
    public static func newSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses a `session` frame's `"<id> <port>"` payload.
    public static func parseSession(_ payload: [UInt8]) -> (id: String, port: UInt32)? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let port = UInt32(parts[1]) else { return nil }
        return (String(parts[0]), port)
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
