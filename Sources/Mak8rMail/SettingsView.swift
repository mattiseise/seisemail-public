import MailCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("Yleiset", systemImage: "gearshape") {
                GeneralSettingsPane()
            }
            Tab("Tilit", systemImage: "person.crop.circle") {
                AccountsSettingsPane()
            }
            Tab("Kirjoittaminen", systemImage: "square.and.pencil") {
                ComposeSettingsPane()
            }
            Tab("Lukeminen", systemImage: "envelope.open") {
                ReadingSettingsPane()
            }
            Tab("Näkymät", systemImage: "line.3.horizontal.decrease.circle") {
                if let store = app.store {
                    ViewsEditor(store: store)
                } else {
                    ContentUnavailableView("Kirjaudu ensin sisään", systemImage: "person.crop.circle")
                }
            }
            Tab("Pikanäppäimet", systemImage: "keyboard") {
                ShortcutSettingsPane()
            }
        }
        .frame(width: 680, height: 520)
        .onChange(of: app.settings.app) { app.applySettings() }
    }
}

private struct ViewsEditor: View {
    let store: MailStore
    @State private var views: [MailView] = []
    @State private var selection: MailView.ID?

    private var changed: Bool { views != store.views }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Näkymä on tallennettu Gmail-haku, esimerkiksi `from:matti has:attachment` tai `label:työ is:unread`.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($views) { $view in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        TextField("Nimi", text: $view.name)
                            .frame(width: 140)
                        TextField("Gmail-haku", text: $view.query)
                            .font(.system(.body, design: .monospaced))
                    }
                    .tag(view.id)
                }
                .onMove { views.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { views.remove(atOffsets: $0) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button {
                    let view = MailView(name: "Uusi näkymä", query: "in:inbox")
                    views.append(view)
                    selection = view.id
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    views.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil || views.count <= 1)
                Spacer()
                Button("Palauta oletukset") { views = SeiseViews.defaults }   // fork (seisemail)
                Button("Peruuta") { views = store.views }
                    .disabled(!changed)
                Button("Tallenna") {
                    let cleaned = views.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.query.trimmingCharacters(in: .whitespaces).isEmpty }
                    Task { await store.updateViews(cleaned) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed || views.isEmpty)
            }
        }
        .padding(20)
        .onAppear { views = store.views }
    }
}
