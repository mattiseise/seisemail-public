import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// The default rules (§7.3, conventions §2) against `daemon_rules_cases.json`. Each case is one new incoming INBOX
/// message in a fresh thread, so `SortingPlanner.decide` reduces to the rule engine: `.classify` or `.unmatched`.
/// The Windows port reads the same fixture.
@Suite struct RuleEngineTableTests {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        struct Expect: Decodable, Sendable {
            var rule: String
            var label: String
            var alsoMatched: [String]
        }

        var name: String
        var from: String?
        var subject: String?
        var headers: [String: String]?
        var userLabels: [String]?
        var systemLabels: [String]?
        var sent: [String]?
        var me: [String]?
        var enable: [String]?
        var disable: [String]?
        var expect: Expect?

        var testDescription: String { name }
    }

    struct File: Decodable { var cases: [Case] }

    static let cases: [Case] = (try? JSONDecoder().decode(File.self, from: Fixture.data("daemon_rules_cases")).cases) ?? []

    @Test func fixtureLoads() {
        #expect(Self.cases.count >= 60)
    }

    @Test(arguments: cases)
    func defaultRule(_ c: Case) throws {
        var ids: [String: String] = [:]
        for (i, name) in (c.userLabels ?? []).enumerated() { ids[name] = "Label_\(i + 1)" }
        let labels = Set(["INBOX", "UNREAD"]).union(c.systemLabels ?? []).union(ids.values)
        let message = Mail.msg("m1", from: c.from ?? "Anna Ahola <anna@example.fi>", subject: c.subject ?? "Hei",
                               labels: labels, headers: c.headers ?? [:])
        let rules = try Rules.defaults(enabling: c.enable ?? [], disabling: c.disable ?? [])
        let (d, decider) = decide(Mail.thread("t1", [message]), new: ["m1"], labels: Snap.with(ids), rules: rules,
                                  sent: sentCache(c.sent ?? []), me: Set(c.me ?? [Mail.me]))
        if let e = c.expect {
            #expect(d == .classify(ruleID: e.rule, label: e.label, alsoMatched: e.alsoMatched))
        } else {
            #expect(d == .unmatched)
        }
        #expect(decider?.id == "m1")
    }

    // Spot checks that read better on their own than as table rows.

    @Test func appleReceiptStaysInKuititWithTheContractPattern() throws {
        let m = Mail.msg("m1", from: "Apple <no_reply@email.apple.com>", subject: "Your receipt from Apple.")
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"]).0 == .classify(ruleID: "kuitit", label: "Lajittelu/Kuitit", alsoMatched: []))
        let wide = try Rules.defaults(enabling: ["ilmoitukset-laaja"])
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"], rules: wide).0
            == .classify(ruleID: "ilmoitukset-laaja", label: "Lajittelu/Ilmoitukset", alsoMatched: ["kuitit"]))
    }

    @Test func firstMatchWinsInFileOrder() throws {
        let m = Mail.msg("m1", from: "noreply@kauppa.fi", subject: "Kuitti", headers: ["List-Id": "<x>"])
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"]).0
            == .classify(ruleID: "uutiskirjeet", label: "Lajittelu/Uutiskirjeet", alsoMatched: ["ilmoitukset", "kuitit"]))
        // Reordering the file changes the winner (Q6 is a rules.json edit, not code).
        let receiptsFirst = try Rules.compile("""
        {"schema": 1, "me": [], "options": {"deferAutoReplyInMyThreads": true}, "rules": [
          {"id": "kuitit", "enabled": true, "label": "Lajittelu/Kuitit", "any": [{"type": "subjectToken", "pattern": "kuitti"}]},
          {"id": "uutiskirjeet", "enabled": true, "label": "Lajittelu/Uutiskirjeet", "any": [{"type": "headerPresent", "header": "List-Id"}]}
        ]}
        """)
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"], rules: receiptsFirst).0
            == .classify(ruleID: "kuitit", label: "Lajittelu/Kuitit", alsoMatched: ["uutiskirjeet"]))
    }

    @Test func extraOwnAddressesFromRulesFileAreNotPeople() throws {
        let rules = try Rules.defaults { $0["me"] = ["matti.alias@example.fi"] }
        let m = Mail.msg("m1", from: "Matti <Matti.Alias@example.fi>")
        let d = decide(Mail.thread("t1", [m]), new: ["m1"], rules: rules, sent: sentCache(["matti.alias@example.fi"])).0
        #expect(d == .unmatched)
    }

    @Test func sentCacheLookupIsCaseInsensitive() {
        let m = Mail.msg("m1", from: "Anna <Anna.Ahola@Example.FI>")
        let d = decide(Mail.thread("t1", [m]), new: ["m1"], sent: sentCache(["anna.ahola@example.fi"])).0
        #expect(d == .classify(ruleID: "ihmiset", label: "Lajittelu/Ihmiset", alsoMatched: []))
    }

    @Test func hasLabelUsesNamesNotIDs() throws {
        // A label whose id happens to look like "kuitit/x" but whose name does not.
        let snapshot = LabelSnapshot(labels: LabelFakeGmail.systemLabels + [GmailLabelInfo(id: "kuitit/x", name: "Muut", kind: .user)])
        let m = Mail.msg("m1", labels: ["INBOX", "kuitit/x"])
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"], labels: snapshot).0 == .unmatched)
    }

    @Test func hasSystemLabelMatchesTheID() throws {
        let rules = try Rules.defaults(enabling: ["gmail-mainokset"])
        let m = Mail.msg("m1", labels: ["INBOX", "CATEGORY_PROMOTIONS"])
        #expect(decide(Mail.thread("t1", [m]), new: ["m1"], rules: rules).0
            == .classify(ruleID: "gmail-mainokset", label: "Lajittelu/Uutiskirjeet", alsoMatched: []))
    }
}
