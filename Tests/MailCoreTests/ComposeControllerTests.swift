import Foundation
import Testing
@testable import MailCore

@Suite struct ComposeControllerTests {
    let api = FakeGmail()
    let drafts = DraftStore(directory: makeTempDir())

    func controller(files: [String: Data] = [:]) -> ComposeController {
        ComposeController(api: api, drafts: drafts, readFile: { url in
            guard let data = files[url.lastPathComponent] else { throw CocoaError(.fileNoSuchFile) }
            return data
        })
    }

    @Test func noRecipientsIsRejected() async {
        await #expect(throws: ComposeError.noRecipients) {
            try await controller().send(Draft(subject: "x", body: "y"), from: "me@x.fi")
        }
        #expect(api.calls.isEmpty)
    }

    @Test func invalidAddressIsRejected() async {
        await #expect(throws: ComposeError.invalidAddress("foo")) {
            try await controller().send(Draft(to: "a@b.fi, foo"), from: "me@x.fi")
        }
    }

    @Test func sendsReplyInThreadAndDeletesDraft() async throws {
        let draft = Draft(to: "Matti <matti@x.fi>", subject: "Re: Hei", body: "Moi", threadID: "t1",
                          inReplyTo: "<m1@x.fi>", references: "<m1@x.fi>")
        try drafts.save(draft)
        try await controller().send(draft, from: "maija.meikalainen@gmail.com")
        let sent = try #require(api.state.withLock { $0.sent.first })
        #expect(sent.1 == "t1")
        let raw = String(decoding: sent.0, as: UTF8.self)
        #expect(raw.contains("To: \"Matti\" <matti@x.fi>"))
        #expect(raw.contains("From: maija.meikalainen@gmail.com"))
        #expect(raw.contains("In-Reply-To: <m1@x.fi>"))
        #expect(drafts.all().isEmpty)
    }

    @Test func readableReplyAddressesAreEncodedOnSend() async throws {
        let m = Message(
            id: "m1", threadID: "t1", from: MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi"), replyTo: [],
            to: [MailAddress(name: "Pekka Järvinen", email: "p@x.fi")], cc: [MailAddress(name: "Virtanen, Äijö", email: "aijo@x.fi")],
            date: Date(timeIntervalSince1970: 0), subject: "Hei", snippet: "", textBody: "x", htmlBody: nil,
            attachments: [], labelIDs: [], messageIDHeader: "<m1@x.fi>", references: nil
        )
        let draft = ComposeFactory.reply(to: m, in: MailThread(id: "t1", messages: [m]), me: "me@x.fi", all: true)
        try await controller().send(draft, from: "me@x.fi")
        let raw = String(decoding: try #require(api.state.withLock { $0.sent.first }).0, as: UTF8.self)
        // The header's value with folding undone.
        func header(_ name: String) throws -> String {
            let lines = raw.components(separatedBy: "\r\n")
            let start = try #require(lines.firstIndex { $0.hasPrefix("\(name): ") })
            var value = String(lines[start].dropFirst(name.count + 2))
            for line in lines[(start + 1)...] {
                guard line.hasPrefix(" ") else { break }
                value += line
            }
            return value
        }
        let to = try header("To")
        let cc = try header("Cc")
        #expect(to.contains("=?UTF-8?B?"))
        #expect(!to.unicodeScalars.contains { !$0.isASCII })
        #expect(AddressParser.parseList(to) == [
            MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi"),
            MailAddress(name: "Pekka Järvinen", email: "p@x.fi"),
        ])
        #expect(AddressParser.parseList(cc) == [MailAddress(name: "Virtanen, Äijö", email: "aijo@x.fi")])
    }

    @Test func fetchesGmailAndFileAttachments() async throws {
        api.update { $0.attachments["a1"] = Data("PDF".utf8) }
        let draft = Draft(to: "a@b.fi", attachments: [
            .gmail(Attachment(messageID: "m1", partID: "1", attachmentID: "a1", filename: "agenda.pdf", mimeType: "application/pdf", size: 3)),
            .file(URL(fileURLWithPath: "/tmp/kuva.png")),
        ])
        try await controller(files: ["kuva.png": Data([0x89, 0x50])]).send(draft, from: "me@x.fi")
        #expect(api.calls.contains("attachment m1/a1"))
        let raw = String(decoding: api.state.withLock { $0.sent[0].0 }, as: UTF8.self)
        #expect(raw.contains("filename=\"agenda.pdf\""))
        #expect(raw.contains("Content-Type: image/png; name=\"kuva.png\""))
    }

    @Test func inlineAttachmentDataIsUsedWithoutFetch() async throws {
        let draft = Draft(to: "a@b.fi", attachments: [
            .gmail(Attachment(messageID: "m1", partID: "1", attachmentID: nil, filename: "x.txt", mimeType: "text/plain", size: 1, inlineData: Data("x".utf8))),
        ])
        try await controller().send(draft, from: "me@x.fi")
        #expect(!api.calls.contains { $0.hasPrefix("attachment") })
    }

    @Test func oversizedMessageIsRejectedBeforeSending() async {
        let big = Data(count: 36 * 1024 * 1024)
        let draft = Draft(to: "a@b.fi", attachments: [.file(URL(fileURLWithPath: "/tmp/big.bin"))])
        await #expect(throws: ComposeError.tooLarge) {
            try await controller(files: ["big.bin": big]).send(draft, from: "me@x.fi")
        }
        #expect(!api.calls.contains { $0.hasPrefix("send") })
    }

    @Test func failedSendKeepsDraft() async throws {
        api.update { $0.failing.insert("send") }
        let draft = Draft(to: "a@b.fi", body: "tärkeä")
        try drafts.save(draft)
        await #expect(throws: GmailError.self) { try await controller().send(draft, from: "me@x.fi") }
        #expect(drafts.all().map(\.body) == ["tärkeä"])
    }

    @Test func mimeTypeFromFilename() {
        #expect(ComposeController.mimeType(forFilename: "a.pdf") == "application/pdf")
        #expect(ComposeController.mimeType(forFilename: "a.PNG") == "image/png")
        #expect(ComposeController.mimeType(forFilename: "noext") == "application/octet-stream")
    }

    @Test func validateChecksRecipientsWithoutSending() {
        #expect(throws: ComposeError.noRecipients) { try ComposeController.validate(Draft(subject: "x")) }
        #expect(throws: ComposeError.invalidAddress("foo")) { try ComposeController.validate(Draft(to: "foo")) }
        #expect(throws: Never.self) { try ComposeController.validate(Draft(to: "a@b.fi")) }
    }
}
