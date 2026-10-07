import MailCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    let store: MailStore
    @State private var query = ""
    @State private var naming = false
    @State private var newViewName = ""
    @FocusState private var searchFocused: Bool
    @State private var showAccounts = false
    /// The view being renamed (or nil with `creating` for a new one).
    @State private var renaming: MailView.ID?
    @State private var creating = false
    @State private var renameText = ""
    @State private var dropTarget: MailView.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            account
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
            search
                .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    sectionTitle("Näkymät") {
                        renameText = ""
                        creating = true
                    }
                    ForEach(store.views) { view in
                        row(view, count: count(for: view))
                            .overlay(alignment: .top) {
                                if dropTarget == view.id { Theme.accent.frame(height: 2).offset(y: -1) }
                            }
                            .draggable(view.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                                Task { await store.moveView(id, before: view.id) }
                                return true
                            } isTargeted: { dropTarget = $0 ? view.id : (dropTarget == view.id ? nil : dropTarget) }
                            .contextMenu { viewMenu(view) }
                    }
                    if let search = store.searchQuery {
                        SidebarRow(icon: "magnifyingglass", title: search, count: nil, selected: true) {}
                        Button("Tallenna näkymäksi") {
                            newViewName = search
                            naming = true
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .padding(.leading, 38)
                        .padding(.vertical, 2)
                    }
                    sectionTitle("Posti")
                    ForEach(MailView.folders) { folder in
                        row(folder, count: nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            SidebarRow(icon: "gearshape", title: "Asetukset", count: nil, selected: false, muted: true) {
                openSettings()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .onChange(of: app.searchFocusRequest) { searchFocused = true }
        .onChange(of: store.searchQuery) { _, new in if new == nil { query = "" } }
        .alert("Uusi näkymä", isPresented: $creating) {
            TextField("Nimi", text: $renameText)
            Button("Luo") { Task { await store.createView(name: renameText) } }
            Button("Peruuta", role: .cancel) {}
        } message: {
            Text("Rajaa näkymä suodattimilla ja tallenna.")
        }
        .alert("Nimeä näkymä", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nimi", text: $renameText)
            Button("Tallenna") {
                if let id = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task { await store.editView(id) { $0.name = renameText } }
                }
            }
            Button("Peruuta", role: .cancel) {}
        }
        .alert("Tallenna näkymäksi", isPresented: $naming) {
            TextField("Nimi", text: $newViewName)
            Button("Tallenna") { store.saveSearchAsView(name: newViewName) }
            Button("Peruuta", role: .cancel) {}
        }
    }

    private var account: some View {
        HStack(spacing: 10) {
            Button {
                showAccounts.toggle()
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent)
                        .frame(width: 24, height: 24)
                        .overlay(Text(initial).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(displayName).font(Theme.emphasis).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        Text(app.me ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Vaihda tiliä")
            .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
                AccountSwitcher(isPresented: $showAccounts)
            }
            Spacer(minLength: 4)
            Button {
                app.openCompose(.new)
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .light)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Uusi viesti (c)")
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
            TextField("Hae", text: $query, prompt: Text("Hae"))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    Task { await store.search(query) }
                    searchFocused = false
                }
                .onExitCommand { searchFocused = false }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(Theme.muted)
        .background(searchFocused ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func sectionTitle(_ title: String, add: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
            Spacer()
            if let add {
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Uusi näkymä")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func viewMenu(_ view: MailView) -> some View {
        Button("Nimeä uudelleen…") {
            renameText = view.name
            renaming = view.id
        }
        Menu("Kuvake") {
            ForEach(Self.icons, id: \.symbol) { icon in
                Button {
                    Task { await store.editView(view.id) { $0.icon = icon.symbol } }
                } label: {
                    Label(icon.name, systemImage: icon.symbol)
                }
            }
        }
        Button("Monista") { Task { await store.duplicateView(view.id) } }
        Button("Muokkaa hakua…") { openSettings() }
        Divider()
        Button("Poista", role: .destructive) { Task { await store.deleteView(view.id) } }
            .disabled(store.views.count <= 1)
    }

    static let icons: [(name: String, symbol: String)] = [
        ("Saapuneet", "tray"), ("Tärkeä", "exclamationmark.circle"), ("Uutiskirje", "newspaper"),
        ("Tähti", "star"), ("Henkilö", "person"), ("Ryhmä", "person.2"), ("Työ", "briefcase"),
        ("Dokumentti", "doc.text"), ("Liite", "paperclip"), ("Lasku", "creditcard"), ("Ostos", "cart"),
        ("Kalenteri", "calendar"), ("Lippu", "flag"), ("Salama", "bolt"), ("Sydän", "heart"),
        ("Kirjanmerkki", "bookmark"), ("Suodatin", "line.3.horizontal.decrease"),
    ]

    /// Torkku shows every snoozed thread, read or not (Matti 7.10.2026); other views their unread count.
    private func count(for view: MailView) -> Int? {
        if SeiseViews.kind(of: view) == .snoozed, let total = app.seise.summary(email: app.me)?.total { return total }
        return store.unreadCounts[view.id]
    }

    private func row(_ view: MailView, count: Int?) -> some View {
        SidebarRow(
            icon: view.icon ?? "line.3.horizontal.decrease",
            title: view.name,
            count: count,
            selected: store.searchQuery == nil && store.activeViewID == view.id
        ) {
            Task { await store.selectView(view.id) }
        }
        .help(viewShortcut(view).map { "\($0) · \(view.query)" } ?? view.query)
    }

    private func viewShortcut(_ view: MailView) -> String? {
        guard let i = store.views.firstIndex(where: { $0.id == view.id }), i < 9 else { return nil }
        return "⌥\(i + 1)"
    }

    private var displayName: String {
        app.me.map(AccountName.display) ?? ""
    }

    private var initial: String { String(displayName.prefix(1)) }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let count: Int?
    let selected: Bool
    var muted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(Theme.font(13, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .frame(width: Theme.metric(18))
                Text(title)
                    .font(selected ? Theme.emphasis : Theme.body)
                    .foregroundStyle(muted ? Theme.muted : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(Theme.font(11, weight: .medium).monospacedDigit())
                        .foregroundStyle(selected ? Theme.accent : Theme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.metric(28))
            .contentShape(Rectangle())
            .background(
                selected ? Theme.selected : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.radius)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
