import Foundation

/// Snooze-relevant state of a thread, by name, so undo can recreate labels deleted meanwhile.
public struct SnoozeState: Sendable, Equatable, Hashable {
    public var inInbox: Bool
    public var marked: Bool
    /// Sorted; every name under the time prefix, valid or not.
    public var timeLabelNames: [String]

    public init(inInbox: Bool, marked: Bool, timeLabelNames: [String]) {
        self.inInbox = inInbox
        self.marked = marked
        self.timeLabelNames = timeLabelNames
    }
}

/// Pure snooze and undo changes (conventions §1 "Torkutus").
public enum SnoozeOperation {
    public static func state(of labelIDs: Set<String>, markerID: String?, namesByID: [String: String],
                             scheme: SnoozeLabelScheme) -> SnoozeState {
        SnoozeState(
            inInbox: labelIDs.contains(GmailLabel.inbox),
            marked: markerID.map(labelIDs.contains) ?? false,
            timeLabelNames: labelIDs.compactMap { namesByID[$0] }.filter(scheme.isTimeLabel).sorted()
        )
    }

    /// add = [markerID, timeLabelID]; remove = [INBOX] + the other time-label IDs in `current`, sorted.
    /// INBOX is always removed (a new message may carry it). Unknown IDs and all other labels stay untouched.
    public static func snoozeChange(current: Set<String>, markerID: String, timeLabelID: String,
                                    namesByID: [String: String], scheme: SnoozeLabelScheme) -> LabelChange {
        LabelChange(add: [markerID, timeLabelID],
                    remove: [GmailLabel.inbox] + timeLabelIDs(in: current, namesByID: namesByID, scheme: scheme) { $0 != timeLabelID })
    }

    /// Moves a thread from `current` back to `target`. INBOX is never removed (a reply may have arrived).
    public static func undoChange(target: SnoozeState, current: Set<String>, markerID: String?,
                                  targetTimeLabelIDs: [String: String], namesByID: [String: String],
                                  scheme: SnoozeLabelScheme) -> LabelChange {
        var add: [String] = []
        var remove: [String] = []
        if target.inInbox, !current.contains(GmailLabel.inbox) { add.append(GmailLabel.inbox) }
        if let markerID {
            if target.marked, !current.contains(markerID) { add.append(markerID) }
            if !target.marked, current.contains(markerID) { remove.append(markerID) }
        }
        add += target.timeLabelNames.compactMap { targetTimeLabelIDs[$0] }.filter { !current.contains($0) }
        let keep = Set(target.timeLabelNames)
        remove += timeLabelIDs(in: current, namesByID: namesByID, scheme: scheme) { namesByID[$0].map { !keep.contains($0) } ?? false }
        return LabelChange(add: add, remove: remove)
    }

    /// IDs in `labelIDs` whose name is under the time prefix and that pass `include`, sorted ascending.
    static func timeLabelIDs(in labelIDs: Set<String>, namesByID: [String: String], scheme: SnoozeLabelScheme,
                             where include: (String) -> Bool = { _ in true }) -> [String] {
        labelIDs.filter { id in (namesByID[id].map(scheme.isTimeLabel) ?? false) && include(id) }.sorted()
    }
}
