import BackgroundTasks
import MailCore
import SwiftUI
import UIKit

@main
struct Mak8rMailiOSApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                app.flushPendingSends()
                AppModel.scheduleBackgroundRefresh()
            }
        }
        .backgroundTask(.appRefresh(AppModel.backgroundRefreshID)) {
            AppModel.scheduleBackgroundRefresh()
            await app.refreshNow()
        }
    }
}

extension AppModel {
    /// iOS may suspend the app soon after it leaves the screen, so messages still
    /// waiting out the undo-send delay go out now, as they do when the Mac app quits.
    func flushPendingSends() {
        guard let pending = pendingSends, !pending.items.isEmpty || pending.isSending else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Lähetys")
        Task {
            let failed = await pending.flush()
            for draft in failed { reopenFailed(draft, error: GmailError.http(0, "background")) }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    nonisolated static let backgroundRefreshID = "fi.mak8r.mail.refresh"

    /// Asks iOS to wake the app now and then to check for new mail and post notifications.
    /// iOS decides when; typically a few times an hour at most, less when the phone is idle.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
