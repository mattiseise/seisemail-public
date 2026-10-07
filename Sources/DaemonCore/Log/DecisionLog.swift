import Foundation
import MailCore

/// One sorting decision in `decisions.jsonl` (design §11.2), in both modes. Personal data that stays on
/// this machine: `from` and `subject` pass through `Sanitize.field`.
public struct DecisionEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// `shadow` or `live`.
    public var mode: String
    public var account: String
    public var thread: String
    /// The decider message, when there is one.
    public var msg: String?
    /// `SortingDecision.name`.
    public var decision: String
    public var rule: String?
    public var label: String?
    /// Propagated label names.
    public var labels: [String]?
    public var alsoMatched: [String]?
    public var from: String?
    public var subject: String?
    /// Why a thread was ignored, or which scan produced the decision (`resync`, `backfill`, `sweep`).
    public var reason: String?
    /// Names actually added (live) or that would have been (shadow); nil when no call was due.
    public var added: [String]?

    public init(at: Date, mode: String, account: String, thread: String, msg: String? = nil, decision: String,
                rule: String? = nil, label: String? = nil, labels: [String]? = nil, alsoMatched: [String]? = nil,
                from: String? = nil, subject: String? = nil, reason: String? = nil, added: [String]? = nil) {
        self.at = at
        self.mode = mode
        self.account = account
        self.thread = thread
        self.msg = msg
        self.decision = decision
        self.rule = rule
        self.label = label
        self.labels = labels
        self.alsoMatched = alsoMatched
        self.from = from.map { Sanitize.field($0) }
        self.subject = subject.map { Sanitize.field($0) }
        self.reason = reason
        self.added = added
    }

    /// Builds the entry for `decision` on `thread` decided by `decider`.
    public init(at: Date, mode: FeatureMode, account: String, thread: ThreadHeaders, decision: SortingDecision,
                decider: HeaderMessage?, reason: String? = nil) {
        var rule: String?, label: String?, labels: [String]?, also: [String]?, why = reason
        switch decision {
        case .classify(let r, let l, let a):
            rule = r
            label = l
            also = a.isEmpty ? nil : a
        case .propagate(let names):
            labels = names
        case .ignore(let text):
            why = reason.map { "\($0): \(text)" } ?? text
        default:
            break
        }
        let from = decider?.first("From").flatMap { MessageFacts.sender($0)?.address }
        // As written (decoded, not lowercased); `Sanitize.field` strips controls and caps the length.
        let subject = decider?.first("Subject").map { String(EncodedWords.decode($0).prefix(1_000)) }
        self.init(at: at, mode: mode.rawValue, account: account, thread: thread.threadID, msg: decider?.id,
                  decision: decision.name, rule: rule, label: label, labels: labels, alsoMatched: also,
                  from: from, subject: subject, reason: why)
    }
}

/// Appends `DecisionEntry` lines (compact JSON) to a sink, normally a `RotatingFile` of 10 MiB × 3.
public final class DecisionLog: Sendable {
    private let sink: any LogSink

    public init(sink: any LogSink) {
        self.sink = sink
    }

    public func append(_ entry: DecisionEntry) {
        guard let data = try? DaemonJSON.encoder(pretty: false).encode(entry) else { return }
        sink.write(String(decoding: data, as: UTF8.self))
    }

    /// Parses `decisions.jsonl` text (for `review`); bad lines are skipped.
    public static func parse(_ text: String) -> [DecisionEntry] {
        let decoder = DaemonJSON.decoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(DecisionEntry.self, from: Data($0.utf8)) }
    }
}
