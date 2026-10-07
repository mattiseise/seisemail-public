import Foundation
import MailCore

/// `mak8r-daemon status [--json]` (design §9.4, §15): reads `status.json`, never the daemon itself.
/// Exit codes: 0 ok, 1 needs attention, 2 not running or stale.
public enum StatusReport {
    public static func exitCode(_ status: DaemonStatus?, now: Date) -> DaemonExitCode {
        guard let status else { return .notRunning }
        switch status.health(now: now) {
        case .ok: return .ok
        case .attention: return .attention
        case .notRunning: return .notRunning
        }
    }

    /// The file as local monitors read it (re-encoded, same keys); `{"schema":1,"state":"missing"}` without one.
    public static func json(_ status: DaemonStatus?, now: Date) -> (text: String, code: DaemonExitCode) {
        guard let status, let data = try? DaemonJSON.encoder().encode(status) else {
            return (#"{"schema":1,"state":"missing"}"#, .notRunning)
        }
        return (String(decoding: data, as: UTF8.self), exitCode(status, now: now))
    }

    /// The Finnish text Matti reads.
    public static func render(_ status: DaemonStatus?, now: Date) -> (text: String, code: DaemonExitCode) {
        let code = exitCode(status, now: now)
        guard let status else {
            return ("Daemon ei ole käynnissä (tilatiedostoa ei ole). Asenna tai käynnistä: make daemon-install", code)
        }
        var lines: [String] = []
        let age = Int(now.timeIntervalSince(status.writtenAt))
        if status.state != "running" {
            lines.append("Daemon pysäytetty \(FinnishTime.full(status.writtenAt, now: now)) (pid \(status.pid)).")
        } else if age > Int(DaemonStatus.staleAfter) {
            lines.append("VIRHE: daemon ei vastaa. Tila päivitettiin viimeksi \(FinnishTime.full(status.writtenAt, now: now)) "
                + "(\(DaemonEvent.duration(TimeInterval(age))) sitten, pid \(status.pid)). Katso make daemon-logs.")
        } else if status.accounts.isEmpty, status.error == nil {
            lines.append("Daemon käynnissä, ei tilejä. Kirjaudu: mak8r-daemon login <osoite>")
        } else {
            lines.append("Daemon käynnissä (pid \(status.pid), käännös \(status.build), käynnistetty "
                + "\(FinnishTime.full(status.startedAt, now: now))).")
        }
        lines.append("Tilat: herätys \(status.modes.wake.rawValue)\(modeNote(status.modes.wake)), "
            + "lajittelu \(status.modes.sorting.rawValue)\(modeNote(status.modes.sorting))")
        if status.safeMode {
            var text = "TURVATILA: daemon käynnistyi toistuvasti ilman hallittua pysäytystä (kaatui tai tapettiin), lajittelu on pois päältä."
            if let until = status.safeModeUntil {
                text += " Tila poistuu itsestään \(FinnishTime.compact(until, now: now)), jos daemon pysyy käynnissä."
            }
            lines.append(text + " Katso daemon.log.")
        } else if let cleared = status.safeModeClearedAt {
            lines.append("Turvatila päättyi \(FinnishTime.compact(cleared, now: now)) (30 min vakaata ajoa), lajittelu jatkuu.")
        }
        if let error = status.error { lines.append("VIRHE: \(error)") }
        for problem in status.configProblems {
            lines.append("Asetusvirhe (käytössä viimeisin kelvollinen): \(problem)")
        }
        for account in status.accounts {
            lines.append("")
            lines += accountLines(account, now: now)
        }
        return (lines.joined(separator: "\n"), code)
    }

    /// The catch-up after going live (§16 stage 4): one dry-run per account with a shadow period, from its
    /// first day. `--account` only when several accounts are signed in.
    public static func backfillCommands(_ status: DaemonStatus?) -> [String] {
        guard let status else { return [] }
        let many = status.accounts.count > 1
        return status.accounts.compactMap { a in
            a.shadowSince.map {
                "mak8r-daemon backfill --since \(BackfillRequest.sinceArgument($0))" + (many ? " --account \(a.email)" : "") + " --dry-run"
            }
        }
    }

    /// "41 s", "12 min", "3 h 5 min"
    static func seconds(_ value: Int) -> String {
        value < 120 ? "\(max(value, 0)) s" : DaemonEvent.duration(TimeInterval(value))
    }

    static func modeNote(_ mode: FeatureMode) -> String {
        switch mode {
        case .off: " (pois)"
        case .shadow: " (varjotila: vain lokiin)"
        case .live: ""
        }
    }

    public static func accountLines(_ a: AccountStatus, now: Date) -> [String] {
        var lines = ["\(a.email): \(phaseText(a))"]
        // needsLogin: the phase line already says KIRJAUDU UUDELLEEN and why.
        if let attention = a.attention, a.phase != "needsLogin" { lines.append("  HUOM: \(attention)") }
        if let action = a.action { lines.append("  → \(action)") }
        if let expiresAt = a.expiresAt {
            let verb = expiresAt > now ? "Kirjautuminen voimassa \(FinnishTime.full(expiresAt, now: now)) asti"
                : "Kirjautuminen vanheni arviolta \(FinnishTime.full(expiresAt, now: now))"
            lines.append("  \(verb)")
        }
        if a.lastWakeAt != nil || a.nextWakeAt != nil {
            var text = "  herätys: " + (a.lastWakeAt.map { "viimeksi \(FinnishTime.compact($0, now: now)) \(resultText(a.lastWakeResult))" } ?? "ei vielä")
            if let next = a.nextWakeAt { text += ", seuraava torkku \(FinnishTime.compact(next, now: now))" }
            lines.append(text)
        }
        if a.lastSyncAt != nil || a.watermarkAgeSeconds != nil {
            var text = "  lajittelu: " + (a.lastSyncAt.map { "viimeksi \(FinnishTime.compact($0, now: now)) \(resultText(a.lastSyncResult))" } ?? "ei vielä")
            if let age = a.watermarkAgeSeconds { text += ", vesileima \(seconds(age)) vanha" }
            lines.append(text)
        }
        if let line = sortingSinceLine(a, now: now) { lines.append(line) }
        switch a.sentBackfill {
        case "done": lines.append("  lähetettyjen välimuisti: valmis")
        case .some: lines.append("  lähetettyjen välimuisti: rakennetaan (\(a.sentBackfillProgress ?? "0/?"))")
        case nil: break
        }
        if let scan = a.scan { lines.append("  läpikäynti: \(scan)") }
        let t = a.today
        lines.append("  tänään: herätetty \(t.woken), peruttu \(t.cancelled), siivottu \(t.cleaned), luokiteltu \(t.classified), "
            + "periytetty \(t.propagated), ei osumaa \(t.unmatched)")
        var meter: [String] = []
        if let skew = a.skewSeconds { meter.append("kellon poikkeama \(String(format: "%.1f", skew).replacingOccurrences(of: ".", with: ",")) s") }
        if let units = a.unitsLastMinute { meter.append("kiintiöyksiköitä viime minuutilla \(units)") }
        if !meter.isEmpty { lines.append("  " + meter.joined(separator: ", ")) }
        return lines
    }

    /// "  lajittelu varjotilassa 4.10. klo 14.02 alkaen (backfill --since 2026-10-04)", with the live start
    /// when known; nil when neither is.
    static func sortingSinceLine(_ a: AccountStatus, now: Date) -> String? {
        switch (a.shadowSince, a.liveSince) {
        case (nil, nil):
            return nil
        case (nil, let live?):
            return "  lajittelu live-tilassa \(FinnishTime.dateAndClock(live, now: now)) alkaen"
        case (let shadow?, nil):
            return "  lajittelu varjotilassa \(FinnishTime.dateAndClock(shadow, now: now)) alkaen "
                + "(backfill --since \(BackfillRequest.sinceArgument(shadow)))"
        case (let shadow?, let live?):
            return "  lajittelu varjotilassa \(FinnishTime.dateAndClock(shadow, now: now)) alkaen, "
                + "live-tilassa \(FinnishTime.dateAndClock(live, now: now)) alkaen "
                + "(varjojakson ketjut: backfill --since \(BackfillRequest.sinceArgument(shadow)))"
        }
    }

    /// One wake tick for `once`.
    public static func wakeText(_ outcome: WakeOutcome) -> String {
        switch outcome {
        case .completed(let woken, let cancelled, let next):
            "ok, herätetty \(woken), peruttu \(cancelled)" + (next.map { ", seuraava \(DaemonLog.utcMinute($0))" } ?? "")
        case .skipped: "ohitettu (herätys pois tai tili ei valmis)"
        case .paused: "tauolla (kirjautuminen ei kelpaa)"
        case .offline: "ei verkkoyhteyttä"
        case .rateLimited: "Gmail rajoittaa kutsuja"
        case .signInExpired: "kirjautuminen vanhentunut"
        case .failed: "virhe (katso daemon.log)"
        case .cancelled: "keskeytetty"
        }
    }

    /// One sync tick for `once`.
    public static func syncText(_ outcome: SyncOutcome) -> String {
        let c = outcome.counts
        let counts = "ketjuja \(c.threads), luokiteltu \(c.classified), periytetty \(c.propagated), ei osumaa \(c.unmatched), "
            + "kirjoituksia \(c.writes), ohitettu \(c.skipped)"
        let stage = outcome.stage.map { " [\($0.rawValue)]" } ?? ""
        let more = outcome.backlog ? "; työtä jäi seuraavalle kierrokselle" : ""
        switch outcome.result {
        case .ok: return "ok\(stage): \(counts)\(more)"
        case .skipped(let why): return "ohitettu (\(why))"
        case .failed(let why): return "virhe: \(Sanitize.line(why))"
        default: return resultText(outcome.result.word).trimmingCharacters(in: CharacterSet(charactersIn: "()")) + stage
        }
    }

    static func phaseText(_ a: AccountStatus) -> String {
        switch a.phase {
        case "starting": return "käynnistyy"
        case "backfillingSent": return "käynnissä, rakentaa lähetettyjen välimuistia (herätys toimii)"
        case "running": return "käynnissä"
        case "needsLogin":
            let why: String = switch a.reason {
            case "expired": "kirjautuminen vanhentunut"
            case "tokenMissing": "ei tokenia"
            case "tokenUnreadable": "tokenitiedosto ei luettavissa"
            case "clientChanged": "OAuth-asiakas vaihtunut"
            case "wrongAccount": "tokeni kuuluu toiselle tilille"
            default: "kirjautuminen ei kelpaa"
            }
            return "KIRJAUDU UUDELLEEN (\(why))"
        case "stateError": return "tilatiedosto ei käytettävissä, tiliä ei käsitellä"
        default: return a.phase
        }
    }

    static func resultText(_ word: String?) -> String {
        switch word {
        case "ok": "ok"
        case "offline": "(ei verkkoyhteyttä)"
        case "rateLimited": "(Gmail rajoittaa kutsuja)"
        case "signInExpired": "(kirjautuminen vanhentunut)"
        case "tokenEndpoint": "(Googlen kirjautumispalvelu ei vastaa)"
        case "stateWriteFailed": "(tilaa ei voi tallentaa)"
        case "failed": "(virhe, katso daemon.log)"
        case "skipped": "(ohitettu)"
        case "paused": "(tauolla)"
        case "cancelled": "(keskeytetty)"
        case let other?: "(\(other))"
        case nil: ""
        }
    }
}
