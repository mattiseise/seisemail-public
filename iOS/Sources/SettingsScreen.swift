import MailCore
import SwiftUI

/// iPhone settings: the Mac's settings tabs as one list.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Tilit") {
                ForEach(app.accounts.emails, id: \.self) { email in
                    NavigationLink {
                        AccountSettingsScreen(email: email)
                    } label: {
                        HStack {
                            Text(email)
                            if app.expired.contains(email) {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Lähetyksen perumisaika", selection: $settings.app.undoSendSeconds) {
                    ForEach(AppSettings.undoSendChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Pois" : "\(seconds) s").tag(seconds)
                    }
                }
                Toggle("Varoita, jos liite puuttuu", isOn: $settings.app.warnMissingAttachment)
            } header: {
                Text("Kirjoittaminen")
            } footer: {
                Text("Lähetetyn viestin voi perua näin monen sekunnin ajan. Jos suljet sovelluksen sitä ennen, viesti lähtee heti.")
            }
            Section {
                Picker("Etäkuvat", selection: $settings.app.remoteImages) {
                    Text("Estä aina").tag(RemoteImagesPolicy.block)
                    Text("Luotetuilta lähettäjiltä").tag(RemoteImagesPolicy.allowFromSenders)
                    Text("Näytä aina").tag(RemoteImagesPolicy.always)
                }
                Picker("Merkitse luetuksi", selection: $settings.app.markRead) {
                    Text("Heti").tag(MarkReadPolicy.immediately)
                    Text("2 sekunnin kuluttua").tag(MarkReadPolicy.afterDelay)
                    Text("Ei koskaan").tag(MarkReadPolicy.never)
                }
                Picker("Arkistoinnin jälkeen", selection: $settings.app.afterArchive) {
                    Text("Seuraava viesti").tag(AfterArchive.next)
                    Text("Edellinen viesti").tag(AfterArchive.previous)
                    Text("Takaisin listaan").tag(AfterArchive.list)
                }
            } header: {
                Text("Lukeminen")
            } footer: {
                Text("Etäkuvilla lähettäjä voi nähdä, milloin avasit viestin.")
            }
            Section("Ilmoitukset") {
                Toggle("Lukemattomien määrä kuvakkeessa", isOn: $settings.app.dockBadge)
                Toggle("Ilmoitusten ääni", isOn: $settings.app.notificationSound)
            }
            if let store = app.store {
                Section {
                    NavigationLink("Näkymät") { ViewsEditorScreen(store: store) }
                }
            }
        }
        .navigationTitle("Asetukset")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: app.settings.app) { app.applySettings() }
    }
}

private struct AccountSettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let email: String
    @State private var importing = false
    @State private var importMessage: String?
    @State private var confirmRemove = false

    private var settings: MailCore.AccountSettings { app.settings.account(email) }

    var body: some View {
        Form {
            Section {
                ForEach(settings.signatures) { signature in
                    NavigationLink(signature.name.isEmpty ? "Nimetön" : signature.name) {
                        SignatureEditor(email: email, id: signature.id)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { settings.signatures[$0].id }
                    app.settings.updateAccount(email) { $0.signatures.removeAll { ids.contains($0.id) } }
                }
                Button {
                    app.settings.updateAccount(email) { $0.signatures.append(Signature(name: "Uusi allekirjoitus", text: "")) }
                } label: {
                    Label("Uusi allekirjoitus", systemImage: "plus")
                }
                Button {
                    Task { await importFromGmail() }
                } label: {
                    HStack {
                        Label("Tuo Gmailista", systemImage: "square.and.arrow.down")
                        if importing { Spacer(); ProgressView() }
                    }
                }
                .disabled(importing)
            } header: {
                Text("Allekirjoitukset")
            } footer: {
                if let importMessage { Text(importMessage) }
            }
            Section {
                Picker("Uusiin viesteihin", selection: defaultBinding(\.defaultForNew)) {
                    Text("Ei allekirjoitusta").tag(Signature.ID?.none)
                    ForEach(settings.signatures) { Text($0.name).tag(Signature.ID?.some($0.id)) }
                }
                Picker("Vastauksiin ja välityksiin", selection: defaultBinding(\.defaultForReplies)) {
                    Text("Ei allekirjoitusta").tag(Signature.ID?.none)
                    ForEach(settings.signatures) { Text($0.name).tag(Signature.ID?.some($0.id)) }
                }
            }
            Section("Ilmoitukset") {
                Toggle("Ilmoita uusista viesteistä", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { value in app.settings.updateAccount(email) { $0.notificationsEnabled = value } }
                ))
            }
            if !settings.trustedImageSenders.isEmpty {
                Section("Luotetut kuvien lähettäjät") {
                    ForEach(settings.trustedImageSenders, id: \.self) { Text($0) }
                        .onDelete { offsets in
                            let senders = offsets.map { settings.trustedImageSenders[$0] }
                            app.settings.updateAccount(email) { $0.trustedImageSenders.removeAll { senders.contains($0) } }
                        }
                }
            }
            Section {
                if app.expired.contains(email) {
                    Button("Kirjaudu uudelleen") {
                        app.switchAccount(email)
                        app.signIn()
                    }
                }
                Button("Poista tili", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(email)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Poistetaanko tili \(email) sovelluksesta?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Poista tili", role: .destructive) {
                dismiss()
                Task { await app.removeAccount(email) }
            }
        } message: {
            Text("Viestit säilyvät Gmailissa.")
        }
    }

    /// Shows "none" for a default that points at a deleted signature.
    private func defaultBinding(_ keyPath: WritableKeyPath<MailCore.AccountSettings, Signature.ID?>) -> Binding<Signature.ID?> {
        Binding(
            get: {
                let id = settings[keyPath: keyPath]
                return settings.signatures.contains { $0.id == id } ? id : nil
            },
            set: { value in app.settings.updateAccount(email) { $0[keyPath: keyPath] = value } }
        )
    }

    private func importFromGmail() async {
        guard let session = app.sessions.first(where: { $0.email == email }) else { return }
        importing = true
        importMessage = nil
        defer { importing = false }
        do {
            let remote = try await session.api.sendAsSignatures()
            let new = GmailSignatureImport.newSignatures(from: remote, existing: settings.signatures)
            if new.isEmpty {
                importMessage = remote.contains { !HTMLText.plainText(fromHTML: $0.html).isEmpty }
                    ? "Gmailin allekirjoitukset on jo tuotu."
                    : "Gmailissa ei ole allekirjoitusta."
                return
            }
            app.settings.updateAccount(email) { $0.signatures.append(contentsOf: new) }
            importMessage = new.count == 1 ? "Tuotiin 1 allekirjoitus." : "Tuotiin \(new.count) allekirjoitusta."
        } catch {
            importMessage = "Allekirjoituksen tuonti epäonnistui."
        }
    }
}

private struct SignatureEditor: View {
    @Environment(AppModel.self) private var app
    let email: String
    let id: Signature.ID

    var body: some View {
        Form {
            Section("Nimi") {
                TextField("Nimi", text: binding(\.name))
            }
            Section("Teksti") {
                TextEditor(text: binding(\.text))
                    .frame(minHeight: 160)
            }
        }
        .navigationTitle("Allekirjoitus")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ keyPath: WritableKeyPath<Signature, String>) -> Binding<String> {
        Binding(
            get: { app.settings.account(email).signatures.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                app.settings.updateAccount(email) { account in
                    guard let i = account.signatures.firstIndex(where: { $0.id == id }) else { return }
                    account.signatures[i][keyPath: keyPath] = value
                }
            }
        )
    }
}

/// Saved Gmail searches shown as views: rename, edit the query, reorder, delete.
private struct ViewsEditorScreen: View {
    let store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var views: [MailView] = []

    private var changed: Bool { views != store.views }

    var body: some View {
        List {
            Section {
                ForEach($views) { $view in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Nimi", text: $view.name)
                            .font(.body.weight(.medium))
                        TextField("Gmail-haku", text: $view.query)
                            .font(.system(.callout, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { views.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { views.remove(atOffsets: $0) }
                Button {
                    views.append(MailView(name: "Uusi näkymä", query: "in:inbox"))
                } label: {
                    Label("Uusi näkymä", systemImage: "plus")
                }
            } footer: {
                Text("Näkymä on tallennettu Gmail-haku, esimerkiksi from:matti has:attachment tai label:työ is:unread.")
            }
            Section {
                Button("Palauta oletukset") { views = ViewsConfigStore.defaults }
            }
        }
        .navigationTitle("Näkymät")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .bottomBar) {
                Button("Tallenna") {
                    let cleaned = views.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
                    Task { await store.updateViews(cleaned) }
                    dismiss()
                }
                .disabled(!changed || views.isEmpty)
            }
        }
        .onAppear { views = store.views }
    }
}
