import MailCore
import SwiftUI

/// Popover listing accounts with avatar, address and unread count; replaces the plain system menu.
struct AccountSwitcher: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(app.accounts.emails.enumerated()), id: \.element) { index, email in
                AccountRow(
                    email: email,
                    unread: app.sessions.first { $0.email == email }?.monitor.unreadCount ?? 0,
                    active: email == app.accounts.active,
                    expired: app.expired.contains(email),
                    shortcut: index < 9 ? "⌘\(index + 1)" : nil
                ) {
                    app.switchAccount(email)
                    isPresented = false
                }
            }
            Divider().padding(.vertical, 6).padding(.horizontal, 8)
            PopoverAction(symbol: "plus", title: "Lisää tili") {
                isPresented = false
                app.signIn()
            }
            PopoverAction(symbol: "gearshape", title: "Hallitse tilejä…") {
                isPresented = false
                openSettings()
            }
        }
        .padding(8)
        .frame(width: 300)
    }
}

enum AccountName {
    /// "maija.meikalainen@gmail.com" → "Maija Meikalainen"
    static func display(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map { $0.capitalized }.joined(separator: " ")
    }
}

private struct AccountRow: View {
    let email: String
    let unread: Int
    let active: Bool
    let expired: Bool
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Theme.accent : Theme.selected)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(String(AccountName.display(email).prefix(1)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(active ? .white : Theme.muted)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(AccountName.display(email)).font(.system(size: 13, weight: .semibold))
                    if expired {
                        Label("Kirjaudu uudelleen", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else {
                        Text(email).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                if active {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                } else if let shortcut, hovering {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
