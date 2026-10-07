import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct ComposeDockTests {
    let drafts = DraftStore(directory: makeTempDir())

    func session(_ body: String = "") -> ComposeSession {
        ComposeSession(draft: Draft(to: "a@b.fi", body: body), store: drafts) { _ in }
    }

    @Test func presentShowsCard() {
        let dock = ComposeDock()
        let s = session()
        dock.present(s)
        #expect(dock.current === s)
        #expect(dock.mode == .card)
    }

    @Test func presentingAnotherSavesTheEditedOne() {
        let dock = ComposeDock()
        let first = session()
        dock.present(first)
        first.draft.body = "kesken"
        dock.present(session())
        #expect(drafts.all().map(\.body) == ["kesken"])
    }

    @Test func minimizeAndExpandKeepTheSession() {
        let dock = ComposeDock()
        let s = session()
        dock.present(s)
        dock.mode = .minimized
        #expect(dock.current === s)
        dock.mode = .peek
        #expect(dock.current === s)
    }

    @Test func dismissClosesSession() {
        let dock = ComposeDock()
        let s = session()
        dock.present(s)
        s.draft.body = "talteen"
        dock.dismiss()
        #expect(dock.current == nil)
        #expect(drafts.all().map(\.body) == ["talteen"])
    }

    @Test func sentSessionIsRemovedWithoutSaving() async throws {
        let dock = ComposeDock()
        let s = session()
        dock.present(s)
        s.draft.body = "lähtee"
        try await dock.send()
        #expect(dock.current == nil)
    }

    @Test func discardDeletesDraft() {
        let dock = ComposeDock()
        let s = session()
        dock.present(s)
        s.draft.body = "pois"
        s.autosave()
        dock.discard()
        #expect(dock.current == nil)
        #expect(drafts.all().isEmpty)
    }
}
