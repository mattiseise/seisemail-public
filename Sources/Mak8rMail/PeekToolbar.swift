import MailCore
import SwiftUI

/// Side peek actions, in the peek's own header row.
struct PeekToolbar: View {
    @Environment(AppModel.self) private var app
    let store: MailStore

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "arrowshape.turn.up.left", help: "Vastaa (r)") { app.openCompose(.reply) }
            IconButton(symbol: "arrowshape.turn.up.left.2", help: "Vastaa kaikille (a)") { app.openCompose(.replyAll) }
            IconButton(symbol: "arrowshape.turn.up.right", help: "Välitä (f)") { app.openCompose(.forward) }
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, 6)
            IconButton(symbol: "archivebox", help: "Arkistoi (e)") { await store.archive() }
            IconButton(symbol: "trash", help: "Siirrä roskakoriin (#)") { await store.trash() }
            IconButton(symbol: store.selectedSummary?.isStarred == true ? "star.fill" : "star", help: "Lisää tai poista tähti (s)",
                       tint: store.selectedSummary?.isStarred == true ? Theme.accent : nil) { await store.toggleStar() }
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, 6)
            IconButton(symbol: "xmark", help: "Sulje (esc)") { store.closePeek() }
        }
    }
}
