import Foundation
import Testing
@testable import MailCore

/// The whole stack under the store: FakeGmailServer → QuotaSimulatingTransport (Gmail's
/// 15,000-unit window) → quota transport → read cache → LiveGmailClient → MailStore.
@MainActor
@Suite struct MailStoreQuotaTests {
    let clock = SkipAheadQuotaClock()
    let server = FakeGmailServer()
    let gmail: QuotaSimulatingTransport
    let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))

    init() throws {
        gmail = try QuotaSimulatingTransport(base: server, clock: clock)
    }

    func ids(_ n: Int, from start: Int = 0) -> [String] { (start..<start + n).map { String(format: "t%04d", $0) } }

    func client(fixed: Bool) -> LiveGmailClient {
        let transport: any HTTPTransport = fixed ? GmailTransports.make(base: gmail, policy: .macApp, clock: clock) : gmail
        return LiveGmailClient(auth: FakeTokens(), transport: transport, retry: RetryPolicy(delays: [], sleep: { _ in }))
    }

    func store(fixed: Bool, threads: Int) async -> (MailStore, LiveGmailClient) {
        server.add(ids(threads))
        let api = client(fixed: fixed)
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        return (store, api)
    }

    /// Matti's incident at 15,000: eight cold pages in a minute, then archive three rows.
    func incidentWorkload(_ store: MailStore) async {
        for _ in 0..<7 { await store.loadMore() }
        for id in store.threads.prefix(3).map(\.id) { store.toggleChecked(id) }
        await store.archive()
    }

    @Test func incidentReplayWithoutFixFails() async {
        let (store, _) = await store(fixed: false, threads: 400)
        await incidentWorkload(store)
        #expect(gmail.rejected > 0)
        #expect(store.toast == "Viestien lataus epäonnistui" || store.toast?.hasPrefix("Toiminto epäonnistui") == true)
    }

    @Test func incidentReplayWithFixSucceeds() async {
        let (store, _) = await store(fixed: true, threads: 400)
        await incidentWorkload(store)
        #expect(store.toast == nil)
        #expect(gmail.rejected == 0)
        #expect(gmail.peakWindow <= GmailQuotaPolicy.macApp.ceiling)
        #expect(store.threads.count == 397)
        #expect(server.thread("t0000")?.labels.contains(GmailLabel.inbox) == false)
    }

    @Test func bulkCleanupReplay() async {
        let (store, _) = await store(fixed: true, threads: 250)
        for _ in 0..<4 {
            store.checkAll()
            await store.archive()
            await store.refresh()
        }
        #expect(store.toast == nil)
        #expect(gmail.rejected == 0)
        #expect(server.calls.filter { $0.hasPrefix("POST") }.count >= 4)
        let archived = ids(200).filter { server.thread($0)?.labels.contains(GmailLabel.inbox) == false }
        #expect(archived.count == 200)
        #expect(store.threads.map(\.id) == ids(50, from: 200))
    }

    @Test func otherClientExhaustedArchiveStillSucceeds() async {
        let (store, _) = await store(fixed: true, threads: 3)
        gmail.prefill(GmailQuotaPolicy.macApp.perUserLimit)
        await store.select(threadID: "t0000")
        await store.archive()
        #expect(store.threads.map(\.id) == ["t0001", "t0002"])
        #expect(store.toast == nil)
        #expect(gmail.rejected > 0)
        #expect(server.thread("t0000")?.labels.contains(GmailLabel.inbox) == false)
    }

    @Test func idleRefreshSendsNoThreadGets() async {
        let (store, api) = await store(fixed: true, threads: 50)
        let monitor = InboxMonitor(api: api)
        _ = await monitor.check(me: server.me)
        server.resetCalls()
        let before = gmail.windowUnits()
        await store.refresh()
        _ = await monitor.check(me: server.me)
        #expect(server.threadGets.isEmpty)
        // list 10 + counts (labels/INBOX 1 + two lists 20 + labels/STARRED 1) + monitor (list 10 + labels 1)
        #expect(gmail.windowUnits() - before == 43)
    }

    @Test func refreshAfterBulkActionRefetchesOnlyTouchedRows() async {
        let (store, _) = await store(fixed: true, threads: 50)
        for id in ids(5) { store.toggleChecked(id) }
        await store.markRead()
        #expect(server.calls.contains("POST messages/batchModify"))
        server.resetCalls()
        let before = gmail.windowUnits()
        await store.refresh()
        #expect(Set(server.threadGets) == Set(ids(5).map { "GET threads/\($0)" }))
        #expect(gmail.windowUnits() - before == 32 + 5 * 40)              // as above, without the monitor
    }

    @Test func smallBulkActionUsesThreadsModify() async {
        let (store, _) = await store(fixed: true, threads: 10)
        for id in ids(2) { store.toggleChecked(id) }
        await store.toggleStar()
        let posts = server.calls.filter { $0.hasPrefix("POST") }
        #expect(Set(posts) == ["POST threads/t0000/modify", "POST threads/t0001/modify"])
    }

    @Test func oneNewMessageCostsOneThreadGet() async {
        let (store, _) = await store(fixed: true, threads: 50)
        server.reply(to: "t0007")
        server.resetCalls()
        await store.refresh()
        #expect(server.threadGets == ["GET threads/t0007"])
        #expect(store.threads.first?.id == "t0007")
    }

    @Test func rateLimitedArchiveShowsQuotaToastAndRestoresRow() async {
        let (store, _) = await store(fixed: true, threads: 3)
        gmail.setRejectAll(true)
        await store.select(threadID: "t0001")
        await store.archive()
        #expect(store.threads.map(\.id) == ["t0000", "t0001", "t0002"])
        #expect(store.toast == "Arkistointi epäonnistui. Gmail rajoittaa pyyntöjä. Yritä uudelleen minuutin päästä.")
        #expect(store.isOffline == false)
        #expect(store.needsSignIn == false)
        #expect(clock.now >= .seconds(60))
    }

    /// Once Gmail keeps refusing past one request's deadline, the rest of a bulk job is not
    /// started with fresh 90 s waits: it ends within about one deadline and the rows come back.
    @Test func sustainedRateLimitEndsBulkTrashWithinOneDeadline() async throws {
        let (store, api) = await store(fixed: true, threads: 50)
        let cache = try #require(api.transport as? GmailReadCacheTransport)
        let scheduler = try #require(cache.base as? GmailQuotaTransport).scheduler
        gmail.setRejectAll(true)
        let start = clock.now
        // All ten concurrent trashes take their deadline at `start`, however late the OS runs one.
        let time = clock.holdTime()
        store.checkAll()
        let trashing = Task { await store.trash() }
        #expect(await eventually { let s = await scheduler.snapshot; return s.queued + s.inFlight == 10 })
        time.open()
        await trashing.value
        #expect(clock.now - start <= .seconds(120))
        #expect(store.toast == "Toiminto epäonnistui kaikissa 50 ketjussa")
        #expect(store.threads.map(\.id) == ids(50))
        #expect(store.bulkStatuses.isEmpty)
    }

    @Test func permission403KeepsPlainToast() async throws {
        let (store, _) = await store(fixed: true, threads: 3)
        server.override("POST threads/", status: 403, body: try Fixture.data("gmail_403_insufficient_permissions"))
        await store.select(threadID: "t0001")
        await store.archive()
        #expect(store.toast == "Arkistointi epäonnistui")
        #expect(gmail.rejected == 0)
        #expect(server.calls.filter { $0.hasPrefix("POST") }.count == 1)
    }

    @Test func countsKeepPreviousValueOnFailure() async {
        let api = FakeGmail()
        api.update { $0.inboxUnread = 4; $0.estimates["is:starred"] = 2 }
        let store = MailStore(api: api, viewsStore: viewsStore)
        await store.start()
        let inbox = store.views[0].id
        let starred = store.views[3].id
        #expect(store.unreadCounts[inbox] == 4)
        api.update { $0.failing.insert("count") }
        await store.refreshCounts()
        #expect(store.unreadCounts[inbox] == 4)
        #expect(store.unreadCounts[starred] == 2)
    }
}
