import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §6.5 decision table, pure. Label IDs come from `Snap` (marker = L_M, Uutiskirjeet = L_U, …).
@Suite struct SortingPlannerTests {
    let newsletterHeaders = ["List-Unsubscribe": "<mailto:pois@lehti.fi>"]

    func newsletter(_ id: String, at seconds: TimeInterval = 0, labels: Set<String> = ["INBOX", "UNREAD"]) -> HeaderMessage {
        Mail.msg(id, from: "Uutiset <uutiset@lehti.fi>", subject: "Viikon uutiset", labels: labels, at: seconds, headers: newsletterHeaders)
    }

    func person(_ id: String, at seconds: TimeInterval = 0, labels: Set<String> = ["INBOX", "UNREAD"]) -> HeaderMessage {
        Mail.msg(id, labels: labels, at: seconds)
    }

    func propagated(_ d: SortingDecision) -> Set<String>? {
        if case .propagate(let names) = d { return Set(names) }
        return nil
    }

    // MARK: Row 0: no new incoming INBOX message

    @Test func noNewMessageIDsIgnores() {
        let (d, decider) = decide(Mail.thread("t1", [newsletter("m1")]), new: [])
        guard case .ignore = d else { Issue.record("expected .ignore, got \(d)"); return }
        #expect(decider == nil)
    }

    @Test(arguments: ["SENT", "DRAFT", "SPAM", "TRASH", "CHAT"])
    func nonIncomingNeverDecides(_ system: String) {
        let m = newsletter("m1", labels: ["INBOX", system])
        let (d, decider) = decide(Mail.thread("t1", [m]), new: ["m1"])
        guard case .ignore = d else { Issue.record("\(system): expected .ignore, got \(d)"); return }
        #expect(decider == nil)
    }

    @Test func archivedAtTheFreshReadIgnores() {
        // A Gmail filter archived it (no INBOX at the fresh read): the thread is not classified.
        let (d, _) = decide(Mail.thread("t1", [newsletter("m1", labels: ["UNREAD"])]), new: ["m1"])
        guard case .ignore = d else { Issue.record("expected .ignore, got \(d)"); return }
    }

    @Test func ownInboxNoteIgnores() {
        let note = Mail.msg("n1", from: Mail.me, subject: "Mak8r-daemon: kirjaudu uudelleen", labels: ["INBOX", "UNREAD"],
                            headers: ["X-Mak8r-Daemon": "1", "Auto-Submitted": "auto-generated"])
        let (d, decider) = decide(Mail.thread("note-1", [note]), new: ["n1"])
        guard case .ignore = d else { Issue.record("expected .ignore, got \(d)"); return }
        #expect(decider == nil)
    }

    /// Headers on incoming mail are the sender's: the marker header alone never makes a message the daemon's own.
    @Test func spoofedOwnNoteHeaderFromAnExternalSenderIsSortedAsUsual() {
        let spoof = Mail.msg("m1", from: "Uutiset <uutiset@lehti.fi>", subject: "Viikon uutiset",
                             headers: newsletterHeaders.merging(["X-Mak8r-Daemon": "1"]) { a, _ in a })
        let (d, decider) = decide(Mail.thread("t1", [spoof]), new: ["m1"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
        #expect(decider?.id == "m1")
        #expect(!SortingPlanner.isOwn(spoof, me: [Mail.me]))
    }

    @Test func ownNoteNeverDecidesAThreadWithOtherNewMail() {
        // The note is newer, but only the newsletter is a candidate decider.
        let note = Mail.msg("n1", from: Mail.me, labels: ["INBOX"], at: 100, headers: ["X-Mak8r-Daemon": "1"])
        let (d, decider) = decide(Mail.thread("t1", [newsletter("m1", at: 10), note]), new: ["m1", "n1"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
        #expect(decider?.id == "m1")
    }

    // MARK: Row 1: propagation

    @Test func classifiedThreadPropagatesToTheNewMessage() {
        let old = newsletter("m1", labels: ["UNREAD", Snap.uutiskirjeet, Snap.marker])
        let (d, decider) = decide(Mail.thread("t1", [old, person("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["Lajittelu/Uutiskirjeet", "Lajittelu/Luokiteltu"])
        #expect(decider?.id == "m2")
    }

    @Test func propagationNeverClassifiesEvenIfTheNewMessageMatchesAnotherRule() {
        let old = person("m1", labels: [Snap.kuitit, Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [old, newsletter("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["Lajittelu/Kuitit", "Lajittelu/Luokiteltu"])
    }

    @Test func manualChangeUutiskirjeetToKuititPropagatesKuitit() {
        // Matti replaced Uutiskirjeet with Kuitit; the marker stayed.
        let old = newsletter("m1", labels: [Snap.kuitit, Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [old, newsletter("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["Lajittelu/Kuitit", "Lajittelu/Luokiteltu"])
    }

    @Test func manualLabelWithoutMarkerGetsTheMarkerToo() {
        let old = person("m1", labels: [Snap.ihmiset])
        let (d, _) = decide(Mail.thread("t1", [old, person("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["Lajittelu/Ihmiset", "Lajittelu/Luokiteltu"])
    }

    @Test func customSortingLabelPropagatesWhateverItsCase() {
        let old = person("m1", labels: [Snap.omat, Snap.marker])              // "lajittelu/omat"
        let (d, _) = decide(Mail.thread("t1", [old, person("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["lajittelu/omat", "Lajittelu/Luokiteltu"])
    }

    @Test func labelsOnAnyMessageCount() {
        let first = person("m1", labels: [Snap.uutiskirjeet])
        let second = person("m2", at: 30, labels: [Snap.ihmiset, Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [first, second, person("m3", at: 60)]), new: ["m3"])
        #expect(propagated(d) == ["Lajittelu/Uutiskirjeet", "Lajittelu/Ihmiset", "Lajittelu/Luokiteltu"])
    }

    @Test func vaatiiToimenpidettaIsNeverPropagated() {
        let old = person("m1", labels: [Snap.uutiskirjeet, Snap.vaatii, Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [old, person("m2", at: 60)]), new: ["m2"])
        #expect(propagated(d) == ["Lajittelu/Uutiskirjeet", "Lajittelu/Luokiteltu"])
    }

    @Test func vaatiiToimenpidettaAloneIsNotASortingLabel() {
        // L = ∅ and no marker: the rules decide.
        let old = person("m1", labels: [Snap.vaatii])
        let (d, _) = decide(Mail.thread("t1", [old, newsletter("m2", at: 60)]), new: ["m2"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
    }

    @Test func nothingMissingIsAnEmptyPropagation() {
        // Crash between modify and save: the replay finds every label already there.
        let m1 = newsletter("m1", labels: ["INBOX", Snap.uutiskirjeet, Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [m1]), new: ["m1"])
        #expect(d == .propagate(addNames: []))
    }

    @Test func propagationCountsOnlyWhatSomeNewMessageLacks() {
        let old = person("m1", labels: [Snap.uutiskirjeet, Snap.marker])
        let done = person("m2", at: 30, labels: ["INBOX", Snap.uutiskirjeet, Snap.marker])
        let fresh = person("m3", at: 60, labels: ["INBOX", Snap.uutiskirjeet])
        let (d, _) = decide(Mail.thread("t1", [old, done, fresh]), new: ["m2", "m3"])
        #expect(propagated(d) == ["Lajittelu/Luokiteltu"])
    }

    @Test func superhumanLabelsAreNotSortingLabels() {
        let old = person("m1", labels: [Snap.superhuman])
        let (d, _) = decide(Mail.thread("t1", [old, newsletter("m2", at: 60)]), new: ["m2"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
    }

    // MARK: Row 2: marker without a sorting label

    @Test func markerWithoutLabelIsManualKept() {
        // Matti removed the label: it never comes back, whatever the new message is.
        let old = newsletter("m1", labels: [Snap.marker])
        let (d, _) = decide(Mail.thread("t1", [old, newsletter("m2", at: 60)]), new: ["m2"])
        #expect(d == .manualKept)
    }

    // MARK: Row 3: out-of-office in Matti's own thread

    func autoReplyThread(sent: Bool) -> ThreadHeaders {
        let reply = Mail.msg("m2", subject: "Automaattinen vastaus: Kokous", at: 60, headers: ["Auto-Submitted": "auto-replied"])
        return Mail.thread("t1", (sent ? [Mail.sent("m1")] : []) + [reply])
    }

    @Test func autoReplyInMyThreadIsDeferred() {
        let (d, decider) = decide(autoReplyThread(sent: true), new: ["m2"])
        #expect(d == .deferredAutoReply)
        #expect(decider?.id == "m2")
    }

    @Test func autoReplyWithParametersIsStillAutoReplied() {
        let reply = Mail.msg("m2", at: 60, headers: ["Auto-Submitted": "Auto-Replied (vacation); owner=x"])
        let (d, _) = decide(Mail.thread("t1", [Mail.sent("m1"), reply]), new: ["m2"])
        #expect(d == .deferredAutoReply)
    }

    @Test func autoReplyOutsideMyThreadsIsANotification() {
        let (d, _) = decide(autoReplyThread(sent: false), new: ["m2"])
        #expect(d == .classify(ruleID: "ilmoitukset", label: "Lajittelu/Ilmoitukset", alsoMatched: []))
    }

    @Test func deferralCanBeSwitchedOff() throws {
        let rules = try Rules.defaults { $0["options"] = ["deferAutoReplyInMyThreads": false] }
        let (d, _) = decide(autoReplyThread(sent: true), new: ["m2"], rules: rules)
        #expect(d == .classify(ruleID: "ilmoitukset", label: "Lajittelu/Ilmoitukset", alsoMatched: []))
    }

    @Test func autoGeneratedInMyThreadIsNotDeferred() {
        let reply = Mail.msg("m2", at: 60, headers: ["Auto-Submitted": "auto-generated"])
        let (d, _) = decide(Mail.thread("t1", [Mail.sent("m1"), reply]), new: ["m2"])
        #expect(d == .classify(ruleID: "ilmoitukset", label: "Lajittelu/Ilmoitukset", alsoMatched: []))
    }

    // MARK: Row 4: classification by the decider

    @Test func newestNewInboxMessageDecides() {
        let (d, decider) = decide(Mail.thread("t1", [newsletter("m1", at: 10), person("m2", at: 20)]), new: ["m1", "m2"])
        #expect(d == .unmatched)
        #expect(decider?.id == "m2")
        let (d2, decider2) = decide(Mail.thread("t1", [person("m1", at: 10), newsletter("m2", at: 20)]), new: ["m1", "m2"])
        #expect(d2 == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
        #expect(decider2?.id == "m2")
    }

    @Test func internalDateDecidesNotThreadOrder() {
        let (d, decider) = decide(Mail.thread("t1", [newsletter("m1", at: 50), person("m2", at: 20)]), new: ["m1", "m2"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
        #expect(decider?.id == "m1")
    }

    @Test func equalDatesAreDecidedByOrder() {
        let (_, decider) = decide(Mail.thread("t1", [newsletter("m1", at: 20), person("m2", at: 20)]), new: ["m1", "m2"])
        #expect(decider?.id == "m2")
    }

    @Test func anOldMessageNeverVotes() {
        // The old newsletter is not new; the new person message decides.
        let (d, decider) = decide(Mail.thread("t1", [newsletter("m1", at: 10, labels: ["INBOX"]), person("m2", at: 60)]), new: ["m2"])
        #expect(d == .unmatched)
        #expect(decider?.id == "m2")
    }

    @Test func aNewMessageOutsideInboxNeverVotes() {
        let archived = newsletter("m2", at: 90, labels: ["UNREAD"])
        let (d, decider) = decide(Mail.thread("t1", [person("m1", at: 10), archived]), new: ["m1", "m2"])
        #expect(d == .unmatched)
        #expect(decider?.id == "m1")
    }

    @Test func sentAndIncomingInOneThread() {
        // Matti's message never decides; the reply from a cached recipient does.
        let sent = sentCache(["anna@example.fi"])
        let (d, decider) = decide(Mail.thread("t1", [Mail.sent("m1", at: 10), person("m2", at: 20)]), new: ["m1", "m2"], sent: sent)
        #expect(d == .classify(ruleID: "ihmiset", label: "Lajittelu/Ihmiset", alsoMatched: []))
        #expect(decider?.id == "m2")
    }

    @Test func kuititFilterLabelIsRuleZero() {
        let m = Mail.msg("m1", labels: ["INBOX", Snap.kuititOstot], headers: newsletterHeaders)
        let (d, _) = decide(Mail.thread("t1", [m]), new: ["m1"])
        #expect(d == .classify(ruleID: "kuitit-suodattimet", label: "Lajittelu/Kuitit", alsoMatched: ["uutiskirjeet"]))
    }

    @Test func ruleLabelsUseTheDecidersLabelsOnly() {
        // kuitit/ostot sits on an old message; the new one has no filter label.
        let old = person("m1", labels: [Snap.kuititOstot])
        let (d, _) = decide(Mail.thread("t1", [old, person("m2", at: 60)]), new: ["m2"])
        #expect(d == .unmatched)
    }

    // MARK: Row 5

    @Test func unmatchedThreadGetsNoDecisionToWrite() {
        let (d, decider) = decide(Mail.thread("t1", [person("m1")]), new: ["m1"])
        #expect(d == .unmatched)
        #expect(decider?.id == "m1")
    }

    @Test func unmatchedIsReevaluatedAtTheNextMessage() {
        // No marker was written, so a later newsletter in the same thread is classified.
        let (d, _) = decide(Mail.thread("t1", [person("m1", labels: ["UNREAD"]), newsletter("m2", at: 60)]), new: ["m2"])
        #expect(d == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
    }

    @Test func ownAddressesAreNeverPeople() {
        let me = Mail.msg("m1", from: "Matti Alias <alias@example.fi>")
        let (d, _) = decide(Mail.thread("t1", [me]), new: ["m1"], sent: sentCache(["alias@example.fi"]),
                            me: [Mail.me, "alias@example.fi"])
        #expect(d == .unmatched)
    }

    // MARK: Decoded Gmail answers

    func decoded(_ fixture: String, id: String) async throws -> ThreadHeaders {
        let body = try Fixture.data(fixture)
        let client = LiveGmailClient(auth: FakeTokens(), transport: StubTransport { _ in (200, body) },
                                     retry: RetryPolicy(delays: [], sleep: { _ in }))
        return try await client.threadHeaders(id: id, headers: ["From", "To", "Cc", "Subject", "List-Unsubscribe", "List-Id",
                                                                "Auto-Submitted", "X-Mak8r-Daemon"])
    }

    @Test func decodedNewsletterWithListIDInCapitals() async throws {
        let thread = try await decoded("daemon_thread_metadata_rules_newsletter", id: "t1")
        let (d, decider) = decide(thread, new: ["m2"], labels: Snap.with(["Muu": "Label_7"]))
        // m2 itself has no list headers; it is the decider, so the thread is not a newsletter by m1's headers.
        #expect(d == .unmatched)
        #expect(decider?.id == "m2")
        let (d1, _) = decide(thread, new: ["m1"], labels: Snap.with(["Muu": "Label_7"]))
        #expect(d1 == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
    }

    @Test func decodedOutOfOfficeInMyThreadIsDeferred() async throws {
        let thread = try await decoded("daemon_thread_metadata_rules_autoreply", id: "t2")
        let (d, decider) = decide(thread, new: ["m2"])
        #expect(d == .deferredAutoReply)
        #expect(decider?.id == "m2")
    }

    @Test func plannerIsDeterministic() {
        let thread = Mail.thread("t1", [newsletter("m1", at: 10), person("m2", at: 20, labels: ["INBOX"])])
        let first = decide(thread, new: ["m1", "m2"])
        for _ in 0..<10 {
            let again = decide(thread, new: ["m1", "m2"])
            #expect(again.0 == first.0)
            #expect(again.decider == first.decider)
        }
    }
}
