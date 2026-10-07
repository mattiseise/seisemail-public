import MailCore
import SwiftUI

/// Accounts, saved views and folders; the iPhone's version of the Mac sidebar.
struct MailboxesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let store: MailStore
    @State private var naming = false
    @State private var newViewName = ""
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section("Tilit") {
                    ForEach(app.accounts.emails, id: \.self) { email in
                        accountRow(email)
                    }
                    Button {
                        dismiss()
                        // Let the sheet go away before the sign-in sheet comes up.
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            app.signIn()
                        }
                    } label: {
                        Label("Lisää tili", systemImage: "plus")
                    }
                }
                Section("Näkymät") {
                    ForEach(store.views) { view in
                        viewRow(view, count: store.unreadCounts[view.id])
                    }
                    if let search = store.searchQuery {
                        Button {
                            newViewName = search
                            naming = true
                        } label: {
                            Label("Tallenna haku \"\(search)\" näkymäksi", systemImage: "plus.magnifyingglass")
                        }
                    }
                }
                Section("Posti") {
                    ForEach(MailView.folders) { folder in
                        viewRow(folder, count: nil)
                    }
                }
                Section {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Asetukset", systemImage: "gearshape")
                    }
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("Kirjaudu ulos", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Mak8r Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valmis") { dismiss() }
                }
            }
            .alert("Tallenna näkymäksi", isPresented: $naming) {
                TextField("Nimi", text: $newViewName)
                Button("Tallenna") { store.saveSearchAsView(name: newViewName) }
                Button("Peruuta", role: .cancel) {}
            }
            .confirmationDialog("Kirjaudu ulos tililtä \(app.me ?? "")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Kirjaudu ulos", role: .destructive) {
                    dismiss()
                    Task { await app.signOut() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func accountRow(_ email: String) -> some View {
        let unread = app.sessions.first { $0.email == email }?.monitor.unreadCount ?? 0
        return Button {
            app.switchAccount(email)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(email).foregroundStyle(Theme.text)
                    if app.expired.contains(email) {
                        Text("Kirjaudu uudelleen").font(Theme.meta).foregroundStyle(.red)
                    }
                }
                Spacer()
                if unread > 0 {
                    Text("\(unread)").font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.muted)
                }
                if email == app.accounts.active {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func viewRow(_ view: MailView, count: Int?) -> some View {
        let selected = store.searchQuery == nil && store.activeViewID == view.id
        return Button {
            dismiss()
            Task { await store.selectView(view.id) }
        } label: {
            HStack {
                Label(view.name, systemImage: view.icon ?? "line.3.horizontal.decrease")
                    .foregroundStyle(Theme.text)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer()
                if let count, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(Theme.meta.monospacedDigit())
                        .foregroundStyle(selected ? Theme.accent : Theme.muted)
                }
            }
        }
    }
}
