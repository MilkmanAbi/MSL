// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation
import MSLCore

/// The non-secret half of the email setup. The API key is in the Keychain.
public struct NotifySettings: Codable, Equatable, Sendable {
    /// `MSL <msl@your-domain.com>` - must be on a domain verified in Resend.
    public var fromAddress: String
    /// Where a colleague's reply should land. Usually the person running MSL.
    public var replyTo: String?
    /// How many "the address changed" emails one person may get in a day.
    ///
    /// Not unlimited, because a free relay rotates hourly and that is 24
    /// emails a day per person for something they read once. After the cap
    /// MSL goes quiet until somebody actually connects, which resets it -
    /// an address nobody is using does not need announcing.
    public var rotationEmailsPerDay: Int

    public init(fromAddress: String, replyTo: String? = nil, rotationEmailsPerDay: Int = 3) {
        self.fromAddress = fromAddress
        self.replyTo = replyTo
        self.rotationEmailsPerDay = rotationEmailsPerDay
    }

    public static let defaultFrom = "MSL <onboarding@resend.dev>"

    static var file: URL {
        MSLPaths.appSupport.appendingPathComponent("public/notify.json")
    }

    public static func load() -> NotifySettings? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(NotifySettings.self, from: data)
    }

    @discardableResult
    public func save() -> Bool {
        _ = MSLPaths.ensureDirectory(Self.file.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: Self.file, options: .atomic)) != nil
    }

    public static func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Ready to send only when both halves are present.
    public static var isConfigured: Bool {
        ResendCredentials.isConfigured && load() != nil
    }

    public static func mailer() -> ResendMailer? {
        guard let key = ResendCredentials.load(), let settings = load() else { return nil }
        return ResendMailer(apiKey: key, from: settings.fromAddress, replyTo: settings.replyTo)
    }
}

/// One person who should be told where an instance is.
public struct NotifyRecipient: Codable, Equatable, Sendable {
    public var email: String
    /// A friendly name, for `msl public notify list` and the app.
    public var label: String
    /// Whether this person has already been sent their key. They only ever
    /// need it once; afterwards a rotation email is just an address.
    public var keyDelivered: Bool
    /// The last address actually sent to them, so an unchanged address is
    /// never announced twice.
    public var lastAddressSent: String?
    /// Rotation emails sent today, against `rotationEmailsPerDay`.
    public var sentToday: Int
    public var sentOn: String

    public init(email: String, label: String) {
        self.email = email
        self.label = label
        self.keyDelivered = false
        self.lastAddressSent = nil
        self.sentToday = 0
        self.sentOn = NotifyRecipient.today()
    }

    public static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Rolls the counter over at midnight.
    mutating func startOfDayIfNeeded() {
        let now = Self.today()
        if sentOn != now {
            sentOn = now
            sentToday = 0
        }
    }
}

/// Who to tell, per instance.
public enum NotifyRoster {
    static func file(instance: String) -> URL {
        MSLPaths.appSupport.appendingPathComponent("public/notify-\(instance).json")
    }

    public static func load(instance: String) -> [NotifyRecipient] {
        guard let data = try? Data(contentsOf: file(instance: instance)) else { return [] }
        return (try? JSONDecoder().decode([NotifyRecipient].self, from: data)) ?? []
    }

    @discardableResult
    public static func save(_ recipients: [NotifyRecipient], instance: String) -> Bool {
        _ = MSLPaths.ensureDirectory(file(instance: instance).deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(recipients) else { return false }
        return (try? data.write(to: file(instance: instance), options: .atomic)) != nil
    }

    public static func forget(instance: String) {
        try? FileManager.default.removeItem(at: file(instance: instance))
    }

    /// Clears everyone's daily count for an instance.
    ///
    /// Called when somebody actually connects: the cap exists to stop
    /// announcing an address nobody is using, so the moment one *is* being
    /// used, announcing the next one is useful again.
    public static func resetQuota(instance: String) {
        var recipients = load(instance: instance)
        guard recipients.contains(where: { $0.sentToday > 0 }) else { return }
        for index in recipients.indices { recipients[index].sentToday = 0 }
        save(recipients, instance: instance)
    }
}

/// A keypair made for one person, so they can be let in and let go
/// individually.
///
/// The private half is **attached to their email and then deleted**. MSL
/// never keeps it: it is theirs, not MSL's, and a copy on this Mac would
/// only be another thing to protect. If it is lost, remove them and add
/// them again - that makes a new key and invalidates the old one, which is
/// also exactly what you want if their laptop goes missing.
public enum RecipientKey {
    /// Returns the private key text and the public line to authorize.
    public static func generate(forEmail email: String, instance: String) -> (privateKey: String, publicKey: String)? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSL-public", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let base = directory.appendingPathComponent("recipient-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: base.appendingPathExtension("pub"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-N", "", "-q",
                             "-C", "msl-\(instance)-\(MailMessage.bareAddress(email))",
                             "-f", base.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let privateKey = try? String(contentsOf: base, encoding: .utf8),
              let publicRaw = try? String(contentsOf: base.appendingPathExtension("pub"), encoding: .utf8),
              let publicKey = PublicHardening.sanitizedPublicKey(publicRaw) else { return nil }
        return (privateKey, publicKey)
    }

    /// What the attachment is called in their inbox. Recognisable, and
    /// safe as a filename whatever their address looks like.
    public static func filename(instance: String) -> String {
        let safe = instance.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "msl-\(String(safe).lowercased())-key"
    }
}
