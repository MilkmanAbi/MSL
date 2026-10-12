// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

public enum MailError: Error, CustomStringConvertible {
    case notConfigured
    case sendFailed(String)
    case refusedByServer(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "no email account is set up yet - run: msl public notify setup"
        case .sendFailed(let detail):
            return "couldn't send the email: \(detail)"
        case .refusedByServer(let detail):
            return detail
        }
    }
}

/// Sends mail through Resend's HTTP API.
///
/// One `curl` POST, because MSL already runs curl for every download and a
/// whole HTTP client for one endpoint would be worse.
public struct ResendMailer: Sendable {
    public let apiKey: String
    public let from: String
    public let replyTo: String?

    public init(apiKey: String, from: String, replyTo: String? = nil) {
        self.apiKey = apiKey
        self.from = from
        self.replyTo = replyTo
    }

    /// Resend's own test sender, which can only deliver to the address on
    /// the Resend account itself. Worth knowing before a send, not after a
    /// bare 403.
    public var usesTestSender: Bool { from.contains("resend.dev") }

    public func send(_ message: MailMessage) throws {
        var payload: [String: Any] = [
            "from": from,
            "to": message.to.map { MailMessage.bareAddress($0) },
            "subject": message.subject,
            "html": message.html,
            "text": message.plainText,
        ]
        if let replyTo = message.replyTo ?? replyTo, !replyTo.isEmpty {
            payload["reply_to"] = MailMessage.bareAddress(replyTo)
        }
        if !message.attachments.isEmpty {
            payload["attachments"] = message.attachments.map {
                ["content": $0.data.base64EncodedString(), "filename": $0.filename]
            }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw MailError.sendFailed("couldn't build the request")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "https://api.resend.com/emails",
            "-X", "POST",
            // The key is read from the environment by curl itself. On the
            // command line it would be visible to every process on this Mac
            // through `ps`, and it can send mail as this domain.
            "-H", "Authorization: Bearer $(MSL_RESEND_KEY)",
            "-H", "Content-Type: application/json",
            "--data-binary", "@-",
            "--silent", "--show-error",
            "--write-out", "\nMSL_HTTP %{http_code}",
            // A mail API that stops answering must never hold up publishing:
            // the email is a convenience, the tunnel is the feature.
            "--connect-timeout", "20", "--max-time", "45",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["MSL_RESEND_KEY"] = apiKey
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            throw MailError.sendFailed(error.localizedDescription)
        }
        input.fileHandleForWriting.write(body)
        input.fileHandleForWriting.closeFile()
        let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard transcript.contains("MSL_HTTP 200") else {
            throw MailError.refusedByServer(
                Self.explain(transcript, from: from, to: message.to))
        }
    }

    /// Turns a status code into the sentence that names the real cause.
    ///
    /// The 403 is the one that matters: it is what everybody hits first,
    /// and "Resend returned 403" tells somebody nothing about what to do.
    static func explain(_ transcript: String, from: String, to: [String]) -> String {
        let recipient = to.first.map { MailMessage.bareAddress($0) } ?? "that address"
        if transcript.contains("MSL_HTTP 403") || transcript.lowercased().contains("verify a domain") {
            if from.contains("resend.dev") {
                return """
                Resend refused it. Its free sender (\(from)) can only email the address your \
                Resend account is registered under - not \(recipient). Verify a domain at \
                resend.com/domains, then set the From address to something on it, like \
                msl@your-domain.com.
                """
            }
            return """
            Resend refused \(from). That usually means the domain is not verified yet - check \
            resend.com/domains and that its DNS records have gone in.
            """
        }
        // Keyed on what Resend says, not on the status code: a bad key
        // comes back as **400**, not the 401 you would expect, so matching
        // the code alone let the raw JSON through to the user.
        if transcript.lowercased().contains("api key is invalid")
            || transcript.contains("MSL_HTTP 401") {
            return "Resend did not accept the API key. Make a new one at resend.com/api-keys."
        }
        if transcript.contains("MSL_HTTP 422") {
            return "Resend rejected the message: \(cleaned(transcript))"
        }
        if transcript.contains("MSL_HTTP 429") {
            return "Resend's rate limit. The free plan allows 100 emails a day."
        }
        if transcript.contains("could not resolve") || transcript.contains("Could not resolve") {
            return "couldn't reach api.resend.com from this Mac."
        }
        return "Resend refused it: \(cleaned(transcript))"
    }

    private static func cleaned(_ transcript: String) -> String {
        String(transcript.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces).suffix(220))
    }
}

/// Where the API key lives.
///
/// ## Not Application Support, and not the Keychain either
///
/// **Not Application Support**, because MSL shares the whole home directory
/// into every guest as `/mnt/mac` and virtiofs hands guest root whatever
/// the Mac user can read - a key there is readable from inside any Linux
/// instance, and it sends mail as this domain.
///
/// **Not the Keychain**, which was tried first and is worse. MSL is ad-hoc
/// signed, so every rebuild gives `mslhd` a new identity and the item's
/// access list no longer matches it. macOS then wants to ask the user, a
/// background daemon cannot show a prompt, and `SecItemCopyMatching`
/// **blocks forever** - measured: `STATUS` answered instantly while
/// `PUBLIC_NOTIFY_LIST` timed out on a daemon that was otherwise healthy.
/// That is not a development annoyance, it is what every user would get on
/// every MSL update, and a wedged handler is far worse than a readable
/// file.
///
/// So: a file in `/Users/Shared/MSL`, which is **outside the home
/// directory** and therefore outside the share. Checked from a guest
/// rather than assumed - `/mnt/mac/../Shared` does not exist, because the
/// mount is rooted at the home directory and `..` cannot escape it.
///
/// `/Users/Shared` is world-writable, so the directory is created 0700 and
/// its ownership is verified before anything is written into it or read
/// back - otherwise another account on this Mac could put a directory
/// there first and be handed the key.
public enum ResendCredentials {
    static let directory = URL(fileURLWithPath: "/Users/Shared/MSL", isDirectory: true)
    static var file: URL { directory.appendingPathComponent("resend-key") }

    /// The directory, once it is known to be ours alone. nil means it is
    /// not safe to use, and a secret is never written to a maybe.
    static func secureDirectory() -> URL? {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        }
        guard let attributes = try? manager.attributesOfItem(atPath: directory.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.int16Value & 0o077 == 0 else { return nil }
        return directory
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        guard secureDirectory() != nil else { return false }
        guard (try? Data(key.utf8).write(to: file, options: [.atomic])) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }

    public static func load() -> String? {
        guard secureDirectory() != nil,
              let data = try? Data(contentsOf: file) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    @discardableResult
    public static func remove() -> Bool {
        (try? FileManager.default.removeItem(at: file)) != nil
    }

    public static var isConfigured: Bool { load() != nil }
}
