import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct MailStoreBulkTests {
    let api = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    func makeStore(_ ids: [String] = ["a", "b", "c"], messageIDs: Bool = true) async -> MailStore {
        api.update { $0.summaryMessageIDs = messageIDs }
        for id in ids { api.addThread(id) }
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        return store
    }

    func inInbox(_ id: String) -> Bool {
        api.state.withLock { $0.threads[id]?.labelIDs.contains(GmailLabel.inbox) ?? false }
    }

    // MARK: - batchModify

    let five = ["a", "b", "c", "d", "e"]

    @Test func bulkArchiveUsesOneBatchModify() async {
        let store = await makeStore(five)
        store.checkAll()
        await store.archive()
        #expect(store.threads.isEmpty)
        #expect(api.mutatingCalls == ["batchModify a-m,b-m,c-m,d-m,e-m + -INBOX"])
        #expect(five.allSatisfy { !inInbox($0) })
    }

    @Test func bulkOfFewerThanFiveUsesThreadsModify() async {
        let store = await makeStore(["a", "b", "c", "d"])
        store.checkAll()
        await store.markUnread()
        #expect(Set(api.mutatingCalls) == ["modify a +UNREAD -", "modify b +UNREAD -", "modify c +UNREAD -", "modify d +UNREAD -"])
    }

    @Test func bulkReadUnreadAndStarUseBatchModify() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(["a", "b", "c", "d"])
        store.checkAll()
        await store.markUnread()
        await store.markRead()
        await store.toggleStar()
        await store.toggleStar()
        let ids = "u-m,a-m,b-m,c-m,d-m"
        #expect(api.mutatingCalls == [
            "batchModify \(ids) +UNREAD -",
            "batchModify \(ids) + -UNREAD",
            "batchModify \(ids) +STARRED -",
            "batchModify \(ids) + -STARRED",
        ])
        #expect(store.threads.allSatisfy { !$0.isUnread && !$0.isStarred })
    }

    @Test func bulkTrashUsesThreadsTrash() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        await store.trash()
        #expect(Set(api.mutatingCalls) == ["trash a", "trash c"])
        #expect(store.threads.map(\.id) == ["b"])
    }

    @Test func singleArchiveStaysOnThreadsModify() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        #expect(api.mutatingCalls == ["modify a + -INBOX"])
    }

    @Test func rowsWithoutMessageIDsFallBackToThreadsModify() async {
        let store = await makeStore(messageIDs: false)
        store.checkAll()
        await store.archive()
        #expect(Set(api.mutatingCalls) == ["modify a + -INBOX", "modify b + -INBOX", "modify c + -INBOX"])
    }

    @Test func batchesSplitAtThousandMessageIDsAlongThreads() async {
        let ids = (0..<1_500).map { String(format: "t%04d", $0) }
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 1_500)
        api.update { $0.summaryMessageIDs = true }
        for id in ids { api.addThread(id) }
        await store.start()
        store.checkAll()
        await store.archive()
        let sizes = api.mutatingCalls.map { $0.split(separator: " ")[1].split(separator: ",").count }
        #expect(sizes == [1_000, 500])
        #expect(store.threads.isEmpty)
    }

    @Test func failedBatchComesBackWithPartialFailureToast() async {
        api.update { $0.failingThreads = ["b"] }
        let store = await makeStore(five)
        store.checkAll()
        await store.archive()
        #expect(store.threads.map(\.id) == five)                 // one call: all five failed together
        #expect(store.toast == "Toiminto epäonnistui kaikissa 5 ketjussa")
        #expect(store.bulkStatuses.isEmpty)
        #expect(store.canUndo == false)
    }

    @Test func undoAfterBatchArchiveIsOneBatchModify() async {
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        let store = await makeStore(ids)
        for id in ["a", "c", "d", "e", "g"] { store.toggleChecked(id) }
        await store.archive()
        #expect(store.threads.map(\.id) == ["b", "f"])
        await store.undo()
        #expect(store.threads.map(\.id) == ids)
        #expect(api.mutatingCalls == ["batchModify a-m,c-m,d-m,e-m,g-m + -INBOX", "batchModify a-m,c-m,d-m,e-m,g-m +INBOX -"])
        #expect(store.bulkStatuses.isEmpty)
    }

    // MARK: - Status

    // Tests that act while a job runs hold its writes at a closed gate and wait until the fake
    // has them (`writesInFlight`), never on the status line alone: the status appears before any
    // write is sent, and a wall-clock delay can run out before the test gets to act.

    /// Waits until exactly `count` writes are recorded and parked at `gate`.
    func writesInFlight(_ count: Int, at gate: CallGate) async -> Bool {
        let api = api
        return await eventually { gate.parkedCount == count && api.mutatingCalls.count == count }
    }

    /// Starts ⌘Z while the job's writes are held and waits until it is waiting for them.
    func startUndo(_ store: MailStore) async -> Task<Void, Never> {
        let undoing = Task { await store.undo() }
        #expect(await eventually { @MainActor in store.bulkStatuses.first?.isUndoing == true })
        return undoing
    }

    @Test func statusShowsWhileRunningThenDone() async throws {
        let gate = api.holdWrites()
        let store = await makeStore()
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await writesInFlight(3, at: gate))
        #expect(store.threads.isEmpty)                            // rows leave at once
        let status = try #require(store.bulkStatuses.first)
        #expect(status.text == "Arkistoidaan 3 ketjua…")
        #expect(status.isFinished == false)
        #expect(store.canUndo)
        gate.open()
        await running.value
        #expect(store.bulkStatuses[0].text == "Arkistoitu 3 ketjua")
        #expect(store.bulkStatuses[0].isFinished)
        #expect(store.bulkStatuses[0].fraction == 1)
        store.dismissBulkStatus(store.bulkStatuses[0].id)
        #expect(store.bulkStatuses.isEmpty)
    }

    @Test func runningStatusCannotBeDismissed() async throws {
        let gate = api.holdWrites()
        let store = await makeStore()
        store.checkAll()
        let running = Task { await store.trash() }
        #expect(await writesInFlight(3, at: gate))
        store.dismissBulkStatus(try #require(store.bulkStatuses.first).id)
        #expect(store.bulkStatuses.count == 1)
        gate.open()
        await running.value
    }

    @Test func partialFailureKeepsDoneStatusAndToasts() async {
        api.update { $0.failingThreads = ["b"] }
        let store = await makeStore(messageIDs: false)
        store.checkAll()
        await store.archive()
        #expect(store.threads.map(\.id) == ["b"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
        #expect(store.bulkStatuses.map(\.text) == ["Arkistoitu 2 ketjua"])
    }

    @Test func undoWhileRunningUndoesTheWholeBatch() async throws {
        let gate = api.holdWrites()
        let ids = (0..<15).map { "t\($0)" }
        let store = await makeStore(ids, messageIDs: false)
        store.checkAll()
        let running = Task { await store.archive() }
        // All ten concurrent writes are on the wire and none has finished, so no eleventh can start.
        #expect(await writesInFlight(10, at: gate))
        #expect(store.threads.isEmpty)
        let undoing = await startUndo(store)                      // waits for the ten in flight
        gate.open()
        await undoing.value
        await running.value
        #expect(store.threads.map(\.id) == ids)
        #expect(ids.allSatisfy { inInbox($0) })
        let archived = api.mutatingCalls.filter { $0.hasSuffix("+ -INBOX") }
        let restored = api.mutatingCalls.filter { $0.hasSuffix("+INBOX -") }
        #expect(archived.count == 10)                             // the other five were never sent
        #expect(restored.count == 10)
        #expect(store.bulkStatuses.isEmpty)
        #expect(store.canUndo == false)
        #expect(store.toast == nil)
    }

    @Test func undoWhileRunningLabelsRevertsOnScreenAndOnGmail() async throws {
        let gate = api.holdWrites()
        let store = await makeStore(five)
        store.checkAll()
        let running = Task { await store.toggleStar() }
        #expect(await writesInFlight(1, at: gate))                // the batchModify is on the wire
        #expect(store.threads.allSatisfy { $0.isStarred })
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        await running.value
        #expect(store.threads.allSatisfy { !$0.isStarred })
        let ids = "a-m,b-m,c-m,d-m,e-m"
        #expect(api.mutatingCalls == ["batchModify \(ids) +STARRED -", "batchModify \(ids) + -STARRED"])
    }

    // MARK: - Texts

    @Test func finnishTexts() {
        #expect(BulkStatus.runningText(.archive, count: 140) == "Arkistoidaan 140 ketjua…")
        #expect(BulkStatus.doneText(.archive, count: 140) == "Arkistoitu 140 ketjua")
        #expect(BulkStatus.runningText(.archive, count: 1) == "Arkistoidaan 1 ketju…")
        #expect(BulkStatus.doneText(.archive, count: 1) == "Arkistoitu 1 ketju")
        #expect(BulkStatus.runningText(.trash, count: 2) == "Siirretään 2 ketjua roskakoriin…")
        #expect(BulkStatus.doneText(.trash, count: 2) == "Siirretty 2 ketjua roskakoriin")
        #expect(BulkStatus.runningText(.markRead, count: 2) == "Merkitään 2 ketjua luetuiksi…")
        #expect(BulkStatus.doneText(.markRead, count: 1) == "Merkitty 1 ketju luetuksi")
        #expect(BulkStatus.runningText(.markUnread, count: 5) == "Merkitään 5 ketjua lukemattomiksi…")
        #expect(BulkStatus.doneText(.markUnread, count: 1) == "Merkitty 1 ketju lukemattomaksi")
        #expect(BulkStatus.runningText(.star, count: 3) == "Lisätään tähti 3 ketjuun…")
        #expect(BulkStatus.doneText(.star, count: 3) == "Tähti lisätty 3 ketjuun")
        #expect(BulkStatus.runningText(.unstar, count: 3) == "Poistetaan tähti 3 ketjusta…")
        #expect(BulkStatus.doneText(.unstar, count: 1) == "Tähti poistettu 1 ketjusta")
        #expect(BulkStatus.undoingText(.archive) == "Kumotaan arkistointi…")
        #expect(BulkStatus.undoingText(.trash) == "Kumotaan roskakoriin siirtäminen…")
        #expect(BulkStatus.undoingText(.markRead) == "Kumotaan luetuksi merkitseminen…")
        #expect(BulkStatus.undoingText(.markUnread) == "Kumotaan lukemattomaksi merkitseminen…")
        #expect(BulkStatus.undoingText(.star) == "Kumotaan tähden lisääminen…")
        #expect(BulkStatus.undoingText(.unstar) == "Kumotaan tähden poistaminen…")
    }

    @Test func undoWhileRunningSaysSoUntilDone() async throws {
        let store = await makeStore(messageIDs: false)
        await store.select(threadID: "a")
        await store.toggleStar()                                  // an older action on the undo stack
        let gate = api.holdWrites()
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await eventually { gate.parkedCount == 3 })
        let undoing = Task { await store.undo() }
        #expect(await eventually { @MainActor in store.bulkStatuses.first?.text == "Kumotaan arkistointi…" })
        #expect(store.bulkStatuses.first?.isUndoing == true)
        #expect(store.canUndo == false)                           // a second ⌘Z waits for this one
        await store.undo()
        gate.open()
        await undoing.value
        await running.value
        #expect(store.bulkStatuses.isEmpty)
        #expect(store.threads.map(\.id) == ["a", "b", "c"])
        #expect(store.threads[0].isStarred)                       // the star was not undone
        #expect(store.canUndo)
    }
}

extension MailStoreBulkTests {
    @Test func refreshDuringBulkArchiveDoesNotBringRowsBack() async throws {
        let gate = api.holdWrites()
        let store = await makeStore(["a", "b", "c", "d"], messageIDs: false)
        store.toggleChecked("a")
        store.toggleChecked("b")
        let running = Task { await store.archive() }
        #expect(await writesInFlight(2, at: gate))
        await store.refresh()                                     // Gmail still lists a and b
        #expect(store.threads.map(\.id) == ["c", "d"])
        gate.open()
        await running.value
        #expect(store.threads.map(\.id) == ["c", "d"])
        #expect(api.mutatingCalls.count == 2)
    }
}

// MARK: - Lists while a job is pending, and where rows come back

extension MailStoreBulkTests {
    @Test func refreshStraddlingFinishDoesNotBringRowsBack() async throws {
        let writes = api.holdWrites()
        let store = await makeStore(["a", "b", "c", "d"], messageIDs: false)
        store.toggleChecked("a")
        store.toggleChecked("b")
        let running = Task { await store.archive() }
        #expect(await writesInFlight(2, at: writes))
        let lists = api.holdLists()
        let refreshing = Task { await store.refresh() }           // lists a and b before the writes land
        #expect(await eventually { lists.parkedCount == 1 })
        writes.open()
        await running.value
        #expect(store.bulkStatuses.first?.isFinished == true)
        lists.open()
        await refreshing.value                                    // …and merges after the job finished
        #expect(store.threads.map(\.id) == ["c", "d"])
    }

    @Test func listStartedSoonAfterFinishStillHidesRows() async {
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        store.toggleChecked("a")
        await store.archive()
        await store.refresh()                                     // Gmail search still lags: lists a
        #expect(store.threads.map(\.id) == ["b", "c"])
    }

    @Test func archivedRowsShowInANegatedInboxSearch() async {
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        api.update { $0.lists["-in:inbox"] = ["a"] }
        store.toggleChecked("a")
        await store.archive()
        await store.search("-in:inbox")                               // "-in:inbox" does not list the inbox
        #expect(store.threads.map(\.id) == ["a"])
    }

    @Test func rowsComeBackOnceALaterListHasThemAgain() async {
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        store.searchLagGrace = .zero
        store.toggleChecked("a")
        await store.archive()
        await store.refresh()                                     // e.g. moved back to the inbox elsewhere
        #expect(store.threads.map(\.id) == ["a", "b", "c"])
    }

    @Test func undoMidBatchKeepsListOrderWithRowsAfterTheBatch() async throws {
        let gate = api.holdWrites()
        let batch = (0..<12).map { "t\($0)" }
        let store = await makeStore(batch + ["z"], messageIDs: false)
        for id in batch { store.toggleChecked(id) }
        let running = Task { await store.archive() }
        #expect(await writesInFlight(10, at: gate))               // t10 and t11 not sent yet
        #expect(store.threads.map(\.id) == ["z"])
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        await running.value
        #expect(store.threads.map(\.id) == batch + ["z"])
    }

    @Test func failedRowComesBackInPlaceAfterAnEarlierSuccess() async {
        api.update { $0.failingThreads = ["c"] }
        let store = await makeStore(["a", "b", "c", "d"], messageIDs: false)
        store.toggleChecked("b")
        store.toggleChecked("c")
        await store.archive()
        #expect(store.threads.map(\.id) == ["a", "c", "d"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 2)")
    }

    func addStarred() {
        api.addThread("s", labels: [GmailLabel.starred], in: ["is:starred"])
    }

    @Test func failedRowsStayOutOfAViewOpenedMeanwhile() async throws {
        addStarred()
        api.update { $0.failingThreads = ["b"] }
        let gate = api.holdWrites()
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        store.checkAll()
        let running = Task { await store.trash() }
        #expect(await writesInFlight(3, at: gate))
        await store.search("is:starred")
        gate.open()
        await running.value
        #expect(store.threads.map(\.id) == ["s"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
        await store.selectView(store.views[0].id)                // back in the inbox: b is there, a and c not
        #expect(store.threads.map(\.id) == ["b"])
    }

    // Fork (seisemail): archive decides with the same positive-term test as the pending rows and snooze.

    @Test func bulkArchiveInANegatedInboxSearchKeepsTheRows() async {
        api.update { $0.lists["-in:inbox foo"] = ["a", "b"] }
        let store = await makeStore(["a", "b"], messageIDs: false)
        await store.search("-in:inbox foo")
        store.checkAll()
        await store.archive()
        #expect(store.threads.map(\.id) == ["a", "b"])
        #expect(store.threads.allSatisfy { !$0.labelIDs.contains(GmailLabel.inbox) })
    }

    @Test func archiveInANegatedInboxSearchKeepsTheRow() async {
        api.update { $0.lists["-in:inbox foo"] = ["a", "b"] }
        let store = await makeStore(["a", "b"], messageIDs: false)
        await store.search("-in:inbox foo")
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.threads.map(\.id) == ["a", "b"])
    }

    @Test func archiveInALabelInboxSearchRemovesTheRow() async {
        api.update { $0.lists["label:inbox"] = ["a", "b"] }
        let store = await makeStore(["a", "b"], messageIDs: false)
        await store.search("label:inbox")
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.threads.map(\.id) == ["b"])
    }

    @Test func undoAfterSwitchingViewsLeavesTheOpenViewAlone() async throws {
        addStarred()
        let gate = api.holdWrites()
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await writesInFlight(3, at: gate))
        await store.search("is:starred")
        let undoing = await startUndo(store)
        gate.open()
        await undoing.value
        await running.value
        #expect(store.threads.map(\.id) == ["s"])
        await store.selectView(store.views[0].id)
        #expect(store.threads.map(\.id) == ["a", "b", "c"])
    }

    @Test func archivedRowsStillShowInOtherViewsWhilePending() async throws {
        api.addThread("a", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        let gate = api.holdWrites()
        let store = await makeStore(["b"], messageIDs: false)
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await writesInFlight(2, at: gate))
        await store.search("is:starred")
        #expect(store.threads.map(\.id) == ["a"])
        gate.open()
        await running.value
    }

    @Test func trashedRowsStayHiddenInOtherViewsWhilePending() async throws {
        api.addThread("a", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["in:inbox", "is:starred"])
        let gate = api.holdWrites()
        let store = await makeStore(["b"], messageIDs: false)
        store.checkAll()
        let running = Task { await store.trash() }
        #expect(await writesInFlight(2, at: gate))
        await store.search("is:starred")
        #expect(store.threads.isEmpty)
        gate.open()
        await running.value
    }

    @Test func reloadWhilePendingHidesRows() async throws {
        let gate = api.holdWrites()
        let store = await makeStore(["a", "b", "c"], messageIDs: false)
        store.toggleChecked("b")
        let running = Task { await store.archive() }
        #expect(await writesInFlight(1, at: gate))
        await store.selectView(store.views[0].id)
        #expect(store.threads.map(\.id) == ["a", "c"])
        gate.open()
        await running.value
    }

    @Test func loadMoreWhilePendingHidesRows() async throws {
        let gate = api.holdWrites()
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 2)
        for id in ["a", "b", "c", "d", "e", "f"] { api.addThread(id) }
        await store.start()
        store.checkAll()
        let running = Task { await store.archive() }
        #expect(await writesInFlight(2, at: gate))
        api.update { $0.lists["in:inbox"] = ["c", "d", "a", "b", "e", "f"] }   // page 2 still has a and b
        await store.loadMore()
        #expect(store.threads.isEmpty)
        gate.open()
        await running.value
    }
}
