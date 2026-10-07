import Foundation
import Observation

/// One account's snooze objects (core design §9.1 item 5): one LabelDirectory shared by the service and a client
/// waker. The waker uses the default Options(), so cleansUp == false: clients never delete labels (conventions §1).
@MainActor @Observable
public final class SnoozeAccount {
    public let scheme: SnoozeLabelScheme
    public let directory: LabelDirectory
    public let service: SnoozeService
    public let waker: SnoozeWaker
    /// The directory's last snapshot, for the rows; nil until one load succeeded.
    public private(set) var labels: LabelSnapshot?
    /// Snoozed thread count and next wake, for the sidebar, Inbox 0 and the menu bar; nil until one read succeeded.
    public private(set) var summary: SnoozeSummary?
    private let api: any GmailLabelsAPI
    private let now: @Sendable () -> Date

    /// nil unless `api` also implements GmailLabelsAPI (LiveGmailClient does; plain FakeGmail does not).
    public init?(api: any GmailAPI, scheme: SnoozeLabelScheme = .standard,
                 now: @escaping @Sendable () -> Date = { Date() }) {
        guard let labelsAPI = api as? any GmailLabelsAPI else { return nil }
        let directory = LabelDirectory(api: labelsAPI)
        self.api = labelsAPI
        self.now = now
        self.scheme = scheme
        self.directory = directory
        service = SnoozeService(api: labelsAPI, directory: directory, scheme: scheme, now: now)
        waker = SnoozeWaker(api: labelsAPI, directory: directory, scheme: scheme, now: now)
    }

    /// Re-reads the summary: 1 unit for the marker, plus 1 per time label probed (SnoozeSummary.load).
    /// Uses the directory's snapshot (network only on its first load). Errors keep the last value.
    public func refreshSummary() async {
        guard let snapshot = try? await directory.snapshot(),
              let fresh = try? await SnoozeSummary.load(api: api, labels: snapshot, scheme: scheme, now: now()) else { return }
        if fresh != summary { summary = fresh }
    }

    public var markerID: String? { labels?.id(forName: scheme.marker) }

    /// Network only on the first load or for IDs the directory never saw; errors keep the old snapshot.
    public func reloadNames(knowing ids: Set<String> = []) async {
        guard let snap = try? await directory.snapshot(knowing: ids), snap != labels else { return }
        labels = snap
    }

    /// Creates the sorting labels Käsiteltävät's query excludes when missing (shown, conventions §2–3:
    /// clients may create them; only the daemon puts them on threads). Returns the names it could not
    /// confirm.
    public func ensureInboxZeroLabels() async -> Set<String> {
        await directory.ensureExisting(InboxZero.excludedFromDefault, visibility: .shown)
    }

    public func rowLabel(for labelIDs: Set<String>, now: Date) -> String? {
        SnoozeText.rowLabel(labelIDs: labelIDs, labels: labels, scheme: scheme, now: now)
    }
}
