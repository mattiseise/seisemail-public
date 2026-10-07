import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct SnoozeAccountTests {
    let fake = LabelFakeGmail()
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00

    func makeAccount(now: Date? = nil) throws -> SnoozeAccount {
        let instant = now ?? N
        let clock: @Sendable () -> Date = { instant }
        return try #require(SnoozeAccount(api: fake, now: clock))
    }

    func count(_ call: String) -> Int { fake.calls.filter { $0 == call }.count }

    @Test func plainFakeHasNone() {
        #expect(SnoozeAccount(api: FakeGmail()) == nil)
    }

    /// gmail-quota.md §10 P1-6: the quota/cache stack every account session uses keeps the label
    /// endpoints, so snooze stays available behind it.
    @Test func liveStackHasOne() {
        #expect(SnoozeAccount(api: LiveGmailClient(auth: FakeTokens(), transport: GmailTransports.live())) != nil)
    }

    @Test func labelsAPIHasOne() throws {
        let account = try makeAccount()
        #expect(account.scheme == .standard)
        #expect(account.labels == nil)
        #expect(account.markerID == nil)
        #expect(fake.calls.isEmpty)                                          // building it costs no request
    }

    @Test func sharesOneDirectory() async throws {
        let account = try makeAccount()
        #expect(account.service.directory === account.directory)
        // The waker uses the same cache: its pass refreshes what reloadNames then reads without a request.
        fake.addLabel("Torkku")
        await account.reloadNames()
        #expect(count("list labels") == 1)
        let added = fake.addLabel("Uusi")                                    // Label_2, server side
        _ = try await account.waker.runOnce()
        #expect(count("list labels") == 2)
        await account.reloadNames(knowing: [added])
        #expect(count("list labels") == 2)
        #expect(account.labels?.name(forID: added) == "Uusi")
    }

    @Test func clientNeverDeletesLabels() async throws {
        let account = try makeAccount(now: D(1_791_177_300))                // 2026-10-05 05:15Z
        fake.addSnoozedThread("a", wake: "20261005T0500Z")                 // Label_1 Torkku, Label_2 due 15 min ago
        fake.addLabel("Torkku/20261005T0400Z", visibility: .hidden)        // Label_3: orphan, due 75 min ago
        let report = try await account.waker.runOnce()
        #expect(fake.calls == ["list labels", "list labelIds Label_1 spamTrash -", "thread labels cached a", "thread labels a",
                               "modify a +INBOX,UNREAD -Label_1,Label_2"])
        #expect(!fake.calls.contains { $0.hasPrefix("label delete") })
        #expect(report.woken == ["a"])
        #expect(report.deletedLabelIDs.isEmpty && report.failedLabelIDs.isEmpty)
        #expect(fake.labelNames(of: "a") == ["INBOX", "UNREAD"])
        #expect(fake.labelID("Torkku/20261005T0500Z") == "Label_2")
        #expect(fake.labelID("Torkku/20261005T0400Z") == "Label_3")
    }

    @Test func reloadNamesFills() async throws {
        let account = try makeAccount()
        let marker = fake.addLabel("Torkku")
        await account.reloadNames()
        #expect(account.labels?.name(forID: marker) == "Torkku")
        #expect(account.labels?.name(forID: "INBOX") == "INBOX")
        #expect(account.markerID == marker)
        #expect(fake.calls == ["list labels"])
    }

    @Test func markerIDIsCaseInsensitive() async throws {
        let account = try makeAccount()
        let marker = fake.addLabel("torkku")
        await account.reloadNames()
        #expect(account.markerID == marker)
    }

    @Test func reloadNamesUnknownOnce() async throws {
        let account = try makeAccount()
        await account.reloadNames()
        #expect(count("list labels") == 1)
        await account.reloadNames()                                          // cached: no request
        #expect(count("list labels") == 1)
        let added = fake.addLabel("Uusi")
        await account.reloadNames(knowing: [added])
        #expect(count("list labels") == 2)
        #expect(account.labels?.contains(id: added) == true)
        await account.reloadNames(knowing: ["Label_99"])                     // missing: one refresh
        #expect(count("list labels") == 3)
        await account.reloadNames(knowing: ["Label_99"])                     // still missing: never again
        #expect(count("list labels") == 3)
        #expect(account.labels?.contains(id: "Label_99") == false)
    }

    @Test func reloadNamesFailureKeeps() async throws {
        let account = try makeAccount()
        let marker = fake.addLabel("Torkku")
        await account.reloadNames()
        let before = try #require(account.labels)
        fake.update { $0.offline = true }
        let added = fake.addLabel("Uusi")
        await account.reloadNames(knowing: [added])
        #expect(count("list labels") == 2)                                   // tried
        #expect(account.labels == before)
        #expect(account.markerID == marker)
    }

    @Test func firstLoadFailureLeavesNil() async throws {
        let account = try makeAccount()
        fake.update { $0.offline = true }
        await account.reloadNames()
        #expect(account.labels == nil)
        #expect(account.rowLabel(for: ["Label_1"], now: N) == nil)
    }

    @Test func rowLabelAfterSnooze() async throws {
        let account = try makeAccount()
        fake.base.addThread("a")
        _ = try await account.service.snooze(threadID: "a", until: D(1_791_176_400))     // ma 5.10. 8.00
        let ids = fake.base.state.withLock { $0.threads["a"]?.labelIDs ?? [] }
        #expect(ids == ["Label_1", "Label_2"])
        #expect(account.rowLabel(for: ids, now: N) == nil)                   // no snapshot yet
        await account.reloadNames()
        #expect(account.rowLabel(for: ids, now: N) == "herää ma 8.00")
        #expect(account.rowLabel(for: ids, now: D(1_791_176_400)) == "herää pian")
        #expect(account.rowLabel(for: ["INBOX"], now: N) == nil)
    }
}
