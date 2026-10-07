import Foundation

/// Which share of the per-user quota a request may use. Interactive requests are what the user is
/// waiting for right now; background requests are list and row loads, counts and polling.
public enum GmailLane: Sendable, Equatable {
    case interactive
    case background
}

/// Gmail quota units of a request, for meters outside the quota transport (the daemon's unit meter).
public enum GmailQuotaPrice {
    /// nil for a request that is not to the Gmail API host (OAuth token endpoint, …).
    public static func units(for request: URLRequest) -> Int? {
        GmailEndpoint(request)?.units
    }
}

/// One parse of a Gmail API request: its quota cost, its lane and what the read cache needs.
/// Costs are Google's per-method quota units (developers.google.com/workspace/gmail/api/reference/quota).
struct GmailEndpoint: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case threadList
        case threadGet(id: String, format: String)
        case threadWrite(id: String)
        case messageWrite
        case labelWrite
        case send
        case other
    }

    static let host = "gmail.googleapis.com"
    /// Charged for any request on the Gmail host that the table does not know.
    static let unknownCost = 40

    let kind: Kind
    let units: Int
    let lane: GmailLane

    init(kind: Kind, units: Int, lane: GmailLane) {
        self.kind = kind
        self.units = units
        self.lane = lane
    }

    /// nil for any other host (OAuth token endpoint, …): those are not metered.
    init?(_ request: URLRequest) {
        guard let url = request.url, url.host()?.lowercased() == Self.host else { return nil }
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = url.path()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rest: [Substring]
        if let range = path.range(of: "/users/me/") {
            rest = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
        } else {
            rest = []
        }
        let (kind, units) = Self.classify(method: method, rest: rest.map(String.init), items: items)
        var fullThread = false
        if case .threadGet(_, let format) = kind { fullThread = format == "full" }
        let interactive = method != "GET"
            || request.cachePolicy == .reloadIgnoringLocalCacheData
            || fullThread
            || (rest.count == 4 && rest[0] == "messages" && rest[2] == "attachments")
            || (rest.count >= 2 && rest[0] == "settings" && rest[1] == "sendAs")
        self.init(kind: kind, units: units, lane: interactive ? .interactive : .background)
    }

    private static func classify(method: String, rest: [String], items: [URLQueryItem]) -> (Kind, Int) {
        let unknown: (Kind, Int) = (.other, unknownCost)
        guard let first = rest.first else { return unknown }
        switch (method, first, rest.count) {
        case ("GET", "threads", 1):
            return (.threadList, 10)
        case ("GET", "threads", 2):
            // Gmail's default format is full.
            let format = items.first { $0.name == "format" }?.value ?? "full"
            return (.threadGet(id: rest[1], format: format), 40)
        case ("DELETE", "threads", 2):
            return (.threadWrite(id: rest[1]), 20)
        case ("POST", "threads", 3):
            switch rest[2] {
            case "modify", "untrash": return (.threadWrite(id: rest[1]), 10)
            case "trash": return (.threadWrite(id: rest[1]), 20)
            default: return unknown
            }
        case ("GET", "messages", 1):
            return (.other, 5)
        case ("POST", "messages", 1):
            // messages.insert (the daemon's expiry note). A new message in a new thread: no cached row to drop.
            return (.other, 25)
        case ("GET", "messages", 2):
            return (.other, 20)
        case ("GET", "messages", 4) where rest[2] == "attachments":
            return (.other, 20)
        case ("POST", "messages", 2):
            switch rest[1] {
            case "batchModify": return (.messageWrite, 50)
            case "send": return (.send, 100)
            default: return unknown
            }
        case ("POST", "messages", 3):
            switch rest[2] {
            case "modify": return (.messageWrite, 5)
            case "trash": return (.messageWrite, 20)
            default: return unknown
            }
        case ("GET", "labels", 1), ("GET", "labels", 2):
            return (.other, 1)
        case ("POST", "labels", 1), ("PUT", "labels", 2), ("PATCH", "labels", 2), ("DELETE", "labels", 2):
            return (.labelWrite, 5)
        case ("GET", "history", 1):
            return (.other, 2)
        case ("GET", "profile", 1):
            return (.other, 1)
        case ("GET", "settings", 2) where rest[1] == "sendAs":
            return (.other, 1)
        default:
            return unknown
        }
    }
}
