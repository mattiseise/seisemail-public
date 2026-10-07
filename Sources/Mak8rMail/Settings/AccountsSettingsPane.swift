import MailCore
import SwiftUI

struct AccountsSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selected: String?

    private var account: String? {
        selected.flatMap { app.accounts.emails.contains($0) ? $0 : nil } ?? app.accounts.active ?? app.accounts.emails.first
    }

    var body: some View {
        Form {
            Section("Tilit") {
                ForEach(app.accounts.emails, id: \.self) { email in
                    HStack {
                        Text(email)
                        if email == app.accounts.active {
                            Text("käytössä").font(.caption).foregroundStyle(.secondary)
                        }
                        if app.expired.contains(email) {
                            Label("Kirjaudu uudelleen", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Poista", role: .destructive) { Task { await app.removeAccount(email) } }
                    }
                }
                Button("Lisää tili…") { app.signIn() }
            }
            if let account {
                if app.accounts.emails.count > 1 {
                    Section {
                        Picker("Tilin asetukset", selection: Binding(get: { account }, set: { selected = $0 })) {
                            ForEach(app.accounts.emails, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                SignatureSection(email: account)
                Section("Ilmoitukset") {
                    Toggle("Ilmoita uusista viesteistä", isOn: accountBinding(account, \.notificationsEnabled))
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func accountBinding<T>(_ email: String, _ keyPath: WritableKeyPath<MailCore.AccountSettings, T>) -> Binding<T> {
        Binding(
            get: { app.settings.account(email)[keyPath: keyPath] },
            set: { value in app.settings.updateAccount(email) { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct SignatureSection: View {
    @Environment(AppModel.self) private var app
    let email: String
    @State private var selection: Signature.ID?
    @State private var importing = false
    @State private var importMessage: String?

    private var settings: MailCore.AccountSettings { app.settings.account(email) }

    var body: some View {
        Section("Allekirjoitukset") {
            if settings.signatures.isEmpty {
                Text("Ei allekirjoituksia. Lisää oma tai tuo Gmailista.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Muokattava", selection: Binding(
                    get: { selection ?? settings.signatures.first?.id },
                    set: { selection = $0 }
                )) {
                    ForEach(settings.signatures) { Text($0.name).tag(Signature.ID?.some($0.id)) }
                }
                if let id = selection ?? settings.signatures.first?.id, settings.signatures.contains(where: { $0.id == id }) {
                    TextField("Nimi", text: signatureBinding(id, \.name))
                    TextEditor(text: signatureBinding(id, \.text))
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                }
            }
            HStack {
                Button {
                    let signature = Signature(name: "Uusi allekirjoitus", text: "")
                    app.settings.updateAccount(email) { $0.signatures.append(signature) }
                    selection = signature.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Uusi allekirjoitus")
                Button {
                    guard let id = selection ?? settings.signatures.first?.id else { return }
                    app.settings.updateAccount(email) { $0.signatures.removeAll { $0.id == id } }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .help("Poista allekirjoitus")
                .disabled(settings.signatures.isEmpty)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button("Tuo Gmailista") { Task { await importFromGmail() } }
                    .disabled(importing)
            }
            if let importMessage {
                Text(importMessage).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Uusiin viesteihin", selection: defaultBinding(\.defaultForNew)) {
                Text("Ei allekirjoitusta").tag(Signature.ID?.none)
                ForEach(settings.signatures) { Text($0.name).tag(Signature.ID?.some($0.id)) }
            }
            Picker("Vastauksiin ja välityksiin", selection: defaultBinding(\.defaultForReplies)) {
                Text("Ei allekirjoitusta").tag(Signature.ID?.none)
                ForEach(settings.signatures) { Text($0.name).tag(Signature.ID?.some($0.id)) }
            }
        }
    }

    private func signatureBinding(_ id: Signature.ID, _ keyPath: WritableKeyPath<Signature, String>) -> Binding<String> {
        Binding(
            get: { settings.signatures.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                app.settings.updateAccount(email) { account in
                    guard let i = account.signatures.firstIndex(where: { $0.id == id }) else { return }
                    account.signatures[i][keyPath: keyPath] = value
                }
            }
        )
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
            selection = new.first?.id
            importMessage = new.count == 1 ? "Tuotiin 1 allekirjoitus." : "Tuotiin \(new.count) allekirjoitusta."
        } catch {
            importMessage = "Allekirjoituksen tuonti epäonnistui."
        }
    }
}
