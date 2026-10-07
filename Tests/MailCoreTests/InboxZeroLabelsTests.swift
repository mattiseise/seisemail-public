import Foundation
import Testing
@testable import MailCore

/// Gmail answers "in:inbox -label:x" with nothing at all while label x does not exist (Matti,
/// 5.10.2026). Until the sorting labels are confirmed, MailStore drops their exclusions from what
/// it sends: without the label no thread carries it, so the query means the same and the inbox
/// shows, instead of a false "Kaikki käsitelty".
@MainActor
@Suite struct InboxZeroLabelsTests {
    let fake = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))
    let both: Set<String> = [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications]

    func makeStore(missing: Set<String>, pageSize: Int = 50) async throws -> MailStore {
        try viewsStore.save(SeiseViews.defaults)
        let store = MailStore(api: fake, viewsStore: viewsStore, pageSize: pageSize)
        await store.setMissingLabels(missing)                                // before start: no request
        #expect(fake.calls.isEmpty)
        await store.start()
        return store
    }

    func lists() -> [String] { fake.calls.filter { $0.hasPrefix("list ") } }

    @Test func missingLabelsListTheInbox() async throws {
        fake.addThread("a", in: ["in:inbox"])                              // Gmail lists nothing for the real query
        let store = try await makeStore(missing: both)
        #expect(store.activeViewID == SeiseViews.inboxZeroID)
        #expect(store.activeQuery == InboxZero.defaultQuery)                // the view itself is unchanged
        #expect(lists() == ["list in:inbox -"])
        #expect(store.threads.map(\.id) == ["a"])
        #expect(store.emptyState == .none)
    }

    @Test func refreshKeepsTheFallback() async throws {
        fake.addThread("a", in: ["in:inbox"])
        let store = try await makeStore(missing: both)
        fake.addThread("b", in: ["in:inbox"])
        await store.refresh()
        #expect(lists().last == "list in:inbox -")
        #expect(Set(store.threads.map(\.id)) == ["a", "b"])               // not emptied by the real query
    }

    @Test func loadMoreKeepsTheFallback() async throws {
        fake.addThread("a", in: ["in:inbox"])
        fake.addThread("b", in: ["in:inbox"])
        let store = try await makeStore(missing: both, pageSize: 1)
        #expect(store.canLoadMore)
        await store.loadMore()
        #expect(lists() == ["list in:inbox -", "list in:inbox 1"])
        #expect(store.threads.map(\.id) == ["a", "b"])
    }

    @Test func missingLabelsEmptyInboxIsTrulyDone() async throws {
        let store = try await makeStore(missing: both)
        #expect(store.threads.isEmpty)
        #expect(store.emptyState == .inboxZero)                            // the inbox really is empty
    }

    @Test func missingLabelsCountTheInbox() async throws {
        fake.update { $0.inboxUnread = 3 }
        let store = try await makeStore(missing: both)
        #expect(store.unreadCounts[SeiseViews.inboxZeroID] == 3)
        #expect(!fake.calls.contains("count \(InboxZero.defaultQuery)"))
    }

    @Test func confirmedLabelsKeepTheQuery() async throws {
        fake.addThread("a", in: [InboxZero.defaultQuery, "in:inbox"])
        let store = try await makeStore(missing: [])
        #expect(lists() == ["list \(InboxZero.defaultQuery) -"])
        #expect(store.threads.map(\.id) == ["a"])
    }

    @Test func oneMissingLabelDropsOnlyItsTerm() async throws {
        let store = try await makeStore(missing: [SeiseLabels.Sorting.notifications])
        _ = store
        #expect(lists() == ["list in:inbox -label:lajittelu-uutiskirjeet -"])
    }

    @Test func labelsConfirmedLaterReloadWithTheRealQuery() async throws {
        fake.addThread("n", in: ["in:inbox"])                              // a newsletter, say
        fake.addThread("a", in: [InboxZero.defaultQuery, "in:inbox"])
        let store = try await makeStore(missing: both)
        #expect(store.threads.map(\.id) == ["n", "a"])
        let before = fake.calls.count
        await store.setMissingLabels([])
        let calls = Array(fake.calls.dropFirst(before))
        #expect(calls.contains("list \(InboxZero.defaultQuery) -"))
        #expect(calls.contains("count \(InboxZero.defaultQuery)"))
        #expect(store.threads.map(\.id) == ["a"])
    }

    @Test func unchangedMissingLabelsSendNothing() async throws {
        let store = try await makeStore(missing: both)
        let before = fake.calls.count
        await store.setMissingLabels(both)
        #expect(fake.calls.count == before)
    }

    @Test func otherViewsAreUntouched() async throws {
        fake.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = try await makeStore(missing: both)
        await store.selectView(try #require(store.views.first { $0.query == "is:starred" }).id)
        #expect(lists().last == "list is:starred -")
        #expect(store.threads.map(\.id) == ["s"])
    }
}
