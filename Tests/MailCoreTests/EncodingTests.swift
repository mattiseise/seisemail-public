import Foundation
import Testing
@testable import MailCore

@Suite struct Base64URLTests {
    @Test func decodesWithoutPadding() {
        #expect(Base64URL.decode("SGk").map { String(decoding: $0, as: UTF8.self) } == "Hi")
    }

    @Test func roundtripsURLSafeAlphabet() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00, 0x3E])
        let encoded = Base64URL.encode(data)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(Base64URL.decode(encoded) == data)
    }

    @Test func rejectsGarbage() {
        #expect(Base64URL.decode("@@@") == nil)
    }
}

@Suite struct EncodedWordsTests {
    @Test func decodesUTF8Base64() {
        #expect(EncodedWords.decode("=?UTF-8?B?w6TDpGtrw7ZzZXQ=?=") == "ääkköset")
    }

    @Test func decodesLatin1QuotedPrintable() {
        #expect(EncodedWords.decode("=?ISO-8859-1?Q?Hyv=E4=E4_p=E4iv=E4=E4?=") == "Hyvää päivää")
    }

    @Test func joinsAdjacentEncodedWords() {
        let header = "=?UTF-8?Q?Tervehdys_?= =?UTF-8?Q?yst=C3=A4v=C3=A4?= ja muut"
        #expect(EncodedWords.decode(header) == "Tervehdys ystävä ja muut")
    }

    // A multi-byte character split across two encoded words must be decoded from the joined bytes.
    @Test func splitBase64CharacterJoins() {
        let bytes = Array("Päivä".utf8)
        let first = Data(bytes[..<2]).base64EncodedString()   // "P" + first byte of "ä"
        let second = Data(bytes[2...]).base64EncodedString()
        #expect(EncodedWords.decode("=?UTF-8?B?\(first)?= =?UTF-8?B?\(second)?=") == "Päivä")
    }

    @Test func splitQuotedPrintableCharacterJoins() {
        #expect(EncodedWords.decode("=?UTF-8?Q?P=C3?= =?utf-8?Q?=A4iv=C3=A4?=") == "Päivä")
    }

    @Test func foldedSplitWordsJoin() {
        #expect(EncodedWords.decode("=?UTF-8?Q?P=C3?=\r\n =?UTF-8?Q?=A4iv=C3=A4?=") == "Päivä")
        #expect(EncodedWords.decode("=?UTF-8?Q?P=C3?=\r\n\t=?UTF-8?Q?=A4iv=C3=A4?= ja muut") == "Päivä ja muut")
    }

    @Test func splitSenderNameDecodes() {
        let bytes = Array("Mäkinen".utf8)
        let first = Data(bytes[..<2]).base64EncodedString()
        let second = Data(bytes[2...]).base64EncodedString()
        let list = AddressParser.parseList("=?UTF-8?B?\(first)?= =?UTF-8?B?\(second)?= <m@x.fi>")
        #expect(list == [MailAddress(name: "Mäkinen", email: "m@x.fi")])
    }

    @Test func differentCharsetsSideBySide() {
        #expect(EncodedWords.decode("=?ISO-8859-1?Q?P=E4iv=E4_?= =?UTF-8?Q?y=C3=B6?=") == "Päivä yö")
    }

    @Test func charsetChangeFlushesPartialBytes() {
        // A dangling UTF-8 lead byte must not swallow the next word in another charset.
        let decoded = EncodedWords.decode("=?UTF-8?Q?a=C3?= =?ISO-8859-1?Q?=E4?=")
        #expect(decoded.hasPrefix("a"))
        #expect(decoded.hasSuffix("ä"))
        #expect(decoded.count == 3)
    }

    @Test func textBetweenWordsFlushes() {
        #expect(EncodedWords.decode("=?UTF-8?Q?P=C3=A4iv=C3=A4?= ja =?UTF-8?Q?y=C3=B6?=") == "Päivä ja yö")
    }

    @Test func unpaddedBase64Decodes() {
        #expect(EncodedWords.decode("=?UTF-8?B?w6TDpA?=") == "ää")
    }

    @Test func whitespaceInsideBase64Decodes() {
        #expect(EncodedWords.decode("=?UTF-8?B?w6TD pA==?=") == "ää")
    }

    @Test func languageSuffixInCharsetIsIgnored() {
        #expect(EncodedWords.decode("=?UTF-8*fi?Q?P=C3=A4iv=C3=A4?=") == "Päivä")
    }

    @Test func brokenWordStaysRawAndNextWordDecodes() {
        #expect(EncodedWords.decode("=?UTF-8?B?***?= =?UTF-8?Q?y=C3=B6?=") == "=?UTF-8?B?***?= yö")
    }

    @Test func brokenWordBetweenDecodedWordsKeepsItsSpaces() {
        #expect(EncodedWords.decode("=?UTF-8?B?w6Q?= =?UTF-8?B?***?= =?UTF-8?B?w6Q?=") == "ä =?UTF-8?B?***?= ä")
    }

    /// Regression: a lone valid-looking byte pair in a short Latin-1 word stays Latin-1.
    @Test func latin1WordWithOneUTF8LookingPairDecodesAsDeclared() {
        #expect(EncodedWords.decode("=?iso-8859-1?Q?=C4=96_x?=") == "Ä– x")
        #expect(EncodedWords.decode("=?iso-8859-2?Q?WSP=D3=A3PRACA?=") == "WSPÓŁPRACA")
    }

    @Test func plainTextPassesThrough() {
        #expect(EncodedWords.decode("Hello world") == "Hello world")
    }

    @Test func encodeLeavesASCIIUnchanged() {
        #expect(EncodedWords.encode("Hei") == "Hei")
    }

    @Test func encodeRoundtripsNonASCII() {
        let encoded = EncodedWords.encode("Hyvä päivä")
        #expect(encoded.hasPrefix("=?UTF-8?B?"))
        #expect(EncodedWords.decode(encoded) == "Hyvä päivä")
    }
}

@Suite struct HTMLTextTests {
    @Test func stripsTagsAndDecodesEntities() {
        let text = HTMLText.plainText(fromHTML: "<p>Hei&nbsp;<b>Maija</b></p><br>Moi &amp; kiitos &#228;")
        #expect(text.contains("Hei Maija"))
        #expect(text.contains("Moi & kiitos ä"))
        #expect(!text.contains("<"))
    }

    @Test func dropsStyleAndScript() {
        let text = HTMLText.plainText(fromHTML: "<style>p{color:red}</style><script>alert(1)</script><div>Sisältö</div>")
        #expect(text == "Sisältö")
    }

    @Test func blockElementsBecomeLineBreaks() {
        let text = HTMLText.plainText(fromHTML: "<div>Rivi 1</div><div>Rivi 2</div>")
        #expect(text == "Rivi 1\nRivi 2")
    }

    @Test func decodesLatin1NamedEntities() {
        #expect(HTMLText.decodeEntities("&oslash;&aelig;&uuml;&eacute;&szlig;&Oslash;&AElig;&Uuml;&Eacute;&ccedil;&ntilde;&yuml;")
                == "øæüéßØÆÜÉçñÿ")
        #expect(HTMLText.decodeEntities("&sect; 3 &deg; &frac12; &laquo;x&raquo; &times; &divide; &iexcl;") == "§ 3 ° ½ «x» × ÷ ¡")
    }

    @Test func decodesTypographicNamedEntities() {
        #expect(HTMLText.decodeEntities("&OElig;&bdquo;x&ldquo; &permil; &bull; &trade; &rarr; &le;&ne;") == "Œ„x“ ‰ • ™ → ≤≠")
    }

    @Test func existingEntitiesUnchangedAndUnknownStayRaw() {
        #expect(HTMLText.decodeEntities("&auml;&nbsp;&amp;&euro;") == "ä &€")
        #expect(HTMLText.decodeEntities("&foo; &OSLASH;") == "&foo; &OSLASH;")
    }

    @Test func plainTextDecodesNordicEntities() {
        #expect(HTMLText.plainText(fromHTML: "<p>Hilsen fra Bj&oslash;rn &amp; S&oslash;ren, K&ouml;ln &szlig;</p>") == "Hilsen fra Bjørn & Søren, Köln ß")
    }

    @Test func escapesSpecialCharacters() {
        #expect(HTMLText.escape("<a href=\"x\">&'") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
    }
}
