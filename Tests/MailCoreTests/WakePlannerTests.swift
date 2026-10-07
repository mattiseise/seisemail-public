import Foundation
import Testing
@testable import MailCore

@Suite struct WakePlannerTests {
    let scheme = SnoozeLabelScheme.standard
    let now = D(1_791_180_000)                      // 2026-10-05 06:00Z
    let m = "Label_1"
    let wake = [GmailLabel.inbox, GmailLabel.unread]
    static let names = [
        "Label_1": "Torkku",
        "Label_2": "Torkku/20261005T0500Z",        // Tp: past
        "Label_3": "Torkku/20261005T0700Z",        // Tf: future
        "Label_4": "Torkku/20261005T0600Z",        // exactly now
        "Label_5": "Torkku/20261005T0601Z",        // one minute ahead
        "Label_6": "Torkku/garbage",
        "Label_7": "Lajittelu/Kuitit",
        "Label_8": "torkku/20261005T0500Z",        // wrong case: not a time label
        "Label_9": "Torkku/20261005T0559Z",
        "Label_10": "Torkku/20261006T0600Z",
        "Label_11": "Torkku/20261005T0800Z",
    ]

    func decide(_ labels: Set<String>, names: [String: String] = WakePlannerTests.names) -> WakeDecision {
        WakePlanner.decide(threadID: "t", labelIDs: labels, markerID: m, namesByID: names, scheme: scheme, now: now)
    }

    @Test func trashBeatsEverything() {
        let d = decide([m, "Label_2", "TRASH", "INBOX"])
        #expect(d.threadID == "t")
        #expect(d.rule == .trashedOrSpam)
        #expect(d.change == LabelChange(add: [], remove: [m, "Label_2"]))
    }

    @Test func spamCancels() {
        let d = decide([m, "Label_3", "SPAM"])
        #expect(d.rule == .trashedOrSpam)
        #expect(d.change == LabelChange(add: [], remove: [m, "Label_3"]))
    }

    @Test func inboxCancelsWithoutUnreadEvenIfDue() {
        let d = decide([m, "Label_2", "INBOX"])
        #expect(d.rule == .alreadyInInbox)
        #expect(d.change == LabelChange(add: [], remove: [m, "Label_2"]))
    }

    @Test func dueExactlyNow() {
        let d = decide([m, "Label_4"])
        #expect(d.rule == .due)
        #expect(d.change == LabelChange(add: wake, remove: [m, "Label_4"]))
    }

    @Test func oneMinuteEarlyIsNotDue() {
        let d = decide([m, "Label_5"])
        #expect(d == WakeDecision(threadID: "t", rule: .notDue, change: nil, wakeAt: D(1_791_180_060)))
    }

    @Test func markerOnlyWakes() {
        let d = decide([m])
        #expect(d.rule == .noValidTimeLabel)
        #expect(d.change == LabelChange(add: wake, remove: [m]))
    }

    @Test func onlyInvalidWakesAndRemovesIt() {
        let d = decide([m, "Label_6", "Label_7"])
        #expect(d.rule == .noValidTimeLabel)
        #expect(d.change == LabelChange(add: wake, remove: [m, "Label_6"]))
    }

    @Test func earliestOfMultiple() {
        let due = decide([m, "Label_10", "Label_9"])
        #expect(due.rule == .due)
        #expect(due.change == LabelChange(add: wake, remove: [m, "Label_10", "Label_9"]))
        let notDue = decide([m, "Label_11", "Label_3"])
        #expect(notDue == WakeDecision(threadID: "t", rule: .notDue, change: nil, wakeAt: D(1_791_183_600)))
    }

    @Test func dueEvenWithInvalidAlongside() {
        let d = decide([m, "Label_2", "Label_6"])
        #expect(d.rule == .due)
        #expect(d.change == LabelChange(add: wake, remove: [m, "Label_2", "Label_6"]))
    }

    @Test func markerMissingIsNoop() {
        let d = decide(["Label_2"])
        #expect(d.rule == .notSnoozed)
        #expect(d.change == nil)
        #expect(decide(["Label_2", "TRASH", "INBOX"]).rule == .notSnoozed)
    }

    @Test func unknownIDsIgnored() {
        // Label_99 could be a time label created after the cache was filled; the executor refreshes first.
        let future = decide([m, "Label_99", "Label_3"])
        #expect(future.rule == .notDue)
        #expect(future.change == nil)
        let none = decide([m, "Label_99"])
        #expect(none.rule == .noValidTimeLabel)
        #expect(none.change == LabelChange(add: wake, remove: [m]))
    }

    @Test func otherLabelsUntouched() {
        let d = decide([m, "Label_2", "STARRED", "UNREAD", "Label_7"])
        #expect(d.rule == .due)
        #expect(d.change == LabelChange(add: wake, remove: [m, "Label_2"]))
    }

    @Test func removeOrderDeterministic() {
        let names = [m: "Torkku", "Label_9": "Torkku/20261005T0500Z", "Label_10": "Torkku/20261005T0400Z"]
        let d = decide([m, "Label_9", "Label_10"], names: names)
        #expect(d.change?.remove == [m, "Label_10", "Label_9"])      // marker first, then ascending String order
    }

    @Test func caseSensitivePrefix() {
        let d = decide([m, "Label_8"])
        #expect(d.rule == .noValidTimeLabel)
        #expect(d.change == LabelChange(add: wake, remove: [m]))     // the lowercase label stays (case-sensitive prefix)
    }

    @Test func renamedScheme() {
        let custom = SnoozeLabelScheme(marker: "Snoozed", timePrefix: "Snooze/")
        let names = ["Label_1": "Snoozed", "Label_2": "Snooze/20261005T0500Z", "Label_3": "Torkku/20261005T0400Z"]
        let d = WakePlanner.decide(threadID: "p", labelIDs: ["Label_1", "Label_2", "Label_3"], markerID: "Label_1",
                                   namesByID: names, scheme: custom, now: now)
        #expect(d.rule == .due)
        #expect(d.change == LabelChange(add: wake, remove: ["Label_1", "Label_2"]))
    }

    // MARK: - Cleanup

    @Test func cleanupCandidates() {
        let names = [
            "Label_1": "Torkku/20261005T0400Z",
            "Label_2": "Torkku/20261005T0512Z",
            "Label_3": "Torkku/20261005T0600Z",
            "Label_4": "Torkku/garbage",
            "Label_5": "Torkku",
            "INBOX": "INBOX",
        ]
        let ids = WakePlanner.cleanupCandidates(namesByID: names, scheme: scheme, now: D(1_791_177_300), margin: 300)
        #expect(ids == ["Label_1"])
    }

    @Test func cleanupMarginIsInclusiveAndSorted() {
        let names = [
            "Label_9": "Torkku/20261005T0510Z",        // exactly now − 300 s
            "Label_10": "Torkku/20261005T0300Z",
            "Label_11": "Torkku/20261005T0511Z",       // 4 min ago: kept
        ]
        let ids = WakePlanner.cleanupCandidates(namesByID: names, scheme: scheme, now: D(1_791_177_300), margin: 300)
        #expect(ids == ["Label_10", "Label_9"])
        #expect(WakePlanner.cleanupCandidates(namesByID: names, scheme: scheme, now: D(1_791_177_300), margin: 0)
                == ["Label_10", "Label_11", "Label_9"])
    }
}
