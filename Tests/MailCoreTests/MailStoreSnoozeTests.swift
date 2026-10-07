import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct MailStoreSnoozeTests {
    let fake: LabelFakeGmail
    let service: SnoozeService
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))
    let until = D(1_791_176_400)        // Mon 5.10.2026 08:00 EEST = Torkku/20261005T0500Z

    init() {
        let fake = LabelFakeGmail()
        self.fake = fake
        service = SnoozeService(api: fake, directory: LabelDirectory(api: fake), now: { D(1_791_018_000) })
    }

    func makeStore(threads: [String] = ["a", "b", "c"]) async -> MailStore {
        for id in threads { fake.base.addThread(id) }
        let store = MailStore(api: fake, viewsStore: viewsStore)
        await store.start()
        return store
    }

    var ids: (MailStore) -> [String] { { $0.threads.map(\.id) } }

    func labels(_ store: MailStore, _ id: String) -> Set<String> {
        store.threads.first { $0.id == id }?.labelIDs ?? []
    }

    // MARK: - Single thread, inbox view

    @Test func snoozeInInboxRemovesRowAndSelectsNext() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["b", "c"])
        #expect(store.selectedThreadID == "b")
        #expect(fake.mutatingCalls == ["label create Torkku", "label create Torkku/20261005T0500Z", "modify a +Label_1,Label_2 -INBOX"])
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
        #expect(store.canUndo)
        #expect(store.toast == nil)
    }

    @Test func undoRestoresRowAndLabels() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(fake.mutatingCalls.last == "modify a +INBOX -Label_1,Label_2")
        #expect(fake.labelNames(of: "a") == ["INBOX"])
        #expect(store.selectedThreadID == "a")
        #expect(store.canUndo == false)
    }

    @Test func failureRollsBack() async {
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.selectedThreadID == "a")
        #expect(store.toast == "Torkutus epäonnistui")
        #expect(store.canUndo == false)
        #expect(fake.labelNames(of: "a") == ["INBOX"])
    }

    @Test func pastTimeToastNoCalls() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: D(1_791_017_940), using: service)
        #expect(store.toast == "Torkutusaika on jo mennyt")
        #expect(ids(store) == ["a", "b", "c"])
        #expect(fake.mutatingCalls.isEmpty)
        #expect(!fake.calls.contains { $0.hasPrefix("thread labels") || $0 == "list labels" })
        #expect(store.canUndo == false)
    }

    @Test func outOfRangeToastNoCalls() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: D(253_402_300_800), using: service)
        #expect(store.toast == "Torkutusaika ei kelpaa")
        #expect(ids(store) == ["a", "b", "c"])
        #expect(!fake.calls.contains { $0.hasPrefix("thread labels") })
    }

    // MARK: - Views where the row stays

    @Test func nonInboxViewKeepsRowAndPatchesLabels() async {
        fake.base.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["s"])
        #expect(labels(store, "s") == ["STARRED", "Label_1", "Label_2"])
        #expect(store.canUndo)
    }

    @Test func nonInboxFailureDoesNotAddInbox() async {
        fake.base.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["s"])
        #expect(labels(store, "s") == ["STARRED"])                         // archive's rollback would add INBOX
        #expect(store.toast == "Torkutus epäonnistui")
    }

    @Test func nonInboxFailureRestoresInbox() async {
        fake.base.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["is:starred"])
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        await store.snooze(until: until, using: service)
        #expect(labels(store, "s") == ["INBOX", "STARRED"])
    }

    @Test func negatedInboxQueryKeepsRow() async {
        fake.update { $0.lists["-in:inbox foo"] = ["a"] }
        let store = await makeStore()
        await store.search("-in:inbox foo")
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["a"])
        #expect(labels(store, "a") == ["Label_1", "Label_2"])
    }

    @Test func resnoozeInSnoozedViewAndUndo() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z", in: ["label:torkku"])     // Label_1, Label_2
        let store = await makeStore(threads: [])
        await store.search("label:torkku")
        await store.select(threadID: "a")
        await store.snooze(until: D(1_791_262_800), using: service)                    // Label_3 = …20261006T0500Z
        #expect(ids(store) == ["a"])
        #expect(labels(store, "a") == ["Label_1", "Label_3"])
        #expect(fake.mutatingCalls == ["label create Torkku/20261006T0500Z", "modify a +Label_1,Label_3 -INBOX,Label_2"])
        await store.undo()
        #expect(ids(store) == ["a"])
        #expect(labels(store, "a") == ["Label_1", "Label_2"])
        #expect(fake.mutatingCalls.last == "modify a +Label_2 -Label_3")
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
    }

    // MARK: - Multi-select

    @Test func bulkSnoozeCreatesLabelsOnce() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["b"])
        #expect(store.checkedIDs.isEmpty)
        #expect(fake.mutatingCalls.filter { $0.hasPrefix("label create") } == ["label create Torkku", "label create Torkku/20261005T0500Z"])
        #expect(Set(fake.mutatingCalls.filter { $0.hasPrefix("modify") }) == ["modify a +Label_1,Label_2 -INBOX", "modify c +Label_1,Label_2 -INBOX"])
        #expect(fake.calls.filter { $0 == "list labels" }.count == 1)
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(Set(fake.mutatingCalls.suffix(2)) == ["modify a +INBOX -Label_1,Label_2", "modify c +INBOX -Label_1,Label_2"])
        #expect(store.canUndo == false)
    }

    @Test func bulkPartialFailure() async {
        fake.update { $0.failingThreads = ["b"] }
        let store = await makeStore()
        store.checkAll()
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["b"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
        await store.undo()                                                 // covers only a and c
        #expect(ids(store) == ["a", "b", "c"])
        #expect(fake.labelNames(of: "b") == ["INBOX"])
    }

    @Test func bulkInNonInboxViewPatchesLabels() async {
        fake.base.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["is:starred"])
        fake.base.addThread("t", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        store.checkAll()
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["s", "t"])
        #expect(labels(store, "s") == ["STARRED", "Label_1", "Label_2"])
        #expect(labels(store, "t") == ["STARRED", "Label_1", "Label_2"])
        await store.undo()
        #expect(labels(store, "s") == ["STARRED", "INBOX"])
        #expect(labels(store, "t") == ["STARRED"])
    }

    // MARK: - Failures and races

    @Test func offlineSetsIsOffline() async {
        let store = await makeStore()
        store.highlight(threadID: "a")
        fake.update { $0.offline = true }
        await store.snooze(until: until, using: service)
        #expect(store.isOffline)
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.selectedThreadID == "a")
        #expect(store.toast == "Torkutus epäonnistui")
        #expect(store.canUndo == false)
    }

    @Test func snoozeDuringRefreshStaysRemoved() async throws {
        let store = await makeStore()
        await store.select(threadID: "a")
        let rows = Gate()
        fake.updateLabels { $0.summaryGate = rows }
        let refresh = Task { await store.refresh() }
        #expect(await rows.waitForArrivals(3))                             // the refresh read its rows, a still in INBOX
        await store.snooze(until: until, using: service)
        await rows.open()
        await refresh.value
        #expect(ids(store) == ["b", "c"])
    }

    /// The server drops a thread from the inbox listing when its modify lands, as Gmail does.
    func serverListsInboxLive() {
        fake.updateLabels { $0.beforeModify = { fake, id, _ in fake.update { $0.lists["in:inbox"]?.removeAll { $0 == id } } } }
    }

    @Test func refreshStartedDuringInFlightSnoozeStaysRemoved() async throws {
        let store = await makeStore()
        await store.select(threadID: "a")
        serverListsInboxLive()
        let reads = Gate()
        fake.updateLabels { $0.threadLabelsGate = reads }                   // the refresh lands before the modify
        let snooze = Task { await store.snooze(until: until, using: service) }
        #expect(await reads.waitForArrivals(1))
        await store.refresh()                                               // still lists "a"
        await reads.open()
        _ = await snooze.value
        #expect(ids(store) == ["b", "c"])
        #expect(store.canUndo)
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func refreshStartedDuringInFlightBulkSnoozeStaysRemoved() async throws {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        serverListsInboxLive()
        let reads = Gate()
        fake.updateLabels { $0.threadLabelsGate = reads }
        let snooze = Task { await store.snooze(until: until, using: service) }
        #expect(await reads.waitForArrivals(2))                             // both threads read, neither modified
        await store.refresh()
        await reads.open()
        _ = await snooze.value
        #expect(ids(store) == ["b"])
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
    }

    // Gmail search can list a thread for a few seconds after its labels changed (main's bulk queue
    // keeps archived rows out meanwhile). The fake's lists never catch up, so a refresh shows the lag.

    @Test func refreshSoonAfterSnoozeKeepsRowOut() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.refresh()                                               // the inbox listing still has a
        #expect(ids(store) == ["b", "c"])
        await store.selectView(store.views[1].id)
        await store.selectView(store.views[0].id)                           // a fresh load as well
        #expect(ids(store) == ["b", "c"])
    }

    @Test func refreshSoonAfterBulkSnoozeKeepsRowsOut() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        await store.snooze(until: until, using: service)
        await store.refresh()
        #expect(ids(store) == ["b"])
    }

    @Test func undoneSnoozeComesBackInLaterLists() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.undo()
        await store.refresh()
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func failedSnoozeDoesNotHideTheRow() async {
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore()
        store.toggleChecked("a")
        await store.snooze(until: until, using: service)
        await store.refresh()
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func snoozedRowReturnsOnceSearchLagGraceIsOver() async {
        let store = await makeStore()
        store.searchLagGrace = .zero
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.refresh()                                               // a list asked after the grace
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func labelInboxQueryRemovesRow() async {
        fake.update { $0.lists["label:inbox"] = ["a", "b"] }
        let store = await makeStore()
        await store.search("label:inbox")
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        #expect(ids(store) == ["b"])
    }

    @Test func labelInboxQueryKeepsSnoozedRowOutOnRefresh() async {
        fake.update { $0.lists["label:inbox"] = ["a", "b"] }
        let store = await makeStore()
        await store.search("label:inbox")
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.refresh()
        #expect(ids(store) == ["b"])
    }

    @Test func noSelectionIsNoop() async {
        let store = await makeStore()
        await store.snooze(until: until, using: service)
        #expect(fake.mutatingCalls.isEmpty)
        #expect(!fake.calls.contains { $0.hasPrefix("thread labels") })
        #expect(store.toast == nil)
        #expect(ids(store) == ["a", "b", "c"])
    }

    // MARK: - Fork (seisemail) Phase 1: return value and target

    @Test func snoozeReturnsOne() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 1)
        #expect(ids(store) == ["b", "c"])
        #expect(store.selectedThreadID == "b")
        #expect(fake.mutatingCalls == ["label create Torkku", "label create Torkku/20261005T0500Z", "modify a +Label_1,Label_2 -INBOX"])
        #expect(store.canUndo)
        #expect(store.toast == nil)
    }

    @Test func snoozeInNonInboxViewReturnsOne() async {
        fake.base.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 1)
        #expect(ids(store) == ["s"])
    }

    @Test func snoozeFailureReturnsZero() async {
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore()
        await store.select(threadID: "a")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 0)
        #expect(store.toast == "Torkutus epäonnistui")
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func nonInboxFailureReturnsZero() async {
        fake.base.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        fake.update { $0.failing = ["modify"] }
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 0)
    }

    @Test func pastTimeReturnsZero() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        let done = await store.snooze(until: D(1_791_017_940), using: service)
        #expect(done == 0)
        #expect(store.toast == "Torkutusaika on jo mennyt")
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func outOfRangeReturnsZero() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        let done = await store.snooze(until: D(253_402_300_800), using: service)
        #expect(done == 0)
        #expect(store.toast == "Torkutusaika ei kelpaa")
    }

    @Test func noSelectionReturnsZero() async {
        let store = await makeStore()
        let done = await store.snooze(until: until, using: service)
        #expect(done == 0)
        #expect(fake.mutatingCalls.isEmpty)
        #expect(store.toast == nil)
    }

    @Test func bulkReturnsCount() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 2)
        #expect(ids(store) == ["b"])
    }

    @Test func bulkPartialReturnsSuccesses() async {
        fake.update { $0.failingThreads = ["b"] }
        let store = await makeStore()
        store.checkAll()
        let done = await store.snooze(until: until, using: service)
        #expect(done == 2)
        #expect(ids(store) == ["b"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
    }

    @Test func bulkAllFailedReturnsZero() async {
        fake.update { $0.failingThreads = ["a", "b"] }
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("b")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 0)
        #expect(store.canUndo == false)
    }

    @Test func targetSingle() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        #expect(store.snoozeTarget?.threadIDs == ["a"])
        store.highlight(threadID: "b")
        #expect(store.snoozeTarget?.threadIDs == ["b"])
    }

    @Test func targetPrefersChecked() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        store.toggleChecked("b")
        store.toggleChecked("c")
        #expect(store.snoozeTarget?.threadIDs == ["b", "c"])
        #expect(store.snoozeTarget == SnoozeTarget(threadIDs: ["b", "c"]))
    }

    @Test func targetNilWithoutSelection() async {
        let store = await makeStore()
        #expect(store.snoozeTarget == nil)
    }

    @Test func targetOnlyListedThreads() async {
        let store = await makeStore()
        store.highlight(threadID: "gone")
        #expect(store.snoozeTarget == nil)
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)                   // a leaves the list; b is selected
        #expect(store.snoozeTarget?.threadIDs == ["b"])
    }

    @Test func snoozeInInboxZeroViewRemovesRow() async throws {
        try viewsStore.save(SeiseViews.defaults)
        for id in ["a", "b"] { fake.base.addThread(id, in: [InboxZero.defaultQuery, "in:inbox"]) }
        let store = await makeStore(threads: [])
        #expect(store.activeViewID == SeiseViews.inboxZeroID)
        #expect(ids(store) == ["a", "b"])
        await store.select(threadID: "a")
        let done = await store.snooze(until: until, using: service)
        #expect(done == 1)
        #expect(ids(store) == ["b"])
        #expect(fake.mutatingCalls.last == "modify a +Label_1,Label_2 -INBOX")
        await store.undo()
        #expect(ids(store) == ["a", "b"])
    }

    // MARK: - Rate limits, ⌘Z while running, view switches (main's bulk-job rules)

    func threadReads() -> Int { fake.calls.filter { $0.hasPrefix("thread labels") }.count }

    /// Starts ⌘Z and waits until it has taken its entry (isUndoing hides canUndo meanwhile).
    func startUndo(_ store: MailStore) async -> Task<Void, Never> {
        let undoing = Task { await store.undo() }
        await eventually("undo started") { !store.canUndo }
        return undoing
    }

    @Test func bulkSnoozeStopsAtTheFirstRateLimit() async {
        let all = (1...12).map { "t\($0)" }
        fake.updateLabels { $0.threadLabelsError = GmailError.rateLimited }
        let store = await makeStore(threads: all)
        store.checkAll()
        let done = await store.snooze(until: until, using: service)
        #expect(done == 0)
        #expect(threadReads() == 10)                                       // the first wave only; t11, t12 never start
        #expect(ids(store) == all)                                          // every row back at once
        #expect(store.toast == "Toiminto epäonnistui kaikissa 12 ketjussa")
        #expect(store.canUndo == false)
    }

    @Test func undoWhileASnoozeRunsTakesBackTheSnooze() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.archive()                                               // a out; b selected
        let gate = fake.base.holdWrites()
        let snooze = Task { await store.snooze(until: until, using: service) }
        await eventually("modify b held") { gate.parkedCount == 1 }
        #expect(ids(store) == ["c"])
        #expect(store.canUndo)
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        _ = await snooze.value
        #expect(fake.labelNames(of: "a").isEmpty)                          // the archive stands
        #expect(fake.labelNames(of: "b") == ["INBOX"])
        #expect(ids(store) == ["b", "c"])
        #expect(store.canUndo)                                              // the archive is still undoable
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.canUndo == false)
    }

    @Test func undoWhileABulkSnoozeRunsTakesBackTheSnooze() async {
        let store = await makeStore(threads: ["a", "b", "c", "d"])
        await store.select(threadID: "a")
        await store.archive()
        store.toggleChecked("b")
        store.toggleChecked("c")
        let gate = fake.base.holdWrites()
        let snooze = Task { await store.snooze(until: until, using: service) }
        await eventually("both modifies held") { gate.parkedCount == 2 }
        #expect(ids(store) == ["d"])
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        _ = await snooze.value
        #expect(fake.labelNames(of: "a").isEmpty)
        #expect(fake.labelNames(of: "b") == ["INBOX"])
        #expect(fake.labelNames(of: "c") == ["INBOX"])
        #expect(ids(store) == ["b", "c", "d"])
        #expect(store.canUndo)
    }

    @Test func undoMidwayStartsNoFurtherSnoozes() async {
        let all = (1...12).map { "t\($0)" }
        let store = await makeStore(threads: all)
        store.checkAll()
        let gate = fake.base.holdWrites()
        let snooze = Task { await store.snooze(until: until, using: service) }
        await eventually("first wave held") { gate.parkedCount == 10 }
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        let done = await snooze.value
        #expect(done == 0)
        #expect(!fake.calls.contains { ["thread labels t11", "thread labels t12"].contains($0) })   // never sent
        #expect(!fake.mutatingCalls.contains { $0.hasPrefix("modify t11") || $0.hasPrefix("modify t12") })
        #expect(ids(store) == all)
        #expect(all.allSatisfy { fake.labelNames(of: $0) == ["INBOX"] })
        #expect(store.canUndo == false)
        #expect(store.toast == nil)
    }

    @Test func bulkSnoozeUndoAfterSwitchingViewsLeavesTheOpenViewAlone() async {
        fake.base.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = await makeStore()
        for id in ["a", "b", "c"] { store.toggleChecked(id) }
        await store.snooze(until: until, using: service)
        #expect(ids(store) == [])
        await store.selectView(store.views[3].id)                          // Tähdellä
        #expect(ids(store) == ["s"])
        await store.undo()
        #expect(ids(store) == ["s"])
        #expect(fake.labelNames(of: "a") == ["INBOX"])
        await store.selectView(store.views[0].id)
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func snoozeUndoAfterSwitchingViewsLeavesTheOpenViewAlone() async {
        fake.base.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.snooze(until: until, using: service)
        await store.selectView(store.views[3].id)
        await store.undo()
        #expect(ids(store) == ["s"])
        #expect(fake.labelNames(of: "a") == ["INBOX"])
        await store.selectView(store.views[0].id)
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func wrapperKeepsArchiveBehaviour() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        #expect(fake.mutatingCalls == ["modify a + -INBOX"])
        #expect(ids(store) == ["b", "c"])
    }
}
