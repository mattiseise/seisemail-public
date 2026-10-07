import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeWakerTests {
    let fake = LabelFakeGmail()
    let clock = TestClock(D(1_791_177_300))          // 2026-10-05 05:15Z (08:15 EEST)

    /// The Mac mini daemon's options: the only waker that cleans up (conventions §1 "Siivous"). Every test below
    /// opts in through it unless it is about the client default.
    static let daemon = SnoozeWaker.Options(cleansUp: true)

    func waker(_ options: SnoozeWaker.Options = daemon, scheme: SnoozeLabelScheme = .standard,
               directory: LabelDirectory? = nil) -> SnoozeWaker {
        SnoozeWaker(api: fake, directory: directory ?? LabelDirectory(api: fake), scheme: scheme, options: options, now: clock.closure)
    }

    func count(_ prefix: String) -> Int { fake.calls.filter { $0.hasPrefix(prefix) }.count }

    // MARK: - Rules

    @Test func wakesDueThreadAndCleansLabel() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let report = try await waker().runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2", "label delete Label_2"])
        #expect(report.woken == ["a"])
        #expect(report.cancelled.isEmpty)
        #expect(report.deletedLabelIDs == ["Label_2"])
        #expect(report.failedThreadIDs.isEmpty && report.failedLabelIDs.isEmpty)
        #expect(report.skipped == false)
        #expect(report.listingComplete)
        #expect(report.nextWakeAt == nil)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
    }

    @Test func futureThreadUntouched() async throws {
        fake.addSnoozedThread("b", wake: "20261005T0600Z")
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls.isEmpty)
        #expect(report.woken.isEmpty && report.cancelled.isEmpty)
        #expect(report.nextWakeAt == D(1_791_180_000))
        #expect(fake.labelNames(of: "b") == ["Torkku", "Torkku/20261005T0600Z"])
    }

    @Test func nextWakeAtIsEarliestAmongNotDue() async throws {
        fake.addSnoozedThread("b", wake: "20261005T0700Z")
        fake.addSnoozedThread("c", wake: "20261005T0600Z")
        fake.addSnoozedThread("d", wake: "20261005T0800Z")
        let report = try await waker().runOnce()
        #expect(report.nextWakeAt == D(1_791_180_000))
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func trashedThreadCancelled() async throws {
        fake.addSnoozedThread("c", wake: "20261005T0600Z", extra: ["TRASH"])
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify c + -Label_1,Label_2"])
        #expect(report.cancelled == ["c"])
        #expect(report.woken.isEmpty)
        #expect(report.deletedLabelIDs.isEmpty)
        #expect(fake.labelNames(of: "c") == ["TRASH"])
    }

    @Test func spamThreadCancelledEvenIfDue() async throws {
        fake.addSnoozedThread("s", wake: "20261005T0500Z", extra: ["SPAM"])
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify s + -Label_1,Label_2", "label delete Label_2"])
        #expect(report.cancelled == ["s"])
        #expect(fake.labelNames(of: "s") == ["SPAM"])
    }

    @Test func replyCancelsWithoutUnread() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0600Z")
        fake.addMessage(to: "a", labels: ["INBOX", "UNREAD"])
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify a + -Label_1,Label_2"])
        #expect(report.cancelled == ["a"])
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
    }

    @Test func markerOnlyWakes() async throws {
        fake.addSnoozedThread("d", wake: nil)
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify d +INBOX,UNREAD -Label_1"])
        #expect(report.woken == ["d"])
    }

    @Test func earliestDecidesAndOnlyDueLabelCleaned() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.apply([fake.addLabel("Torkku/20261005T0600Z", visibility: .hidden)], to: "a")
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2,Label_3", "label delete Label_2"])
        #expect(report.woken == ["a"])
        #expect(fake.labelID("Torkku/20261005T0600Z") == "Label_3")
    }

    // MARK: - Races

    @Test func markerGoneBetweenListAndGet() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeThreadLabels = { fake, id, call in
            if call == 1 { fake.strip(["Label_1"], from: id) }
        } }
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["label delete Label_2"])
        #expect(report.woken.isEmpty && report.cancelled.isEmpty && report.failedThreadIDs.isEmpty)
    }

    @Test func labelCreatedAfterPassStartIsRecognised() async throws {
        fake.addSnoozedThread("a", wake: nil)
        fake.updateLabels { $0.beforeThreadLabels = { fake, id, call in
            if call == 1 { fake.apply([fake.addLabel("Torkku/20261005T0700Z", visibility: .hidden)], to: id) }
        } }
        let report = try await waker().runOnce()
        #expect(count("list labels") == 2)
        #expect(fake.mutatingCalls.isEmpty)                               // without the refresh, rule 4 would wake it
        #expect(report.nextWakeAt == D(1_791_183_600))                    // 07:00Z
    }

    @Test func staleRemoveIDRetriesOnce() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { fake, _, call in
            if call == 1 { fake.deleteLabelServerSide("Torkku/20261005T0500Z") }
        } }
        let report = try await waker().runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2", "list labels", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1"])
        #expect(report.woken == ["a"])
        #expect(report.deletedLabelIDs.isEmpty)
        #expect(report.failedThreadIDs.isEmpty)
    }

    @Test func staleRetryFindsMarkerGone() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { fake, id, call in
            // Another waker wakes the thread and cleans the label just before our modify lands.
            guard call == 1 else { return }
            fake.strip(["Label_1"], from: id)
            fake.apply(["INBOX", "UNREAD"], to: id)
            fake.deleteLabelServerSide("Torkku/20261005T0500Z")
        } }
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(report.woken.isEmpty && report.failedThreadIDs.isEmpty)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
    }

    @Test func persistentStaleStatusNotRetriedWhenUnchanged() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { s in
            s.forcedModifyStatus = 400
            // Safety valve: a regressed retry loop ends here instead of hanging the suite.
            s.beforeModify = { fake, _, call in if call >= 6 { fake.updateLabels { $0.forcedModifyStatus = nil } } }
        }
        let report = try await waker().runOnce()
        #expect(count("modify ") == 1)
        #expect(report.failedThreadIDs == ["a"])
        #expect(report.woken.isEmpty)
        #expect(report.deletedLabelIDs == ["Label_2"])                    // the pass still cleans up
    }

    @Test func secondStaleFailureRecordedAfterOneRetry() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { fake, _, call in
            // Each modify loses a label it names: first the time label, then the marker.
            if call == 1 { fake.deleteLabelServerSide("Torkku/20261005T0500Z") }
            if call == 2 { fake.deleteLabelServerSide("Torkku") }
        } }
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2", "modify a +INBOX,UNREAD -Label_1"])
        #expect(report.failedThreadIDs == ["a"])
        #expect(report.woken.isEmpty)
    }

    @Test func staleRetry404TreatedLikeStale() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { s in
            s.unknownLabelStatus = 404
            s.beforeModify = { fake, _, call in if call == 1 { fake.deleteLabelServerSide("Torkku/20261005T0500Z") } }
        }
        let report = try await waker().runOnce()
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2", "modify a +INBOX,UNREAD -Label_1"])
        #expect(report.woken == ["a"])
        #expect(report.failedThreadIDs.isEmpty)
    }

    @Test func threadDeletedBeforeModifySkipped() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { fake, id, _ in fake.update { $0.threads[id] = nil } } }
        let report = try await waker().runOnce()
        // modify 404 → refresh → re-fetch 404 → the thread is gone.
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2", "list labels", "thread labels a",
                               "label delete Label_2"])
        #expect(report.woken.isEmpty && report.failedThreadIDs.isEmpty)
    }

    @Test func failedThreadWokenNextPass() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        fake.update { $0.failingThreads = ["a"] }
        let w = waker()
        let first = try await w.runOnce()
        #expect(first.woken == ["b"])
        #expect(first.failedThreadIDs == ["a"])
        #expect(first.deletedLabelIDs == ["Label_2"])
        #expect(fake.labelNames(of: "a") == ["Torkku"])                   // cleanup stripped the time label
        fake.update { $0.failingThreads = [] }
        let before = fake.mutatingCalls.count
        let second = try await w.runOnce()
        #expect(Array(fake.mutatingCalls.dropFirst(before)) == ["modify a +INBOX,UNREAD -Label_1"])
        #expect(second.woken == ["a"])
        #expect(second.failedThreadIDs.isEmpty)
    }

    @Test func threadGoneSkipped() async throws {
        fake.addSnoozedThread("x", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeThreadLabels = { fake, id, _ in fake.update { $0.threads[id] = nil } } }
        let report = try await waker().runOnce()
        #expect(report.failedThreadIDs.isEmpty)
        #expect(report.woken.isEmpty)
        #expect(fake.mutatingCalls == ["label delete Label_2"])
    }

    @Test func offlineAbortsPass() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeThreadLabels = { fake, _, _ in fake.update { $0.offline = true } } }
        let w = waker()
        await #expect(throws: GmailError.offline) { try await w.runOnce() }
        #expect(fake.mutatingCalls.isEmpty)                               // no cleanup either
    }

    @Test func authErrorAbortsPass() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        fake.updateLabels { $0.threadLabelsError = AuthError.invalidGrant }
        let w = waker()
        await #expect(throws: AuthError.invalidGrant) { try await w.runOnce() }
        #expect(count("thread labels") == 1)
        #expect(fake.mutatingCalls.isEmpty)                               // no cleanup either
    }

    @Test func rateLimitAbortsPass() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        fake.updateLabels { $0.threadLabelsError = GmailError.rateLimited }
        let w = waker()
        await #expect(throws: GmailError.rateLimited) { try await w.runOnce() }
        #expect(count("thread labels") == 1)                              // no GET for b
        #expect(fake.mutatingCalls.isEmpty)                               // no cleanup either
    }

    @Test func cancellationBetweenThreadsAbortsPass() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { _, _, call in if call == 1 { withUnsafeCurrentTask { $0?.cancel() } } } }
        let w = waker()
        let pass = Task { try await w.runOnce() }
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])
    }

    @Test func cancellationBeforeCleanupAbortsPass() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.updateLabels { $0.beforeModify = { _, _, _ in withUnsafeCurrentTask { $0?.cancel() } } }
        let w = waker()
        let pass = Task { try await w.runOnce() }
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(fake.mutatingCalls == ["modify a +INBOX,UNREAD -Label_1,Label_2"])    // no label delete
    }

    @Test func urlSessionCancellationAbortsPass() async {
        // URLSessionTransport reports cancellation as URLError(.cancelled), not CancellationError.
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        fake.updateLabels { s in
            s.urlSessionCancellation = true
            s.beforeThreadLabels = { _, _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let w = waker()
        let pass = Task { try await w.runOnce() }
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(!fake.calls.contains { $0.hasPrefix("label delete") })
    }

    @Test func urlSessionCancellationOnLastThreadWithoutCleanupAbortsPass() async {
        fake.addSnoozedThread("a", wake: nil)                              // no time label: nothing to clean up
        fake.updateLabels { s in
            s.urlSessionCancellation = true
            s.beforeThreadLabels = { _, _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let w = waker()
        let pass = Task { try await w.runOnce() }
        await #expect(throws: CancellationError.self) { try await pass.value }
    }

    @Test func listingFailuresThrow() async {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.update { $0.failing = ["labels"] }
        await #expect(throws: GmailError.http(500, "fail")) { try await waker().runOnce() }
        fake.update { $0.failing = ["listIDs"] }
        await #expect(throws: GmailError.http(500, "fail")) { try await waker().runOnce() }
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func passCanRunAgainAfterThrowing() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.update { $0.failing = ["labels"] }
        let w = waker()
        await #expect(throws: GmailError.http(500, "fail")) { try await w.runOnce() }
        fake.update { $0.failing = [] }
        let report = try await w.runOnce()
        #expect(report.skipped == false)
        #expect(report.woken == ["a"])
    }

    // MARK: - Cleanup

    @Test func noMarkerOnlyListsAndCleans() async throws {
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        let report = try await waker().runOnce()
        #expect(fake.calls == ["list labels", "label delete Label_1"])
        #expect(report.deletedLabelIDs == ["Label_1"])
        #expect(report.listingComplete)
    }

    @Test func eachPassReloadsLabels() async throws {
        // The account had never snoozed when the daemon started; another device then snoozes "a".
        let w = waker()
        let first = try await w.runOnce()
        #expect(first.woken.isEmpty)
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let before = fake.calls.count
        let second = try await w.runOnce()
        #expect(Array(fake.calls.dropFirst(before)).first == "list labels")
        #expect(second.woken == ["a"])
        #expect(second.deletedLabelIDs == ["Label_2"])
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
    }

    @Test func cleanupOnlyValidDueBeyondMargin() async throws {
        for name in ["Torkku/20261005T0400Z", "Torkku/20261005T0512Z", "Torkku/20261005T0600Z", "Torkku/garbage", "Torkku"] {
            fake.addLabel(name, visibility: .hidden)
        }
        let report = try await waker().runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_5 spamTrash -", "label delete Label_1"])
        #expect(report.deletedLabelIDs == ["Label_1"])
    }

    @Test func cleanupMarginOption() async throws {
        fake.addLabel("Torkku/20261005T0512Z", visibility: .hidden)
        let report = try await waker(SnoozeWaker.Options(cleanupMargin: 120, cleansUp: true)).runOnce()
        #expect(report.deletedLabelIDs == ["Label_1"])                    // 05:12 ≤ 05:15 − 2 min
    }

    @Test func cleanupStripsOrphan() async throws {
        let label = fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        fake.base.addThread("o", labels: [label], in: [])
        _ = try await waker().runOnce()
        #expect(fake.labelNames(of: "o").isEmpty)
    }

    @Test func cleanup404CountsAsDeleted() async throws {
        let label = fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        fake.updateLabels { $0.deleteErrors[label] = 404 }
        let report = try await waker().runOnce()
        #expect(report.deletedLabelIDs == ["Label_1"])
        #expect(report.failedLabelIDs.isEmpty)
    }

    @Test func cleanupFailureIsIsolated() async throws {
        let first = fake.addLabel("Torkku/20261005T0300Z", visibility: .hidden)
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        fake.updateLabels { $0.deleteErrors[first] = 500 }
        let report = try await waker().runOnce()
        #expect(report.failedLabelIDs == ["Label_1"])
        #expect(report.deletedLabelIDs == ["Label_2"])
    }

    // MARK: - Cached scan, fresh write path (gmail-quota §10 P1-3)

    @Test func notDueThreadsReadOnceFromCache() async throws {
        fake.addSnoozedThread("b", wake: "20261005T0600Z")
        fake.addSnoozedThread("c", wake: "20261005T0700Z")
        let report = try await waker(SnoozeWaker.Options()).runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached b", "thread labels cached c"])
        #expect(report.nextWakeAt == D(1_791_180_000))
        #expect(fake.mutatingCalls.isEmpty)
    }

    @Test func actsOnlyAfterFreshRead() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let report = try await waker(SnoozeWaker.Options()).runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a",
                               "thread labels a", "modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(report.woken == ["a"])
    }

    @Test func staleCachedDueThreadIsNotWoken() async throws {
        // The cache still holds a due time label that another device has since replaced with a later one.
        fake.addSnoozedThread("a", wake: "20261005T0600Z")                 // Label_1 Torkku, Label_2 in 45 min
        let due = fake.addLabel("Torkku/20261005T0500Z", visibility: .hidden)
        fake.updateLabels { $0.staleCache["a"] = ["Label_1", due] }
        let report = try await waker(SnoozeWaker.Options()).runOnce()
        #expect(fake.calls.filter { $0.hasPrefix("thread labels") } == ["thread labels cached a", "thread labels a"])
        #expect(fake.mutatingCalls.isEmpty)
        #expect(report.woken.isEmpty)
        #expect(report.nextWakeAt == D(1_791_180_000))
    }

    // MARK: - Cleanup gate (only the daemon cleans up)

    @Test func clientDefaultNeverDeletesLabels() async throws {
        #expect(SnoozeWaker.Options().cleansUp == false)
        fake.addSnoozedThread("a", wake: "20261005T0500Z")                 // Label_1 Torkku, Label_2 due 15 min ago
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)        // Label_3: orphan, due 75 min ago
        let report = try await waker(SnoozeWaker.Options()).runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(count("label delete") == 0)
        #expect(report.woken == ["a"])
        #expect(report.deletedLabelIDs.isEmpty && report.failedLabelIDs.isEmpty)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
        #expect(fake.labelID("Torkku/20261005T0500Z") == "Label_2")
        #expect(fake.labelID("Torkku/20261005T0400Z") == "Label_3")
    }

    @Test func clientDefaultWithoutMarkerOnlyLists() async throws {
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        let report = try await waker(SnoozeWaker.Options(pageSize: 2, maxPages: 2, cleanupMargin: 0)).runOnce()
        #expect(fake.calls == ["list labels"])
        #expect(report.deletedLabelIDs.isEmpty && report.failedLabelIDs.isEmpty)
        #expect(fake.labelID("Torkku/20261005T0400Z") == "Label_1")
    }

    @Test func cleansUpKeepsDaemonBehaviour() async throws {
        let options = SnoozeWaker.Options(cleansUp: true)
        #expect(options == SnoozeWaker.Options(pageSize: 500, maxPages: 20, cleanupMargin: 300, cleansUp: true))
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)
        let report = try await waker(options).runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2", "label delete Label_2", "label delete Label_3"])
        #expect(report.woken == ["a"])
        #expect(report.deletedLabelIDs == ["Label_2", "Label_3"])
        #expect(report.failedLabelIDs.isEmpty)
        #expect(fake.labelID("Torkku/20261005T0500Z") == nil)
        #expect(fake.labelID("Torkku/20261005T0400Z") == nil)
    }

    // MARK: - Listing

    @Test func paginationFollowsTokens() async throws {
        for id in ["t1", "t2", "t3", "t4", "t5"] { fake.addSnoozedThread(id, wake: "20261005T0500Z") }
        let report = try await waker(SnoozeWaker.Options(pageSize: 2, cleansUp: true)).runOnce()
        #expect(fake.calls.filter { $0.hasPrefix("list labelIds") } == [
            "list labelIds Label_1 spamTrash -", "list labelIds Label_1 spamTrash 2", "list labelIds Label_1 spamTrash 4",
        ])
        #expect(report.woken == ["t1", "t2", "t3", "t4", "t5"])
        #expect(report.listingComplete)
    }

    @Test func maxPagesBoundsListing() async throws {
        for id in ["t1", "t2", "t3", "t4", "t5"] { fake.addSnoozedThread(id, wake: "20261005T0500Z") }
        let w = waker(SnoozeWaker.Options(pageSize: 2, maxPages: 2, cleansUp: true))
        let first = try await w.runOnce()
        #expect(count("list labelIds") == 2)
        #expect(first.woken == ["t1", "t2", "t3", "t4"])
        #expect(first.listingComplete == false)
        #expect(first.deletedLabelIDs == ["Label_2"])
        let second = try await w.runOnce()
        #expect(second.woken == ["t5"])                                    // rule 4: its time label was cleaned
        #expect(fake.mutatingCalls.last == "modify t5 +INBOX,UNREAD -Label_1")
        #expect(second.listingComplete)
    }

    @Test func secondPassIsNoop() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let w = waker()
        _ = try await w.runOnce()
        let mutating = fake.mutatingCalls
        let second = try await w.runOnce()
        #expect(fake.mutatingCalls == mutating)
        #expect(second.woken.isEmpty && second.cancelled.isEmpty && second.deletedLabelIDs.isEmpty)
    }

    @Test func usesClockForEachPass() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0530Z")
        let w = waker()
        let early = try await w.runOnce()
        #expect(early.woken.isEmpty)
        #expect(early.nextWakeAt == D(1_791_178_200))
        clock.set(D(1_791_178_200))
        let due = try await w.runOnce()
        #expect(due.woken == ["a"])
    }

    // MARK: - Concurrency

    @Test func overlappingPassSkipped() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let gate = Gate()
        fake.updateLabels { $0.threadLabelsGate = gate }
        let w = waker()
        let first = Task { try await w.runOnce() }
        #expect(await gate.waitForArrivals(1))                            // the first pass is mid-way
        let second = try await w.runOnce()
        #expect(second.skipped)
        #expect(second.woken.isEmpty)
        await gate.open()
        let report = try await first.value
        #expect(report.skipped == false)
        #expect(report.woken == ["a"])
        #expect(count("list labels") == 1)
    }

    @Test func concurrentWakersConverge() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let one = waker(directory: LabelDirectory(api: fake))
        let two = waker(directory: LabelDirectory(api: fake))
        async let r1 = one.runOnce()
        async let r2 = two.runOnce()
        let (first, second) = try await (r1, r2)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
        #expect(first.failedThreadIDs.isEmpty && second.failedThreadIDs.isEmpty)
        #expect(first.failedLabelIDs.isEmpty && second.failedLabelIDs.isEmpty)
        #expect(fake.labelID("Torkku/20261005T0500Z") == nil)
    }

    @Test func renamedSchemeIgnoresOtherMarker() async throws {
        let marker = fake.addLabel("Snoozed")
        let time = fake.addLabel("Snooze/20261005T0500Z", visibility: .hidden)
        fake.base.addThread("p", labels: [marker, time], in: [])
        fake.addSnoozedThread("q", wake: "20261005T0500Z")                 // Label_3 Torkku, Label_4 Torkku/…
        let report = try await waker(scheme: SnoozeLabelScheme(marker: "Snoozed", timePrefix: "Snooze/")).runOnce()
        #expect(fake.mutatingCalls == ["modify p +INBOX,UNREAD -Label_1,Label_2", "label delete Label_2"])
        #expect(report.woken == ["p"])
        #expect(fake.labelNames(of: "q") == ["Torkku", "Torkku/20261005T0500Z"])
    }
}
