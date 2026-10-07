import Foundation
import Testing
@testable import MailCore

@Suite struct SnoozeTextTests {
    let N = D(1_791_018_000)                     // la 3.10.2026 12.00

    /// INBOX (system), Label_1 "Torkku", Label_2 Monday 8.00, Label_3 Sunday 8.00, Label_4 an invalid time label.
    func snapshot(marker: String = "Torkku") -> LabelSnapshot {
        LabelSnapshot(labels: [
            GmailLabelInfo(id: "INBOX", name: "INBOX", kind: .system),
            GmailLabelInfo(id: "Label_1", name: marker, kind: .user),
            GmailLabelInfo(id: "Label_2", name: "Torkku/20261005T0500Z", kind: .user),    // ma 5.10. 8.00
            GmailLabelInfo(id: "Label_3", name: "Torkku/20261004T0500Z", kind: .user),    // su 4.10. 8.00
            GmailLabelInfo(id: "Label_4", name: "Torkku/huomenna", kind: .user),
        ])
    }

    func row(_ ids: Set<String>, now: Date? = nil, labels: LabelSnapshot? = nil) -> String? {
        SnoozeText.rowLabel(labelIDs: ids, labels: labels ?? snapshot(), now: now ?? N)
    }

    // MARK: - Row label

    @Test func noMarkerIsNil() {
        #expect(row(["INBOX", "Label_2"]) == nil)
        #expect(row([]) == nil)
    }

    @Test func nilSnapshotIsNil() {
        #expect(SnoozeText.rowLabel(labelIDs: ["Label_1", "Label_2"], labels: nil, now: N) == nil)
    }

    @Test func markerMissingFromSnapshotIsNil() {
        let noMarker = LabelSnapshot(labels: [GmailLabelInfo(id: "Label_2", name: "Torkku/20261005T0500Z", kind: .user)])
        #expect(SnoozeText.rowLabel(labelIDs: ["Label_1", "Label_2"], labels: noMarker, now: N) == nil)
    }

    @Test func earliestWins() {
        #expect(row(["Label_1", "Label_2", "Label_3"]) == "herää huomenna 8.00")
    }

    @Test func singleTime() {
        #expect(row(["Label_1", "Label_2"]) == "herää ma 8.00")
        #expect(row(["Label_1", "Label_3", "INBOX"]) == "herää huomenna 8.00")
    }

    @Test func dueIsSoon() {
        #expect(row(["Label_1", "Label_2"], now: D(1_791_176_460)) == "herää pian")
        #expect(row(["Label_1", "Label_2"], now: D(1_791_176_400)) == "herää pian")      // exactly due
        #expect(row(["Label_1", "Label_2"], now: D(1_791_176_340)) == "herää tänään 8.00")
    }

    @Test func markerOnlyIsSoon() {
        #expect(row(["Label_1", "INBOX"]) == "herää pian")
        #expect(row(["Label_1"]) == "herää pian")
    }

    @Test func invalidTimeLabelIsSoon() {
        #expect(row(["Label_1", "Label_4"]) == "herää pian")                           // every ID known (wake rule 4)
        #expect(row(["Label_1", "Label_4", "Label_2"]) == "herää ma 8.00")             // the valid one counts
    }

    @Test func unknownIDIsSnoozed() {
        #expect(row(["Label_1", "Label_99"]) == "torkussa")
        #expect(row(["Label_1", "Label_4", "Label_99"]) == "torkussa")
    }

    @Test func knownTimeBeatsUnknownID() {
        #expect(row(["Label_1", "Label_2", "Label_99"]) == "herää ma 8.00")
    }

    @Test func markerCaseInsensitive() {
        #expect(row(["Label_1", "Label_2"], labels: snapshot(marker: "torkku")) == "herää ma 8.00")
        #expect(row(["Label_1"], labels: snapshot(marker: "TORKKU")) == "herää pian")
    }

    @Test func rowLabelUsesGivenZone() {
        let label = SnoozeText.rowLabel(labelIDs: ["Label_1", "Label_2"], labels: snapshot(), now: N,
                                        timeZone: TimeZone(identifier: "UTC")!)
        #expect(label == "herää ma 5.00")
    }

    @Test func rowLabelFarAndOtherYear() {
        let far = LabelSnapshot(labels: [
            GmailLabelInfo(id: "Label_1", name: "Torkku", kind: .user),
            GmailLabelInfo(id: "Label_5", name: "Torkku/20261010T0500Z", kind: .user),     // la 10.10. 8.00
            GmailLabelInfo(id: "Label_6", name: "Torkku/20270105T0600Z", kind: .user),     // ti 5.1.2027 8.00
        ])
        #expect(row(["Label_1", "Label_5"], labels: far) == "herää 10.10. klo 8.00")
        #expect(row(["Label_1", "Label_6"], labels: far) == "herää 5.1.2027 klo 8.00")
    }

    // MARK: - Toasts and summary

    @Test func successToastSingle() {
        #expect(SnoozeText.successToast(count: 1, wakeAt: D(1_791_176_400), now: N) == "Torkutettu – herää ma 5.10. klo 8.00")
    }

    @Test func successToastPlural() {
        #expect(SnoozeText.successToast(count: 3, wakeAt: D(1_791_176_400), now: N) == "3 torkutettua – herää ma 5.10. klo 8.00")
        #expect(SnoozeText.successToast(count: 2, wakeAt: D(1_791_090_000), now: N) == "2 torkutettua – herää su 4.10. klo 8.00")
        #expect(SnoozeText.successToast(count: 12, wakeAt: D(1_791_176_400), now: N) == "12 torkutettua – herää ma 5.10. klo 8.00")
    }

    @Test func successToastOtherYear() {
        #expect(SnoozeText.successToast(count: 1, wakeAt: D(1_799_128_800), now: N) == "Torkutettu – herää ti 5.1.2027 klo 8.00")
    }

    @Test func dailySummary() {
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 0, snoozed: 0)) == nil)
        #expect(SnoozeText.dailySummary(.zero) == nil)
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 1, snoozed: 0)) == "Tänään: 1 arkistoitu")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 0, snoozed: 2)) == "Tänään: 2 torkutettua")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 12, snoozed: 3)) == "Tänään: 12 arkistoitua · 3 torkutettua")
    }

    /// Owner decision 1 (2026-10-04): nominative for exactly 1, partitive for every other count.
    @Test func dailySummaryOneVsMany() {
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 1, snoozed: 1)) == "Tänään: 1 arkistoitu · 1 torkutettu")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 0, snoozed: 1)) == "Tänään: 1 torkutettu")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 2, snoozed: 1)) == "Tänään: 2 arkistoitua · 1 torkutettu")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 1, snoozed: 2)) == "Tänään: 1 arkistoitu · 2 torkutettua")
        #expect(SnoozeText.dailySummary(ActivityCounts(archived: 21, snoozed: 0)) == "Tänään: 21 arkistoitua")
    }

    @Test func countedForms() {
        #expect(SnoozeText.counted(1, "valittu", "valittua") == "1 valittu")
        #expect(SnoozeText.counted(2, "valittu", "valittua") == "2 valittua")
        #expect(SnoozeText.counted(0, "valittu", "valittua") == "0 valittua")
        #expect(SnoozeText.counted(11, "torkutettu", "torkutettua") == "11 torkutettua")
    }
}
