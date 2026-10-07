import Foundation
import Observation
import os

/// App state: views, the active thread list, the open thread and optimistic mail actions.
@MainActor @Observable
public final class MailStore {
    private enum LocalChange {
        case removed(String)
        case restored(ThreadSummary, index: Int)
        case labels(String, add: [String], remove: [String])
    }

    private enum UndoAction {
        case archive(ThreadSummary, index: Int, removed: Bool)
        case trash(ThreadSummary, index: Int)
        case star(threadID: String, added: Bool)
        case unread(threadID: String)
        case read(threadID: String)
        /// Fork (seisemail): a `relabel` action (snooze), one thread or several; undone as one step,
        /// also while it is still running.
        case relabel(RelabelJob)
        /// A multi-select action; undone as one step, also while it is still running.
        case batch(BulkJob)
    }

    /// One multi-select action: its rows, what it changes and how far it got.
    private struct PendingRemoval {
        let jobID: UUID
        let trashed: Bool
        /// When the job finished; nil while it runs.
        var releasedAt: ContinuousClock.Instant?

        /// Archived rows stay off inbox lists; trashed rows off every list but the trash.
        func hides(in query: String) -> Bool {
            // Fork (seisemail): "-in:inbox" does not list the inbox; "label:inbox" does (as snooze's predicate).
            if !trashed { return SearchSyntax.hasPositiveTerm(query, "in:inbox") || SearchSyntax.hasPositiveTerm(query, "label:inbox") }
            let terms = query.split(separator: " ")
            return !(terms.contains("in:trash") || (terms.contains("in:anywhere") && !terms.contains("-in:trash")))
        }
    }

    @MainActor private final class BulkJob {
        let action: BulkStatus.Action
        let statusID = UUID()
        /// In list order, with each row's index when the action started.
        let items: [(summary: ThreadSummary, index: Int)]
        /// The list the rows were removed from; they only go back into that list.
        let query: String?
        let removesRows: Bool
        let add: [String]
        let remove: [String]
        var succeeded: Set<String> = []
        var failed: Set<String> = []
        /// ⌘Z while running: send nothing more; undo takes care of the rest.
        var undoRequested = false
        /// Gmail still rate limited a request after its whole deadline: start nothing more.
        var gaveUp = false
        var isDone = false
        var task: Task<Void, Never>?
        /// Fork (seisemail): threads this job gave the daily counter; a ⌘Z takes them back.
        var countedArchived = 0

        init(action: BulkStatus.Action, items: [(summary: ThreadSummary, index: Int)], query: String?,
             removesRows: Bool, add: [String], remove: [String]) {
            self.action = action
            self.items = items
            self.query = query
            self.removesRows = removesRows
            self.add = add
            self.remove = remove
        }
    }

    /// Fork (seisemail): one `relabel` action (snooze) on the selected thread or the checked ones. As with
    /// BulkJob, its undo entry exists before anything is sent, so ⌘Z while it runs takes back this action
    /// and not an older one, and a final rate limit ends it within about one request deadline.
    @MainActor private final class RelabelJob {
        /// In list order, with each row's index when the action started.
        let items: [(summary: ThreadSummary, index: Int)]
        /// The list the rows were removed from; they only go back into that list.
        let query: String?
        let removesRows: Bool
        /// Applied locally at once when the rows stay.
        let optimistic: LabelChange
        /// The `pendingRemoved` entries of removed rows.
        var pendingID: UUID?
        var outcomes: [String: RelabelOutcome] = [:]
        var failed: Set<String> = []
        var firstError: Error?
        /// ⌘Z while running: send nothing more; undo takes care of the rest.
        var undoRequested = false
        /// Gmail still rate limited a request after its whole deadline: start nothing more.
        var gaveUp = false
        var isDone = false
        var task: Task<Void, Never>?
        /// Threads this job gave the daily counter; a ⌘Z takes them back.
        var countedSnoozed = 0

        init(items: [(summary: ThreadSummary, index: Int)], query: String?, removesRows: Bool, optimistic: LabelChange) {
            self.items = items
            self.query = query
            self.removesRows = removesRows
            self.optimistic = optimistic
        }
    }

    @ObservationIgnored private let api: GmailAPI
    @ObservationIgnored private let viewsStore: ViewsConfigStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cache: [String: MailThread] = [:]
    @ObservationIgnored private var nextPageToken: String?
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var openGeneration = 0
    /// Local edits made while a refresh is in flight; replayed onto its (older) result.
    @ObservationIgnored private var changesDuringRefresh: [LocalChange]?
    /// Rows a multi-select action removed: lists of the same kind must not bring them back while
    /// the action runs, nor if they were asked before Gmail's search caught up with it.
    @ObservationIgnored private var pendingRemoved: [String: PendingRemoval] = [:]
    /// How long Gmail search may still list a thread after a label change.
    @ObservationIgnored var searchLagGrace: Duration = .seconds(10)
    private var undoStack: [UndoAction] = [] {
        didSet { noteUndoStackChange(from: oldValue) }        // fork (seisemail): daily counter
    }
    /// An undo is still waiting on Gmail; a second ⌘Z must not take back an older action meanwhile.
    private var isUndoing = false

    public private(set) var me: String?
    public private(set) var views: [MailView]
    public private(set) var activeViewID: MailView.ID?
    public private(set) var searchQuery: String?
    public private(set) var threads: [ThreadSummary] = []
    public private(set) var isLoading = false
    public private(set) var canLoadMore = false
    public private(set) var selectedThreadID: String?
    public private(set) var openThread: MailThread?
    /// Whether the side peek shows the selected thread. With it closed, j/k only move the highlight.
    public private(set) var isPeekOpen = false
    /// Multi-selected threads; when non-empty, actions apply to all of them.
    public private(set) var checkedIDs: Set<String> = []
    @ObservationIgnored private var checkAnchor: String?
    public private(set) var unreadCounts: [MailView.ID: Int] = [:]
    /// Multi-select actions in progress or just finished, oldest first.
    public private(set) var bulkStatuses: [BulkStatus] = []
    /// The filter bar's chips for the open view; differs from the view's saved filters until saved.
    public private(set) var draftFilters: [MailFilter] = []
    public private(set) var isOffline = false
    public private(set) var needsSignIn = false
    /// Fork (seisemail): whether the list on screen came from a successful load (empty states).
    public private(set) var listLoadState: ListLoadState = .notLoaded
    public var toast: String?
    public var markReadPolicy: MarkReadPolicy = .immediately
    public var afterArchive: AfterArchive = .next
    @ObservationIgnored public var markReadDelay: Duration = .seconds(2)
    @ObservationIgnored var pendingRead: Task<Void, Never>?
    /// Called when a thread is marked read (`false`) or unread (`true`) here, for badges kept elsewhere.
    @ObservationIgnored public var onUnreadChanged: ((_ threadID: String, _ unread: Bool) -> Void)?
    /// Fork (seisemail): archive/snooze done (+) or undone (−), for the daily counter. Unset on iOS.
    @ObservationIgnored public var onActivity: ((ActivityCounts) -> Void)?
    /// Fork (seisemail): views that are exactly one label, by query → label ID. Their unread badge comes
    /// from labels.get (1 unit) instead of a search (10). SnoozeCoordinator adds "label:torkku".
    @ObservationIgnored public var countLabelIDs: [String: String] = ["is:starred": GmailLabel.starred]
    /// Fork (seisemail): sorting labels not confirmed to exist; their `-label:` exclusions are left out of
    /// what is sent to Gmail (`InboxZero.serverQuery`). Set with `setMissingLabels`.
    @ObservationIgnored public private(set) var missingLabelNames: Set<String> = []
    @ObservationIgnored private var countsTask: Task<Void, Never>?

    public init(api: GmailAPI, viewsStore: ViewsConfigStore, pageSize: Int = 50) {
        self.api = api
        self.viewsStore = viewsStore
        self.pageSize = pageSize
        self.views = viewsStore.load()
        self.activeViewID = views.first?.id
        self.draftFilters = views.first?.filters ?? []
    }

    private var activeView: MailView? {
        (views + MailView.folders).first { $0.id == activeViewID }
    }

    public var activeQuery: String? {
        searchQuery ?? activeView.map { MailFilter.query(base: $0.query, draftFilters) }
    }

    public var activeTitle: String {
        if let searchQuery { return "Haku: \(searchQuery)" }
        return activeView?.name ?? ""
    }

    public var canUndo: Bool { !undoStack.isEmpty && !isUndoing }

    public var selectedSummary: ThreadSummary? {
        threads.first { $0.id == selectedThreadID }
    }

    // MARK: - Loading

    public func start() async {
        do {
            me = try await api.profileEmail()
            succeeded()
        } catch {
            handle(error, toast: nil)
            if needsSignIn { return }
        }
        await reloadList()
        await refreshCounts()
    }

    public func selectView(_ id: MailView.ID) async {
        activeViewID = id
        searchQuery = nil
        draftFilters = activeView?.filters ?? []
        await reloadList()
    }

    // MARK: - Filters

    /// The chips differ from what the open view has saved.
    public var filtersChanged: Bool {
        searchQuery == nil && draftFilters != (activeView?.filters ?? [])
    }

    /// Whether the open view is one of the user's views, so its filters can be saved into it.
    public var canSaveFiltersToView: Bool {
        views.contains { $0.id == activeViewID }
    }

    public func addFilter(_ filter: MailFilter) async {
        await setFilters(draftFilters + [filter])
    }

    public func updateFilter(_ filter: MailFilter) async {
        await setFilters(draftFilters.map { $0.id == filter.id ? filter : $0 })
    }

    public func removeFilter(_ id: MailFilter.ID) async {
        await setFilters(draftFilters.filter { $0.id != id })
    }

    /// Reloads only when the Gmail query changes; a chip still without a value changes nothing.
    public func setFilters(_ filters: [MailFilter]) async {
        let previousQuery = activeQuery
        draftFilters = filters
        if activeQuery != previousQuery { await reloadList() }
    }

    /// Writes the chips into the open view.
    public func saveFilters() {
        guard let i = views.firstIndex(where: { $0.id == activeViewID }) else { return }
        views[i].filters = draftFilters
        persistViews()
        Task { await refreshCounts() }
    }

    public func resetFilters() async {
        await setFilters(activeView?.filters ?? [])
    }

    /// A new view with the open view's search and the chips; the open view stays as it was.
    public func saveFiltersAsView(name: String) {
        guard let base = activeView else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let view = MailView(name: trimmed.isEmpty ? base.name : trimmed, query: base.query, filters: draftFilters)
        views.append(view)
        persistViews()
        activeViewID = view.id
        Task { await refreshCounts() }
    }

    public func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed.isEmpty ? nil : trimmed
        await reloadList()
    }

    public func saveSearchAsView(name: String) {
        guard let searchQuery else { return }
        let view = MailView(name: name, query: searchQuery)
        views.append(view)
        persistViews()
        activeViewID = view.id
        self.searchQuery = nil
        draftFilters = []
    }

    public func updateViews(_ newViews: [MailView]) async {
        let previousQuery = activeQuery
        let previousSaved = activeView?.filters
        views = newViews
        persistViews()
        if searchQuery == nil, activeView == nil {
            activeViewID = views.first?.id
            draftFilters = activeView?.filters ?? []
        } else if activeView?.filters != previousSaved {
            draftFilters = activeView?.filters ?? []
        }
        if activeQuery != previousQuery { await reloadList() }
        await refreshCounts()
    }

    /// A new view on the inbox, opened so the filter bar can shape it.
    public func createView(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let view = MailView(name: trimmed.isEmpty ? "Uusi näkymä" : trimmed, query: "in:inbox")
        await updateViews(views + [view])
        await selectView(view.id)
    }

    /// Copies the view right after the original; its filters get new ids.
    public func duplicateView(_ id: MailView.ID) async {
        guard let i = views.firstIndex(where: { $0.id == id }) else { return }
        let original = views[i]
        let copy = MailView(
            name: "\(original.name) (kopio)",
            query: original.query,
            icon: original.icon,
            filters: original.filters.map { MailFilter($0.kind, negated: $0.negated) }
        )
        var next = views
        next.insert(copy, at: i + 1)
        await updateViews(next)
    }

    /// Moves a view in front of `target`; nil moves it last.
    public func moveView(_ id: MailView.ID, before target: MailView.ID?) async {
        guard id != target, let view = views.first(where: { $0.id == id }) else { return }
        var next = views.filter { $0.id != id }
        let index = target.flatMap { t in next.firstIndex { $0.id == t } } ?? next.count
        next.insert(view, at: index)
        await updateViews(next)
    }

    public func editView(_ id: MailView.ID, _ change: (inout MailView) -> Void) async {
        guard let i = views.firstIndex(where: { $0.id == id }) else { return }
        var next = views
        change(&next[i])
        await updateViews(next)
    }

    /// The last view cannot be deleted.
    public func deleteView(_ id: MailView.ID) async {
        guard views.count > 1 else { return }
        await updateViews(views.filter { $0.id != id })
    }

    public func loadMore() async {
        guard let token = nextPageToken, let query = activeQuery, !isLoading else { return }
        let generation = listGeneration
        let startedAt = ContinuousClock.now
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        do {
            let page = try await api.listThreads(query: serverQuery(query), pageToken: token, maxResults: pageSize)
            let summaries = try await fetchSummaries(page.ids)
            guard generation == listGeneration else { return }
            let existing = Set(threads.map(\.id))
            threads += summaries.filter { !existing.contains($0.id) && !isPendingRemoved($0.id, in: query, listedAt: startedAt) }
            nextPageToken = page.nextPageToken
            canLoadMore = page.nextPageToken != nil
            succeeded()
        } catch {
            handle(error, toast: "Viestien lataus epäonnistui")
        }
    }

    public func refresh() async {
        if me == nil { me = try? await api.profileEmail() }
        await mergeFirstPage()
        await refreshCounts()
    }

    /// Fetches page 1 and merges it into the loaded list: new mail appears on top, loaded older pages
    /// and the open thread stay put, and actions taken meanwhile are not overwritten.
    private func mergeFirstPage() async {
        guard let query = activeQuery else { return }
        listGeneration += 1
        let generation = listGeneration
        let startedAt = ContinuousClock.now
        changesDuringRefresh = []
        defer { if generation == listGeneration { changesDuringRefresh = nil } }
        do {
            let page = try await api.listThreads(query: serverQuery(query), pageToken: nil, maxResults: pageSize)
            let fresh = try await fetchSummaries(page.ids)
            guard generation == listGeneration else { return }
            succeeded()
            listLoadState = .loaded                                  // fork (seisemail)

            let freshIDs = Set(fresh.map(\.id))
            var tail: [ThreadSummary] = []
            if page.nextPageToken != nil {
                if let last = fresh.last, let k = threads.firstIndex(where: { $0.id == last.id }) {
                    tail = threads[(k + 1)...].filter { !freshIDs.contains($0.id) }
                } else {
                    tail = threads.dropFirst(pageSize).filter { !freshIDs.contains($0.id) }
                }
            }
            var merged = (fresh + tail).filter { !isPendingRemoved($0.id, in: query, listedAt: startedAt) }
            for change in changesDuringRefresh ?? [] {
                switch change {
                case .removed(let id):
                    merged.removeAll { $0.id == id }
                case .restored(let summary, let index):
                    if !merged.contains(where: { $0.id == summary.id }) {
                        merged.insert(summary, at: min(index, merged.count))
                    }
                case .labels(let id, let add, let remove):
                    if let i = merged.firstIndex(where: { $0.id == id }) {
                        merged[i].labelIDs.formUnion(add)
                        merged[i].labelIDs.subtract(remove)
                    }
                }
            }
            for summary in merged {
                if let cached = cache[summary.id], cached.messages.count != summary.messageCount {
                    cache[summary.id] = nil
                }
            }
            threads = merged
            checkedIDs.formIntersection(merged.map(\.id))
            if tail.isEmpty {
                nextPageToken = page.nextPageToken
                canLoadMore = page.nextPageToken != nil
            }
            if let selected = selectedThreadID {
                if !threads.contains(where: { $0.id == selected }) {
                    await select(threadID: nil)
                } else if isPeekOpen, cache[selected] == nil {
                    await reloadOpenThread(selected)
                }
            }
        } catch {
            // fork (seisemail): a superseded reloadList left the list unloaded; without this it spins forever.
            if generation == listGeneration, listLoadState != .loaded { listLoadState = .failed }
            handle(error, toast: "Viestien lataus epäonnistui")
        }
    }

    private func reloadList() async {
        guard let query = activeQuery else { return }
        listGeneration += 1
        let generation = listGeneration
        let startedAt = ContinuousClock.now
        threads = []
        listLoadState = .notLoaded                                   // fork (seisemail)
        clearChecked()
        await select(threadID: nil)
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        do {
            let page = try await api.listThreads(query: serverQuery(query), pageToken: nil, maxResults: pageSize)
            let summaries = try await fetchSummaries(page.ids)
            guard generation == listGeneration else { return }
            threads = summaries.filter { !isPendingRemoved($0.id, in: query, listedAt: startedAt) }
            nextPageToken = page.nextPageToken
            canLoadMore = page.nextPageToken != nil
            succeeded()
            listLoadState = .loaded                                  // fork (seisemail)
        } catch {
            if generation == listGeneration { listLoadState = .failed }   // fork (seisemail)
            handle(error, toast: "Viestien lataus epäonnistui")
        }
    }

    private func fetchSummaries(_ ids: [String]) async throws -> [ThreadSummary] {
        let api = self.api
        let me = self.me
        return try await withThrowingTaskGroup(of: (Int, ThreadSummary).self) { group in
            var results = [ThreadSummary?](repeating: nil, count: ids.count)
            var next = 0
            func enqueue() {
                let i = next
                next += 1
                group.addTask { (i, try await api.threadSummary(id: ids[i], me: me)) }
            }
            for _ in 0..<min(10, ids.count) { enqueue() }
            while let (i, summary) = try await group.next() {
                results[i] = summary
                if next < ids.count { enqueue() }
            }
            return results.compactMap { $0 }
        }
    }

    /// Sidebar counts come from Gmail; refetch them shortly after a read/unread change.
    private func scheduleCountsRefresh() {
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            // Gmail search lags label changes by a few seconds; the second pass catches up.
            for delay in [2, 8] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.refreshCounts()
            }
        }
    }

    public func refreshCounts() async {
        let api = self.api
        let targets = views.map { ($0.id, serverQuery($0.effectiveQuery)) }   // fork (seisemail): serverQuery
        let labelIDs = countLabelIDs                                    // fork (seisemail)
        let counts = await withTaskGroup(of: (MailView.ID, Int?).self) { group in
            for (id, query) in targets {
                group.addTask {
                    let count = query == "in:inbox"
                        ? try? await api.inboxUnreadCount()
                        : try? await Self.unreadCount(api: api, query: query, labelID: labelIDs[query])
                    return (id, count)
                }
            }
            var acc: [MailView.ID: Int] = [:]
            for await (id, count) in group {
                if let count { acc[id] = count }
            }
            return acc
        }
        // A view whose count could not be fetched keeps its previous badge.
        var merged = counts
        for (id, _) in targets where merged[id] == nil { merged[id] = unreadCounts[id] }
        unreadCounts = merged
    }

    // MARK: - Selection

    public func select(threadID: String?) async {
        openGeneration += 1
        let generation = openGeneration
        pendingRead?.cancel()
        pendingRead = nil
        selectedThreadID = threadID
        isPeekOpen = threadID != nil
        guard let threadID else {
            openThread = nil
            return
        }
        if let cached = cache[threadID] {
            openThread = cached
        } else {
            openThread = nil
            do {
                let thread = try await api.thread(id: threadID)
                guard generation == openGeneration else { return }
                cache[threadID] = thread
                openThread = thread
                succeeded()
            } catch {
                guard generation == openGeneration else { return }
                handle(error, toast: "Viestin avaaminen epäonnistui")
                return
            }
        }
        guard openThread?.isUnread == true || threads.first(where: { $0.id == threadID })?.isUnread == true else { return }
        switch markReadPolicy {
        case .immediately:
            await markRead(threadID)
        case .never:
            break
        case .afterDelay:
            let delay = markReadDelay
            pendingRead = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, generation == self.openGeneration else { return }
                await self.markRead(threadID)
            }
        }
    }

    /// Opens a thread from a notification or the menu bar: switches to the inbox view first.
    public func openInInbox(threadID: String) async {
        if activeQuery != "in:inbox", let inbox = views.first(where: { $0.query == "in:inbox" }) {
            await selectView(inbox.id)
        }
        await select(threadID: threadID)
    }

    /// Moves the highlight without opening the thread or marking it read.
    public func highlight(threadID: String?) {
        openGeneration += 1
        selectedThreadID = threadID
        openThread = nil
        isPeekOpen = false
    }

    public func closePeek() {
        guard let selected = selectedThreadID else { return }
        highlight(threadID: selected)
    }

    /// Opens or highlights depending on whether the peek is open.
    private func move(to threadID: String?) async {
        if isPeekOpen, threadID != nil {
            await select(threadID: threadID)
        } else {
            highlight(threadID: threadID)
        }
    }

    private func reloadOpenThread(_ id: String) async {
        let generation = openGeneration
        guard let thread = try? await api.thread(id: id), generation == openGeneration, selectedThreadID == id else { return }
        cache[id] = thread
        openThread = thread
    }

    public func selectNext() async {
        guard !threads.isEmpty else { return }
        guard let current = selectedIndex else {
            await move(to: threads[0].id)
            return
        }
        if current + 1 >= threads.count, canLoadMore {
            await loadMore()
        }
        if current + 1 < threads.count {
            await move(to: threads[current + 1].id)
        }
    }

    public func selectPrevious() async {
        guard !threads.isEmpty else { return }
        guard let current = selectedIndex else {
            await move(to: threads[0].id)
            return
        }
        if current > 0 { await move(to: threads[current - 1].id) }
    }

    private var selectedIndex: Int? {
        threads.firstIndex { $0.id == selectedThreadID }
    }

    public func cached(threadID: String) -> MailThread? { cache[threadID] }

    // MARK: - Multi-select

    public func toggleChecked(_ id: String) {
        if checkedIDs.contains(id) { checkedIDs.remove(id) } else { checkedIDs.insert(id) }
        checkAnchor = id
        if isPeekOpen { closePeek() }
    }

    /// Checks every thread between the last toggled (or highlighted) thread and `id`.
    public func checkRange(to id: String) {
        guard let end = threads.firstIndex(where: { $0.id == id }) else { return }
        let anchorID = checkAnchor ?? selectedThreadID ?? id
        let start = threads.firstIndex { $0.id == anchorID } ?? end
        checkedIDs.formUnion(threads[min(start, end)...max(start, end)].map(\.id))
        checkAnchor = id
        if isPeekOpen { closePeek() }
    }

    public func checkAll() {
        checkedIDs = Set(threads.map(\.id))
        if isPeekOpen { closePeek() }
    }

    public func clearChecked() {
        checkedIDs = []
        checkAnchor = nil
    }

    /// Checked threads in list order.
    private var checkedInOrder: [(summary: ThreadSummary, index: Int)] {
        threads.enumerated().filter { checkedIDs.contains($0.element.id) }.map { ($0.element, $0.offset) }
    }

    /// Runs `operation` for each thread, at most 10 at a time; returns the ids that failed.
    /// Stops starting new ones once `shouldContinue` is false; those ids are neither done nor failed.
    private func runEach(
        _ ids: [String],
        while shouldContinue: @escaping () -> Bool = { true },
        onResult: @escaping (_ id: String, _ error: Error?) -> Void = { _, _ in },
        _ operation: @escaping @Sendable (GmailAPI, String) async throws -> Void
    ) async -> Set<String> {
        let api = self.api
        var failed: Set<String> = []
        await withTaskGroup(of: (String, Error?).self) { group in
            var next = 0
            func enqueue() {
                guard next < ids.count, shouldContinue() else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    do { try await operation(api, id); return (id, nil) } catch { return (id, error) }
                }
            }
            for _ in 0..<min(10, ids.count) { enqueue() }
            while let (id, error) = await group.next() {
                if let error {
                    failed.insert(id)
                    handle(error, toast: nil)
                }
                onResult(id, error)
                enqueue()
            }
        }
        return failed
    }

    /// "Toiminto epäonnistui 1 ketjussa (yhteensä 3)"; all failed: "Toiminto epäonnistui kaikissa 5 ketjussa".
    private func reportPartialFailure(_ failed: Int, of total: Int) {
        guard failed > 0 else { return }
        toast = switch (failed, total) {
        case (1, 1): "Toiminto epäonnistui"
        case _ where failed == total: "Toiminto epäonnistui kaikissa \(total) ketjussa"
        default: "Toiminto epäonnistui \(failed) ketjussa (yhteensä \(total))"
        }
    }

    private func bulkRemove(trashing: Bool) async {
        let items = checkedInOrder
        guard !items.isEmpty else { return }
        let removes = trashing || listsInbox
        clearChecked()
        await runBulk(trashing ? .trash : .archive, items: items, removesRows: removes, add: [], remove: trashing ? [] : [GmailLabel.inbox])
    }

    private func bulkLabels(_ action: BulkStatus.Action, add: [String], remove: [String]) async {
        // The selection stays, so star and read toggles can be repeated on the same rows.
        await runBulk(action, items: checkedInOrder, removesRows: false, add: add, remove: remove)
    }

    /// Applies a multi-select action at once on screen, then on Gmail in the background with a
    /// status line. The undo entry exists from the start, so ⌘Z undoes the whole batch even
    /// mid-way. Only threads that finally fail come back, with "x/y epäonnistui".
    private func runBulk(_ action: BulkStatus.Action, items: [(summary: ThreadSummary, index: Int)], removesRows: Bool, add: [String], remove: [String]) async {
        guard !items.isEmpty else { return }
        let job = BulkJob(action: action, items: items, query: activeQuery, removesRows: removesRows, add: add, remove: remove)
        if removesRows {
            prunePendingRemovals()
            for item in items {
                pendingRemoved[item.summary.id] = PendingRemoval(jobID: job.statusID, trashed: action == .trash)
            }
            for item in items.reversed() { removeRow(at: item.index) }
            let firstIndex = items[0].index
            highlight(threadID: firstIndex < threads.count ? threads[firstIndex].id : threads.last?.id)
        } else {
            for item in items { applyLabels(item.summary.id, add: add, remove: remove) }
        }
        bulkStatuses.append(BulkStatus(id: job.statusID, action: action, total: items.count))
        undoStack.append(.batch(job))
        let task = Task { await self.execute(job) }
        job.task = task
        await task.value
    }

    private func execute(_ job: BulkJob) async {
        let summaries = job.items.map(\.summary)
        let record: (String, Error?) -> Void = { [weak self] id, error in
            if let error {
                job.failed.insert(id)
                if let e = error as? GmailError, e == .rateLimited { job.gaveUp = true }
            } else {
                job.succeeded.insert(id)
            }
            self?.updateStatus(job)
        }
        let goOn = { !job.undoRequested && !job.gaveUp }
        if job.action == .trash {
            _ = await runEach(summaries.map(\.id), while: goOn, onResult: record) { api, id in
                try await api.trash(threadID: id)
            }
        } else {
            let (batches, singles) = Self.plan(summaries)
            for batch in batches {
                guard goOn() else { break }
                do {
                    try await api.batchModify(messageIDs: batch.flatMap(\.messageIDs), add: job.add, remove: job.remove)
                    for summary in batch { record(summary.id, nil) }
                } catch {
                    handle(error, toast: nil)
                    for summary in batch { record(summary.id, error) }
                }
            }
            let (add, remove) = (job.add, job.remove)
            _ = await runEach(singles, while: goOn, onResult: record) { api, id in
                try await api.modify(threadID: id, add: add, remove: remove)
            }
        }
        // After a final rate limit the rest was never sent: those come back as failed too, so a
        // sustained limit ends the job within about one request deadline, not one per thread.
        if job.gaveUp, !job.undoRequested {
            for item in job.items where !job.succeeded.contains(item.summary.id) { job.failed.insert(item.summary.id) }
            updateStatus(job)
        }
        finish(job)
    }

    /// From this many threads up, one messages.batchModify (50 units) is cheaper than a
    /// threads.modify (10 units) per thread.
    static let batchModifyMinThreads = 5

    /// Rows that know their message ids go in thread-aligned messages.batchModify calls of up to
    /// 1,000 ids when there are enough of them; the rest go one thread at a time (threads.modify).
    private static func plan(_ summaries: [ThreadSummary]) -> (batches: [[ThreadSummary]], singles: [String]) {
        let batchable = summaries.filter { !$0.messageIDs.isEmpty && $0.messageIDs.count <= LiveGmailClient.batchModifyLimit }
        guard batchable.count >= batchModifyMinThreads else { return ([], summaries.map(\.id)) }
        let batched = Set(batchable.map(\.id))
        return (batches(batchable), summaries.map(\.id).filter { !batched.contains($0) })
    }

    /// Thread-aligned groups of at most 1,000 message ids.
    private static func batches(_ summaries: [ThreadSummary]) -> [[ThreadSummary]] {
        var out: [[ThreadSummary]] = []
        var current: [ThreadSummary] = []
        var size = 0
        for summary in summaries {
            if size + summary.messageIDs.count > LiveGmailClient.batchModifyLimit {
                out.append(current)
                current = []
                size = 0
            }
            current.append(summary)
            size += summary.messageIDs.count
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func updateStatus(_ job: BulkJob) {
        guard let i = bulkStatuses.firstIndex(where: { $0.id == job.statusID }) else { return }
        bulkStatuses[i].completed = job.succeeded.count + job.failed.count
        bulkStatuses[i].succeeded = job.succeeded.count
    }

    private func finish(_ job: BulkJob) {
        job.isDone = true
        if job.removesRows {
            // Done rows stay hidden from lists asked before Gmail's search has caught up.
            let now = ContinuousClock.now
            for item in job.items where pendingRemoved[item.summary.id]?.jobID == job.statusID {
                if job.failed.contains(item.summary.id) {
                    pendingRemoved[item.summary.id] = nil
                } else {
                    pendingRemoved[item.summary.id]?.releasedAt = now
                }
            }
        }
        // Threads that finally failed come back.
        restore(job.failed, of: job)
        if job.undoRequested { return }        // the waiting undo restores the rest
        noteFinished(job)                       // fork (seisemail): daily counter
        if job.succeeded.isEmpty {
            bulkStatuses.removeAll { $0.id == job.statusID }
            undoStack.removeAll { if case .batch(let j) = $0 { j === job } else { false } }
        } else if let i = bulkStatuses.firstIndex(where: { $0.id == job.statusID }) {
            bulkStatuses[i].isFinished = true
        }
        reportPartialFailure(job.failed.count, of: job.items.count)
    }

    /// Hides a finished status line.
    public func dismissBulkStatus(_ id: BulkStatus.ID) {
        bulkStatuses.removeAll { $0.id == id && $0.isFinished }
    }

    /// Takes back a multi-select action, waiting for it first if it is still running.
    private func undoBatch(_ job: BulkJob) async throws {
        if let i = bulkStatuses.firstIndex(where: { $0.id == job.statusID }) {
            bulkStatuses[i].isUndoing = true
            bulkStatuses[i].isFinished = false
        }
        if !job.isDone {
            job.undoRequested = true
            await job.task?.value
        }
        defer { bulkStatuses.removeAll { $0.id == job.statusID } }
        for item in job.items where pendingRemoved[item.summary.id]?.jobID == job.statusID {
            pendingRemoved[item.summary.id] = nil
        }
        // Rows never sent only changed on screen; they come back with the reverted ones, in one pass.
        let sent = job.succeeded.union(job.failed)
        let unsent = Set(job.items.map(\.summary.id)).subtracting(sent)
        let done = job.items.filter { job.succeeded.contains($0.summary.id) }
        var reverted: Set<String> = []
        var firstError: Error?
        defer { restore(unsent.union(reverted), of: job) }
        guard !done.isEmpty else { return }
        if job.action == .trash {
            let failed = await runEach(done.map(\.summary.id)) { api, id in try await api.untrash(threadID: id) }
            reverted = Set(done.map(\.summary.id)).subtracting(failed)
        } else {
            let (batches, singles) = Self.plan(done.map(\.summary))
            for batch in batches {
                do {
                    try await api.batchModify(messageIDs: batch.flatMap(\.messageIDs), add: job.remove, remove: job.add)
                    reverted.formUnion(batch.map(\.id))
                } catch {
                    firstError = firstError ?? error
                }
            }
            let (add, remove) = (job.remove, job.add)
            let failed = await runEach(singles) { api, id in try await api.modify(threadID: id, add: add, remove: remove) }
            reverted.formUnion(Set(singles).subtracting(failed))
        }
        if reverted.count < done.count { throw firstError ?? GmailError.http(0, "undo") }
    }

    /// Puts these rows of `job` back as they were before it. Removed rows go back only into the
    /// list they left (another view shows Gmail's state on its next load), each at its old place
    /// counted past the job's rows that are still missing.
    private func restore(_ ids: Set<String>, of job: BulkJob) {
        guard !ids.isEmpty else { return }
        guard job.removesRows else {
            for item in job.items where ids.contains(item.summary.id) {
                applyLabels(item.summary.id, add: job.remove, remove: job.add)
            }
            return
        }
        reinsert(ids, from: job.items, into: job.query)
    }

    /// Puts these removed rows back into the list they left, if it is still open, each at its old
    /// place counted past the action's rows that are still missing.
    private func reinsert(_ ids: Set<String>, from items: [(summary: ThreadSummary, index: Int)], into query: String?) {
        guard !ids.isEmpty, activeQuery == query else { return }
        var present = Set(threads.map(\.id))
        var missingBefore = 0
        for item in items where !present.contains(item.summary.id) {
            if ids.contains(item.summary.id) {
                insertRow(item.summary, at: item.index - missingBefore)
                present.insert(item.summary.id)
            } else {
                missingBefore += 1
            }
        }
    }

    /// Whether a list for `query`, asked at `listedAt`, must leave out `id`.
    private func isPendingRemoved(_ id: String, in query: String, listedAt: ContinuousClock.Instant) -> Bool {
        guard let pending = pendingRemoved[id], pending.hides(in: query) else { return false }
        guard let released = pending.releasedAt else { return true }
        return listedAt < released + searchLagGrace
    }

    /// Drops entries no list can still need: none runs ten minutes.
    private func prunePendingRemovals() {
        let now = ContinuousClock.now
        pendingRemoved = pendingRemoved.filter { _, p in p.releasedAt.map { now - $0 < searchLagGrace + .seconds(600) } ?? true }
    }

    // MARK: - Actions

    private func markRead(_ id: String) async {
        applyLabels(id, add: [], remove: [GmailLabel.unread])
        do {
            try await api.modify(threadID: id, add: [], remove: [GmailLabel.unread])
        } catch {
            applyLabels(id, add: [GmailLabel.unread], remove: [])
            handle(error, toast: nil)
        }
    }

    /// Marks the checked threads, or the highlighted one, as read.
    public func markRead() async {
        if !checkedIDs.isEmpty {
            await bulkLabels(.markRead, add: [], remove: [GmailLabel.unread])
            return
        }
        guard let id = selectedThreadID else { return }
        applyLabels(id, add: [], remove: [GmailLabel.unread])
        do {
            try await api.modify(threadID: id, add: [], remove: [GmailLabel.unread])
            undoStack.append(.read(threadID: id))
        } catch {
            applyLabels(id, add: [GmailLabel.unread], remove: [])
            handle(error, toast: "Merkitseminen epäonnistui")
        }
    }
    /// Fork (seisemail): whether the open list is an inbox list, so archived or snoozed rows leave it.
    /// "-in:inbox" does not list the inbox; "label:inbox" does (the same test as `PendingRemoval.hides`).
    var listsInbox: Bool {
        SearchSyntax.hasPositiveTerm(activeQuery, "in:inbox") || SearchSyntax.hasPositiveTerm(activeQuery, "label:inbox")
    }

    public func archive() async {
        if !checkedIDs.isEmpty { await bulkRemove(trashing: false); return }
        guard let id = selectedThreadID, let index = selectedIndex else { return }
        let summary = threads[index]
        if listsInbox {
            removeRow(at: index)
            let op = Task { try await self.api.modify(threadID: id, add: [], remove: [GmailLabel.inbox]) }
            await selectAfterRemoval(at: index)
            do {
                try await op.value
                undoStack.append(.archive(summary, index: index, removed: true))
            } catch {
                insertRow(summary, at: index)
                await move(to: id)
                handle(error, toast: "Arkistointi epäonnistui")
            }
        } else {
            applyLabels(id, add: [], remove: [GmailLabel.inbox])
            do {
                try await api.modify(threadID: id, add: [], remove: [GmailLabel.inbox])
                undoStack.append(.archive(summary, index: index, removed: false))
            } catch {
                applyLabels(id, add: [GmailLabel.inbox], remove: [])
                handle(error, toast: "Arkistointi epäonnistui")
            }
        }
    }

    public func trash() async {
        if !checkedIDs.isEmpty { await bulkRemove(trashing: true); return }
        guard let id = selectedThreadID, let index = selectedIndex else { return }
        let summary = threads[index]
        removeRow(at: index)
        let op = Task { try await self.api.trash(threadID: id) }
        await selectAfterRemoval(at: index)
        do {
            try await op.value
            undoStack.append(.trash(summary, index: index))
        } catch {
            insertRow(summary, at: index)
            await move(to: id)
            handle(error, toast: "Roskakoriin siirto epäonnistui")
        }
    }

    public func toggleStar() async {
        if !checkedIDs.isEmpty {
            let allStarred = checkedInOrder.allSatisfy { $0.summary.isStarred }
            let labels = [GmailLabel.starred]
            await bulkLabels(allStarred ? .unstar : .star, add: allStarred ? [] : labels, remove: allStarred ? labels : [])
            return
        }
        guard let id = selectedThreadID, let summary = selectedSummary else { return }
        let adding = !summary.isStarred
        let add = adding ? [GmailLabel.starred] : []
        let remove = adding ? [] : [GmailLabel.starred]
        applyLabels(id, add: add, remove: remove)
        do {
            try await api.modify(threadID: id, add: add, remove: remove)
            undoStack.append(.star(threadID: id, added: adding))
        } catch {
            applyLabels(id, add: remove, remove: add)
            handle(error, toast: "Tähden muutos epäonnistui")
        }
    }

    public func markUnread() async {
        if !checkedIDs.isEmpty {
            await bulkLabels(.markUnread, add: [GmailLabel.unread], remove: [])
            return
        }
        guard let id = selectedThreadID else { return }
        applyLabels(id, add: [GmailLabel.unread], remove: [])
        do {
            try await api.modify(threadID: id, add: [GmailLabel.unread], remove: [])
            undoStack.append(.unread(threadID: id))
        } catch {
            applyLabels(id, add: [], remove: [GmailLabel.unread])
            handle(error, toast: "Merkitseminen epäonnistui")
        }
    }

    public func undo() async {
        guard !isUndoing, let action = undoStack.popLast() else { return }
        noteUndone(action)                      // fork (seisemail): daily counter
        isUndoing = true
        defer { isUndoing = false }
        do {
            try await performUndo(action, moveSelection: true)
        } catch {
            handle(error, toast: "Kumoaminen epäonnistui")
        }
    }

    private func performUndo(_ action: UndoAction, moveSelection: Bool) async throws {
        switch action {
        case .archive(let summary, let index, let removed):
            try await api.modify(threadID: summary.id, add: [GmailLabel.inbox], remove: [])
            if removed {
                insertRow(summary, at: index)
            } else {
                applyLabels(summary.id, add: [GmailLabel.inbox], remove: [])
            }
            if moveSelection { await move(to: summary.id) }
        case .trash(let summary, let index):
            try await api.untrash(threadID: summary.id)
            insertRow(summary, at: index)
            if moveSelection { await move(to: summary.id) }
        case .star(let id, let added):
            let labels = [GmailLabel.starred]
            try await api.modify(threadID: id, add: added ? [] : labels, remove: added ? labels : [])
            applyLabels(id, add: added ? [] : labels, remove: added ? labels : [])
        case .unread(let id):
            try await api.modify(threadID: id, add: [], remove: [GmailLabel.unread])
            applyLabels(id, add: [], remove: [GmailLabel.unread])
        case .read(let id):
            try await api.modify(threadID: id, add: [GmailLabel.unread], remove: [])
            applyLabels(id, add: [GmailLabel.unread], remove: [])
        case .relabel(let job):
            try await undoRelabel(job, moveSelection: moveSelection)
        case .batch(let job):
            try await undoBatch(job)
        }
    }

    // MARK: - Helpers

    private func removeRow(at index: Int) {
        changesDuringRefresh?.append(.removed(threads[index].id))
        threads.remove(at: index)
    }

    private func insertRow(_ summary: ThreadSummary, at index: Int) {
        changesDuringRefresh?.append(.restored(summary, index: index))
        guard !threads.contains(where: { $0.id == summary.id }) else { return }
        threads.insert(summary, at: min(index, threads.count))
    }

    private func selectAfterRemoval(at index: Int) async {
        let target: ThreadSummary? = switch afterArchive {
        case .next: index < threads.count ? threads[index] : threads.last
        case .previous: index > 0 ? threads[index - 1] : threads.first
        case .list: nil
        }
        if let target { await move(to: target.id) } else { await select(threadID: nil) }
    }

    private func applyLabels(_ id: String, add: [String], remove: [String]) {
        changesDuringRefresh?.append(.labels(id, add: add, remove: remove))
        let touchesUnread = add.contains(GmailLabel.unread) || remove.contains(GmailLabel.unread)
        if let i = threads.firstIndex(where: { $0.id == id }) {
            let wasUnread = threads[i].isUnread
            threads[i].labelIDs.formUnion(add)
            threads[i].labelIDs.subtract(remove)
            // The thread is in the visible view, so its count changes by one right away.
            if searchQuery == nil, let view = activeViewID, let count = unreadCounts[view], wasUnread != threads[i].isUnread {
                unreadCounts[view] = max(0, count + (threads[i].isUnread ? 1 : -1))
            }
        }
        if touchesUnread {
            onUnreadChanged?(id, add.contains(GmailLabel.unread))
            scheduleCountsRefresh()
        }
        func update(_ thread: inout MailThread) {
            for m in thread.messages.indices {
                thread.messages[m].labelIDs.subtract(remove)
                thread.messages[m].labelIDs.formUnion(add.filter { $0 != GmailLabel.unread })
            }
            // Marking unread applies to the latest message only, like Gmail.
            if add.contains(GmailLabel.unread), let last = thread.messages.indices.last {
                thread.messages[last].labelIDs.insert(GmailLabel.unread)
            }
        }
        if var cached = cache[id] {
            update(&cached)
            cache[id] = cached
        }
        if var open = openThread, open.id == id {
            update(&open)
            openThread = open
        }
    }

    private func persistViews() {
        do {
            try viewsStore.save(views)
        } catch {
            toast = "Näkymien tallennus epäonnistui"
        }
    }

    private func succeeded() {
        isOffline = false
    }

    private func handle(_ error: Error, toast message: String?) {
        Logger(subsystem: "fi.mak8r.mail", category: "store").error("\(message ?? "silent", privacy: .public): \(String(describing: error), privacy: .public)")
        if let e = error as? GmailError, e == .offline {
            isOffline = true
            if let message, message != "Viestien lataus epäonnistui" { toast = message }
            return
        }
        if let e = error as? AuthError, e == .invalidGrant || e == .notSignedIn {
            needsSignIn = true
            return
        }
        if let e = error as? GmailError, e == .rateLimited {
            // Not offline and still signed in: Gmail only asks us to slow down.
            if let message { toast = "\(message). Gmail rajoittaa pyyntöjä. Yritä uudelleen minuutin päästä." }
            return
        }
        if let message { toast = message }
    }
}

// MARK: - Fork (seisemail): generic label-action hook
// In this file because it needs MailStore's private helpers. Snooze itself: MailStore+Snooze.swift.
@MainActor
extension MailStore {
    /// Optimistic, undoable label change for the checked threads, or the selected one.
    /// `removesRow`: the rows leave the active view (removed before the calls, put back on failure).
    /// `optimistic`: IDs known before the call, applied locally at once when the rows stay.
    /// The undo entry is pushed before anything is sent (⌘Z while it runs takes this action back), and
    /// the first final rate limit ends a multi-select action: threads not started yet count as failed.
    /// Returns how many threads were changed (0 when ⌘Z took the action back while it ran).
    @discardableResult
    func relabel(removesRow: Bool, optimistic: LabelChange, failureToast: String,
                 perform: @escaping @Sendable (_ threadID: String) async throws -> RelabelOutcome) async -> Int {
        let single = checkedIDs.isEmpty
        let items: [(summary: ThreadSummary, index: Int)]
        if single {
            guard selectedThreadID != nil, let index = selectedIndex else { return 0 }
            items = [(threads[index], index)]
        } else {
            items = checkedInOrder
            guard !items.isEmpty else { return 0 }
            clearChecked()
        }
        let job = RelabelJob(items: items, query: activeQuery, removesRows: removesRow, optimistic: optimistic)
        if removesRow {
            job.pendingID = holdRemoved(items.map(\.summary.id))
            for item in items.reversed() { removeRow(at: item.index) }
        } else {
            for item in items { applyLabels(item.summary.id, add: optimistic.add, remove: optimistic.remove) }
        }
        undoStack.append(.relabel(job))
        let task = Task { await self.execute(job, perform: perform) }
        job.task = task
        if removesRow {
            if single {
                await selectAfterRemoval(at: items[0].index)
            } else {
                let first = items[0].index
                highlight(threadID: first < threads.count ? threads[first].id : threads.last?.id)
            }
        }
        await task.value
        guard !job.undoRequested else { return 0 }
        if single {
            if let error = job.firstError {
                let id = items[0].summary.id
                if removesRow, threads.contains(where: { $0.id == id }) { await move(to: id) }
                handle(error, toast: failureToast)
            }
        } else {
            reportPartialFailure(job.failed.count, of: items.count)
        }
        return job.outcomes.count
    }

    private func execute(_ job: RelabelJob, perform: @escaping @Sendable (_ threadID: String) async throws -> RelabelOutcome) async {
        let results = RelabelResults()
        let record: (String, Error?) -> Void = { id, error in
            if let error {
                job.failed.insert(id)
                job.firstError = job.firstError ?? error
                if GmailFailure.isRateLimited(error) { job.gaveUp = true }
            } else if let outcome = results[id] {
                job.outcomes[id] = outcome
            }
        }
        _ = await runEach(job.items.map(\.summary.id), while: { !job.undoRequested && !job.gaveUp }, onResult: record) { _, id in
            results.set(id, try await perform(id))
        }
        // After a final rate limit the rest was never sent: those come back as failed too.
        if job.gaveUp, !job.undoRequested {
            for item in job.items where job.outcomes[item.summary.id] == nil { job.failed.insert(item.summary.id) }
        }
        finish(job)
    }

    private func finish(_ job: RelabelJob) {
        job.isDone = true
        let ids = job.items.map(\.summary.id)
        if let pendingID = job.pendingID {                    // before the reinsertions, so their positions hold
            for id in ids where job.outcomes[id] != nil { reassertRemoved(id) }
            releaseRemoved(ids, of: pendingID, failed: job.failed)
        } else {
            for (id, outcome) in job.outcomes { applyLabels(id, add: outcome.applied.add, remove: outcome.applied.remove) }
        }
        putBack(job.failed, of: job)
        if job.undoRequested { return }                       // the waiting undo puts back the rest
        noteFinished(job)
        if job.outcomes.isEmpty {
            undoStack.removeAll { if case .relabel(let j) = $0 { j === job } else { false } }
        }
    }

    /// Rows of `job` that were not changed (failed or never sent), or were reverted (`reverted`), as before it:
    /// removed rows back into the list they left, kept rows with their labels rolled back.
    private func putBack(_ ids: Set<String>, reverted: [String: LabelChange] = [:], of job: RelabelJob) {
        if job.removesRows {
            reinsert(ids.union(reverted.keys), from: job.items, into: job.query)
            return
        }
        for item in job.items {
            let id = item.summary.id
            if ids.contains(id) {
                let rollback = job.optimistic.inverse(before: item.summary.labelIDs)
                applyLabels(id, add: rollback.add, remove: rollback.remove)
            } else if let change = reverted[id] {
                applyLabels(id, add: change.add, remove: change.remove)
            }
        }
    }

    /// Takes back a relabel action, waiting for it first if it is still running.
    private func undoRelabel(_ job: RelabelJob, moveSelection: Bool) async throws {
        if !job.isDone {
            job.undoRequested = true
            await job.task?.value
        }
        if let pendingID = job.pendingID {                    // later lists may show these rows again
            for item in job.items where pendingRemoved[item.summary.id]?.jobID == pendingID {
                pendingRemoved[item.summary.id] = nil
            }
        }
        let sent = Set(job.outcomes.keys).union(job.failed)
        let unsent = Set(job.items.map(\.summary.id)).subtracting(sent)
        let done = job.items.map(\.summary.id).filter { job.outcomes[$0] != nil }
        let undos = job.outcomes.mapValues(\.undo)
        let results = LabelChangeResults()
        var firstError: Error?
        _ = await runEach(done, onResult: { _, error in firstError = firstError ?? error }) { _, id in
            guard let undo = undos[id] else { return }
            results.set(id, try await undo())
        }
        var reverted: [String: LabelChange] = [:]
        for id in done { if let change = results[id] { reverted[id] = change } }
        putBack(unsent, reverted: reverted, of: job)
        if moveSelection, job.items.count == 1, let id = job.items.first?.summary.id, threads.contains(where: { $0.id == id }) {
            await move(to: id)
        }
        if let firstError { throw firstError }
    }

    /// After a successful removing action: a refresh that started while the call was in flight may have listed
    /// the row again (the server had not seen the change yet). Removes it again, and from a refresh still running.
    private func reassertRemoved(_ id: String) {
        if let i = threads.firstIndex(where: { $0.id == id }) {
            removeRow(at: i)
        } else {
            changesDuringRefresh?.append(.removed(id))
        }
    }

    /// Like main's bulk jobs: lists asked while the change runs, or before Gmail's search has caught
    /// up with it, leave these rows out. Returns the id that `releaseRemoved` takes.
    private func holdRemoved(_ ids: [String]) -> UUID {
        prunePendingRemovals()
        let actionID = UUID()
        for id in ids { pendingRemoved[id] = PendingRemoval(jobID: actionID, trashed: false) }
        return actionID
    }

    /// The change is done: failed rows may be listed at once, done ones after the search-lag grace.
    private func releaseRemoved(_ ids: [String], of actionID: UUID, failed: Set<String>) {
        let now = ContinuousClock.now
        for id in ids where pendingRemoved[id]?.jobID == actionID {
            if failed.contains(id) { pendingRemoved[id] = nil } else { pendingRemoved[id]?.releasedAt = now }
        }
    }

    /// What Gmail is asked for `query`: without the exclusions of labels that do not exist.
    private func serverQuery(_ query: String) -> String {
        InboxZero.serverQuery(query, missingLabels: missingLabelNames)
    }

    /// Records which sorting labels are not confirmed to exist. Before the first load it only takes
    /// note; afterwards a change reloads the open list (when its query changes) and the counts.
    public func setMissingLabels(_ names: Set<String>) async {
        guard names != missingLabelNames else { return }
        let before = activeQuery.map(serverQuery)
        missingLabelNames = names
        guard listGeneration > 0 else { return }
        if activeQuery.map(serverQuery) != before { await reloadList() }
        await refreshCounts()
    }

    /// A one-label view's badge by labels.get when the client has the label endpoints, else by search.
    nonisolated static func unreadCount(api: any GmailAPI, query: String, labelID: String?) async throws -> Int {
        if let labelID, let labels = api as? any GmailLabelsAPI {
            return try await labels.labelThreadsUnread(id: labelID)
        }
        return try await api.unreadEstimate(query: query)
    }

    /// Daily-counter hook for pushes: a new undo entry is a done action. Pops are counted by
    /// `undo()` (`noteUndone`), so a bulk job leaving the middle of the stack is not mistaken for one.
    private func noteUndoStackChange(from old: [UndoAction]) {
        guard undoStack.count == old.count + 1, let pushed = undoStack.last else { return }
        report(Self.activity(of: pushed))
    }

    /// Undo pops before the server call: the entry counts back even if Gmail then refuses (risk §10.7).
    private func noteUndone(_ action: UndoAction) {
        report(Self.activity(of: action).negated)
    }

    /// A bulk archive counts when its job is done, only what Gmail confirmed. The job's undo entry was
    /// pushed before anything ran, at zero.
    private func noteFinished(_ job: BulkJob) {
        guard job.action == .archive else { return }
        job.countedArchived = job.items.filter { job.succeeded.contains($0.summary.id) && $0.summary.labelIDs.contains(GmailLabel.inbox) }.count
        report(ActivityCounts(archived: job.countedArchived))
    }

    /// A relabel (snooze) counts when its job is done, only what Gmail confirmed, as a bulk archive does.
    /// Phase 1 invariant: every relabel is a snooze. A second relabel action needs a kind here.
    private func noteFinished(_ job: RelabelJob) {
        job.countedSnoozed = job.items.filter { job.outcomes[$0.summary.id] != nil && $0.summary.labelIDs.contains(GmailLabel.inbox) }.count
        report(ActivityCounts(snoozed: job.countedSnoozed))
    }

    private func report(_ delta: ActivityCounts) {
        if delta != .zero { onActivity?(delta) }
    }

    /// Only threads that left INBOX count (undo entries capture the row before the change).
    private static func activity(of action: UndoAction) -> ActivityCounts {
        switch action {
        case .archive(let s, _, _): s.labelIDs.contains(GmailLabel.inbox) ? ActivityCounts(archived: 1) : .zero
        case .relabel(let job): ActivityCounts(snoozed: job.countedSnoozed)
        case .batch(let job): ActivityCounts(archived: job.countedArchived)
        case .trash, .star, .unread, .read: .zero
        }
    }
}
