import MailCore
import SwiftUI

/// The signed-in app: the active account's thread list, the open thread and the composer sheet.
struct MailboxView: View {
    @Environment(AppModel.self) private var app
    @State private var leftoverDrafts = 0
    @State private var askRestore = false

    var body: some View {
        Group {
            if let store = app.store {
                MailboxStack(store: store)
                    .id(app.me)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: composing) {
            if let session = app.composeDock.current {
                ComposeScreen(session: session)
                    .id(session.draft.id)
            }
        }
        .onAppear {
            leftoverDrafts = app.unsentDrafts.count
            askRestore = leftoverDrafts > 0
        }
        .alert(leftoverDrafts == 1 ? "Sinulla on 1 tallentamaton luonnos" : "Sinulla on \(leftoverDrafts) tallentamatonta luonnosta", isPresented: $askRestore) {
            Button("Palauta") { app.restoreDrafts() }
            Button("Hylkää", role: .destructive) { app.discardUnsentDrafts() }
        } message: {
            Text(leftoverDrafts == 1 ? "Se jäi kesken edellisellä kerralla." : "Uusin avataan; muut säilyvät luonnoksina.")
        }
    }

    /// Swiping the sheet away closes the composer and keeps the message as a draft.
    private var composing: Binding<Bool> {
        Binding(
            get: { app.composeDock.current != nil },
            set: { if !$0, app.composeDock.current != nil { app.composeDock.dismiss() } }
        )
    }
}

private struct MailboxStack: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    @State private var query = ""
    @State private var showMailboxes = false
    @State private var selecting = false

    var body: some View {
        NavigationStack {
            ThreadList(store: store, selecting: selecting) { selecting = false }
                .navigationTitle(store.activeTitle)
                .searchable(text: $query, prompt: "Hae")
                .onSubmit(of: .search) { Task { await store.search(query) } }
                .onChange(of: query) { _, new in
                    if new.isEmpty, store.searchQuery != nil { Task { await store.search("") } }
                }
                .onChange(of: store.searchQuery) { _, new in if new == nil { query = "" } }
                .toolbar { toolbar }
                .navigationDestination(isPresented: threadOpen) {
                    ThreadScreen(store: store)
                }
        }
        .sheet(isPresented: $showMailboxes) {
            MailboxesView(store: store)
        }
        .overlay(alignment: .top) {
            if store.isOffline {
                Label("Ei yhteyttä", systemImage: "wifi.slash")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) { banners }
        .animation(.easeOut(duration: 0.2), value: app.pendingSends.items.map(\.id))
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .animation(.easeOut(duration: 0.2), value: store.bulkStatuses.map(\.id))
        .animation(.easeOut(duration: 0.2), value: store.isOffline)
        .task(id: store.toast) {
            guard store.toast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            store.toast = nil
        }
        .onChange(of: store.needsSignIn) { _, needs in
            if needs { app.handleExpiredActive() }
        }
        .onChange(of: selecting) { _, on in
            if !on { store.clearChecked() }
        }
    }

    /// The thread screen is pushed while the store has a thread open; going back closes it.
    private var threadOpen: Binding<Bool> {
        Binding(get: { store.isPeekOpen }, set: { if !$0 { store.closePeek() } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showMailboxes = true } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Näkymät ja tilit")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "Valmis" : "Valitse") { selecting.toggle() }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let none = store.checkedIDs.isEmpty
                bulk("archivebox", "Arkistoi", disabled: none) { await store.archive() }
                Spacer()
                bulk("trash", "Roskakoriin", disabled: none) { await store.trash() }
                Spacer()
                bulk("envelope.open", "Merkitse luetuksi", disabled: none) { await store.markRead() }
                Spacer()
                bulk("envelope.badge", "Merkitse lukemattomaksi", disabled: none) { await store.markUnread() }
                Spacer()
                bulk("star", "Tähti", disabled: none) { await store.toggleStar() }
            }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                if store.canUndo {
                    Button { Task { await store.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Kumoa")
                }
                Spacer()
                Group {
                    if store.isLoading {
                        ProgressView()
                    } else if let count = store.activeViewID.flatMap({ store.unreadCounts[$0] }), count > 0, store.searchQuery == nil {
                        Text(count == 1 ? "1 lukematon" : "\(count) lukematonta")
                    }
                }
                .font(Theme.meta)
                .foregroundStyle(Theme.muted)
                Spacer()
                Button { app.openCompose(.new) } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Uusi viesti")
            }
        }
    }

    /// The store takes the checked rows and starts the job before its first suspension, so
    /// selection mode can end at once and the normal toolbar (with Kumoa) shows while it runs.
    private func bulk(_ symbol: String, _ label: String, disabled: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task.immediate { await action() }
            selecting = false
        } label: {
            Image(systemName: symbol)
        }
        .accessibilityLabel(label)
        .disabled(disabled)
    }

    private var banners: some View {
        VStack(spacing: 8) {
            ForEach(app.pendingSends.items) { item in
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Lähetetään…")
                    Button("Peruuta") { app.undoSend(item.id) }
                        .foregroundStyle(Theme.accent)
                }
                .font(Theme.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ForEach(store.bulkStatuses) { status in
                HStack(spacing: 12) {
                    if status.isFinished {
                        Image(systemName: "checkmark").foregroundStyle(Theme.muted)
                    } else if status.isUndoing {
                        ProgressView()
                    } else {
                        ProgressView(value: status.fraction).progressViewStyle(.circular)
                    }
                    Text(status.text).monospacedDigit()
                }
                .font(Theme.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: status.isFinished) {
                    guard status.isFinished else { return }
                    try? await Task.sleep(for: .seconds(3))
                    store.dismissBulkStatus(status.id)
                }
            }
            if let toast = store.toast {
                Text(toast)
                    .font(Theme.body)
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.text, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 64)
    }
}
