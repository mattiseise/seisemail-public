import Foundation
import Testing
@testable import MailCore

@Suite struct MessageParserTests {
    @Test func multipartMessageHasBodiesAndAttachment() throws {
        let thread = MessageParser.thread(try Fixture.thread("thread_full_multipart"))
        #expect(thread.messages.count == 2)
        let m = thread.messages[1]
        #expect(m.textBody == "Liitteenä agenda.\n\nLiisa")
        #expect(m.htmlBody?.contains("<b>agenda</b>") == true)
        #expect(m.attachments.count == 1)
        let a = try #require(m.attachments.first)
        #expect(a.filename == "agenda.pdf")
        #expect(a.mimeType == "application/pdf")
        #expect(a.attachmentID == "att1")
        #expect(a.messageID == "m2")
        #expect(a.size == 12345)
    }

    @Test func headersAreParsed() throws {
        let thread = MessageParser.thread(try Fixture.thread("thread_full_multipart"))
        let first = thread.messages[0]
        #expect(first.subject == "Tapaaminen torstaina")
        #expect(first.from == MailAddress(name: "Matti Meikäläinen", email: "matti@example.fi"))
        #expect(first.messageIDHeader == "<m1@example.fi>")
        #expect(first.date == Date(timeIntervalSince1970: 1_758_612_000))
        let second = thread.messages[1]
        #expect(second.to.map(\.email) == ["maija.meikalainen@gmail.com", "matti@example.fi"])
        #expect(second.cc == [MailAddress(name: "Pekka", email: "pekka@example.fi")])
        #expect(second.replyTo.map(\.email) == ["liisa.work@example.fi"])
        #expect(second.references == "<m1@example.fi>")
        #expect(second.isUnread)
        #expect(thread.subject == "Tapaaminen torstaina")
        #expect(thread.labelIDs.isSuperset(of: ["INBOX", "UNREAD", "STARRED"]))
    }

    @Test func latin1BodyDecodes() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_latin1")).messages[0]
        #expect(m.textBody == "Hyvää päivää, tässä uutiset.")
        #expect(m.subject == "Päivän uutiset")
    }

    @Test func splitAttachmentNameDecodes() throws {
        let bytes = Array("Päiväkirja.pdf".utf8)
        let first = Data(bytes[..<2]).base64EncodedString()
        let second = Data(bytes[2...]).base64EncodedString()
        let json = """
        {"id": "t9", "messages": [{"id": "m9", "threadId": "t9", "payload": {"mimeType": "multipart/mixed", "parts": [
          {"partId": "1", "mimeType": "application/pdf", "filename": "=?UTF-8?B?\(first)?= =?UTF-8?B?\(second)?=",
           "body": {"attachmentId": "a9", "size": 10}}
        ]}}]}
        """
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: Data(json.utf8))
        let m = MessageParser.thread(dto).messages[0]
        #expect(m.attachments.map(\.filename) == ["Päiväkirja.pdf"])
    }

    @Test func htmlOnlyMessage() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_html_only")).messages[0]
        #expect(m.textBody == nil)
        #expect(m.htmlBody?.contains("Viikon <b>tarjoukset</b>") == true)
        #expect(m.plainTextForQuoting == "Viikon tarjoukset\nKahvi 3 €")
    }

    @Test func summaryFromMetadata() throws {
        let s = MessageParser.summary(try Fixture.thread("thread_metadata"), me: "maija.meikalainen@gmail.com")
        #expect(s.id == "t1")
        #expect(s.subject == "Tapaaminen")
        #expect(s.isUnread)
        #expect(s.isStarred)
        #expect(s.hasAttachments)
        #expect(s.messageCount == 2)
        #expect(s.snippet == "It's liitteenä")
        #expect(s.date == Date(timeIntervalSince1970: 1_758_612_120))
        // Latest message is from me, so the row shows the other participant.
        #expect(s.sender == "Matti Meikäläinen")
    }

    @Test func summaryOnlyFromMeShowsMina() throws {
        var dto = try Fixture.thread("thread_metadata")
        dto.messages?.removeFirst()
        let s = MessageParser.summary(dto, me: "maija.meikalainen@gmail.com")
        #expect(s.sender == "Minä")
    }
}
