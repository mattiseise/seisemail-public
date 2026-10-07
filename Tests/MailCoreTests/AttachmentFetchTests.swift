import Foundation
import Testing
@testable import MailCore

@Suite struct AttachmentFetchTests {
    let api = FakeGmail()
    let dir = makeTempDir()

    func attachment(part: String = "2", id: String? = "a1", name: String = "lasku.pdf", mime: String = "application/pdf",
                    size: Int = 3, inline: Data? = nil) -> MailCore.Attachment {
        MailCore.Attachment(messageID: "m1", partID: part, attachmentID: id, filename: name, mimeType: mime, size: size, inlineData: inline)
    }

    var downloads: Int { api.calls.filter { $0.hasPrefix("attachment") }.count }

    @Test func downloadsOnceThenServesFromCache() async throws {
        api.update { $0.attachments["a1"] = Data("PDF".utf8) }
        let first = try await AttachmentFetch.file(for: attachment(), api: api, directory: dir)
        let second = try await AttachmentFetch.file(for: attachment(), api: api, directory: dir)
        #expect(first == second)
        #expect(downloads == 1)
        #expect(try Data(contentsOf: first) == Data("PDF".utf8))
        #expect(first.path.hasSuffix("/m1/2/lasku.pdf"))
    }

    @Test func sizeMismatchDownloadsAgain() async throws {
        api.update { $0.attachments["a1"] = Data("PDF".utf8) }
        let url = AttachmentFetch.cacheURL(for: attachment(), in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PD".utf8).write(to: url)                       // a cut-off earlier download
        _ = try await AttachmentFetch.file(for: attachment(), api: api, directory: dir)
        #expect(downloads == 1)
        #expect(try Data(contentsOf: url) == Data("PDF".utf8))
    }

    @Test func inlineDataNeedsNoDownload() async throws {
        let url = try await AttachmentFetch.file(for: attachment(id: nil, inline: Data("PDF".utf8)), api: api, directory: dir)
        #expect(downloads == 0)
        #expect(try Data(contentsOf: url) == Data("PDF".utf8))
    }

    @Test func sameNameInOneMessageDoesNotOverwrite() async throws {
        api.update { $0.attachments = ["a1": Data("one".utf8), "a2": Data("two".utf8)] }
        let one = try await AttachmentFetch.file(for: attachment(part: "1", id: "a1"), api: api, directory: dir)
        let two = try await AttachmentFetch.file(for: attachment(part: "2", id: "a2"), api: api, directory: dir)
        #expect(one != two)
        #expect(one.lastPathComponent == two.lastPathComponent)
        #expect(try Data(contentsOf: one) == Data("one".utf8))
        #expect(try Data(contentsOf: two) == Data("two".utf8))
    }

    @Test func missingDataIsNotFound() async {
        await #expect(throws: AttachmentFetch.Failure.notFound) {
            _ = try await AttachmentFetch.file(for: attachment(id: nil), api: api, directory: dir)
        }
    }

    @Test func rateLimitedDownloadGivesQuotaText() async {
        api.update { $0.offline = true }
        do {
            _ = try await AttachmentFetch.file(for: attachment(), api: api, directory: dir)
            Issue.record("expected an error")
        } catch {
            #expect(AttachmentFetch.message(for: error) == "Liitettä ei voitu ladata – ei verkkoyhteyttä.")
        }
        #expect(AttachmentFetch.message(for: GmailError.rateLimited)
                == "Liitteen lataus epäonnistui: Gmailin pyyntöraja on täynnä. Yritä uudelleen minuutin päästä.")
    }

    @Test func messagesPerFailureKind() {
        #expect(AttachmentFetch.message(for: GmailError.decoding) == "Liitteen sisältö oli viallinen.")
        #expect(AttachmentFetch.message(for: AttachmentFetch.Failure.notFound) == "Liitettä ei löytynyt viestistä.")
        #expect(AttachmentFetch.message(for: GmailError.http(404, "")) == "Liitettä ei löytynyt viestistä.")
        #expect(AttachmentFetch.message(for: AttachmentFetch.Failure.write) == "Liitteen tallennus epäonnistui.")
        #expect(AttachmentFetch.message(for: GmailError.http(500, "")) == "Liitteen lataus epäonnistui (Gmail-virhe 500).")
        #expect(AttachmentFetch.message(for: URLError(.badURL)) == "Liitteen lataus epäonnistui")
    }

    @Test(arguments: [
        ("a/b:c.pdf", "application/pdf", "a-b-c.pdf"),
        ("liite", "application/pdf", "liite.pdf"),
        ("raportti", "image/png", "raportti.png"),
        ("scan.PDF", "application/pdf", "scan.PDF"),
        ("scan.2024", "application/pdf", "scan.2024.pdf"),
        ("muistio.txt", "application/pdf", "muistio.txt"),
        ("..", "application/octet-stream", "liite"),
        ("..piilo.pdf", "application/pdf", "piilo.pdf"),
        ("  tyhjä  ", "application/octet-stream", "tyhjä"),
        ("rivi\nvaihto.pdf", "application/pdf", "rivivaihto.pdf"),
    ])
    func fileNameCleanup(_ input: String, _ mime: String, _ expected: String) {
        #expect(AttachmentFetch.fileName(for: attachment(name: input, mime: mime)) == expected)
    }

    @Test func fileNameIsNFC() {
        let decomposed = "A\u{0308}iti.pdf"                       // Ä as A + combining diaeresis
        let name = AttachmentFetch.fileName(for: attachment(name: decomposed))
        #expect(name == "\u{00C4}iti.pdf")
        #expect(name.unicodeScalars.count == 8)
    }

    @Test func longNameKeepsExtension() {
        let name = AttachmentFetch.fileName(for: attachment(name: String(repeating: "ä", count: 300) + ".pdf"))
        #expect(name.utf8.count <= 200)
        #expect(name.hasSuffix(".pdf"))
    }

    @Test func findsAttachmentForLink() throws {
        let a = attachment(part: "root")
        let message = Message(id: "m1", threadID: "t1", from: nil, replyTo: [], to: [], cc: [], date: .distantPast,
                              subject: "", snippet: "", textBody: nil, htmlBody: nil, attachments: [a], labelIDs: [],
                              messageIDHeader: nil, references: nil)
        let action = try #require(ThreadHTML.attachmentAction(from: URL(string: "mak8r-attachment://preview/m1/root")!))
        #expect(action.partID == "root")
        #expect(AttachmentFetch.attachment(for: action, in: MailThread(id: "t1", messages: [message])) == a)
        let missing = ThreadHTML.AttachmentAction(kind: .save, messageID: "m1", partID: "9")
        #expect(AttachmentFetch.attachment(for: missing, in: MailThread(id: "t1", messages: [message])) == nil)
    }

    @Test func topLevelAttachmentGetsRootPartID() throws {
        let dto = try JSONDecoder().decode(GmailMessageDTO.self, from: json([
            "id": "m1", "threadId": "t1",
            "payload": ["partId": "", "mimeType": "application/pdf", "filename": "doc.pdf",
                        "body": ["attachmentId": "a1", "size": 10]],
        ]))
        let message = MessageParser.message(dto)
        #expect(message.attachments.map(\.partID) == ["root"])
        let html = ThreadHTML.document(for: MailThread(id: "t1", messages: [message]), me: nil)
        #expect(html.contains("mak8r-attachment://preview/m1/root"))
    }
}
