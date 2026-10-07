import Foundation
import Testing
@testable import MailCore

@MainActor
struct MeetingHintsTests {
    func summary(_ id: String, count: Int = 1, subject: String = "Aihe", snippet: String = "") -> ThreadSummary {
        ThreadSummary(id: id, subject: subject, sender: "X", snippet: snippet, date: .now, labelIDs: [], hasAttachments: false, messageCount: count)
    }

    func thread(_ id: String, _ bodies: [String]) -> MailThread {
        MailThread(id: id, messages: bodies.enumerated().map { MeetingLinkDetectorTests.message("\(id)-\($0.offset)", text: $0.element) })
    }

    @Test func snippetHintBadgesRowsWithoutBodies() {
        let hints = MeetingHints()
        #expect(hints.service(for: summary("a", snippet: "Liity kokoukseen nyt")) == .teams)
        #expect(hints.service(for: summary("b", snippet: "meet.google.com/abc-defg-hij")) == .googleMeet)
        #expect(hints.service(for: summary("c", snippet: "Kiitos viestistä")) == nil)
    }

    @Test func openedBodyOverridesSnippetUntilNewMessage() {
        let hints = MeetingHints()
        let row = summary("a", snippet: "Join the meeting now")
        #expect(hints.service(for: row) == .teams)
        // The body says otherwise (a cancelled meeting quoting the old invite text): the body wins.
        #expect(hints.record(thread("a", ["Join the meeting now – kokous peruttu"])) == nil)
        #expect(hints.service(for: row) == nil)
        // A new message in the thread makes the old body result stale; the snippet counts again.
        #expect(hints.service(for: summary("a", count: 2, snippet: "Join the meeting now")) == .teams)
    }

    @Test func bodyFindsLinkSnippetMissed() {
        let hints = MeetingHints()
        let row = summary("a", count: 2, snippet: "Kiitos, nähdään")
        #expect(hints.service(for: row) == nil)
        let link = hints.record(thread("a", ["https://zoom.us/j/81234567890", "Kiitos, nähdään"]))
        #expect(link?.service == .zoom)
        #expect(hints.service(for: row) == .zoom)
        #expect(hints.link(for: row)?.url.absoluteString == "https://zoom.us/j/81234567890")
    }

    @Test func recordParsesOncePerMessageCount() {
        let hints = MeetingHints()
        let first = thread("a", ["https://zoom.us/j/81234567890"])
        hints.record(first)
        #expect(hints.parseCount == 1)
        hints.record(first)
        #expect(hints.parseCount == 1)
        hints.record(thread("a", ["https://zoom.us/j/81234567890", "https://meet.google.com/abc-defg-hij"]))
        #expect(hints.parseCount == 2)
        #expect(hints.service(for: summary("a", count: 2)) == .googleMeet)
    }

    @Test func recordNotifiesObserversOnlyOnNewResults() {
        let hints = MeetingHints()
        final class Flag: @unchecked Sendable { var fired = false }
        let t = thread("a", ["https://zoom.us/j/81234567890"])
        hints.record(t)
        let flag = Flag()
        withObservationTracking { _ = hints.service(for: summary("a")) } onChange: { flag.fired = true }
        hints.record(t)
        #expect(!flag.fired)
        hints.record(thread("b", ["https://zoom.us/j/81234567890"]))
        #expect(flag.fired)
    }

    @Test func snippetHintIsMemoisedPerRowContent() {
        let hints = MeetingHints()
        _ = hints.service(for: summary("a", snippet: "Join Zoom Meeting"))
        _ = hints.service(for: summary("a", snippet: "Join Zoom Meeting"))
        #expect(hints.snippetParseCount == 1)
        #expect(hints.service(for: summary("a", snippet: "Kiitos")) == nil)
        #expect(hints.snippetParseCount == 2)
    }
}
