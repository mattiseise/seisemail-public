import Foundation

public struct RuleMatch: Sendable, Equatable {
    public var ruleID: String
    public var label: String
    /// Later enabled rules that matched too (for the shadow review, Q6).
    public var alsoMatched: [String]

    public init(ruleID: String, label: String, alsoMatched: [String] = []) {
        self.ruleID = ruleID
        self.label = label
        self.alsoMatched = alsoMatched
    }
}

/// Evaluates the rules on one message's facts (design §7.2): enabled rules in file order; a rule
/// matches when any condition does; the first match wins. Pure.
public enum RuleEngine {
    public static func evaluate(_ facts: MessageFacts, rules: CompiledRules, sent: SentCache, me: Set<String>) -> RuleMatch? {
        let ids = matchingRules(facts, rules: rules, sent: sent, me: me)
        guard let first = ids.first, let rule = rules.rules.first(where: { $0.id == first }) else { return nil }
        return RuleMatch(ruleID: rule.id, label: rule.label, alsoMatched: Array(ids.dropFirst()))
    }

    /// IDs of every enabled rule that matches, in file order.
    public static func matchingRules(_ facts: MessageFacts, rules: CompiledRules, sent: SentCache, me: Set<String>) -> [String] {
        let mine = Set(me.map { $0.lowercased() }).union(rules.me)
        return rules.rules.filter { rule in
            rule.enabled && rule.conditions.contains { matches($0, facts, sent: sent, me: mine) }
        }.map(\.id)
    }

    public static func matches(_ condition: CompiledCondition, _ facts: MessageFacts, sent: SentCache, me: Set<String>) -> Bool {
        switch condition {
        case .headerPresent(let name):
            return facts.hasHeader(name)
        case .fromAddress(let pattern):
            return facts.fromAddress.map(pattern.occurs(in:)) ?? false
        case .autoSubmitted(let notIn):
            guard let value = facts.autoSubmitted else { return false }
            return !notIn.contains(value)
        case .subjectToken(let pattern):
            return facts.subjectTokens.contains(where: pattern.matchesWhole)
        case .senderToken(let pattern):
            return facts.senderTokens.contains(where: pattern.matchesWhole)
        case .fromInSentCache:
            guard let address = facts.fromAddress else { return false }
            return sent.contains(address) && !me.contains(address)
        case .hasLabel(let pattern):
            return facts.userLabelNames.contains(where: pattern.matchesWhole)
        case .hasSystemLabel(let id):
            return facts.systemLabelIDs.contains(id)
        }
    }
}
