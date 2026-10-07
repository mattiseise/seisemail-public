import Foundation
import Testing
@testable import MailCore

@Suite struct BatchModifyTests {
    func client(_ transport: StubTransport) -> LiveGmailClient {
        LiveGmailClient(auth: FakeTokens(), transport: transport, retry: RetryPolicy(delays: [], sleep: { _ in }))
    }

    @Test func postsIdsAndLabels() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        try await client(transport).batchModify(messageIDs: ["m1", "m2"], add: ["STARRED"], remove: ["INBOX"])
        let r = try #require(transport.requests.first)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.path == "/gmail/v1/users/me/messages/batchModify")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode(BatchModifyDTO.self, from: try #require(r.httpBody))
        #expect(body.ids == ["m1", "m2"])
        #expect(body.addLabelIds == ["STARRED"])
        #expect(body.removeLabelIds == ["INBOX"])
    }

    @Test func splitsAtGmailsLimit() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        let ids = (0..<2_500).map { "m\($0)" }
        try await client(transport).batchModify(messageIDs: ids, add: [], remove: ["UNREAD"])
        let sizes = try transport.requests.map { try JSONDecoder().decode(BatchModifyDTO.self, from: $0.httpBody!).ids.count }
        #expect(sizes == [1_000, 1_000, 500])
    }

    @Test func costs50InteractiveUnits() {
        var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/batchModify")!)
        r.httpMethod = "POST"
        #expect(GmailEndpoint(r) == GmailEndpoint(kind: .messageWrite, units: 50, lane: .interactive))
    }

    @Test func summaryCarriesMessageIDs() throws {
        let summary = MessageParser.summary(try Fixture.thread("thread_metadata"), me: nil)
        #expect(summary.messageIDs == ["m1", "m2"])
    }
}
