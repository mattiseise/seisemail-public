import MailCore
import SwiftUI

/// Fork (seisemail): command-palette-style card over the thread list. The main window stays key.
struct SnoozeMenuHost: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack(alignment: .top) {
            if let menu = app.seise.menu {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { app.seise.closeMenu() }                   // a click outside closes
                    .accessibilityHidden(true)
                SnoozeMenuCard(menu: menu)
                    .padding(.top, 52)                                      // below the 44 pt header
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: app.seise.isMenuOpen)
        .onDisappear { app.seise.closeMenu() }                              // LoginView replaced the list (expiry, sign-in)
    }
}

struct SnoozeMenuCard: View {
    @Environment(AppModel.self) private var app
    let menu: SeiseController.OpenMenu
    private var outsideHelsinki: Bool { TimeZone.current.identifier != SnoozePresets.helsinki.identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(menu.model.title)
                .font(Theme.meta.weight(.medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            switch menu.model.mode {
            case .list:
                ForEach(Array(menu.model.entries.enumerated()), id: \.element.id) { index, entry in
                    SnoozeMenuRow(entry: entry, highlighted: index == menu.model.highlighted) { app.seise.choose(index) }
                }
            case .custom:
                SnoozeCustomTime(model: menu.model, actions: .init(
                    selectDay: { app.seise.selectDay($0) }, setTime: { app.seise.setTime(minutes: $0) },
                    showMonth: { app.seise.showMonth(by: $0) }, focusTime: { app.seise.customField = .time }))
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }
            Hairline().padding(.top, 6)
            Text(menu.model.footer + (outsideHelsinki ? " · ajat Helsingin aikaa" : ""))
                .font(Theme.font(11)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: Theme.metric(360, cap: 1.6))                          // rows to 200 % text; calendar + time
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)              // the ComposeView card idiom
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu.model.title)
        .accessibilityAddTraits(.isModal)
    }
}

/// No `keyboardShortcut`: ↩ and Esc come through KeyboardMonitor, and a shortcut would fire them twice.
struct SnoozeMenuRow: View {
    let entry: SnoozeMenuEntry
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(entry.number)").font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 14)
                Text(entry.title).font(Theme.body).lineLimit(1)
                Spacer(minLength: 12)
                Text(entry.detail).font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: Theme.metric(30)).contentShape(Rectangle())
            .background(highlighted ? Theme.selected : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)                                         // "Tänään illalla" after the evening hour
        .opacity(entry.isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 && entry.isEnabled }
        .padding(.horizontal, 6)
        .accessibilityLabel("\(entry.title), \(entry.detail)")
        .accessibilityHint("Näppäin \(entry.number)")
    }
}
