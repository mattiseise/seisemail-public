import Foundation
import Testing
@testable import DaemonCore
@testable import MailCore

/// §7.2 schema 1 validation and §7.3 defaults. A refused file never takes effect (`ConfigStoreTests`).
@Suite struct RuleSetTests {
    func rulesFile(_ rules: String, options: String = #"{"deferAutoReplyInMyThreads": true}"#, extra: String = "") -> String {
        #"{"schema": 1, "me": [], "options": \#(options)\#(extra), "rules": [\#(rules)]}"#
    }

    func rule(id: String = "oma", label: String = "Lajittelu/Omat", any: String = #"[{"type": "headerPresent", "header": "List-Id"}]"#,
              extra: String = "") -> String {
        #"{"id": "\#(id)", "enabled": true, "label": "\#(label)", "any": \#(any)\#(extra)}"#
    }

    func refused(_ json: String) -> (any Error)? {
        do {
            _ = try Rules.compile(json)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Defaults

    @Test func defaultsEqualTheFixture() throws {
        #expect(try RuleSet.decode(Rules.defaultFixture()) == DefaultRules.file)
    }

    @Test func defaultsRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DefaultRules.file)
        #expect(try RuleSet.decode(encoded) == DefaultRules.file)
    }

    @Test func defaultsCompile() throws {
        _ = try RuleSet.compile(DefaultRules.file)
        _ = try Rules.compile(Rules.defaultFixture())
    }

    @Test func defaultFileIsTheContractOrder() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Rules.defaultFixture()) as? [String: Any])
        let rules = try #require(object["rules"] as? [[String: Any]])
        #expect(rules.compactMap { $0["id"] as? String } == ["kuitit-suodattimet", "uutiskirjeet", "ilmoitukset", "ilmoitukset-laaja",
                                                            "kuitit", "ihmiset", "gmail-mainokset"])
        #expect(rules.compactMap { $0["enabled"] as? Bool } == [true, true, true, false, true, true, false])
    }

    @Test func minimalValidFile() throws {
        _ = try Rules.compile(rulesFile(rule()))
        _ = try Rules.compile(rulesFile(rule(any: #"[{"type": "hasLabel", "pattern": "kuitit/.*"}]"#)))
        _ = try Rules.compile(rulesFile(rule(any: #"[{"type": "fromInSentCache"}]"#)))
        _ = try Rules.compile(rulesFile(rule(any: #"[{"type": "autoSubmitted", "notIn": ["no"]}]"#)))
        _ = try Rules.compile(rulesFile(rule(any: #"[{"type": "hasSystemLabel", "id": "CATEGORY_SOCIAL"}]"#)))
        _ = try Rules.compile(rulesFile(rule(extra: #", "note": "vapaa teksti""#)))
    }

    // MARK: Refusals

    @Test func badRegexNamesTheRuleAndTheCondition() throws {
        let error = try #require(refused(rulesFile(rule(id: "rikki", any: #"[{"type": "headerPresent", "header": "List-Id"}, {"type": "subjectToken", "pattern": "kuit(ti"}]"#))))
        let text = String(describing: error)
        #expect(text.contains("rikki"))
        #expect(text.contains("kuit(ti") || text.contains("1") || text.contains("2"))
    }

    @Test(arguments: [#"\\bkuitti\\b"#, #"(?<=e-)lasku"#, #"(?<!säh)kölasku"#])
    func wordBoundaryAndLookbehindAreRefused(_ pattern: String) {
        #expect(refused(rulesFile(rule(any: #"[{"type": "subjectToken", "pattern": "\#(pattern)"}]"#))) != nil)
    }

    @Test func lookaheadIsAllowed() throws {
        _ = try Rules.compile(rulesFile(rule(any: #"[{"type": "subjectToken", "pattern": "lasku(?!ri)[\\p{L}-]*"}]"#)))
    }

    @Test(arguments: ["Kuitit", "Uutiskirjeet/Lajittelu", "Torkku/Omat", "Lajittelu/Luokiteltu", "lajittelu/luokiteltu",
                      "Lajittelu/Vaatii toimenpidettä", ""])
    func labelMustBeAnOrdinarySortingLabel(_ label: String) {
        #expect(refused(rulesFile(rule(label: label))) != nil, "label \(label)")
    }

    @Test func unknownTopLevelKeyIsRefused() {
        #expect(refused(rulesFile(rule(), extra: #", "rule": []"#)) != nil)
    }

    @Test func unknownRuleKeyIsRefused() {
        #expect(refused(rulesFile(rule(extra: #", "enabeld": false"#))) != nil)
    }

    @Test func unknownConditionKeyIsRefused() {
        #expect(refused(rulesFile(rule(any: #"[{"type": "headerPresent", "header": "List-Id", "value": "x"}]"#))) != nil)
    }

    @Test func unknownConditionTypeIsRefused() {
        #expect(refused(rulesFile(rule(any: #"[{"type": "bodyContains", "pattern": "x"}]"#))) != nil)
    }

    @Test func unknownOptionIsRefused() {
        #expect(refused(rulesFile(rule(), options: #"{"deferAutoReplyInMyThreads": true, "aggressive": true}"#)) != nil)
    }

    @Test func schema2IsRefused() {
        let json = rulesFile(rule()).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#)
        #expect(refused(json) != nil)
    }

    @Test func duplicateIDsAreRefused() {
        #expect(refused(rulesFile(rule(id: "sama") + "," + rule(id: "sama", label: "Lajittelu/Kuitit"))) != nil)
    }

    @Test(arguments: ["Iso", "ala_viiva", "väli lyönti", ""])
    func idMustBeLowercaseDashed(_ id: String) {
        #expect(refused(rulesFile(rule(id: id))) != nil, "id \(id)")
    }

    @Test func emptyAnyIsRefused() {
        #expect(refused(rulesFile(rule(any: "[]"))) != nil)
    }

    @Test func notJSONIsRefused() {
        #expect(refused("{\"schema\": 1, \"rules\": [") != nil)
    }
}

/// `SentCache` (§9.2: capped at 20,000 addresses, evicting the least recently sent).
@Suite struct SentCacheTests {
    @Test func addressesAreLowercased() {
        let cache = sentCache(["Anna.Ahola@Example.FI"])
        #expect(cache.contains("anna.ahola@example.fi"))
        #expect(cache.contains("ANNA.AHOLA@example.fi"))
        #expect(!cache.contains("kalle@example.fi"))
    }

    @Test func leastRecentlySentIsEvicted() {
        var cache = SentCache(capacity: 3)
        cache.record(["a@x.fi"], at: D(1_000))
        cache.record(["b@x.fi"], at: D(2_000))
        cache.record(["c@x.fi"], at: D(3_000))
        cache.record(["a@x.fi"], at: D(4_000))           // sent again: now the newest
        cache.record(["d@x.fi"], at: D(5_000))
        #expect(cache.count == 3)
        #expect(cache.contains("a@x.fi") && cache.contains("c@x.fi") && cache.contains("d@x.fi"))
        #expect(!cache.contains("b@x.fi"))
    }

    @Test func defaultCapacityIs20000() {
        var cache = SentCache(capacity: 20_000)
        for i in 0..<20_005 { cache.record(["h\(i)@x.fi"], at: D(TimeInterval(i))) }
        #expect(cache.count == 20_000)
        #expect(!cache.contains("h0@x.fi"))
        #expect(cache.contains("h20004@x.fi"))
    }
}
