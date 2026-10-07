import Foundation
import Testing
@testable import MailCore

/// Fork (seisemail): the thread list header's tri-state select-all control.
@MainActor
@Suite struct MailStoreSelectAllTests {
    let api = FakeGmail()
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    func makeStore(threads: [String] = ["a", "b", "c"], pageSize: Int = 50) async -> MailStore {
        for id in threads { api.addThread(id) }
        let store = MailStore(api: api, viewsStore: viewsStore, pageSize: pageSize)
        await store.start()
        return store
    }

    func removeFromInbox(_ id: String) {
        api.update { $0.lists["in:inbox"]?.removeAll { $0 == id } }
    }

    // MARK: - checkState

    @Test func emptyListIsUnchecked() async {
        let store = await makeStore(threads: [])
        #expect(store.threads.isEmpty)
        #expect(store.checkState == .unchecked)
    }

    @Test func nothingCheckedIsUnchecked() async {
        let store = await makeStore()
        #expect(store.checkState == .unchecked)
    }

    @Test func someCheckedIsPartial() async {
        let store = await makeStore()
        store.toggleChecked("b")
        #expect(store.checkState == .partial)
        store.toggleChecked("a")
        #expect(store.checkState == .partial)
    }

    @Test func everyLoadedThreadCheckedIsAll() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("b")
        store.toggleChecked("c")
        #expect(store.checkState == .all)
    }

    @Test func checkAllIsAllAndClearIsUnchecked() async {
        let store = await makeStore()
        store.checkAll()
        #expect(store.checkState == .all)
        store.clearChecked()
        #expect(store.checkState == .unchecked)
    }

    @Test func singleThreadCheckedIsAll() async {
        let store = await makeStore(threads: ["a"])
        store.toggleChecked("a")
        #expect(store.checkState == .all)
    }

    @Test func loadMoreAddsUncheckedRowsSoAllBecomesPartial() async {
        let store = await makeStore(pageSize: 2)
        #expect(store.threads.map(\.id) == ["a", "b"])
        store.checkAll()
        #expect(store.checkState == .all)
        await store.loadMore()
        #expect(store.threads.map(\.id) == ["a", "b", "c"])
        #expect(store.checkedIDs == ["a", "b"])
        #expect(store.checkState == .partial)
    }

    @Test func refreshDroppingTheOnlyCheckedThreadIsUnchecked() async {
        let store = await makeStore()
        store.toggleChecked("b")
        removeFromInbox("b")
        await store.refresh()
        #expect(store.threads.map(\.id) == ["a", "c"])
        #expect(store.checkedIDs.isEmpty)
        #expect(store.checkState == .unchecked)
    }

    @Test func refreshDroppingAnUncheckedThreadCanMakePartialAll() async {
        let store = await makeStore()
        store.toggleChecked("a")
        store.toggleChecked("c")
        #expect(store.checkState == .partial)
        removeFromInbox("b")
        await store.refresh()
        #expect(store.threads.map(\.id) == ["a", "c"])
        #expect(store.checkState == .all)
    }

    @Test func refreshDroppingACheckedThreadKeepsAll() async {
        let store = await makeStore()
        store.checkAll()
        removeFromInbox("b")
        await store.refresh()
        #expect(store.checkedIDs == ["a", "c"])
        #expect(store.checkState == .all)
    }

    @Test func refreshBringingNewMailMakesAllPartial() async {
        let store = await makeStore()
        store.checkAll()
        api.update { $0.lists["in:inbox"]?.insert("n", at: 0) }
        api.addThread("n", in: [])
        await store.refresh()
        #expect(store.threads.map(\.id) == ["n", "a", "b", "c"])
        #expect(store.checkState == .partial)
    }

    @Test func bulkArchiveOfAllLeavesEmptyListUnchecked() async {
        let store = await makeStore()
        store.checkAll()
        await store.archive()
        #expect(store.threads.isEmpty)
        #expect(store.checkState == .unchecked)
    }

    // MARK: - toggleCheckAll

    @Test func toggleFromUncheckedChecksAll() async {
        let store = await makeStore()
        store.toggleCheckAll()
        #expect(store.checkedIDs == ["a", "b", "c"])
        #expect(store.checkState == .all)
    }

    @Test func toggleFromPartialChecksAll() async {
        let store = await makeStore()
        store.toggleChecked("b")
        store.toggleCheckAll()
        #expect(store.checkedIDs == ["a", "b", "c"])
        #expect(store.checkState == .all)
    }

    @Test func toggleFromAllClears() async {
        let store = await makeStore()
        store.checkAll()
        store.toggleCheckAll()
        #expect(store.checkedIDs.isEmpty)
        #expect(store.checkState == .unchecked)
    }

    @Test func toggleTwiceRoundTrips() async {
        let store = await makeStore()
        store.toggleCheckAll()
        store.toggleCheckAll()
        #expect(store.checkedIDs.isEmpty)
    }

    @Test func toggleOnEmptyListDoesNothing() async {
        let store = await makeStore(threads: [])
        api.addThread("x", in: [])                  // openable, but not in the (empty) list
        await store.select(threadID: "x")
        #expect(store.threads.isEmpty)
        #expect(store.isPeekOpen)
        store.toggleCheckAll()
        #expect(store.isPeekOpen)                   // checkAll() would have closed it
        #expect(store.checkedIDs.isEmpty)
        #expect(store.checkState == .unchecked)
    }

    @Test func toggleAfterLoadMoreChecksTheNewRowsToo() async {
        let store = await makeStore(pageSize: 2)
        store.checkAll()
        await store.loadMore()
        #expect(store.checkState == .partial)
        store.toggleCheckAll()
        #expect(store.checkedIDs == ["a", "b", "c"])
    }

    @Test func toggleChecksAllAndClosesPeekLikeCommandA() async {
        let store = await makeStore()
        await store.select(threadID: "a")
        #expect(store.isPeekOpen)
        store.toggleCheckAll()
        #expect(store.isPeekOpen == false)
        #expect(store.checkState == .all)
    }

    @Test func toggleMakesNoServerCalls() async {
        let store = await makeStore()
        store.toggleCheckAll()
        store.toggleCheckAll()
        #expect(api.mutatingCalls.isEmpty)
    }
}
