import Testing
@testable import MailCore

@Suite struct MailAddressTests {
    @Test func parsesListWithQuotedComma() {
        let list = AddressParser.parseList("\"Meikäläinen, Matti\" <matti@x.fi>, b@y.com, Liisa <l@z.fi>")
        #expect(list == [
            MailAddress(name: "Meikäläinen, Matti", email: "matti@x.fi"),
            MailAddress(name: nil, email: "b@y.com"),
            MailAddress(name: "Liisa", email: "l@z.fi"),
        ])
    }

    @Test func decodesEncodedDisplayName() {
        let list = AddressParser.parseList("=?UTF-8?B?w4RpdGk=?= <aiti@x.fi>")
        #expect(list.first?.name == "Äiti")
    }

    @Test func emptyInputGivesEmptyList() {
        #expect(AddressParser.parseList("  ").isEmpty)
    }

    @Test func displayNameFallsBackToEmail() {
        #expect(MailAddress(name: nil, email: "a@b.fi").displayName == "a@b.fi")
        #expect(MailAddress(name: "Matti", email: "a@b.fi").displayName == "Matti")
    }

    @Test func rfc5322QuotesAndEncodesName() {
        #expect(MailAddress(name: "Matti M.", email: "a@b.fi").rfc5322 == "\"Matti M.\" <a@b.fi>")
        #expect(MailAddress(name: nil, email: "a@b.fi").rfc5322 == "a@b.fi")
        #expect(MailAddress(name: "Äiti", email: "a@b.fi").rfc5322.hasPrefix("=?UTF-8?B?"))
    }

    @Test func editableFormKeepsNonASCIINamesReadable() {
        #expect(MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi").editableForm == "\"Mäkinen Åsa\" <asa@x.fi>")
        #expect(MailAddress(name: nil, email: "a@b.fi").editableForm == "a@b.fi")
        #expect(MailAddress(name: "", email: "a@b.fi").editableForm == "a@b.fi")
        #expect(MailAddress(name: "Matti", email: "a@b.fi").editableForm == "\"Matti\" <a@b.fi>")
        #expect(MailAddress(name: "Sanoi \"hei\" \\ moi", email: "a@b.fi").editableForm == "\"Sanoi \\\"hei\\\" \\\\ moi\" <a@b.fi>")
    }

    @Test func editableFormRoundTripsThroughParser() {
        let list = [
            MailAddress(name: "Mäkinen Åsa", email: "asa@x.fi"),
            MailAddress(name: "Virtanen, Äijö", email: "aijo@x.fi"),
            MailAddress(name: "Sörén \"Öst\"", email: "s@x.fi"),
            MailAddress(name: nil, email: "pekka@x.fi"),
        ]
        let text = list.map(\.editableForm).joined(separator: ", ")
        #expect(!text.contains("=?"))
        #expect(AddressParser.parseList(text) == list)
    }

    @Test func validityCheck() {
        #expect(MailAddress(name: nil, email: "a@b.fi").isValid)
        #expect(!MailAddress(name: nil, email: "foo").isValid)
    }
}
