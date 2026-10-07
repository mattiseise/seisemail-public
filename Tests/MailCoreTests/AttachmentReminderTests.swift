import Foundation
import Testing
@testable import MailCore

@Suite struct AttachmentReminderTests {
    @Test(arguments: [
        "Laitan liitteen tähän.", "Liitteenä kuitti", "liitteet ohessa", "Katso liite", "Tiedot liitteessä",
        "Ohessa tarjous", "Please see attached", "The attachment is here", "Enclosed you'll find",
    ])
    func mentions(_ body: String) {
        #expect(AttachmentReminder.mentionsAttachment(in: body))
    }

    @Test(arguments: ["Moi, nähdään huomenna", "Liisa tulee myös", "Kiitos!"])
    func doesNotMention(_ body: String) {
        #expect(!AttachmentReminder.mentionsAttachment(in: body))
    }

    @Test func ignoresQuoteSignatureAndForwardedPart() {
        #expect(!AttachmentReminder.mentionsAttachment(in: "Kiitos!\n\nPe 1.9.2026 klo 9.00 Matti kirjoitti:\n> Liitteenä lasku"))
        #expect(!AttachmentReminder.mentionsAttachment(in: "Kiitos!\n\n-- \nLiitteet: ks. example.fi"))
        #expect(!AttachmentReminder.mentionsAttachment(in: "Tiedoksi\n\n---------- Välitetty viesti ----------\nLiitteenä kuitti"))
    }

    @Test func warnsOnlyWithoutAttachments() {
        var draft = Draft(body: "Liitteenä kuitti")
        #expect(AttachmentReminder.shouldWarn(draft))
        draft.attachments = [.file(URL(fileURLWithPath: "/tmp/k.pdf"))]
        #expect(!AttachmentReminder.shouldWarn(draft))
    }
}
