import Foundation
import Testing
@testable import MailCore

@Suite struct ComposeFactoryTests {
    let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    func sampleMessage(
        from: MailAddress = MailAddress(name: "Matti", email: "matti@example.fi"),
        replyTo: [MailAddress] = [],
        to: [MailAddress] = [MailAddress(name: "Maija", email: "maija.meikalainen@gmail.com"), MailAddress(name: "Liisa", email: "liisa@example.fi")],
        cc: [MailAddress] = [MailAddress(name: nil, email: "pekka@example.fi"), MailAddress(name: nil, email: "LIISA@example.fi")],
        subject: String = "Tapaaminen",
        text: String? = "Rivi 1\n\nRivi 3",
        html: String? = nil
    ) -> Message {
        Message(
            id: "m1", threadID: "t1", from: from, replyTo: replyTo, to: to, cc: cc,
            // Fri 2026-09-25 07:42 UTC = 10.42 Helsinki
            date: Date(timeIntervalSince1970: 1_790_322_120),
            subject: subject, snippet: "", textBody: text, htmlBody: html,
            attachments: [Attachment(messageID: "m1", partID: "1", attachmentID: "a1", filename: "agenda.pdf", mimeType: "application/pdf", size: 10)],
            labelIDs: [], messageIDHeader: "<m1@example.fi>", references: "<m0@example.fi>"
        )
    }

    func thread(_ m: Message) -> MailThread { MailThread(id: "t1", messages: [m]) }

    @Test func attributionIsFinnish() {
        #expect(ComposeFactory.attribution(for: sampleMessage(), timeZone: helsinki) == "Pe 25.9.2026 klo 10.42 Matti kirjoitti:")
    }

    @Test func replyAddressesSenderAndQuotes() {
        let m = sampleMessage()
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: false, timeZone: helsinki)
        #expect(d.to == "\"Matti\" <matti@example.fi>")
        #expect(d.cc.isEmpty)
        #expect(d.subject == "Re: Tapaaminen")
        #expect(d.threadID == "t1")
        #expect(d.inReplyTo == "<m1@example.fi>")
        #expect(d.references == "<m0@example.fi> <m1@example.fi>")
        #expect(d.body == "\n\nPe 25.9.2026 klo 10.42 Matti kirjoitti:\n> Rivi 1\n>\n> Rivi 3")
        #expect(d.attachments.isEmpty)
    }

    @Test func replyPrefersReplyTo() {
        let m = sampleMessage(replyTo: [MailAddress(name: nil, email: "work@example.fi")])
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: false, timeZone: helsinki)
        #expect(d.to == "work@example.fi")
    }

    @Test func subjectPrefixNotDoubled() {
        let m = sampleMessage(subject: "RE: Tapaaminen")
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "x@y.fi", all: false, timeZone: helsinki)
        #expect(d.subject == "RE: Tapaaminen")
    }

    @Test func replyAllExcludesSelfCaseInsensitive() {
        let m = sampleMessage()
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: true, timeZone: helsinki)
        let to = AddressParser.parseList(d.to).map { $0.email.lowercased() }
        let cc = AddressParser.parseList(d.cc).map { $0.email.lowercased() }
        #expect(to == ["matti@example.fi", "liisa@example.fi"])
        #expect(cc == ["pekka@example.fi"])
    }

    @Test func replyToOwnMessageGoesToOriginalRecipients() {
        let m = sampleMessage(from: MailAddress(name: "Maija", email: "maija.meikalainen@gmail.com"),
                              to: [MailAddress(name: nil, email: "matti@example.fi")], cc: [])
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: false, timeZone: helsinki)
        #expect(d.to == "matti@example.fi")
    }

    @Test func replyQuotesHtmlOnlyMessage() {
        let m = sampleMessage(text: nil, html: "<p>Hei <b>Maija</b></p><p>Moi</p>")
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "x@y.fi", all: false, timeZone: helsinki)
        #expect(d.body.hasSuffix("> Hei Maija\n> Moi"))
    }

    @Test func forwardCarriesAttachmentsAndHeader() {
        let m = sampleMessage()
        let d = ComposeFactory.forward(m, in: thread(m), timeZone: helsinki)
        #expect(d.subject == "Fwd: Tapaaminen")
        #expect(d.to.isEmpty)
        #expect(d.threadID == nil)
        #expect(d.body.contains("---------- Välitetty viesti ----------"))
        #expect(d.body.contains("Lähettäjä: \"Matti\" <matti@example.fi>"))
        #expect(d.body.contains("Aihe: Tapaaminen"))
        #expect(d.body.hasSuffix("Rivi 1\n\nRivi 3"))
        #expect(d.attachments.map(\.filename) == ["agenda.pdf"])
    }

    @Test func replyAllShowsNonASCIINamesReadably() {
        let m = sampleMessage(
            from: MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi"),
            to: [MailAddress(name: "Pekka Järvinen", email: "p@x.fi"), MailAddress(name: "Maija", email: "maija.meikalainen@gmail.com")],
            cc: [MailAddress(name: "Sörén Öst", email: "s@x.fi")]
        )
        let d = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: true, timeZone: helsinki)
        #expect(d.to == "\"Mäkinen Åsa\" <asa@x.fi>, \"Pekka Järvinen\" <p@x.fi>")
        #expect(d.cc == "\"Sörén Öst\" <s@x.fi>")
        #expect(!d.to.contains("=?") && !d.cc.contains("=?"))
    }

    @Test func forwardHeaderShowsNonASCIINamesReadably() {
        let m = sampleMessage(
            from: MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi"),
            to: [MailAddress(name: "Pekka Järvinen", email: "p@x.fi")]
        )
        let d = ComposeFactory.forward(m, in: thread(m), timeZone: helsinki)
        #expect(d.body.contains("Lähettäjä: \"Mäkinen Åsa\" <asa@x.fi>"))
        #expect(d.body.contains("Vastaanottaja: \"Pekka Järvinen\" <p@x.fi>"))
        #expect(!d.body.contains("=?"))
    }

    @Test func newDraftIsEmpty() {
        let d = ComposeFactory.new()
        #expect(d.to.isEmpty && d.subject.isEmpty && d.body.isEmpty && d.threadID == nil)
    }

    @Test func newMessageGetsSignature() {
        let sig = Signature(name: "Lyhyt", text: "-S")
        let draft = ComposeFactory.new(signature: sig)
        #expect(draft.body == "\n\n-- \n-S")
        #expect(draft.signatureID == sig.id)
        #expect(ComposeFactory.new().body == "")
    }

    @Test func replySignatureGoesAboveQuote() {
        let sig = Signature(name: "Lyhyt", text: "-S")
        let m = sampleMessage()
        let plain = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: false, timeZone: helsinki)
        let signed = ComposeFactory.reply(to: m, in: thread(m), me: "maija.meikalainen@gmail.com", all: false, signature: sig, timeZone: helsinki)
        #expect(signed.body == "\n\n-- \n-S" + plain.body)
        #expect(signed.signatureID == sig.id)
    }

    @Test func forwardSignatureGoesAboveForwardedMessage() {
        let sig = Signature(name: "Lyhyt", text: "-S")
        let m = sampleMessage()
        let plain = ComposeFactory.forward(m, in: thread(m), timeZone: helsinki)
        let signed = ComposeFactory.forward(m, in: thread(m), signature: sig, timeZone: helsinki)
        #expect(signed.body == "\n\n-- \n-S" + plain.body)
    }
}
