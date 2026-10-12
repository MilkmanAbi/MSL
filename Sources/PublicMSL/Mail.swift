// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// One email MSL wants to send.
///
/// ## Why Resend and nothing else
///
/// The obvious alternative was an ordinary mail account - a Gmail made for
/// MSL, an app password, send as that. It was built and then removed,
/// because the two paths into a personal mailbox have both closed:
///
/// - **OAuth** ("Connect your Gmail") now requires an Authorised Domain on
///   the consent screen, which means owning a domain and proving it through
///   Search Console. That is the same requirement Resend has, with weeks of
///   Google review on top.
/// - **App passwords** still work, but they are a credential Google has
///   said it intends to retire, and Outlook already killed the equivalent.
///
/// So the honest shape of this feature is: it needs a domain either way.
/// Resend is the version where the domain is the *only* thing needed - no
/// review queue, no consent screen, no OAuth client to keep alive - and
/// anybody who does not have one simply runs `msl public status` when they
/// want the current address, which costs them one command.
public struct MailMessage: Sendable {
    public struct Attachment: Sendable {
        public var filename: String
        public var data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// `MSL <msl@your-domain.com>`. The address must be on a domain
    /// verified in Resend, or it refuses the send.
    public var from: String
    public var to: [String]
    public var subject: String
    public var plainText: String
    public var html: String
    /// Where a reply goes - the point of this is a colleague who may want
    /// to answer a human, not a no-reply robot.
    public var replyTo: String?
    public var attachments: [Attachment]

    public init(from: String, to: [String], subject: String, plainText: String, html: String,
                replyTo: String? = nil, attachments: [Attachment] = []) {
        self.from = from
        self.to = to
        self.subject = subject
        self.plainText = plainText
        self.html = html
        self.replyTo = replyTo
        self.attachments = attachments
    }

    /// The bare address out of `Name <addr@host>`.
    public static func bareAddress(_ value: String) -> String {
        guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"),
              open < close else {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// Whether something looks like an email address at all. Deliberately
    /// loose - the mail server is the real judge, and this only exists so a
    /// typo is caught before a network round trip.
    public static func looksLikeAnAddress(_ value: String) -> Bool {
        let address = bareAddress(value)
        guard let at = address.firstIndex(of: "@"), at != address.startIndex else { return false }
        let domain = address[address.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !address.contains(" ")
    }
}
