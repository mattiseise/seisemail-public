import MailCore
import SwiftUI

@main
struct Mak8rMailApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Mak8r Mail", id: "main") {
            RootView()
                .environment(app)
                .onAppear { delegate.model = app }
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { MailCommands(app: app) }

        MenuBarExtra(isInserted: $app.menuBarIconShown) {
            MenuBarContent()
                .environment(app)
        } label: {
            MenuBarLabel()
                .environment(app)
        }

        Settings {
            SettingsView()
                .environment(app)
                .tint(Theme.accent)
        }
    }
}

/// Sends messages still in their undo-send delay before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let pending = model.pendingSends, !pending.items.isEmpty || pending.isSending else { return .terminateNow }
        Task {
            let failed = await pending.flush()
            // Stay open so the user sees what did not go out.
            for draft in failed { model.reopenFailed(draft, error: GmailError.http(0, "quit")) }
            sender.reply(toApplicationShouldTerminate: failed.isEmpty)
        }
        return .terminateLater
    }
}
