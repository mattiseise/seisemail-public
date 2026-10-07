// fork (seisemail): select-all checkbox at the leading edge of the thread list header.
import MailCore
import SwiftUI

/// Tri-state circle lined up with the rows' selection circles. Clicking checks every loaded thread,
/// or clears the selection when they are all checked already. Same effect as ⌘A / esc.
struct SelectAllButton: View {
    let store: MailStore
    @State private var hovering = false

    var body: some View {
        let state = store.checkState
        Button { store.toggleCheckAll() } label: {
            Image(systemName: symbol(state))
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(state == .unchecked ? Theme.muted : Theme.accent)
                .frame(width: 16, height: 16)
                // 24x24 hover/hit area like the header's other buttons, without moving the 16x16 glyph.
                .padding(4)
                .background(hovering ? Theme.hover : .clear, in: Circle())
                .contentShape(Rectangle())
                .padding(-4)
        }
        .buttonStyle(.plain)
        .focusable(false)                        // keyboard focus stays with the list shortcuts
        .disabled(store.threads.isEmpty)
        .opacity(store.threads.isEmpty ? 0.4 : 1)
        .onHover { hovering = $0 && !store.threads.isEmpty }
        .padding(.trailing, 4)                   // title starts where the rows' sender column does
        .help(help(state))                       // shortcut hint lives only here (VoiceOver reads it once, as help)
        .accessibilityLabel(state == .all ? "Tyhjennä valinta" : "Valitse kaikki")
        .accessibilityValue(value(state))
        .accessibilityAddTraits(.isToggle)
    }

    private func symbol(_ state: CheckState) -> String {
        switch state {
        case .unchecked: "circle"
        case .partial: "minus.circle.fill"
        case .all: "checkmark.circle.fill"
        }
    }

    private func help(_ state: CheckState) -> String {
        state == .all ? "Tyhjennä valinta (esc)" : "Valitse kaikki (⌘A)"
    }

    private func value(_ state: CheckState) -> String {
        switch state {
        case .unchecked: "Ei valittu"
        case .partial: "Osittain valittu"
        case .all: "Kaikki valittu"
        }
    }
}
