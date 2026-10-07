import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct SnoozeSummaryTests {
    let fake = LabelFakeGmail()
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00 (09.00Z)
    let sunday8 = D(1_791_090_000)               // su 4.10. 8.00 = Torkku/20261004T0500Z
    let monday8 = D(1_791_176_400)               // ma 5.10. 8.00 = Torkku/20261005T0500Z
    let overdue = D(1_791_017_700)               // la 3.10. 11.55 = Torkku/20261003T0855Z

    func load(maxProbes: Int = 8) async throws -> SnoozeSummary {
        let snapshot = LabelSnapshot(labels: try await fake.listLabels())
        return try await SnoozeSummary.load(api: fake, labels: snapshot, scheme: .standard, now: N, maxProbes: maxProbes)
    }

    func countCalls() -> [String] { fake.calls.filter { $0.hasPrefix("count label") } }

    @Test func noMarkerIsEmptyAndCostsNothing() async throws {
        #expect(try await load() == .empty)
        #expect(countCalls().isEmpty)
    }

    @Test func totalCountsReadAndUnreadThreads() async throws {
        fake.addSnoozedThread("a", wake: "20261004T0500Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z", extra: [GmailLabel.unread])
        #expect(try await load() == SnoozeSummary(total: 2, nextWake: sunday8))
    }

    @Test func earliestLabelWithoutThreadsIsSkipped() async throws {
        let empty = fake.addLabel("Torkku/20261004T0500Z", visibility: .hidden)   // its thread woke already
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        #expect(try await load() == SnoozeSummary(total: 1, nextWake: monday8))
        #expect(countCalls().contains("count label \(empty)"))
    }

    @Test func oldPastLabelsAreNeverProbed() async throws {
        fake.addSnoozedThread("stuck", wake: "20261001T0500Z")                     // two days old, not cleaned yet
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let old = try #require(fake.labelID("Torkku/20261001T0500Z"))
        #expect(try await load() == SnoozeSummary(total: 2, nextWake: monday8))
        #expect(!countCalls().contains("count label \(old)"))
    }

    @Test func recentlyOverdueStillCountsAsNext() async throws {
        fake.addSnoozedThread("a", wake: "20261003T0855Z")
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        let summary = try await load()
        #expect(summary == SnoozeSummary(total: 2, nextWake: overdue))
        #expect(SnoozeText.snoozedLine(summary, now: N) == "2 torkussa · seuraava herää pian")
    }

    @Test func nothingSnoozedSkipsTheProbes() async throws {
        fake.addSnoozedThread("a", wake: "20261005T0500Z")
        let marker = try #require(fake.labelID("Torkku"))
        fake.strip([marker], from: "a")                                            // woken: marker gone
        #expect(try await load() == .empty)
        #expect(countCalls() == ["count label \(marker)"])
    }

    @Test func probesAreCapped() async throws {
        for day in 4...13 { fake.addLabel(String(format: "Torkku/202610%02dT0500Z", day), visibility: .hidden) }
        fake.addSnoozedThread("late", wake: "20261020T0500Z")
        #expect(try await load(maxProbes: 8) == SnoozeSummary(total: 1, nextWake: nil))
        #expect(countCalls().count == 1 + 8)
    }

    @Test func accountKeepsTheLastSummaryOnError() async throws {
        fake.addSnoozedThread("a", wake: "20261004T0500Z")
        let clock: @Sendable () -> Date = { [N] in N }
        let account = try #require(SnoozeAccount(api: fake, now: clock))
        #expect(account.summary == nil)
        await account.refreshSummary()
        #expect(account.summary == SnoozeSummary(total: 1, nextWake: sunday8))
        fake.update { $0.failing.insert("labelGet") }
        fake.addSnoozedThread("b", wake: "20261005T0500Z")
        await account.refreshSummary()
        #expect(account.summary == SnoozeSummary(total: 1, nextWake: sunday8))
    }

    // MARK: - Text

    @Test func lineIsNilWhenNothingIsSnoozed() {
        #expect(SnoozeText.snoozedLine(nil, now: N) == nil)
        #expect(SnoozeText.snoozedLine(.empty, now: N) == nil)
    }

    @Test(arguments: [
        (SnoozeSummary(total: 4, nextWake: nil), "4 torkussa"),
        (SnoozeSummary(total: 1, nextWake: D(1_791_090_000)), "1 torkussa · seuraava herää huomenna 8.00"),
        (SnoozeSummary(total: 2, nextWake: D(1_791_176_400)), "2 torkussa · seuraava herää ma 8.00"),
        (SnoozeSummary(total: 3, nextWake: D(1_791_028_800)), "3 torkussa · seuraava herää tänään 15.00"),
    ])
    func lineForms(_ summary: SnoozeSummary, _ expected: String) {
        #expect(SnoozeText.snoozedLine(summary, now: N) == expected)
    }
}
