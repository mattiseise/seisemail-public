import Foundation
import Testing
@testable import MailCore

@Suite struct AccountListTests {
    @Test func addActivatesAndIgnoresDuplicates() {
        var list = AccountList()
        let first = list.add("maija@example.fi")
        let second = list.add("maija.meikalainen@gmail.com")
        #expect(first && second)
        #expect(list.active == "maija.meikalainen@gmail.com")
        let duplicate = list.add("MAIJA@example.fi")
        #expect(!duplicate)
        #expect(list.emails == ["maija@example.fi", "maija.meikalainen@gmail.com"])
        #expect(list.active == "maija@example.fi") // re-adding an existing account switches to it
    }

    @Test func removeMovesActiveToRemaining() {
        var list = AccountList(emails: ["a@x.fi", "b@x.fi"], active: "a@x.fi")
        list.remove("A@x.fi")
        #expect(list.emails == ["b@x.fi"])
        #expect(list.active == "b@x.fi")
        list.remove("b@x.fi")
        #expect(list.emails.isEmpty)
        #expect(list.active == nil)
    }

    @Test func activateOnlyKnownAccounts() {
        var list = AccountList(emails: ["a@x.fi", "b@x.fi"], active: "a@x.fi")
        list.activate("B@x.fi")
        #expect(list.active == "b@x.fi")
        list.activate("zzz@x.fi")
        #expect(list.active == "b@x.fi")
    }

    @Test func storeRoundtrip() throws {
        let store = AccountListStore(fileURL: makeTempDir().appendingPathComponent("accounts.json"))
        #expect(store.load() == nil)
        let list = AccountList(emails: ["a@x.fi"], active: "a@x.fi")
        try store.save(list)
        #expect(store.load() == list)
    }
}

@Suite struct AccountPathTests {
    @Test func keychainAccountPerEmail() {
        #expect(KeychainTokenStore.accountName(for: "Maija@Example.fi") == "google-oauth:maija@example.fi")
    }

    @Test func viewsFilePerEmail() {
        #expect(ViewsConfigStore.url(for: "Maija@Example.fi").lastPathComponent == "views-maija@example.fi.json")
    }

    @Test func oldDraftsDecodeWithoutAccount() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","to":"a@b.fi","cc":"","bcc":"","subject":"","body":"","attachments":[],"updatedAt":0}"#
        let draft = try JSONDecoder().decode(Draft.self, from: Data(json.utf8))
        #expect(draft.account == nil)
        var d = draft
        d.account = "a@x.fi"
        #expect(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(d)).account == "a@x.fi")
    }
}
