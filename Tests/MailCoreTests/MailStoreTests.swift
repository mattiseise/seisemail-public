import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct MailStoreTests {
    let api = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    func makeStore(threads: [String] = ["a", "b", "c"]) async -> MailStore {
        for id in threads { api.addThread(id) }
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        return store
    }

    var ids: (MailStore) -> [String] { { $0.threads.map(\.id) } }

    @Test func startLoadsInboxAndCounts() async {
        api.update { $0.inboxUnread = 4; $0.estimates["is:starred"] = 2 }
        let store = await makeStore()
        #expect(store.me == "maija.meikalainen@gmail.com")
        #expect(store.activeViewID == store.views.first?.id)
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.unreadCounts[store.views[0].id] == 4)
        #expect(store.unreadCounts[store.views[3].id] == 2)
        #expect(store.isLoading == false)
    }

    @Test func readingLowersVisibleViewCountAtOnce() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        api.update { $0.inboxUnread = 1 }
        let store = await makeStore(threads: [])
        let inbox = store.views[0].id
        #expect(store.unreadCounts[inbox] == 1)
        await store.select(threadID: "u")
        #expect(store.unreadCounts[inbox] == 0)
    }

    @Test func selectOpensThreadAndMarksRead() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        await store.select(threadID: "u")
        #expect(store.openThread?.id == "u")
        #expect(store.threads[0].isUnread == false)
        #expect(store.openThread?.isUnread == false)
        #expect(api.mutatingCalls == ["modify u + -UNREAD"])
    }

    @Test func selectReadThreadDoesNotModify() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        #expect(api.mutatingCalls.isEmpty)
    }

    @Test func staleThreadLoadIsIgnored() async throws {
        let store = await makeStore()
        let gate = api.holdThread("a")
        let slow = Task { await store.select(threadID: "a") }
        #expect(await eventually { gate.parkedCount == 1 })                 // a's load is in flight
        await store.select(threadID: "b")
        gate.open()
        await slow.value
        #expect(store.selectedThreadID == "b")
        #expect(store.openThread?.id == "b")
    }

    @Test func selectNextAndPrevious() async {
        let store = await makeStore()
        await store.selectNext()
        #expect(store.selectedThreadID == "a")
        await store.selectNext()
        #expect(store.selectedThreadID == "b")
        await store.selectPrevious()
        #expect(store.selectedThreadID == "a")
        await store.selectPrevious()
        #expect(store.selectedThreadID == "a")
    }

    @Test func archiveRemovesAndAdvances() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        #expect(ids(store) == ["b", "c"])
        #expect(store.selectedThreadID == "b")
        #expect(api.mutatingCalls == ["modify a + -INBOX"])
        #expect(store.canUndo)
    }

    @Test func archiveLastRowSelectsPrevious() async {
        let store = await makeStore()
        await store.select(threadID: "c")
        await store.archive()
        #expect(ids(store) == ["a", "b"])
        #expect(store.selectedThreadID == "b")
    }

    @Test func archiveOnlyRowClearsSelection() async {
        let store = await makeStore(threads: ["a"])
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.threads.isEmpty)
        #expect(store.selectedThreadID == nil)
        #expect(store.openThread == nil)
    }

    @Test func archiveFailureRevertsAndToasts() async {
        api.update { $0.failing.insert("modify") }
        let store = await makeStore()
        await store.select(threadID: "b")
        await store.archive()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.selectedThreadID == "b")
        #expect(store.toast == "Arkistointi epäonnistui")
        #expect(store.canUndo == false)
    }

    @Test func archiveInNonInboxViewKeepsRow() async {
        api.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred], in: ["is:starred"])
        let store = await makeStore(threads: [])
        await store.selectView(store.views[3].id)
        await store.select(threadID: "s")
        await store.archive()
        #expect(ids(store) == ["s"])
        #expect(store.threads[0].labelIDs.contains(GmailLabel.inbox) == false)
    }

    @Test func toggleStarOptimistic() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.toggleStar()
        #expect(store.threads[0].isStarred)
        #expect(api.mutatingCalls == ["modify a +STARRED -"])
        await store.toggleStar()
        #expect(store.threads[0].isStarred == false)
        #expect(api.mutatingCalls.last == "modify a + -STARRED")
    }

    @Test func toggleStarFailureReverts() async {
        api.update { $0.failing.insert("modify") }
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.toggleStar()
        #expect(store.threads[0].isStarred == false)
        #expect(store.toast == "Tähden muutos epäonnistui")
    }

    @Test func trashRemovesRow() async {
        let store = await makeStore()
        await store.select(threadID: "b")
        await store.trash()
        #expect(ids(store) == ["a", "c"])
        #expect(store.selectedThreadID == "c")
        #expect(api.mutatingCalls == ["trash b"])
    }

    @Test func markUnreadAddsLabel() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.markUnread()
        #expect(store.threads[0].isUnread)
        #expect(api.mutatingCalls == ["modify a +UNREAD -"])
    }

    @Test func undoArchiveRestoresRow() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.archive()
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.selectedThreadID == "a")
        #expect(api.mutatingCalls == ["modify a + -INBOX", "modify a +INBOX -"])
        #expect(store.canUndo == false)
    }

    @Test func undoTrashUntrashes() async {
        let store = await makeStore()
        await store.select(threadID: "b")
        await store.trash()
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(api.mutatingCalls.last == "untrash b")
    }

    @Test func undoReinsertsAtClampedIndex() async {
        let store = await makeStore()
        await store.select(threadID: "c")
        await store.archive()          // removed from index 2
        await store.select(threadID: "b")
        await store.archive()          // list is now ["a"]
        await store.select(threadID: "a")
        await store.archive()          // list is now []
        await store.undo()             // "a" back at index 0
        await store.undo()             // "b" back at index 1
        await store.undo()             // "c" back at index 2
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func undoStarReverts() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.toggleStar()
        await store.undo()
        #expect(store.threads[0].isStarred == false)
        #expect(api.mutatingCalls.last == "modify a + -STARRED")
    }

    @Test func offlineFlagSetAndCleared() async {
        let store = await makeStore()
        api.update { $0.offline = true }
        await store.refresh()
        #expect(store.isOffline)
        #expect(ids(store) == ["a", "b", "c"]) // cached list kept
        api.update { $0.offline = false }
        await store.refresh()
        #expect(store.isOffline == false)
    }

    @Test func searchCreatesTemporaryView() async {
        api.addThread("x", in: ["from:matti"])
        let store = await makeStore()
        await store.search("from:matti")
        #expect(store.searchQuery == "from:matti")
        #expect(store.activeQuery == "from:matti")
        #expect(ids(store) == ["x"])
        store.saveSearchAsView(name: "Matti")
        #expect(store.searchQuery == nil)
        #expect(store.views.last?.name == "Matti")
        #expect(store.activeViewID == store.views.last?.id)
        #expect(viewsStore.load().last?.query == "from:matti")
    }

    @Test func emptySearchReturnsToView() async {
        let store = await makeStore()
        await store.search("from:x")
        await store.search("   ")
        #expect(store.searchQuery == nil)
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func loadMoreAppendsNextPage() async {
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 2)
        for id in ["a", "b", "c"] { api.addThread(id) }
        await store.start()
        #expect(ids(store) == ["a", "b"])
        #expect(store.canLoadMore)
        await store.loadMore()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.canLoadMore == false)
    }

    @Test func selectNextLoadsMoreAtEnd() async {
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 2)
        for id in ["a", "b", "c"] { api.addThread(id) }
        await store.start()
        await store.select(threadID: "b")
        await store.selectNext()
        #expect(store.selectedThreadID == "c")
    }

    @Test func refreshKeepsSelectionWhenPresent() async {
        let store = await makeStore()
        await store.select(threadID: "b")
        api.addThread("d")
        await store.refresh()
        #expect(ids(store) == ["a", "b", "c", "d"])
        #expect(store.selectedThreadID == "b")
    }

    @Test func refreshClearsSelectionWhenGone() async {
        let store = await makeStore()
        await store.select(threadID: "b")
        api.update { $0.lists["in:inbox"] = ["a", "c"] }
        await store.refresh()
        #expect(store.selectedThreadID == nil)
        #expect(store.openThread == nil)
    }

    @Test func switchingViewClearsSelection() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.selectView(MailView.folders[1].id)
        #expect(store.selectedThreadID == nil)
        #expect(store.threads.isEmpty)
    }

    @Test func updateViewsPersistsAndFallsBack() async {
        let store = await makeStore()
        let only = MailView(name: "Vain", query: "in:inbox")
        await store.updateViews([only])
        #expect(viewsStore.load() == [only])
        #expect(store.activeViewID == only.id)
    }

    @Test func authFailureRequestsSignIn() async {
        final class Revoked: GmailAPI, @unchecked Sendable {
            func profileEmail() async throws -> String { throw AuthError.invalidGrant }
            func listThreads(query: String, pageToken: String?, maxResults: Int) async throws -> ThreadPage { throw AuthError.invalidGrant }
            func threadSummary(id: String, me: String?) async throws -> ThreadSummary { throw AuthError.invalidGrant }
            func thread(id: String) async throws -> MailThread { throw AuthError.invalidGrant }
            func modify(threadID: String, add: [String], remove: [String]) async throws {}
            func batchModify(messageIDs: [String], add: [String], remove: [String]) async throws {}
            func trash(threadID: String) async throws {}
            func untrash(threadID: String) async throws {}
            func send(raw: Data, threadID: String?) async throws {}
            func attachmentData(messageID: String, attachmentID: String) async throws -> Data { Data() }
            func inboxUnreadCount() async throws -> Int { 0 }
            func unreadEstimate(query: String) async throws -> Int { 0 }
            func sendAsSignatures() async throws -> [SendAsSignature] { [] }
        }
        let store = MailStore(api: Revoked(), viewsStore: viewsStore)
        await store.start()
        #expect(store.needsSignIn)
    }

    // MARK: - Final review fixes

    @Test func refreshKeepsLoadedPagesAndOlderSelection() async {
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 2)
        for id in ["a", "b", "c"] { api.addThread(id) }
        await store.start()
        await store.loadMore()
        await store.select(threadID: "c")
        await store.refresh()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(store.selectedThreadID == "c")
        #expect(store.openThread?.id == "c")
    }

    @Test func refreshShowsNewMailOnTop() async {
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: 2)
        for id in ["a", "b", "c"] { api.addThread(id) }
        await store.start()
        await store.loadMore()
        api.update { $0.lists["in:inbox"] = ["n", "a", "b", "c"] }
        api.addThread("n", in: [])
        await store.refresh()
        #expect(ids(store) == ["n", "a", "b", "c"])
    }

    @Test func archiveDuringRefreshIsNotUndoneByStaleResult() async throws {
        let store = await makeStore()
        await store.select(threadID: "a")
        let rows = api.holdSummaries()
        let refresh = Task { await store.refresh() }
        #expect(await eventually { rows.parkedCount == 3 })                 // rows read while a was in INBOX
        api.update { $0.summaryGate = nil }
        await store.archive()
        rows.open()
        await refresh.value
        #expect(ids(store) == ["b", "c"])
    }

    @Test func markReadDuringRefreshStaysRead() async throws {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        let rows = api.holdSummaries()
        let refresh = Task { await store.refresh() }
        #expect(await eventually { rows.parkedCount == 1 })                 // u's row read while still unread
        api.update { $0.summaryGate = nil }
        await store.select(threadID: "u")
        rows.open()
        await refresh.value
        #expect(store.threads.first?.isUnread == false)
    }

    @Test func refreshInvalidatesCacheWhenThreadGrew() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.select(threadID: "b")
        api.update { s in
            var t = s.threads["a"]!
            var reply = t.messages[0]
            reply.id = "a-m2"
            reply.textBody = "Uusi vastaus"
            t.messages.append(reply)
            s.threads["a"] = t
        }
        await store.refresh()
        await store.select(threadID: "a")
        #expect(store.openThread?.messages.count == 2)
    }

    @Test func refreshFetchesProfileIfStartWasOffline() async {
        api.addThread("a")
        api.update { $0.offline = true }
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        #expect(store.me == nil)
        api.update { $0.offline = false }
        await store.refresh()
        #expect(store.me == "maija.meikalainen@gmail.com")
    }

    // MARK: - Side peek: highlight vs open

    @Test func highlightDoesNotLoadOrMarkRead() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        store.highlight(threadID: "u")
        #expect(store.selectedThreadID == "u")
        #expect(store.isPeekOpen == false)
        #expect(store.openThread == nil)
        #expect(store.threads[0].isUnread)
        #expect(!api.calls.contains("thread u"))
    }

    @Test func selectOpensPeek() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        #expect(store.isPeekOpen)
    }

    @Test func closePeekKeepsSelection() async {
        let store = await makeStore()
        await store.select(threadID: "b")
        store.closePeek()
        #expect(store.isPeekOpen == false)
        #expect(store.openThread == nil)
        #expect(store.selectedThreadID == "b")
    }

    @Test func nextWithPeekClosedOnlyHighlights() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        await store.selectNext()
        #expect(store.selectedThreadID == "u")
        #expect(store.isPeekOpen == false)
        #expect(store.threads[0].isUnread)
    }

    @Test func nextWithPeekOpenOpensNext() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        await store.selectNext()
        #expect(store.openThread?.id == "b")
        #expect(store.isPeekOpen)
    }

    @Test func archiveWithPeekClosedHighlightsNext() async {
        let store = await makeStore()
        store.highlight(threadID: "a")
        await store.archive()
        #expect(store.selectedThreadID == "b")
        #expect(store.isPeekOpen == false)
        #expect(!api.calls.contains("thread b"))
    }

    @Test func foldersCanBeSelected() async {
        api.addThread("s", in: ["in:sent"])
        let store = await makeStore()
        await store.selectView(MailView.folders[1].id)
        #expect(store.activeQuery == "in:sent")
        #expect(store.activeTitle == "Lähetetyt")
        #expect(ids(store) == ["s"])
    }

    @Test func openInInboxSwitchesViewAndOpensThread() async {
        api.addThread("s", in: ["is:starred"])
        let store = await makeStore()
        await store.selectView(store.views[3].id)
        await store.openInInbox(threadID: "b")
        #expect(store.activeQuery == "in:inbox")
        #expect(store.openThread?.id == "b")
        #expect(store.isPeekOpen)
    }

    // MARK: - Multi-select

    @Test func toggleAndRangeSelection() async {
        let store = await makeStore(threads: ["a", "b", "c", "d", "e"])
        store.toggleChecked("b")
        #expect(store.checkedIDs == ["b"])
        store.checkRange(to: "d")
        #expect(store.checkedIDs == ["b", "c", "d"])
        store.toggleChecked("c")
        #expect(store.checkedIDs == ["b", "d"])
    }

    @Test func checkAllAndClear() async {
        let store = await makeStore()
        store.checkAll()
        #expect(store.checkedIDs == ["a", "b", "c"])
        store.clearChecked()
        #expect(store.checkedIDs.isEmpty)
    }

    @Test func checkingClosesPeek() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        store.toggleChecked("b")
        #expect(store.isPeekOpen == false)
    }

    @Test func bulkArchiveRemovesAllAndUndoRestores() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        await store.archive()
        #expect(ids(store) == ["b"])
        #expect(store.checkedIDs.isEmpty)
        #expect(Set(api.mutatingCalls) == ["modify a + -INBOX", "modify c + -INBOX"])
        await store.undo()
        #expect(ids(store) == ["a", "b", "c"])
        #expect(api.mutatingCalls.filter { $0.hasSuffix("+INBOX -") }.count == 2)
    }

    @Test func bulkPartialFailureRestoresOnlyFailed() async {
        api.update { $0.failingThreads = ["b"] }
        let store = await makeStore()
        store.checkAll()
        await store.archive()
        #expect(ids(store) == ["b"])
        #expect(store.toast == "Toiminto epäonnistui 1 ketjussa (yhteensä 3)")
        await store.undo()                      // undo covers only the two that succeeded
        #expect(ids(store) == ["a", "b", "c"])
    }

    @Test func bulkTrash() async {
        let store = await makeStore()
        store.toggleChecked("b")
        store.toggleChecked("c")
        await store.trash()
        #expect(ids(store) == ["a"])
        #expect(Set(api.mutatingCalls) == ["trash b", "trash c"])
    }

    @Test func bulkStarStarsAllUnlessAllStarred() async {
        api.addThread("s", labels: [GmailLabel.inbox, GmailLabel.starred])
        let store = await makeStore()           // a b c s
        store.toggleChecked("a")
        store.toggleChecked("s")
        await store.toggleStar()
        #expect(store.threads.filter(\.isStarred).map(\.id).sorted() == ["a", "s"])
        await store.toggleStar()                // all starred now -> unstar all
        #expect(store.threads.filter(\.isStarred).isEmpty)
        #expect(store.checkedIDs == ["a", "s"])  // selection stays for star/read toggles
    }

    @Test func bulkMarkReadAndUnread() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("u")
        await store.markUnread()
        #expect(store.threads.filter(\.isUnread).map(\.id).sorted() == ["a", "u"])
        await store.markRead()
        #expect(store.threads.filter(\.isUnread).isEmpty)
    }

    @Test func markReadOnSingleSelection() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        store.highlight(threadID: "u")
        await store.markRead()
        #expect(store.threads[0].isUnread == false)
    }

    @Test func markReadNeverLeavesUnread() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        store.markReadPolicy = .never
        await store.select(threadID: "u")
        #expect(store.threads[0].isUnread)
        #expect(api.mutatingCalls.isEmpty)
    }

    @Test func markReadAfterDelayOnlyIfStillOpen() async {
        api.addThread("u", labels: [GmailLabel.inbox, GmailLabel.unread])
        api.addThread("v", labels: [GmailLabel.inbox, GmailLabel.unread])
        let store = await makeStore(threads: [])
        store.markReadPolicy = .afterDelay
        store.markReadDelay = .milliseconds(20)
        await store.select(threadID: "u")
        #expect(api.mutatingCalls.isEmpty)
        let first = store.pendingRead
        await store.select(threadID: "v")
        await first?.value
        #expect(api.mutatingCalls.isEmpty)
        await store.pendingRead?.value
        #expect(api.mutatingCalls == ["modify v + -UNREAD"])
    }

    @Test func afterArchivePrevious() async {
        let store = await makeStore()
        store.afterArchive = .previous
        await store.select(threadID: "b")
        await store.archive()
        #expect(store.selectedThreadID == "a")
    }

    @Test func afterArchivePreviousAtTopTakesFirst() async {
        let store = await makeStore()
        store.afterArchive = .previous
        await store.select(threadID: "a")
        await store.archive()
        #expect(store.selectedThreadID == "b")
    }

    @Test func afterArchiveListClearsSelection() async {
        let store = await makeStore()
        store.afterArchive = .list
        await store.select(threadID: "b")
        await store.trash()
        #expect(store.selectedThreadID == nil)
        #expect(store.isPeekOpen == false)
    }
}
