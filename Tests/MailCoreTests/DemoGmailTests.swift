import Foundation
import Testing
@testable import MailCore

/// The screenshot account answers the app's own queries the way Gmail would.
@Suite struct DemoGmailTests {
    let now = D(1_791_363_600)                                                      // ke 7.10.2026 12.00

    func demo() -> DemoGmail { DemoGmail(now: now, writeDelay: .zero) }

    @Test func viewsSeeTheirThreads() async throws {
        let g = demo()
        #expect(try await g.listThreads(query: InboxZero.defaultQuery, pageToken: nil, maxResults: 50).ids
            == ["d01", "d02", "d03", "d04", "d05", "d06", "d07"])                  // newest first, sorted mail out
        #expect(try await g.listThreads(query: "in:inbox", pageToken: nil, maxResults: 50).ids.count == 9)
        #expect(Set(try await g.listThreads(query: SnoozeLabelScheme.standard.viewQuery, pageToken: nil, maxResults: 50).ids)
            == ["d10", "d11", "d12", "d13"])
        #expect(try await g.unreadEstimate(query: InboxZero.defaultQuery) == 3)
    }

    @Test func meetingSearchesFindTheirInvites() async throws {
        let g = demo()
        for (service, id) in [(MeetingService.teams, "d01"), (.zoom, "d04"), (.googleMeet, "d05")] {
            let query = MeetingLinkDetector.searchQuery(service: service, scope: InboxZero.defaultQuery)
            #expect(try await g.listThreadsOnce(query: query, pageToken: nil, maxResults: 50).ids == [id], "\(service)")
        }
    }

    @Test func snoozedThreadsCarryFutureTimeLabels() async throws {
        let g = demo()
        let labels = try await g.listLabels()
        let times = labels.map(\.name).filter { $0.hasPrefix(SeiseLabels.snoozeTimePrefix) }
        #expect(times.count == 4)
        for name in times {
            let stamp = String(name.dropFirst(SeiseLabels.snoozeTimePrefix.count))
            #expect(try #require(SnoozeTime.decode(stamp)) > now, "\(name)")
        }
    }

    @Test func archivingEmptiesTheInbox() async throws {
        let g = demo()
        let ids = try await g.listThreads(query: InboxZero.defaultQuery, pageToken: nil, maxResults: 50).ids
        var messages: [String] = []
        for id in ids { messages += try await g.threadSummary(id: id, me: nil).messageIDs }
        try await g.batchModify(messageIDs: messages, add: [], remove: [GmailLabel.inbox])
        #expect(try await g.listThreads(query: InboxZero.defaultQuery, pageToken: nil, maxResults: 50).ids.isEmpty)
    }
}
