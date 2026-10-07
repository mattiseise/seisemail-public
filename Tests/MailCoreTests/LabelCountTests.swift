import Foundation
import Testing
@testable import MailCore

/// gmail-quota.md §10 P1-4: a view that is one label counts its unread threads with labels.get
/// (1 unit) instead of a search (10 units).
@MainActor
@Suite struct LabelCountTests {
    let fake = LabelFakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    func makeStore(api: (any GmailAPI)? = nil) async -> MailStore {
        let store = MailStore(api: api ?? fake, viewsStore: viewsStore)
        await store.start()
        return store
    }

    func view(_ store: MailStore, _ query: String) throws -> MailView.ID {
        try #require(store.views.first { $0.query == query }).id
    }

    @Test func starredViewUsesLabelsGet() async throws {
        fake.base.addThread("s", labels: [GmailLabel.starred, GmailLabel.unread], in: ["is:starred"])
        fake.base.addThread("r", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = await makeStore()
        #expect(store.unreadCounts[try view(store, "is:starred")] == 1)
        #expect(fake.calls.contains("count label STARRED"))
        #expect(!fake.calls.contains("count is:starred"))
        #expect(fake.calls.contains("count inbox"))                         // the inbox keeps its own count
    }

    @Test func otherViewsStillSearch() async throws {
        let store = await makeStore()
        _ = store
        #expect(fake.calls.contains("count category:promotions OR category:updates"))
        #expect(fake.calls.filter { $0.hasPrefix("count label") } == ["count label STARRED"])
    }

    @Test func clientsWithoutLabelEndpointsSearch() async throws {
        let plain = FakeGmail()
        plain.update { $0.estimates["is:starred"] = 2 }
        let store = await makeStore(api: plain)
        #expect(store.unreadCounts[try view(store, "is:starred")] == 2)
        #expect(plain.calls.contains("count is:starred"))
    }

    @Test func torkkuViewUsesTheMarkerOnceKnown() async throws {
        try viewsStore.save(SeiseViews.defaults)
        fake.addSnoozedThread("t", wake: "20261005T0500Z", extra: [GmailLabel.unread], in: ["label:torkku"])
        let store = await makeStore()
        let torkku = try view(store, "label:torkku")
        #expect(fake.calls.contains("count label:torkku"))                  // marker ID not known yet
        store.countLabelIDs["label:torkku"] = fake.labelID("Torkku")
        let before = fake.calls.count
        await store.refreshCounts()
        let calls = Array(fake.calls.dropFirst(before))
        #expect(calls.contains("count label Label_1"))
        #expect(!calls.contains("count label:torkku"))
        #expect(store.unreadCounts[torkku] == 1)
    }

    @Test func failedLabelsGetKeepsTheBadge() async throws {
        fake.base.addThread("s", labels: [GmailLabel.starred, GmailLabel.unread], in: ["is:starred"])
        let store = await makeStore()
        let starred = try view(store, "is:starred")
        #expect(store.unreadCounts[starred] == 1)
        fake.update { $0.failing = ["labelGet"] }
        await store.refreshCounts()
        #expect(store.unreadCounts[starred] == 1)
    }
}
