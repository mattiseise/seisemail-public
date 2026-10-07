import MailCore
import SwiftUI

/// Full-width, Notion Mail-style list: date groups, one line per thread, side peek on the right.
struct ThreadListView: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    @AppStorage("peekFraction") private var peekFraction = 0.55
    @State private var openFilterID: MailFilter.ID?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    header
                    if store.searchQuery == nil, !store.draftFilters.isEmpty {
                        FilterBar(store: store, openID: $openFilterID)
                    }
                    list
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.isPeekOpen {
                    PeekView(store: store, width: peekWidth(total: geo.size.width)) { newWidth in
                        peekFraction = min(0.85, max(0.35, newWidth / geo.size.width))
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.isPeekOpen)
        }
        .seiseThreadList(store: store)              // fork (seisemail): snooze card, label names, menu closing
    }

    /// Title row at the height of the window buttons; actions on the right.
    private var header: some View {
        HStack(spacing: 8) {
            SelectAllButton(store: store)  // fork (seisemail): select-all circle
            Text(store.activeTitle)
                .font(Theme.title)
            Spacer()
            if !store.checkedIDs.isEmpty {
                BulkToolbar(store: store)
            } else {
                if store.searchQuery == nil {
                    AddFilterMenu(store: store, openID: $openFilterID)
                        .frame(width: 26, height: 26)
                }
                if store.isLoading {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Päivitä (⌘R)") { await app.refreshNow() }
                }
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    /// ⌘-click toggles, ⇧-click extends the multi-selection, a plain click opens the thread.
    private func tap(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            store.toggleChecked(id)
        } else if flags.contains(.shift) {
            store.checkRange(to: id)
        } else {
            store.clearChecked()
            Task { await store.select(threadID: id) }
        }
    }

    private func peekWidth(total: CGFloat) -> CGFloat {
        max(420, total * peekFraction)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    let groups = ThreadGrouping.groups(store.threads)
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(Theme.meta.weight(.medium))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, group.id == groups.first?.id ? 6 : 20)
                            .padding(.bottom, 4)
                            .padding(.horizontal, 12)
                        ForEach(group.threads) { thread in
                            ThreadRow(
                                thread: thread,
                                selected: thread.id == store.selectedThreadID,
                                checked: store.checkedIDs.contains(thread.id),
                                selecting: !store.checkedIDs.isEmpty,
                                onToggleCheck: { store.toggleChecked(thread.id) },
                                wakeLabel: app.seise.wakeLabel(for: thread, in: store, email: app.me)
                            )
                            .id(thread.id)
                            .onTapGesture { tap(thread.id) }
                            .contextMenu { SnoozeRowMenu(store: store, threadID: thread.id) }
                                .onAppear {
                                    if thread.id == store.threads.last?.id, store.canLoadMore {
                                        Task { await store.loadMore() }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
            .overlay { ThreadListEmptyState(store: store) }
            .onChange(of: store.selectedThreadID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    let selected: Bool
    var checked = false
    var selecting = false
    var onToggleCheck: () -> Void = {}
    /// Fork (seisemail): "herää ma 8.00".
    var wakeLabel: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            HStack(spacing: 5) {
                Text(thread.sender)
                    .font(thread.isUnread ? Theme.emphasis : Theme.body)
                    .lineLimit(1)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)").font(Theme.meta).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: Theme.metric(200, cap: 1.5), alignment: .leading)
            Text(thread.subject.isEmpty ? "(ei aihetta)" : thread.subject)
                .foregroundStyle(thread.isUnread ? Theme.text : Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            MeetingBadgeSlot(thread: thread)
            if thread.hasAttachments {
                Image(systemName: "paperclip").font(Theme.font(11)).foregroundStyle(Theme.muted)
            }
            if thread.isStarred {
                Image(systemName: "star.fill").font(Theme.font(10)).foregroundStyle(Theme.accent)
            }
            if let wakeLabel {
                Label(wakeLabel, systemImage: "moon.zzz")
                    .font(Theme.meta.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()                      // the subject column gives way
            }
            Text(RelativeDate.format(thread.date))
                .font(Theme.meta.monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: Theme.metric(48), alignment: .trailing)
        }
        .font(Theme.body)
        .padding(.horizontal, 12)
        .frame(height: Theme.metric(32))
        .contentShape(Rectangle())
        .background(
            checked ? Theme.checked : selected ? Theme.selected : hovering ? Theme.hover : .clear,
            in: RoundedRectangle(cornerRadius: Theme.radius)
        )
        .onHover { hovering = $0 }
    }

    /// Unread dot normally; a selection circle on hover, while selecting, or when checked.
    @ViewBuilder
    private var leading: some View {
        if checked || selecting || hovering {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(Theme.font(13, weight: .light))
                .foregroundStyle(checked ? Theme.accent : Theme.muted)
                .frame(width: Theme.metric(16), height: Theme.metric(16))
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleCheck)
                .help("Valitse (x)")
        } else {
            Circle()
                .fill(thread.isUnread ? Theme.accent : .clear)
                .frame(width: 6, height: 6)
                .frame(width: Theme.metric(16), height: Theme.metric(16))
        }
    }
}

/// Actions for the multi-selection, shown in the toolbar.
struct BulkToolbar: View {
    let store: MailStore

    var body: some View {
        HStack(spacing: 2) {
            Text(SnoozeText.counted(store.checkedIDs.count, "valittu", "valittua"))
                .font(Theme.meta.weight(.medium))
                .foregroundStyle(Theme.muted)
                .padding(.trailing, 6)
            IconButton(symbol: "archivebox", help: "Arkistoi (e)") { await store.archive() }
            IconButton(symbol: "trash", help: "Roskakoriin (#)") { await store.trash() }
            IconButton(symbol: "star", help: "Tähti (s)") { await store.toggleStar() }
            IconButton(symbol: "envelope.open", help: "Merkitse luetuksi (⇧I)") { await store.markRead() }
            IconButton(symbol: "envelope.badge", help: "Merkitse lukemattomaksi (⇧U)") { await store.markUnread() }
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, 6)
            IconButton(symbol: "xmark", help: "Tyhjennä valinta (esc)") { store.clearChecked() }
        }
    }
}

/// Small borderless icon button with hover background, used in headers and toolbars.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: @MainActor () async -> Void
    @State private var hovering = false

    var body: some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint ?? Theme.muted)
                .frame(width: 26, height: 26)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
