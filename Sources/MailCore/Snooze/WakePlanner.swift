import Foundation

/// The conventions §1 wake rule that matched, plus rule 0.
public enum WakeRule: String, Sendable, Equatable {
    /// 0: the marker is gone (another waker or Matti was first).
    case notSnoozed
    /// 1
    case trashedOrSpam
    /// 2
    case alreadyInInbox
    /// 3
    case due
    /// 4
    case noValidTimeLabel
    /// No rule matched.
    case notDue
}

public struct WakeDecision: Sendable, Equatable {
    public var threadID: String
    public var rule: WakeRule
    /// nil = no modify.
    public var change: LabelChange?
    /// Earliest valid time label, if any.
    public var wakeAt: Date?

    public init(threadID: String, rule: WakeRule, change: LabelChange?, wakeAt: Date?) {
        self.threadID = threadID
        self.rule = rule
        self.change = change
        self.wakeAt = wakeAt
    }
}

/// Pure wake decisions (conventions §1 "Herätys").
public enum WakePlanner {
    /// `labelIDs` is the union over the thread's messages. IDs absent from `namesByID` are ignored, so the executor
    /// refreshes the directory first. System IDs are checked directly (ID == name). The first matching rule wins.
    public static func decide(threadID: String, labelIDs: Set<String>, markerID: String,
                              namesByID: [String: String], scheme: SnoozeLabelScheme, now: Date) -> WakeDecision {
        guard labelIDs.contains(markerID) else {
            return WakeDecision(threadID: threadID, rule: .notSnoozed, change: nil, wakeAt: nil)
        }
        let strip = [markerID] + SnoozeOperation.timeLabelIDs(in: labelIDs, namesByID: namesByID, scheme: scheme)
        let earliest = scheme.earliestWakeDate(labelIDs: labelIDs, namesByID: namesByID)
        let cancel = LabelChange(add: [], remove: strip)
        let wake = LabelChange(add: [GmailLabel.inbox, GmailLabel.unread], remove: strip)
        func decision(_ rule: WakeRule, _ change: LabelChange?) -> WakeDecision {
            WakeDecision(threadID: threadID, rule: rule, change: change, wakeAt: earliest)
        }
        if labelIDs.contains(GmailLabel.trash) || labelIDs.contains(SeiseLabels.spam) { return decision(.trashedOrSpam, cancel) }
        if labelIDs.contains(GmailLabel.inbox) { return decision(.alreadyInInbox, cancel) }
        // Rules 3 and 4 are mutually exclusive; checking 4 first is only code order.
        guard let wakeAt = earliest else { return decision(.noValidTimeLabel, wake) }
        return wakeAt <= now ? decision(.due, wake) : decision(.notDue, nil)
    }

    /// IDs of labels whose name decodes to a time ≤ now − margin, sorted ascending. Excludes the marker, invalid
    /// names and future times (conventions §1 "Siivous").
    public static func cleanupCandidates(namesByID: [String: String], scheme: SnoozeLabelScheme,
                                         now: Date, margin: TimeInterval) -> [String] {
        let limit = now.addingTimeInterval(-margin)
        return namesByID.filter { scheme.wakeDate(fromLabelName: $0.value).map { $0 <= limit } ?? false }.keys.sorted()
    }
}
