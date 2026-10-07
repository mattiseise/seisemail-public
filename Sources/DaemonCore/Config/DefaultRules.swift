import Foundation

/// The default `rules.json` (design §7.3; conventions §2 "Oletussäännöt"). Written by `mak8r-daemon init`,
/// built in while the file is absent, and duplicated in `Tests/MailCoreTests/Fixtures/daemon_rules_default.json`.
public enum DefaultRules {
    /// The file text exactly as `init` writes it.
    public static let json = #"""
    {
      "schema": 1,
      "me": [],
      "options": { "deferAutoReplyInMyThreads": true },
      "rules": [
        { "id": "kuitit-suodattimet", "enabled": true, "label": "Lajittelu/Kuitit",
          "note": "Matin omat kuitit/*-suodatintunnisteet ennen muita sääntöjä",
          "any": [ { "type": "hasLabel", "pattern": "kuitit/.*" } ] },
        { "id": "uutiskirjeet", "enabled": true, "label": "Lajittelu/Uutiskirjeet",
          "any": [ { "type": "headerPresent", "header": "List-Unsubscribe" },
                   { "type": "headerPresent", "header": "List-Id" } ] },
        { "id": "ilmoitukset", "enabled": true, "label": "Lajittelu/Ilmoitukset",
          "any": [ { "type": "fromAddress", "pattern": "no-reply|noreply|notifications?@" },
                   { "type": "autoSubmitted", "notIn": ["no"] } ] },
        { "id": "ilmoitukset-laaja", "enabled": false, "label": "Lajittelu/Ilmoitukset",
          "note": "no_reply, donotreply, do-not-reply, mailer-daemon (siirtää myös Applen kuitit Ilmoituksiin)",
          "any": [ { "type": "fromAddress", "pattern": "no[-_.]?reply|do[-_.]?not[-_.]?reply|mailer-daemon@" } ] },
        { "id": "kuitit", "enabled": true, "label": "Lajittelu/Kuitit",
          "any": [ { "type": "subjectToken", "pattern": "[\\p{L}-]*kuit(?:t[ie]|i[klnst]|ei)[\\p{L}-]*" },
                   { "type": "subjectToken", "pattern": "[\\p{L}-]*tilausvahvistu[\\p{L}-]*" },
                   { "type": "subjectToken", "pattern": "[\\p{L}-]*lasku(?!ri|varj|kon|kaav)[\\p{L}-]*" },
                   { "type": "subjectToken", "pattern": "[\\p{L}-]*receipts?" },
                   { "type": "subjectToken", "pattern": "[\\p{L}-]*invoic\\p{L}*" },
                   { "type": "senderToken",  "pattern": "[\\p{L}-]*kuit(?:t[ie]|i[klnst]|ei)[\\p{L}-]*|receipts?|invoic\\p{L}*|[\\p{L}-]*lasku(?!ri|varj|kon|kaav)[\\p{L}-]*" } ] },
        { "id": "ihmiset", "enabled": true, "label": "Lajittelu/Ihmiset",
          "any": [ { "type": "fromInSentCache" } ] },
        { "id": "gmail-mainokset", "enabled": false, "label": "Lajittelu/Uutiskirjeet",
          "any": [ { "type": "hasSystemLabel", "id": "CATEGORY_PROMOTIONS" } ] }
      ]
    }

    """#

    public static let file: RuleFile = {
        do {
            return try RuleSet.decode(Data(json.utf8))
        } catch {
            preconditionFailure("built-in rules do not decode: \(error)")
        }
    }()

    public static let compiled: CompiledRules = {
        do {
            return try RuleSet.compile(file)
        } catch {
            preconditionFailure("built-in rules do not compile: \(error)")
        }
    }()
}
