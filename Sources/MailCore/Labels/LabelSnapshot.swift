import Foundation

/// One `labels.list` result with name and ID lookups.
public struct LabelSnapshot: Sendable, Equatable {
    /// In `labels.list` order.
    public let labels: [GmailLabelInfo]
    public let namesByID: [String: String]

    public init(labels: [GmailLabelInfo]) {
        self.labels = labels
        self.namesByID = labels.reduce(into: [:]) { $0[$1.id] = $1.name }
    }

    /// Exact name match first; else the first label (list order) whose lowercased name matches.
    /// Gmail treats names case-insensitively.
    public func id(forName name: String) -> String? {
        if let exact = labels.first(where: { $0.name == name }) { return exact.id }
        let lower = name.lowercased()
        return labels.first { $0.name.lowercased() == lower }?.id
    }

    public func name(forID id: String) -> String? { namesByID[id] }

    public func contains(id: String) -> Bool { namesByID[id] != nil }

    public func label(id: String) -> GmailLabelInfo? { labels.first { $0.id == id } }

    /// Replaces an entry with the same id, else appends.
    func inserting(_ label: GmailLabelInfo) -> LabelSnapshot {
        var next = labels
        if let i = next.firstIndex(where: { $0.id == label.id }) { next[i] = label } else { next.append(label) }
        return LabelSnapshot(labels: next)
    }

    func removing(id: String) -> LabelSnapshot {
        LabelSnapshot(labels: labels.filter { $0.id != id })
    }
}
