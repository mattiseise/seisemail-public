import Foundation

/// Finnish snooze text for the Mac UI: row labels, toasts and the daily summary (phase 1 design §7).
public enum SnoozeText {
    /// nil without a snapshot or without the marker (exact name, else case-insensitive, like the waker).
    /// Earliest valid time label > now → "herää " + compact; ≤ now, or no valid time while every ID is known
    /// (wake rule 4) → "herää pian"; no valid time and some ID not in the snapshot (made on another device) → "torkussa".
    public static func rowLabel(labelIDs: Set<String>, labels: LabelSnapshot?, scheme: SnoozeLabelScheme = .standard,
                                now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String? {
        guard let labels, let marker = labels.id(forName: scheme.marker), labelIDs.contains(marker) else { return nil }
        if let wake = scheme.earliestWakeDate(labelIDs: labelIDs, namesByID: labels.namesByID) {
            return wake > now ? "herää " + FinnishTime.compact(wake, now: now, timeZone: timeZone) : "herää pian"
        }
        return labelIDs.allSatisfy(labels.contains(id:)) ? "herää pian" : "torkussa"
    }

    /// "1 valittu", "3 valittua": the nominative for exactly 1, the partitive for any other count
    /// (Matti's decision 4.10.2026). Every fork string that puts a number before a past participle uses this.
    public static func counted(_ count: Int, _ nominative: String, _ partitive: String) -> String {
        "\(count) " + (count == 1 ? nominative : partitive)
    }

    /// "Torkutettu – herää ma 5.10. klo 8.00" / "3 torkutettua – herää ma 5.10. klo 8.00"
    public static func successToast(count: Int, wakeAt: Date, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let lead = count == 1 ? "Torkutettu" : counted(count, "torkutettu", "torkutettua")
        return lead + " – herää " + FinnishTime.full(wakeAt, now: now, timeZone: timeZone)
    }

    /// nil without a summary or when nothing is snoozed; "4 torkussa", "4 torkussa · seuraava herää ma 8.00",
    /// "1 torkussa · seuraava herää pian" (the wake time has passed but the wake pass has not run yet).
    public static func snoozedLine(_ summary: SnoozeSummary?, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String? {
        guard let summary, summary.total > 0 else { return nil }
        let lead = "\(summary.total) torkussa"
        guard let next = summary.nextWake else { return lead }
        return lead + " · seuraava herää " + (next > now ? FinnishTime.compact(next, now: now, timeZone: timeZone) : "pian")
    }

    /// nil when both are 0; "Tänään: 12 arkistoitua · 3 torkutettua", "Tänään: 1 arkistoitu · 1 torkutettu",
    /// "Tänään: 2 torkutettua"
    public static func dailySummary(_ counts: ActivityCounts) -> String? {
        var parts: [String] = []
        if counts.archived > 0 { parts.append(counted(counts.archived, "arkistoitu", "arkistoitua")) }
        if counts.snoozed > 0 { parts.append(counted(counts.snoozed, "torkutettu", "torkutettua")) }
        return parts.isEmpty ? nil : "Tänään: " + parts.joined(separator: " · ")
    }
}
