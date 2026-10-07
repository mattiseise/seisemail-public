import Foundation

/// Addresses Matti has sent mail to (To and Cc), per account, for rule 4 "Ihmiset" (design §6.7, §9.2).
/// Stored as address → epoch seconds of the latest send; capped, evicting the least recently sent.
public struct SentCache: Codable, Sendable, Equatable {
    public static let defaultCapacity = 20_000

    public private(set) var lastSent: [String: Int]
    public var capacity: Int

    public init(lastSent: [String: Int] = [:], capacity: Int = SentCache.defaultCapacity) {
        self.lastSent = lastSent
        self.capacity = capacity
    }

    public var count: Int { lastSent.count }

    public func contains(_ address: String) -> Bool {
        lastSent[address.lowercased()] != nil
    }

    /// Records normalised addresses (lowercased; `me` removed) as sent at `date`, keeping the newest time.
    public mutating func record(_ addresses: some Sequence<String>, at date: Date, me: Set<String> = []) {
        let stamp = Int(date.timeIntervalSince1970)
        for address in addresses {
            let key = address.lowercased()
            guard !key.isEmpty, !me.contains(key) else { continue }
            lastSent[key] = max(lastSent[key] ?? stamp, stamp)
        }
        evict()
    }

    /// Drops `addresses` (e.g. a newly learnt own address).
    public mutating func remove(_ addresses: some Sequence<String>) {
        for address in addresses { lastSent[address.lowercased()] = nil }
    }

    private mutating func evict() {
        let excess = lastSent.count - max(capacity, 0)
        guard excess > 0 else { return }
        // Oldest first; ties by address so the result is deterministic.
        let victims = lastSent.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(excess)
        for (key, _) in victims { lastSent[key] = nil }
    }

    // The file keeps only the map (design §9.2 `"sent": {"addr@x.fi": 1791000000}`).
    public init(from decoder: any Decoder) throws {
        lastSent = try decoder.singleValueContainer().decode([String: Int].self)
        capacity = Self.defaultCapacity
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(lastSent)
    }
}
