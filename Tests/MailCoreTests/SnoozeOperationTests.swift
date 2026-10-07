import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeOperationTests {
    let scheme = SnoozeLabelScheme.standard
    let names = [
        "Label_1": "Torkku",
        "Label_2": "Torkku/20261005T0500Z",     // new time
        "Label_3": "Torkku/20261004T0500Z",     // old time
        "Label_4": "Torkku/garbage",
        "Label_5": "Lajittelu/Kuitit",
    ]

    func snooze(_ current: Set<String>, target: String = "Label_2") -> LabelChange {
        SnoozeOperation.snoozeChange(current: current, markerID: "Label_1", timeLabelID: target, namesByID: names, scheme: scheme)
    }

    func undo(to target: SnoozeState, from current: Set<String>, targetIDs: [String: String] = [:]) -> LabelChange {
        SnoozeOperation.undoChange(target: target, current: current, markerID: "Label_1", targetTimeLabelIDs: targetIDs,
                                   namesByID: names, scheme: scheme)
    }

    // MARK: - Snooze

    @Test func snoozeFromInbox() {
        #expect(snooze(["INBOX", "UNREAD"]) == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
    }

    @Test func resnoozeRemovesOldAndInvalid() {
        let change = snooze(["Label_1", "Label_3", "Label_4", "Label_5"])
        #expect(change == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX", "Label_3", "Label_4"]))
        #expect(!change.remove.contains("Label_5") && !change.add.contains("Label_5"))
    }

    @Test func sameMinuteDisjoint() {
        let change = snooze(["Label_1", "Label_2"])
        #expect(change == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
        #expect(Set(change.add).isDisjoint(with: change.remove))
    }

    @Test func inboxAlwaysRemoved() {
        #expect(snooze(["STARRED"]) == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
        #expect(snooze([]) == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
    }

    @Test func unknownIDsUntouched() {
        #expect(snooze(["Label_99"]) == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX"]))
    }

    @Test func oldTimeLabelsRemovedInAscendingIDOrder() {
        let names = ["Label_1": "Torkku", "Label_2": "Torkku/20261005T0500Z",
                     "Label_9": "Torkku/20261004T0500Z", "Label_10": "Torkku/20261003T0500Z"]
        let change = SnoozeOperation.snoozeChange(current: ["Label_9", "Label_10", "Label_1"], markerID: "Label_1",
                                                  timeLabelID: "Label_2", namesByID: names, scheme: scheme)
        #expect(change == LabelChange(add: ["Label_1", "Label_2"], remove: ["INBOX", "Label_10", "Label_9"]))
    }

    @Test func stateCapturesNames() {
        let state = SnoozeOperation.state(of: ["INBOX", "Label_1", "Label_3", "Label_4", "Label_5"], markerID: "Label_1",
                                          namesByID: names, scheme: scheme)
        #expect(state == SnoozeState(inInbox: true, marked: true, timeLabelNames: ["Torkku/20261004T0500Z", "Torkku/garbage"]))
    }

    @Test func stateWithoutMarkerLabel() {
        let state = SnoozeOperation.state(of: ["STARRED", "Label_99"], markerID: nil, namesByID: names, scheme: scheme)
        #expect(state == SnoozeState(inInbox: false, marked: false, timeLabelNames: []))
    }

    // MARK: - Undo

    @Test func undoFromInbox() {
        let change = undo(to: SnoozeState(inInbox: true, marked: false, timeLabelNames: []), from: ["Label_1", "Label_2"])
        #expect(change == LabelChange(add: ["INBOX"], remove: ["Label_1", "Label_2"]))
    }

    @Test func undoResnoozeWithRecreatedLabel() {
        let change = undo(to: SnoozeState(inInbox: false, marked: true, timeLabelNames: ["Torkku/20261004T0500Z"]),
                          from: ["Label_1", "Label_2"], targetIDs: ["Torkku/20261004T0500Z": "Label_6"])
        #expect(change == LabelChange(add: ["Label_6"], remove: ["Label_2"]))
    }

    @Test func undoFromArchived() {
        let change = undo(to: SnoozeState(inInbox: false, marked: false, timeLabelNames: []), from: ["Label_1", "Label_2"])
        #expect(change == LabelChange(add: [], remove: ["Label_1", "Label_2"]))
    }

    @Test func undoNeverRemovesInbox() {
        let change = undo(to: SnoozeState(inInbox: false, marked: false, timeLabelNames: []), from: ["Label_1", "Label_2", "INBOX"])
        #expect(change == LabelChange(add: [], remove: ["Label_1", "Label_2"]))
    }

    @Test func undoAlreadyRestoredIsEmpty() {
        let change = undo(to: SnoozeState(inInbox: true, marked: false, timeLabelNames: []), from: ["INBOX", "UNREAD"])
        #expect(change == LabelChange())
        #expect(change.isEmpty)
    }

    @Test func undoKeepsTargetTimeLabelAndRemovesInvalid() {
        let change = undo(to: SnoozeState(inInbox: false, marked: true, timeLabelNames: ["Torkku/20261004T0500Z"]),
                          from: ["Label_1", "Label_2", "Label_3", "Label_4"], targetIDs: ["Torkku/20261004T0500Z": "Label_3"])
        #expect(change == LabelChange(add: [], remove: ["Label_2", "Label_4"]))
    }

    // MARK: - LabelChange

    @Test func inverseBefore() {
        let change = LabelChange(add: ["A", "B"], remove: ["INBOX", "C"])
        #expect(change.inverse(before: ["INBOX", "B"]) == LabelChange(add: ["INBOX"], remove: ["A"]))
        #expect(LabelChange(add: [], remove: ["INBOX"]).inverse(before: ["STARRED"]) == LabelChange())
    }

    @Test func emptiness() {
        #expect(LabelChange().isEmpty)
        #expect(LabelChange(add: ["A"]).isEmpty == false)
        #expect(LabelChange(remove: ["A"]).isEmpty == false)
    }
}
