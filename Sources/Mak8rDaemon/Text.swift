import DaemonCore
import Foundation
import MailCore

/// The CLI's own Finnish strings (the reports' text lives with them in DaemonCore, where it is tested).
enum Text {
    static let helpHint = "Ohje: mak8r-daemon help"

    /// Shown with the consent URL (stdout only, never the log). `pasteOnly`: no loopback listener runs.
    static func consent(_ url: URL, pasteOnly: Bool, browser: Bool) -> String {
        var lines = [
            browser ? "Selain avaa Googlen kirjautumissivun. Jos selain ei avaudu, avaa tämä osoite ja hyväksy pyyntö:"
                : "Avaa tämä osoite selaimessa (esimerkiksi puhelimessa) ja hyväksy pyyntö:",
            "",
            url.absoluteString,
            "",
        ]
        if pasteOnly {
            lines += [
                "Paikallinen vastaanotin ei käynnistynyt. Hyväksynnän jälkeen selain päätyy virhesivulle",
                "(http://127.0.0.1:…). Kopioi sivun osoite, liitä se tähän ja paina rivinvaihtoa.",
            ]
        } else {
            lines += [
                "Jos hyväksyt puhelimella, selain päätyy lopuksi virhesivulle (http://127.0.0.1:…).",
                "Kopioi osoiteriviltä sivun osoite ja aja Mac minillä 10 minuutin kuluessa:",
                "  mak8r-daemon login --callback '<osoite>'",
                "tai liitä osoite tähän ja paina rivinvaihtoa.",
            ]
        }
        lines.append("Odotetaan enintään 10 minuuttia…")
        return lines.joined(separator: "\n")
    }

    static func loginSaved(_ token: StoredToken, now: Date) -> String {
        "Kirjautuminen on voimassa \(FinnishTime.full(token.expiresAt, now: now)) asti (7 vrk, koska OAuth-sovellus on testitilassa)."
    }

    enum DaemonState {
        case running, installedNotRunning, notInstalled
    }

    static func afterLogin(_ state: DaemonState) -> String {
        switch state {
        case .running: "Daemon jatkaa minuutin kuluessa."
        case .installedNotRunning: "Daemon jatkaa minuutin kuluessa, kun se on käynnissä (make daemon-status)."
        case .notInstalled: "Daemonia ei ole asennettu. Asenna se: make daemon-install"
        }
    }

    static let callbackForwarded = "Osoite välitetty odottavalle kirjautumiselle. Tulos näkyy sen ikkunassa."

    static let lockHeldOnce = """
    Daemon on käynnissä (lukko on varattu), joten once-komentoa ei ajeta. Pysäytä daemon ensin \
    (launchctl bootout gui/$(id -u)/fi.seise.mail.daemon) tai käytä mak8r-daemon status. \
    Käynnistä se sen jälkeen uudelleen: make daemon-install \
    (tai launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/fi.seise.mail.daemon.plist).
    """

    static func oauthMissing() -> String { LoginError.oauthMissing.message }
}
