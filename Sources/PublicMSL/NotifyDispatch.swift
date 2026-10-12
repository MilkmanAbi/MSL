// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// Decides who gets told what, and sends it.
///
/// Kept apart from `PublicMSLManager` because the decisions here - has this
/// person had their key, has the address actually changed, have they had
/// enough emails today - are worth testing without a virtual machine or a
/// network anywhere near them.
public enum NotifyDispatch {

    /// What should happen for one recipient, given where things stand.
    public enum Action: Equatable {
        /// First contact: make them a key, let it into the guest, email it.
        case inviteWithKey
        /// They have the key; the address moved.
        case announceNewAddress
        /// Nothing to say.
        case nothing(why: String)
    }

    /// The rule, in one place.
    ///
    /// Deliberately total and deliberately boring: every email MSL sends
    /// unprompted comes through here, so it should be possible to read this
    /// and know exactly what will land in somebody's inbox.
    public static func decide(for recipient: NotifyRecipient, address: String,
                              cap: Int) -> Action {
        if !recipient.keyDelivered { return .inviteWithKey }
        guard recipient.lastAddressSent != address else {
            return .nothing(why: "they already have this address")
        }
        guard recipient.sentToday < cap else {
            return .nothing(why: "they have had \(recipient.sentToday) today, which is the limit")
        }
        return .announceNewAddress
    }

    /// Carries out the decision for every recipient of one instance.
    ///
    /// `authorize` puts a public key into the guest - passed in rather than
    /// reached for, so the whole path can be exercised with no guest.
    /// Failures are returned, never thrown: an email that will not send
    /// must not stop an instance being published.
    @discardableResult
    public static func run(instance: String, endpoint: PublicEndpoint,
                           senderName: String?,
                           authorize: (String, String) -> Bool,
                           deauthorize: (String) -> Void = { _ in },
                           send: (MailMessage) throws -> Void,
                           log: (String) -> Void = { _ in }) -> [String] {
        var recipients = NotifyRoster.load(instance: instance)
        guard !recipients.isEmpty else { return [] }
        let cap = NotifySettings.load()?.rotationEmailsPerDay ?? 3
        let address = "\(endpoint.host):\(endpoint.port)"
        var failures: [String] = []

        for index in recipients.indices {
            recipients[index].startOfDayIfNeeded()
            let recipient = recipients[index]
            switch decide(for: recipient, address: address, cap: cap) {
            case .nothing(let why):
                log("not emailing \(recipient.email): \(why)")

            case .inviteWithKey:
                guard let pair = RecipientKey.generate(forEmail: recipient.email, instance: instance) else {
                    failures.append("couldn't make a key for \(recipient.email)")
                    continue
                }
                // Into the guest first. Emailing somebody a key that will
                // not open anything is worse than not emailing them.
                guard authorize(pair.publicKey, recipient.label) else {
                    failures.append("couldn't let \(recipient.email)'s key into \(instance)")
                    continue
                }
                var message = NotifyMessages.invitation(
                    instance: instance, endpoint: endpoint,
                    privateKey: pair.privateKey, senderName: senderName)
                message.to = [recipient.email]
                do {
                    try send(message)
                    recipients[index].keyDelivered = true
                    recipients[index].lastAddressSent = address
                    log("sent \(recipient.email) their key and the address")
                } catch {
                    // **Take the key back out.** It was authorized a moment
                    // ago on the assumption the email would arrive; it did
                    // not, so nobody has it and nobody ever will. Leaving
                    // it would be access granted to a person who was never
                    // told - a key in the guest that matches nothing
                    // anyone holds, which is pure liability and invisible
                    // in `msl public keys` as anything but a real user.
                    deauthorize(pair.publicKey)
                    failures.append("\(recipient.email): \(error)")
                }

            case .announceNewAddress:
                var message = NotifyMessages.addressChanged(instance: instance, endpoint: endpoint)
                message.to = [recipient.email]
                do {
                    try send(message)
                    recipients[index].lastAddressSent = address
                    recipients[index].sentToday += 1
                    log("told \(recipient.email) the new address")
                } catch {
                    failures.append("\(recipient.email): \(error)")
                }
            }
        }
        NotifyRoster.save(recipients, instance: instance)
        return failures
    }
}
