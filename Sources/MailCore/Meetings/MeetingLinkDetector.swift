import Foundation

/// Video meeting services whose join links are highlighted.
public enum MeetingService: String, CaseIterable, Codable, Hashable, Sendable {
    case teams, zoom, googleMeet

    /// Full service name, as in the join button.
    public var displayName: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        }
    }

    /// Short text of the list row badge.
    public var badgeLabel: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Meet"
        }
    }

    /// Tooltip of the list row badge.
    public var badgeHelp: String { "Viestissä on \(compound("kokouslinkki"))" }

    /// The reading pane's join button.
    public var joinTitle: String { "Liity \(compound("kokoukseen"))" }

    /// Finnish compounds: "Teams-kokous", but "Google Meet -kokous" for a two-word name.
    private func compound(_ word: String) -> String {
        displayName.contains(" ") ? "\(displayName) -\(word)" : "\(displayName)-\(word)"
    }
}

public struct MeetingLink: Hashable, Sendable {
    public let service: MeetingService
    /// The meeting's own https URL, unwrapped from Safe Links and redirectors and rebuilt from
    /// its parts. Only `MeetingLinkDetector` creates these.
    public let url: URL

    init(service: MeetingService, url: URL) {
        self.service = service
        self.url = url
    }
}

/// Finds meeting join links in mail. Mail content is untrusted: a link counts only when, after
/// unwrapping, its host is exactly a known service host and its path is a join path. The result is
/// a rebuilt https URL (no userinfo, port or fragment), opened only when the user clicks.
///
/// Fork (seisemail). Pure classification, so the Phase 2 daemon can reuse it.
public enum MeetingLinkDetector {
    // MARK: - Bodies

    /// The link to join from: the newest message that has one wins.
    public static func primaryLink(in thread: MailThread) -> MeetingLink? {
        for message in thread.messages.reversed() {
            if let link = links(in: message).first { return link }
        }
        return nil
    }

    public static func links(in message: Message) -> [MeetingLink] {
        var found: [MeetingLink] = []
        if let html = message.htmlBody { found += links(inHTML: html) }
        if let text = message.textBody { found += links(inText: text) }
        return unique(found)
    }

    /// Hrefs and visible text alike: entities are decoded so `&amp;` in hrefs does not cut a URL.
    public static func links(inHTML html: String) -> [MeetingLink] {
        links(inText: HTMLText.decodeEntities(html))
    }

    public static func links(inText text: String) -> [MeetingLink] {
        var found: [MeetingLink] = []
        for match in text.matches(of: urlPattern) {
            guard let hit = match.output.1 ?? match.output.2 else { continue }
            let raw = trimTrailing(String(hit))
            let candidate = raw.lowercased().hasPrefix("http") ? raw : "https://" + raw
            if let url = URL(string: candidate), let link = classify(url) { found.append(link) }
        }
        return unique(found)
    }

    // MARK: - Row hint (subject and snippet, no API cost)

    /// Visible phrases of the services' invite templates. Snippets cut off before most URLs, and
    /// Outlook's Teams invites hide the URL behind "Join the meeting now".
    static let invitePhrases: [(phrase: String, service: MeetingService)] = [
        ("Join the meeting now", .teams),
        ("Liity kokoukseen nyt", .teams),
        ("Click here to join the meeting", .teams),
        ("Napsauta tätä liittyäksesi kokoukseen", .teams),
        // Only with the template's next line: "Microsoft Teams meeting" alone is plain conversation.
        ("Microsoft Teams meeting Join on your computer", .teams),
        ("Microsoft Teams -kokous Liity tietokoneella", .teams),
        ("Join Zoom Meeting", .zoom),
        ("Liity Zoom-kokoukseen", .zoom),
        ("Join with Google Meet", .googleMeet),
        ("Liity Google Meetillä", .googleMeet),
    ]

    /// A cheap guess for a list row: a join URL in the subject or snippet, else an invite phrase.
    /// Only a badge comes from this; the join button needs a link found in a body.
    public static func snippetHint(subject: String, snippet: String) -> MeetingService? {
        let text = HTMLText.decodeEntities(subject + "\n" + snippet)
        if let service = links(inText: text).first?.service { return service }
        let flat = text.replacing(/\s+/, with: " ")
        return invitePhrases.first { flat.range(of: $0.phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil }?.service
    }

    // MARK: - Gmail search (delivery B)

    /// Search terms per service. Gmail search sees an invite's visible text, not its href targets,
    /// so these are the invite templates' visible words. Matti checked each one against real
    /// invites in Gmail on the web on 2026-10-04.
    static func searchTerms(for service: MeetingService) -> String {
        switch service {
        case .teams: "(\"Join the meeting now\" OR \"Liity kokoukseen nyt\")"
        case .zoom: "\"zoom.us/j\""
        case .googleMeet: "\"meet.google.com\""
        }
    }

    /// The Gmail search for one service's invites within a list's own query (`scope`). The scope is
    /// grouped so an `OR` inside it cannot swallow the service terms.
    public static func searchQuery(service: MeetingService, scope: String) -> String {
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = searchTerms(for: service)
        return scope.isEmpty ? terms : "(\(scope)) \(terms)"
    }

    // MARK: - Opening

    /// The URL to hand to the browser, checked once more at the moment of the click: https, an
    /// allowlisted host and join path, and exactly what classification rebuilds. Anything else is nil.
    public static func openableURL(for link: MeetingLink) -> URL? {
        guard link.url.scheme == "https", let again = classify(link.url),
              again.service == link.service, again.url == link.url else { return nil }
        return again.url
    }

    // MARK: - URL classification

    public static func classify(_ url: URL) -> MeetingLink? {
        let target = unwrap(url)
        guard let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let c = URLComponents(url: target, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil,
              let host = c.host?.lowercased()
        else { return nil }
        let path = c.percentEncodedPath
        guard let service = service(host: host, path: path) else { return nil }
        // Rebuilt from the checked parts only: no userinfo, port or fragment survives.
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host
        clean.percentEncodedPath = path
        clean.percentEncodedQuery = c.percentEncodedQuery
        guard let rebuilt = clean.url, rebuilt.host() == host else { return nil }
        return MeetingLink(service: service, url: rebuilt)
    }

    /// Exact hosts (or subdomains of the Zoom domains only) and the services' join paths.
    static func service(host: String, path: String) -> MeetingService? {
        // The browser resolves "." and ".." (also as %2e) away, leaving the join path behind.
        guard !hasDotSegment(path) else { return nil }
        let p = path.lowercased()
        if ["teams.microsoft.com", "teams.cloud.microsoft", "gov.teams.microsoft.us", "dod.teams.microsoft.us"].contains(host),
           p.hasPrefix("/l/meetup-join/") || p.firstMatch(of: /^\/meet\/\d{6,}/) != nil {
            return .teams
        }
        if host == "teams.live.com", p.firstMatch(of: /^\/meet\/\d{6,}/) != nil || p.hasPrefix("/l/meetup-join/") {
            return .teams
        }
        if isHost(host, under: "zoom.us") || isHost(host, under: "zoomgov.com") {
            if p.firstMatch(of: /^\/(j|w|wc\/join)\/\d{9,11}(\/|$)/) != nil { return .zoom }
            if p.firstMatch(of: /^\/my\/[a-z0-9._-]+\/?$/) != nil { return .zoom }
        }
        if host == "meet.google.com", p.firstMatch(of: /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/) != nil {
            return .googleMeet
        }
        return nil
    }

    private static func hasDotSegment(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            return [segment, Substring(decoded)].contains { $0 == "." || $0 == ".." }
        }
    }

    /// `domain` itself or a DNS label chain under it, e.g. `us02web.zoom.us`.
    private static func isHost(_ host: String, under domain: String) -> Bool {
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Outlook Safe Links, Teams' own Safe Links page, Google's /url redirector and Proofpoint v3,
    /// up to three levels deep. Unwrapping never vouches for the target: it is classified afterwards.
    static func unwrap(_ url: URL, depth: Int = 0) -> URL {
        guard depth < 3, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https" || c.scheme?.lowercased() == "http",
              let host = c.host?.lowercased() else { return url }
        let items = c.queryItems ?? []
        func param(_ name: String) -> URL? {
            items.first { $0.name == name }?.value.flatMap(URL.init(string:))
        }
        var inner: URL?
        if host.hasSuffix(".safelinks.protection.outlook.com") {
            inner = param("url")
        } else if host == "statics.teams.cdn.office.net", c.path.hasSuffix("/atp-safelinks.html") {
            inner = param("url")
        } else if host == "www.google.com" || host == "google.com", c.path == "/url" {
            inner = param("q") ?? param("url")
        } else if host == "urldefense.com", c.percentEncodedPath.hasPrefix("/v3/__") {
            inner = proofpointV3Target(url.absoluteString)
        }
        guard let inner else { return url }
        return unwrap(inner, depth: depth + 1)
    }

    /// Proofpoint v3: `https://urldefense.com/v3/__<url>__;<base64>!!<signature>$`. Characters of
    /// `<url>` that Proofpoint rewrites (every `%` of a percent-escape, among others) are `*`, and
    /// `**X` is a run of them whose length `X` gives; the originals are, in order, the URL-safe
    /// base64 text after `__;`. Anything that does not add up is nil, so nothing is detected.
    static func proofpointV3Target(_ wrapped: String) -> URL? {
        guard let start = wrapped.range(of: "/v3/__"),
              let end = wrapped.range(of: "__;", range: start.upperBound..<wrapped.endIndex)
        else { return nil }
        let encoded = wrapped[end.upperBound...].prefix { $0 != "!" }
        var base64 = String(encoded).replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) else { return nil }
        let replacements = Array(decoded.unicodeScalars)
        var next = 0
        var url = String.UnicodeScalarView()
        var scalars = wrapped.unicodeScalars[start.upperBound..<end.lowerBound].makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "*" else { url.append(scalar); continue }
            var count = 1
            // "**X": a run; "*" followed by anything else is a single character.
            var lookahead = scalars
            if lookahead.next() == "*" {
                guard let code = lookahead.next(), let index = proofpointRunLengths.firstIndex(of: code) else { return nil }
                count = proofpointRunLengths.distance(from: proofpointRunLengths.startIndex, to: index) + 2
                scalars = lookahead
            }
            guard next + count <= replacements.count else { return nil }
            url.append(contentsOf: replacements[next..<next + count])
            next += count
        }
        guard next == replacements.count else { return nil }
        return URL(string: String(url))
    }

    /// Run lengths of `**X`: `A` is 2, `B` is 3, and so on.
    private static let proofpointRunLengths = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars

    // MARK: - Helpers

    /// Absolute URLs, plus scheme-less ones on the service hosts (snippets and plain text).
    /// Swift Regex has no lookbehind: the scheme-less branch consumes one boundary character.
    private static var urlPattern: Regex<(Substring, Substring?, Substring?)> { /(?i)(https?:\/\/[^\s<>"'`\[\]{}|\\^]+)|(?:^|[^\w.\/@-])((?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com)\/[^\s<>"'`\[\]{}|\\^]+)/ }

    private static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, ".,;:!?)>*".contains(last) { s = s.dropLast() }
        return String(s)
    }

    private static func unique(_ links: [MeetingLink]) -> [MeetingLink] {
        var seen = Set<URL>()
        return links.filter { seen.insert($0.url).inserted }
    }
}
