import MailCore
import SwiftUI

// Fork (seisemail): the thread list's snooze card, wake labels, row menu and empty states.

extension View {
    func seiseThreadList(store: MailStore) -> some View { modifier(SeiseThreadList(store: store)) }
}

private struct SeiseThreadList: ViewModifier {
    @Environment(AppModel.self) private var app
    let store: MailStore
    private struct NamesKey: Equatable { var email: String?; var ids: Set<String> }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { SnoozeMenuHost() }
            // Learns time labels made on another device; network only for IDs the directory never saw.
            .task(id: NamesKey(email: app.me, ids: labelIDs)) { await app.seise.reloadNames(knowing: labelIDs, email: app.me) }
            .onChange(of: store.activeViewID) { app.seise.closeMenu() }
            .onChange(of: app.me) { app.seise.closeMenu() }                    // ⌘1…9 passes through the menu
    }
    private var labelIDs: Set<String> { store.threads.reduce(into: []) { $0.formUnion($1.labelIDs) } }
}

struct SnoozeRowMenu: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    let threadID: String
    var body: some View {
        Button("Torkuta…") {
            if !store.checkedIDs.contains(threadID) {                          // the clicked row, unless part of the selection
                store.clearChecked()
                if store.selectedThreadID != threadID { store.highlight(threadID: threadID) }
            }
            app.seise.openMenu(session: app.activeSession)
        }
    }
}

struct ThreadListEmptyState: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    var body: some View {
        switch store.emptyState {
        case .none: EmptyView()
        case .loading: ProgressView()
        case .inboxZero: InboxZeroView(counter: app.seise.counter)
        case .snoozedEmpty:
            ContentUnavailableView("Ei torkutettuja viestejä", systemImage: "moon.zzz",
                                   description: Text("Torkutetut viestit odottavat täällä herätysaikaansa."))
        case .empty: ContentUnavailableView("Ei viestejä", systemImage: "tray")
        case .offline:
            ContentUnavailableView("Ei yhteyttä", systemImage: "wifi.slash",
                                   description: Text("Viestit latautuvat, kun yhteys palaa."))
        case .failed:
            ContentUnavailableView {
                Label("Viestien lataus epäonnistui", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Yritä hetken kuluttua uudelleen.")
            } actions: {
                Button("Yritä uudelleen") { Task { await store.refresh() } }   // keeps the filter chips
            }
        }
    }
}

/// Inbox 0 (Matti 7.10.2026, after Superhuman): the photo of the day edge to edge, the week streak in the middle,
/// the day's counts bottom left and the photo credit bottom right. The text sits on soft dark scrims and carries a
/// shadow, so it stays readable on any photo (luettavuus voittaa tehokeinon).
struct InboxZeroView: View {
    @Environment(AppModel.self) private var app
    let counter: DailyCounterStore

    private struct WeekKey: Hashable { var email: String?; var monday: Int }

    var body: some View {
        TimelineView(.everyMinute) { ctx in                                    // rolls over at Helsinki midnight
            let day = DailyPhotoStore.day(of: ctx.date)
            InboxZeroPhoto(store: app.seise.photos, day: day, daily: app.settings.app.inboxZeroDailyPhoto) { credit in
                ZStack {
                    InboxZeroScrims()
                    InboxZeroStreakBadge(weeks: app.seise.streak.streak(email: app.me, now: ctx.date))
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            status(now: ctx.date)
                            Spacer(minLength: 24)
                            if let credit { PhotoCreditLine(credit: credit) }
                        }
                    }
                    .padding(.horizontal, Theme.metric(22))
                    .padding(.bottom, Theme.metric(18))
                }
            }
            .task(id: WeekKey(email: app.me, monday: InboxZeroWeeks.monday(of: day))) {
                if let me = app.me { app.seise.streak.record(email: me) }       // this week counts
            }
        }
    }

    private func status(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Inbox 0 – kaikki on käsitelty").font(Theme.font(13, weight: .medium))
            if let line = SnoozeText.dailySummary(counter.counts(now: now)) {
                Text(line).font(Theme.meta.monospacedDigit())
            }
            if let line = SnoozeText.snoozedLine(app.seise.summary(email: app.me), now: now) {
                Label(line, systemImage: "moon.zzz").font(Theme.meta.monospacedDigit())
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.6), radius: 5, y: 1)
        .accessibilityElement(children: .combine)
    }
}
