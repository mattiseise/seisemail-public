import Foundation
import Testing
@testable import MailCore

@Suite struct ViewsConfigStoreTests {
    @Test func missingFileWritesDefaults() throws {
        let url = makeTempDir().appendingPathComponent("sub/views.json")
        let store = ViewsConfigStore(fileURL: url)
        let views = store.load()
        #expect(views.map(\.name) == ["Inbox", "Tärkeät", "Uutiskirjeet", "Tähdellä"])
        #expect(views.map(\.query) == [
            "in:inbox",
            "in:inbox is:important -category:promotions -category:social",
            "category:promotions OR category:updates",
            "is:starred",
        ])
        #expect(views.map(\.icon) == ["tray", "exclamationmark.circle", "newspaper", "star"])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.load() == views) // stable ids once written
    }

    @Test func roundtrip() throws {
        let store = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))
        let views = [MailView(name: "Työ", query: "label:work")]
        try store.save(views)
        #expect(store.load() == views)
    }

    @Test func corruptFileFallsBackAndKeepsBackup() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("views.json")
        try Data("{ not json".utf8).write(to: url)
        let views = ViewsConfigStore(fileURL: url).load()
        #expect(views.count == 4)
        let backup = dir.appendingPathComponent("views.json.broken")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test func untouchedOldDefaultsAreMigrated() throws {
        let url = makeTempDir().appendingPathComponent("views.json")
        let old = [
            ("Inbox", "in:inbox"),
            ("Tärkeät", "in:inbox is:important -category:promotions -category:social"),
            ("Uutiskirjeet", "category:promotions OR category:updates"),
            ("Tähdellä", "is:starred"),
            ("Lähetetyt", "in:sent"),
            ("Kaikki", "in:anywhere -in:trash -in:spam"),
        ].map { ["id": UUID().uuidString, "name": $0.0, "query": $0.1] }
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let store = ViewsConfigStore(fileURL: url)
        let views = store.load()
        #expect(views.map(\.name) == ["Inbox", "Tärkeät", "Uutiskirjeet", "Tähdellä"])
        #expect(views.map(\.id.uuidString) == old.prefix(4).map { $0["id"]! })
        #expect(views.first?.icon == "tray")
        #expect(store.load() == views) // persisted
    }

    @Test func customisedViewsAreNotMigrated() throws {
        let url = makeTempDir().appendingPathComponent("views.json")
        let custom = [["id": UUID().uuidString, "name": "Lähetetyt", "query": "in:sent"]]
        try JSONSerialization.data(withJSONObject: custom).write(to: url)
        let views = ViewsConfigStore(fileURL: url).load()
        #expect(views.map(\.name) == ["Lähetetyt"])
        #expect(views.first?.icon == nil)
    }

    @Test func foldersAreFixed() {
        #expect(MailView.folders.map(\.name) == ["Kaikki", "Lähetetyt", "Luonnokset", "Roskaposti", "Roskakori"])
        #expect(MailView.folders.map(\.query) == ["in:anywhere -in:trash -in:spam", "in:sent", "in:drafts", "in:spam", "in:trash"])
        #expect(MailView.folders.map(\.id) == MailView.folders.map(\.id)) // stable across calls
    }
}

@Suite struct DraftStoreTests {
    @Test func saveListDelete() throws {
        let store = DraftStore(directory: makeTempDir())
        let older = Draft(subject: "vanha", updatedAt: Date(timeIntervalSince1970: 100))
        let newer = Draft(subject: "uusi", updatedAt: Date(timeIntervalSince1970: 200))
        try store.save(older)
        try store.save(newer)
        #expect(store.all().map(\.subject) == ["uusi", "vanha"])
        store.delete(id: newer.id)
        #expect(store.all().map(\.subject) == ["vanha"])
    }

    @Test func saveOverwritesSameID() throws {
        let store = DraftStore(directory: makeTempDir())
        var d = Draft(subject: "a")
        try store.save(d)
        d.subject = "b"
        try store.save(d)
        #expect(store.all().map(\.subject) == ["b"])
    }

    @Test func corruptDraftIsSkipped() throws {
        let dir = makeTempDir()
        let store = DraftStore(directory: dir)
        try store.save(Draft(subject: "ok"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(store.all().map(\.subject) == ["ok"])
    }

    @Test func missingDirectoryGivesEmptyList() {
        let store = DraftStore(directory: makeTempDir().appendingPathComponent("nope"))
        #expect(store.all().isEmpty)
    }

    @Test func draftWithAttachmentsRoundtrips() throws {
        let store = DraftStore(directory: makeTempDir())
        let d = Draft(to: "a@b.fi", attachments: [
            .file(URL(fileURLWithPath: "/tmp/x.pdf")),
            .gmail(Attachment(messageID: "m", partID: "1", attachmentID: "a", filename: "y.pdf", mimeType: "application/pdf", size: 3)),
        ])
        try store.save(d)
        #expect(store.all().first?.attachments == d.attachments)
    }
}
