import MailCore
import SwiftUI

/// Threads grouped by date. Tap opens; swipe left archives or trashes, swipe right marks read/unread or stars.
struct ThreadList: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    let selecting: Bool
    let endSelecting: () -> Void

    var body: some View {
        List {
            ForEach(ThreadGrouping.groups(store.threads)) { group in
                Section {
                    ForEach(group.threads) { thread in
                        row(thread)
                    }
                } header: {
                    Text(group.title)
                        .font(Theme.meta.weight(.medium))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await app.refreshNow() }
        .overlay {
            if store.threads.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Ei viestejä", systemImage: "tray")
                }
            }
        }
    }

    private func row(_ thread: ThreadSummary) -> some View {
        let checked = store.checkedIDs.contains(thread.id)
        return Button {
            if selecting {
                store.toggleChecked(thread.id)
            } else {
                Task { await store.select(threadID: thread.id) }
            }
        } label: {
            ThreadRowView(thread: thread, selecting: selecting, checked: checked)
        }
        .buttonStyle(.plain)
        .listRowBackground(checked ? Theme.checked : Theme.background)
        .swipeActions(edge: .trailing) {
            Button {
                act(on: thread) { await store.archive() }
            } label: {
                Label("Arkistoi", systemImage: "archivebox")
            }
            .tint(Theme.accent)
            Button(role: .destructive) {
                act(on: thread) { await store.trash() }
            } label: {
                Label("Roskakoriin", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                act(on: thread) {
                    if thread.isUnread { await store.markRead() } else { await store.markUnread() }
                }
            } label: {
                Label(thread.isUnread ? "Luettu" : "Lukematon", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
            Button {
                act(on: thread) { await store.toggleStar() }
            } label: {
                Label(thread.isStarred ? "Poista tähti" : "Lisää tähti", systemImage: thread.isStarred ? "star.slash" : "star")
            }
            .tint(.orange)
        }
        .onAppear {
            if thread.id == store.threads.last?.id, store.canLoadMore {
                Task { await store.loadMore() }
            }
        }
    }

    /// Store actions work on the highlighted thread, so a swipe highlights its row first.
    private func act(on thread: ThreadSummary, _ action: @escaping @MainActor () async -> Void) {
        if selecting { endSelecting() }
        store.highlight(threadID: thread.id)
        Task { await action() }
    }
}

struct ThreadRowView: View {
    let thread: ThreadSummary
    var selecting = false
    var checked = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(thread.sender)
                        .font(thread.isUnread ? Theme.emphasis.weight(.semibold) : Theme.body)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(Theme.muted)
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text(RelativeDate.format(thread.date))
                        .font(Theme.meta.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                Text(thread.subject.isEmpty ? "(ei aihetta)" : thread.subject)
                    .font(thread.isUnread ? Theme.meta.weight(.medium) : Theme.meta)
                    .foregroundStyle(thread.isUnread ? Theme.text : Theme.muted)
                    .lineLimit(1)
                if !thread.snippet.isEmpty {
                    Text(thread.snippet)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if selecting {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(checked ? Theme.accent : Theme.muted)
                .frame(width: 22)
        } else {
            Circle()
                .fill(thread.isUnread ? Theme.accent : .clear)
                .frame(width: 8, height: 8)
                .frame(width: 10)
        }
    }
}
