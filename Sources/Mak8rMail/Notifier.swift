#if os(macOS)
import AppKit
#endif
import MailCore
import UserNotifications

/// Posts new-mail notifications and routes clicks back to the app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Called with the thread id (nil for a summary notification) and the account it belongs to.
    var onOpenThread: ((String?, String?) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// - Parameter account: shown as the subtitle's prefix when several accounts are signed in.
    /// - Parameter sound: a system sound name (macOS); nil posts silently.
    func post(_ events: [NewMailEvent], account: String? = nil, sound: String? = nil) {
        guard !events.isEmpty else { return }
        #if os(macOS)
        // Played here rather than via the notification: UNNotificationSound only offers the
        // system default or sounds bundled in the app.
        if let sound { Self.play(sound) }
        #endif
        for event in events {
            let content = UNMutableNotificationContent()
            #if os(macOS)
            content.sound = nil
            #else
            content.sound = sound == nil ? nil : .default
            #endif
            content.threadIdentifier = "new-mail"
            let id: String
            switch event {
            case .single(let thread):
                content.title = thread.sender
                content.subtitle = account.map { "\($0) · \(thread.subject)" } ?? thread.subject
                content.body = thread.snippet
                content.userInfo = ["threadID": thread.id, "account": account ?? ""]
                id = "thread-\(thread.id)"
            case .summary(let count):
                content.title = account ?? "Mak8r Mail"
                content.body = count == 1 ? "1 uusi viesti" : "\(count) uutta viestiä"
                content.userInfo = ["account": account ?? ""]
                id = "summary-\(UUID().uuidString)"
            }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    #if os(macOS)
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
    #endif

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let threadID = info["threadID"] as? String
        let account = (info["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run {
            #if os(macOS)
            NSApp.activate()
            #endif
            self.onOpenThread?(threadID, account)
        }
    }
}
