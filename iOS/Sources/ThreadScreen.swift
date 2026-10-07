import MailCore
import SwiftUI

/// The open thread, pushed over the list.
struct ThreadScreen: View {
    @Environment(AppModel.self) private var app
    let store: MailStore

    var body: some View {
        Group {
            if let thread = store.openThread {
                content(thread)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await store.selectPrevious() } } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Edellinen ketju")
                Button { Task { await store.selectNext() } } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Seuraava ketju")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { Task { await store.archive() } } label: { Image(systemName: "archivebox") }
                    .accessibilityLabel("Arkistoi")
                Spacer()
                Button { Task { await store.trash() } } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Siirrä roskakoriin")
                Spacer()
                Button {
                    Task {
                        await store.markUnread()
                        store.closePeek()
                    }
                } label: { Image(systemName: "envelope.badge") }
                    .accessibilityLabel("Merkitse lukemattomaksi")
                Spacer()
                Button { Task { await store.toggleStar() } } label: {
                    Image(systemName: store.selectedSummary?.isStarred == true ? "star.fill" : "star")
                }
                .accessibilityLabel("Lisää tai poista tähti")
                Spacer()
                Menu {
                    Button { app.openCompose(.reply) } label: { Label("Vastaa", systemImage: "arrowshape.turn.up.left") }
                    Button { app.openCompose(.replyAll) } label: { Label("Vastaa kaikille", systemImage: "arrowshape.turn.up.left.2") }
                    Button { app.openCompose(.forward) } label: { Label("Välitä", systemImage: "arrowshape.turn.up.right") }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                } primaryAction: {
                    app.openCompose(.reply)
                }
                .accessibilityLabel("Vastaa")
            }
        }
    }

    private func content(_ thread: MailThread) -> some View {
        let allowImages = app.imagesAllowed(in: thread)
        return VStack(alignment: .leading, spacing: 0) {
            Text(thread.subject.isEmpty ? "(ei aihetta)" : thread.subject)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if !allowImages, thread.messages.contains(where: { $0.htmlBody != nil }) {
                HStack(spacing: 14) {
                    Button("Näytä kuvat") { app.remoteContentAllowed.insert(thread.id) }
                    if app.settings.app.remoteImages == .allowFromSenders, let sender = app.imageSender(of: thread) {
                        Button("Näytä aina kuvat tältä lähettäjältä") { app.trustImages(from: sender) }
                    }
                }
                .font(Theme.meta)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            ThreadWebView(
                html: ThreadHTML.document(for: thread, me: store.me, allowRemoteContent: allowImages),
                allowRemoteContent: allowImages,
                onAttachment: { action in
                    Task { await AttachmentActions.perform(action, thread: thread, app: app) }
                },
                onMailto: { address in
                    guard var draft = app.draft(for: .new) else { return }
                    draft.to = address
                    app.presentCompose(draft)
                }
            )
            .padding(.top, 8)
        }
    }
}
