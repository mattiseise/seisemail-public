import MailCore
import SwiftUI

/// Notion-style chip row under the list title: one chip per filter, edited in a popover.
/// Shown while the open view has filters; unsaved changes offer Palauta and Tallenna.
struct FilterBar: View {
    let store: MailStore
    /// The chip whose popover is open; set when a chip is added so it can be filled in at once.
    @Binding var openID: MailFilter.ID?
    @State private var naming = false
    @State private var newViewName = ""

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.draftFilters) { filter in
                        FilterChip(filter: filter, store: store, isOpen: Binding(
                            get: { openID == filter.id },
                            set: { openID = $0 ? filter.id : nil }
                        ))
                    }
                    AddFilterMenu(store: store, openID: $openID, compact: true)
                }
                .padding(.vertical, 2)
            }
            if store.filtersChanged {
                Button("Palauta") { Task { await store.resetFilters() } }
                    .buttonStyle(.plain)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6)
                saveMenu
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .frame(height: Theme.metric(34))
        .alert("Tallenna uutena näkymänä", isPresented: $naming) {
            TextField("Nimi", text: $newViewName)
            Button("Tallenna") { store.saveFiltersAsView(name: newViewName) }
            Button("Peruuta", role: .cancel) {}
        }
    }

    @ViewBuilder private var saveMenu: some View {
        let saveAsNew = {
            newViewName = store.draftFilters.first.map(\.chipText) ?? store.activeTitle
            naming = true
        }
        if store.canSaveFiltersToView {
            Menu {
                Button("Päivitä näkymä ”\(store.activeTitle)”") { store.saveFilters() }
                Button("Tallenna uutena näkymänä…", action: saveAsNew)
            } label: {
                Text("Tallenna").font(Theme.meta.weight(.medium))
            } primaryAction: {
                store.saveFilters()
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
            .fixedSize()
        } else {
            Button("Tallenna näkymäksi…", action: saveAsNew)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
        }
    }
}

/// "+ Suodatin": the filter types. Chips that need a value open their popover when added.
struct AddFilterMenu: View {
    let store: MailStore
    @Binding var openID: MailFilter.ID?
    /// In the chip row: text button; in the title row: icon only.
    var compact = false

    var body: some View {
        Menu {
            Section {
                item("Lähettäjä", "person", .from(""))
                item("Vastaanottaja", "person.2", .to(""))
                item("Aihe", "textformat", .subject(""))
                item("Sisältää", "text.magnifyingglass", .contains(""))
            }
            Section {
                item("Aikaväli", "calendar", .date(.lastDays(7)))
                item("Liitteitä", "paperclip", .attachment(nil))
            }
            Section {
                item("Lukematon", "envelope.badge", .unread)
                item("Luettu", "envelope.open", .read)
                item("Tähdellä", "star", .starred)
                item("Tärkeä", "exclamationmark.circle", .important)
                item("Kalenterikutsu", "calendar.badge.plus", .calendarInvite)
            }
        } label: {
            if compact {
                Label("Suodatin", systemImage: "plus")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Lisää suodatin")
    }

    private func item(_ title: String, _ symbol: String, _ kind: MailFilter.Kind) -> some View {
        Button {
            let filter = MailFilter(kind)
            Task {
                await store.addFilter(filter)
                if filter.kind.needsValue { openID = filter.id }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct FilterChip: View {
    let filter: MailFilter
    let store: MailStore
    @Binding var isOpen: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.kind.symbol).font(.system(size: 10))
                Text(filter.chipText).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .font(Theme.meta)
            .foregroundStyle(filter.kind.hasValue ? Theme.accent : Theme.muted)
            .padding(.horizontal, 8)
            .frame(height: Theme.metric(24))
            .background(hovering ? Theme.selected : Theme.checked, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Poista suodatin") { Task { await store.removeFilter(filter.id) } }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FilterEditor(filter: filter, store: store) { isOpen = false }
        }
    }
}

/// Popover content: on / ei ole and the value. Text is applied on Return or when the popover closes,
/// so typing does not refetch the list on every key.
private struct FilterEditor: View {
    let store: MailStore
    let close: () -> Void
    @State private var draft: MailFilter
    @State private var text: String
    @FocusState private var textFocused: Bool

    init(filter: MailFilter, store: MailStore, close: @escaping () -> Void) {
        self.store = store
        self.close = close
        _draft = State(initialValue: filter)
        _text = State(initialValue: filter.kind.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.kind.editorTitle).font(Theme.emphasis)
                Spacer()
                Picker("", selection: $draft.negated) {
                    Text(draft.kind.negationLabels.on).tag(false)
                    Text(draft.kind.negationLabels.off).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            value
            Divider()
            Button(role: .destructive) {
                Task { await store.removeFilter(draft.id) }
                close()
            } label: {
                Label("Poista suodatin", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .font(Theme.meta)
            .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { textFocused = draft.kind.text != nil }
        // Typing changes only `text`, so this applies choices at once but text on Return or close.
        .onChange(of: draft) { apply() }
        .onDisappear { apply() }
    }

    @ViewBuilder private var value: some View {
        switch draft.kind {
        case .from, .to, .subject, .contains:
            TextField(draft.kind.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit {
                    apply()
                    close()
                }
        case .date(let range):
            DateRangeEditor(range: range) { draft.kind = .date($0) }
        case .attachment(let type):
            Picker("Tyyppi", selection: Binding(get: { type }, set: { draft.kind = .attachment($0) })) {
                Text("Mikä tahansa").tag(MailFilter.AttachmentType?.none)
                ForEach(MailFilter.AttachmentType.allCases, id: \.self) { t in
                    Text(t.title).tag(MailFilter.AttachmentType?.some(t))
                }
            }
        case .unread, .read, .starred, .important, .calendarInvite:
            EmptyView()
        }
    }

    private func apply() {
        var filter = draft
        if filter.kind.text != nil { filter.kind = filter.kind.withText(text) }
        guard store.draftFilters.contains(where: { $0.id == filter.id }),
              store.draftFilters.first(where: { $0.id == filter.id }) != filter else { return }
        Task { await store.updateFilter(filter) }
    }
}

private struct DateRangeEditor: View {
    let range: MailFilter.DateRange
    let onChange: (MailFilter.DateRange) -> Void

    private enum Choice: Hashable { case days(Int), custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Aikaväli", selection: Binding(get: { choice }, set: select)) {
                Text("Viimeiset 7 päivää").tag(Choice.days(7))
                Text("Viimeiset 30 päivää").tag(Choice.days(30))
                Text("Viimeinen vuosi").tag(Choice.days(365))
                Text("Mukautettu").tag(Choice.custom)
            }
            if case .between(let after, let before) = range {
                DatePicker("Alkupäivä", selection: Binding(
                    get: { after ?? Date() },
                    set: { onChange(.between(after: $0, before: before)) }
                ), displayedComponents: .date)
                DatePicker("Loppupäivä", selection: Binding(
                    get: { before ?? Date() },
                    set: { onChange(.between(after: after, before: $0)) }
                ), displayedComponents: .date)
            }
        }
    }

    private var choice: Choice {
        if case .lastDays(let n) = range, [7, 30, 365].contains(n) { return .days(n) }
        return .custom
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .days(let n): onChange(.lastDays(n))
        case .custom:
            let start = Calendar.current.date(byAdding: .day, value: -30, to: Date())
            onChange(.between(after: start, before: Date()))
        }
    }
}

// MARK: - Labels

extension MailFilter {
    /// "Lähettäjä: matti", "Lähettäjä ei ole: matti", "Aihe ei sisällä: lasku", "Ei sisällä: lasku",
    /// "Lukematon", "Ei lukematon", "Ei tähdellä".
    var chipText: String {
        switch kind {
        case .unread, .read, .starred, .important, .calendarInvite:
            return negated ? "Ei \(kind.title.lowercased())" : kind.title
        case .attachment(nil):
            return negated ? "Ei liitteitä" : kind.title
        default:
            let value = kind.valueText ?? "…"
            guard negated else { return "\(kind.title): \(value)" }
            return switch kind {
            case .subject: "Aihe ei sisällä: \(value)"
            case .contains: "Ei sisällä: \(value)"
            case .date: "Aikavälin ulkopuolella: \(value)"
            case .attachment: "Ei liitteitä: \(value)"
            default: "\(kind.title) ei ole: \(value)"
            }
        }
    }
}

extension MailFilter.Kind {
    /// The filter editor's heading before the on/off picker: "Viesti [sisältää | ei sisällä]".
    var editorTitle: String {
        if case .contains = self { return "Viesti" }
        return title
    }

    /// The on/off picker: "Aihe sisältää / ei sisällä", "Lähettäjä on / ei ole".
    var negationLabels: (on: String, off: String) {
        switch self {
        case .subject, .contains: ("sisältää", "ei sisällä")
        default: ("on", "ei ole")
        }
    }

    var title: String {
        switch self {
        case .from: "Lähettäjä"
        case .to: "Vastaanottaja"
        case .subject: "Aihe"
        case .contains: "Sisältää"
        case .date: "Aikaväli"
        case .attachment: "Liitteitä"
        case .unread: "Lukematon"
        case .read: "Luettu"
        case .starred: "Tähdellä"
        case .important: "Tärkeä"
        case .calendarInvite: "Kalenterikutsu"
        }
    }

    var symbol: String {
        switch self {
        case .from: "person"
        case .to: "person.2"
        case .subject: "textformat"
        case .contains: "text.magnifyingglass"
        case .date: "calendar"
        case .attachment: "paperclip"
        case .unread: "envelope.badge"
        case .read: "envelope.open"
        case .starred: "star"
        case .important: "exclamationmark.circle"
        case .calendarInvite: "calendar.badge.plus"
        }
    }

    var placeholder: String {
        switch self {
        case .from, .to: "Nimi tai osoite"
        case .subject: "Otsikon sana"
        default: "Teksti"
        }
    }

    /// The typed value of a text filter; nil for other kinds.
    var text: String? {
        switch self {
        case .from(let v), .to(let v), .subject(let v), .contains(let v): v
        default: nil
        }
    }

    func withText(_ v: String) -> Self {
        switch self {
        case .from: .from(v)
        case .to: .to(v)
        case .subject: .subject(v)
        case .contains: .contains(v)
        default: self
        }
    }

    /// Text filters start empty and open for typing when added.
    var needsValue: Bool { text != nil }

    var hasValue: Bool {
        guard let text else { return true }
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var valueText: String? {
        switch self {
        case .from(let v), .to(let v), .subject(let v), .contains(let v):
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        case .date(.lastDays(let n)):
            return n == 365 ? "viimeinen vuosi" : "\(n) pv"
        case .date(.between(let after, let before)):
            let f = Date.FormatStyle().day().month()
            return "\(after.map { $0.formatted(f) } ?? "")–\(before.map { $0.formatted(f) } ?? "")"
        case .attachment(let type):
            return type?.title ?? "mikä tahansa"
        default:
            return nil
        }
    }
}

extension MailFilter.AttachmentType {
    var title: String {
        switch self {
        case .pdf: "PDF"
        case .image: "Kuvat"
        case .office: "Office-tiedostot"
        }
    }
}
