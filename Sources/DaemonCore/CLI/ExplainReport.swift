import Foundation
import MailCore

/// `mak8r-daemon explain <threadId>` (design §15): the full decision trace of one fresh read. Every
/// message counts as new, so the decider is the newest incoming INBOX message, as when a message arrives.
/// The CLI reads through a shadow gate, so nothing is ever written. Pure: tests render it without Gmail.
public enum ExplainReport {
    public static func render(thread: ThreadHeaders, labels: LabelSnapshot, rules: CompiledRules, sent: SentCache,
                              me: Set<String>, now: Date) -> String {
        let newIDs = Set(thread.messages.map(\.id))
        let (decision, decider) = SortingPlanner.decide(thread: thread, newMessageIDs: newIDs, labels: labels,
                                                        rules: rules, sent: sent, me: me)
        var lines = ["Ketju \(thread.threadID)\(thread.historyID.map { " (historia \($0))" } ?? ""), \(thread.messages.count) viestiä:"]
        for m in thread.messages {
            let date = m.internalDate.map { FinnishTime.full($0, now: now) } ?? "-"
            let kind = SortingPlanner.isOwn(m, me: me) ? "daemonin muistutus"
                : !SortingPlanner.isIncoming(m) ? "ei saapunut"
                : m.labelIDs.contains(GmailLabel.inbox) ? "saapunut, Saapuneissa" : "saapunut, arkistoitu"
            lines.append("  \(m.id)  \(date)  [\(labelNames(m.labelIDs, labels).joined(separator: ", "))]  \(kind)")
            lines.append("      \(clean(m.first("From") ?? "-"))  \"\(clean(m.first("Subject") ?? ""))\"")
        }
        guard let decider else {
            lines.append("Ratkaiseva viesti: ei (yksikään viesti ei ole saapunut ja Saapuneissa)")
            lines.append("Päätös: \(decisionText(decision))")
            lines.append("(varjo: mitään ei kirjoitettu)")
            return lines.joined(separator: "\n")
        }
        lines.append("Ratkaiseva viesti: \(decider.id) (uusin saapunut viesti Saapuneissa)")

        let facts = MessageFacts(message: decider, labels: labels)
        let mine = Set(me.map { $0.lowercased() }).union(rules.me)
        lines.append("Tiedot:")
        lines.append("  lähettäjä: \(facts.fromAddress.map(clean) ?? "- (ei kelvollista osoitetta)")"
            + (facts.fromName.map { " (\(clean($0)))" } ?? ""))
        lines.append("  aihe: \(clean(facts.subject))")
        lines.append("  aiheen sanat: \(list(facts.subjectTokens))")
        lines.append("  lähettäjän sanat: \(list(facts.senderTokens))")
        lines.append("  Auto-Submitted: \(facts.autoSubmitted.map(clean) ?? "-")")
        lines.append("  otsakkeet: \(list(facts.presentHeaders.sorted()))")
        lines.append("  tunnisteet: \(list(facts.userLabelNames)); järjestelmä: \(list(facts.systemLabelIDs.sorted()))")
        let inCache = facts.fromAddress.map { sent.contains($0) } ?? false
        let isMine = facts.fromAddress.map { mine.contains($0) } ?? false
        lines.append("  lähetettyjen välimuistissa: \(inCache ? "kyllä" : "ei")\(isMine ? " (oma osoite)" : "")")

        switch decision {
        case .propagate, .manualKept:
            lines.append("Säännöt eivät ratkaise: ketjulla on jo lajittelutunniste tai merkki (käsin tehty voittaa).")
        default:
            lines.append("Säännöt:")
            for (index, rule) in rules.rules.enumerated() {
                let definition = index < rules.file.rules.count ? rules.file.rules[index] : nil
                guard rule.enabled else {
                    lines.append("  \(index + 1). \(rule.id): pois päältä")
                    continue
                }
                let hits = rule.conditions.indices.filter { RuleEngine.matches(rule.conditions[$0], facts, sent: sent, me: mine) }
                if hits.isEmpty {
                    lines.append("  \(index + 1). \(rule.id): ei osu")
                } else {
                    let why = hits.compactMap { i in definition.flatMap { i < $0.any.count ? RulesReport.conditionText($0.any[i]) : nil } }
                    lines.append("  \(index + 1). \(rule.id): osuu (\(why.joined(separator: "; "))) → \(rule.label)")
                }
            }
        }
        lines.append("Päätös: \(decisionText(decision))")
        if !decision.addNames.isEmpty {
            lines.append("  lisättäisiin: \(decision.addNames.joined(separator: ", "))")
        }
        lines.append("(varjo: mitään ei kirjoitettu)")
        return lines.joined(separator: "\n")
    }

    static func decisionText(_ decision: SortingDecision) -> String {
        switch decision {
        case .ignore(let why): "ignore (\(why))"
        case .propagate(let names): names.isEmpty ? "propagate (kaikki tunnisteet jo paikallaan, ei kutsua)" : "propagate +" + names.joined(separator: " +")
        case .classify(let rule, let label, let also):
            "classify \(rule) → \(label)" + (also.isEmpty ? "" : " (myös: \(also.joined(separator: ", ")))")
        case .manualKept: "manualKept (merkki ilman lajittelutunnistetta: Matti poisti tunnisteen, ei kosketa)"
        case .deferredAutoReply: "deferredAutoReply (automaattivastaus omassa ketjussa: seuraava viesti ratkaisee)"
        case .unmatched: "unmatched (ei osumaa: ei merkkiä, arvioidaan uudelleen seuraavasta viestistä)"
        }
    }

    static func labelNames(_ ids: Set<String>, _ labels: LabelSnapshot) -> [String] {
        ids.map { labels.name(forID: $0) ?? $0 }.sorted()
    }

    static func list(_ items: [String]) -> String {
        items.isEmpty ? "-" : items.map(clean).joined(separator: ", ")
    }

    static func clean(_ text: String) -> String { ReviewReport.clean(text) }
}
