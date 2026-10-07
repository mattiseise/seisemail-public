import Foundation

/// A command-line mistake: printed with the help hint, exit 64 (design §15).
public struct UsageError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// `review [--since 24h] [--account a] [--rule id] [--summary]`
public struct ReviewQuery: Equatable, Sendable {
    public var since: String
    public var account: String?
    public var rule: String?
    public var summary: Bool

    public init(since: String = "24h", account: String? = nil, rule: String? = nil, summary: Bool = false) {
        self.since = since
        self.account = account
        self.rule = rule
        self.summary = summary
    }
}

/// `mak8r-daemon` argv (design §15). Hand-written parsing, no dependencies; `Mak8rDaemon` runs the result.
public enum DaemonCommand: Equatable, Sendable {
    public enum Feature: String, Sendable, CaseIterable {
        case wake, sorting
    }

    public enum OnceScope: Sendable, Equatable {
        case both, wake, sync
    }

    /// `requested`: asked for (`help`, `--help`, exit 0) rather than shown for an empty command line (exit 64).
    case help(requested: Bool)
    case run
    case login(email: String, noBrowser: Bool)
    case loginCallback(url: String)
    case logout(email: String)
    case status(json: Bool)
    case mode(Feature, FeatureMode)
    case initialize
    case rulesCheck
    case review(ReviewQuery)
    case explain(threadID: String, account: String?)
    case backfill(since: String, account: String?, dryRun: Bool)
    case once(account: String?, scope: OnceScope)
    case debugInvalidateToken(email: String)
    case debugNoteNow(email: String)

    public static func parse(_ arguments: [String]) throws(UsageError) -> DaemonCommand {
        guard let command = arguments.first else { return .help(requested: false) }
        var args = Args(Array(arguments.dropFirst()))
        switch command {
        case "help", "--help", "-h":
            return .help(requested: true)
        case "run":
            try args.end()
            return .run
        case "login":
            if let url = try args.value("--callback") {
                try args.end()
                return .loginCallback(url: url)
            }
            let noBrowser = args.flag("--no-browser")
            let email = try args.positional("login: anna sähköpostiosoite (login <osoite>)")
            try args.end()
            return .login(email: email, noBrowser: noBrowser)
        case "logout":
            let email = try args.positional("logout: anna sähköpostiosoite")
            try args.end()
            return .logout(email: email)
        case "status":
            let json = args.flag("--json")
            try args.end()
            return .status(json: json)
        case "mode":
            let featureText = try args.positional("mode: anna wake tai sorting ja tila (off, shadow, live)")
            guard let feature = Feature(rawValue: featureText) else {
                throw UsageError("mode: tuntematon toiminto \(featureText) (wake tai sorting)")
            }
            let modeText = try args.positional("mode: anna tila off, shadow tai live")
            guard let mode = FeatureMode(rawValue: modeText) else {
                throw UsageError("mode: tuntematon tila \(modeText) (off, shadow tai live)")
            }
            try args.end()
            return .mode(feature, mode)
        case "init":
            try args.end()
            return .initialize
        case "rules":
            let sub = try args.positional("rules: ainoa alikomento on check")
            guard sub == "check" else { throw UsageError("rules: tuntematon alikomento \(sub) (rules check)") }
            try args.end()
            return .rulesCheck
        case "review":
            var query = ReviewQuery()
            query.since = try args.value("--since") ?? query.since
            query.account = try args.value("--account")
            query.rule = try args.value("--rule")
            query.summary = args.flag("--summary")
            try args.end()
            return .review(query)
        case "explain":
            let account = try args.value("--account")
            let thread = try args.positional("explain: anna ketjun tunnus (explain <ketju>)")
            try args.end()
            return .explain(threadID: thread, account: account)
        case "backfill":
            let account = try args.value("--account")
            let dryRun = args.flag("--dry-run")
            guard let since = try args.value("--since") else {
                throw UsageError("backfill: --since puuttuu (esimerkiksi --since 3d tai --since 2026-10-01)")
            }
            try args.end()
            return .backfill(since: since, account: account, dryRun: dryRun)
        case "once":
            let account = try args.value("--account")
            let wake = args.flag("--wake")
            let sync = args.flag("--sync")
            try args.end()
            if wake && sync { throw UsageError("once: valitse --wake tai --sync, ei molempia") }
            return .once(account: account, scope: wake ? .wake : sync ? .sync : .both)
        case "debug":
            let sub = try args.positional("debug: anna invalidate-token tai note-now ja osoite")
            let email = try args.positional("debug \(sub): anna sähköpostiosoite")
            try args.end()
            switch sub {
            case "invalidate-token": return .debugInvalidateToken(email: email)
            case "note-now": return .debugNoteNow(email: email)
            default: throw UsageError("debug: tuntematon alikomento \(sub) (invalidate-token tai note-now)")
            }
        default:
            throw UsageError("tuntematon komento \(command)")
        }
    }

    /// Consumes options in any order; whatever is left over is an error.
    private struct Args {
        var rest: [String]

        init(_ rest: [String]) {
            self.rest = rest
        }

        mutating func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }

        mutating func value(_ name: String) throws(UsageError) -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else {
                throw UsageError("\(name) tarvitsee arvon")
            }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }

        mutating func positional(_ missing: String) throws(UsageError) -> String {
            guard let index = rest.firstIndex(where: { !$0.hasPrefix("--") }) else { throw UsageError(missing) }
            return rest.remove(at: index)
        }

        func end() throws(UsageError) {
            guard let extra = rest.first else { return }
            throw UsageError(extra.hasPrefix("--") ? "tuntematon valitsin \(extra)" : "ylimääräinen argumentti \(extra)")
        }
    }

    /// `mak8r-daemon help`
    public static let helpText = """
    mak8r-daemon: Mac minin postidaemon (torkkujen herätys ja lajittelu, docs/design/phase2-daemon.md)

    Käyttö: mak8r-daemon <komento> [valitsimet]

    Komennot:
      run                                  launchd-agentin käynnistys (make daemon-install); lukko varattu → 75
      login <osoite> [--no-browser]        kirjaudu Googleen; aja sandboxin ulkopuolella
      login --callback '<osoite>'          välitä puhelimen virhesivun osoite (http://127.0.0.1:…) odottavalle kirjautumiselle
      logout <osoite>                      poista tilin tokeni (ei peru kirjautumista Googlessa; tila säilyy)
      status [--json]                      daemonin tila; --json koneluettavana
      mode wake|sorting off|shadow|live    vaihda herätyksen tai lajittelun tila (daemon.json)
      init                                 luo daemon.json ja rules.json, jos niitä ei ole
      rules check                          tarkista rules.json ja näytä voimassa olevat säännöt
      review [--since 24h] [--account a] [--rule id] [--summary]
                                           lajittelupäätökset (decisions.jsonl)
      explain <ketju> [--account a]        lue ketju tuoreena ja näytä, miten säännöt sen ratkaisevat (ei kirjoita)
      backfill --since <Nd|VVVV-KK-PP> [--account a] [--dry-run]
                                           lajittele Saapuneiden ketjut annetusta päivästä nykyisessä tilassa
      once [--account a] [--wake|--sync]   yksi kierros etualalla (vain kun daemon ei ole käynnissä)
      debug invalidate-token <osoite>      korvaa tokeni roskalla (testaa vanhenemisen)
      debug note-now <osoite>              lisää kirjautumismuistutus Saapuneisiin nyt

    Poistumiskoodit: 0 kunnossa · 1 vaatii huomiota · 2 ei käynnissä · 64 käyttövirhe · 65 virheellinen tieto ·
                     69 ei käytettävissä (verkko, OAuth-asiakas, aikakatkaisu) · 75 lukko varattu ·
                     77 väärä tili, hylätty tai oikeus puuttuu

    Ympäristö: MAK8R_DAEMON_SUPPORT_DIR ja MAK8R_DAEMON_LOGS_DIR korvaavat kansiot
               ~/Library/Application Support/Mak8rMail ja ~/Library/Logs/Mak8rMail (testit);
               MAK8R_DAEMON_DEBUG=1 kirjoittaa debug-rivit lokiin.
    """
}
