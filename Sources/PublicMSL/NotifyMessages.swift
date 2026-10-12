// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MilkmanAbi

import Foundation

/// The two emails MSL sends.
///
/// Written for somebody who has never heard of MSL and does not want to.
/// They were sent a link to a machine; they want to be in it. So: the
/// command first, the explanation second, and nothing that needs reading
/// twice. No MSL branding beyond the name, no "exciting news", no emoji.
public enum NotifyMessages {

    /// The first email to a person: their key, and how to use it.
    public static func invitation(instance: String, endpoint: PublicEndpoint,
                                  privateKey: String, senderName: String?) -> MailMessage {
        let file = RecipientKey.filename(instance: instance)
        // IdentitiesOnly so the one key attached here is the one offered;
        // an agent with other keys loaded would otherwise use up the
        // server's attempts before reaching it.
        let command = "ssh -i ~/Downloads/\(file) -o IdentitiesOnly=yes "
            + "-p \(endpoint.port) \(endpoint.user)@\(endpoint.host)"
        let who = senderName.map { "\($0) has given you access to" } ?? "You have been given access to"

        let plain = """
        \(who) a Linux machine called \(instance).

        Two commands. The key is attached to this email - save it to your Downloads
        folder first.

          chmod 600 ~/Downloads/\(file)
          \(command)

        That is everything. You do not need to install anything; ssh is already on
        your Mac or Linux machine. On Windows it is in PowerShell.

        ABOUT THE ADDRESS
        The port above changes from time to time, and you will get a short email
        whenever it does. The key stays the same - you only ever save it once.

        ABOUT THE KEY
        The attached file is yours alone. Anyone holding it can log in as you, so
        keep it where you would keep a password. If you lose it, ask for a new one;
        the old one can be switched off on its own.
        """

        let html = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                    font-size:15px;line-height:1.55;color:#1d1d1f;max-width:560px">
          <p>\(escape(who)) a Linux machine called <strong>\(escape(instance))</strong>.</p>
          <p>Two commands. The key is attached &mdash; save it to your Downloads folder first.</p>
          <pre style="background:#f5f5f7;border-radius:8px;padding:14px;overflow-x:auto;
                      font-size:13px;line-height:1.5"><code>chmod 600 ~/Downloads/\(escape(file))
        \(escape(command))</code></pre>
          <p>That is everything. Nothing to install &mdash; <code>ssh</code> is already on your Mac or
             Linux machine, and on Windows it is in PowerShell.</p>
          <h3 style="font-size:15px;margin:22px 0 4px">About the address</h3>
          <p style="margin-top:0;color:#515154">The port changes from time to time, and you will get a
             short email whenever it does. The key stays the same &mdash; you only save it once.</p>
          <h3 style="font-size:15px;margin:22px 0 4px">About the key</h3>
          <p style="margin-top:0;color:#515154">The attached file is yours alone. Anyone holding it can
             log in as you, so keep it where you would keep a password. Lost it? Ask for a new one
             &mdash; the old one can be switched off by itself.</p>
        </div>
        """

        return MailMessage(
            from: "",
            to: [],
            subject: "Access to \(instance)",
            plainText: plain,
            html: html,
            attachments: [.init(filename: file, data: Data(privateKey.utf8))])
    }

    /// Every email after that: the address moved.
    public static func addressChanged(instance: String, endpoint: PublicEndpoint) -> MailMessage {
        let file = RecipientKey.filename(instance: instance)
        // IdentitiesOnly so the one key attached here is the one offered;
        // an agent with other keys loaded would otherwise use up the
        // server's attempts before reaching it.
        let command = "ssh -i ~/Downloads/\(file) -o IdentitiesOnly=yes "
            + "-p \(endpoint.port) \(endpoint.user)@\(endpoint.host)"

        let plain = """
        \(instance) has a new address. Same key as before - nothing to save.

          \(command)

        (The old address has stopped working. This happens every so often.)
        """

        let html = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                    font-size:15px;line-height:1.55;color:#1d1d1f;max-width:560px">
          <p><strong>\(escape(instance))</strong> has a new address. Same key as before &mdash;
             nothing to save.</p>
          <pre style="background:#f5f5f7;border-radius:8px;padding:14px;overflow-x:auto;
                      font-size:13px;line-height:1.5"><code>\(escape(command))</code></pre>
          <p style="color:#515154">The old address has stopped working. This happens every so often.</p>
        </div>
        """

        return MailMessage(from: "", to: [], subject: "\(instance): new address",
                           plainText: plain, html: html)
    }

    /// Sent by `msl public notify test`, so a setup can be proved before
    /// anybody is relying on it.
    public static func test(to address: String) -> MailMessage {
        let plain = """
        This is MSL checking that it can send you email.

        If you are reading it, the setup works: when you publish an instance,
        whoever you have added will get the address and their key here.
        """
        let html = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
                    font-size:15px;line-height:1.55;color:#1d1d1f;max-width:560px">
          <p>This is MSL checking that it can send you email.</p>
          <p>If you are reading it, the setup works: when you publish an instance, whoever you have
             added will get the address and their key here.</p>
        </div>
        """
        return MailMessage(from: "", to: [address], subject: "MSL can reach you",
                           plainText: plain, html: html)
    }

    /// HTML-escapes a value that came from a machine name, a hostname or a
    /// person's own text. These go into an email body, and an instance can
    /// be called anything.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
