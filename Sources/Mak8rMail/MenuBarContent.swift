import MailCore
import SwiftUI

/// Menu bar item: unread inbox mail and quick actions. Keeps the app alive when its window is closed.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !app.sessions.isEmpty {
            let many = app.sessions.count > 1
            ForEach(app.sessions) { session in
                let monitor = session.monitor
                if many { Text(session.email).font(.headline) }
                if monitor.unread.isEmpty {
                    Text("Ei lukemattomia viestejä")
                } else {
                    Text(monitor.unreadCount == 1 ? "1 lukematon" : "\(monitor.unreadCount) lukematonta")
                    ForEach(monitor.unread.prefix(5)) { thread in
                        Button {
                            showMain()
                            Task { await app.openThread(thread.id, account: session.email) }
                        } label: {
                            Text("\(thread.sender) – \(thread.subject)")
                        }
                    }
                }
                // Fork (seisemail): "4 torkussa · seuraava herää ma 8.00" opens the account's Torkku view.
                if let line = SnoozeText.snoozedLine(app.seise.summary(email: session.email), now: Date()) {
                    Button { openSnoozed(session.email) } label: { Label(line, systemImage: "moon.zzz") }
                }
                if many { Divider() }
            }
            if !many { Divider() }
            Button("Päivitä") { Task { await app.refreshNow() } }
        }
        Button("Avaa Mak8r Mail") { showMain() }
            .keyboardShortcut("o")
        Divider()
        Button("Lopeta") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func openSnoozed(_ email: String) {
        showMain()
        if app.me != email { app.switchAccount(email) }
        guard let store = app.store, let view = store.views.first(where: { SeiseViews.kind(of: $0) == .snoozed }) else { return }
        Task { await store.selectView(view.id) }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = app.totalUnread
        let snoozed = app.seise.totalSnoozed(emails: app.sessions.map(\.email))   // fork (seisemail)
        if snoozed > 0, let badge = Self.badge(unread: count, snoozed: snoozed) {
            Image(nsImage: badge)
        } else if count > 0 {
            Label("\(count)", systemImage: "envelope.badge")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "envelope")
        }
    }

    /// A status item shows one image and one title, so unread and snoozed are drawn into one template image
    /// (it follows the menu bar's light and dark appearance).
    private static func badge(unread: Int, snoozed: Int) -> NSImage? {
        let content = HStack(spacing: 3) {
            Image(systemName: unread > 0 ? "envelope.badge" : "envelope")
            if unread > 0 { Text("\(unread)") }
            Image(systemName: "moon.zzz").padding(.leading, 5)
            Text("\(snoozed)")
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
