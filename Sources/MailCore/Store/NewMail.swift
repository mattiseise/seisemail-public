import Foundation
import Observation

public enum NewMailEvent: Equatable, Sendable {
    case single(ThreadSummary)
    case summary(count: Int)

    public var threadID: String? {
        if case .single(let summary) = self { return summary.id }
        return nil
    }
}

/// Decides which unread inbox threads are new since the previous check.
/// The first check only records a baseline so launching the app does not flood notifications.
public struct NewMailDetector: Sendable {
    private var seen: Set<String>?
    public let maxIndividual: Int

    public init(maxIndividual: Int = 3) {
        self.maxIndividual = maxIndividual
    }

    public mutating func process(_ unread: [ThreadSummary]) -> [NewMailEvent] {
        let ids = Set(unread.map(\.id))
        defer { seen = ids } // a thread read in between and unread again counts as new
        guard let seen else { return [] }
        let fresh = unread.filter { !seen.contains($0.id) }
        if fresh.count > maxIndividual { return [.summary(count: fresh.count)] }
        return fresh.map { .single($0) }
    }

    /// Treats `id` as already seen, e.g. when the user marked it unread themselves.
    public mutating func acknowledge(_ id: String) {
        seen?.insert(id)
    }
}

/// Polls unread inbox threads independently of the view on screen; feeds the menu bar,
/// the Dock badge and new-mail notifications.
@MainActor @Observable
public final class InboxMonitor {
    public private(set) var unread: [ThreadSummary] = []
    public private(set) var unreadCount = 0

    @ObservationIgnored private let api: GmailAPI
    @ObservationIgnored private var detector = NewMailDetector()
    @ObservationIgnored private let limit: Int

    public init(api: GmailAPI, limit: Int = 20) {
        self.api = api
        self.limit = limit
    }

    @ObservationIgnored private var recountTask: Task<Void, Never>?

    public func check(me: String? = nil) async -> [NewMailEvent] {
        guard let summaries = await fetch(me: me) else { return [] }
        return detector.process(summaries)
    }

    /// Reloads the unread list and count without deciding what is new.
    public func recount(me: String? = nil) async {
        _ = await fetch(me: me)
    }

    /// The user read or unread a thread in the app: update at once, then confirm from Gmail.
    public func noteChange(threadID: String, unread isUnread: Bool, me: String? = nil, then done: @escaping @MainActor () -> Void = {}) {
        if isUnread {
            detector.acknowledge(threadID) // marked unread by hand: no notification for it
        } else if let i = unread.firstIndex(where: { $0.id == threadID }) {
            unread.remove(at: i)
            unreadCount = max(0, unreadCount - 1)
        }
        recountTask?.cancel()
        recountTask = Task { [weak self] in
            // Lets the label change reach Gmail and coalesces bulk actions.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.recount(me: me)
            done()
        }
    }

    private func fetch(me: String?) async -> [ThreadSummary]? {
        do {
            let page = try await api.listThreads(query: "in:inbox is:unread", pageToken: nil, maxResults: limit)
            var summaries: [ThreadSummary] = []
            for id in page.ids {
                summaries.append(try await api.threadSummary(id: id, me: me))
            }
            let count = (try? await api.inboxUnreadCount()) ?? summaries.count
            unread = summaries
            unreadCount = count
            return summaries
        } catch {
            return nil
        }
    }
}
