import Foundation

/// Snooze label names as one value, so a rename or the Graph mapping is data, not code. The standard names
/// (Torkku, Torkku/) were decided 2026-10-03.
public struct SnoozeLabelScheme: Sendable, Equatable {
    /// "Torkku"
    public var marker: String
    /// "Torkku/"
    public var timePrefix: String
    public var markerVisibility: LabelVisibility
    public var timeVisibility: LabelVisibility

    /// Precondition: the marker is not under the time prefix.
    public init(marker: String, timePrefix: String, markerVisibility: LabelVisibility = .shown, timeVisibility: LabelVisibility = .hidden) {
        precondition(!marker.utf8.starts(with: timePrefix.utf8), "Snooze marker \(marker) is under \(timePrefix)")
        self.marker = marker
        self.timePrefix = timePrefix
        self.markerVisibility = markerVisibility
        self.timeVisibility = timeVisibility
    }

    public static let standard = SnoozeLabelScheme(marker: SeiseLabels.snoozeMarker, timePrefix: SeiseLabels.snoozeTimePrefix)

    public func timeLabelName(for wakeAt: Date) -> String {
        timePrefix + SnoozeTime.encode(wakeAt)
    }

    /// nil unless `name` starts with the prefix (byte-exact, so case-sensitive) and the rest is a valid stamp.
    public func wakeDate(fromLabelName name: String) -> Date? {
        guard isTimeLabel(name) else { return nil }
        return SnoozeTime.decode(utf8: Array(name.utf8.dropFirst(timePrefix.utf8.count)))
    }

    /// Under the prefix, valid or not (used for removal).
    public func isTimeLabel(_ name: String) -> Bool {
        name.utf8.starts(with: timePrefix.utf8)
    }

    /// Earliest valid wake among `labelIDs`; IDs missing from `namesByID` are ignored.
    public func earliestWakeDate(labelIDs: Set<String>, namesByID: [String: String]) -> Date? {
        labelIDs.compactMap { namesByID[$0].flatMap(wakeDate(fromLabelName:)) }.min()
    }

    /// Search query for the Torkku view: "label:torkku".
    public var viewQuery: String { SearchSyntax.label(marker) }
}
