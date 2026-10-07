import Foundation
import Testing
@testable import MailCore

@Suite struct NewMailDetectorTests {
    func s(_ id: String) -> ThreadSummary {
        ThreadSummary(id: id, subject: id, sender: id, snippet: "", date: Date(timeIntervalSince1970: 0), labelIDs: [GmailLabel.unread], hasAttachments: false, messageCount: 1)
    }

    @Test func firstCheckOnlyRecordsBaseline() {
        var d = NewMailDetector()
        #expect(d.process([s("a"), s("b")]).isEmpty)
    }

    @Test func newThreadsAreReportedOnce() {
        var d = NewMailDetector()
        _ = d.process([s("a")])
        #expect(d.process([s("c"), s("b"), s("a")]) == [.single(s("c")), .single(s("b"))])
        #expect(d.process([s("c"), s("b"), s("a")]).isEmpty)
    }

    @Test func threadThatWasReadAndGetsNewMailIsReportedAgain() {
        var d = NewMailDetector()
        _ = d.process([s("a")])
        _ = d.process([])          // user read it
        #expect(d.process([s("a")]) == [.single(s("a"))])
    }

    @Test func manyNewThreadsBecomeOneSummary() {
        var d = NewMailDetector()
        _ = d.process([])
        #expect(d.process((1...5).map { s("n\($0)") }) == [.summary(count: 5)])
    }

    @Test func acknowledgedThreadIsNotReportedAsNew() {
        var d = NewMailDetector()
        _ = d.process([])
        d.acknowledge("a")         // user marked it unread by hand
        #expect(d.process([s("a")]).isEmpty)
    }

    @Test func exactlyThreeAreStillIndividual() {
        var d = NewMailDetector()
        _ = d.process([])
        #expect(d.process([s("1"), s("2"), s("3")]).count == 3)
    }
}

@MainActor
@Suite struct InboxMonitorTests {
    let api = FakeGmail()

    @Test func checkReportsNewUnreadAndCounts() async {
        api.addThread("old", labels: [GmailLabel.inbox, GmailLabel.unread], in: ["in:inbox is:unread"])
        api.update { $0.inboxUnread = 1 }
        let monitor = InboxMonitor(api: api)
        #expect(await monitor.check().isEmpty)
        #expect(monitor.unread.map(\.id) == ["old"])
        #expect(monitor.unreadCount == 1)

        api.addThread("new", labels: [GmailLabel.inbox, GmailLabel.unread], in: [])
        api.update { $0.lists["in:inbox is:unread"] = ["new", "old"]; $0.inboxUnread = 2 }
        let events = await monitor.check()
        #expect(events.map(\.threadID) == ["new"])
        #expect(monitor.unreadCount == 2)
        #expect(monitor.unread.map(\.id) == ["new", "old"])
    }

    @Test func failedCheckKeepsPreviousStateAndReportsNothing() async {
        api.addThread("a", labels: [GmailLabel.inbox, GmailLabel.unread], in: ["in:inbox is:unread"])
        let monitor = InboxMonitor(api: api)
        _ = await monitor.check()
        api.update { $0.offline = true }
        #expect(await monitor.check().isEmpty)
        #expect(monitor.unread.map(\.id) == ["a"])
    }

    @Test func markingReadDropsBadgeAtOnce() async {
        api.addThread("a", labels: [GmailLabel.inbox, GmailLabel.unread], in: ["in:inbox is:unread"])
        api.update { $0.inboxUnread = 1 }
        let monitor = InboxMonitor(api: api)
        _ = await monitor.check()
        monitor.noteChange(threadID: "a", unread: false)
        #expect(monitor.unread.isEmpty)
        #expect(monitor.unreadCount == 0)
    }

    @Test func markingUnreadByHandDoesNotNotify() async {
        _ = api.addThread("a", labels: [GmailLabel.inbox], in: ["in:inbox"])
        let monitor = InboxMonitor(api: api)
        _ = await monitor.check()
        monitor.noteChange(threadID: "a", unread: true)
        api.update { $0.lists["in:inbox is:unread"] = ["a"]; $0.inboxUnread = 1 }
        #expect(await monitor.check().isEmpty)
        #expect(monitor.unreadCount == 1)
    }
}
