import AppKit
import MailCore
import SwiftUI

/// Fork (seisemail): Teams/Zoom/Meet highlighting. A list badge from an already parsed body, a
/// Gmail search hit or the subject/snippet, and a join button in the reading pane.
/// Mail content is untrusted: only a rebuilt https URL on an allowlisted host is ever opened, and
/// only when the user clicks. Nothing is labelled.

/// Keeps the search hits of the shown list current (delivery B: 3 × 10 units when the list shows a
/// row or a message no search has covered, at most once a minute). The task restarts on every list
/// change and on an account switch; `MeetingHints` skips lists whose rows were all searched (in any
/// view), lets a search in flight finish when rows were only removed, debounces, waits out the
/// start-up burst and backs off after a 403/429. Cancelling the task never stops a search that has
/// already started.
struct MeetingHintsRefresher: ViewModifier {
    @Environment(AppModel.self) private var app
    let store: MailStore

    private struct Key: Equatable {
        var account: String
        var list: MeetingHints.ListSignature?
    }

    func body(content: Content) -> some View {
        // The session that owns this store: its address keys the hints, its client searches.
        let session = app.sessions.first { $0.store === store }
        let query = store.activeQuery
        let threads = store.threads
        content.task(id: Key(account: session?.email ?? "", list: MeetingHints.signature(query: query, threads: threads))) {
            guard let session else { return }
            await MeetingHintsRegistry.shared.hints(for: session.email)
                .refresh(api: session.api, query: query, threads: threads)
        }
    }
}

extension View {
    func meetingHints(store: MailStore) -> some View {
        modifier(MeetingHintsRefresher(store: store))
    }
}

/// The list row's badge slot: empty unless the thread looks like it has a meeting link.
struct MeetingBadgeSlot: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        if let service = MeetingHintsRegistry.shared.hints(for: app.me).service(for: thread) {
            MeetingBadge(service: service)
        }
    }
}

struct MeetingBadge: View {
    let service: MeetingService

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "video.fill").font(Theme.font(9))
            Text(service.badgeLabel)
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .fixedSize()
        .help(service.badgeHelp)
    }
}

/// The reading pane's join button. Parses the open thread once per message count, outside `body`;
/// the result also confirms or clears the thread's list badge.
struct MeetingJoinSlot: View {
    @Environment(AppModel.self) private var app
    let thread: MailThread

    var body: some View {
        let hints = MeetingHintsRegistry.shared.hints(for: app.me)
        // A container that is always there, so the task runs even while there is no button.
        // The button reads the recorded result, which always belongs to this thread and count.
        HStack(spacing: 0) {
            if let link = hints.link(threadID: thread.id, messageCount: thread.messages.count) {
                MeetingJoinButton(link: link)
            }
        }
        .task(id: "\(app.me ?? "")|\(thread.id)|\(thread.messages.count)") {
            hints.record(thread)
        }
    }
}

struct MeetingJoinButton: View {
    let link: MeetingLink

    var body: some View {
        Button {
            guard let url = MeetingLinkDetector.openableURL(for: link) else { return }
            ThreadWebView.openExternally(url)
        } label: {
            Label(link.service.joinTitle, systemImage: "video.fill")
        }
        // Built here, in `body`, so the button redraws when the text size changes.
        .buttonStyle(MeetingJoinButtonStyle(
            font: Theme.font(12, weight: .medium),
            horizontalPadding: Theme.metric(8),
            verticalPadding: Theme.metric(3)
        ))
        .help("Avautuu selaimessa: \(link.url.host() ?? "")")
        .contextMenu {
            Button("Kopioi kokouslinkki") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }
}

/// Drawn by hand: a native bordered button takes its label font from its control size and
/// ignores the scaled `Theme` font, so it would stay small at every text size.
struct MeetingJoinButtonStyle: ButtonStyle {
    let font: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
            .fixedSize()
    }
}
