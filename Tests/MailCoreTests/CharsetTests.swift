import Foundation
import Testing
@testable import MailCore

/// Body charset decoding. Regression for Matti's 2026-10-04 screenshots, where whole
/// Outlook/Exchange HTML bodies showed as UTF-8 read as Latin-1 ("pÃ¤Ã¤tÃ¶svaltaisuus").
@Suite struct CharsetTests {
    static let expectedPhrases = ["päätösvaltaisuus", "§ 3", "isännöitsijä", "Järjestelmäviittaus", "päivää", "12 €", "”Hallitus”", "–", "👋"]

    func expectClean(_ body: String?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let body else {
            Issue.record("body missing", sourceLocation: sourceLocation)
            return
        }
        #expect(!body.contains("Ã"), sourceLocation: sourceLocation)
        #expect(!body.contains("Â"), sourceLocation: sourceLocation)
        #expect(!body.unicodeScalars.contains { (0x80...0x9F).contains($0.value) }, sourceLocation: sourceLocation)
        for phrase in Self.expectedPhrases {
            #expect(body.contains(phrase), "missing \(phrase)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Whole-body regression fixtures

    @Test func utf8BodyWithOneStrayByteStaysUTF8() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_utf8_stray_byte")).messages[0]
        expectClean(m.htmlBody)
        expectClean(m.textBody)
        // The stray bytes themselves are read as windows-1252: 0xA0 is a no-break space, 0x96 an en dash.
        #expect(m.htmlBody?.contains("Hallituksen kokous\u{00A0}</p>") == true)
        #expect(m.textBody?.hasPrefix("Hallituksen kokous – 2026") == true)
        expectClean(m.plainTextForQuoting)
        #expect(m.from == MailAddress(name: "Mika Mäkinen", email: "mika@example.fi"))
    }

    @Test func declaredLatin1OverValidUTF8IsReadAsUTF8() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_utf8_declared_latin1")).messages[0]
        expectClean(m.htmlBody)
        expectClean(m.textBody)
    }

    @Test func declaredWindows1252OverUTF8WithStrayByteIsReadAsUTF8() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_utf8_declared_latin1")).messages[1]
        expectClean(m.htmlBody)
        expectClean(m.textBody)
    }

    @Test func trueLatin1FixtureStillDecodes() throws {
        let m = MessageParser.thread(try Fixture.thread("thread_full_latin1")).messages[0]
        #expect(m.textBody == "Hyvää päivää, tässä uutiset.")
    }

    // MARK: Charset.string

    @Test func validUTF8IsUnchanged() {
        let text = "Hyvää päivää – 12 € 👋 “lainaus”"
        #expect(Charset.string(from: Data(text.utf8), charset: "utf-8") == text)
        #expect(Charset.string(from: Data(text.utf8), charset: nil) == text)
    }

    @Test func strayByteOnlyAffectsItself() {
        var data = Data("päivä ".utf8)
        data.append(0x96)
        data.append(contentsOf: Array(" yö 👋".utf8))
        #expect(Charset.string(from: data, charset: "UTF-8") == "päivä – yö 👋")
        #expect(Charset.string(from: data, charset: nil) == "päivä – yö 👋")
    }

    @Test func truncatedSequenceIsReadAsSingleBytes() {
        // "ä" (C3 A4) cut after its lead byte, then ASCII.
        let data = Data([0x61, 0xC3, 0x62])
        #expect(Charset.string(from: data, charset: "utf-8") == "aÃb")
    }

    @Test func windows1252PunctuationDecodes() {
        let data = Data([0x80, 0x20, 0x96, 0x20, 0x93, 0x78, 0x94, 0x20, 0x92, 0x20, 0x85])
        let expected = "€ – “x” ’ …"
        #expect(Charset.string(from: data, charset: "iso-8859-1") == expected)
        #expect(Charset.string(from: data, charset: "latin1") == expected)
        #expect(Charset.string(from: data, charset: "windows-1252") == expected)
        #expect(Charset.string(from: data, charset: nil) == expected)
        #expect(Charset.string(from: data, charset: "utf-8") == expected)
    }

    @Test func noC1ControlCharactersFromSingleByteFallback() {
        let data = Data(0x80...0xFF)
        for charset in ["iso-8859-1", "windows-1252", "utf-8"] {
            let s = Charset.string(from: data, charset: charset)
            #expect(!s.unicodeScalars.contains { (0x80...0x9F).contains($0.value) }, "\(charset)")
        }
    }

    @Test func trueLatin1TextStaysLatin1() {
        let data = Data("Hyvää päivää, tässä öljyä ja ÅÄÖ.".data(using: .isoLatin1)!)
        #expect(Charset.string(from: data, charset: "ISO-8859-1") == "Hyvää päivää, tässä öljyä ja ÅÄÖ.")
        #expect(Charset.string(from: data, charset: nil) == "Hyvää päivää, tässä öljyä ja ÅÄÖ.")
        #expect(Charset.string(from: data, charset: "utf-8") == "Hyvää päivää, tässä öljyä ja ÅÄÖ.")
    }

    @Test func singleByteLabelOverValidUTF8PrefersUTF8() {
        let text = "isännöitsijä § päätösvaltaisuus 👋"
        for label in ["iso-8859-1", "ISO-8859-15", "windows-1252", "us-ascii", "latin1"] {
            #expect(Charset.string(from: Data(text.utf8), charset: label) == text, "\(label)")
        }
    }

    @Test func singleByteLabelOverShortUTF8PrefersUTF8() {
        // One three-byte sequence is enough evidence; Latin-1 text almost never forms one.
        #expect(Charset.string(from: Data("12 €".utf8), charset: "iso-8859-1") == "12 €")
        #expect(Charset.string(from: Data("Päivä".utf8), charset: "iso-8859-1") == "Päivä")
    }

    /// Regression: one byte pair that happens to be valid UTF-8 must not override the label.
    @Test func singleValidLookingPairKeepsDeclaredWesternCharset() {
        // "Ä–" is C4 96 in windows-1252, which is also the UTF-8 encoding of "Ė".
        let text = "TERVEYDENHOITAJÄ–"
        let data = Data([UInt8]("TERVEYDENHOITAJ".utf8) + [0xC4, 0x96])
        for label in ["windows-1252", "iso-8859-1", "latin1"] {
            #expect(Charset.string(from: data, charset: label) == text, "\(label)")
        }
    }

    /// Regression: in Central European charsets uppercase accented letters are UTF-8 lead
    /// bytes and common letters continuation bytes, so valid-looking pairs are frequent.
    @Test func centralEuropeanCharsetsDecodeAsDeclared() throws {
        let polish = "WSPÓŁPRACA"
        let latin2 = Data([UInt8]("WSP".utf8) + [0xD3, 0xA3] + [UInt8]("PRACA".utf8))
        #expect(Charset.string(from: latin2, charset: "iso-8859-2") == polish)
        let czech = "ÚŘAD žluťoučký"
        let cp1250 = try #require(czech.data(using: .windowsCP1250))
        #expect(Charset.string(from: cp1250, charset: "windows-1250") == czech)
        let latin2Text = try #require("Łódź, ŠKODA, žąśł".data(using: .isoLatin2))
        #expect(Charset.string(from: latin2Text, charset: "ISO-8859-2") == "Łódź, ŠKODA, žąśł")
    }

    @Test func otherSingleByteCharsetsStillDecode() {
        // ISO-8859-15 has € at 0xA4.
        #expect(Charset.string(from: Data([0x31, 0x32, 0x20, 0xA4]), charset: "iso-8859-15") == "12 €")
    }

    @Test func multiByteLegacyCharsetIsHonoured() {
        let data = "日本語".data(using: .shiftJIS)!
        #expect(Charset.string(from: data, charset: "Shift_JIS") == "日本語")
    }

    @Test func unknownCharsetFallsBack() {
        #expect(Charset.string(from: Data("päivä".utf8), charset: "x-unknown-charset") == "päivä")
    }
}
