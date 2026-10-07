import Foundation
import Testing
@testable import MailCore

@Suite struct GmailEndpointTests {
    static let api = "https://gmail.googleapis.com/gmail/v1/users/me/"

    static func request(_ method: String, _ path: String, policy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        let url = path.hasPrefix("https://") ? URL(string: path)! : URL(string: api + path)!
        var r = URLRequest(url: url, cachePolicy: policy)
        r.httpMethod = method
        return r
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var method: String
        var path: String
        var units: Int
        var testDescription: String { "\(method) \(path) = \(units)" }
    }

    /// The cost table in docs/design/gmail-quota.md §6 and docs/gmail-quota.md.
    static let table: [Row] = [
        Row(method: "GET", path: "threads?q=in:inbox&maxResults=50", units: 10),
        Row(method: "GET", path: "threads/t1?format=metadata", units: 40),
        Row(method: "GET", path: "threads/t1?format=full", units: 40),
        Row(method: "GET", path: "threads/t1?format=minimal", units: 40),
        Row(method: "POST", path: "threads/t1/modify", units: 10),
        Row(method: "POST", path: "threads/t1/trash", units: 20),
        Row(method: "POST", path: "threads/t1/untrash", units: 10),
        Row(method: "DELETE", path: "threads/t1", units: 20),
        Row(method: "GET", path: "messages?q=x", units: 5),
        Row(method: "GET", path: "messages/m1", units: 20),
        Row(method: "GET", path: "messages/m1/attachments/a1", units: 20),
        Row(method: "POST", path: "messages/m1/modify", units: 5),
        Row(method: "POST", path: "messages/m1/trash", units: 20),
        Row(method: "POST", path: "messages/batchModify", units: 50),
        Row(method: "POST", path: "messages", units: 25),                // messages.insert (daemon notes, V5)
        Row(method: "POST", path: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart", units: 100),
        Row(method: "GET", path: "labels", units: 1),
        Row(method: "GET", path: "labels/INBOX", units: 1),
        Row(method: "POST", path: "labels", units: 5),
        Row(method: "PUT", path: "labels/Label_1", units: 5),
        Row(method: "PATCH", path: "labels/Label_1", units: 5),
        Row(method: "DELETE", path: "labels/Label_1", units: 5),
        Row(method: "GET", path: "history?startHistoryId=1", units: 2),
        Row(method: "GET", path: "profile", units: 1),
        Row(method: "GET", path: "settings/sendAs", units: 1),
    ]

    @Test(arguments: table)
    func costTableMatchesDocumentation(_ row: Row) throws {
        let endpoint = try #require(GmailEndpoint(Self.request(row.method, row.path)))
        #expect(endpoint.units == row.units)
    }

    @Test func kindsForTheCache() throws {
        #expect(GmailEndpoint(Self.request("GET", "threads?q=x"))?.kind == .threadList)
        #expect(GmailEndpoint(Self.request("GET", "threads/t1?format=metadata"))?.kind == .threadGet(id: "t1", format: "metadata"))
        #expect(GmailEndpoint(Self.request("GET", "threads/t1"))?.kind == .threadGet(id: "t1", format: "full"))
        #expect(GmailEndpoint(Self.request("POST", "threads/t1/modify"))?.kind == .threadWrite(id: "t1"))
        #expect(GmailEndpoint(Self.request("POST", "threads/t1/trash"))?.kind == .threadWrite(id: "t1"))
        #expect(GmailEndpoint(Self.request("DELETE", "threads/t1"))?.kind == .threadWrite(id: "t1"))
        #expect(GmailEndpoint(Self.request("POST", "messages/batchModify"))?.kind == .messageWrite)
        #expect(GmailEndpoint(Self.request("POST", "messages/m1/modify"))?.kind == .messageWrite)
        #expect(GmailEndpoint(Self.request("POST", "labels"))?.kind == .labelWrite)
        #expect(GmailEndpoint(Self.request("POST", "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send"))?.kind == .send)
    }

    @Test func lanes() {
        func lane(_ method: String, _ path: String, _ policy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> GmailLane? {
            GmailEndpoint(Self.request(method, path, policy: policy))?.lane
        }
        #expect(lane("POST", "threads/t1/modify") == .interactive)
        #expect(lane("POST", "messages/batchModify") == .interactive)
        #expect(lane("DELETE", "labels/L") == .interactive)
        #expect(lane("GET", "threads/t1?format=full") == .interactive)
        #expect(lane("GET", "threads/t1") == .interactive)
        #expect(lane("GET", "messages/m1/attachments/a1") == .interactive)
        #expect(lane("GET", "settings/sendAs") == .interactive)
        #expect(lane("GET", "threads/t1?format=minimal", .reloadIgnoringLocalCacheData) == .interactive)

        #expect(lane("GET", "threads?q=x") == .background)
        #expect(lane("GET", "threads/t1?format=metadata") == .background)
        #expect(lane("GET", "threads/t1?format=minimal") == .background)
        #expect(lane("GET", "labels/INBOX") == .background)
        #expect(lane("GET", "profile") == .background)
    }

    @Test func unknownGmailEndpointCosts40() {
        #expect(GmailEndpoint(Self.request("GET", "settings/filters"))?.units == 40)
        #expect(GmailEndpoint(Self.request("POST", "threads/t1/frobnicate"))?.units == 40)
        #expect(GmailEndpoint(Self.request("GET", "https://gmail.googleapis.com/discovery"))?.units == 40)
    }

    @Test func nonGmailHostIsUnmetered() {
        #expect(GmailEndpoint(Self.request("POST", "https://oauth2.googleapis.com/token")) == nil)
        #expect(GmailEndpoint(Self.request("GET", "https://www.googleapis.com/oauth2/v3/userinfo")) == nil)
    }
}
