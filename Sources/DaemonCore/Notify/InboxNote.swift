import Foundation
import MailCore

/// The expiry reminder put into the inbox with `messages.insert` (design §11.3): never sent anywhere.
/// RFC 822, UTF-8 `text/plain`, From = To = the account, `X-Mak8r-Daemon: 1` (the sorter ignores it)
/// and `Auto-Submitted: auto-generated`. Labels INBOX and UNREAD.
public enum InboxNote {
    public static let labelIDs = [GmailLabel.inbox, GmailLabel.unread]

    /// "Mak8r-daemon: kirjaudu uudelleen ennen ma 12.10. klo 9.12"
    public static func subject(expiresAt: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        "Mak8r-daemon: kirjaudu uudelleen ennen \(shortDate(expiresAt, timeZone: timeZone))"
    }

    public static func body(account: String, expiresAt: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        """
        Mac minin postidaemonin Google-kirjautuminen vanhenee \(longDate(expiresAt, timeZone: timeZone))
        (OAuth-sovellus on testitilassa: kirjautuminen kestää 7 päivää).

        Mac minillä:   mak8r-daemon login \(account)
        Puhelimelta:   1) pyydä Claude Codea ajamaan taustalla (sandboxin ulkopuolella):
                          mak8r-daemon login \(account) --no-browser
                       2) avaa tulostettu linkki puhelimessa ja hyväksy
                       3) kopioi osoiteriviltä virhesivun osoite (http://127.0.0.1:…)
                       4) aja itse: mak8r-daemon login --callback '<osoite>'

        Daemon jatkaa itsestään minuutin kuluessa. Mitään ei menetetä: vanhenemisen jälkeen
        tulleet viestit käsitellään kirjautumisen jälkeen. Tämä viesti arkistoituu itsestään.

        """
    }

    /// The whole message, CRLF line ends, body base64 (UTF-8 survives every hop).
    public static func raw(account: String, expiresAt: Date, now: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> Data {
        let body = body(account: account, expiresAt: expiresAt, timeZone: timeZone)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let headers = [
            "From: \(account)",
            "To: \(account)",
            "Subject: \(EncodedWords.encode(subject(expiresAt: expiresAt, timeZone: timeZone)))",
            "Date: \(rfc5322Date(now))",
            "Message-ID: <mak8r-daemon-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased())@mak8r.local>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "\(DaemonHeaders.ownNote): 1",
            "Auto-Submitted: auto-generated",
        ]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + encoded + "\r\n").utf8)
    }

    /// "ma 12.10. klo 9.12"
    public static func shortDate(_ date: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let p = parts(date, timeZone)
        return "\(p.weekday) \(p.day).\(p.month). klo \(p.hour).\(String(format: "%02d", p.minute))"
    }

    /// "ma 12.10.2026 klo 9.12"
    public static func longDate(_ date: Date, timeZone: TimeZone = SnoozePresets.helsinki) -> String {
        let p = parts(date, timeZone)
        return "\(p.weekday) \(p.day).\(p.month).\(p.year) klo \(p.hour).\(String(format: "%02d", p.minute))"
    }

    private static func parts(_ date: Date, _ timeZone: TimeZone) -> (weekday: String, day: Int, month: Int, year: Int, hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute], from: date)
        // Calendar weekday: 1 = Sunday; FinnishTime.weekdays is ISO (Monday first).
        let iso = ((c.weekday ?? 2) + 5) % 7
        return (FinnishTime.weekdays[iso], c.day ?? 0, c.month ?? 0, c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `Tue, 06 Oct 2026 06:14:02 +0000`
    static func rfc5322Date(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute, .second], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d +0000", days[(c.weekday ?? 1) - 1], c.day ?? 1,
                      months[(c.month ?? 1) - 1], c.year ?? 1970, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
