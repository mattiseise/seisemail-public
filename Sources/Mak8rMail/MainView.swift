import MailCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    let store: MailStore
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        // Own layout rather than NavigationSplitView: macOS 26 draws that sidebar as a floating
        // translucent panel, while this app wants a flat Notion/Linear-style column.
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(store: store)
                    .frame(width: Theme.metric(236, cap: 1.5))
                    .background(Theme.sidebar)
                Hairline(vertical: true)
            }
            ThreadListView(store: store)
                .background(Theme.background)
                .meetingHints(store: store)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .navigationTitle(store.activeTitle)
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .bottomTrailing) { ComposeHost() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
        }
        .overlay(alignment: .top) {
            if store.isOffline {
                Label("Ei yhteyttä – näytetään välimuistissa olevat viestit", systemImage: "wifi.slash")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                ForEach(app.pendingSends.items) { item in
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Lähetetään…")
                        Button("Peruuta") { app.undoSend(item.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(Theme.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ForEach(store.bulkStatuses) { status in
                    BulkStatusRow(status: status) { store.dismissBulkStatus(status.id) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toast = store.toast {
                    Text(toast)
                        .font(Theme.body)
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
        }
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
    }
}

/// A multi-select action running in the background ("Arkistoidaan 140 ketjua…"); once done it
/// shows the result for a moment and goes away by itself.
struct BulkStatusRow: View {
    let status: BulkStatus
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if status.isFinished {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.muted)
            } else if status.isUndoing {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: status.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            Text(status.text)
                .monospacedDigit()
        }
        .font(Theme.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
        .task(id: status.isFinished) {
            guard status.isFinished else { return }
            try? await Task.sleep(for: .seconds(3))
            dismiss()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var leftoverDrafts = 0
    @State private var askRestore = false

    var body: some View {
        Group {
            if app.phase == .ready, let store = app.store {
                MainView(store: store)
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
        .tint(Theme.accent)
        .background(WindowAccessor { app.mainWindow = $0 })
        .onAppear {
            app.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate()
            }
            KeyboardMonitor.shared.install(app)
        }
        .onChange(of: app.phase) { _, phase in
            guard phase == .ready else { return }
            leftoverDrafts = app.unsentDrafts.count
            askRestore = leftoverDrafts > 0
        }
        .alert(leftoverDrafts == 1 ? "Viesti jäi kesken edellisellä kerralla"
               : "\(leftoverDrafts) viestiä jäi kesken edellisellä kerralla", isPresented: $askRestore) {
            Button("Palauta") { app.restoreDrafts() }
            Button("Hylkää", role: .destructive) { app.discardUnsentDrafts() }
        } message: {
            Text(leftoverDrafts == 1 ? "Palauta se, niin voit jatkaa kirjoittamista." : "Uusin avautuu, ja muut säilyvät luonnoksina.")
        }
    }
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("fi.mak8r.mail.toggleSidebar")
}
