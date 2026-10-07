import Foundation
import Testing
@testable import MailCore

@MainActor
final class ActivityLog {
    var deltas: [ActivityCounts] = []
}

@MainActor
@Suite struct MailStoreSeiseTests {
    let fake = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))
    let log = ActivityLog()

    /// Upstream default views (Inbox first) unless `seise` pre-saves the fork's defaults (Käsiteltävät first).
    func makeStore(api: (any GmailAPI)? = nil, seise: Bool = false, start: Bool = true) async throws -> MailStore {
        if seise { try viewsStore.save(SeiseViews.defaults) }
        let store = MailStore(api: api ?? fake, viewsStore: viewsStore)
        store.onActivity = { [log] in log.deltas.append($0) }
        if start { await store.start() }
        return store
    }

    func view(_ store: MailStore, query: String) throws -> MailView.ID {
        try #require(store.views.first { $0.query == query }).id
    }

    func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Load state

    @Test func loadStateLifecycle() async throws {
        fake.addThread("a")
        let store = try await makeStore(start: false)
        #expect(store.listLoadState == .notLoaded)
        #expect(store.emptyState == .loading)
        await store.start()
        #expect(store.listLoadState == .loaded)
        #expect(store.emptyState == .none)
    }

    @Test func failedLoad() async throws {
        fake.update { $0.failing = ["list"] }
        let store = try await makeStore()
        #expect(store.listLoadState == .failed)
        #expect(store.emptyState == .failed)
    }

    @Test func offlineLoad() async throws {
        fake.update { $0.offline = true }
        let store = try await makeStore()
        #expect(store.listLoadState == .failed)
        #expect(store.isOffline)
        #expect(store.emptyState == .offline)
    }

    @Test func refreshRecovers() async throws {
        fake.addThread("a")
        fake.update { $0.failing = ["list"] }
        let store = try await makeStore()
        #expect(store.listLoadState == .failed)
        fake.update { $0.failing = [] }
        await store.refresh()
        #expect(store.listLoadState == .loaded)
        #expect(store.threads.map(\.id) == ["a"])
        #expect(store.emptyState == .none)
    }

    @Test func backgroundFailureKeepsLoaded() async throws {
        fake.addThread("a")
        let store = try await makeStore()
        #expect(store.listLoadState == .loaded)
        fake.update { $0.failing = ["list"] }
        await store.refresh()
        #expect(store.listLoadState == .loaded)
        #expect(store.threads.map(\.id) == ["a"])
    }

    @Test func viewSwitchResets() async throws {
        fake.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let api = LabelFakeGmail(base: fake)
        let store = try await makeStore(api: api)
        #expect(store.listLoadState == .loaded)
        let gate = Gate()
        api.updateLabels { $0.summaryGate = gate }
        let starred = try view(store, query: "is:starred")
        let switching = Task { await store.selectView(starred) }
        #expect(await gate.waitForArrivals(1))                                // the switch is in flight
        #expect(store.listLoadState == .notLoaded)
        #expect(store.emptyState == .loading)
        await gate.open()
        await switching.value
        #expect(store.listLoadState == .loaded)
        #expect(store.threads.map(\.id) == ["s"])
    }

    /// A load that a newer one replaced must not mark the newer list failed when it fails late.
    @Test func staleFailedLoadDoesNotOverrideNewer() async throws {
        fake.update { $0.lists["is:starred", default: []].append("ghost") }   // listed, but its summary is a 404
        let api = LabelFakeGmail(base: fake)
        let store = try await makeStore(api: api)
        let gate = Gate()
        api.updateLabels { $0.summaryGate = gate }
        let starred = try view(store, query: "is:starred")
        let stale = Task { await store.selectView(starred) }
        #expect(await gate.waitForArrivals(1))                                // the starred load holds its failure
        await store.selectView(try view(store, query: "in:inbox"))           // empty inbox: no summary call
        #expect(store.listLoadState == .loaded)
        await gate.open()
        await stale.value
        #expect(store.listLoadState == .loaded)
        #expect(store.emptyState == .empty)
    }

    /// A refresh that supersedes a view switch and then fails: the failed state, not an endless spinner.
    @Test(arguments: [true, false])
    func supersededLoadThenFailedRefreshIsNotStuck(offline: Bool) async throws {
        fake.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let api = LabelFakeGmail(base: fake)
        let store = try await makeStore(api: api)
        let gate = Gate()
        api.updateLabels { $0.summaryGate = gate }
        let starred = try view(store, query: "is:starred")
        let switching = Task { await store.selectView(starred) }
        #expect(await gate.waitForArrivals(1))
        fake.update { if offline { $0.offline = true } else { $0.failing = ["list"] } }
        await store.refresh()                                                 // bumps the generation, then fails
        await gate.open()
        await switching.value                                                 // its result is dropped
        #expect(store.threads.isEmpty)
        #expect(store.listLoadState == .failed)
        #expect(store.emptyState == (offline ? .offline : .failed))
    }

    @Test func failedViewSwitchIsFailedNotEmpty() async throws {
        let store = try await makeStore()
        fake.update { $0.failing = ["list"] }
        let starred = try view(store, query: "is:starred")
        await store.selectView(starred)
        #expect(store.listLoadState == .failed)
        #expect(store.emptyState == .failed)
    }

    // MARK: - Empty-state kinds

    @Test func emptyStateKinds() async throws {
        let store = try await makeStore(seise: true)
        #expect(store.activeViewID == SeiseViews.inboxZeroID)               // Käsiteltävät opens first
        #expect(fake.calls.contains("list \(InboxZero.defaultQuery) -"))
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .inboxZero)

        await store.selectView(SeiseViews.snoozedID)
        #expect(store.listViewKind == .snoozed)
        #expect(store.emptyState == .snoozedEmpty)

        let inbox = try view(store, query: "in:inbox")
        await store.selectView(inbox)
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)

        await store.selectView(SeiseViews.inboxZeroID)
        await store.addFilter(MailFilter(.unread))                          // a chip changes the view
        #expect(store.filtersChanged)
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)

        await store.resetFilters()
        #expect(store.emptyState == .inboxZero)
        await store.search("foo")
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)
    }

    /// Owner decision 3 (2026-10-04): a view with an equivalent query counts like the fork view.
    @Test func equivalentQueryViewsGetForkEmptyStates() async throws {
        try viewsStore.save([
            MailView(name: "Inbox", query: "in:inbox"),
            MailView(name: "Oma nolla", query: "IN:inbox  -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset"),
            MailView(name: "Torkut", query: "Label:Torkku"),
            MailView(name: "Melkein", query: "in:inbox -label:lajittelu-uutiskirjeet"),
            MailView(name: "Lukemattomat torkut", query: "label:torkku is:unread"),
        ])
        let store = try await makeStore()
        #expect(store.listViewKind == .other)                                // Inbox
        #expect(store.emptyState == .empty)

        await store.selectView(try view(store, query: "IN:inbox  -label:lajittelu-uutiskirjeet -label:lajittelu-ilmoitukset"))
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .inboxZero)

        await store.selectView(try view(store, query: "Label:Torkku"))
        #expect(store.listViewKind == .snoozed)
        #expect(store.emptyState == .snoozedEmpty)

        await store.selectView(try view(store, query: "in:inbox -label:lajittelu-uutiskirjeet"))
        #expect(store.listViewKind == .other)                                // not equivalent
        #expect(store.emptyState == .empty)

        await store.selectView(try view(store, query: "label:torkku is:unread"))
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)
    }

    @Test func duplicatedForkViewsGetForkEmptyStates() async throws {
        let store = try await makeStore(seise: true)
        await store.duplicateView(SeiseViews.inboxZeroID)
        await store.duplicateView(SeiseViews.snoozedID)
        let zeroCopy = try #require(store.views.first { $0.name == "Käsiteltävät (kopio)" })
        let snoozedCopy = try #require(store.views.first { $0.name == "Torkku (kopio)" })
        #expect(zeroCopy.id != SeiseViews.inboxZeroID)
        #expect(snoozedCopy.id != SeiseViews.snoozedID)

        await store.selectView(zeroCopy.id)
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .inboxZero)
        await store.addFilter(MailFilter(.unread))                          // changed chips still never count
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)

        await store.selectView(snoozedCopy.id)
        #expect(store.listViewKind == .snoozed)
        #expect(store.emptyState == .snoozedEmpty)
        await store.search("label:torkku")                                   // an ad-hoc search never counts
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)
    }

    @Test func editedQueryStopsCounting() async throws {
        let store = try await makeStore(seise: true)
        await store.duplicateView(SeiseViews.inboxZeroID)
        let copy = try #require(store.views.first { $0.name == "Käsiteltävät (kopio)" }).id
        await store.editView(copy) { $0.query = "in:inbox" }
        await store.selectView(copy)
        #expect(store.listViewKind == .other)
        #expect(store.emptyState == .empty)
        await store.editView(SeiseViews.inboxZeroID) { $0.query = "in:inbox" }   // the fixed ID still counts (Q9)
        await store.selectView(SeiseViews.inboxZeroID)
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .inboxZero)
    }

    @Test func listedThreadsAreNotEmpty() async throws {
        fake.addThread("a", in: [InboxZero.defaultQuery, "in:inbox"])
        let store = try await makeStore(seise: true)
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .none)
    }

    @Test func offlineInboxZeroIsNotZero() async throws {
        fake.update { $0.offline = true }
        let store = try await makeStore(seise: true)
        #expect(store.listViewKind == .inboxZero)
        #expect(store.emptyState == .offline)
    }

    // MARK: - Notification taps

    @Test func openPreferringStays() async throws {
        fake.addThread("a", in: [InboxZero.defaultQuery, "in:inbox"])
        let store = try await makeStore(seise: true)
        let lists = fake.calls.filter { $0.hasPrefix("list ") }.count
        await store.openPreferringCurrentView(threadID: "a")
        #expect(store.activeViewID == SeiseViews.inboxZeroID)
        #expect(store.selectedThreadID == "a")
        #expect(store.openThread?.id == "a")
        #expect(fake.calls.filter { $0.hasPrefix("list ") }.count == lists)  // no reload
    }

    @Test func openPreferringFallsBack() async throws {
        fake.addThread("a", in: [InboxZero.defaultQuery, "in:inbox"])
        fake.addThread("n", in: ["in:inbox"])
        let store = try await makeStore(seise: true)
        let inbox = try view(store, query: "in:inbox")
        await store.openPreferringCurrentView(threadID: "n")
        #expect(store.activeViewID == inbox)
        #expect(store.selectedThreadID == "n")
        #expect(store.openThread?.id == "n")
    }

    // MARK: - Activity (daily counter hook)

    @Test func archiveCountsOne() async throws {
        fake.addThread("a")
        fake.addThread("b")
        let store = try await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.threads.map(\.id) == ["b"])
        #expect(log.deltas == [ActivityCounts(archived: 1)])
    }

    @Test func archiveNonInboxCountsNothing() async throws {
        fake.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = try await makeStore()
        let starred = try view(store, query: "is:starred")
        await store.selectView(starred)
        await store.select(threadID: "s")
        await store.archive()
        #expect(store.canUndo)                                              // pushed, but nothing left INBOX
        #expect(log.deltas == [])
        await store.undo()
        #expect(log.deltas == [])
    }

    @Test func archiveFromInboxInOtherViewCounts() async throws {
        fake.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        let store = try await makeStore()
        let starred = try view(store, query: "is:starred")
        await store.selectView(starred)
        await store.select(threadID: "s")
        await store.archive()
        #expect(store.threads.map(\.id) == ["s"])                           // the row stays in Tähdellä
        #expect(log.deltas == [ActivityCounts(archived: 1)])
    }

    @Test func bulkArchivePartial() async throws {
        for id in ["a", "b", "c"] { fake.addThread(id) }
        fake.update { $0.failingThreads = ["b"] }
        let store = try await makeStore()
        store.checkAll()
        await store.archive()
        #expect(store.threads.map(\.id) == ["b"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
        #expect(log.deltas == [ActivityCounts(archived: 2)])
        await store.undo()
        #expect(log.deltas == [ActivityCounts(archived: 2), ActivityCounts(archived: -2)])
    }

    // Bulk archive runs as a background job (main's bulk queue): it counts what Gmail confirmed,
    // once the job is done, and a ⌘Z takes back exactly that.

    @Test func bulkArchiveCountsWhenGmailIsDone() async throws {
        for id in ["a", "b", "c"] { fake.addThread(id) }
        let gate = fake.holdWrites()
        let store = try await makeStore()
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await eventually { gate.parkedCount == 3 })
        #expect(store.threads.isEmpty)
        #expect(log.deltas == [])                                           // nothing confirmed yet
        gate.open()
        await running.value
        #expect(log.deltas == [ActivityCounts(archived: 3)])
    }

    @Test func bulkArchiveUndoneWhileRunningCountsNothing() async throws {
        for id in ["a", "b", "c"] { fake.addThread(id) }
        let gate = fake.holdWrites()
        let store = try await makeStore()
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await eventually { gate.parkedCount == 3 })
        let undoing = Task { await store.undo() }
        #expect(await eventually { @MainActor in store.bulkStatuses.first?.isUndoing == true })
        gate.open()
        await undoing.value
        await running.value
        #expect(store.threads.map(\.id) == ["a", "b", "c"])
        #expect(log.deltas == [])
    }

    @Test func bulkArchiveInOtherViewCountsOnlyInboxThreads() async throws {
        fake.addThread("s1", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        fake.addThread("s2", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = try await makeStore()
        await store.selectView(try view(store, query: "is:starred"))
        store.checkAll()
        await store.archive()
        #expect(log.deltas == [ActivityCounts(archived: 1)])
        await store.undo()
        #expect(log.deltas == [ActivityCounts(archived: 1), ActivityCounts(archived: -1)])
    }

    @Test func failedBulkJobDoesNotUncountALaterArchive() async throws {
        for id in ["a", "b", "c", "x"] { fake.addThread(id) }
        let api = GatedFailingGmail(base: fake, failing: ["a", "b", "c"])
        let store = try await makeStore(api: api)
        for id in ["a", "b", "c"] { store.toggleChecked(id) }
        let running = Task { await store.archive() }
        #expect(await eventually { api.gate.parkedCount == 3 })
        await store.select(threadID: "x")
        await store.archive()                                               // its undo entry sits above the job's
        #expect(log.deltas == [ActivityCounts(archived: 1)])
        api.gate.open()
        await running.value                                                 // all failed: the job leaves the stack
        #expect(Set(store.threads.map(\.id)) == ["a", "b", "c"])
        #expect(log.deltas == [ActivityCounts(archived: 1)])
        await store.undo()                                                  // takes back the archive of x
        #expect(log.deltas == [ActivityCounts(archived: 1), ActivityCounts(archived: -1)])
        #expect(store.canUndo == false)
    }

    @Test func failedArchiveCountsNothing() async throws {
        fake.addThread("a")
        let store = try await makeStore()
        await store.select(threadID: "a")
        fake.update { $0.failing = ["modify"] }
        await store.archive()
        #expect(store.toast == "Arkistointi epäonnistui")
        #expect(log.deltas == [])
    }

    @Test func otherActionsCountNothing() async throws {
        for id in ["a", "b"] { fake.addThread(id) }
        let store = try await makeStore()
        await store.select(threadID: "a")
        await store.toggleStar()
        await store.markUnread()
        await store.markRead()
        await store.trash()
        #expect(store.threads.map(\.id) == ["b"])
        #expect(log.deltas == [])
        for _ in 0..<4 { await store.undo() }
        #expect(store.canUndo == false)
        #expect(log.deltas == [])
    }

    @Test func undoArchiveCountsBack() async throws {
        fake.addThread("a")
        let store = try await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        await store.undo()
        #expect(store.threads.map(\.id) == ["a"])
        #expect(log.deltas == [ActivityCounts(archived: 1), ActivityCounts(archived: -1)])
    }

    @Test func failedUndoStillCountsBack() async throws {
        // Undo pops before the server call (risk §10.7).
        fake.addThread("a")
        let store = try await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        fake.update { $0.failing = ["modify"] }
        await store.undo()
        #expect(store.toast == "Kumoaminen epäonnistui")
        #expect(log.deltas == [ActivityCounts(archived: 1), ActivityCounts(archived: -1)])
    }

    @Test func noHookHarmless() async throws {
        fake.addThread("a")
        let store = MailStore(api: fake, viewsStore: viewsStore)
        await store.start()
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.threads.isEmpty)
        await store.undo()
        #expect(store.threads.map(\.id) == ["a"])
        #expect(store.canUndo == false)
    }

    // MARK: - Activity: snooze

    var until: Date { D(1_791_176_400) }                                     // ma 5.10.2026 8.00

    func snoozing() -> (LabelFakeGmail, SnoozeService) {
        let labels = LabelFakeGmail(base: fake)
        return (labels, SnoozeService(api: labels, directory: LabelDirectory(api: labels), now: { D(1_791_018_000) }))
    }

    @Test func snoozeCounts() async throws {
        let (api, service) = snoozing()
        for id in ["a", "b"] { fake.addThread(id) }
        let store = try await makeStore(api: api)
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(store.threads.map(\.id) == ["b"])
        #expect(log.deltas == [ActivityCounts(snoozed: 1)])
    }

    @Test func bulkSnoozeCounts() async throws {
        let (api, service) = snoozing()
        for id in ["a", "b", "c"] { fake.addThread(id) }
        let store = try await makeStore(api: api)
        store.checkAll()
        await store.snooze(until: until, using: service)
        #expect(store.threads.isEmpty)
        #expect(log.deltas == [ActivityCounts(snoozed: 3)])
        await store.undo()
        #expect(log.deltas == [ActivityCounts(snoozed: 3), ActivityCounts(snoozed: -3)])
    }

    @Test func resnoozeInTorkkuCountsNothing() async throws {
        let (api, service) = snoozing()
        api.addSnoozedThread("a", wake: "20261005T0500Z", in: ["label:torkku"])    // Label_1, Label_2; no INBOX
        let store = try await makeStore(api: api)
        await store.search("label:torkku")
        await store.select(threadID: "a")
        await store.snooze(until: D(1_791_262_800), using: service)
        #expect(store.canUndo)
        #expect(log.deltas == [])
        await store.undo()
        #expect(log.deltas == [])
    }

    @Test func undoSnoozeCountsBack() async throws {
        let (api, service) = snoozing()
        fake.addThread("a")
        let store = try await makeStore(api: api)
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.undo()
        #expect(store.threads.map(\.id) == ["a"])
        #expect(log.deltas == [ActivityCounts(snoozed: 1), ActivityCounts(snoozed: -1)])
    }

    @Test func failedSnoozeCountsNothing() async throws {
        let (api, service) = snoozing()
        fake.addThread("a")
        fake.update { $0.failing = ["modify"] }
        let store = try await makeStore(api: api)
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(store.toast == "Torkutus epäonnistui")
        #expect(log.deltas == [])
    }

    @Test func mixedActionsKeepSeparateCounts() async throws {
        let (api, service) = snoozing()
        for id in ["a", "b", "c"] { fake.addThread(id) }
        let store = try await makeStore(api: api)
        await store.select(threadID: "a")
        await store.archive()                                                // a out; b selected
        await store.snooze(until: until, using: service)                     // b out
        #expect(store.threads.map(\.id) == ["c"])
        #expect(log.deltas == [ActivityCounts(archived: 1), ActivityCounts(snoozed: 1)])
        await store.undo()                                                   // the snooze
        #expect(log.deltas.last == ActivityCounts(snoozed: -1))
        await store.undo()                                                   // the archive
        #expect(log.deltas.last == ActivityCounts(archived: -1))
        #expect(log.deltas.count == 4)
    }
}

/// Writes to the `failing` threads wait at `gate`, then fail; everything else goes to `base`.
final class GatedFailingGmail: GmailAPI {
    let base: FakeGmail
    let failing: Set<String>
    let gate = CallGate()

    init(base: FakeGmail, failing: Set<String>) {
        self.base = base
        self.failing = failing
    }

    func profileEmail() async throws -> String { try await base.profileEmail() }
    func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        try await base.listThreads(query: query, pageToken: pageToken, maxResults: maxResults)
    }
    func threadSummary(id: String, me: String?) async throws -> ThreadSummary { try await base.threadSummary(id: id, me: me) }
    func thread(id: String) async throws -> MailThread { try await base.thread(id: id) }
    func modify(threadID: String, add: [String], remove: [String]) async throws {
        if failing.contains(threadID) {
            try await gate.pass()
            throw GmailError.http(500, "fail")
        }
        try await base.modify(threadID: threadID, add: add, remove: remove)
    }
    func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {
        try await base.batchModify(messageIDs: messageIDs, add: add, remove: remove)
    }
    func trash(threadID: String) async throws { try await base.trash(threadID: threadID) }
    func untrash(threadID: String) async throws { try await base.untrash(threadID: threadID) }
    func send(raw: Data, threadID: String?) async throws { try await base.send(raw: raw, threadID: threadID) }
    func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await base.attachmentData(messageID: messageID, attachmentID: attachmentID)
    }
    func inboxUnreadCount() async throws -> Int { try await base.inboxUnreadCount() }
    func unreadEstimate(query: String) async throws -> Int { try await base.unreadEstimate(query: query) }
    func sendAsSignatures() async throws -> [SendAsSignature] { try await base.sendAsSignatures() }
}
