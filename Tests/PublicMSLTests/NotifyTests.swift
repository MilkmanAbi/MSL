import XCTest
@testable import PublicMSL

/// Who gets emailed, and when.
///
/// Every unprompted email MSL sends goes through `NotifyDispatch.decide`,
/// so these are the rules for what lands in somebody else's inbox.
final class NotifyDecisionTests: XCTestCase {

    private func recipient(keyDelivered: Bool = true, lastAddress: String? = nil,
                           sentToday: Int = 0) -> NotifyRecipient {
        var person = NotifyRecipient(email: "sam@work.com", label: "Sam")
        person.keyDelivered = keyDelivered
        person.lastAddressSent = lastAddress
        person.sentToday = sentToday
        return person
    }

    func testSomebodyNewGetsTheirKey() {
        XCTAssertEqual(NotifyDispatch.decide(for: recipient(keyDelivered: false),
                                             address: "host:22", cap: 3),
                       .inviteWithKey)
    }

    func testTheKeyIsOnlyEverSentOnce() {
        // The second email must not carry a second key: it would be a new
        // one, which would make their saved file stop working.
        let action = NotifyDispatch.decide(for: recipient(lastAddress: "old:1"),
                                           address: "new:2", cap: 3)
        XCTAssertEqual(action, .announceNewAddress)
    }

    func testAnUnchangedAddressIsNeverAnnounced() {
        // The watcher re-runs on every publish, including ones where the
        // address came back identical. Without this, republishing would
        // email everybody for nothing.
        let action = NotifyDispatch.decide(for: recipient(lastAddress: "same:1"),
                                           address: "same:1", cap: 3)
        XCTAssertEqual(action, .nothing(why: "they already have this address"))
    }

    func testTheDailyCapStopsTheHourlyDrip() {
        // A free relay rotates hourly: 24 emails a day, per person, for
        // something they read once.
        let action = NotifyDispatch.decide(for: recipient(lastAddress: "old:1", sentToday: 3),
                                           address: "new:2", cap: 3)
        guard case .nothing = action else {
            return XCTFail("a recipient at the cap must not be emailed again")
        }
    }

    func testTheCapNeverBlocksTheFirstEmail() {
        // Somebody added late in a busy day still needs their key, or they
        // simply cannot get in.
        let action = NotifyDispatch.decide(for: recipient(keyDelivered: false, sentToday: 99),
                                           address: "new:2", cap: 3)
        XCTAssertEqual(action, .inviteWithKey)
    }

    func testTheCounterRollsOverAtMidnight() {
        var person = recipient(lastAddress: "old:1", sentToday: 3)
        person.sentOn = "2000-01-01"
        person.startOfDayIfNeeded()
        XCTAssertEqual(person.sentToday, 0)
        XCTAssertEqual(person.sentOn, NotifyRecipient.today())
    }
}

/// The emails themselves.
final class NotifyMessageTests: XCTestCase {

    private let endpoint = PublicEndpoint(
        host: "abcd-1-2-3-4.run.pinggy-free.link", port: 41234, user: "abi",
        identityFile: "/tmp/k", expires: nil, backend: "relay-pinggy")

    func testTheInvitationCarriesTheKeyAsAnAttachment() {
        let message = NotifyMessages.invitation(instance: "Ubuntu", endpoint: endpoint,
                                                privateKey: "PRIVATE-KEY-BODY", senderName: "Abi")
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.filename, "msl-ubuntu-key")
        XCTAssertEqual(String(decoding: message.attachments[0].data, as: UTF8.self), "PRIVATE-KEY-BODY")
        // The key must never be in the body as well - people forward emails.
        XCTAssertFalse(message.plainText.contains("PRIVATE-KEY-BODY"))
        XCTAssertFalse(message.html.contains("PRIVATE-KEY-BODY"))
    }

    func testTheInvitationContainsACommandThatWouldActuallyWork() {
        let message = NotifyMessages.invitation(instance: "Ubuntu", endpoint: endpoint,
                                                privateKey: "k", senderName: nil)
        XCTAssertTrue(message.plainText.contains("-p 41234"))
        XCTAssertTrue(message.plainText.contains("abi@abcd-1-2-3-4.run.pinggy-free.link"))
        // Without this the key is world-readable and ssh refuses it, which
        // is the single most common first-time failure.
        XCTAssertTrue(message.plainText.contains("chmod 600"))
    }

    func testTheRotationEmailHasNoKeyAndSaysSo() {
        let message = NotifyMessages.addressChanged(instance: "Ubuntu", endpoint: endpoint)
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertTrue(message.plainText.lowercased().contains("same key"))
    }

    func testAnInstanceNameCannotInjectHTML() {
        // Instance names are free text and end up in an email body.
        let message = NotifyMessages.addressChanged(
            instance: "<img src=x onerror=alert(1)>", endpoint: endpoint)
        XCTAssertFalse(message.html.contains("<img"))
        XCTAssertTrue(message.html.contains("&lt;img"))
    }

    func testTheFilenameSurvivesAnAwkwardInstanceName() {
        XCTAssertEqual(RecipientKey.filename(instance: "My Server/2"), "msl-my-server-2-key")
    }
}

/// Address handling.
final class MailAddressTests: XCTestCase {

    func testADisplayNameIsStrippedForTheEnvelope() {
        XCTAssertEqual(MailMessage.bareAddress("MSL <msl@example.com>"), "msl@example.com")
        XCTAssertEqual(MailMessage.bareAddress("  plain@example.com "), "plain@example.com")
    }

    func testObviousTyposAreCaughtBeforeANetworkRoundTrip() {
        XCTAssertTrue(MailMessage.looksLikeAnAddress("sam@work.com"))
        XCTAssertTrue(MailMessage.looksLikeAnAddress("Sam <sam@work.co.uk>"))
        XCTAssertFalse(MailMessage.looksLikeAnAddress("sam"))
        XCTAssertFalse(MailMessage.looksLikeAnAddress("@work.com"))
        XCTAssertFalse(MailMessage.looksLikeAnAddress("sam@work"))
        XCTAssertFalse(MailMessage.looksLikeAnAddress("sam @work.com"))
    }

    func testTheTestSenderIsRecognised() {
        XCTAssertTrue(ResendMailer(apiKey: "k", from: "onboarding@resend.dev").usesTestSender)
        XCTAssertFalse(ResendMailer(apiKey: "k", from: "msl@mycompany.com").usesTestSender)
    }

    func testTheDomainRefusalExplainsItself() {
        // Everybody hits this first, and "403" tells nobody anything.
        let message = ResendMailer.explain("MSL_HTTP 403", from: "onboarding@resend.dev",
                                           to: ["sam@work.com"])
        XCTAssertTrue(message.contains("resend.com/domains"))
        XCTAssertTrue(message.contains("sam@work.com"))
    }

    func testABadKeyIsNotBlamedOnTheDomain() {
        XCTAssertTrue(ResendMailer.explain("MSL_HTTP 401", from: "msl@x.com", to: ["a@b.com"])
            .contains("API key"))
    }

    func testTheRealBadKeyResponseIsRecognised() {
        // What Resend actually returns, captured from a live call. It is a
        // **400**, not the 401 the status alone would suggest, so matching
        // on the code let raw JSON through to the user.
        let real = #"{"message":"API key is invalid","name":"validation_error","statusCode":400} MSL_HTTP 400"#
        let message = ResendMailer.explain(real, from: "msl@x.com", to: ["a@b.com"])
        XCTAssertTrue(message.contains("resend.com/api-keys"))
        XCTAssertFalse(message.contains("statusCode"), "the user should not be shown raw JSON")
    }
}

/// What happens when the email does not go.
final class NotifyRollbackTests: XCTestCase {

    func testAFailedInvitationTakesTheKeyBackOut() {
        // Found live: a send failed on a bad API key and the recipient's
        // key stayed authorized in the guest. That is access granted to
        // somebody who was never told it existed - and it shows up in
        // `msl public keys` looking like a real person.
        let instance = "RollbackTest"
        NotifyRoster.save([NotifyRecipient(email: "sam@example.com", label: "Sam")],
                          instance: instance)
        defer { NotifyRoster.forget(instance: instance) }

        var authorized: [String] = []
        var deauthorized: [String] = []
        let endpoint = PublicEndpoint(host: "h", port: 1, user: "u", identityFile: "k",
                                      expires: nil, backend: "b")

        let failures = NotifyDispatch.run(
            instance: instance, endpoint: endpoint, senderName: nil,
            authorize: { key, _ in authorized.append(key); return true },
            deauthorize: { deauthorized.append($0) },
            send: { _ in throw MailError.sendFailed("no") })

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(authorized.count, 1, "the key goes in before the email is attempted")
        XCTAssertEqual(deauthorized, authorized, "and comes back out when the email fails")
        // And they are still owed their key next time round.
        XCTAssertEqual(NotifyRoster.load(instance: instance).first?.keyDelivered, false)
    }

    func testASuccessfulInvitationLeavesTheKeyInPlace() {
        let instance = "RollbackTest2"
        NotifyRoster.save([NotifyRecipient(email: "sam@example.com", label: "Sam")],
                          instance: instance)
        defer { NotifyRoster.forget(instance: instance) }

        var deauthorized: [String] = []
        let endpoint = PublicEndpoint(host: "h", port: 1, user: "u", identityFile: "k",
                                      expires: nil, backend: "b")
        let failures = NotifyDispatch.run(
            instance: instance, endpoint: endpoint, senderName: nil,
            authorize: { _, _ in true },
            deauthorize: { deauthorized.append($0) },
            send: { _ in })

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(deauthorized.isEmpty)
        XCTAssertEqual(NotifyRoster.load(instance: instance).first?.keyDelivered, true)
    }
}

/// The two forms of the connect command.
///
/// The local one names a file at /Users/Shared/MSL/keys/..., which exists
/// on exactly one computer. Sending that to a colleague reads as an
/// instruction they cannot follow, and the obvious guess - that they need
/// that exact path - is wrong.
final class ShareableCommandTests: XCTestCase {

    func testTheSharedFormHasNoLocalPath() {
        let endpoint = PublicEndpoint(
            host: "yqlnz-218-212-52-212.run.pinggy-free.link", port: 37829, user: "abinaash",
            identityFile: "/Users/Shared/MSL/keys/msl_public_Ubuntu",
            expires: nil, backend: "relay-pinggy")
        // `sshCommand` is the local one and keeps the real path.
        XCTAssertTrue(endpoint.sshCommand.contains("/Users/Shared/MSL/keys/msl_public_Ubuntu"))
    }

    func testTheEmailTellsThemWhereToPutTheKey() {
        // The email is the other place a path is handed to somebody else,
        // and it must name a file on *their* machine.
        let endpoint = PublicEndpoint(host: "h.example.net", port: 2222, user: "abi",
                                      identityFile: "/Users/Shared/MSL/keys/k",
                                      expires: nil, backend: "b")
        let message = NotifyMessages.invitation(instance: "Ubuntu", endpoint: endpoint,
                                                privateKey: "k", senderName: nil)
        XCTAssertFalse(message.plainText.contains("/Users/Shared"),
                       "a path on the sender's Mac means nothing to the recipient")
        XCTAssertTrue(message.plainText.contains("~/Downloads/msl-ubuntu-key"))
    }
}

/// Offering exactly one key.
///
/// A published instance allows a limited number of attempts per
/// connection. ssh offers every key its agent holds before the one named
/// by `-i`, so on a machine with a populated agent the server hangs up
/// before reaching the right key - and reports `Permission denied
/// (publickey)` about a key it never tried. Measured on a Windows laptop
/// with a key that was correct and worked from the Mac.
final class IdentitiesOnlyTests: XCTestCase {

    private let endpoint = PublicEndpoint(
        host: "h.example.net", port: 2222, user: "abi",
        identityFile: "/Users/Shared/MSL/keys/k", expires: nil, backend: "b")

    func testTheCommandMSLPrintsOffersOneKey() {
        XCTAssertTrue(endpoint.sshCommand.contains("-o IdentitiesOnly=yes"))
    }

    func testTheEmailedCommandOffersOneKey() {
        let message = NotifyMessages.invitation(instance: "Ubuntu", endpoint: endpoint,
                                                privateKey: "k", senderName: nil)
        XCTAssertTrue(message.plainText.contains("-o IdentitiesOnly=yes"))
        XCTAssertTrue(message.html.contains("IdentitiesOnly"))
    }

    func testTheRotationEmailOffersOneKeyToo() {
        let message = NotifyMessages.addressChanged(instance: "Ubuntu", endpoint: endpoint)
        XCTAssertTrue(message.plainText.contains("-o IdentitiesOnly=yes"))
    }

    func testTheAttemptLimitIsNotTighterThanTheDefault() {
        // Tightening it to 3 looked like sensible hardening and is what
        // caused the above: it counts every key offered, not every password
        // guessed, and buys almost nothing because the limit is per
        // connection and anything brute-forcing just reconnects.
        let command = PublicHardening.hardenCommand(convenienceKey: nil, user: "abi")
        XCTAssertTrue(command.contains("MaxAuthTries 6"))
        XCTAssertFalse(command.contains("MaxAuthTries 3"))
    }
}
