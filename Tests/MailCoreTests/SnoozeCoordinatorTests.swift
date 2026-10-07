import Foundation
import Testing
@testable import MailCore

@MainActor
final class EmailLog {
    var emails: [String] = []
}

/// The coordinator runs against real time (SnoozeAccount's default clock), so due threads use a past stamp and
/// future threads a far one.
@MainActor
@Suite struct SnoozeCoordinatorTests {
    nonisolated static let due = "20200101T0000Z"
    nonisolated static let future = "20991231T0000Z"
    nonisolated static let futureDate = D(4_102_358_400)                             // 2099-12-31T00:00:00Z
    nonisolated static let email = "maija@example.fi"

    let fake = LabelFakeGmail()
    let sleeper = StepSleeper()

    func makeSession(email: String = Self.email, api: (any GmailAPI)? = nil, views: [MailView]? = nil,
                     start: Bool = true) async -> AccountSession {
        let viewsStore = ViewsConfigStore(fileURL: makeTempDir().appendingPathComponent("views.json"))
        if let views { try? viewsStore.save(views) }
        let session = AccountSession(email: email, auth: nil, api: api ?? fake, viewsStore: viewsStore,
                                     drafts: DraftStore(directory: makeTempDir()))
        if start { await session.store.start() }
        return session
    }

    /// Never opened: the launch grace never runs out unless a test passes its own `graceSleep`.
    let endlessGrace = CallGate()

    func makeCoordinator(wakerEnabled: Bool = true, policy: WakePolicy = WakePolicy(),
                         graceSleep: (@Sendable (Duration) async throws -> Void)? = nil) -> SnoozeCoordinator {
        let endless = endlessGrace
        return SnoozeCoordinator(policy: policy, wakerEnabled: wakerEnabled, sleep: sleeper.closure,
                                 graceSleep: graceSleep ?? { _ in try await endless.pass() })
    }

    func count(_ prefix: String) -> Int { fake.calls.filter { $0.hasPrefix(prefix) }.count }

    /// Gmail puts a woken thread back in the inbox listing when its modify lands.
    func serverListsWokenInInbox() {
        fake.updateLabels { s in
            s.beforeModify = { fake, id, _ in fake.update { $0.lists["in:inbox", default: []].append(id) } }
        }
    }

    /// Lets queued main-actor work (the loop task) run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Launch pass

    @Test func attachRunsLaunchPassAndRefreshes() async throws {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)                         // Label_1 Torkku, Label_2 time
        serverListsWokenInInbox()
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let before = fake.calls.count
        let outcome = await coordinator.attach(session)
        #expect(outcome == .completed(woken: 1, cancelled: 0, nextWakeAt: nil))
        let calls = Array(fake.calls.dropFirst(before))
        #expect(Array(calls.prefix(6)) == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a",
                                           "thread labels a", "modify a +INBOX,UNREAD -Label_1,Label_2", "list in:inbox -"])
        #expect(calls.contains("summary a"))
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 2)  // store.start, then the refresh
        #expect(calls.filter { $0 == "list labels" }.count == 1)          // names come from the refreshed cache
        #expect(session.store.threads.map(\.id) == ["a"])
        let account = try #require(coordinator.account(email: Self.email))
        #expect(account.labels != nil)
        #expect(account.markerID == "Label_1")
        #expect(session.store.countLabelIDs["label:torkku"] == "Label_1")   // P1-4: Torkku's badge by labels.get
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(300)])
    }

    @Test func noRefreshWhenNothingChanged() async {
        let session = await makeSession()
        fake.addSnoozedThread("f", wake: Self.future)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let before = fake.calls.count
        let outcome = await coordinator.attach(session)
        #expect(outcome == .completed(woken: 0, cancelled: 0, nextWakeAt: Self.futureDate))
        let calls = Array(fake.calls.dropFirst(before))
        #expect(calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached f"])
        #expect(fake.mutatingCalls.isEmpty)
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 1)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(300)])
    }

    @Test func cancelledThreadAlsoRefreshes() async {
        let session = await makeSession()
        fake.addSnoozedThread("t", wake: Self.future, extra: ["TRASH"])
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let outcome = await coordinator.attach(session)
        #expect(outcome == .completed(woken: 0, cancelled: 1, nextWakeAt: nil))
        #expect(fake.mutatingCalls == ["modify t + -Label_1,Label_2"])
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 2)
    }

    @Test func plainFakeAttachesNothing() async {
        let plain = FakeGmail()
        let session = await makeSession(api: plain)
        let before = plain.calls.count
        let coordinator = makeCoordinator()
        #expect(await coordinator.attach(session) == nil)
        #expect(coordinator.account(email: Self.email) == nil)
        #expect(coordinator.accounts.isEmpty)
        #expect(plain.calls.count == before)
        await settle()
        #expect(await sleeper.requests.isEmpty)
    }

    @Test func pausedSkipsPass() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let asked = EmailLog()
        coordinator.isPaused = { email in asked.emails.append(email); return true }
        let outcome = await coordinator.attach(session)
        #expect(outcome == .paused)
        #expect(asked.emails == [Self.email])
        #expect(count("list labelIds") == 0)
        #expect(fake.mutatingCalls.isEmpty)
        #expect(coordinator.account(email: Self.email) != nil)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(300)])
        #expect(await coordinator.runPass(email: Self.email) == .paused)
        #expect(count("list labelIds") == 0)
    }

    @Test func wakerDisabledBuildsHolderOnly() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        let coordinator = makeCoordinator(wakerEnabled: false)
        defer { coordinator.detach(email: Self.email) }
        let outcome = await coordinator.attach(session)
        #expect(outcome == nil)
        let account = coordinator.account(email: Self.email)
        #expect(account != nil)
        #expect(account?.markerID == "Label_1")                              // names still load for the rows
        #expect(count("list labelIds") == 0)
        #expect(fake.mutatingCalls.isEmpty)
        await settle()
        #expect(await sleeper.requests.isEmpty)
    }

    @Test func rateLimitedRetriesSooner() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let expired = EmailLog()
        coordinator.onSignInExpired = { expired.emails.append($0) }
        fake.updateLabels { $0.threadLabelsError = GmailError.rateLimited }
        let outcome = await coordinator.attach(session)
        #expect(outcome == .rateLimited)
        #expect(expired.emails.isEmpty)
        #expect(session.store.toast == nil)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(60)])
        // Gmail lets requests through again: the retry wakes the thread, the next pass is 300 s later.
        fake.updateLabels { $0.threadLabelsError = nil }
        #expect(await sleeper.step())
        #expect(await sleeper.waitForRequests(2))
        #expect(await sleeper.requests == [.seconds(60), .seconds(300)])
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])
    }

    @Test func offlineQuietAndSooner() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let expired = EmailLog()
        coordinator.onSignInExpired = { expired.emails.append($0) }
        fake.update { $0.offline = true }
        let outcome = await coordinator.attach(session)
        #expect(outcome == .offline)
        #expect(expired.emails.isEmpty)
        #expect(session.store.toast == nil)
        #expect(coordinator.account(email: Self.email)?.labels == nil)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(60)])
        // Back online: the retry wakes the thread and the next pass is 300 s later.
        fake.update { $0.offline = false }
        #expect(await sleeper.step())
        #expect(await sleeper.waitForRequests(2))
        #expect(await sleeper.requests == [.seconds(60), .seconds(300)])
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(coordinator.account(email: Self.email)?.labels != nil)
    }

    @Test func signInExpiredReported() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        fake.updateLabels { $0.threadLabelsError = AuthError.invalidGrant }
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let expired = EmailLog()
        coordinator.onSignInExpired = { expired.emails.append($0) }
        let outcome = await coordinator.attach(session)
        #expect(outcome == .signInExpired)
        #expect(expired.emails == [Self.email])
        #expect(fake.mutatingCalls.isEmpty)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(300)])
    }

    @Test func otherErrorsAreQuietAndKeepCadence() async {
        let session = await makeSession()
        fake.addSnoozedThread("a", wake: Self.due)
        fake.update { $0.failing = ["listIDs"] }
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let expired = EmailLog()
        coordinator.onSignInExpired = { expired.emails.append($0) }
        #expect(await coordinator.attach(session) == .failed)
        #expect(expired.emails.isEmpty)
        #expect(session.store.toast == nil)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.requests == [.seconds(300)])
    }

    // MARK: - Loop

    @Test func loopRunsAfterSleep() async {
        let session = await makeSession()
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        #expect(await coordinator.attach(session) == .completed(woken: 0, cancelled: 0, nextWakeAt: nil))
        #expect(await sleeper.waitForRequests(1))
        let lists = count("list labels")
        fake.addSnoozedThread("a", wake: Self.due)                         // snoozed elsewhere meanwhile
        serverListsWokenInInbox()
        #expect(await sleeper.step())
        #expect(await sleeper.waitForRequests(2))
        #expect(count("list labels") == lists + 1)
        #expect(await sleeper.requests == [.seconds(300), .seconds(300)])
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 2)
        #expect(session.store.threads.map(\.id) == ["a"])
        #expect(coordinator.account(email: Self.email)?.markerID == "Label_1")
    }

    @Test func runPassRefreshesOnlyWhenChanged() async {
        let session = await makeSession()
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        _ = await coordinator.attach(session)
        #expect(await coordinator.runPass(email: Self.email) == .completed(woken: 0, cancelled: 0, nextWakeAt: nil))
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 1)
        fake.addSnoozedThread("a", wake: Self.due)
        #expect(await coordinator.runPass(email: Self.email) == .completed(woken: 1, cancelled: 0, nextWakeAt: nil))
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 2)
    }

    @Test func runPassUnknownEmailIsCancelled() async {
        let coordinator = makeCoordinator()
        #expect(await coordinator.runPass(email: "nobody@example.fi") == .cancelled)
        #expect(fake.calls.isEmpty)
    }

    // MARK: - Identity

    // MARK: - Sorting labels before the first load (Käsiteltävät)

    @Test func prepareCreatesSortingLabelsBeforeTheFirstLoad() async throws {
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        await coordinator.prepare(session)
        #expect(fake.calls == ["list labels", "label create Lajittelu/Uutiskirjeet", "label create Lajittelu/Ilmoitukset"])
        #expect(fake.visibility(ofLabelNamed: "Lajittelu/Uutiskirjeet") == .shown)
        #expect(fake.visibility(ofLabelNamed: "Lajittelu/Ilmoitukset") == .shown)
        #expect(session.store.missingLabelNames.isEmpty)
        let holder = try #require(coordinator.account(email: Self.email))
        await coordinator.prepare(session)                                   // idempotent
        #expect(fake.calls.count == 3)
        await session.store.start()
        #expect(fake.calls.contains("list \(InboxZero.defaultQuery) -"))
        _ = await coordinator.attach(session)
        #expect(coordinator.account(email: Self.email) === holder)          // attach keeps the prepared holder
        #expect(count("list labels") == 2)                                   // only the wake pass refreshed
        #expect(count("label create") == 2)
    }

    @Test func failedSortingLabelsFallBackToTheInboxUntilAPassCreatesThem() async throws {
        fake.base.addThread("a", in: ["in:inbox"])
        fake.update { $0.failing = ["createLabel"] }
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        await coordinator.prepare(session)
        #expect(session.store.missingLabelNames == [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications])
        await session.store.start()
        #expect(fake.calls.contains("list in:inbox -"))
        #expect(session.store.threads.map(\.id) == ["a"])                   // not "Kaikki käsitelty"
        fake.update { $0.failing = [] }
        _ = await coordinator.attach(session)                                // the launch pass tries again
        #expect(session.store.missingLabelNames.isEmpty)
        #expect(fake.calls.last { $0.hasPrefix("list in:inbox") } == "list \(InboxZero.defaultQuery) -")
        #expect(fake.labelID("Lajittelu/Ilmoitukset") != nil)
    }

    @Test func slowSortingLabelCheckDoesNotHoldTheFirstLoad() async throws {
        fake.base.addThread("a", in: ["in:inbox"])
        let labelsGate = Gate()
        fake.updateLabels { $0.listLabelsGate = labelsGate }
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator(graceSleep: { _ in })              // the launch grace is over at once
        defer { coordinator.detach(email: Self.email) }
        await coordinator.prepare(session)
        #expect(session.store.missingLabelNames == [SeiseLabels.Sorting.newsletters, SeiseLabels.Sorting.notifications])
        await session.store.start()
        #expect(fake.calls.contains("list in:inbox -"))
        #expect(session.store.threads.map(\.id) == ["a"])
        await labelsGate.open()
        await coordinator.labelCheck(email: Self.email)?.value
        #expect(session.store.missingLabelNames.isEmpty)
        #expect(fake.calls.last { $0.hasPrefix("list in:inbox") } == "list \(InboxZero.defaultQuery) -")
        #expect(count("list labels") == 1)
    }

    @Test func aSortingLabelDeletedLaterIsCreatedAgainAfterAPass() async throws {
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        await coordinator.launch(session)
        fake.deleteLabelServerSide("Lajittelu/Ilmoitukset")                  // by hand in Gmail on the web
        #expect(await coordinator.runPass(email: Self.email) == .completed(woken: 0, cancelled: 0, nextWakeAt: nil))
        #expect(fake.labelID("Lajittelu/Ilmoitukset") != nil)
        #expect(count("label create Lajittelu/Ilmoitukset") == 2)
        #expect(session.store.missingLabelNames.isEmpty)
    }

    @Test func aSortingLabelDeletedLaterFallsBackWhenItCannotBeCreated() async throws {
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        await coordinator.launch(session)
        fake.deleteLabelServerSide("Lajittelu/Ilmoitukset")
        fake.update { $0.failing = ["createLabel"] }
        _ = await coordinator.runPass(email: Self.email)
        #expect(session.store.missingLabelNames == [SeiseLabels.Sorting.notifications])
        #expect(fake.calls.last { $0.hasPrefix("list in:inbox") } == "list in:inbox -label:lajittelu-uutiskirjeet -")
    }

    @Test func launchCreatesSortingLabelsBeforeTheFirstListThenAttaches() async throws {
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        await coordinator.launch(session)
        let firstList = try #require(fake.calls.firstIndex { $0.hasPrefix("list in:inbox") })
        let lastCreate = try #require(fake.calls.lastIndex { $0.hasPrefix("label create") })
        #expect(lastCreate < firstList)
        #expect(fake.calls[firstList] == "list \(InboxZero.defaultQuery) -")
        #expect(coordinator.account(email: Self.email) != nil)
        #expect(await coordinator.attach(session) == nil)                    // already attached by the launch
    }

    @Test func launchOfAReplacedSessionOnlyStartsTheStore() async throws {
        let session = await makeSession(views: SeiseViews.defaults, start: false)
        let coordinator = makeCoordinator()
        await coordinator.launch(session, isCurrent: { false })
        #expect(count("list labels") == 0)
        #expect(count("label create") == 0)
        #expect(fake.calls.contains("list \(InboxZero.defaultQuery) -"))
        #expect(coordinator.account(email: Self.email) == nil)
    }

    @Test func deletedMarkerFallsBackToTheSearchCount() async throws {
        fake.addSnoozedThread("f", wake: Self.future)                        // Label_1 Torkku
        let session = await makeSession()
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        _ = await coordinator.attach(session)
        #expect(session.store.countLabelIDs["label:torkku"] == "Label_1")
        fake.deleteLabelServerSide("Torkku")
        _ = await coordinator.runPass(email: Self.email)
        #expect(session.store.countLabelIDs["label:torkku"] == nil)
    }

    @Test func plainFakePrepareDoesNothing() async {
        let plain = FakeGmail()
        let session = await makeSession(api: plain, start: false)
        let coordinator = makeCoordinator()
        await coordinator.prepare(session)
        #expect(plain.calls.isEmpty)
        #expect(session.store.missingLabelNames.isEmpty)
    }

    @Test func sameSessionIsNoop() async {
        let session = await makeSession()
        fake.addSnoozedThread("f", wake: Self.future)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let first = await coordinator.attach(session)
        #expect(first == .completed(woken: 0, cancelled: 0, nextWakeAt: Self.futureDate))
        let holder = coordinator.account(email: Self.email)
        #expect(await coordinator.attach(session) == nil)
        #expect(coordinator.account(email: Self.email) === holder)
        #expect(count("list labelIds") == 1)
        #expect(await sleeper.waitForRequests(1))
        await settle()
        #expect(await sleeper.requests.count == 1)
        #expect(await sleeper.cancellations == 0)
    }

    @Test func newSessionRebuilds() async throws {
        let s1 = await makeSession()
        let s2 = await makeSession()
        fake.addSnoozedThread("f", wake: Self.future)
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        _ = await coordinator.attach(s1)
        let old = try #require(coordinator.account(email: Self.email))
        #expect(await sleeper.waitForRequests(1))
        let outcome = await coordinator.attach(s2)
        #expect(outcome == .completed(woken: 0, cancelled: 0, nextWakeAt: Self.futureDate))
        let new = try #require(coordinator.account(email: Self.email))
        #expect(new !== old)
        #expect(await sleeper.waitForCancellations(1))                       // S1's loop sleep threw
        #expect(await sleeper.waitForRequests(2))
        #expect(await sleeper.pendingCount == 1)                             // only S2's loop is waiting
        let lists = count("list labelIds")
        #expect(await sleeper.step())
        #expect(await sleeper.waitForRequests(3))
        #expect(count("list labelIds") == lists + 1)                         // one loop, one pass
        await settle()
        #expect(await sleeper.requests.count == 3)
    }

    @Test func detachCancelsLoop() async {
        let session = await makeSession()
        let coordinator = makeCoordinator()
        _ = await coordinator.attach(session)
        #expect(await sleeper.waitForRequests(1))
        coordinator.detach(email: Self.email)
        #expect(coordinator.account(email: Self.email) == nil)
        #expect(await sleeper.waitForCancellations(1))
        #expect(await sleeper.pendingCount == 0)
        coordinator.detach(email: "nobody@example.fi")                       // unknown: harmless
        #expect(await coordinator.runPass(email: Self.email) == .cancelled)
    }

    @Test func detachDropsLateResult() async throws {
        let session = await makeSession()
        let coordinator = makeCoordinator()
        _ = await coordinator.attach(session)
        fake.addSnoozedThread("a", wake: Self.due)
        let gate = Gate()
        fake.updateLabels { $0.listLabelsGate = gate }
        let pass = Task { await coordinator.runPass(email: Self.email) }
        #expect(await gate.waitForArrivals(1))                               // the pass is in flight
        coordinator.detach(email: Self.email)
        await gate.open()
        #expect(await pass.value == .cancelled)
        #expect(fake.calls.filter { $0 == "list in:inbox -" }.count == 1)    // no store refresh
        #expect(coordinator.account(email: Self.email) == nil)
    }

    /// A newer session attached while the older one's launch pass runs: one loop, and it is the newer one's.
    @Test func reattachDuringLaunchPassKeepsOneLoop() async throws {
        let s1 = await makeSession()
        let s2 = await makeSession()
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        let gate = Gate()
        fake.updateLabels { $0.listLabelsGate = gate }
        let first = Task { await coordinator.attach(s1) }
        #expect(await gate.waitForArrivals(1))                               // S1's launch pass is held
        fake.updateLabels { $0.listLabelsGate = nil }
        _ = await coordinator.attach(s2)
        let holder = try #require(coordinator.account(email: Self.email))
        await gate.open()
        #expect(await first.value == .cancelled)
        await settle()
        #expect(coordinator.account(email: Self.email) === holder)
        #expect(await sleeper.requests.count == 1)
        #expect(await sleeper.pendingCount == 1)                             // only S2's loop
        coordinator.detach(email: Self.email)
        #expect(await sleeper.waitForCancellations(1))
        #expect(await sleeper.pendingCount == 0)
    }

    /// The holder outlived its session (deallocated without detach): the loop detaches and ends instead of
    /// running empty passes every 5 min.
    @Test func deallocatedSessionDetaches() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        weak var gone: AccountSession?
        do {
            let orphan = await makeSession()
            gone = orphan
            _ = await coordinator.attach(orphan)
        }
        #expect(gone == nil)
        #expect(await sleeper.waitForRequests(1))
        #expect(await sleeper.step())                                        // the loop's next pass
        #expect(await sleeper.waitForCancellations(1))                       // its following sleep was cancelled
        await settle()
        #expect(coordinator.account(email: Self.email) == nil)
        #expect(await sleeper.pendingCount == 0)
        #expect(await coordinator.runPass(email: Self.email) == .cancelled)
    }

    @Test func accountsAreKeyedByLowercasedEmail() async {
        let session = await makeSession(email: "Maija@Example.FI")
        let coordinator = makeCoordinator()
        defer { coordinator.detach(email: Self.email) }
        _ = await coordinator.attach(session)
        #expect(coordinator.account(email: Self.email) != nil)
        #expect(Array(coordinator.accounts.keys) == [Self.email])
    }
}
