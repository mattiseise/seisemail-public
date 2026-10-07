import Foundation

/// `mak8r-daemon rules check` (design §7.2, §15): validates `rules.json` as the daemon would and prints
/// the rules in effect. Exit 65 when the file is refused (the daemon then keeps the last valid copy).
public enum RulesReport {
    public static func check(paths: DaemonPaths) -> (text: String, code: DaemonExitCode) {
        let data: Data?
        do {
            data = try AtomicFile.read(paths.rules)
        } catch {
            return ("rules.json: ei luettavissa (\(error)).", .invalidData)
        }
        guard let data else {
            return ("rules.json puuttuu: käytössä sisäänrakennetut oletussäännöt (mak8r-daemon init kirjoittaa ne tiedostoon).\n\n"
                + describe(CompiledRules.defaults), .ok)
        }
        do {
            let rules = try RuleSet.load(data)
            return ("rules.json kunnossa: \(rules.rules.filter(\.enabled).count)/\(rules.rules.count) sääntöä päällä.\n\n"
                + describe(rules), .ok)
        } catch {
            let problems = error.problems.map { "  - " + ($0.hasPrefix("rules.json") ? $0 : "rules.json: " + $0) }
            let text = (["rules.json on virheellinen, eikä daemon ota sitä käyttöön:"] + problems
                + ["Daemon pitää käytössä viimeisimmän kelvollisen version (tai oletukset). Korjaa tiedosto ja aja rules check uudelleen."])
                .joined(separator: "\n")
            return (text, .invalidData)
        }
    }

    /// The rules in file order: the first enabled match wins.
    public static func describe(_ rules: CompiledRules) -> String {
        var lines = ["Säännöt järjestyksessä (ensimmäinen osuma voittaa):"]
        for (index, rule) in rules.file.rules.enumerated() {
            let state = rule.enabled ? "päällä" : "pois päältä"
            lines.append("\(index + 1). \(rule.id)  \(state)  → \(rule.label)")
            if let note = rule.note { lines.append("     \(note)") }
            for condition in rule.any { lines.append("     - " + conditionText(condition)) }
        }
        var options = ["automaattivastaus omassa ketjussa odottaa: \(rules.options.deferAutoReplyInMyThreads ? "kyllä" : "ei")"]
        if !rules.file.me.isEmpty { options.append("omat lisäosoitteet: \(rules.file.me.joined(separator: ", "))") }
        lines.append("Asetukset: " + options.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    static func conditionText(_ condition: RuleCondition) -> String {
        switch condition {
        case .headerPresent(let header): "otsake \(header) on olemassa"
        case .fromAddress(let pattern): "lähettäjän osoitteessa /\(pattern)/"
        case .autoSubmitted(let notIn): "Auto-Submitted on muu kuin \(notIn.joined(separator: ", "))"
        case .subjectToken(let pattern): "aiheen sana on /\(pattern)/"
        case .senderToken(let pattern): "lähettäjän sana on /\(pattern)/"
        case .fromInSentCache: "lähettäjälle on lähetetty viesti (lähetettyjen välimuisti)"
        case .hasLabel(let pattern): "tunniste /\(pattern)/"
        case .hasSystemLabel(let id): "Gmailin tunniste \(id)"
        }
    }
}
