import Foundation
import Testing
@testable import MailCore

@Suite struct MessageBuilderTests {
    let me = MailAddress(name: "Maija", email: "maija.meikalainen@gmail.com")

    func message(subject: String = "Hei", body: String = "Moi!\nToinen rivi", attachments: [OutgoingAttachment] = []) -> OutgoingMessage {
        OutgoingMessage(
            from: me,
            to: [MailAddress(name: "Matti", email: "matti@example.fi")],
            cc: [MailAddress(name: nil, email: "pekka@example.fi")],
            bcc: [MailAddress(name: nil, email: "salainen@example.fi")],
            subject: subject,
            body: body,
            inReplyTo: "<m1@example.fi>",
            references: "<m0@example.fi> <m1@example.fi>",
            attachments: attachments,
            date: Date(timeIntervalSince1970: 1_758_612_000)
        )
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func headerBlock(_ raw: String) -> String {
        String(raw[..<raw.range(of: "\r\n\r\n")!.lowerBound])
    }

    @Test func writesHeaders() {
        let raw = text(MessageBuilder.build(message()))
        let headers = headerBlock(raw)
        #expect(headers.contains("From: \"Maija\" <maija.meikalainen@gmail.com>"))
        #expect(headers.contains("To: \"Matti\" <matti@example.fi>"))
        #expect(headers.contains("Cc: pekka@example.fi"))
        #expect(headers.contains("Bcc: salainen@example.fi"))
        #expect(headers.contains("Subject: Hei"))
        #expect(headers.contains("MIME-Version: 1.0"))
        #expect(headers.contains("In-Reply-To: <m1@example.fi>"))
        #expect(headers.contains("References: <m0@example.fi> <m1@example.fi>"))
        #expect(headers.contains("Date: "))
        #expect(headers.contains("Message-ID: <"))
    }

    @Test func encodesNonASCIISubject() {
        let raw = text(MessageBuilder.build(message(subject: "Hyvää päivää")))
        let subjectLine = headerBlock(raw).split(separator: "\r\n").first { $0.hasPrefix("Subject: ") }!
        #expect(subjectLine.hasPrefix("Subject: =?UTF-8?B?"))
        #expect(EncodedWords.decode(String(subjectLine.dropFirst(9))) == "Hyvää päivää")
    }

    @Test func singlePartBodyIsBase64UTF8() throws {
        let raw = text(MessageBuilder.build(message(body: "Hei äiti\nterveisiä")))
        #expect(raw.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(raw.contains("Content-Transfer-Encoding: base64"))
        let body = String(raw[raw.range(of: "\r\n\r\n")!.upperBound...]).replacingOccurrences(of: "\r\n", with: "")
        let decoded = try #require(Data(base64Encoded: body))
        #expect(String(decoding: decoded, as: UTF8.self) == "Hei äiti\r\nterveisiä")
    }

    @Test func omitsReplyHeadersWhenAbsent() {
        var m = message()
        m.inReplyTo = nil
        m.references = nil
        let headers = headerBlock(text(MessageBuilder.build(m)))
        #expect(!headers.contains("In-Reply-To"))
        #expect(!headers.contains("References"))
    }

    @Test func multipartWithAttachment() {
        let payload = Data((0..<200).map { UInt8($0) })
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "raportti.pdf", mimeType: "application/pdf", data: payload)]),
            boundary: "BOUNDARY"
        ))
        #expect(raw.contains("Content-Type: multipart/mixed; boundary=\"BOUNDARY\""))
        #expect(raw.contains("--BOUNDARY\r\nContent-Type: text/plain; charset=utf-8"))
        #expect(raw.contains("Content-Type: application/pdf; name=\"raportti.pdf\""))
        #expect(raw.contains("Content-Disposition: attachment; filename=\"raportti.pdf\""))
        #expect(raw.hasSuffix("--BOUNDARY--\r\n"))
        let lines = raw.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.count <= 998 })
        let attachmentBody = raw.components(separatedBy: "Content-Transfer-Encoding: base64\r\n\r\n").last!
            .components(separatedBy: "\r\n--BOUNDARY--")[0]
        #expect(attachmentBody.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(Data(base64Encoded: attachmentBody.replacingOccurrences(of: "\r\n", with: "")) == payload)
    }

    @Test func nonASCIIFilenameIsEncoded() {
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "kuva äiti.jpg", mimeType: "image/jpeg", data: Data([1]))]),
            boundary: "B"
        ))
        #expect(raw.contains("filename=\"=?UTF-8?B?"))
    }

    /// The header's value with folding undone, plus its physical lines.
    func header(_ name: String, in raw: String) -> (value: String, lines: [String])? {
        let lines = headerBlock(raw).components(separatedBy: "\r\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name):") }) else { return nil }
        var block = [lines[start]]
        for line in lines[(start + 1)...] {
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            block.append(line)
        }
        let value = block.joined(separator: "\r\n").dropFirst(name.count + 1)
            .replacingOccurrences(of: "\r\n", with: "").dropFirst()
        return (String(value), block)
    }

    /// The attachment part from its Content-Type line on, so `header(_:in:)` reads its headers.
    func attachmentPart(_ raw: String) -> String {
        String(raw[raw.range(of: "Content-Type: application/pdf")!.lowerBound...])
    }

    @Test func longNonASCIISubjectIsFoldedIntoShortEncodedWords() throws {
        let subject = "Hallituksen kokous: päätösvaltaisuus, isännöitsijän katsaus, järjestelmäviittaus ja muut asiat 👋 – " +
            String(repeating: "äöå", count: 30)
        let raw = text(MessageBuilder.build(message(subject: subject)))
        let h = try #require(header("Subject", in: raw))
        #expect(h.lines.count > 1)
        #expect(h.lines.allSatisfy { $0.count <= 78 })
        let words = h.value.matches(of: /=\?[^?]+\?[BbQq]\?[^?]*\?=/).map { String($0.output) }
        #expect(words.count == h.lines.count)
        #expect(words.allSatisfy { $0.count <= 75 })
        #expect(EncodedWords.decode(h.value) == subject)
        #expect(!h.value.unicodeScalars.contains { !$0.isASCII })
    }

    @Test func subjectIsSentAsNFC() throws {
        let nfd = "Pa\u{0308}iva\u{0308}"
        let raw = text(MessageBuilder.build(message(subject: nfd)))
        let decoded = EncodedWords.decode(try #require(header("Subject", in: raw)).value)
        #expect(decoded.unicodeScalars.map(\.value) == "Päivä".unicodeScalars.map(\.value))
        #expect(!decoded.unicodeScalars.contains { $0.value == 0x0308 })
    }

    @Test func nonASCIISubjectCannotInjectHeaders() {
        let raw = text(MessageBuilder.build(message(subject: "Hyvä\r\nBcc: x@evil.com")))
        let lines = raw.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("Bcc:") } == ["Bcc: salainen@example.fi"])
    }

    @Test func nonASCIIFilenameGetsRFC2231Parameter() throws {
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "Päiväkirja 1/2.pdf", mimeType: "application/pdf", data: Data([1]))]),
            boundary: "B"
        ))
        let h = try #require(header("Content-Disposition", in: attachmentPart(raw)))
        #expect(h.value.contains("filename*=UTF-8''P%C3%A4iv%C3%A4kirja%201%2F2.pdf"))
        #expect(h.value.contains("filename=\"=?UTF-8?B?"))
        #expect(h.lines.allSatisfy { $0.count <= 78 })
    }

    @Test func nfdFilenameIsSentAsNFC() throws {
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "ka\u{0308}vely.pdf", mimeType: "application/pdf", data: Data([1]))]),
            boundary: "B"
        ))
        let h = try #require(header("Content-Disposition", in: attachmentPart(raw)))
        #expect(h.value.contains("filename*=UTF-8''k%C3%A4vely.pdf"))
        let word = try #require(h.value.firstMatch(of: /filename="([^"]+)"/)).1
        let name = EncodedWords.decode(String(word))
        #expect(name == "k\u{00E4}vely.pdf")
        #expect(!name.unicodeScalars.contains { $0.value == 0x0308 })
        let type = try #require(header("Content-Type", in: attachmentPart(raw)))
        #expect(EncodedWords.decode(String(try #require(type.value.firstMatch(of: /name="([^"]+)"/)).1)) == "k\u{00E4}vely.pdf")
    }

    /// The RFC 2231 `filename*` value, joined from its `filename*0*=`… continuations if any.
    func extendedFilename(_ disposition: String) -> String? {
        let segments = disposition.matches(of: /filename\*(\d*)\*?=([^;\s]+)/)
            .map { (Int($0.1) ?? 0, String($0.2)) }
            .sorted { $0.0 < $1.0 }
        guard !segments.isEmpty else { return nil }
        let joined = segments.map(\.1).joined()
        guard joined.hasPrefix("UTF-8''") else { return nil }
        return String(joined.dropFirst(7)).removingPercentEncoding
    }

    /// Regression: name= and filename= put every encoded word on one line, so a filename
    /// over 42 UTF-8 bytes gave Content-Type lines of 120+ characters.
    @Test(arguments: [
        "Hallituksen kokouksen pöytäkirja 4-2026.pdf",
        "Hallituksen kokouksen pöytäkirja 4-2026 liitteineen.pdf",
        String(repeating: "Äänekosken pöytäkirja ", count: 10) + ".pdf",
        "Hallituksen_kokouksen_poytakirja_2026-04_liitteineen_lopullinen_versio_3.pdf",
        "Hallituksen kokouksen pöytäkirja ja liitteet \"lopullinen\" versio 3.pdf",
    ])
    func longFilenameHeadersFitLines(filename: String) throws {
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: filename, mimeType: "application/pdf", data: Data([1]))]),
            boundary: "B"
        ))
        let part = attachmentPart(raw)
        let lines = headerBlock(part).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.count <= 78 }, "\(lines.filter { $0.count > 78 })")
        #expect(!headerBlock(part).unicodeScalars.contains { !$0.isASCII })
        let expected = filename
        let type = try #require(header("Content-Type", in: part))
        let name = try #require(type.value.firstMatch(of: /name="([^"]+)"/)).1
        #expect(EncodedWords.decode(String(name)) == expected)
        let disposition = try #require(header("Content-Disposition", in: part))
        let quoted = try #require(disposition.value.firstMatch(of: /filename="([^"]+)"/)).1
        #expect(EncodedWords.decode(String(quoted)) == expected)
        #expect(extendedFilename(disposition.value) == filename)
    }

    @Test func longOfficeMIMETypeFitsLines() throws {
        let mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "Esitys äidille.pptx", mimeType: mime, data: Data([1]))]),
            boundary: "B"
        ))
        let part = String(raw[raw.range(of: "Content-Type:", options: [], range: raw.range(of: "--B\r\nContent-Type: text/plain")!.upperBound..<raw.endIndex)!.lowerBound...])
        #expect(headerBlock(part).components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        let type = try #require(header("Content-Type", in: part))
        #expect(type.value.hasPrefix(mime + "; name=\"=?UTF-8?B?"))
    }

    @Test func longAddressListFitsLines() throws {
        var m = message()
        m.to = [
            MailAddress(name: "Äänekosken kaupungin isännöitsijätoimiston päätösvaltainen hallitus", email: "h@x.fi"),
            MailAddress(name: "Pekka Järvinen", email: "pekka.jarvinen@example.fi"),
            MailAddress(name: "Sörén Öst-Mäkinen ja muut hallituksen jäsenet", email: "soren@example.fi"),
            MailAddress(name: "Matti", email: "matti.meikalainen.pitka.osoite@example.fi"),
        ]
        m.references = (1...8).map { "<message-\($0)-\(UUID().uuidString)@mail.example.fi>" }.joined(separator: " ")
        let raw = text(MessageBuilder.build(m))
        #expect(headerBlock(raw).components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        let to = try #require(header("To", in: raw))
        #expect(to.lines.count > 1)
        #expect(AddressParser.parseList(to.value) == m.to)
        #expect(try #require(header("References", in: raw)).value == m.references)
    }

    @Test func asciiFilenameHasNoExtendedParameter() {
        let raw = text(MessageBuilder.build(
            message(attachments: [OutgoingAttachment(filename: "raportti.pdf", mimeType: "application/pdf", data: Data([1]))]),
            boundary: "B"
        ))
        #expect(!raw.contains("filename*="))
    }

    @Test func longNonASCIINameUsesShortEncodedWords() throws {
        var m = message()
        m.to = [MailAddress(name: "Äänekosken kaupungin isännöitsijätoimiston päätösvaltainen hallitus", email: "h@x.fi")]
        let raw = text(MessageBuilder.build(m))
        let h = try #require(header("To", in: raw))
        let words = h.value.matches(of: /=\?[^?]+\?[BbQq]\?[^?]*\?=/).map { String($0.output) }
        #expect(words.count > 1)
        #expect(words.allSatisfy { $0.count <= 75 })
        #expect(AddressParser.parseList(h.value) == m.to)
    }

    @Test func usesCRLFOnly() {
        let raw = text(MessageBuilder.build(message()))
        #expect(!raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func headerValuesCannotInjectNewHeaders() {
        var m = message(subject: "Re: Hi\r\nBcc: x@evil.com")
        m.to = [MailAddress(name: "Evil\r\nBcc: y@evil.com", email: "a@b.fi")]
        m.references = "<a@b>\r\nBcc: z@evil.com"
        m.attachments = [OutgoingAttachment(filename: "x\r\nBcc: w@evil.com.pdf", mimeType: "application/pdf", data: Data([1]))]
        let raw = text(MessageBuilder.build(m, boundary: "B"))
        let lines = raw.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("Bcc:") } == ["Bcc: salainen@example.fi"])
    }
}
