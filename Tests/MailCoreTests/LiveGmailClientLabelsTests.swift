import Foundation
import Testing
@testable import MailCore

@Suite struct LiveGmailClientLabelsTests {
    let tokens = FakeTokens()
    let sleeps = Counter()

    func client(_ transport: StubTransport) -> LiveGmailClient {
        let sleeps = self.sleeps
        return LiveGmailClient(auth: tokens, transport: transport,
                               retry: RetryPolicy(delays: [.milliseconds(500), .seconds(1), .seconds(2)], sleep: { _ in sleeps.increment() }))
    }

    func query(_ r: URLRequest) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }

    func body(_ r: URLRequest) throws -> [String: String] {
        let data = try #require(r.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    static let created = ["id": "Label_9", "name": "Torkku/20261005T0600Z", "type": "user",
                          "labelListVisibility": "labelHide", "messageListVisibility": "hide"]

    // MARK: - labels.list

    @Test func listLabelsDecodes() async throws {
        let fixture = try Fixture.data("labels_list")
        let transport = StubTransport { _ in (200, fixture) }
        let labels = try await client(transport).listLabels()
        #expect(labels == [
            GmailLabelInfo(id: "INBOX", name: "INBOX", kind: .system),
            GmailLabelInfo(id: "TRASH", name: "TRASH", kind: .system),
            GmailLabelInfo(id: "Label_1", name: "Torkku", kind: .user),
            GmailLabelInfo(id: "Label_2", name: "Torkku/20261005T0500Z", kind: .user),
            GmailLabelInfo(id: "Label_3", name: "Lajittelu/Vaatii toimenpidettä", kind: .user),   // no "type" → user
        ])
        let r = transport.requests[0]
        #expect(r.httpMethod == "GET")
        #expect(r.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t0")
        #expect(r.httpBody == nil)
    }

    @Test func listLabelsEmptyObject() async throws {
        let transport = StubTransport { _ in (200, json([:])) }
        #expect(try await client(transport).listLabels() == [])
    }

    @Test func labels401RefreshesOnce() async throws {
        let transport = StubTransport { r in
            r.value(forHTTPHeaderField: "Authorization") == "Bearer t0" ? (401, Data()) : (200, json(["labels": [["id": "INBOX", "name": "INBOX", "type": "system"]]]))
        }
        #expect(try await client(transport).listLabels() == [GmailLabelInfo(id: "INBOX", name: "INBOX", kind: .system)])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        #expect(tokens.refreshes.count == 1)
    }

    // MARK: - labels.create

    @Test func createLabelPostsJSON() async throws {
        let transport = StubTransport { _ in (200, json(Self.created)) }
        let label = try await client(transport).createLabel(name: "Torkku/20261005T0600Z", visibility: .hidden)
        #expect(label == GmailLabelInfo(id: "Label_9", name: "Torkku/20261005T0600Z", kind: .user))
        let r = transport.requests[0]
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try body(r) == ["name": "Torkku/20261005T0600Z", "labelListVisibility": "labelHide", "messageListVisibility": "hide"])
    }

    @Test func createLabelShownVisibility() async throws {
        let transport = StubTransport { _ in (200, json(["id": "Label_1", "name": "Torkku", "type": "user"])) }
        _ = try await client(transport).createLabel(name: "Torkku", visibility: .shown)
        #expect(try body(transport.requests[0]) == ["name": "Torkku", "labelListVisibility": "labelShow", "messageListVisibility": "show"])
    }

    @Test func createLabelUnicodeName() async throws {
        let name = "Lajittelu/Vaatii toimenpidettä"
        let transport = StubTransport { _ in (200, json(["id": "Label_3", "name": name])) }
        let label = try await client(transport).createLabel(name: name, visibility: .shown)
        #expect(try body(transport.requests[0])["name"] == name)
        #expect(label == GmailLabelInfo(id: "Label_3", name: name, kind: .user))
    }

    @Test func createLabel409NotRetried() async {
        let transport = StubTransport { _ in (409, Data("Label name exists or conflicts".utf8)) }
        await #expect(throws: GmailError.http(409, "Label name exists or conflicts")) {
            try await client(transport).createLabel(name: "Torkku", visibility: .shown)
        }
        #expect(transport.requests.count == 1)
        #expect(sleeps.count == 0)
    }

    @Test func createLabelRetries5xx() async throws {
        let calls = Counter()
        let transport = StubTransport { _ in
            calls.increment()
            return calls.count <= 2 ? (500, Data()) : (200, json(Self.created))
        }
        let label = try await client(transport).createLabel(name: "Torkku/20261005T0600Z", visibility: .hidden)
        #expect(label.id == "Label_9")
        #expect(transport.requests.count == 3)
        #expect(sleeps.count == 2)
    }

    @Test func createLabel500Then409() async {
        // The first create may have succeeded server-side; the retry then sees the name taken. LabelDirectory adopts it.
        let calls = Counter()
        let transport = StubTransport { _ in
            calls.increment()
            return calls.count == 1 ? (500, Data()) : (409, Data("exists".utf8))
        }
        await #expect(throws: GmailError.http(409, "exists")) {
            try await client(transport).createLabel(name: "Torkku", visibility: .shown)
        }
        #expect(transport.requests.count == 2)
    }

    @Test func createLabelBadJSONIsDecodingError() async {
        let transport = StubTransport { _ in (200, Data("x".utf8)) }
        await #expect(throws: GmailError.decoding) { try await client(transport).createLabel(name: "Torkku", visibility: .shown) }
    }

    // MARK: - labels.delete

    @Test func deleteLabelSendsDELETE() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        try await client(transport).deleteLabel(id: "Label_7")
        let r = transport.requests[0]
        #expect(r.httpMethod == "DELETE")
        #expect(r.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/labels/Label_7")
        #expect(r.httpBody == nil)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t0")
        let ok = StubTransport { _ in (200, Data("{}".utf8)) }
        try await client(ok).deleteLabel(id: "Label_7")
        #expect(ok.requests.count == 1)
    }

    @Test func deleteLabel404Throws() async {
        let transport = StubTransport { _ in (404, Data("Not Found".utf8)) }
        await #expect(throws: GmailError.http(404, "Not Found")) { try await client(transport).deleteLabel(id: "Label_7") }
        #expect(transport.requests.count == 1)
    }

    // MARK: - threads.list by label ID

    @Test func listThreadIDsQuery() async throws {
        let transport = StubTransport { _ in
            (200, json(["threads": [["id": "a", "historyId": "1"]], "nextPageToken": "p2", "resultSizeEstimate": 3]))
        }
        let page = try await client(transport).listThreadIDs(labelIDs: ["Label_1", "INBOX"], includeSpamTrash: true,
                                                             pageToken: "p1", maxResults: 500)
        #expect(page == ThreadPage(ids: ["a"], nextPageToken: "p2", estimate: 3))
        let r = transport.requests[0]
        #expect(r.httpMethod == "GET")
        #expect(r.url?.path == "/gmail/v1/users/me/threads")
        let q = query(r)
        #expect(q["labelIds"] == ["Label_1", "INBOX"])
        #expect(q["includeSpamTrash"] == ["true"])
        #expect(q["maxResults"] == ["500"])
        #expect(q["pageToken"] == ["p1"])
        #expect(q["q"] == nil)
        #expect(Set(q.keys) == ["labelIds", "includeSpamTrash", "maxResults", "pageToken"])
    }

    @Test func listThreadIDsDefaultsAndClamp() async throws {
        let transport = StubTransport { _ in (200, json(["resultSizeEstimate": 0])) }
        let page = try await client(transport).listThreadIDs(labelIDs: ["Label_1"], includeSpamTrash: false,
                                                             pageToken: nil, maxResults: 1000)
        #expect(page == ThreadPage(ids: [], nextPageToken: nil, estimate: 0))
        let q = query(transport.requests[0])
        #expect(q["includeSpamTrash"] == nil)
        #expect(q["pageToken"] == nil)
        #expect(q["maxResults"] == ["500"])
        #expect(q["labelIds"] == ["Label_1"])
        _ = try await client(transport).listThreadIDs(labelIDs: ["Label_1"], includeSpamTrash: false, pageToken: nil, maxResults: 0)
        #expect(query(transport.requests[1])["maxResults"] == ["1"])
    }

    // MARK: - threads.get?format=minimal

    @Test func threadLabelsMinimal() async throws {
        let fixture = try Fixture.data("thread_minimal_snoozed")
        let transport = StubTransport { _ in (200, fixture) }
        let labels = try await client(transport).threadLabels(id: "t1")
        let r = transport.requests[0]
        #expect(r.url?.path == "/gmail/v1/users/me/threads/t1")
        #expect(query(r) == ["format": ["minimal"]])
        #expect(labels == ThreadLabels(threadID: "t1", messageLabelIDs: [["Label_1", "Label_2"], ["INBOX", "UNREAD"]], historyID: "987654"))
        #expect(labels.labelIDs == ["Label_1", "Label_2", "INBOX", "UNREAD"])
    }

    @Test func threadLabelsWithoutLabelIDs() async throws {
        let transport = StubTransport { _ in (200, json(["id": "t2", "messages": [["id": "m1", "threadId": "t2"]]])) }
        let labels = try await client(transport).threadLabels(id: "t2")
        #expect(labels == ThreadLabels(threadID: "t2", messageLabelIDs: [[]], historyID: nil))
        #expect(labels.labelIDs.isEmpty)
    }

    @Test func threadLabels404Throws() async {
        let transport = StubTransport { _ in (404, Data("gone".utf8)) }
        await #expect(throws: GmailError.http(404, "gone")) { try await client(transport).threadLabels(id: "t9") }
        #expect(transport.requests.count == 1)
    }

    @Test func liveClientIsALabelsAPI() {
        let api: any GmailAPI = client(StubTransport { _ in (200, Data()) })
        #expect(api is any GmailLabelsAPI)
    }
}
