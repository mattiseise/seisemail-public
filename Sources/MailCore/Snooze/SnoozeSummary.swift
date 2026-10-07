import Foundation

/// How much is snoozed for one account: threads carrying the marker and the earliest pending wake.
public struct SnoozeSummary: Sendable, Equatable {
    /// Threads carrying the marker (labels.get `threadsTotal`), read or not.
    public var total: Int
    /// The earliest time label that still has threads; nil when none was found within the probes.
    public var nextWake: Date?

    public init(total: Int, nextWake: Date?) {
        self.total = total
        self.nextWake = nextWake
    }

    public static let empty = SnoozeSummary(total: 0, nextWake: nil)

    /// Time labels this far in the past still count as pending: the wake pass may not have reached them yet.
    /// Older ones are leftovers until the daemon cleans them up (conventions §1) and are never probed.
    static let overdueWindow: TimeInterval = 10 * 60

    /// Reads it from Gmail: 1 unit for the marker, then 1 per time label probed in wake order, at most
    /// `maxProbes`. No marker label means nothing was ever snoozed: no network.
    static func load(api: any GmailLabelsAPI, labels: LabelSnapshot, scheme: SnoozeLabelScheme, now: Date,
                     maxProbes: Int = 8) async throws -> SnoozeSummary {
        guard let markerID = labels.id(forName: scheme.marker) else { return .empty }
        let total = try await api.labelCounts(id: markerID).threadsTotal
        guard total > 0 else { return .empty }
        let earliest = now.addingTimeInterval(-overdueWindow)
        let candidates = labels.labels
            .compactMap { info in scheme.wakeDate(fromLabelName: info.name).map { (wake: $0, id: info.id) } }
            .filter { $0.wake >= earliest }
            .sorted { $0.wake < $1.wake }
        for candidate in candidates.prefix(maxProbes) where try await api.labelCounts(id: candidate.id).threadsTotal > 0 {
            return SnoozeSummary(total: total, nextWake: candidate.wake)
        }
        return SnoozeSummary(total: total, nextWake: nil)
    }
}
