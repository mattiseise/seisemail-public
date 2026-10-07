import Foundation
import Testing
@testable import MailCore

/// `LiveGmailClient+Sync` (design §4): requests, decoding and error mapping of the daemon's endpoints.
@Suite struct LiveGmailClientSyncTests {
    func client(_ transport: StubTransport) -> LiveGmailClient {
        LiveGmailClient(auth: FakeTokens(), transport: transport, retry: RetryPolicy(delays: [], sleep: { _ in }))
    }

    func query(_ r: URLRequest) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }

    func path(_ r: URLRequest) -> String {
        r.url!.path().components(separatedBy: "/users/me/").last ?? ""
    }

    // MARK: profile

    @Test func profileCarriesHistoryID() async throws {
        let body = try Fixture.data("daemon_profile")
        let transport = StubTransport { _ in (200, body) }
        let profile = try await client(transport).profile()
        #expect(profile == GmailProfile(email: "matti@example.fi", historyID: "987654321"))
        #expect(path(transport.requests[0]) == "profile")
        #expect(transport.requests[0].httpMethod ?? "GET" == "GET")
    }

    @Test func profileEmailStillWorksWithHistoryIDInTheBody() async throws {
        let body = try Fixture.data("daemon_profile")
        let email = try await client(StubTransport { _ in (200, body) }).profileEmail()
        #expect(email == "matti@example.fi")
    }

    // MARK: history

    @Test func historyRequestsMessageAddedOnly() async throws {
        let body = try Fixture.data("daemon_history_added")
        let transport = StubTransport { _ in (200, body) }
        _ = try await client(transport).history(startHistoryID: "1000", pageToken: "p1", maxResults: 100)
        let r = transport.requests[0]
        let q = query(r)
        #expect(path(r) == "history")
        #expect(q["startHistoryId"] == ["1000"])
        #expect(q["historyTypes"] == ["messageAdded"])
        #expect(q["maxResults"] == ["100"])
        #expect(q["pageToken"] == ["p1"])
        #expect(q["labelId"] == nil)                        // D9: no labelId filter
    }

    @Test func historyFirstPageHasNoPageToken() async throws {
        let body = try Fixture.data("daemon_history_empty")
        let transport = StubTransport { _ in (200, body) }
        _ = try await client(transport).history(startHistoryID: "1000", pageToken: nil, maxResults: 100)
        #expect(query(transport.requests[0])["pageToken"] == nil)
    }

    @Test func historyDecodesAddedMessagesInRecordOrder() async throws {
        let body = try Fixture.data("daemon_history_added")
        let page = try await client(StubTransport { _ in (200, body) }).history(startHistoryID: "1000", pageToken: nil, maxResults: 100)
        #expect(page.added == [
            AddedMessage(id: "m1", threadID: "t1", labelIDs: ["UNREAD", "CATEGORY_UPDATES", "INBOX"]),
            AddedMessage(id: "m3", threadID: "t1", labelIDs: ["SENT"]),
            AddedMessage(id: "m4", threadID: "t3", labelIDs: nil),          // no hint: labels unknown
        ])
        #expect(page.lastRecordID == "1003")
        #expect(page.historyID == "1010")
        #expect(page.nextPageToken == "page-2")
    }

    @Test func emptyHistoryPage() async throws {
        let body = try Fixture.data("daemon_history_empty")
        let page = try await client(StubTransport { _ in (200, body) }).history(startHistoryID: "1000", pageToken: nil, maxResults: 100)
        #expect(page.added.isEmpty)
        #expect(page.lastRecordID == nil)
        #expect(page.historyID == "1010")
        #expect(page.nextPageToken == nil)
    }

    @Test func history404IsHistoryExpired() async throws {
        let body = try Fixture.data("daemon_history_404")
        let api = client(StubTransport { _ in (404, body) })
        await #expect(throws: GmailSyncError.historyExpired) {
            _ = try await api.history(startHistoryID: "1", pageToken: nil, maxResults: 100)
        }
    }

    @Test func otherHistoryErrorsStayGmailErrors() async throws {
        let api = client(StubTransport { _ in (400, Data("{}".utf8)) })
        await #expect(throws: GmailError.self) {
            _ = try await api.history(startHistoryID: "1", pageToken: nil, maxResults: 100)
        }
    }

    // MARK: threadHeaders

    @Test func threadHeadersIsAFreshMetadataRead() async throws {
        let body = try Fixture.data("daemon_thread_metadata_rules_newsletter")
        let transport = StubTransport { _ in (200, body) }
        _ = try await client(transport).threadHeaders(id: "t1", headers: ["From", "List-Id", "X-Mak8r-Daemon"])
        let r = transport.requests[0]
        #expect(path(r) == "threads/t1")
        #expect(query(r)["format"] == ["metadata"])
        #expect(query(r)["metadataHeaders"] == ["From", "List-Id", "X-Mak8r-Daemon"])
        #expect(r.cachePolicy == .reloadIgnoringLocalCacheData)            // always fresh (§4)
    }

    @Test func threadHeadersDecodesLowercasedHeadersOldestFirst() async throws {
        let body = try Fixture.data("daemon_thread_metadata_rules_newsletter")
        let thread = try await client(StubTransport { _ in (200, body) }).threadHeaders(id: "t1", headers: ["From"])
        #expect(thread.threadID == "t1")
        #expect(thread.historyID == "1009")
        #expect(thread.messages.map(\.id) == ["m1", "m2"])
        let m1 = thread.messages[0]
        #expect(m1.labelIDs == ["INBOX", "Label_7"])
        #expect(m1.internalDate == Date(timeIntervalSince1970: 1_791_100_000))
        #expect(m1.headers["list-id"] == ["<uutiset.lehti.fi>"])          // "List-ID" stored lowercased
        #expect(m1.headers["list-unsubscribe"] == ["<mailto:pois@lehti.fi>", "<https://lehti.fi/pois>"])
        #expect(m1.first("List-Id") == "<uutiset.lehti.fi>")
        #expect(m1.first("LIST-UNSUBSCRIBE") == "<mailto:pois@lehti.fi>")
        #expect(m1.first("Auto-Submitted") == nil)
        let m2 = thread.messages[1]
        #expect(m2.first("From") == "Uutiset <uutiset@lehti.fi>")         // sent as "from"
        #expect(m2.first("subject") == "Viikon uutiset 2")                // sent as "SUBJECT"
        #expect(thread.labelIDs == ["INBOX", "Label_7", "UNREAD"])
    }

    @Test func threadHeaders404StaysNotFound() async throws {
        let api = client(StubTransport { _ in (404, Data("{}".utf8)) })
        await #expect(throws: GmailError.self) { _ = try await api.threadHeaders(id: "gone", headers: ["From"]) }
    }

    // MARK: messages.list and messages.get

    @Test func listMessageIDs() async throws {
        let body = try Fixture.data("daemon_messages_list")
        let transport = StubTransport { _ in (200, body) }
        let page = try await client(transport).listMessageIDs(query: "in:sent newer_than:730d", pageToken: "p0", maxResults: 500)
        #expect(page == MessageIDPage(ids: ["s1", "s2"], nextPageToken: "next-1"))
        let r = transport.requests[0]
        #expect(path(r) == "messages")
        #expect(query(r)["q"] == ["in:sent newer_than:730d"])
        #expect(query(r)["maxResults"] == ["500"])
        #expect(query(r)["pageToken"] == ["p0"])
    }

    @Test func emptyMessageList() async throws {
        let page = try await client(StubTransport { _ in (200, Data("{\"resultSizeEstimate\":0}".utf8)) })
            .listMessageIDs(query: "in:sent", pageToken: nil, maxResults: 500)
        #expect(page == MessageIDPage(ids: [], nextPageToken: nil))
    }

    @Test func messageHeaders() async throws {
        let body = try Fixture.data("daemon_message_metadata_sent")
        let transport = StubTransport { _ in (200, body) }
        let message = try await client(transport).messageHeaders(id: "s1", headers: ["To", "Cc"])
        let r = transport.requests[0]
        #expect(path(r) == "messages/s1")
        #expect(query(r)["format"] == ["metadata"])
        #expect(query(r)["metadataHeaders"] == ["To", "Cc"])
        #expect(message.id == "s1")
        #expect(message.labelIDs == ["SENT"])
        #expect(message.first("to") == "\"Virtanen, Matti\" <Matti.Virtanen@x.fi>, anna@example.fi")
        #expect(message.first("CC") == "kalle@x.fi (Kalle)")
    }

    // MARK: messages.insert

    /// The note is archived with `threads.modify`, so the caller stores the thread id.
    @Test func insertMessageReturnsTheThreadID() async throws {
        let transport = StubTransport { _ in (200, Data(#"{"id": "m7", "threadId": "t7", "labelIds": ["INBOX"]}"#.utf8)) }
        #expect(try await client(transport).insertMessage(raw: Data("Subject: x\r\n\r\ny".utf8), labelIDs: ["INBOX"]) == "t7")
    }

    @Test func insertMessageSendsRawAndLabels() async throws {
        let body = try Fixture.data("daemon_insert_response")
        let transport = StubTransport { _ in (200, body) }
        let raw = Data("From: matti@example.fi\r\nTo: matti@example.fi\r\nSubject: x\r\nX-Mak8r-Daemon: 1\r\n\r\nä?\r\n".utf8)
        let id = try await client(transport).insertMessage(raw: raw, labelIDs: ["INBOX", "UNREAD"])
        #expect(id == "n1")
        let r = transport.requests[0]
        #expect(r.httpMethod == "POST")
        #expect(path(r) == "messages")
        #expect(r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let sent = try #require(try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect(sent["labelIds"] as? [String] == ["INBOX", "UNREAD"])
        let encoded = try #require(sent["raw"] as? String)
        #expect(!encoded.contains("+") && !encoded.contains("/"))           // base64url
        #expect(Base64URL.decode(encoded) == raw)
    }

    @Test func insertIsPricedLikeGmail() throws {
        var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!)
        r.httpMethod = "POST"
        #expect(GmailEndpoint(r)?.units == 25)                             // V5: was unknownCost 40
        #expect(GmailQuotaPrice.units(for: r) == 25)
    }

    // MARK: Labels

    @Test func chatAndMarkerConstants() {
        #expect(SeiseLabels.chat == "CHAT")
        #expect(SeiseLabels.Sorting.classifiedMarker == "Lajittelu/Luokiteltu")
        #expect(!SeiseLabels.Sorting.all.contains(SeiseLabels.Sorting.classifiedMarker))   // app views unchanged
    }

    @Test func logsDirectory() {
        #expect(AppPaths.logsDirectory.path().hasSuffix("Library/Logs/Mak8rMail") ||
                AppPaths.logsDirectory.path().hasSuffix("Library/Logs/Mak8rMail/"))
    }
}
