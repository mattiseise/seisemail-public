import Foundation
import MailCore

/// `mak8r-daemon review` (design §15, §16 stage 2): `decisions.jsonl` and its rotations as lines or a summary.
public enum ReviewReport {
    /// `24h`, `90min`, `3d` (Helsinki midnight, as `backfill`) or `2026-10-01`. nil when unparsable or not positive.
    public static func parseSince(_ text: String, now: Date) -> Date? {
        if text.hasSuffix("min"), let minutes = Int(text.dropLast(3)), minutes > 0 {
            return now.addingTimeInterval(-Double(minutes) * 60)
        }
        if text.hasSuffix("h"), let hours = Int(text.dropLast()), hours > 0 {
            return now.addingTimeInterval(-Double(hours) * 3_600)
        }
        return BackfillRequest.parseSince(text, now: now)
    }

    /// Every readable entry: `decisions.jsonl.3` … `.1`, then the current file (oldest first).
    public static func load(paths: DaemonPaths) -> [DecisionEntry] {
        let current = paths.decisions
        let files = (1...3).reversed().map { URL(fileURLWithPath: current.path + ".\($0)") } + [current]
        return files.flatMap { url -> [DecisionEntry] in
            guard let data = try? AtomicFile.read(url) else { return [] }
            return DecisionLog.parse(String(decoding: data, as: UTF8.self))
        }
    }

    public static func filter(_ entries: [DecisionEntry], _ query: ReviewQuery, now: Date) throws(UsageError) -> [DecisionEntry] {
        guard let since = parseSince(query.since, now: now) else {
            throw UsageError("review: --since \(query.since) ei kelpaa (esimerkiksi 24h, 90min, 3d tai 2026-10-01)")
        }
        let account = query.account?.lowercased()
        return entries.filter { e in
            e.at >= since
                && (account == nil || e.account.lowercased() == account)
                && (query.rule == nil || e.rule == query.rule || (e.alsoMatched ?? []).contains(query.rule!))
        }
    }

    public static func render(_ entries: [DecisionEntry], summary: Bool, now: Date) -> String {
        guard !entries.isEmpty else { return "Ei päätöksiä valitulla aikavälillä." }
        return summary ? summaryText(entries) : entries.map { line($0, now: now) }.joined(separator: "\n")
    }

    /// `ma 5.10. klo 12.01  VARJO  classify kuitit → Lajittelu/Kuitit (myös: ihmiset)  from  "subject"  thread`
    static func line(_ e: DecisionEntry, now: Date) -> String {
        let mode = e.mode == "live" ? "LIVE " : "VARJO"
        let from = e.from.map(clean) ?? "-"
        let subject = e.subject.map { "\"\(clean($0))\"" } ?? "\"\""
        return [FinnishTime.full(e.at, now: now), mode, decisionText(e), from, subject, e.thread]
            .joined(separator: "  ")
    }

    static func decisionText(_ e: DecisionEntry) -> String {
        switch e.decision {
        case "classify":
            var text = "classify \(e.rule ?? "?") → \(e.label ?? "?")"
            if let also = e.alsoMatched, !also.isEmpty { text += " (myös: \(also.joined(separator: ", ")))" }
            return text
        case "propagate":
            let names = e.labels ?? []
            return names.isEmpty ? "propagate (ei puuttuvia)" : "propagate +" + names.joined(separator: " +")
        case "manualKept": return "manualKept (Matti poisti tunnisteen, ei kosketa)"
        case "deferredAutoReply": return "deferredAutoReply (automaattivastaus omassa ketjussa, seuraava viesti ratkaisee)"
        case "unmatched": return "unmatched (ei osumaa)"
        case "ignore": return "ignore" + (e.reason.map { " (\(clean($0)))" } ?? "")
        default: return e.decision
        }
    }

    static func summaryText(_ entries: [DecisionEntry]) -> String {
        func count(_ decision: String) -> Int { entries.filter { $0.decision == decision }.count }
        var lines = ["Päätöksiä \(entries.count) (varjo \(entries.filter { $0.mode != "live" }.count), "
            + "live \(entries.filter { $0.mode == "live" }.count))"]
        lines.append("  luokiteltu: \(count("classify"))")
        lines.append("  periytetty: \(count("propagate"))")
        lines.append("  ei osumaa: \(count("unmatched"))")
        lines.append("  käsin poistettu (ei kosketa): \(count("manualKept"))")
        lines.append("  automaattivastaus odottaa: \(count("deferredAutoReply"))")
        lines.append("  ohitettu: \(count("ignore"))")

        var byRule: [String: Int] = [:]
        var order: [String] = []
        var overlaps: [String: Int] = [:]
        var overlapOrder: [String] = []
        for e in entries where e.decision == "classify" {
            let rule = e.rule ?? "?"
            if byRule[rule] == nil { order.append(rule) }
            byRule[rule, default: 0] += 1
            for other in e.alsoMatched ?? [] {
                let key = "\(rule) + \(other)"
                if overlaps[key] == nil { overlapOrder.append(key) }
                overlaps[key, default: 0] += 1
            }
        }
        if !order.isEmpty {
            lines.append("Säännöittäin:")
            for rule in order.sorted(by: { (byRule[$0]!, $1) > (byRule[$1]!, $0) }) {
                lines.append("  \(rule): \(byRule[rule]!)")
            }
        }
        if !overlapOrder.isEmpty {
            lines.append("Päällekkäiset osumat (voittaja + myös osunut, kysymys Q6):")
            for key in overlapOrder.sorted(by: { (overlaps[$0]!, $1) > (overlaps[$1]!, $0) }) {
                lines.append("  \(key): \(overlaps[key]!)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Untrusted text for a terminal: controls and format characters out, one line.
    static func clean(_ text: String) -> String {
        Sanitize.field(text, max: Sanitize.maxFieldLength).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
