import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §7.1 normalisation of the decider. Assumed shape: `MessageFacts(message:labels:)` with `fromAddress`,
/// `subjectTokens`, `senderTokens`, `autoSubmitted`, `hasHeader(_:)`, `userLabelNames` and `systemLabelIDs`.
@Suite struct MessageFactsTests {
    func facts(from: String = "Anna Ahola <anna@example.fi>", subject: String = "Hei", headers: [String: String] = [:],
               labels: Set<String> = ["INBOX"], snapshot: LabelSnapshot = Snap.snapshot) -> MessageFacts {
        MessageFacts(message: Mail.msg("m1", from: from, subject: subject, labels: labels, headers: headers), labels: snapshot)
    }

    // MARK: From address

    @Test func plainAddressIsLowercased() {
        #expect(facts(from: "Anna Ahola <Anna.Ahola@Example.FI>").fromAddress == "anna.ahola@example.fi")
    }

    @Test func commaInAnUnquotedDisplayName() {
        // parseList splits at the comma; the first entry that passes isValid wins.
        #expect(facts(from: "Virtanen, Matti <matti.virtanen@x.fi>").fromAddress == "matti.virtanen@x.fi")
    }

    @Test func quotedCommaDisplayName() {
        #expect(facts(from: "\"Virtanen, Matti\" <matti.virtanen@x.fi>").fromAddress == "matti.virtanen@x.fi")
    }

    @Test func commentAfterTheAddressIsStripped() {
        #expect(facts(from: "noreply@x.com (No Reply)").fromAddress == "noreply@x.com")
        #expect(facts(from: "anna@example.fi(Anna)").fromAddress == "anna@example.fi")
    }

    @Test func encodedDisplayName() {
        let f = facts(from: "=?UTF-8?B?U8OkaGvDtmxhc2t1IE95?= <info@sahko.fi>")
        #expect(f.fromAddress == "info@sahko.fi")
        #expect(f.senderTokens.contains("sähkölasku"))
        #expect(f.senderTokens.contains("oy"))
        #expect(f.senderTokens.contains("info"))
    }

    @Test(arguments: ["", "Anna Ahola", "anna", "<>", "Anna <anna@>"])
    func noValidAddressIsNil(_ from: String) {
        #expect(facts(from: from).fromAddress == nil)
    }

    @Test func missingFromIsNil() {
        let m = HeaderMessage(id: "m1", labelIDs: ["INBOX"], internalDate: daemonEpoch, headers: ["subject": ["Hei"]])
        #expect(MessageFacts(message: m, labels: Snap.snapshot).fromAddress == nil)
    }

    // MARK: Sender tokens

    @Test func senderTokensAreNameAndLocalPartNotDomain() {
        let f = facts(from: "Laskutus Oy <receipts+acct_1abc@lasku.fi>")
        #expect(Set(f.senderTokens).isSuperset(of: ["laskutus", "oy", "receipts", "acct"]))
        #expect(!f.senderTokens.contains("lasku"))                        // the domain is ignored
        #expect(!f.senderTokens.contains("fi"))
    }

    // MARK: Subject

    @Test func subjectTokensAreLowercasedLetterRuns() {
        #expect(facts(subject: "Kuitti #123: E-lasku, tilaus/2026").subjectTokens == ["kuitti", "e-lasku", "tilaus"])
    }

    @Test func softHyphenInsideAnEncodedSubjectIsRemoved() {
        #expect(facts(subject: "=?UTF-8?B?S3Vpwq10dGkgdGlsYXVrc2VzdGFzaQ==?=").subjectTokens == ["kuitti", "tilauksestasi"])
    }

    @Test func zeroWidthSpaceInsideAnEncodedSubjectIsRemoved() {
        #expect(facts(subject: "=?UTF-8?B?S3VpdOKAi3RpIHRpbGF1a3Nlc3Rhc2k=?=").subjectTokens == ["kuitti", "tilauksestasi"])
    }

    @Test(arguments: ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"])
    func formatCharactersAreRemoved(_ c: String) {
        #expect(facts(subject: "Ku\(c)itti").subjectTokens == ["kuitti"])
    }

    @Test func nfdSubjectBecomesNFC() throws {
        let tokens = facts(subject: "Sa\u{0308}hko\u{0308}lasku").subjectTokens
        let token = try #require(tokens.first)
        #expect(tokens.count == 1)
        #expect(token.unicodeScalars.count == 10)                         // "sähkölasku" precomposed
        #expect(token.unicodeScalars.map(\.value) == "sähkölasku".precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
    }

    @Test func subjectIsTruncatedTo1000Characters() {
        let long = String(repeating: "a", count: 999) + " kuitti"
        #expect(!facts(subject: long).subjectTokens.contains("kuitti"))
        #expect(facts(subject: "kuitti " + long).subjectTokens.first == "kuitti")
    }

    // MARK: Headers

    @Test func headerNamesAreCaseInsensitive() {
        let f = facts(headers: ["List-ID": "<x.lehti.fi>"])
        #expect(f.hasHeader("List-Id"))
        #expect(f.hasHeader("list-id"))
        #expect(!f.hasHeader("List-Unsubscribe"))
    }

    @Test func blankHeaderIsAbsent() {
        #expect(!facts(headers: ["List-Unsubscribe": "  \t "]).hasHeader("List-Unsubscribe"))
    }

    @Test func autoSubmittedNormalisation() {
        #expect(facts(headers: ["Auto-Submitted": "no"]).autoSubmitted == "no")
        #expect(facts(headers: ["Auto-Submitted": "auto-generated"]).autoSubmitted == "auto-generated")
        #expect(facts(headers: ["Auto-Submitted": "Auto-Replied (vacation); owner-email=a@x.fi"]).autoSubmitted == "auto-replied")
        #expect(facts(headers: ["Auto-Submitted": " auto-replied ; x"]).autoSubmitted == "auto-replied")
        #expect(facts().autoSubmitted == nil)
    }

    // MARK: Labels

    @Test func labelsSplitIntoUserNamesAndSystemIDs() {
        let f = facts(labels: ["INBOX", "CATEGORY_PROMOTIONS", Snap.kuititOstot, Snap.omat, "Label_unknown"])
        #expect(Set(f.userLabelNames) == ["kuitit/ostot", "lajittelu/omat"])
        #expect(f.systemLabelIDs == ["INBOX", "CATEGORY_PROMOTIONS"])
    }
}
