import Foundation
import Testing
@testable import MailCore

/// Delivery B: Gmail search hits for rows whose bodies were never fetched. Every list change costs
/// at most one `threads.list` per service (3 × 10 units); nothing else may call the API.
@MainActor
struct MeetingHintsRefreshTests {
    let clock = ManualClock()
    let gmail = FakeGmail()

    func summary(_ id: String, count: Int = 1, snippet: String = "") -> ThreadSummary {
        ThreadSummary(id: id, subject: "Aihe", sender: "X", snippet: snippet, date: .now, labelIDs: [], hasAttachments: false, messageCount: count)
    }

    func thread(_ id: String, _ bodies: [String]) -> MailThread {
        MailThread(id: id, messages: bodies.enumerated().map { MeetingLinkDetectorTests.message("\(id)-\($0.offset)", text: $0.element) })
    }

    func query(_ service: MeetingService, _ scope: String = "in:inbox") -> String {
        MeetingLinkDetector.searchQuery(service: service, scope: scope)
    }

    func listCall(_ service: MeetingService, _ scope: String = "in:inbox") -> String {
        "list \(query(service, scope)) -"
    }

    /// Hints whose 60 s start-up window has already passed.
    func readyHints() -> MeetingHints {
        let hints = MeetingHints(clock: clock)
        clock.advance(by: MeetingHints.startupDelay)
        return hints
    }

    @MainActor final class Done { var value = false }

    /// Runs one refresh attempt to the end: whenever it sleeps (debounce, start-up, spacing,
    /// backoff), moves the clock to its deadline; stops once the attempt has returned.
    func refreshOnce(_ hints: MeetingHints, api: GmailAPI? = nil, query: String? = "in:inbox", _ rows: [ThreadSummary]) async -> MeetingHints.RefreshOutcome {
        let api = api ?? gmail
        let done = Done()
        let task = Task {
            let outcome = await hints.refreshOnce(api: api, query: query, threads: rows)
            done.value = true
            return outcome
        }
        // Waits for the next sleep or the end, however long scheduling takes, instead of treating
        // a short quiet spell as "settled".
        for _ in 0..<10 where !done.value {
            await eventually("next refresh sleep or the end") { clock.sleeperCount > 0 || done.value }
            if done.value { break }
            clock.advanceToNextDeadline()
        }
        return await valueWithin(task)
    }

    // MARK: - Calls

    @Test func listChangeMakesOneSequentialCallPerService() async {
        gmail.update { $0.lists[query(.zoom)] = ["b", "outside"] }
        let hints = readyHints()
        let outcome = await refreshOnce(hints, [summary("a"), summary("b")])
        #expect(outcome == .refreshed)
        #expect(gmail.calls == [listCall(.teams), listCall(.zoom), listCall(.googleMeet)])
        #expect(gmail.state.withLock { $0.listMaxResults } == [500, 500, 500])
        #expect(gmail.state.withLock { $0.maxListsInFlight } == 1)
        #expect(hints.service(for: summary("b")) == .zoom)
        #expect(hints.service(for: summary("a")) == nil)
        // Hits are kept only for rows in the list.
        #expect(hints.searchHitCount == 1)
    }

    @Test func unchangedListMakesNoCalls() async {
        let hints = readyHints()
        let rows = [summary("a"), summary("b")]
        #expect(await refreshOnce(hints, rows) == .refreshed)
        #expect(gmail.calls.count == 3)
        // Same rows, same counts, same scope, in another order: no calls and no debounce wait.
        #expect(await refreshOnce(hints, rows.reversed()) == .unchanged)
        #expect(gmail.calls.count == 3)
    }

    @Test func removingRowsMakesNoCalls() async {
        gmail.update { $0.lists[query(.zoom)] = ["b"] }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a"), summary("b"), summary("c")]) == .refreshed)
        // Archiving rows one by one during triage: the remaining rows' hits are still valid.
        #expect(await refreshOnce(hints, [summary("b"), summary("c")]) == .unchanged)
        #expect(await refreshOnce(hints, [summary("b")]) == .unchanged)
        // Undo brings a row back as it was: still nothing new to search.
        #expect(await refreshOnce(hints, [summary("a"), summary("b")]) == .unchanged)
        #expect(gmail.calls.count == 3)
        #expect(hints.service(for: summary("b")) == .zoom)
    }

    @Test func searchesAtMostOncePerMinute() async {
        let hints = readyHints()
        let firstStart = clock.now + MeetingHints.debounce
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        let next = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a"), summary("b")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: MeetingHints.debounce)
        await eventually("interval sleep") { clock.sleeperCount == 1 }
        #expect(gmail.calls.count == 3)
        clock.advanceToNextDeadline()
        #expect(await valueWithin(next) == .refreshed)
        #expect(clock.now - firstStart == MeetingHints.minInterval)
        #expect(gmail.calls.count == 6)
    }

    @Test(arguments: ["new row", "new message", "new row in another view"])
    func eachKindOfListChangeRefreshes(_ change: String) async {
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        switch change {
        case "new row": #expect(await refreshOnce(hints, [summary("a"), summary("b")]) == .refreshed)
        case "new message": #expect(await refreshOnce(hints, [summary("a", count: 2)]) == .refreshed)
        default: #expect(await refreshOnce(hints, query: "label:Kokoukset", [summary("a"), summary("k")]) == .refreshed)
        }
        #expect(gmail.calls.count == 6)
    }

    @Test func returningToAViewKeepsItsHitsAndMakesNoCalls() async {
        gmail.update { s in
            s.lists[query(.zoom)] = ["a"]
            s.lists[query(.teams, "label:Kokoukset")] = ["k"]
        }
        let hints = readyHints()
        let inbox = [summary("a"), summary("b")]
        #expect(await refreshOnce(hints, inbox) == .refreshed)
        #expect(await refreshOnce(hints, query: "label:Kokoukset", [summary("k")]) == .refreshed)
        // The other view's search does not wipe the inbox rows' hits …
        #expect(hints.service(for: summary("a")) == .zoom)
        #expect(hints.service(for: summary("k")) == .teams)
        // … and coming back to the inbox, or a view showing rows already searched in any view,
        // costs nothing and waits for nothing.
        let before = clock.now
        #expect(await refreshOnce(hints, inbox) == .unchanged)
        #expect(await refreshOnce(hints, query: "subject:x", [summary("k"), summary("a")]) == .unchanged)
        #expect(clock.now == before)
        #expect(gmail.calls.count == 6)
        #expect(hints.service(for: summary("a")) == .zoom)
    }

    @Test func emptyListOrNoScopeMakesNoCalls() async {
        let hints = readyHints()
        #expect(await refreshOnce(hints, []) == .nothingToSearch)
        #expect(await refreshOnce(hints, query: nil, [summary("a")]) == .nothingToSearch)
        #expect(gmail.calls.isEmpty)
    }

    // MARK: - Timing

    @Test func waitsOutTheFirstSixtySecondsAfterStart() async {
        let hints = MeetingHints(clock: clock)
        let task = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce sleep") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("start-up sleep") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(57))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(gmail.calls.isEmpty)
        #expect(clock.now == .seconds(59))
        clock.advance(by: .seconds(1))
        #expect(await valueWithin(task) == .refreshed)
        #expect(gmail.calls.count == 3)
    }

    @Test func debounceCoalescesRapidChanges() async {
        gmail.update { $0.lists[query(.teams)] = ["b"] }
        let hints = readyHints()
        let first = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("first debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        let second = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a"), summary("b")]) }
        await eventually("second debounce") { clock.sleeperCount == 2 }
        clock.advance(by: .seconds(1))
        #expect(await valueWithin(first) == .superseded)
        #expect(gmail.calls.isEmpty)
        clock.advance(by: .seconds(1))
        #expect(await valueWithin(second) == .refreshed)
        #expect(gmail.calls.count == 3)
        #expect(hints.service(for: summary("b")) == .teams)
    }

    @Test func changeDuringFetchStopsItAndWaitsForTheCallInFlight() async {
        let gate = gmail.holdLists()
        let hints = readyHints()
        let first = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("first debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("first call in flight") { gate.parkedCount == 1 }
        let second = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("b")]) }
        await eventually("second debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        gate.open()                                               // the first call answers only now
        // The superseded search's call counts towards the one-minute spacing.
        await eventually("interval sleep") { clock.sleeperCount == 1 }
        clock.advanceToNextDeadline()
        #expect(await valueWithin(first) == .superseded)
        #expect(await valueWithin(second) == .refreshed)
        // The superseded refresh stopped after its call in flight; calls never overlapped.
        #expect(gmail.calls.count == 4)
        #expect(gmail.state.withLock { $0.maxListsInFlight } == 1)
    }

    @Test func cancelledRefreshMakesNoCallsAndCommitsNothing() async {
        let hints = readyHints()
        let task = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        task.cancel()
        #expect(await valueWithin(task) == .superseded)
        #expect(gmail.calls.isEmpty)
        // Not recorded as done: the same list refreshes next time.
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
    }

    @Test func cancellingTheCallerDuringFetchLetsTheSearchFinish() async {
        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        gmail.update { $0.lists = [query(.googleMeet): ["b"]] }
        let gate = gmail.holdLists()
        let task = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a"), summary("b")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("interval sleep") { clock.sleeperCount == 1 }
        clock.advanceToNextDeadline()
        await eventually("call in flight") { gate.parkedCount == 1 && gmail.calls.count == 4 }
        // The view's task goes away (window closed, account switched): the units of the search
        // are being spent anyway, so it finishes and its hits are kept.
        task.cancel()
        gate.open()
        #expect(await valueWithin(task) == .refreshed)
        #expect(gmail.calls.count == 6)
        #expect(hints.service(for: summary("b")) == .googleMeet)
        #expect(hints.service(for: summary("a")) == nil)
    }

    @Test func shrinkingTheListDuringASearchLetsItFinishAndCommit() async {
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a"), summary("y")]) == .refreshed)
        gmail.update { $0.lists[query(.zoom)] = ["x"] }
        let gate = gmail.holdLists()
        // New mail x arrives; its search starts.
        let grown = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a"), summary("y"), summary("x")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("interval sleep") { clock.sleeperCount == 1 }
        clock.advanceToNextDeadline()
        await eventually("call in flight") { gate.parkedCount == 1 && gmail.calls.count == 4 }
        // Matti archives y: the view cancels its task and starts one for the shrunk list.
        grown.cancel()
        let joined = Done()
        let shrunk = Task {
            joined.value = true                                   // runs on into refreshOnce without suspending
            return await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a"), summary("x")])
        }
        let before = clock.now
        // Only once the shrunk list waits on the search does the search's first call answer.
        await eventually("shrunk list started") { joined.value }
        gate.open()
        // The search in flight already covers every row: no new debounce, wait or calls.
        #expect(await valueWithin(shrunk) == .refreshed)
        #expect(await valueWithin(grown) == .refreshed)
        #expect(clock.now == before)
        #expect(clock.sleeperCount == 0)
        #expect(gmail.calls.count == 6)
        #expect(hints.service(for: summary("x")) == .zoom)
        #expect(await refreshOnce(hints, [summary("a"), summary("x")]) == .unchanged)
        #expect(gmail.calls.count == 6)
    }

    // MARK: - Errors

    @Test func quotaTransportRateLimitBacksOff() async {
        // Behind GmailQuotaTransport Gmail's limit arrives as .rateLimited, not as a raw 403/429.
        gmail.update { $0.listError = .rateLimited }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .rateLimited)
        #expect(gmail.calls.count == 1)
    }

    @Test(arguments: [403, 429])
    func rateLimitBacksOffForTwoMinutes(_ status: Int) async {
        gmail.update { $0.listError = .http(status, "Quota exceeded for quota metric 'Queries' … per user") }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .rateLimited)
        // The first call failed: the other two services were not tried.
        #expect(gmail.calls.count == 1)
        let failedAt = clock.now
        gmail.update { $0.listError = nil }

        let retry = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("backoff sleep") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(117))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(gmail.calls.count == 1)
        clock.advance(by: .seconds(1))
        #expect(await valueWithin(retry) == .refreshed)
        #expect(clock.now - failedAt == MeetingHints.backoff)
        #expect(gmail.calls.count == 4)
    }

    @Test func rateLimitDuringASupersededSearchStillBacksOff() async {
        gmail.update { $0.listError = .http(429, "rateLimitExceeded") }
        let gate = gmail.holdLists()
        let hints = readyHints()
        let first = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("first debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        let firstStart = clock.now
        await eventually("first call in flight") { gate.parkedCount == 1 }
        // New mail b arrives while Gmail is still answering 429: the first search is superseded.
        let second = Task { await hints.refreshOnce(api: gmail, query: "in:inbox", threads: [summary("b")]) }
        await eventually("second debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        gate.open()                                               // the 429 arrives only now
        // The quota belongs to the account: the 429 starts the backoff even though its list is gone.
        #expect(await valueWithin(first) == .rateLimited)
        gmail.update { $0.listError = nil }
        await eventually("backoff sleep") { clock.sleeperCount == 1 }
        clock.advanceToNextDeadline()
        #expect(await valueWithin(second) == .refreshed)
        #expect(clock.now - firstStart >= MeetingHints.backoff)
        #expect(gmail.calls.count == 4)
    }

    @Test(arguments: [429, 503])
    func theClientDoesNotRetryTheBackgroundSearch(_ status: Int) async {
        // LiveGmailClient retries 429 and 5xx three times for foreground calls; the badge search
        // relies on its own backoff instead, so one failing attempt is one request (10 units).
        let transport = StubTransport { _ in (status, Data("limit".utf8)) }
        let retries = Counter()
        let live = LiveGmailClient(auth: FakeTokens(), transport: transport,
                                   retry: RetryPolicy(delays: [.milliseconds(500), .seconds(1), .seconds(2)], sleep: { _ in retries.increment() }))
        let hints = readyHints()
        #expect(await refreshOnce(hints, api: live, [summary("a")]) == (status == 429 ? .rateLimited : .failed))
        #expect(transport.requests.count == 1)
        #expect(retries.count == 0)
    }

    @Test func refreshRetriesOnceTheBackoffHasPassed() async {
        gmail.update { $0.listError = .http(429, "rateLimitExceeded") }
        gmail.update { $0.lists[query(.googleMeet)] = ["a"] }
        let hints = readyHints()
        let task = Task { await hints.refresh(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("rate-limited call") { gmail.calls.count == 1 }
        gmail.update { $0.listError = nil }
        await eventually("retry debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await eventually("backoff sleep") { clock.sleeperCount == 1 }
        clock.advance(by: MeetingHints.backoff)
        await valueWithin(task)
        #expect(gmail.calls.count == 4)
        #expect(hints.service(for: summary("a")) == .googleMeet)
    }

    @Test func otherErrorsStopWithoutBackoffOrRetry() async {
        gmail.update { $0.listError = .http(500, "backend") }
        let hints = readyHints()
        let task = Task { await hints.refresh(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        await valueWithin(task)
        #expect(gmail.calls.count == 1)
        // No backoff: the next attempt waits only for the debounce and the one-minute spacing.
        let failedAt = clock.now
        gmail.update { $0.listError = nil }
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        #expect(gmail.calls.count == 4)
        #expect(clock.now - failedAt < MeetingHints.backoff)
    }

    // MARK: - Precedence

    @Test func searchHitBeatsSnippetHint() async {
        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        let hints = readyHints()
        let row = summary("a", snippet: "Liity kokoukseen nyt")
        #expect(hints.service(for: row) == .teams)
        #expect(await refreshOnce(hints, [row]) == .refreshed)
        #expect(hints.service(for: row) == .zoom)
    }

    @Test func bodyResultBeatsSearchHitUntilNewMessage() async {
        gmail.update { $0.lists[query(.teams)] = ["a"] }
        let hints = readyHints()
        let row = summary("a")
        #expect(await refreshOnce(hints, [row]) == .refreshed)
        #expect(hints.service(for: row) == .teams)
        // The body has no join link (the phrase was quoted text): the exact result wins.
        hints.record(thread("a", ["> Join the meeting now – kokous peruttiin"]))
        #expect(hints.service(for: row) == nil)
        // A body with a link wins over a different search hit too.
        hints.record(thread("b", ["https://zoom.us/j/81234567890"]))
        #expect(hints.service(for: summary("b")) == .zoom)
        // A new message makes the body result stale; the search hit counts again.
        #expect(hints.service(for: summary("a", count: 2)) == .teams)
    }

    @Test func firstServiceWinsWhenSeveralMatch() async {
        gmail.update { s in
            s.lists[query(.teams)] = ["a"]
            s.lists[query(.googleMeet)] = ["a"]
        }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        #expect(hints.service(for: summary("a")) == .teams)
    }

    /// A row searched again gets the new result; rows not in that search keep theirs.
    @Test func refreshReplacesOldHits() async {
        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        gmail.update { $0.lists = [:] }
        #expect(await refreshOnce(hints, [summary("a", count: 2)]) == .refreshed)
        #expect(hints.service(for: summary("a", count: 2)) == nil)
    }

    @Test func unchangedHitsDoNotNotifyObservers() async {
        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        let hints = readyHints()
        #expect(await refreshOnce(hints, [summary("a")]) == .refreshed)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = hints.service(for: summary("a")) } onChange: { flag.fired = true }
        #expect(await refreshOnce(hints, [summary("a"), summary("b")]) == .refreshed)
        #expect(!flag.fired)
    }

    // MARK: - Accounts

    @Test func registryKeepsAccountsApart() async {
        let registry = MeetingHintsRegistry(clock: clock)
        let maija = registry.hints(for: "Maija@example.fi")
        #expect(registry.hints(for: "maija@example.fi") === maija)
        let matti = registry.hints(for: "matti@example.fi")
        #expect(matti !== maija)
        clock.advance(by: MeetingHints.startupDelay)

        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        let mattiGmail = FakeGmail()
        #expect(await refreshOnce(maija, api: gmail, [summary("a")]) == .refreshed)
        // The same thread id in the other account has no hit and its own (unchanged) list still
        // costs that account's calls, through its own client.
        #expect(matti.service(for: summary("a")) == nil)
        #expect(await refreshOnce(matti, api: mattiGmail, [summary("a")]) == .refreshed)
        #expect(mattiGmail.calls.count == 3)
        #expect(gmail.calls.count == 3)
        #expect(matti.service(for: summary("a")) == nil)
        #expect(maija.service(for: summary("a")) == .zoom)
    }

    @Test func startUpWindowCountsFromTheRegistryNotFromEachAccount() async {
        let registry = MeetingHintsRegistry(clock: clock)
        _ = registry.hints(for: "matti@example.fi")
        clock.advance(by: .seconds(1_800))
        // The second account is first shown half an hour after start: no 60 s wait for it.
        let later = registry.hints(for: "toinen@example.fi")
        let before = clock.now
        #expect(await refreshOnce(later, [summary("a")]) == .refreshed)
        #expect(clock.now - before == MeetingHints.debounce)
    }

    @Test func switchingAwayCancelsTheOldAccountsRefresh() async {
        let registry = MeetingHintsRegistry(clock: clock)
        let maija = registry.hints(for: "maija@example.fi")
        clock.advance(by: MeetingHints.startupDelay)
        gmail.update { $0.lists[query(.zoom)] = ["a"] }
        // The view's task for Maija's list is cancelled when the active account changes.
        let task = Task { await maija.refresh(api: gmail, query: "in:inbox", threads: [summary("a")]) }
        await eventually("debounce") { clock.sleeperCount == 1 }
        task.cancel()
        await valueWithin(task)
        #expect(gmail.calls.isEmpty)
        #expect(maija.service(for: summary("a")) == nil)
    }
}
