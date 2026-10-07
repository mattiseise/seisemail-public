import Foundation
import Synchronization
import Testing
@testable import MailCore

final class FakeTokens: AccessTokenProvider {
    private let token = Mutex("t0")
    let refreshes = Counter()
    func accessToken() async throws -> String { token.withLock { $0 } }
    func refreshAfterUnauthorized() async throws -> String {
        refreshes.increment()
        return token.withLock { $0 = "t\(refreshes.count)"; return $0 }
    }
}

@Suite struct LiveGmailClientTests {
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

    @Test func listThreadsBuildsQuery() async throws {
        let transport = StubTransport { _ in (200, json(["threads": [["id": "a"], ["id": "b"]], "nextPageToken": "p2", "resultSizeEstimate": 42])) }
        let page = try await client(transport).listThreads(query: "in:inbox is:unread", pageToken: "p1", maxResults: 50)
        #expect(page.ids == ["a", "b"])
        #expect(page.nextPageToken == "p2")
        #expect(page.estimate == 42)
        let r = transport.requests[0]
        #expect(r.url?.path == "/gmail/v1/users/me/threads")
        #expect(query(r)["q"] == ["in:inbox is:unread"])
        #expect(query(r)["pageToken"] == ["p1"])
        #expect(query(r)["maxResults"] == ["50"])
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t0")
    }

    @Test func emptyListHasNoThreads() async throws {
        let transport = StubTransport { _ in (200, json(["resultSizeEstimate": 0])) }
        let page = try await client(transport).listThreads(query: "x", pageToken: nil, maxResults: 50)
        #expect(page.ids.isEmpty && page.nextPageToken == nil)
        #expect(query(transport.requests[0])["pageToken"] == nil)
    }

    @Test func threadSummaryRequestsMetadataHeaders() async throws {
        let fixture = try Fixture.data("thread_metadata")
        let transport = StubTransport { _ in (200, fixture) }
        let summary = try await client(transport).threadSummary(id: "t1", me: "maija.meikalainen@gmail.com")
        #expect(summary.id == "t1")
        let q = query(transport.requests[0])
        #expect(transport.requests[0].url?.path == "/gmail/v1/users/me/threads/t1")
        #expect(q["format"] == ["metadata"])
        #expect(Set(q["metadataHeaders"] ?? []) == ["From", "Subject", "Date", "Content-Type"])
    }

    @Test func fullThreadIsParsed() async throws {
        let fixture = try Fixture.data("thread_full_multipart")
        let transport = StubTransport { _ in (200, fixture) }
        let thread = try await client(transport).thread(id: "t1")
        #expect(thread.messages.count == 2)
        #expect(query(transport.requests[0])["format"] == ["full"])
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        let transport = StubTransport { r in
            r.value(forHTTPHeaderField: "Authorization") == "Bearer t0" ? (401, Data()) : (200, json(["emailAddress": "me@x.fi"]))
        }
        #expect(try await client(transport).profileEmail() == "me@x.fi")
        #expect(tokens.refreshes.count == 1)
        #expect(transport.requests.count == 2)
    }

    @Test func retriesRateLimitThenSucceeds() async throws {
        let calls = Counter()
        let transport = StubTransport { _ in
            calls.increment()
            return calls.count <= 2 ? (429, Data()) : (200, json(["emailAddress": "me@x.fi"]))
        }
        #expect(try await client(transport).profileEmail() == "me@x.fi")
        #expect(sleeps.count == 2)
    }

    @Test func givesUpAfterThreeRetries() async {
        let transport = StubTransport { _ in (500, Data("boom".utf8)) }
        await #expect(throws: GmailError.http(500, "boom")) { try await client(transport).profileEmail() }
        #expect(transport.requests.count == 4)
    }

    @Test func clientErrorIsNotRetried() async {
        let transport = StubTransport { _ in (404, Data("nope".utf8)) }
        await #expect(throws: GmailError.http(404, "nope")) { try await client(transport).thread(id: "x") }
        #expect(transport.requests.count == 1)
    }

    @Test func offlineMapsToOfflineError() async {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: GmailError.offline) { try await client(transport).profileEmail() }
    }

    @Test func modifyPostsLabelChanges() async throws {
        let transport = StubTransport { _ in (200, json([:])) }
        try await client(transport).modify(threadID: "t1", add: ["STARRED"], remove: ["INBOX"])
        let r = transport.requests[0]
        #expect(r.httpMethod == "POST")
        #expect(r.url?.path == "/gmail/v1/users/me/threads/t1/modify")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [String]]
        #expect(body == ["addLabelIds": ["STARRED"], "removeLabelIds": ["INBOX"]])
    }

    @Test func trashAndUntrash() async throws {
        let transport = StubTransport { _ in (200, json([:])) }
        try await client(transport).trash(threadID: "t1")
        try await client(transport).untrash(threadID: "t1")
        #expect(transport.requests.map { $0.url!.path } == ["/gmail/v1/users/me/threads/t1/trash", "/gmail/v1/users/me/threads/t1/untrash"])
    }

    @Test func sendUsesMultipartUploadWithThreadID() async throws {
        let transport = StubTransport { _ in (200, json(["id": "new"])) }
        try await client(transport).send(raw: Data("Subject: Hei\r\n\r\nMoi".utf8), threadID: "t9")
        let r = transport.requests[0]
        #expect(r.url?.absoluteString == "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")
        let contentType = try #require(r.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/related; boundary="))
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(body.contains("{\"threadId\":\"t9\"}"))
        #expect(body.contains("Content-Type: message/rfc822\r\n\r\nSubject: Hei\r\n\r\nMoi"))
    }

    @Test func sendWithoutThreadHasEmptyMetadata() async throws {
        let transport = StubTransport { _ in (200, json(["id": "new"])) }
        try await client(transport).send(raw: Data("x".utf8), threadID: nil)
        #expect(String(decoding: transport.requests[0].httpBody!, as: UTF8.self).contains("\r\n\r\n{}\r\n"))
    }

    @Test func attachmentDataIsDecoded() async throws {
        let transport = StubTransport { _ in (200, json(["size": 2, "data": Base64URL.encode(Data([0xFF, 0xFE]))])) }
        let data = try await client(transport).attachmentData(messageID: "m1", attachmentID: "a1")
        #expect(data == Data([0xFF, 0xFE]))
        #expect(transport.requests[0].url?.path == "/gmail/v1/users/me/messages/m1/attachments/a1")
    }

    @Test func unreadCounts() async throws {
        let transport = StubTransport { r in
            r.url!.path.hasSuffix("/labels/INBOX") ? (200, json(["id": "INBOX", "threadsUnread": 7])) : (200, json(["resultSizeEstimate": 3]))
        }
        #expect(try await client(transport).inboxUnreadCount() == 7)
        #expect(try await client(transport).unreadEstimate(query: "is:starred") == 0)
        #expect(query(transport.requests[1])["q"] == ["is:starred is:unread"])
    }

    @Test func unreadCountIsExactWhenItFitsOnOnePage() async throws {
        let one = StubTransport { _ in (200, json(["threads": [["id": "a"], ["id": "b"]], "resultSizeEstimate": 5])) }
        #expect(try await client(one).unreadEstimate(query: "x") == 2)
        let many = StubTransport { _ in (200, json(["threads": [["id": "a"]], "nextPageToken": "p", "resultSizeEstimate": 250])) }
        #expect(try await client(many).unreadEstimate(query: "x") == 250)
    }

    @Test func offlineDuringTokenRefreshMapsToOffline() async {
        struct OfflineAuth: AccessTokenProvider {
            func accessToken() async throws -> String { throw URLError(.notConnectedToInternet) }
            func refreshAfterUnauthorized() async throws -> String { throw URLError(.notConnectedToInternet) }
        }
        let client = LiveGmailClient(auth: OfflineAuth(), transport: StubTransport { _ in (200, Data()) },
                                     retry: RetryPolicy(delays: [], sleep: { _ in }))
        await #expect(throws: GmailError.offline) { try await client.profileEmail() }
    }

    @Test func sendIsNotRetriedOnServerError() async {
        let transport = StubTransport { _ in (502, Data("bad gateway".utf8)) }
        await #expect(throws: GmailError.self) { try await client(transport).send(raw: Data("x".utf8), threadID: nil) }
        #expect(transport.requests.count == 1)
    }

    @Test func sendIsRetriedOnRateLimit() async throws {
        let calls = Counter()
        let transport = StubTransport { _ in
            calls.increment()
            return calls.count == 1 ? (429, Data()) : (200, json(["id": "x"]))
        }
        try await client(transport).send(raw: Data("x".utf8), threadID: nil)
        #expect(transport.requests.count == 2)
    }

    // Fork (seisemail): background searches (meeting badges) have their own backoff.
    @Test(arguments: [429, 500, 503])
    func listThreadsOnceDoesNotRetryRateLimitOrServerErrors(_ status: Int) async {
        let transport = StubTransport { _ in (status, Data("limit".utf8)) }
        await #expect(throws: GmailError.http(status, "limit")) {
            try await client(transport).listThreadsOnce(query: "in:inbox", pageToken: nil, maxResults: 500)
        }
        #expect(transport.requests.count == 1)
        #expect(sleeps.count == 0)
    }

    @Test func listThreadsOnceStillRefreshesAnExpiredToken() async throws {
        let transport = StubTransport { r in
            r.value(forHTTPHeaderField: "Authorization") == "Bearer t0" ? (401, Data()) : (200, json(["threads": [["id": "a"]]]))
        }
        let page = try await client(transport).listThreadsOnce(query: "in:inbox", pageToken: nil, maxResults: 500)
        #expect(page.ids == ["a"])
        #expect(query(transport.requests[1])["q"] == ["in:inbox"])
        #expect(query(transport.requests[1])["maxResults"] == ["500"])
        #expect(transport.requests.count == 2)
    }

    @Test func sendAsSignatures() async throws {
        let transport = StubTransport { _ in (200, json(["sendAs": [
            ["sendAsEmail": "maija@example.fi", "signature": "<b>S</b>"],
            ["sendAsEmail": "alias@example.fi"],
        ]])) }
        let list = try await client(transport).sendAsSignatures()
        #expect(list == [SendAsSignature(email: "maija@example.fi", html: "<b>S</b>"), SendAsSignature(email: "alias@example.fi", html: "")])
        #expect(transport.requests[0].url?.path == "/gmail/v1/users/me/settings/sendAs")
    }
}
