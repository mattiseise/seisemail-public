import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeServiceTests {
    let fake: LabelFakeGmail
    let directory: LabelDirectory
    let service: SnoozeService
    let now = D(1_791_018_000)          // Sat 3.10.2026 12:00 EEST
    let until = D(1_791_176_400)        // Mon 5.10.2026 08:00 EEST = Torkku/20261005T0500Z

    init() {
        let fake = LabelFakeGmail()
        self.fake = fake
        directory = LabelDirectory(api: fake)
        service = SnoozeService(api: fake, directory: directory, now: { D(1_791_018_000) })
    }

    var modifyCount: Int { fake.mutatingCalls.filter { $0.hasPrefix("modify ") }.count }

    /// Test 1's setup: thread "a" in the inbox, snoozed with a fresh account (Label_1 = Torkku, Label_2 = time).
    func snoozeFromInbox() async throws -> SnoozeResult {
        fake.base.addThread("a")
        return try await service.snooze(threadID: "a", until: until)
    }

    /// Test 3's setup: "a" snoozed to 5.10 05:00Z elsewhere (Label_1, Label_2), re-snoozed to 6.10 05:00Z (Label_3).
    func resnooze() async throws -> SnoozeResult {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        return try await service.snooze(threadID: "a", until: D(1_791_262_800))
    }

    // MARK: - Snooze

    @Test func firstSnoozeCreatesLabelsThenOneModify() async throws {
        let result = try await snoozeFromInbox()
        #expect(fake.calls == ["thread labels a", "list labels", "label create Torkku",
                               "label create Torkku/20261005T0500Z", "modify a +Label_1,Label_2 -INBOX"])
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
        #expect(fake.visibility(ofLabelNamed: "Torkku") == .shown)
        #expect(fake.visibility(ofLabelNamed: "Torkku/20261005T0500Z") == .hidden)
        #expect(result.threadID == "a")
        #expect(result.wakeAt == until)
        #expect(result.timeLabelName == "Torkku/20261005T0500Z")
        #expect(result.applied == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
        #expect(result.before == SnoozeState(inInbox: true, marked: false, timeLabelNames: []))
    }

    @Test func snoozeServiceReadsFresh() async throws {
        fake.base.addThread("a")
        fake.updateLabels { $0.staleCache["a"] = ["STARRED"] }             // a cached read would miss INBOX
        let result = try await service.snooze(threadID: "a", until: until)
        #expect(result.before.inInbox)
        _ = try await service.undo(result)
        #expect(fake.calls.filter { $0.hasPrefix("thread labels") } == ["thread labels a", "thread labels a"])
        #expect(fake.labelNames(of: "a") == ["INBOX"])
    }

    @Test func wakeTimeRoundedUpToMinute() async throws {
        fake.base.addThread("a")
        let result = try await service.snooze(threadID: "a", until: D(1_791_176_401))
        #expect(result.wakeAt == D(1_791_176_460))
        #expect(result.timeLabelName == "Torkku/20261005T0501Z")
        #expect(fake.mutatingCalls.last == "modify a +Label_1,Label_2 -INBOX")
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0501Z"])
    }

    @Test func secondSnoozeSameTimeReusesLabels() async throws {
        _ = try await snoozeFromInbox()
        fake.base.addThread("b")
        let before = fake.calls.count
        _ = try await service.snooze(threadID: "b", until: until)
        #expect(Array(fake.calls.dropFirst(before)) == ["thread labels b", "modify b +Label_1,Label_2 -INBOX"])
    }

    @Test func resnoozeRemovesOldTimeLabel() async throws {
        let result = try await resnooze()
        #expect(fake.mutatingCalls == ["label create Torkku/20261006T0500Z", "modify a +Label_1,Label_3 -INBOX,Label_2"])
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261006T0500Z"])
        #expect(result.before == SnoozeState(inInbox: false, marked: true, timeLabelNames: ["Torkku/20261005T0500Z"]))
        #expect(result.timeLabelName == "Torkku/20261006T0500Z")
    }

    @Test func resnoozeSameMinuteNoOverlap() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let result = try await service.snooze(threadID: "a", until: until)
        #expect(fake.mutatingCalls == ["modify a +Label_1,Label_2 -INBOX"])
        #expect(Set(result.applied.add).isDisjoint(with: result.applied.remove))
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
    }

    @Test func removesInvalidNamespaceLabel() async throws {
        let garbage = fake.addLabel("Torkku/garbage")
        fake.base.addThread("a", labels: ["INBOX", garbage])
        _ = try await service.snooze(threadID: "a", until: until)
        #expect(fake.mutatingCalls == ["label create Torkku", "label create Torkku/20261005T0500Z",
                                       "modify a +Label_2,Label_3 -INBOX,Label_1"])
    }

    @Test func readStateUntouched() async throws {
        fake.base.addThread("a", labels: ["INBOX", "UNREAD"])
        _ = try await service.snooze(threadID: "a", until: until)
        #expect(fake.mutatingCalls.last == "modify a +Label_1,Label_2 -INBOX")
        #expect(fake.labelNames(of: "a") == ["UNREAD", "Torkku", "Torkku/20261005T0500Z"])
    }

    @Test func otherLabelsUntouched() async throws {
        let receipts = fake.addLabel("Lajittelu/Kuitit")
        fake.base.addThread("a", labels: ["INBOX", "STARRED", receipts])
        _ = try await service.snooze(threadID: "a", until: until)
        #expect(fake.mutatingCalls.last == "modify a +Label_2,Label_3 -INBOX")
        #expect(fake.labelNames(of: "a") == ["STARRED", "Lajittelu/Kuitit", "Torkku", "Torkku/20261005T0500Z"])
    }

    @Test func unknownCurrentLabelTriggersRefresh() async throws {
        _ = try await directory.snapshot()
        let old = fake.addLabel("Torkku/20261004T0500Z", visibility: .hidden)      // another device, after our list
        fake.base.addThread("a", labels: ["INBOX", old])
        _ = try await service.snooze(threadID: "a", until: until)
        #expect(fake.calls == ["list labels", "thread labels a", "list labels", "label create Torkku",
                               "label create Torkku/20261005T0500Z", "modify a +Label_2,Label_3 -INBOX,Label_1"])
    }

    @Test func concurrentSnoozesCreateLabelsOnce() async throws {
        let ids = ["a", "b", "c", "d", "e"]
        for id in ids { fake.base.addThread(id) }
        let service = self.service
        let until = self.until
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = try await service.snooze(threadID: id, until: until) } }
            try await group.waitForAll()
        }
        #expect(fake.calls.filter { $0 == "list labels" }.count == 1)
        #expect(fake.mutatingCalls.count == 7)
        #expect(Set(fake.mutatingCalls) == Set(["label create Torkku", "label create Torkku/20261005T0500Z"]
                                               + ids.map { "modify \($0) +Label_1,Label_2 -INBOX" }))
    }

    // MARK: - Stale label IDs (conventions §0)

    @Test func retriesOnceAfterLabelDeletedElsewhere() async throws {
        fake.base.addThread("z")
        _ = try await service.snooze(threadID: "z", until: until)          // cache now holds Label_1, Label_2
        fake.base.addThread("a")
        fake.deleteLabelServerSide("Torkku/20261005T0500Z")                 // e.g. another device's cleanup
        let before = fake.calls.count
        let result = try await service.snooze(threadID: "a", until: until)
        #expect(Array(fake.calls.dropFirst(before)) == [
            "thread labels a",
            "modify a +Label_1,Label_2 -INBOX",                             // 400: Label_2 is gone
            "list labels",
            "thread labels a",
            "label create Torkku/20261005T0500Z",
            "modify a +Label_1,Label_3 -INBOX",
        ])
        #expect(result.applied == LabelChange(add: ["Label_1", "Label_3"], remove: ["INBOX"]))
        #expect(result.before == SnoozeState(inInbox: true, marked: false, timeLabelNames: []))
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
    }

    @Test func persistent400NotRetriedWhenUnchanged() async {
        fake.base.addThread("a")
        fake.updateLabels { $0.forcedModifyStatus = 400 }
        await #expect(throws: GmailError.http(400, "forced")) { try await service.snooze(threadID: "a", until: until) }
        #expect(fake.mutatingCalls == ["label create Torkku", "label create Torkku/20261005T0500Z",
                                       "modify a +Label_1,Label_2 -INBOX"])
        #expect(fake.labelNames(of: "a") == ["INBOX"])
    }

    @Test func persistent404NotRetriedWhenUnchanged() async {
        fake.base.addThread("a")
        fake.updateLabels { $0.forcedModifyStatus = 404 }
        await #expect(throws: GmailError.http(404, "forced")) { try await service.snooze(threadID: "a", until: until) }
        #expect(modifyCount == 1)
        // 404 takes the stale-ID path too: refresh and re-fetch, then stop because the change is unchanged.
        #expect(Array(fake.calls.suffix(2)) == ["list labels", "thread labels a"])
        #expect(fake.calls.filter { $0 == "list labels" }.count == 2)
    }

    @Test func retriesOnceAfterLabelDeletedElsewhere404() async throws {
        fake.updateLabels { $0.unknownLabelStatus = 404 }
        fake.base.addThread("z")
        _ = try await service.snooze(threadID: "z", until: until)
        fake.base.addThread("a")
        fake.deleteLabelServerSide("Torkku/20261005T0500Z")
        let before = fake.calls.count
        let result = try await service.snooze(threadID: "a", until: until)
        #expect(Array(fake.calls.dropFirst(before)) == [
            "thread labels a",
            "modify a +Label_1,Label_2 -INBOX",                             // 404: Label_2 is gone
            "list labels",
            "thread labels a",
            "label create Torkku/20261005T0500Z",
            "modify a +Label_1,Label_3 -INBOX",
        ])
        #expect(result.applied == LabelChange(add: ["Label_1", "Label_3"], remove: ["INBOX"]))
    }

    @Test func secondStaleFailurePropagates() async {
        fake.base.addThread("a")
        fake.updateLabels { $0.beforeModify = { fake, _, _ in fake.deleteLabelServerSide("Torkku/20261005T0500Z") } }
        await #expect(throws: GmailError.http(400, "Invalid label: Label_3")) {
            try await service.snooze(threadID: "a", until: until)
        }
        #expect(fake.mutatingCalls == [
            "label create Torkku",
            "label create Torkku/20261005T0500Z",
            "modify a +Label_1,Label_2 -INBOX",
            "label create Torkku/20261005T0500Z",
            "modify a +Label_1,Label_3 -INBOX",
        ])
    }

    @Test func serverErrorNotRetriedByService() async {
        fake.base.addThread("a")
        fake.update { $0.failing = ["modify"] }
        await #expect(throws: GmailError.http(500, "fail")) { try await service.snooze(threadID: "a", until: until) }
        #expect(modifyCount == 1)
        #expect(fake.calls.filter { $0 == "list labels" }.count == 1)
    }

    @Test func threadDeletedBeforeModifyPropagates404() async {
        fake.base.addThread("a")
        fake.updateLabels { $0.beforeModify = { fake, id, _ in fake.update { $0.threads[id] = nil } } }
        await #expect(throws: GmailError.http(404, "a")) { try await service.snooze(threadID: "a", until: until) }
        #expect(Array(fake.calls.suffix(3)) == ["modify a +Label_1,Label_2 -INBOX", "list labels", "thread labels a"])
    }

    @Test func missingThreadPropagates404() async {
        await #expect(throws: GmailError.http(404, "x")) { try await service.snooze(threadID: "x", until: until) }
        #expect(fake.calls == ["thread labels x"])
    }

    // MARK: - Validation

    @Test func pastAndNowRejectedWithoutCalls() async {
        await #expect(throws: SnoozeError.wakeTimeNotInFuture) { try await service.snooze(threadID: "a", until: D(1_791_017_940)) }
        await #expect(throws: SnoozeError.wakeTimeNotInFuture) { try await service.snooze(threadID: "a", until: now) }
        #expect(throws: SnoozeError.wakeTimeNotInFuture) { try service.validatedWakeDate(D(1_791_017_999.5)) }
        #expect(fake.calls.isEmpty)
    }

    @Test func oneSecondAheadRoundsUp() throws {
        #expect(try service.validatedWakeDate(D(1_791_018_001)) == D(1_791_018_060))
        #expect(try service.validatedWakeDate(D(1_791_018_060)) == D(1_791_018_060))
        #expect(try SnoozeTime.encode(service.validatedWakeDate(D(1_791_018_001))) == "20261003T0901Z")
    }

    @Test func outOfRangeRejected() throws {
        #expect(throws: SnoozeError.wakeTimeOutOfRange) { try service.validatedWakeDate(D(253_402_300_800)) }
        #expect(throws: SnoozeError.wakeTimeOutOfRange) { try service.validatedWakeDate(D(253_402_300_740.5)) }
        #expect(try service.validatedWakeDate(D(253_402_300_740)) == SnoozeTime.latest)
    }

    // MARK: - Undo

    @Test func undoFromInbox() async throws {
        let result = try await snoozeFromInbox()
        let reverted = try await service.undo(result)
        #expect(reverted == LabelChange(add: ["INBOX"], remove: ["Label_1", "Label_2"]))
        #expect(fake.mutatingCalls.last == "modify a +INBOX -Label_1,Label_2")
        #expect(fake.labelNames(of: "a") == ["INBOX"])
    }

    @Test func undoResnoozeRecreatesCleanedLabel() async throws {
        // Warm cache: the service still believes Label_2 exists, so the first modify hits the stale-ID path.
        let result = try await resnooze()
        fake.deleteLabelServerSide("Torkku/20261005T0500Z")
        let before = fake.calls.count
        let reverted = try await service.undo(result)
        #expect(Array(fake.calls.dropFirst(before)) == [
            "thread labels a",
            "modify a +Label_2 -Label_3",
            "list labels",
            "thread labels a",
            "label create Torkku/20261005T0500Z",
            "modify a +Label_4 -Label_3",
        ])
        #expect(reverted == LabelChange(add: ["Label_4"], remove: ["Label_3"]))
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
        #expect(fake.visibility(ofLabelNamed: "Torkku/20261005T0500Z") == .hidden)
    }

    @Test func undoRecreatesCleanedLabelWithFreshCache() async throws {
        let result = try await resnooze()
        fake.deleteLabelServerSide("Torkku/20261005T0500Z")
        _ = try await directory.refresh()
        let before = fake.mutatingCalls.count
        let reverted = try await service.undo(result)
        #expect(Array(fake.mutatingCalls.dropFirst(before)) == ["label create Torkku/20261005T0500Z", "modify a +Label_4 -Label_3"])
        #expect(reverted == LabelChange(add: ["Label_4"], remove: ["Label_3"]))
        #expect(fake.labelNames(of: "a") == ["Torkku", "Torkku/20261005T0500Z"])
    }

    @Test func undoAfterWakeIsNoop() async throws {
        let result = try await snoozeFromInbox()
        fake.strip(["Label_1", "Label_2"], from: "a")                     // a waker got there first
        fake.apply(["INBOX", "UNREAD"], to: "a")
        let before = fake.mutatingCalls
        let reverted = try await service.undo(result)
        #expect(reverted.isEmpty)
        #expect(fake.mutatingCalls == before)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
    }

    @Test func undoNeverRemovesInboxFromReply() async throws {
        fake.base.addThread("a", labels: ["STARRED"])                      // archived thread
        let result = try await service.snooze(threadID: "a", until: until)
        #expect(result.before == SnoozeState(inInbox: false, marked: false, timeLabelNames: []))
        fake.addMessage(to: "a", labels: ["INBOX", "UNREAD"])             // reply arrives before undo
        let reverted = try await service.undo(result)
        #expect(reverted == LabelChange(add: [], remove: ["Label_1", "Label_2"]))
        #expect(fake.labelNames(of: "a") == ["STARRED", "INBOX", "UNREAD"])
    }

    @Test func undoPersistentStaleStatusNotRetriedWhenUnchanged() async throws {
        let result = try await snoozeFromInbox()
        fake.updateLabels { s in
            s.forcedModifyStatus = 400
            // Safety valve: a regressed retry loop ends here instead of hanging the suite.
            s.beforeModify = { fake, _, call in if call >= 8 { fake.updateLabels { $0.forcedModifyStatus = nil } } }
        }
        await #expect(throws: GmailError.http(400, "forced")) { try await service.undo(result) }
        #expect(modifyCount == 2)                                          // the snooze, then one undo attempt
    }

    @Test func undoSecondStaleFailurePropagates() async throws {
        let result = try await resnooze()                                   // modify call 1
        fake.updateLabels { $0.beforeModify = { fake, _, call in
            // Every undo modify loses the time label it restores; bounded so a regression cannot hang.
            if call <= 10 { fake.deleteLabelServerSide("Torkku/20261005T0500Z") }
        } }
        await #expect(throws: GmailError.http(400, "Invalid label: Label_4")) { try await service.undo(result) }
        #expect(Array(fake.mutatingCalls.filter { $0.hasPrefix("modify ") }.dropFirst()) == [
            "modify a +Label_2 -Label_3", "modify a +Label_4 -Label_3",
        ])
    }

    // MARK: - Failures

    @Test func offlineThrows() async {
        fake.base.addThread("a")
        fake.update { $0.offline = true }
        await #expect(throws: GmailError.offline) { try await service.snooze(threadID: "a", until: until) }
        #expect(fake.mutatingCalls.isEmpty)
        #expect(fake.calls == ["thread labels a"])
    }

    @Test func reservedMarkerSurfaces() async {
        fake.base.addThread("a")
        fake.updateLabels { $0.createErrors["torkku"] = 400 }
        await #expect(throws: LabelDirectoryError.createRejected(name: "Torkku", status: 400)) {
            try await service.snooze(threadID: "a", until: until)
        }
        #expect(fake.mutatingCalls == ["label create Torkku"])
        #expect(fake.labelNames(of: "a") == ["INBOX"])
    }
}
