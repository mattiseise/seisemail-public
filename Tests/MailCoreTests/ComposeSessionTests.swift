import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct ComposeSessionTests {
    let drafts = DraftStore(directory: makeTempDir())
    let reply = Draft(to: "matti@x.fi", subject: "Re: Hei", body: "\n\n> lainaus", threadID: "t1")

    func session(_ draft: Draft, keepOnClose: Bool = false, send: @escaping @MainActor (Draft) async throws -> Void = { _ in }) -> ComposeSession {
        ComposeSession(draft: draft, store: drafts, keepOnClose: keepOnClose, send: send)
    }

    @Test func autosaveDoesNotChangeTheEditedDraft() {
        let s = session(reply)
        s.draft.body = "Moi" + s.draft.body
        let key = s.autosaveKey
        let before = s.draft
        s.autosave()
        #expect(s.autosaveKey == key)
        #expect(s.draft == before)
        #expect(drafts.all().map(\.body) == ["Moi\n\n> lainaus"])
    }

    @Test func untouchedReplyIsNotKeptOnClose() {
        let s = session(reply)
        s.autosave()
        s.close()
        #expect(drafts.all().isEmpty)
    }

    @Test func editedDraftIsKeptOnClose() {
        let s = session(reply)
        s.draft.body = "Kesken"
        s.close()
        #expect(drafts.all().map(\.body) == ["Kesken"])
    }

    @Test func restoredDraftIsKeptOnCloseEvenIfUntouched() throws {
        try drafts.save(reply)
        let s = session(reply, keepOnClose: true)
        s.close()
        #expect(drafts.all().count == 1)
    }

    @Test func sentDraftIsNotResurrectedByCloseOrAutosave() async throws {
        let drafts = self.drafts
        let s = session(reply) { draft in drafts.delete(id: draft.id) }
        s.draft.body = "Vastaus"
        try await s.send()
        #expect(s.state == .sent)
        s.autosave()
        s.close()
        #expect(drafts.all().isEmpty)
    }

    @Test func draftIsSavedBeforeSendingAndAutosaveIsIgnoredMeanwhile() async throws {
        let drafts = self.drafts
        var savedBeforeSend: [String] = []
        weak var ref: ComposeSession?
        let s = session(reply) { draft in
            savedBeforeSend = drafts.all().map(\.body)
            drafts.delete(id: draft.id)   // what ComposeController does on success
            ref?.autosave()               // a timer firing mid-send must not bring it back
        }
        ref = s
        s.draft.body = "Vastaus"
        try await s.send()
        #expect(savedBeforeSend == ["Vastaus"])
        #expect(drafts.all().isEmpty)
    }

    @Test func failedSendKeepsDraftAndReturnsToEditing() async {
        struct Boom: Error {}
        let s = session(reply) { _ in throw Boom() }
        s.draft.body = "Tärkeä"
        await #expect(throws: Boom.self) { try await s.send() }
        #expect(s.state == .editing)
        #expect(drafts.all().map(\.body) == ["Tärkeä"])
    }

    @Test func discardDeletesAndStopsSaving() {
        let s = session(reply)
        s.draft.body = "x"
        s.autosave()
        s.discard()
        s.autosave()
        s.close()
        #expect(drafts.all().isEmpty)
        #expect(s.state == .discarded)
    }
}
