import Foundation
import MailCore

/// Something Matti should hear about (design §11.3).
public enum DaemonEvent: Sendable, Equatable {
    case expiresSoon(account: String, expiresAt: Date, hours: Int)
    case needsLogin(account: String, since: Date, reminder: Bool)
    /// A new login while running (before expiry).
    case renewed(account: String, expiresAt: Date)
    /// A new login after needsLogin.
    case resumed(account: String, after: TimeInterval)
    case persistentError(account: String?, kind: String, since: Date)
    case safeMode(starts: Int)

    /// `MAK8R_EVENT`
    public var name: String {
        switch self {
        case .expiresSoon: "expiresSoon"
        case .needsLogin: "needsLogin"
        case .renewed: "renewed"
        case .resumed: "resumed"
        case .persistentError: "persistentError"
        case .safeMode: "safeMode"
        }
    }

    /// `MAK8R_ACCOUNT`
    public var account: String? {
        switch self {
        case .expiresSoon(let a, _, _), .needsLogin(let a, _, _), .renewed(let a, _), .resumed(let a, _): a
        case .persistentError(let a, _, _): a
        case .safeMode: nil
        }
    }

    /// The log level of the event's line.
    public var level: DaemonLog.Level {
        switch self {
        case .expiresSoon, .renewed, .resumed: .notice
        case .needsLogin, .persistentError, .safeMode: .error
        }
    }

    /// Whether the opt-in command hook hears it (design §11.3): everything but `renewed`, and `resumed`
    /// only after a pause over an hour.
    public var forHook: Bool {
        switch self {
        case .renewed: false
        case .resumed(_, let after): after > 3_600
        default: true
        }
    }

    /// `MAK8R_TEXT`: Finnish, no secrets.
    public func text(now: Date = Date()) -> String {
        switch self {
        case .expiresSoon(let account, let expiresAt, let hours):
            return "Postidaemonin kirjautuminen (\(account)) vanhenee \(FinnishTime.full(expiresAt, now: now)) "
                + "(\(hours) h). Kirjaudu uudelleen: mak8r-daemon login \(account)"
        case .needsLogin(let account, let since, let reminder):
            return (reminder ? "Muistutus: " : "")
                + "Postidaemonin kirjautuminen (\(account)) vanheni \(FinnishTime.full(since, now: now)). "
                + "Torkut ja lajittelu odottavat. Kirjaudu uudelleen: mak8r-daemon login \(account)"
        case .renewed(let account, let expiresAt):
            return "Postidaemonin kirjautuminen (\(account)) uusittu, voimassa \(FinnishTime.full(expiresAt, now: now)) asti."
        case .resumed(let account, let after):
            return "Postidaemon jatkaa tilillä \(account) \(Self.duration(after)) tauon jälkeen."
        case .persistentError(let account, let kind, let since):
            return "Postidaemonin virhe on jatkunut \(FinnishTime.full(since, now: now)) alkaen"
                + (account.map { " (\($0))" } ?? "") + ": \(Self.kindText(kind))."
        case .safeMode(let starts):
            return "Postidaemon käynnistyi \(starts) kertaa 10 minuutissa ilman hallittua pysäytystä: lajittelu pois päältä "
                + "(turvatila). Lajittelu jatkuu itsestään, kun daemon on pysynyt käynnissä 30 min. Katso daemon.log."
        }
    }

    static func kindText(_ kind: String) -> String {
        switch kind {
        case "offline": "ei verkkoyhteyttä"
        case "rateLimited": "Gmail rajoittaa kutsuja"
        case "tokenEndpoint": "Googlen kirjautumispalvelu ei vastaa oikein"
        case "stateWrite": "tilatiedostoa ei voi kirjoittaa, lajittelu pysäytetty"
        case "skew": "koneen kello poikkeaa Gmailin kellosta, siivous pois päältä"
        case "threads": "ketjujen käsittely epäonnistuu toistuvasti"
        case "oauthConfig": "OAuth-asiakas puuttuu"
        default: kind
        }
    }

    /// "3 h 5 min", "12 min"
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) vrk"
    }
}

/// Where events go: the log, the command hook (`Mak8rDaemon`), test recorders.
public protocol DaemonNotifier: Sendable {
    func post(_ e: DaemonEvent) async
}
