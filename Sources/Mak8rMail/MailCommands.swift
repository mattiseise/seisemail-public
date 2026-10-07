import MailCore
import SwiftUI

/// Menu bar. Single-key shortcuts are handled by KeyboardMonitor, so menu titles show them as hints.
struct MailCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Uusi viesti") { app.openCompose(.new) }
                .keyboardShortcut("n")
                .disabled(app.phase != .ready)
        }
        CommandMenu("Viesti") {
            item("Vastaa", "r") { app.openCompose(.reply) }
            item("Vastaa kaikille", "a") { app.openCompose(.replyAll) }
            item("Välitä", "f") { app.openCompose(.forward) }
            Divider()
            item("Arkistoi", "e") { await app.store?.archive() }
            item("Lisää tai poista tähti", "s") { await app.store?.toggleStar() }
            item("Siirrä roskakoriin", "#") { await app.store?.trash() }
            item("Torkuta…", "h") { app.seise.openMenu(session: app.activeSession) }   // fork (seisemail)
                .disabled(app.store?.snoozeTarget == nil)
            item("Merkitse luetuksi", "⇧I") { await app.store?.markRead() }
            item("Merkitse lukemattomaksi", "⇧U") { await app.store?.markUnread() }
            Divider()
            item("Valitse tai poista valinta", "x") { await app.perform(.toggleCheck) }
            item("Valitse kaikki", "⌘A") { app.store?.checkAll() }
            Divider()
            item("Kumoa toiminto", "⌘Z") { await app.store?.undo() }
                .disabled(app.store?.canUndo != true)
            Divider()
            item("Seuraava ketju", "j") { await app.store?.selectNext() }
            item("Edellinen ketju", "k") { await app.store?.selectPrevious() }
        }
        CommandMenu("Näkymä") {
            Button("Hae  /") { app.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Button("Päivitä") { Task { await app.refreshNow() } }
                .keyboardShortcut("r")
            Button("Näytä tai kätke sivupalkki") { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            TextSizeCommands(app: app)
            Divider()
            if app.accounts.emails.count > 1 {
                Divider()
                ForEach(Array(app.accounts.emails.prefix(9).enumerated()), id: \.element) { index, email in
                    Button(email) { app.switchAccount(email) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
            }
            if let store = app.store {
                // ⌥1…9 is handled by KeyboardMonitor (not a menu shortcut) so ⌥2 still types "@" in text fields.
                ForEach(Array(store.views.prefix(9).enumerated()), id: \.element.id) { index, view in
                    Button("\(view.name)    ⌥\(index + 1)") { Task { await store.selectView(view.id) } }
                }
            }
        }
    }

    private func item(_ title: String, _ key: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button("\(title)    \(key)") { Task { await action() } }
            .disabled(app.phase != .ready)
    }
}
