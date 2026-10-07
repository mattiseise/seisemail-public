import Foundation
import Synchronization
import Testing
@testable import DaemonCore
@testable import MailCore

/// D10: shadow is structural. `DaemonGmail` records the writes and performs none; reads pass through; the
/// watermark still advances and every decision is logged.
@Suite struct ShadowModeTests {
    let env: DaemonEnv

    init() throws {
        env = try DaemonEnv()
        try env.writeToken()
        try env.seedState(watermark: "1000")
    }

    var fake: SyncFakeGmail { env.fake }

    func shadowModified(_ thread: String) -> Bool {
        env.shadowWrites.contains { write in
            if case .modify(let t, _, _) = write { return t == thread }
            return false
        }
    }

    @Test func fullReplayWakeAndCleanupInShadowWriteNothing() async throws {
        try env.setConfig(wake: .shadow, sorting: .shadow)
        fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")    // due an hour ago
        fake.labels.addLabel("Torkku/20261005T0700Z", visibility: .hidden) // stale time label
        env.newsletter("t1")
        fake.deliver("t2", from: "GitHub <noreply@github.com>")
        let runner = env.runner()
        _ = await runner.wakeTick()
        try await env.measureSkew(aheadBy: 2)
        _ = await runner.wakeTick()
        _ = await runner.syncTick()
        _ = await runner.syncTick()
        #expect(fake.writes.isEmpty)                                       // no labels.create, modify, delete
        #expect(fake.labelNames(of: "snoozed").contains("Torkku"))
        #expect(fake.labels.labelID("Lajittelu/Uutiskirjeet") == nil)
        #expect(fake.labels.labelID("Lajittelu/Luokiteltu") == nil)
        #expect(fake.historyStarts.count == 2)
        #expect(fake.historyStarts[1] != "1000")                          // W advances in shadow too
        #expect(shadowModified("snoozed"))
        #expect(shadowModified("t1"))
    }

    @Test func shadowDecisionsAreLogged() async throws {
        try env.setConfig(sorting: .shadow)
        fake.deliver("t1", from: "Apple <no_reply@email.apple.com>", subject: "Your receipt from Apple.")
        _ = await env.runner().syncTick()
        let line = try #require(env.decisionLines.first { $0["thread"] as? String == "t1" })
        #expect(line["mode"] as? String == "shadow")
        #expect(line["decision"] as? String == "classify")
        #expect(line["rule"] as? String == "kuitit")
        #expect(line["label"] as? String == "Lajittelu/Kuitit")
        #expect(line["from"] as? String == "no_reply@email.apple.com")
        #expect((line["subject"] as? String)?.hasPrefix("Your receipt") == true)
        #expect(line["at"] is String)
        #expect(posixMode(env.decisionsURL) == 0o600)
    }

    @Test func shadowSorterNeverCreatesRealLabelsWhileWakeIsLive() async throws {
        try env.setConfig(wake: .live, sorting: .shadow)
        fake.labels.addSnoozedThread("snoozed", wake: "20261005T0800Z")
        env.newsletter("t1")
        let runner = env.runner()
        _ = await runner.syncTick()
        _ = await runner.wakeTick()
        #expect(!fake.calls.contains { $0.hasPrefix("label create") })
        #expect(fake.modifies(of: "t1").isEmpty)
        #expect(fake.modifies(of: "snoozed").count == 1)                   // the live waker still wakes
        #expect(fake.labelNames(of: "snoozed").isSuperset(of: ["INBOX", "UNREAD"]))
    }

    @Test func shadowUnmatchedAndPropagationAreLoggedToo() async throws {
        try env.setConfig(sorting: .shadow)
        fake.deliver("t1", from: "Tuntematon <x@example.fi>")
        _ = await env.runner().syncTick()
        let line = try #require(env.decisionLines.first { $0["thread"] as? String == "t1" })
        #expect(line["decision"] as? String == "unmatched")
        #expect(line["mode"] as? String == "shadow")
    }

    @Test func untrustedTextInTheDecisionLogIsSanitised() async throws {
        try env.setConfig(sorting: .shadow)
        let nasty = "Kuitti\u{0007}\u{202E}\u{200B} \"lainaus\" " + String(repeating: "x", count: 300)
        fake.deliver("t1", from: "Kauppa <kauppa@example.fi>", subject: nasty)
        _ = await env.runner().syncTick()
        let line = try #require(env.decisionLines.first { $0["thread"] as? String == "t1" })
        let subject = try #require(line["subject"] as? String)
        #expect(subject.count <= 120)
        #expect(!subject.unicodeScalars.contains { $0.value == 0x07 || $0.value == 0x202E || $0.value == 0x200B })
    }

    // MARK: DaemonGmail

    @Test(arguments: [true, false])
    func sendTrashAndUntrashAreAlwaysForbidden(_ live: Bool) async throws {
        fake.deliver("t1")
        let api = DaemonGmail(fake, mode: live ? .live : .shadow(record: { _ in }))
        await #expect(throws: DaemonError.self) { try await api.send(raw: Data("x".utf8), threadID: nil) }
        await #expect(throws: DaemonError.self) { try await api.trash(threadID: "t1") }
        await #expect(throws: DaemonError.self) { try await api.untrash(threadID: "t1") }
        #expect(fake.calls.isEmpty)
        #expect(fake.attempts == 0)
    }

    @Test func shadowGateRecordsWritesAndPerformsNone() async throws {
        fake.deliver("t1")
        let existing = fake.labels.addLabel("Vanha")
        let recorded = RecordedWrites()
        let api = DaemonGmail(fake, mode: .shadow(record: { recorded.append($0) }))
        try await api.modify(threadID: "t1", add: ["Label_9"], remove: ["INBOX"])
        try await api.batchModify(messageIDs: ["t1-m1", "x"], add: ["STARRED"], remove: [])
        try await api.deleteLabel(id: existing)
        let created = try await api.createLabel(name: "Lajittelu/Kuitit", visibility: .shown)
        _ = try await api.insertMessage(raw: Data("Subject: x\r\n\r\ny".utf8), labelIDs: ["INBOX"])
        #expect(created.id == "SHADOW:Lajittelu/Kuitit")
        #expect(created.name == "Lajittelu/Kuitit")
        #expect(recorded.all == [
            .modify(thread: "t1", add: ["Label_9"], remove: ["INBOX"]), .batchModify(2), .deleteLabel(existing),
            .createLabel("Lajittelu/Kuitit"), .insert,
        ])
        #expect(fake.writes.isEmpty)
        #expect(fake.labelNames(of: "t1") == ["INBOX", "UNREAD"])
        #expect(fake.labels.labelID("Vanha") == existing)
    }

    @Test func shadowGatePassesReadsThrough() async throws {
        fake.deliver("t1")
        let api = DaemonGmail(fake, mode: .shadow(record: { _ in }))
        _ = try await api.listLabels()
        _ = try await api.threadHeaders(id: "t1", headers: ["From"])
        _ = try await api.history(startHistoryID: "1000", pageToken: nil, maxResults: 100)
        _ = try await api.profile()
        #expect(fake.calls == ["list labels", "thread headers t1", "list history 1000 -", "profile"])
    }

    @Test func liveGatePassesWritesThrough() async throws {
        fake.deliver("t1")
        let api = DaemonGmail(fake, mode: .live)
        try await api.modify(threadID: "t1", add: ["STARRED"], remove: [])
        _ = try await api.insertMessage(raw: Data("Subject: x\r\n\r\ny".utf8), labelIDs: ["INBOX"])
        #expect(fake.writes == ["modify t1 +STARRED -", "insert INBOX"])
    }
}

final class RecordedWrites: Sendable {
    private let log = Mutex<[ShadowWrite]>([])
    func append(_ w: ShadowWrite) { log.withLock { $0.append(w) } }
    var all: [ShadowWrite] { log.withLock { $0 } }
}
