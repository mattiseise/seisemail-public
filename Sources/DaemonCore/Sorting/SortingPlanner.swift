import Foundation
import MailCore

public enum SortingDecision: Sendable, Equatable {
    /// No new incoming INBOX message (SENT-only, archived by a filter, own note, …). The reason is for the log.
    case ignore(String)
    /// The thread already has `Lajittelu/*` labels: the names some new INBOX message lacks (add only).
    /// `[]` = nothing missing, no call.
    case propagate(addNames: [String])
    case classify(ruleID: String, label: String, alsoMatched: [String])
    /// The marker without a sorting label: Matti removed it. Never touched again.
    case manualKept
    /// An out-of-office reply in my own thread: the next message decides.
    case deferredAutoReply
    /// No rule matched: no marker, re-evaluated at the next incoming message (Q4).
    case unmatched

    /// The decision's name in `decisions.jsonl`.
    public var name: String {
        switch self {
        case .ignore: "ignore"
        case .propagate: "propagate"
        case .classify: "classify"
        case .manualKept: "manualKept"
        case .deferredAutoReply: "deferredAutoReply"
        case .unmatched: "unmatched"
        }
    }

    /// Label names the decision adds (`threads.modify`, add only). Empty = no call.
    public var addNames: [String] {
        switch self {
        case .classify(_, let label, _): [label, SeiseLabels.Sorting.classifiedMarker]
        case .propagate(let names): names
        default: []
        }
    }
}

/// The decision table (design §6.5). Pure: the thread is a fresh read, the snapshot knows its labels.
public enum SortingPlanner {
    /// Never classify these: SENT, DRAFT, SPAM, TRASH, CHAT.
    public static let notIncoming: Set<String> = [SeiseLabels.sent, SeiseLabels.draft, SeiseLabels.spam, GmailLabel.trash, SeiseLabels.chat]

    public static func isIncoming(_ m: HeaderMessage) -> Bool { m.labelIDs.isDisjoint(with: notIncoming) }

    /// The daemon's own expiry note: the `X-Mak8r-Daemon` header **and** From one of my addresses (InboxNote writes
    /// From = the account). Headers on incoming mail are the sender's, so the header alone proves nothing.
    public static func isOwn(_ m: HeaderMessage, me: Set<String>) -> Bool {
        guard m.first(DaemonHeaders.ownNote) != nil, let from = m.first("From") else { return false }
        let mine = Set(me.map { $0.lowercased() })
        guard let address = MessageFacts.addresses(from).first else { return false }
        return mine.contains(address)
    }

    public static func decide(thread: ThreadHeaders, newMessageIDs: Set<String>, labels: LabelSnapshot,
                              rules: CompiledRules, sent: SentCache, me: Set<String>) -> (SortingDecision, decider: HeaderMessage?) {
        let newInbox = thread.messages.filter {
            newMessageIDs.contains($0.id) && isIncoming($0) && $0.labelIDs.contains(GmailLabel.inbox) && !isOwn($0, me: me)
        }
        // Newest by internalDate; on a tie the later one in thread order.
        let decider = newInbox.enumerated().max { a, b in
            (a.element.internalDate ?? .distantPast, a.offset) < (b.element.internalDate ?? .distantPast, b.offset)
        }?.element
        guard let decider else {
            return (.ignore(ignoreReason(thread, newMessageIDs, me: me)), nil)
        }

        let markerName = SeiseLabels.Sorting.classifiedMarker
        let markerID = labels.id(forName: markerName)
        let needsActionID = labels.id(forName: SeiseLabels.Sorting.needsAction)
        let prefix = SeiseLabels.Sorting.prefix.lowercased()
        let sortingIDs = thread.labelIDs.filter { id in
            guard id != markerID, id != needsActionID, let label = labels.label(id: id), label.kind == .user else { return false }
            let name = label.name.precomposedStringWithCanonicalMapping.lowercased()
            return name.hasPrefix(prefix) && !isReserved(name)
        }

        // Row 1: propagation is not classification (D3). Add only, never remove.
        if !sortingIDs.isEmpty {
            var names: [String] = []
            for id in sortingIDs.sorted(by: { (labels.name(forID: $0) ?? $0) < (labels.name(forID: $1) ?? $1) })
            where newInbox.contains(where: { !$0.labelIDs.contains(id) }) {
                names.append(labels.name(forID: id) ?? id)
            }
            if markerID.map({ id in newInbox.contains { !$0.labelIDs.contains(id) } }) ?? true {
                names.append(markerName)
            }
            return (.propagate(addNames: names), decider)
        }
        // Row 2: the marker without a sorting label: Matti removed it (manual always wins).
        if let markerID, thread.labelIDs.contains(markerID) {
            return (.manualKept, decider)
        }
        let facts = MessageFacts(message: decider, labels: labels)
        // Row 3: an auto-reply in a thread I wrote in waits for the next message (Q8).
        if rules.options.deferAutoReplyInMyThreads, facts.autoSubmitted == "auto-replied",
           thread.messages.contains(where: { $0.labelIDs.contains(SeiseLabels.sent) }) {
            return (.deferredAutoReply, decider)
        }
        // Rows 4–5.
        if let match = RuleEngine.evaluate(facts, rules: rules, sent: sent, me: me) {
            return (.classify(ruleID: match.ruleID, label: match.label, alsoMatched: match.alsoMatched), decider)
        }
        return (.unmatched, decider)
    }

    static func isReserved(_ lowercasedNFCName: String) -> Bool {
        [SeiseLabels.Sorting.classifiedMarker, SeiseLabels.Sorting.needsAction]
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            .contains(lowercasedNFCName)
    }

    private static func ignoreReason(_ thread: ThreadHeaders, _ newIDs: Set<String>, me: Set<String>) -> String {
        let new = thread.messages.filter { newIDs.contains($0.id) }
        if new.isEmpty { return "no new message" }
        if new.allSatisfy({ isOwn($0, me: me) }) { return "own note" }
        if !new.contains(where: isIncoming) { return "not incoming" }
        return "not in inbox"
    }
}
